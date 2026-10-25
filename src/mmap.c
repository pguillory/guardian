// Read-only memory mapping of whole files as binaries, for loading segment files.
//
// Replaces the mmap 0.1.1 Hex package. That package never released its resource's
// allocation reference, so no mapping or file descriptor was ever freed, and it leaked
// the descriptor when stat or mmap failed.
//
// The descriptor is closed as soon as the file is mapped: the mapping keeps the file
// alive by itself. The mapping is unmapped when the last binary (or sub-binary)
// referring to it is garbage collected.

#include <erl_nif.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdatomic.h>
#include <stdint.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

struct mapping {
  void * data;
  size_t size;
};

static ErlNifResourceType * mapping_type;

// Mappings whose destructor has not yet run. Tests use it to check release.
static atomic_llong live_mappings = 0;

static ERL_NIF_TERM ok_atom;
static ERL_NIF_TERM error_atom;

static void mapping_destructor(ErlNifEnv * env, void * obj) {
  struct mapping * mapping = (struct mapping *) obj;
  munmap(mapping->data, mapping->size);
  atomic_fetch_sub(&live_mappings, 1);
}

static const char * errno_name(int error) {
  switch (error) {
    case EACCES: return "eacces";
    case EAGAIN: return "eagain";
    case EBADF: return "ebadf";
    case EFBIG: return "efbig";
    case EINTR: return "eintr";
    case EINVAL: return "einval";
    case EIO: return "eio";
    case EISDIR: return "eisdir";
    case ELOOP: return "eloop";
    case EMFILE: return "emfile";
    case ENAMETOOLONG: return "enametoolong";
    case ENFILE: return "enfile";
    case ENODEV: return "enodev";
    case ENOENT: return "enoent";
    case ENOMEM: return "enomem";
    case ENOTDIR: return "enotdir";
    case ENXIO: return "enxio";
    case EOVERFLOW: return "eoverflow";
    case EPERM: return "eperm";
    default: return "unknown";
  }
}

static ERL_NIF_TERM error_tuple(ErlNifEnv * env, int error) {
  return enif_make_tuple2(env, error_atom, enif_make_atom(env, errno_name(error)));
}

static ERL_NIF_TERM read_nif(ErlNifEnv * env, int argc, const ERL_NIF_TERM argv[]) {
  ErlNifBinary path;

  if (argc != 1 || !enif_inspect_binary(env, argv[0], &path)) {
    return enif_make_badarg(env);
  }

  if (path.size >= PATH_MAX) {
    return error_tuple(env, ENAMETOOLONG);
  }

  if (memchr(path.data, 0, path.size) != NULL) {
    return enif_make_badarg(env);
  }

  char filename[PATH_MAX];
  memcpy(filename, path.data, path.size);
  filename[path.size] = 0;

  int fd = open(filename, O_RDONLY | O_CLOEXEC);
  if (fd == -1) {
    return error_tuple(env, errno);
  }

  // Every path below closes fd exactly once before returning.
  struct stat st;
  if (fstat(fd, &st) == -1) {
    int error = errno;
    close(fd);
    return error_tuple(env, error);
  }

  if (S_ISDIR(st.st_mode)) {
    close(fd);
    return error_tuple(env, EISDIR);
  }

  if (!S_ISREG(st.st_mode)) {
    close(fd);
    return error_tuple(env, EINVAL);
  }

  if ((uintmax_t) st.st_size > (uintmax_t) SIZE_MAX) {
    close(fd);
    return error_tuple(env, EFBIG);
  }

  size_t size = (size_t) st.st_size;

  // mmap rejects a zero length.
  if (size == 0) {
    close(fd);
    ERL_NIF_TERM empty;
    enif_make_new_binary(env, 0, &empty);
    return enif_make_tuple2(env, ok_atom, empty);
  }

  void * data = mmap(NULL, size, PROT_READ, MAP_SHARED, fd, 0);
  int map_error = errno;
  close(fd);

  if (data == MAP_FAILED) {
    return error_tuple(env, map_error);
  }

  struct mapping * mapping = enif_alloc_resource(mapping_type, sizeof(struct mapping));
  if (mapping == NULL) {
    munmap(data, size);
    return error_tuple(env, ENOMEM);
  }

  mapping->data = data;
  mapping->size = size;
  atomic_fetch_add(&live_mappings, 1);

  ERL_NIF_TERM binary = enif_make_resource_binary(env, mapping, data, size);
  // The binary holds its own reference. Release the allocation's reference so the
  // destructor unmaps the file once no binary refers to it.
  enif_release_resource(mapping);
  return enif_make_tuple2(env, ok_atom, binary);
}

static ERL_NIF_TERM live_mappings_nif(ErlNifEnv * env, int argc, const ERL_NIF_TERM argv[]) {
  if (argc != 0) {
    return enif_make_badarg(env);
  }
  return enif_make_int64(env, atomic_load(&live_mappings));
}

static ErlNifFunc nif_funcs[] = {
  // open can block on slow storage, so run it off the normal schedulers.
  {"nif_read", 1, read_nif, ERL_NIF_DIRTY_JOB_IO_BOUND},
  {"live_mappings", 0, live_mappings_nif, 0},
};

static int load(ErlNifEnv * env, void ** priv_data, ERL_NIF_TERM load_info) {
  ok_atom = enif_make_atom(env, "ok");
  error_atom = enif_make_atom(env, "error");
  ErlNifResourceFlags tried;
  mapping_type = enif_open_resource_type(env, NULL, "mapping", mapping_destructor, ERL_NIF_RT_CREATE, &tried);
  return mapping_type == NULL;
}

ERL_NIF_INIT(Elixir.Guardian.Storage.Mmap, nif_funcs, load, NULL, NULL, NULL)
