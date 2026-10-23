// Sandboxed jq worker for Guardian's jq() query function.
//
// Guardian starts one of these per jq() evaluation (see Query.Jq) as
// `/usr/bin/env -i priv/jq_worker <time_ms> <row_bytes> <total_bytes> <memory_bytes>`
// and talks to it over stdin/stdout with 4-byte big-endian length-prefixed frames.
//
// Why a separate process: libjq has no interrupt or step-budget hook, and single C
// builtins (string repetition, regex, building huge arrays) can loop or allocate
// without returning to the interpreter. A process can be killed, given a hard memory
// cap, an empty environment, and an OS sandbox, so every limit holds whatever the jq
// program does.
//
// Startup, before any caller data is read:
//   1. The environment must be empty (`env -i`), so $ENV, env, and anything built on
//      them see {}. environ stays a valid empty vector (jq's f_env does not check it
//      for NULL, so clearenv() would crash it).
//   2. Descriptors other than 0, 1, 2 are closed; fd 2 goes to /dev/null so nothing a
//      program does (debug, stderr, compile errors in jq 1.6) reaches the server log.
//   3. Limits: a one-shot wall-clock timer for the whole life of the worker (SIGALRM
//      terminates it), RLIMIT_CPU as an unblockable backstop, RLIMIT_AS (enforced on
//      Linux only), no core files, no new descriptors.
//   4. OS sandbox: seccomp-BPF allowlist on Linux (no open, stat, exec, signals, timer
//      changes, or rlimit changes), sandbox_init pure-computation profile on macOS.
//   5. Self-check: if a file can still be opened or stat-ed, the worker refuses to run.
//
// Requests:
//   'C' <program>                compile (replaces any earlier program)
//   'R' (<u32 len> <json>)*      run the program on each input
//   'Q'                          exit
// Replies:
//   'K'                          compiled
//   'E' <message>                compile error or limit; the caller fails the query
//   'B' (<tag> <u32 len> <data>)* one result per input: 'J' JSON array of outputs,
//                                'N' input is not valid JSON
//
// A jq runtime error ends that input's outputs early, keeping the outputs before it
// (the behavior of the libjq NIF this replaces).

#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <unistd.h>

#include <jq.h>
#include <jv.h>

#if defined(__linux__)
#include <linux/audit.h>
#include <linux/filter.h>
#include <linux/seccomp.h>
#include <stddef.h>
#include <sys/prctl.h>
#include <sys/syscall.h>
#elif defined(__APPLE__)
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
#include <sandbox.h>
#endif

extern char ** environ;

#define MAX_REQUEST_BYTES (8u * 1024 * 1024)
#define MAX_ERROR_BYTES 1024

static long time_limit_ms = 2000;
static size_t max_row_bytes = 1024 * 1024;
static size_t max_total_bytes = 16 * 1024 * 1024;
static size_t memory_limit_bytes = 256 * 1024 * 1024;
static size_t total_output_bytes = 0;
static int self_test = 0;

static jq_state * jq = NULL;
static char error_message[MAX_ERROR_BYTES];

// ---------------------------------------------------------------------------------
// I/O

static void die(int code) {
  _exit(code);
}

static void write_all(const void * data, size_t size) {
  const char * p = data;
  while (size > 0) {
    ssize_t n = write(1, p, size);
    if (n < 0) {
      if (errno == EINTR) continue;
      die(2);
    }
    p += n;
    size -= (size_t) n;
  }
}

static int read_all(void * data, size_t size) {
  char * p = data;
  while (size > 0) {
    ssize_t n = read(0, p, size);
    if (n == 0) return 0;
    if (n < 0) {
      if (errno == EINTR) continue;
      return 0;
    }
    p += n;
    size -= (size_t) n;
  }
  return 1;
}

static void put_u32(unsigned char * p, uint32_t value) {
  p[0] = (unsigned char) (value >> 24);
  p[1] = (unsigned char) (value >> 16);
  p[2] = (unsigned char) (value >> 8);
  p[3] = (unsigned char) value;
}

static uint32_t get_u32(const unsigned char * p) {
  return ((uint32_t) p[0] << 24) | ((uint32_t) p[1] << 16) | ((uint32_t) p[2] << 8) | p[3];
}

static void send_frame(char tag, const void * data, size_t size) {
  if (self_test) {
    // The self test prints lines instead of frames.
    if (tag == 'E') {
      write_all("error: ", 7);
      write_all(data, size);
      write_all("\n", 1);
    }
    return;
  }
  unsigned char header[5];
  put_u32(header, (uint32_t) (size + 1));
  header[4] = (unsigned char) tag;
  write_all(header, 5);
  if (size > 0) write_all(data, size);
}

static void send_error(const char * message) {
  send_frame('E', message, strlen(message));
}

// Growable reply buffer, bounded by max_total_bytes plus framing.
struct buffer {
  char * data;
  size_t size;
  size_t capacity;
};

static void buffer_reserve(struct buffer * b, size_t extra) {
  if (b->size + extra <= b->capacity) return;
  size_t capacity = b->capacity ? b->capacity : 4096;
  while (capacity < b->size + extra) capacity *= 2;
  char * data = realloc(b->data, capacity);
  if (data == NULL) {
    send_error("jq exceeded its memory limit");
    die(3);
  }
  b->data = data;
  b->capacity = capacity;
}

static void buffer_append(struct buffer * b, const void * data, size_t size) {
  buffer_reserve(b, size);
  memcpy(b->data + b->size, data, size);
  b->size += size;
}

// ---------------------------------------------------------------------------------
// jq callbacks

static const char nomem_frame[] = "\0\0\0\x1d" "Ejq exceeded its memory limit";

// Called by jv's allocator when malloc fails (RLIMIT_AS). Allocation-free.
static void nomem_handler(void * data) {
  (void) data;
  if (self_test) {
    static const char ok[] = "ok: memory limit ends the worker\n";
    ssize_t ignored = write(1, ok, sizeof(ok) - 1);
    (void) ignored;
    _exit(0);
  }
  ssize_t ignored = write(1, nomem_frame, sizeof(nomem_frame) - 1);
  (void) ignored;
  _exit(3);
}

static void error_callback(void * data, jv message) {
  (void) data;
  if (error_message[0] == 0) {
    if (jv_get_kind(message) == JV_KIND_STRING) {
      snprintf(error_message, sizeof(error_message), "%s", jv_string_value(message));
    } else {
      snprintf(error_message, sizeof(error_message), "invalid program");
    }
  }
  jv_free(message);
}

static void ignore_message(void * data, jv message) {
  (void) data;
  jv_free(message);
}

// ---------------------------------------------------------------------------------
// Requests

static void compile_program(const char * program, size_t size) {
  if (jq != NULL) {
    jq_teardown(&jq);
  }

  char * text = malloc(size + 1);
  if (text == NULL) nomem_handler(NULL);
  memcpy(text, program, size);
  text[size] = 0;

  jq = jq_init();
  if (jq == NULL) nomem_handler(NULL);
  jq_set_nomem_handler(jq, nomem_handler, NULL);
  error_message[0] = 0;
  jq_set_error_cb(jq, error_callback, NULL);
  jq_set_debug_cb(jq, ignore_message, NULL);
  jq_set_attr(jq, jv_string("JQ_LIBRARY_PATH"), jv_array());

  int ok = strlen(text) == size && jq_compile(jq, text);
  free(text);

  if (!ok) {
    char message[MAX_ERROR_BYTES + 64];
    snprintf(message, sizeof(message), "jq compile error: %s",
             error_message[0] ? error_message : "invalid program");
    jq_teardown(&jq);
    jq = NULL;
    send_error(message);
    return;
  }

  send_frame('K', NULL, 0);
}

// Runs the program on one input. Returns 0 and sends an error on a limit.
static void send_output_limit_error(int row_limit) {
  char message[128];
  if (row_limit)
    snprintf(message, sizeof(message), "jq output for one row exceeds %zu bytes", max_row_bytes);
  else
    snprintf(message, sizeof(message), "jq output exceeds %zu bytes", max_total_bytes);
  send_error(message);
}

static int run_one(struct buffer * reply, const char * input, size_t size) {
  jv value = jv_parse_sized(input, (int) size);
  unsigned char header[5];

  if (!jv_is_valid(value)) {
    jv_free(value);
    header[0] = 'N';
    put_u32(header + 1, 0);
    buffer_append(reply, header, 5);
    return 1;
  }

  size_t start = reply->size;
  header[0] = 'J';
  put_u32(header + 1, 0);
  buffer_append(reply, header, 5);
  buffer_append(reply, "[", 1);
  // Count the row's JSON array exactly: its brackets, then each value and the comma
  // before every value after the first.
  size_t row_bytes = 2;
  total_output_bytes += 2;
  int first = 1;

  if (row_bytes > max_row_bytes || total_output_bytes > max_total_bytes) {
    jv_free(value);
    send_output_limit_error(row_bytes > max_row_bytes);
    return 0;
  }

  jq_start(jq, value, 0);

  for (;;) {
    jv result = jq_next(jq);
    if (!jv_is_valid(result)) {
      jv_free(result);
      break;
    }

    jv text = jv_dump_string(result, 0);
    size_t length = (size_t) jv_string_length_bytes(jv_copy(text));
    size_t added = length + (first ? 0 : 1);
    row_bytes += added;
    total_output_bytes += added;

    if (row_bytes > max_row_bytes || total_output_bytes > max_total_bytes) {
      jv_free(text);
      send_output_limit_error(row_bytes > max_row_bytes);
      return 0;
    }

    if (!first) buffer_append(reply, ",", 1);
    buffer_append(reply, jv_string_value(text), length);
    jv_free(text);
    first = 0;

    if (jq_halted(jq)) break;
  }

  buffer_append(reply, "]", 1);
  put_u32((unsigned char *) reply->data + start + 1, (uint32_t) (reply->size - start - 5));
  return 1;
}

static void run_batch(const unsigned char * payload, size_t size) {
  if (jq == NULL) {
    send_error("jq program not compiled");
    return;
  }

  struct buffer reply = {0};
  buffer_append(&reply, "B", 1);

  while (size > 0) {
    if (size < 4) die(4);
    uint32_t length = get_u32(payload);
    if (length > size - 4) die(4);
    if (!run_one(&reply, (const char *) payload + 4, length)) {
      free(reply.data);
      return;
    }
    payload += 4 + length;
    size -= 4 + length;
  }

  unsigned char header[4];
  put_u32(header, (uint32_t) reply.size);
  write_all(header, 4);
  write_all(reply.data, reply.size);
  free(reply.data);
}

static void serve(void) {
  for (;;) {
    unsigned char header[4];
    if (!read_all(header, 4)) die(0);
    uint32_t size = get_u32(header);
    if (size == 0 || size > MAX_REQUEST_BYTES) die(4);

    unsigned char * payload = malloc(size);
    if (payload == NULL) nomem_handler(NULL);
    if (!read_all(payload, size)) die(0);

    switch (payload[0]) {
    case 'C':
      compile_program((const char *) payload + 1, size - 1);
      break;
    case 'R':
      run_batch(payload + 1, size - 1);
      break;
    case 'Q':
      die(0);
      break;
    default:
      die(4);
    }
    free(payload);
  }
}

// ---------------------------------------------------------------------------------
// Sandbox

static void fail_setup(const char * message) {
  send_error(message);
  die(5);
}

static void close_other_descriptors(void) {
#if defined(__linux__) && defined(SYS_close_range)
  if (syscall(SYS_close_range, 3, ~0U, 0) == 0) return;
#endif
  long max = sysconf(_SC_OPEN_MAX);
  if (max < 0 || max > 65536) max = 65536;
  for (int fd = 3; fd < max; fd++) close(fd);
}

static void set_limit(int resource, rlim_t soft, rlim_t hard) {
  struct rlimit limit = {soft, hard};
  if (setrlimit(resource, &limit) != 0) fail_setup("jq sandbox: setrlimit failed");
}

#if defined(__linux__)

#if defined(__x86_64__)
#define SANDBOX_ARCH AUDIT_ARCH_X86_64
#elif defined(__aarch64__)
#define SANDBOX_ARCH AUDIT_ARCH_AARCH64
#else
#error "jq_worker: seccomp filter needs an architecture"
#endif

#define ALLOW(name) \
  BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, __NR_##name, 0, 1), \
  BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW)

static void install_sandbox(void) {
  struct sock_filter filter[] = {
    BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, arch)),
    BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, SANDBOX_ARCH, 1, 0),
    BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_KILL_PROCESS),
    BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, nr)),
    ALLOW(read),
    ALLOW(write),
    ALLOW(close),
    ALLOW(exit),
    ALLOW(exit_group),
    ALLOW(brk),
    ALLOW(mmap),
    ALLOW(munmap),
    ALLOW(mremap),
    ALLOW(mprotect),
    ALLOW(madvise),
    ALLOW(rt_sigreturn),
    ALLOW(restart_syscall),
    ALLOW(futex),
    ALLOW(sched_yield),
    ALLOW(clock_gettime),
    ALLOW(gettimeofday),
#ifdef __NR_time
    ALLOW(time),
#endif
#ifdef __NR_getrandom
    ALLOW(getrandom),
#endif
    BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ERRNO | (EPERM & SECCOMP_RET_DATA)),
  };
  struct sock_fprog program = {
    .len = (unsigned short) (sizeof(filter) / sizeof(filter[0])),
    .filter = filter,
  };

  if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0) fail_setup("jq sandbox: no_new_privs failed");
  if (prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, &program) != 0) {
    fail_setup("jq sandbox: seccomp failed");
  }
}

#elif defined(__APPLE__)

static void install_sandbox(void) {
  char * error = NULL;
  if (sandbox_init(kSBXProfilePureComputation, SANDBOX_NAMED, &error) != 0) {
    fail_setup("jq sandbox: sandbox_init failed");
  }
}

#pragma clang diagnostic pop

#else
#error "jq_worker: no sandbox for this platform"
#endif

static void check_sandbox(void) {
  struct stat st;
  int fd = open("/", O_RDONLY);
  if (fd >= 0) fail_setup("jq sandbox: files can still be opened");
  if (stat("/", &st) == 0) fail_setup("jq sandbox: files can still be inspected");
#if defined(__linux__)
  if (errno != EPERM) fail_setup("jq sandbox: stat not denied by seccomp");
#endif
}

static void setup(void) {
  if (environ == NULL || environ[0] != NULL) fail_setup("jq sandbox: environment is not empty");

  close_other_descriptors();

  int null_fd = open("/dev/null", O_WRONLY);
  if (null_fd < 0 || dup2(null_fd, 2) < 0) fail_setup("jq sandbox: cannot redirect stderr");
  if (null_fd != 2) close(null_fd);

  sigset_t none;
  sigemptyset(&none);
  sigprocmask(SIG_SETMASK, &none, NULL);
  signal(SIGALRM, SIG_DFL);
  signal(SIGXCPU, SIG_DFL);
  signal(SIGPIPE, SIG_DFL);

  rlim_t cpu_seconds = (rlim_t) (time_limit_ms / 1000 + 1);
  set_limit(RLIMIT_CPU, cpu_seconds, cpu_seconds + 1);
  set_limit(RLIMIT_CORE, 0, 0);
#if defined(__linux__)
  set_limit(RLIMIT_AS, memory_limit_bytes, memory_limit_bytes);
#endif

  jv_nomem_handler(nomem_handler, NULL);

  struct itimerval timer = {{0, 0}, {time_limit_ms / 1000, (time_limit_ms % 1000) * 1000}};
  if (setitimer(ITIMER_REAL, &timer, NULL) != 0) fail_setup("jq sandbox: setitimer failed");

  // Before the sandbox: on Linux, setrlimit is prlimit64, which the filter denies.
  set_limit(RLIMIT_NOFILE, 3, 3);
  install_sandbox();
  check_sandbox();
}

// ---------------------------------------------------------------------------------
// Self test: run by the Dockerfile on the target platform, as
// `env -i priv/jq_worker --self-test`. Prints "ok:" lines and exits 0 only if every
// check passed, ending with the memory limit.

static void say(const char * line) {
  write_all(line, strlen(line));
  write_all("\n", 1);
}

static void expect(const char * program, const char * input, const char * expected) {
  char line[512];
  struct buffer out = {0};

  compile_program(program, strlen(program));
  if (jq == NULL) {
    snprintf(line, sizeof(line), "FAIL: %s does not compile", program);
    say(line);
    die(1);
  }
  // compile_program sent a 'K' frame on stdout; the self test ignores framing.
  run_one(&out, input, strlen(input));
  buffer_append(&out, "", 1);
  const char * json = out.data + 5;
  if (expected != NULL && strcmp(json, expected) != 0) {
    snprintf(line, sizeof(line), "FAIL: %s gave %.200s, expected %s", program, json, expected);
    say(line);
    die(1);
  }
  snprintf(line, sizeof(line), "ok: %s -> %.100s", program, json);
  say(line);
  free(out.data);
}

static void expect_compile_error(const char * program) {
  compile_program(program, strlen(program));
  if (jq != NULL) {
    char line[512];
    snprintf(line, sizeof(line), "FAIL: %s compiled", program);
    say(line);
    die(1);
  }
  char line[512];
  snprintf(line, sizeof(line), "ok: %s does not compile", program);
  say(line);
}

static void run_self_test(void) {
  self_test = 1;
  time_limit_ms = 20000;
  setup();
  say("ok: sandbox installed, environment empty, files denied");

  expect("$ENV", "null", "[{}]");
  expect("env", "null", "[{}]");
  expect("[env, $ENV] | map(length)", "null", "[[0,0]]");
  expect("input_filename", "null", "[null]");
  expect("get_search_list", "null", "[[]]");
  expect("[inputs]", "null", "[[]]");
  expect("\"abc\" | test(\"b\")", "null", "[true]");
  expect("\"a1b22\" | [scan(\"[0-9]+\")]", "null", "[[\"1\",\"22\"]]");
  expect("now | type", "null", "[\"number\"]");
  expect("0 | todate", "null", "[\"1970-01-01T00:00:00Z\"]");
  expect("\"2015-03-05T23:51:47Z\" | fromdate", "null", "[1425599507]");
  expect("0 | localtime | mktime", "null", NULL);
  expect("0 | strftime(\"%Y\")", "null", "[\"1970\"]");
  expect("[range(200000)] | length", "null", "[200000]");
  expect("\"x\" * 100000 | length", "null", "[100000]");
  expect("1, error(\"boom\"), 2", "null", "[1]");
  expect("1, halt_error, 2", "null", "[1]");
  expect(".a", "{\"a\": 5}", "[5]");
  expect_compile_error("import \"passwd\" as $p {search: \"/etc\"}; $p");
  expect_compile_error("include \"x\" {search: \"/\"}; 1");
  expect_compile_error("{");

#if defined(__linux__)
  // Ends in nomem_handler, which prints the last ok line and exits 0.
  compile_program("[range(1e10)]", strlen("[range(1e10)]"));
  struct buffer out = {0};
  run_one(&out, "null", 4);
  say("FAIL: memory limit did not end the worker");
  die(1);
#else
  // RLIMIT_AS is not enforced here; running this would eat host memory.
  say("ok: memory limit check skipped (not enforced on this platform)");
  die(0);
#endif
}

int main(int argc, char ** argv) {
  if (argc == 2 && strcmp(argv[1], "--self-test") == 0) {
    run_self_test();
    return 0;
  }

  if (argc != 5) fail_setup("usage: jq_worker <time_ms> <row_bytes> <total_bytes> <memory_bytes>");
  time_limit_ms = strtol(argv[1], NULL, 10);
  max_row_bytes = strtoull(argv[2], NULL, 10);
  max_total_bytes = strtoull(argv[3], NULL, 10);
  memory_limit_bytes = strtoull(argv[4], NULL, 10);
  if (time_limit_ms <= 0 || max_row_bytes == 0 || max_total_bytes == 0 || memory_limit_bytes == 0) {
    fail_setup("jq_worker: invalid limits");
  }

  setup();
  serve();
  return 0;
}
