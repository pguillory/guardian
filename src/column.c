#include <assert.h>
#include <erl_nif.h>
#include <math.h>
#include <limits.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// Sizes, counts, and offsets are 64-bit throughout. All targets are 64-bit.
_Static_assert(sizeof(size_t) == 8, "size_t must be 64 bits");
_Static_assert(sizeof(void *) == 8, "pointers must be 64 bits");

// A size that cannot be represented or an allocation that fails aborts the VM with a
// message, as the BEAM does when it runs out of memory. Every size that comes from a
// NIF argument is bounded first, so these fire only on real out-of-memory or a bug.
static void fail(const char * message) {
  fprintf(stderr, "column NIF: %s\r\n", message);
  abort();
}

static size_t checked_add(size_t a, size_t b) {
  size_t result;
  if (__builtin_add_overflow(a, b, &result)) {
    fail("size overflow");
  }
  return result;
}

static size_t checked_mul(size_t a, size_t b) {
  size_t result;
  if (__builtin_mul_overflow(a, b, &result)) {
    fail("size overflow");
  }
  return result;
}

// C may return NULL for a zero-size allocation, so every allocation has at least one
// byte.
static void * xmalloc(size_t size) {
  void * data = malloc(size > 0 ? size : 1);
  if (data == NULL) {
    fail("out of memory");
  }
  return data;
}

static void * xcalloc(size_t size) {
  void * data = calloc(size > 0 ? size : 1, 1);
  if (data == NULL) {
    fail("out of memory");
  }
  return data;
}

static void * xrealloc(void * data, size_t size) {
  data = realloc(data, size > 0 ? size : 1);
  if (data == NULL) {
    fail("out of memory");
  }
  return data;
}

// 64-bit words in a bitmap of count bits, without overflowing near UINT64_MAX.
static size_t bitmap_words(uint64_t count) {
  return count / 64 + (count % 64 != 0);
}

static size_t bitmap_bytes(uint64_t count) {
  return checked_mul(bitmap_words(count), sizeof(uint64_t));
}

struct slice {
  size_t size;
  unsigned char * data;
};

struct buffer {
  struct slice used;
  struct slice free;
};

struct buffer buffer_open(void * data, size_t size) {
  return (struct buffer) {
    .used = {.size = 0, .data = data},
    .free = {.size = size, .data = data}
  };
}

void buffer_write(struct buffer * buffer, void * data, size_t size) {
  assert(buffer->free.size >= size);
  memcpy(buffer->free.data, data, size);
  buffer->used.size += size;
  buffer->free.data += size;
  buffer->free.size -= size;
}

void buffer_write_zeroes(struct buffer * buffer, size_t size) {
  assert(buffer->free.size >= size);
  memset(buffer->free.data, 0, size);
  buffer->used.size += size;
  buffer->free.data += size;
  buffer->free.size -= size;
}

unsigned char * buffer_read(struct buffer * buffer, size_t size) {
  assert(buffer->free.size >= size);
  unsigned char * data = buffer->free.data;
  buffer->used.size += size;
  buffer->free.data += size;
  buffer->free.size -= size;
  return data;
}

void assert_buffer_consumed(struct buffer * buffer, void * data, size_t size) {
  assert(buffer->used.size == size);
  assert(buffer->used.data == data);
  assert(buffer->free.size == 0);
  assert(buffer->free.data == data + size);
}

// Storage.Column.nil_column_size/1 depends on this being 72 bytes.
struct header {
  uint64_t count;
  uint64_t null_count;
  uint64_t false_count;
  uint64_t true_count;
  uint64_t int_count;
  uint64_t float_count;
  uint64_t string_count;
  uint64_t list_count;
  uint64_t string_total_sizes;
};
_Static_assert(sizeof(struct header) == 72, "nil_column_size assumes a 72-byte header");

struct column {
  struct header * header;
  // Rows the bitmaps have room for.
  uint64_t capacity;
  // Elements each value array has room for. They grow with their own counts rather
  // than with capacity, so a column of mostly nils holds little more memory than its
  // packed size.
  uint64_t int_values_capacity;
  uint64_t float_values_capacity;
  uint64_t string_sizes_capacity;
  uint64_t list_lengths_capacity;
  // Bytes allocated for string_values. Packed columns point into their binary and are
  // never appended to.
  uint64_t string_capacity;
  uint64_t * null_bitmap;
  uint64_t * false_bitmap;
  uint64_t * true_bitmap;
  uint64_t * int_bitmap;
  uint64_t * float_bitmap;
  uint64_t * string_bitmap;
  uint64_t * list_bitmap;
  int64_t * int_values;
  double * float_values;
  int32_t * string_sizes;
  int32_t * list_lengths;
  char * string_values;
};

// The largest string size or list length of one value: the packed format stores them
// as int32_t.
#define MAX_VALUE_LENGTH INT32_MAX
// The largest row count or capacity an argument may ask for. Far beyond any real
// column, it keeps every size computed from it representable.
#define MAX_COLUMN_CAPACITY (1ULL << 40)
#define MAX_COLUMNS_PER_STACK 3

static ERL_NIF_TERM max_string_size_nif(ErlNifEnv * env, int argc, const ERL_NIF_TERM argv[]) {
  if (argc != 0) {
    return enif_make_badarg(env);
  }

  return enif_make_int(env, MAX_VALUE_LENGTH);
}

static ERL_NIF_TERM max_list_length_nif(ErlNifEnv * env, int argc, const ERL_NIF_TERM argv[]) {
  if (argc != 0) {
    return enif_make_badarg(env);
  }

  return enif_make_int(env, MAX_VALUE_LENGTH);
}

static ERL_NIF_TERM max_list_depth_nif(ErlNifEnv * env, int argc, const ERL_NIF_TERM argv[]) {
  if (argc != 0) {
    return enif_make_badarg(env);
  }

  return enif_make_int(env, MAX_COLUMNS_PER_STACK);
}

struct stack {
  int num_columns;
  struct column columns[MAX_COLUMNS_PER_STACK];
};

struct column_resource {
  struct stack * stack;
};

ErlNifResourceType * column_resource_type;

ERL_NIF_TERM ok_atom;
ERL_NIF_TERM error_atom;
ERL_NIF_TERM nil_atom;
ERL_NIF_TERM false_atom;
ERL_NIF_TERM true_atom;

void init_atoms(ErlNifEnv * env) {
  ok_atom = enif_make_atom(env, "ok");
  error_atom = enif_make_atom(env, "error");
  nil_atom = enif_make_atom(env, "nil");
  false_atom = enif_make_atom(env, "false");
  true_atom = enif_make_atom(env, "true");
}

size_t column_size(struct column * column) {
  size_t p = sizeof(struct header);
  // Seven bitmaps: null, false, true, int, float, string, and list.
  p = checked_add(p, checked_mul(bitmap_bytes(column->header->count), 7));
  p = checked_add(p, checked_mul(column->header->int_count, sizeof(int64_t)));
  p = checked_add(p, checked_mul(column->header->float_count, sizeof(double)));
  p = checked_add(p, checked_mul(column->header->string_count, sizeof(int32_t)));
  p = checked_add(p, checked_mul(column->header->list_count, sizeof(int32_t)));
  p = checked_add(p, column->header->string_total_sizes);
  p = checked_add(p, (4 - (p & 3)) & 3);
  return p;
}

size_t stack_size(struct stack * stack) {
  size_t p = 0;
  for (int i = 0; i < stack->num_columns; i++) {
    struct column * column = &stack->columns[i];
    p = checked_add(p, column_size(column));
  }
  return p;
}

void pack_column(struct column * column, struct buffer * buffer) {
  assert(((intptr_t) buffer->free.data & 3) == 0);
  buffer_write(buffer, column->header, sizeof(struct header));
  size_t bitmap_size = bitmap_bytes(column->header->count);
  buffer_write(buffer, column->null_bitmap, bitmap_size);
  buffer_write(buffer, column->false_bitmap, bitmap_size);
  buffer_write(buffer, column->true_bitmap, bitmap_size);
  buffer_write(buffer, column->int_bitmap, bitmap_size);
  buffer_write(buffer, column->float_bitmap, bitmap_size);
  buffer_write(buffer, column->string_bitmap, bitmap_size);
  buffer_write(buffer, column->list_bitmap, bitmap_size);
  buffer_write(buffer, column->int_values, checked_mul(column->header->int_count, sizeof(int64_t)));
  buffer_write(buffer, column->float_values, checked_mul(column->header->float_count, sizeof(double)));
  buffer_write(buffer, column->string_sizes, checked_mul(column->header->string_count, sizeof(int32_t)));
  buffer_write(buffer, column->list_lengths, checked_mul(column->header->list_count, sizeof(int32_t)));
  buffer_write(buffer, column->string_values, column->header->string_total_sizes);
  buffer_write_zeroes(buffer, (4 - ((intptr_t) buffer->free.data & 3)) & 3);
}

ERL_NIF_TERM pack_stack(ErlNifEnv * env, struct stack * stack) {
  size_t size = stack_size(stack);
  ERL_NIF_TERM result;
  unsigned char * data = enif_make_new_binary(env, size, &result);
  struct buffer buffer = buffer_open(data, size);

  for (int i = 0; i < stack->num_columns; i++) {
    struct column * column = &stack->columns[i];
    pack_column(column, &buffer);
  }
  assert_buffer_consumed(&buffer, data, size);
  return result;
}

void unpack_column(struct column * column, struct buffer * buffer) {
  assert(((intptr_t) buffer->free.data & 3) == 0);
  column->header = (struct header *) buffer_read(buffer, sizeof(struct header));
  column->capacity = column->header->count;
  column->int_values_capacity = column->header->int_count;
  column->float_values_capacity = column->header->float_count;
  column->string_sizes_capacity = column->header->string_count;
  column->list_lengths_capacity = column->header->list_count;
  column->string_capacity = column->header->string_total_sizes;
  size_t bitmap_size = bitmap_bytes(column->header->count);
  column->null_bitmap = (uint64_t *) buffer_read(buffer, bitmap_size);
  column->false_bitmap = (uint64_t *) buffer_read(buffer, bitmap_size);
  column->true_bitmap = (uint64_t *) buffer_read(buffer, bitmap_size);
  column->int_bitmap = (uint64_t *) buffer_read(buffer, bitmap_size);
  column->float_bitmap = (uint64_t *) buffer_read(buffer, bitmap_size);
  column->string_bitmap = (uint64_t *) buffer_read(buffer, bitmap_size);
  column->list_bitmap = (uint64_t *) buffer_read(buffer, bitmap_size);
  column->int_values = (int64_t *) buffer_read(buffer, checked_mul(column->header->int_count, sizeof(int64_t)));
  column->float_values = (double *) buffer_read(buffer, checked_mul(column->header->float_count, sizeof(double)));
  column->string_sizes = (int32_t *) buffer_read(buffer, checked_mul(column->header->string_count, sizeof(int32_t)));
  column->list_lengths = (int32_t *) buffer_read(buffer, checked_mul(column->header->list_count, sizeof(int32_t)));
  column->string_values = (char *) buffer_read(buffer, column->header->string_total_sizes);
  buffer_read(buffer, (4 - ((intptr_t) buffer->free.data & 3)) & 3);
}

void unpack_stack(struct stack * stack, unsigned char * data, size_t size) {
  struct buffer buffer = buffer_open(data, size);
  stack->num_columns = 0;
  struct column * column = NULL;
  do {
    column = &stack->columns[stack->num_columns++];
    unpack_column(column, &buffer);
  } while (column->header->list_count > 0 && stack->num_columns < MAX_COLUMNS_PER_STACK);
  assert(column->header->list_count == 0);
  assert(size == stack_size(stack));
  assert_buffer_consumed(&buffer, data, size);
}

// Callers bound capacity by MAX_COLUMN_CAPACITY.
void init_column(struct column * column, uint64_t capacity) {
  assert(capacity <= MAX_COLUMN_CAPACITY);
  column->header = xmalloc(sizeof(struct header));
  column->header->count = 0;
  column->header->null_count = 0;
  column->header->false_count = 0;
  column->header->true_count = 0;
  column->header->int_count = 0;
  column->header->float_count = 0;
  column->header->string_count = 0;
  column->header->list_count = 0;
  column->header->string_total_sizes = 0;
  column->capacity = capacity;
  size_t bitmap_size = bitmap_bytes(capacity);
  column->null_bitmap = xcalloc(bitmap_size);
  column->false_bitmap = xcalloc(bitmap_size);
  column->true_bitmap = xcalloc(bitmap_size);
  column->int_bitmap = xcalloc(bitmap_size);
  column->float_bitmap = xcalloc(bitmap_size);
  column->string_bitmap = xcalloc(bitmap_size);
  column->list_bitmap = xcalloc(bitmap_size);
  column->int_values = xmalloc(checked_mul(capacity, sizeof(int64_t)));
  column->float_values = xmalloc(checked_mul(capacity, sizeof(double)));
  column->string_sizes = xmalloc(checked_mul(capacity, sizeof(int32_t)));
  column->list_lengths = xmalloc(checked_mul(capacity, sizeof(int32_t)));
  column->int_values_capacity = capacity;
  column->float_values_capacity = capacity;
  column->string_sizes_capacity = capacity;
  column->list_lengths_capacity = capacity;
  column->string_values = xmalloc(0);
  column->string_capacity = 0;
}

// Returns NULL if capacity is more than MAX_COLUMN_CAPACITY. Callers return badarg.
struct stack * alloc_stack(const uint64_t capacity) {
  if (capacity > MAX_COLUMN_CAPACITY) {
    return NULL;
  }
  struct stack * stack = xmalloc(sizeof(struct stack));
  stack->num_columns = 1;
  struct column * column = &stack->columns[0];
  init_column(column, capacity);
  return stack;
}

struct column * add_column(struct stack * stack) {
  assert(stack->num_columns < MAX_COLUMNS_PER_STACK);
  struct column * column = &stack->columns[stack->num_columns++];
  init_column(column, 0);
  return column;
}

void realloc_column(struct column * column, const uint64_t capacity) {
  assert(capacity > column->capacity);
  size_t old_bitmap_size = bitmap_bytes(column->capacity);
  size_t new_bitmap_size = bitmap_bytes(capacity);
  column->capacity = capacity;
  column->null_bitmap = xrealloc(column->null_bitmap, new_bitmap_size);
  column->false_bitmap = xrealloc(column->false_bitmap, new_bitmap_size);
  column->true_bitmap = xrealloc(column->true_bitmap, new_bitmap_size);
  column->int_bitmap = xrealloc(column->int_bitmap, new_bitmap_size);
  column->float_bitmap = xrealloc(column->float_bitmap, new_bitmap_size);
  column->string_bitmap = xrealloc(column->string_bitmap, new_bitmap_size);
  column->list_bitmap = xrealloc(column->list_bitmap, new_bitmap_size);

  size_t bitmap_size_diff = new_bitmap_size - old_bitmap_size;

  memset((void *) column->null_bitmap + old_bitmap_size, 0, bitmap_size_diff);
  memset((void *) column->false_bitmap + old_bitmap_size, 0, bitmap_size_diff);
  memset((void *) column->true_bitmap + old_bitmap_size, 0, bitmap_size_diff);
  memset((void *) column->int_bitmap + old_bitmap_size, 0, bitmap_size_diff);
  memset((void *) column->float_bitmap + old_bitmap_size, 0, bitmap_size_diff);
  memset((void *) column->string_bitmap + old_bitmap_size, 0, bitmap_size_diff);
  memset((void *) column->list_bitmap + old_bitmap_size, 0, bitmap_size_diff);
}

void free_column(struct column * column) {
  free(column->header);
  free(column->null_bitmap);
  free(column->false_bitmap);
  free(column->true_bitmap);
  free(column->int_bitmap);
  free(column->float_bitmap);
  free(column->string_bitmap);
  free(column->list_bitmap);
  free(column->int_values);
  free(column->float_values);
  free(column->string_sizes);
  free(column->list_lengths);
  free(column->string_values);
}

void free_stack(struct stack * stack) {
  for (int i = 0; i < stack->num_columns; i++) {
    free_column(&stack->columns[i]);
  }
  free(stack);
}

// Drops nested layers that no list refers to. The packed format ends at the first
// layer without lists, so such layers must not be packed.
void trim_unused_layers(struct stack * stack) {
  int num_columns = 1;
  while (num_columns < stack->num_columns &&
         stack->columns[num_columns - 1].header->list_count > 0) {
    num_columns++;
  }
  for (int i = num_columns; i < stack->num_columns; i++) {
    free_column(&stack->columns[i]);
  }
  stack->num_columns = num_columns;
}

ERL_NIF_TERM pack_and_free_stack(ErlNifEnv * env, struct stack * stack) {
  ERL_NIF_TERM result = pack_stack(env, stack);
  free_stack(stack);
  return result;
}

void assert_valid_column(struct column * column, uint64_t expected_total_list_length) {
  assert(column->header->count == column->header->null_count
                                + column->header->false_count
                                + column->header->true_count
                                + column->header->int_count
                                + column->header->float_count
                                + column->header->string_count
                                + column->header->list_count);

  assert(column->header->count <= column->capacity);

  uint64_t count = column->header->count;

#ifndef GOFASTERINPROD
  if (count > 129) {
    return;
  }
#endif

  uint64_t null_count = 0;
  uint64_t false_count = 0;
  uint64_t true_count = 0;
  uint64_t int_count = 0;
  uint64_t float_count = 0;
  uint64_t string_count = 0;
  uint64_t list_count = 0;

  uint64_t word_count = bitmap_words(count);

  for (uint64_t word = 0; word < word_count; word++) {
    null_count += __builtin_popcountll(column->null_bitmap[word]);
    false_count += __builtin_popcountll(column->false_bitmap[word]);
    true_count += __builtin_popcountll(column->true_bitmap[word]);
    int_count += __builtin_popcountll(column->int_bitmap[word]);
    float_count += __builtin_popcountll(column->float_bitmap[word]);
    string_count += __builtin_popcountll(column->string_bitmap[word]);
    list_count += __builtin_popcountll(column->list_bitmap[word]);
  }

  assert(null_count == column->header->null_count);
  assert(false_count == column->header->false_count);
  assert(true_count == column->header->true_count);
  assert(int_count == column->header->int_count);
  assert(float_count == column->header->float_count);
  assert(string_count == column->header->string_count);
  assert(list_count == column->header->list_count);

  // Every word but the last is full.
  for (uint64_t word = 0; word + 1 < word_count; word++) {
    assert(64 == (__builtin_popcountll(column->null_bitmap[word]
                                     | column->false_bitmap[word]
                                     | column->true_bitmap[word]
                                     | column->int_bitmap[word]
                                     | column->float_bitmap[word]
                                     | column->string_bitmap[word]
                                     | column->list_bitmap[word])));

    assert(64 == (__builtin_popcountll(column->null_bitmap[word])
                + __builtin_popcountll(column->false_bitmap[word])
                + __builtin_popcountll(column->true_bitmap[word])
                + __builtin_popcountll(column->int_bitmap[word])
                + __builtin_popcountll(column->float_bitmap[word])
                + __builtin_popcountll(column->string_bitmap[word])
                + __builtin_popcountll(column->list_bitmap[word])));
  }

  if (word_count > 0 && (count % 64) > 0) {
    for (uint64_t word = word_count - 1; word < word_count; word++) {
      uint64_t bit = count % 64;
      uint64_t mask = ~(-1ULL << bit);

      assert(bit == (uint64_t) (__builtin_popcountll(column->null_bitmap[word]
                                        | column->false_bitmap[word]
                                        | column->true_bitmap[word]
                                        | column->int_bitmap[word]
                                        | column->float_bitmap[word]
                                        | column->string_bitmap[word]
                                        | column->list_bitmap[word])));

      assert(bit == (uint64_t) (__builtin_popcountll(column->null_bitmap[word])
                   + __builtin_popcountll(column->false_bitmap[word])
                   + __builtin_popcountll(column->true_bitmap[word])
                   + __builtin_popcountll(column->int_bitmap[word])
                   + __builtin_popcountll(column->float_bitmap[word])
                   + __builtin_popcountll(column->string_bitmap[word])
                   + __builtin_popcountll(column->list_bitmap[word])));

      assert(mask == (column->null_bitmap[word]
                    | column->false_bitmap[word]
                    | column->true_bitmap[word]
                    | column->int_bitmap[word]
                    | column->float_bitmap[word]
                    | column->string_bitmap[word]
                    | column->list_bitmap[word]));
    }
  }

  for (uint64_t offset = 0, float_offset = 0; offset < count; offset++) {
    uint64_t word = offset / 64;
    uint64_t bit = offset % 64;
    if (column->float_bitmap[word] & 1ULL << bit) {
      assert(isfinite(column->float_values[float_offset++]));
    }
  }

  uint64_t string_total_sizes = 0;
  for (uint64_t offset = 0, string_offset = 0; offset < count; offset++) {
    uint64_t word = offset / 64;
    uint64_t bit = offset % 64;
    if (column->string_bitmap[word] & 1ULL << bit) {
      int32_t string_size = column->string_sizes[string_offset++];
      assert(string_size >= 0);
      string_total_sizes += (uint64_t) string_size;
    }
  }
  assert(string_total_sizes == column->header->string_total_sizes);

  uint64_t total_list_length = 0;
  for (uint64_t i = 0; i < list_count; i++) {
    int32_t list_length = column->list_lengths[i];
    assert(list_length >= 0);
    total_list_length += (uint64_t) list_length;
  }
  assert(total_list_length == expected_total_list_length);
}

void assert_valid_stack(struct stack * stack) {
  assert(stack->num_columns >= 1);
  assert(stack->num_columns <= MAX_COLUMNS_PER_STACK);
  uint64_t expected_total_list_length = 0;
  for (int i = stack->num_columns - 1; i >= 0; i--) {
    assert_valid_column(&stack->columns[i], expected_total_list_length);
    expected_total_list_length = stack->columns[i].header->count;
  }
  assert(stack->columns[stack->num_columns - 1].header->list_count == 0);
}

void ensure_available_capacity(struct column * column) {
  if (column->header->count < column->capacity) {
    return;
  }
  realloc_column(column, column->capacity > 0 ? checked_mul(column->capacity, 2) : 64);
}

// Makes room in a value array for one element past count, doubling its capacity.
void * reserve_value(void * values, uint64_t * capacity, uint64_t count, size_t element_size) {
  assert(count <= *capacity);
  if (count < *capacity) {
    return values;
  }
  *capacity = *capacity > 0 ? checked_mul(*capacity, 2) : 8;
  return xrealloc(values, checked_mul(*capacity, element_size));
}

// Bytes a mutable column holds in memory.
size_t column_allocated_size(struct column * column) {
  size_t p = sizeof(struct header);
  p = checked_add(p, checked_mul(bitmap_bytes(column->capacity), 7));
  p = checked_add(p, checked_mul(column->int_values_capacity, sizeof(int64_t)));
  p = checked_add(p, checked_mul(column->float_values_capacity, sizeof(double)));
  p = checked_add(p, checked_mul(column->string_sizes_capacity, sizeof(int32_t)));
  p = checked_add(p, checked_mul(column->list_lengths_capacity, sizeof(int32_t)));
  p = checked_add(p, column->string_capacity);
  return p;
}

void append_null(struct column * column) {
  ensure_available_capacity(column);
  uint64_t word = column->header->count / 64;
  uint64_t bit = column->header->count % 64;
  column->null_bitmap[word] |= 1ULL << bit;
  column->header->count += 1;
  column->header->null_count += 1;
}

void append_false(struct column * column) {
  ensure_available_capacity(column);
  uint64_t word = column->header->count / 64;
  uint64_t bit = column->header->count % 64;
  column->false_bitmap[word] |= 1ULL << bit;
  column->header->count += 1;
  column->header->false_count += 1;
}

void append_true(struct column * column) {
  ensure_available_capacity(column);
  uint64_t word = column->header->count / 64;
  uint64_t bit = column->header->count % 64;
  column->true_bitmap[word] |= 1ULL << bit;
  column->header->count += 1;
  column->header->true_count += 1;
}

void append_int(struct column * column, int64_t value) {
  ensure_available_capacity(column);
  uint64_t word = column->header->count / 64;
  uint64_t bit = column->header->count % 64;
  column->int_bitmap[word] |= 1ULL << bit;
  column->int_values = reserve_value(column->int_values, &column->int_values_capacity, column->header->int_count, sizeof(int64_t));
  column->int_values[column->header->int_count] = value;
  column->header->count += 1;
  column->header->int_count += 1;
}

void append_float(struct column * column, double value) {
  ensure_available_capacity(column);
  uint64_t word = column->header->count / 64;
  uint64_t bit = column->header->count % 64;
  column->float_bitmap[word] |= 1ULL << bit;
  column->float_values = reserve_value(column->float_values, &column->float_values_capacity, column->header->float_count, sizeof(double));
  column->float_values[column->header->float_count] = value;
  column->header->count += 1;
  column->header->float_count += 1;
}

// For arithmetic results: a value that isn't finite (division by zero, overflow) is
// stored as null. A column never holds inf or NaN (assert_valid_column).
void append_arithmetic_float(struct column * column, double value) {
  if (isfinite(value)) {
    append_float(column, value);
  }
  else {
    append_null(column);
  }
}

void append_string(struct column * column, size_t size, unsigned char * data) {
  assert(size <= MAX_VALUE_LENGTH);
  ensure_available_capacity(column);
  uint64_t word = column->header->count / 64;
  uint64_t bit = column->header->count % 64;
  column->string_bitmap[word] |= 1ULL << bit;
  column->string_sizes = reserve_value(column->string_sizes, &column->string_sizes_capacity, column->header->string_count, sizeof(int32_t));
  column->string_sizes[column->header->string_count] = (int32_t) size;
  if (size > 0) {
    // Grow geometrically, so filling a layer with strings takes linear time.
    assert(column->string_capacity >= column->header->string_total_sizes);
    size_t needed = checked_add(column->header->string_total_sizes, size);
    if (needed > column->string_capacity) {
      size_t capacity = column->string_capacity > 0 ? checked_mul(column->string_capacity, 2) : 64;
      if (capacity < needed) {
        capacity = needed;
      }
      column->string_values = xrealloc(column->string_values, capacity);
      column->string_capacity = capacity;
    }
    memcpy(column->string_values + column->header->string_total_sizes, data, size);
  }
  column->header->count += 1;
  column->header->string_count += 1;
  column->header->string_total_sizes += size;
}

void append_list_length(struct column * column, uint64_t list_length) {
  assert(list_length <= MAX_VALUE_LENGTH);
  ensure_available_capacity(column);
  uint64_t word = column->header->count / 64;
  uint64_t bit = column->header->count % 64;
  column->list_bitmap[word] |= 1ULL << bit;
  column->list_lengths = reserve_value(column->list_lengths, &column->list_lengths_capacity, column->header->list_count, sizeof(int32_t));
  column->list_lengths[column->header->list_count] = (int32_t) list_length;
  column->header->count += 1;
  column->header->list_count += 1;
}

// Checks that append_term can store value at layer_index without failing partway.
int validate_term(ErlNifEnv * env, int layer_index, ERL_NIF_TERM value) {
  if (layer_index < 0 || layer_index >= MAX_COLUMNS_PER_STACK) {
    return 0;
  }

  ErlNifSInt64 int_value;
  double float_value;
  ErlNifBinary string_value;

  if (value == nil_atom || value == false_atom || value == true_atom) {
    return 1;
  }
  else if (enif_get_int64(env, value, &int_value)) {
    return 1;
  }
  else if (enif_get_double(env, value, &float_value)) {
    return isfinite(float_value);
  }
  else if (enif_inspect_binary(env, value, &string_value)) {
    return string_value.size <= MAX_VALUE_LENGTH;
  }
  else if (enif_is_list(env, value)) {
    if (layer_index + 1 >= MAX_COLUMNS_PER_STACK) {
      return 0;
    }
    ERL_NIF_TERM head, tail = value;
    uint64_t list_length = 0;
    while (enif_get_list_cell(env, tail, &head, &tail)) {
      list_length += 1;
      if (list_length > MAX_VALUE_LENGTH ||
          !validate_term(env, layer_index + 1, head)) {
        return 0;
      }
    }
    return enif_is_empty_list(env, tail);
  }
  else {
    return 0;
  }
}

// Callers must validate value with validate_term first, so that a failure cannot leave
// the stack partially updated.
int append_term(ErlNifEnv * env, struct stack * stack, int layer_index, ERL_NIF_TERM value) {
  assert(layer_index >= 0);
  assert(layer_index < stack->num_columns);
  struct column * column = &stack->columns[layer_index];

  ErlNifSInt64 int_value;
  double float_value;
  ErlNifBinary string_value;

  if (value == nil_atom) {
    append_null(column);
    return 1;
  }
  else if (value == false_atom) {
    append_false(column);
    return 1;
  }
  else if (value == true_atom) {
    append_true(column);
    return 1;
  }
  else if (enif_get_int64(env, value, &int_value)) {
    append_int(column, int_value);
    return 1;
  }
  else if (enif_get_double(env, value, &float_value)) {
    append_float(column, float_value);
    return 1;
  }
  else if (enif_inspect_binary(env, value, &string_value)) {
    append_string(column, string_value.size, string_value.data);
    return 1;
  }
  else if (enif_is_list(env, value)) {
    int next_layer = layer_index + 1;
    if (next_layer >= stack->num_columns) {
      if (stack->num_columns >= MAX_COLUMNS_PER_STACK) {
        return 0;
      }
      add_column(stack);
    }
    assert(next_layer < stack->num_columns);
    ERL_NIF_TERM head, tail = value;
    uint64_t list_length = 0;
    while (enif_get_list_cell(env, tail, &head, &tail)) {
      list_length += 1;
      if (!append_term(env, stack, next_layer, head)) {
        return 0;
      }
    }
    append_list_length(column, list_length);
    return 1;
  }
  else {
    return 0;
  }
}

// Column resources whose destructor has not yet run. Tests use it to check that dropped
// columns release their native buffers.
static atomic_llong live_columns = 0;

void free_column_resource(ErlNifEnv * env, void * obj) {
  struct column_resource * column_resource = (struct column_resource *) obj;
  free_stack(column_resource->stack);
  column_resource->stack = NULL;
  atomic_fetch_sub(&live_columns, 1);
}

int create_column_resource_type(ErlNifEnv * env) {
  ErlNifResourceFlags tried;
  column_resource_type = enif_open_resource_type(env, NULL, "column", free_column_resource, ERL_NIF_RT_CREATE, &tried);
  return column_resource_type != NULL;
}

int get_stack_from_resource(ErlNifEnv * env, ERL_NIF_TERM arg, struct stack ** stack) {
  struct column_resource * column_resource;

  if (!enif_get_resource(env, arg, column_resource_type, (void **) &column_resource)) {
    return 0;
  }

  *stack = column_resource->stack;
  assert_valid_stack(*stack);
  return 1;
}

int get_stack_from_resource_or_binary(ErlNifEnv * env, ERL_NIF_TERM arg, struct stack * stack) {
  ErlNifBinary packed_column;
  struct column_resource * column_resource;

  if (enif_inspect_binary(env, arg, &packed_column)) {
    unpack_stack(stack, packed_column.data, packed_column.size);
  }
  else if (enif_get_resource(env, arg, column_resource_type, (void **) &column_resource)) {
    *stack = *column_resource->stack;
  } else {
    return 0;
  }

  assert_valid_stack(stack);
  return 1;
}

static ERL_NIF_TERM new_nif(ErlNifEnv * env, int argc, const ERL_NIF_TERM argv[]) {
  ErlNifUInt64 capacity;

  if (argc != 1 ||
      !enif_get_uint64(env, argv[0], &capacity) ||
      capacity > MAX_COLUMN_CAPACITY) {
    return enif_make_badarg(env);
  }

  struct column_resource * column_resource = enif_alloc_resource(column_resource_type, sizeof(struct column_resource));
  column_resource->stack = alloc_stack(capacity);
  assert(column_resource->stack != NULL);
  assert_valid_stack(column_resource->stack);
  atomic_fetch_add(&live_columns, 1);
  ERL_NIF_TERM term = enif_make_resource(env, column_resource);
  // The term holds its own reference. Release the allocation's reference so the
  // destructor runs, freeing the buffers, once no term refers to the column.
  enif_release_resource(column_resource);
  return term;
}

static ERL_NIF_TERM live_columns_nif(ErlNifEnv * env, int argc, const ERL_NIF_TERM argv[]) {
  if (argc != 0) {
    return enif_make_badarg(env);
  }
  return enif_make_int64(env, atomic_load(&live_columns));
}

static ERL_NIF_TERM pad_nif(ErlNifEnv * env, int argc, const ERL_NIF_TERM argv[]) {
  struct stack * stack;
  ErlNifUInt64 new_count;

  if (argc != 2 ||
      !get_stack_from_resource(env, argv[0], &stack) ||
      !enif_get_uint64(env, argv[1], &new_count) ||
      new_count > MAX_COLUMN_CAPACITY) {
    return enif_make_badarg(env);
  }

  struct column * column = &stack->columns[0];

  while (column->header->count < new_count) {
    append_null(column);
  }

  assert_valid_stack(stack);
  return argv[0];
}

static ERL_NIF_TERM append_nif(ErlNifEnv * env, int argc, const ERL_NIF_TERM argv[]) {
  struct stack * stack;

  if (argc != 2 ||
      !get_stack_from_resource(env, argv[0], &stack)) {
    return enif_make_badarg(env);
  }

  if (!validate_term(env, 0, argv[1])) {
    return enif_make_badarg(env);
  }

  if (!append_term(env, stack, 0, argv[1])) {
    // Unreachable after validation. Crash loudly in debug builds rather than leave a
    // partially appended value behind.
    assert(0);
    return enif_make_badarg(env);
  }

  assert_valid_stack(stack);
  return ok_atom;
}

// Returns true if value can be appended to an empty column.
static ERL_NIF_TERM valid_value_nif(ErlNifEnv * env, int argc, const ERL_NIF_TERM argv[]) {
  if (argc != 1) {
    return enif_make_badarg(env);
  }

  return validate_term(env, 0, argv[0]) ? true_atom : false_atom;
}

static ERL_NIF_TERM pack_nif(ErlNifEnv * env, int argc, const ERL_NIF_TERM argv[]) {
  struct stack * stack;

  if (argc != 1 ||
      !get_stack_from_resource(env, argv[0], &stack)) {
    return enif_make_badarg(env);
  }

  return pack_stack(env, stack);
}

// The size of the column once packed. For a packed column, its byte size.
static ERL_NIF_TERM packed_size_nif(ErlNifEnv * env, int argc, const ERL_NIF_TERM argv[]) {
  struct stack stack;

  if (argc != 1 ||
      !get_stack_from_resource_or_binary(env, argv[0], &stack)) {
    return enif_make_badarg(env);
  }

  return enif_make_uint64(env, stack_size(&stack));
}

// The bytes of a mutable column's buffers, across all of its layers, without its
// fixed structs and allocator overhead.
static ERL_NIF_TERM allocated_size_nif(ErlNifEnv * env, int argc, const ERL_NIF_TERM argv[]) {
  struct stack * stack;

  if (argc != 1 ||
      !get_stack_from_resource(env, argv[0], &stack)) {
    return enif_make_badarg(env);
  }

  size_t size = 0;
  for (int i = 0; i < stack->num_columns; i++) {
    size = checked_add(size, column_allocated_size(&stack->columns[i]));
  }
  return enif_make_uint64(env, size);
}

static ERL_NIF_TERM from_list_nif(ErlNifEnv * env, int argc, const ERL_NIF_TERM argv[]) {
  if (argc != 1 ||
      !enif_is_list(env, argv[0])) {
    return enif_make_badarg(env);
  }

  unsigned int capacity;

  // enif_get_list_length fails for lists longer than UINT_MAX, which is below
  // MAX_COLUMN_CAPACITY.
  _Static_assert(UINT_MAX < MAX_COLUMN_CAPACITY, "from_list capacity is bounded");
  if (!enif_get_list_length(env, argv[0], &capacity)) {
    return enif_make_badarg(env);
  }

  ERL_NIF_TERM head, tail = argv[0];

  while (enif_get_list_cell(env, tail, &head, &tail)) {
    if (!validate_term(env, 0, head)) {
      return enif_make_badarg(env);
    }
  }

  struct stack * stack = alloc_stack(capacity);
  assert(stack != NULL);
  tail = argv[0];

  while (enif_get_list_cell(env, tail, &head, &tail)) {
    if (!append_term(env, stack, 0, head)) {
      free_stack(stack);
      return enif_make_badarg(env);
    }
  }

  if (!enif_is_empty_list(env, tail)) {
    free_stack(stack);
    return enif_make_badarg(env);
  }

  assert_valid_stack(stack);
  return pack_and_free_stack(env, stack);
}

// static ERL_NIF_TERM get_value_nif(ErlNifEnv * env, int argc, const ERL_NIF_TERM argv[]) {
//   struct column column;
//   int offset;

//   if (argc != 2 ||
//       !get_stack_from_resource_or_binary(env, argv[0], &stack) ||
//       !enif_get_int(env, argv[1], &offset) ||
//       offset < 0) {
//     return enif_make_badarg(env);
//   }

//   if (offset >= column.header->count) {
//     return nil_atom;
//   }

//   int word = offset / 64;
//   int bit = offset % 64;

//   if (column.null_bitmap[word] & (1ULL << bit)) {
//     return nil_atom;
//   }
//   else if (column.false_bitmap[word] & (1ULL << bit)) {
//     return false_atom;
//   }
//   else if (column.true_bitmap[word] & (1ULL << bit)) {
//     return true_atom;
//   }
//   else if (column.int_bitmap[word] & (1ULL << bit)) {
//     for (int w = 0; w < word; w++) {
//       column.int_values += __builtin_popcountll(column.int_bitmap[w]);
//     }
//     column.int_values += (column.int_bitmap[word] & (-1ULL << bit));
//     return enif_make_int(env, *column.int_values);
//   }
//   else if (column.float_bitmap[word] & (1ULL << bit)) {
//     for (int w = 0; w < word; w++) {
//       column.float_values += __builtin_popcountll(column.float_bitmap[w]);
//     }
//     column.float_values += (column.float_bitmap[word] & (-1ULL << bit));
//     return enif_make_double(env, *column.float_values);
//   }
//   else if (column.string_bitmap[word] & (1ULL << bit)) {
//     for (int w = 0; w < word; w++) {
//       if (column.string_bitmap[w]) {
//         for (int b = 0; b < 64; b++) {
//           if (column.string_bitmap[w] & (1ULL << b)) {
//             column.string_values += *(column.string_sizes++);
//           }
//         }
//       }
//     }

//     for (int b = 0; b < bit; b++) {
//       if (column.string_bitmap[word] & (1ULL << b)) {
//         column.string_values += *(column.string_sizes++);
//       }
//     }

//     ERL_NIF_TERM result;
//     unsigned char * string_data = enif_make_new_binary(env, *column.string_sizes, &result);
//     memcpy(string_data, column.string_values, *column.string_sizes);
//     return result;
//   }
//   else {
//     return enif_make_badarg(env);
//   }
// }

void column_to_terms_array(ErlNifEnv * env, struct column column, ERL_NIF_TERM * next_layer_terms, ERL_NIF_TERM * terms) {
  const uint64_t count = column.header->count;
  uint64_t word_count = bitmap_words(count);

  if (column.header->null_count > 0) {
    for (uint64_t word = 0; word < word_count; word++) {
      if (column.null_bitmap[word]) {
        for (int bit = 0; bit < 64; bit++) {
          if (column.null_bitmap[word] & (1ULL << bit)) {
            assert(word * 64 + bit < count);
            terms[word * 64 + bit] = nil_atom;
          }
        }
      }
    }
  }

  if (column.header->false_count > 0) {
    for (uint64_t word = 0; word < word_count; word++) {
      if (column.false_bitmap[word]) {
        for (int bit = 0; bit < 64; bit++) {
          if (column.false_bitmap[word] & (1ULL << bit)) {
            assert(word * 64 + bit < count);
            terms[word * 64 + bit] = false_atom;
          }
        }
      }
    }
  }

  if (column.header->true_count > 0) {
    for (uint64_t word = 0; word < word_count; word++) {
      if (column.true_bitmap[word]) {
        for (int bit = 0; bit < 64; bit++) {
          if (column.true_bitmap[word] & (1ULL << bit)) {
            assert(word * 64 + bit < count);
            terms[word * 64 + bit] = true_atom;
          }
        }
      }
    }
  }

  if (column.header->int_count > 0) {
    for (uint64_t word = 0; word < word_count; word++) {
      if (column.int_bitmap[word]) {
        for (int bit = 0; bit < 64; bit++) {
          if (column.int_bitmap[word] & (1ULL << bit)) {
            assert(word * 64 + bit < count);
            terms[word * 64 + bit] = enif_make_int64(env, *column.int_values);
            column.int_values++;
          }
        }
      }
    }
  }

  if (column.header->float_count > 0) {
    for (uint64_t word = 0; word < word_count; word++) {
      if (column.float_bitmap[word]) {
        for (int bit = 0; bit < 64; bit++) {
          if (column.float_bitmap[word] & (1ULL << bit)) {
            assert(word * 64 + bit < count);
            terms[word * 64 + bit] = enif_make_double(env, *column.float_values);
            column.float_values++;
          }
        }
      }
    }
  }

  if (column.header->string_count > 0) {
    for (uint64_t word = 0; word < word_count; word++) {
      if (column.string_bitmap[word]) {
        for (int bit = 0; bit < 64; bit++) {
          if (column.string_bitmap[word] & (1ULL << bit)) {
            size_t string_size = (size_t) *column.string_sizes;
            assert(word * 64 + bit < count);
            unsigned char * string_data = enif_make_new_binary(env, string_size, &terms[word * 64 + bit]);
            memcpy(string_data, column.string_values, string_size);
            column.string_sizes++;
            column.string_values += string_size;
          }
        }
      }
    }
  }

  if (column.header->list_count > 0) {
    for (uint64_t word = 0; word < word_count; word++) {
      if (column.list_bitmap[word]) {
        for (int bit = 0; bit < 64; bit++) {
          if (column.list_bitmap[word] & (1ULL << bit)) {
            unsigned list_length = (unsigned) *column.list_lengths++;
            terms[word * 64 + bit] = enif_make_list_from_array(env, next_layer_terms, list_length);
            next_layer_terms += list_length;
          }
        }
      }
    }
  }
}

static ERL_NIF_TERM to_list_nif(ErlNifEnv * env, int argc, const ERL_NIF_TERM argv[]) {
  struct stack stack;

  if (argc != 1 ||
      !get_stack_from_resource_or_binary(env, argv[0], &stack)) {
    return enif_make_badarg(env);
  }

  // enif_make_list_from_array takes an unsigned length. Nested lists are shorter:
  // each holds at most MAX_VALUE_LENGTH elements.
  if (stack.columns[0].header->count > UINT_MAX) {
    return enif_make_badarg(env);
  }

  uint64_t count = 0;
  ERL_NIF_TERM * next_layer_terms = NULL;
  ERL_NIF_TERM * terms = NULL;

  for (int layer_index = stack.num_columns - 1; layer_index >= 0; layer_index--) {
    struct column column = stack.columns[layer_index];
    count = column.header->count;
    next_layer_terms = terms;
    terms = xmalloc(checked_mul(sizeof(ERL_NIF_TERM), count));
    column_to_terms_array(env, column, next_layer_terms, terms);
    if (next_layer_terms) {
      free(next_layer_terms);
    }
  }

  ERL_NIF_TERM result = enif_make_list_from_array(env, terms, (unsigned) count);
  free(terms);
  return result;
}

static ERL_NIF_TERM count_nif(ErlNifEnv * env, int argc, const ERL_NIF_TERM argv[]) {
  struct stack stack;

  if (argc != 1 ||
      !get_stack_from_resource_or_binary(env, argv[0], &stack)) {
    return enif_make_badarg(env);
  }

  struct column column = stack.columns[0];

  return enif_make_uint64(env, column.header->count);
}

static ERL_NIF_TERM null_count_nif(ErlNifEnv * env, int argc, const ERL_NIF_TERM argv[]) {
  struct stack stack;

  if (argc != 1 ||
      !get_stack_from_resource_or_binary(env, argv[0], &stack)) {
    return enif_make_badarg(env);
  }

  struct column column = stack.columns[0];

  return enif_make_uint64(env, column.header->null_count);
}

static ERL_NIF_TERM false_count_nif(ErlNifEnv * env, int argc, const ERL_NIF_TERM argv[]) {
  struct stack stack;

  if (argc != 1 ||
      !get_stack_from_resource_or_binary(env, argv[0], &stack)) {
    return enif_make_badarg(env);
  }

  struct column column = stack.columns[0];

  return enif_make_uint64(env, column.header->false_count);
}

static ERL_NIF_TERM true_count_nif(ErlNifEnv * env, int argc, const ERL_NIF_TERM argv[]) {
  struct stack stack;

  if (argc != 1 ||
      !get_stack_from_resource_or_binary(env, argv[0], &stack)) {
    return enif_make_badarg(env);
  }

  struct column column = stack.columns[0];

  return enif_make_uint64(env, column.header->true_count);
}

static ERL_NIF_TERM int_count_nif(ErlNifEnv * env, int argc, const ERL_NIF_TERM argv[]) {
  struct stack stack;

  if (argc != 1 ||
      !get_stack_from_resource_or_binary(env, argv[0], &stack)) {
    return enif_make_badarg(env);
  }

  struct column column = stack.columns[0];

  return enif_make_uint64(env, column.header->int_count);
}

static ERL_NIF_TERM float_count_nif(ErlNifEnv * env, int argc, const ERL_NIF_TERM argv[]) {
  struct stack stack;

  if (argc != 1 ||
      !get_stack_from_resource_or_binary(env, argv[0], &stack)) {
    return enif_make_badarg(env);
  }

  struct column column = stack.columns[0];

  return enif_make_uint64(env, column.header->float_count);
}

static ERL_NIF_TERM string_count_nif(ErlNifEnv * env, int argc, const ERL_NIF_TERM argv[]) {
  struct stack stack;

  if (argc != 1 ||
      !get_stack_from_resource_or_binary(env, argv[0], &stack)) {
    return enif_make_badarg(env);
  }

  struct column column = stack.columns[0];

  return enif_make_uint64(env, column.header->string_count);
}

static ERL_NIF_TERM metadata_nif(ErlNifEnv * env, int argc, const ERL_NIF_TERM argv[]) {
  struct stack stack;

  if (argc != 1 ||
      !get_stack_from_resource_or_binary(env, argv[0], &stack)) {
    return enif_make_badarg(env);
  }

  ERL_NIF_TERM result = enif_make_list(env, 0);

  for (int i = stack.num_columns - 1; i >= 0; i--) {
    struct column column = stack.columns[i];

    ERL_NIF_TERM layer_metadata = enif_make_tuple8(env,
      enif_make_uint64(env, column.header->count),
      enif_make_uint64(env, column.header->null_count),
      enif_make_uint64(env, column.header->false_count),
      enif_make_uint64(env, column.header->true_count),
      enif_make_uint64(env, column.header->int_count),
      enif_make_uint64(env, column.header->float_count),
      enif_make_uint64(env, column.header->string_count),
      enif_make_uint64(env, column.header->list_count)
    );

    result = enif_make_list_cell(env, layer_metadata, result);
  }

  return result;
}

void move_value(struct stack * stack3, struct stack * stack1, int layer_index, uint64_t offsets[]) {
  assert(layer_index >= 0);
  assert(layer_index < MAX_COLUMNS_PER_STACK);

  struct column * column1 = &stack1->columns[layer_index];
  struct column * column3 = &stack3->columns[layer_index];
  uint64_t offset = offsets[layer_index]++;
  uint64_t word = offset / 64;
  uint64_t bit = offset % 64;

  if (column1->null_bitmap[word] & (1ULL << bit)) {
    append_null(column3);
  }
  else if (column1->false_bitmap[word] & (1ULL << bit)) {
    append_false(column3);
  }
  else if (column1->true_bitmap[word] & (1ULL << bit)) {
    append_true(column3);
  }
  else if (column1->int_bitmap[word] & (1ULL << bit)) {
    append_int(column3, *column1->int_values);
    column1->int_values++;
  }
  else if (column1->float_bitmap[word] & (1ULL << bit)) {
    append_float(column3, *column1->float_values);
    column1->float_values++;
  }
  else if (column1->string_bitmap[word] & (1ULL << bit)) {
    size_t string_size = (size_t) *column1->string_sizes++;
    append_string(column3, string_size, (unsigned char *) column1->string_values);
    column1->string_values += string_size;
  }
  else if (column1->list_bitmap[word] & (1ULL << bit)) {
    uint64_t list_length = (uint64_t) *column1->list_lengths++;
    append_list_length(column3, list_length);
    for (uint64_t i = 0; i < list_length; i++) {
      move_value(stack3, stack1, layer_index + 1, offsets);
    }
  }
  else {
    assert(0);
  }
}

void pop_value(struct stack * stack1, int layer_index, uint64_t offsets[]) {
  assert(layer_index >= 0);
  assert(layer_index < MAX_COLUMNS_PER_STACK);

  struct column * column1 = &stack1->columns[layer_index];
  uint64_t offset = offsets[layer_index]++;
  uint64_t word = offset / 64;
  uint64_t bit = offset % 64;

  if (column1->null_bitmap[word] & (1ULL << bit)) {
    // Pass.
  }
  else if (column1->false_bitmap[word] & (1ULL << bit)) {
    // Pass.
  }
  else if (column1->true_bitmap[word] & (1ULL << bit)) {
    // Pass.
  }
  else if (column1->int_bitmap[word] & (1ULL << bit)) {
    column1->int_values++;
  }
  else if (column1->float_bitmap[word] & (1ULL << bit)) {
    column1->float_values++;
  }
  else if (column1->string_bitmap[word] & (1ULL << bit)) {
    column1->string_values += (size_t) *column1->string_sizes++;
  }
  else if (column1->list_bitmap[word] & (1ULL << bit)) {
    uint64_t list_length = (uint64_t) *column1->list_lengths++;
    for (uint64_t i = 0; i < list_length; i++) {
      pop_value(stack1, layer_index + 1, offsets);
    }
  }
  else {
    assert(0);
  }
}

static ERL_NIF_TERM filter_nif(ErlNifEnv * env, int argc, const ERL_NIF_TERM argv[]) {
  struct stack stack1;
  struct stack stack2;

  if (argc != 2 ||
      !get_stack_from_resource_or_binary(env, argv[0], &stack1) ||
      !get_stack_from_resource_or_binary(env, argv[1], &stack2)) {
    return enif_make_badarg(env);
  }

  struct column column1 = stack1.columns[0];
  struct column column2 = stack2.columns[0];

  if (column1.header->count != column2.header->count) {
    return enif_make_badarg(env);
  }

  const uint64_t count = column1.header->count;
  const uint64_t word_count = bitmap_words(count);
  struct stack * stack3 = alloc_stack(count);
  if (stack3 == NULL) {
    return enif_make_badarg(env);
  }
  struct column * column3 = &stack3->columns[0];

  // Kept list values are copied into the nested layers, so the result needs the same
  // layers as the input. Layers that end up unused are trimmed below.
  while (stack3->num_columns < stack1.num_columns) {
    add_column(stack3);
  }

  uint64_t offsets[MAX_COLUMNS_PER_STACK] = {0};

  for (uint64_t offset = 0; offset < count; offset++) {
    uint64_t word = offset / 64;
    uint64_t bit = offset % 64;

    uint64_t keep = column2.true_bitmap[word] & (1ULL << bit);

    if (keep) {
      move_value(stack3, &stack1, 0, offsets);
    } else {
      pop_value(&stack1, 0, offsets);
    }
  }

  trim_unused_layers(stack3);
  assert_valid_stack(stack3);
  assert(column3->header->count == column2.header->true_count);
  return pack_and_free_stack(env, stack3);
}

static ERL_NIF_TERM add_nif(ErlNifEnv * env, int argc, const ERL_NIF_TERM argv[]) {
  struct stack stack1;
  struct stack stack2;

  if (argc != 2 ||
      !get_stack_from_resource_or_binary(env, argv[0], &stack1) ||
      !get_stack_from_resource_or_binary(env, argv[1], &stack2)) {
    return enif_make_badarg(env);
  }

  struct column column1 = stack1.columns[0];
  struct column column2 = stack2.columns[0];

  if (column1.header->count != column2.header->count) {
    return enif_make_badarg(env);
  }

  const uint64_t count = column1.header->count;
  const uint64_t word_count = bitmap_words(count);
  struct stack * stack3 = alloc_stack(count);
  if (stack3 == NULL) {
    return enif_make_badarg(env);
  }
  struct column * column3 = &stack3->columns[0];

  for (uint64_t offset = 0; offset < count; offset++) {
    uint64_t word = offset / 64;
    uint64_t bit = offset % 64;
    if (column1.int_bitmap[word] & (1ULL << bit)) {
      if (column2.int_bitmap[word] & (1ULL << bit)) {
        append_int(column3, *(column1.int_values++) + *(column2.int_values++));
      }
      else if (column2.float_bitmap[word] & (1ULL << bit)) {
        append_arithmetic_float(column3, *(column1.int_values++) + *(column2.float_values++));
      }
      else {
        append_null(column3);
        column1.int_values++;
      }
    }
    else if (column1.float_bitmap[word] & (1ULL << bit)) {
      if (column2.int_bitmap[word] & (1ULL << bit)) {
        append_arithmetic_float(column3, *(column1.float_values++) + *(column2.int_values++));
      }
      else if (column2.float_bitmap[word] & (1ULL << bit)) {
        append_arithmetic_float(column3, *(column1.float_values++) + *(column2.float_values++));
      }
      else {
        append_null(column3);
        column1.float_values++;
      }
    }
    else {
      // The left side isn't a number: skip the right side's value too, or every
      // later row would pair with the wrong right-hand value.
      append_null(column3);
      if (column2.int_bitmap[word] & (1ULL << bit)) {
        column2.int_values++;
      }
      else if (column2.float_bitmap[word] & (1ULL << bit)) {
        column2.float_values++;
      }
    }
  }

  assert_valid_stack(stack3);
  return pack_and_free_stack(env, stack3);
}

static ERL_NIF_TERM subtract_nif(ErlNifEnv * env, int argc, const ERL_NIF_TERM argv[]) {
  struct stack stack1;
  struct stack stack2;

  if (argc != 2 ||
      !get_stack_from_resource_or_binary(env, argv[0], &stack1) ||
      !get_stack_from_resource_or_binary(env, argv[1], &stack2)) {
    return enif_make_badarg(env);
  }

  struct column column1 = stack1.columns[0];
  struct column column2 = stack2.columns[0];

  if (column1.header->count != column2.header->count) {
    return enif_make_badarg(env);
  }

  const uint64_t count = column1.header->count;
  const uint64_t word_count = bitmap_words(count);
  struct stack * stack3 = alloc_stack(count);
  if (stack3 == NULL) {
    return enif_make_badarg(env);
  }
  struct column * column3 = &stack3->columns[0];

  for (uint64_t offset = 0; offset < count; offset++) {
    uint64_t word = offset / 64;
    uint64_t bit = offset % 64;
    if (column1.int_bitmap[word] & (1ULL << bit)) {
      if (column2.int_bitmap[word] & (1ULL << bit)) {
        append_int(column3, *(column1.int_values++) - *(column2.int_values++));
      }
      else if (column2.float_bitmap[word] & (1ULL << bit)) {
        append_arithmetic_float(column3, *(column1.int_values++) - *(column2.float_values++));
      }
      else {
        append_null(column3);
        column1.int_values++;
      }
    }
    else if (column1.float_bitmap[word] & (1ULL << bit)) {
      if (column2.int_bitmap[word] & (1ULL << bit)) {
        append_arithmetic_float(column3, *(column1.float_values++) - *(column2.int_values++));
      }
      else if (column2.float_bitmap[word] & (1ULL << bit)) {
        append_arithmetic_float(column3, *(column1.float_values++) - *(column2.float_values++));
      }
      else {
        append_null(column3);
        column1.float_values++;
      }
    }
    else {
      // The left side isn't a number: skip the right side's value too, or every
      // later row would pair with the wrong right-hand value.
      append_null(column3);
      if (column2.int_bitmap[word] & (1ULL << bit)) {
        column2.int_values++;
      }
      else if (column2.float_bitmap[word] & (1ULL << bit)) {
        column2.float_values++;
      }
    }
  }

  assert_valid_stack(stack3);
  return pack_and_free_stack(env, stack3);
}

static ERL_NIF_TERM multiply_nif(ErlNifEnv * env, int argc, const ERL_NIF_TERM argv[]) {
  struct stack stack1;
  struct stack stack2;

  if (argc != 2 ||
      !get_stack_from_resource_or_binary(env, argv[0], &stack1) ||
      !get_stack_from_resource_or_binary(env, argv[1], &stack2)) {
    return enif_make_badarg(env);
  }

  struct column column1 = stack1.columns[0];
  struct column column2 = stack2.columns[0];

  if (column1.header->count != column2.header->count) {
    return enif_make_badarg(env);
  }

  const uint64_t count = column1.header->count;
  const uint64_t word_count = bitmap_words(count);
  struct stack * stack3 = alloc_stack(count);
  if (stack3 == NULL) {
    return enif_make_badarg(env);
  }
  struct column * column3 = &stack3->columns[0];

  for (uint64_t offset = 0; offset < count; offset++) {
    uint64_t word = offset / 64;
    uint64_t bit = offset % 64;
    if (column1.int_bitmap[word] & (1ULL << bit)) {
      if (column2.int_bitmap[word] & (1ULL << bit)) {
        append_int(column3, *(column1.int_values++) * *(column2.int_values++));
      }
      else if (column2.float_bitmap[word] & (1ULL << bit)) {
        append_arithmetic_float(column3, *(column1.int_values++) * *(column2.float_values++));
      }
      else {
        append_null(column3);
        column1.int_values++;
      }
    }
    else if (column1.float_bitmap[word] & (1ULL << bit)) {
      if (column2.int_bitmap[word] & (1ULL << bit)) {
        append_arithmetic_float(column3, *(column1.float_values++) * *(column2.int_values++));
      }
      else if (column2.float_bitmap[word] & (1ULL << bit)) {
        append_arithmetic_float(column3, *(column1.float_values++) * *(column2.float_values++));
      }
      else {
        append_null(column3);
        column1.float_values++;
      }
    }
    else {
      // The left side isn't a number: skip the right side's value too, or every
      // later row would pair with the wrong right-hand value.
      append_null(column3);
      if (column2.int_bitmap[word] & (1ULL << bit)) {
        column2.int_values++;
      }
      else if (column2.float_bitmap[word] & (1ULL << bit)) {
        column2.float_values++;
      }
    }
  }

  assert_valid_stack(stack3);
  return pack_and_free_stack(env, stack3);
}

static ERL_NIF_TERM divide_nif(ErlNifEnv * env, int argc, const ERL_NIF_TERM argv[]) {
  struct stack stack1;
  struct stack stack2;

  if (argc != 2 ||
      !get_stack_from_resource_or_binary(env, argv[0], &stack1) ||
      !get_stack_from_resource_or_binary(env, argv[1], &stack2)) {
    return enif_make_badarg(env);
  }

  struct column column1 = stack1.columns[0];
  struct column column2 = stack2.columns[0];

  if (column1.header->count != column2.header->count) {
    return enif_make_badarg(env);
  }

  const uint64_t count = column1.header->count;
  const uint64_t word_count = bitmap_words(count);
  struct stack * stack3 = alloc_stack(count);
  if (stack3 == NULL) {
    return enif_make_badarg(env);
  }
  struct column * column3 = &stack3->columns[0];

  for (uint64_t offset = 0; offset < count; offset++) {
    uint64_t word = offset / 64;
    uint64_t bit = offset % 64;
    if (column1.int_bitmap[word] & (1ULL << bit)) {
      if (column2.int_bitmap[word] & (1ULL << bit)) {
        append_arithmetic_float(column3, (double) *(column1.int_values++) / *(column2.int_values++));
      }
      else if (column2.float_bitmap[word] & (1ULL << bit)) {
        append_arithmetic_float(column3, *(column1.int_values++) / *(column2.float_values++));
      }
      else {
        append_null(column3);
        column1.int_values++;
      }
    }
    else if (column1.float_bitmap[word] & (1ULL << bit)) {
      if (column2.int_bitmap[word] & (1ULL << bit)) {
        append_arithmetic_float(column3, *(column1.float_values++) / *(column2.int_values++));
      }
      else if (column2.float_bitmap[word] & (1ULL << bit)) {
        append_arithmetic_float(column3, *(column1.float_values++) / *(column2.float_values++));
      }
      else {
        append_null(column3);
        column1.float_values++;
      }
    }
    else {
      // The left side isn't a number: skip the right side's value too, or every
      // later row would pair with the wrong right-hand value.
      append_null(column3);
      if (column2.int_bitmap[word] & (1ULL << bit)) {
        column2.int_values++;
      }
      else if (column2.float_bitmap[word] & (1ULL << bit)) {
        column2.float_values++;
      }
    }
  }

  assert_valid_stack(stack3);
  return pack_and_free_stack(env, stack3);
}

uint64_t trim_bitmap(uint64_t * bitmap, uint64_t count) {
  const uint64_t bit = count % 64;
  if (bit == 0) {
    return 0;
  }
  const uint64_t word_count = bitmap_words(count);
  const uint64_t word = word_count - 1;
  uint64_t mask = ~(-1ULL << bit);
  uint64_t popcount = 0;
  popcount += __builtin_popcountll(bitmap[word]);
  bitmap[word] &= mask;
  popcount -= __builtin_popcountll(bitmap[word]);
  return popcount;
}

static ERL_NIF_TERM and_nif(ErlNifEnv * env, int argc, const ERL_NIF_TERM argv[]) {
  struct stack stack1;
  struct stack stack2;

  if (argc != 2 ||
      !get_stack_from_resource_or_binary(env, argv[0], &stack1) ||
      !get_stack_from_resource_or_binary(env, argv[1], &stack2)) {
    return enif_make_badarg(env);
  }

  struct column column1 = stack1.columns[0];
  struct column column2 = stack2.columns[0];

  if (column1.header->count != column2.header->count) {
    return enif_make_badarg(env);
  }

  const uint64_t count = column1.header->count;
  const uint64_t word_count = bitmap_words(count);
  struct stack * stack3 = alloc_stack(count);
  if (stack3 == NULL) {
    return enif_make_badarg(env);
  }
  struct column * column3 = &stack3->columns[0];
  column3->header->count = count;

  for (uint64_t word = 0; word < word_count; word++) {
    column3->true_bitmap[word] = column1.true_bitmap[word] & column2.true_bitmap[word];
    column3->false_bitmap[word] = column1.false_bitmap[word] | column2.false_bitmap[word];
    column3->null_bitmap[word] = ~column3->true_bitmap[word] & ~column3->false_bitmap[word];
    column3->header->true_count += __builtin_popcountll(column3->true_bitmap[word]);
    column3->header->false_count += __builtin_popcountll(column3->false_bitmap[word]);
    column3->header->null_count += __builtin_popcountll(column3->null_bitmap[word]);
  }

  column3->header->null_count -= trim_bitmap(column3->null_bitmap, count);
  assert_valid_stack(stack3);
  return pack_and_free_stack(env, stack3);
}

static ERL_NIF_TERM or_nif(ErlNifEnv * env, int argc, const ERL_NIF_TERM argv[]) {
  struct stack stack1;
  struct stack stack2;

  if (argc != 2 ||
      !get_stack_from_resource_or_binary(env, argv[0], &stack1) ||
      !get_stack_from_resource_or_binary(env, argv[1], &stack2)) {
    return enif_make_badarg(env);
  }

  struct column column1 = stack1.columns[0];
  struct column column2 = stack2.columns[0];

  if (column1.header->count != column2.header->count) {
    return enif_make_badarg(env);
  }

  const uint64_t count = column1.header->count;
  const uint64_t word_count = bitmap_words(count);
  struct stack * stack3 = alloc_stack(count);
  if (stack3 == NULL) {
    return enif_make_badarg(env);
  }
  struct column * column3 = &stack3->columns[0];
  column3->header->count = count;

  for (uint64_t word = 0; word < word_count; word++) {
    column3->true_bitmap[word] = column1.true_bitmap[word] | column2.true_bitmap[word];
    column3->false_bitmap[word] = column1.false_bitmap[word] & column2.false_bitmap[word];
    column3->null_bitmap[word] = ~column3->true_bitmap[word] & ~column3->false_bitmap[word];
    column3->header->true_count += __builtin_popcountll(column3->true_bitmap[word]);
    column3->header->false_count += __builtin_popcountll(column3->false_bitmap[word]);
    column3->header->null_count += __builtin_popcountll(column3->null_bitmap[word]);
  }

  column3->header->null_count -= trim_bitmap(column3->null_bitmap, count);
  assert_valid_stack(stack3);
  return pack_and_free_stack(env, stack3);
}

static ERL_NIF_TERM not_nif(ErlNifEnv * env, int argc, const ERL_NIF_TERM argv[]) {
  struct stack stack1;

  if (argc != 1 ||
      !get_stack_from_resource_or_binary(env, argv[0], &stack1)) {
    return enif_make_badarg(env);
  }

  struct column column1 = stack1.columns[0];

  const uint64_t count = column1.header->count;
  const uint64_t word_count = bitmap_words(count);
  struct stack * stack3 = alloc_stack(count);
  if (stack3 == NULL) {
    return enif_make_badarg(env);
  }
  struct column * column3 = &stack3->columns[0];
  column3->header->count = count;

  for (uint64_t word = 0; word < word_count; word++) {
    column3->true_bitmap[word] = column1.false_bitmap[word];
    column3->false_bitmap[word] = column1.true_bitmap[word];
    column3->null_bitmap[word] = ~column3->true_bitmap[word] & ~column3->false_bitmap[word];
    column3->header->true_count += __builtin_popcountll(column3->true_bitmap[word]);
    column3->header->false_count += __builtin_popcountll(column3->false_bitmap[word]);
    column3->header->null_count += __builtin_popcountll(column3->null_bitmap[word]);
  }

  column3->header->null_count -= trim_bitmap(column3->null_bitmap, count);
  assert_valid_stack(stack3);
  return pack_and_free_stack(env, stack3);
}

// Compares an int64 with a double exactly: -1, 0 or 1 as i is less than, equal to or
// greater than d. Converting i to double would round above 2^53. d must not be NaN
// (BEAM floats are never NaN or infinite).
static int compare_int64_double(int64_t i, double d) {
  if (d >= 9223372036854775808.0) {
    return -1;
  }
  if (d < -9223372036854775808.0) {
    return 1;
  }
  // d is in int64 range, so truncating it is exact, and so is converting the result
  // back to double.
  int64_t t = (int64_t) d;
  if (i != t) {
    return i < t ? -1 : 1;
  }
  double fraction = d - (double) t;
  if (fraction > 0.0) {
    return -1;
  }
  if (fraction < 0.0) {
    return 1;
  }
  return 0;
}

static ERL_NIF_TERM min_max_number_nif(ErlNifEnv * env, int argc, const ERL_NIF_TERM argv[]) {
  struct stack stack1;

  if (argc != 1 ||
      !get_stack_from_resource_or_binary(env, argv[0], &stack1)) {
    return enif_make_badarg(env);
  }

  struct column column1 = stack1.columns[0];

  const uint64_t count = column1.header->count;
  const uint64_t word_count = bitmap_words(count);

  int64_t min_int = 0;
  int64_t max_int = 0;
  double min_float = 0.0;
  double max_float = 0.0;
  int found_int = 0;
  int found_float = 0;

  if (column1.header->int_count > 0) {
    for (uint64_t word = 0; word < word_count; word++) {
      if (column1.int_bitmap[word]) {
        for (int bit = 0; bit < 64; bit++) {
          if (column1.int_bitmap[word] & (1ULL << bit)) {
            int64_t int_value = *column1.int_values++;
            if (!found_int) {
              found_int = 1;
              min_int = int_value;
              max_int = int_value;
            } else if (min_int > int_value) {
              min_int = int_value;
            } else if (max_int < int_value) {
              max_int = int_value;
            }
          }
        }
      }
    }
  }

  if (column1.header->float_count > 0) {
    for (uint64_t word = 0; word < word_count; word++) {
      if (column1.float_bitmap[word]) {
        for (int bit = 0; bit < 64; bit++) {
          if (column1.float_bitmap[word] & (1ULL << bit)) {
            double float_value = *column1.float_values++;
            if (!found_float) {
              found_float = 1;
              min_float = float_value;
              max_float = float_value;
            } else if (min_float > float_value) {
              min_float = float_value;
            } else if (max_float < float_value) {
              max_float = float_value;
            }
          }
        }
      }
    }
  }

  ERL_NIF_TERM min_term;
  ERL_NIF_TERM max_term;

  if (found_int && found_float) {
    // On a tie, the int is returned.
    if (compare_int64_double(min_int, min_float) <= 0) {
      min_term = enif_make_int64(env, min_int);
    } else {
      min_term = enif_make_double(env, min_float);
    }
    if (compare_int64_double(max_int, max_float) >= 0) {
      max_term = enif_make_int64(env, max_int);
    } else {
      max_term = enif_make_double(env, max_float);
    }
  } else if (found_int) {
    min_term = enif_make_int64(env, min_int);
    max_term = enif_make_int64(env, max_int);
  } else if (found_float) {
    min_term = enif_make_double(env, min_float);
    max_term = enif_make_double(env, max_float);
  } else {
    min_term = nil_atom;
    max_term = nil_atom;
  }

  return enif_make_tuple2(env, min_term, max_term);
}

static ERL_NIF_TERM number_to_false_nif(ErlNifEnv * env, int argc, const ERL_NIF_TERM argv[]) {
  struct stack stack1;

  if (argc != 1 ||
      !get_stack_from_resource_or_binary(env, argv[0], &stack1)) {
    return enif_make_badarg(env);
  }

  struct column column1 = stack1.columns[0];

  const uint64_t count = column1.header->count;
  const uint64_t word_count = bitmap_words(count);
  struct stack * stack3 = alloc_stack(count);
  if (stack3 == NULL) {
    return enif_make_badarg(env);
  }
  struct column * column3 = &stack3->columns[0];
  column3->header->count = count;

  for (uint64_t word = 0; word < word_count; word++) {
    column3->false_bitmap[word] = column1.int_bitmap[word] | column1.float_bitmap[word];
    column3->null_bitmap[word] = ~column3->false_bitmap[word];
    column3->header->false_count += __builtin_popcountll(column3->false_bitmap[word]);
    column3->header->null_count += __builtin_popcountll(column3->null_bitmap[word]);
  }

  column3->header->null_count -= trim_bitmap(column3->null_bitmap, count);
  assert_valid_stack(stack3);
  return pack_and_free_stack(env, stack3);
}

static ERL_NIF_TERM number_to_true_nif(ErlNifEnv * env, int argc, const ERL_NIF_TERM argv[]) {
  struct stack stack1;

  if (argc != 1 ||
      !get_stack_from_resource_or_binary(env, argv[0], &stack1)) {
    return enif_make_badarg(env);
  }

  struct column column1 = stack1.columns[0];

  const uint64_t count = column1.header->count;
  const uint64_t word_count = bitmap_words(count);
  struct stack * stack3 = alloc_stack(count);
  if (stack3 == NULL) {
    return enif_make_badarg(env);
  }
  struct column * column3 = &stack3->columns[0];
  column3->header->count = count;

  for (uint64_t word = 0; word < word_count; word++) {
    column3->true_bitmap[word] = column1.int_bitmap[word] | column1.float_bitmap[word];
    column3->null_bitmap[word] = ~column3->true_bitmap[word];
    column3->header->true_count += __builtin_popcountll(column3->true_bitmap[word]);
    column3->header->null_count += __builtin_popcountll(column3->null_bitmap[word]);
  }

  column3->header->null_count -= trim_bitmap(column3->null_bitmap, count);
  assert_valid_stack(stack3);
  return pack_and_free_stack(env, stack3);
}

static ERL_NIF_TERM to_boolean_nif(ErlNifEnv * env, int argc, const ERL_NIF_TERM argv[]) {
  struct stack stack1;

  if (argc != 1 ||
      !get_stack_from_resource_or_binary(env, argv[0], &stack1)) {
    return enif_make_badarg(env);
  }

  struct column column1 = stack1.columns[0];

  if (column1.header->null_count + column1.header->false_count + column1.header->true_count == column1.header->count) {
    return argv[0];
  }

  const uint64_t count = column1.header->count;
  const uint64_t word_count = bitmap_words(count);
  struct stack * stack3 = alloc_stack(count);
  if (stack3 == NULL) {
    return enif_make_badarg(env);
  }
  struct column * column3 = &stack3->columns[0];
  column3->header->count = count;

  for (uint64_t word = 0; word < word_count; word++) {
    column3->true_bitmap[word] = column1.true_bitmap[word];
    column3->false_bitmap[word] = column1.false_bitmap[word];
    column3->null_bitmap[word] = ~column1.true_bitmap[word] & ~column1.false_bitmap[word];
  }

  column3->header->true_count = column1.header->true_count;
  column3->header->false_count = column1.header->false_count;
  column3->header->null_count = column1.header->count - column1.header->true_count - column1.header->false_count;
  trim_bitmap(column3->null_bitmap, count);
  assert_valid_stack(stack3);
  return pack_and_free_stack(env, stack3);
}

static ERL_NIF_TERM to_string_nif(ErlNifEnv * env, int argc, const ERL_NIF_TERM argv[]) {
  struct stack stack1;

  if (argc != 1 ||
      !get_stack_from_resource_or_binary(env, argv[0], &stack1)) {
    return enif_make_badarg(env);
  }

  struct column column1 = stack1.columns[0];

  if (column1.header->null_count + column1.header->string_count == column1.header->count) {
    return argv[0];
  }

  const uint64_t count = column1.header->count;
  const uint64_t word_count = bitmap_words(count);
  struct stack * stack3 = alloc_stack(count);
  if (stack3 == NULL) {
    return enif_make_badarg(env);
  }
  struct column * column3 = &stack3->columns[0];
  column3->header->count = count;

  for (uint64_t word = 0; word < word_count; word++) {
    column3->string_bitmap[word] = column1.string_bitmap[word];
    column3->null_bitmap[word] = ~column1.string_bitmap[word];
  }

  column3->header->string_count = column1.header->string_count;
  column3->header->null_count = column1.header->count - column1.header->string_count;
  column3->header->string_total_sizes = column1.header->string_total_sizes;
  trim_bitmap(column3->null_bitmap, count);
  column3->string_values = xrealloc(column3->string_values, column3->header->string_total_sizes);
  column3->string_capacity = column3->header->string_total_sizes;
  memcpy(column3->string_sizes, column1.string_sizes, checked_mul(column1.header->string_count, sizeof(int32_t)));
  memcpy(column3->string_values, column1.string_values, column1.header->string_total_sizes);
  assert_valid_stack(stack3);
  return pack_and_free_stack(env, stack3);
}

static ErlNifFunc nif_funcs[] = {
  {"max_string_size", 0, max_string_size_nif},
  {"max_list_length", 0, max_list_length_nif},
  {"max_list_depth", 0, max_list_depth_nif},
  {"new", 1, new_nif},
  {"pad", 2, pad_nif},
  {"append", 2, append_nif},
  {"valid_value", 1, valid_value_nif},
  {"pack", 1, pack_nif},
  {"packed_size", 1, packed_size_nif},
  {"allocated_size", 1, allocated_size_nif},
  {"live_columns", 0, live_columns_nif},
  {"from_list", 1, from_list_nif},
  {"to_list", 1, to_list_nif},
  {"count", 1, count_nif},
  {"null_count", 1, null_count_nif},
  {"false_count", 1, false_count_nif},
  {"true_count", 1, true_count_nif},
  {"int_count", 1, int_count_nif},
  {"float_count", 1, float_count_nif},
  {"string_count", 1, string_count_nif},
  {"metadata", 1, metadata_nif},
  {"filter", 2, filter_nif},
  {"add", 2, add_nif},
  {"subtract", 2, subtract_nif},
  {"multiply", 2, multiply_nif},
  {"divide", 2, divide_nif},
  {"and_oper", 2, and_nif},
  {"or_oper", 2, or_nif},
  {"not_oper", 1, not_nif},
  {"min_max_number", 1, min_max_number_nif},
  {"number_to_false", 1, number_to_false_nif},
  {"number_to_true", 1, number_to_true_nif},
  {"to_boolean", 1, to_boolean_nif},
  {"to_string", 1, to_string_nif},
};

int load(ErlNifEnv * env, void ** priv_data, ERL_NIF_TERM load_info) {
  init_atoms(env);

  if (!create_column_resource_type(env)) {
    return 1;
  }

  return 0;
}

int upgrade(ErlNifEnv * env, void ** priv_data, void ** old_priv_data, ERL_NIF_TERM load_info) {
  printf("Upgrading column.c\r\n"); fflush(stdout);
  return 0;
}

ERL_NIF_INIT(Elixir.Storage.Column.NIF, nif_funcs, load, NULL, upgrade, NULL)
