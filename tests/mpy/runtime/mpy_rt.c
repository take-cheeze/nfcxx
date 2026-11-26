/* The runtime that lowered MicroPython code calls (docs/notes/mpy-pathb.md, "Values").
 *
 * A value is one 64-bit word, with the tagging of MicroPython's MICROPY_OBJ_REPR_A (py/obj.h):
 *   xxxx...xxx1  a small int; the value is the word shifted right by one
 *   xxxx...x110  an immediate object: None, False, True (value 0, 1, 2 in bits 3 and up)
 * A pointer (low two bits clear, not zero) is a heap object. Its first member is a pointer to its type (MpyType), as
 * MicroPython's mp_obj_base_t has it. The heap types are str (MpyStr), function (MpyFunc), cell, list, tuple, iterator,
 * range (MpyRange), dict (MpyDict), slice (MpySlice) and builtin (MpyBuiltin: len, str, range, and the list methods append
 * and pop). A value of another kind is an error.
 *
 * Strings (docs/notes/mpy-pathb.md, "Strings"): a MpyStr is the type pointer, the byte length, and the bytes followed by a
 * NUL. The bytes are immutable. A literal is allocated once, the first time its site runs, and kept (no GC yet); a
 * concatenation allocates a new one and it is kept too.
 *
 * Dicts and slices (docs/notes/mpy-pathb.md, "Dicts" and "Slices"). A value 0 is never a value: it is the null that a
 * `del` stores (LOAD_NULL), so STORE_SUBSCR with it deletes.
 *
 * Integers wider than the small-int range would be big ints in MicroPython (MICROPY_LONGINT_IMPL). They are an error here
 * until the runtime has them, so a test program must stay in the small-int range. Names are looked up in one module
 * globals table, keyed by the name's bytes. */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef uint64_t mpv;

#define MPY_NONE ((mpv)0x06)
#define MPY_FALSE ((mpv)0x0e)
#define MPY_TRUE ((mpv)0x16)

/* MP_BINARY_OP_* and MP_UNARY_OP_* (py/runtime0.h), as the bytecode carries them. */
enum {
  MPY_OP_LESS = 0, MPY_OP_MORE = 1, MPY_OP_EQUAL = 2, MPY_OP_LESS_EQUAL = 3, MPY_OP_MORE_EQUAL = 4, MPY_OP_NOT_EQUAL = 5,
  MPY_OP_IN = 6, MPY_OP_IS = 7,
  MPY_OP_OR = 22, MPY_OP_XOR = 23, MPY_OP_AND = 24, MPY_OP_LSHIFT = 25, MPY_OP_RSHIFT = 26, MPY_OP_ADD = 27,
  MPY_OP_SUBTRACT = 28, MPY_OP_MULTIPLY = 29, MPY_OP_FLOOR_DIVIDE = 31, MPY_OP_MODULO = 33
};
enum { MPY_UOP_POSITIVE = 0, MPY_UOP_NEGATIVE = 1, MPY_UOP_INVERT = 2, MPY_UOP_NOT = 3 };

#define MPY_SMALL_MAX ((int64_t)((1ULL << 62) - 1))
#define MPY_SMALL_MIN ((int64_t)(-(1LL << 62)))

static void fail(const char *what) {
  fprintf(stderr, "mpy: %s\n", what);
  exit(1);
}

static int is_small(mpv v) { return (v & 1) != 0; }
static int64_t small_value(mpv v) { return ((int64_t)v) >> 1; }

static mpv make_small(int64_t n) {
  if (n > MPY_SMALL_MAX || n < MPY_SMALL_MIN) fail("integer out of the small-int range (big ints are not implemented)");
  return ((mpv)n << 1) | 1;
}

static int is_bool(mpv v) { return v == MPY_FALSE || v == MPY_TRUE; }

/* Heap objects. The type is the first member of every heap record. */
typedef struct MpyType {
  const char *name;
} MpyType;

static const MpyType mpy_type_str = {"str"};
static const MpyType mpy_type_function = {"function"};

typedef struct {
  const MpyType *type;
  size_t len;
  int interned;   /* a literal of the module (MicroPython's qstr); a str built at run time is not */
  char data[];    /* len bytes and a NUL */
} MpyStr;

static int is_heap(mpv v) { return v != 0 && (v & 3) == 0; }
static const MpyType *type_of(mpv v) { return *(const MpyType *const *)(uintptr_t)v; }
static int is_str(mpv v) { return is_heap(v) && type_of(v) == &mpy_type_str; }
static int is_qstr(mpv v) { return is_str(v) && ((const MpyStr *)(uintptr_t)v)->interned; }
static const MpyStr *str_of(mpv v) { return (const MpyStr *)(uintptr_t)v; }

/* Lists, tuples and iterators. A list owns its item array; a tuple holds its items in place; an iterator names its sequence
 * and the next index. */
static const MpyType mpy_type_list = {"list"};
static const MpyType mpy_type_tuple = {"tuple"};
static const MpyType mpy_type_iter = {"iterator"};
static const MpyType mpy_type_range = {"range"};
static const MpyType mpy_type_dict = {"dict"};
static const MpyType mpy_type_slice = {"slice"};
/* The builtin functions are called builtin_function_or_method; str and range are types, which are called too. */
static const MpyType mpy_type_bfn = {"builtin_function_or_method"};
static const MpyType mpy_type_type = {"type"};

typedef struct {
  const MpyType *type;
  size_t len, cap;
  mpv *items;
} MpyList;

typedef struct {
  const MpyType *type;
  size_t len;
  mpv items[]; /* C99 flexible array member */
} MpyTuple;

typedef struct {
  const MpyType *type;
  mpv seq;      /* the list, tuple or range being iterated */
  size_t index; /* the next item to give (for a range, the number of items given) */
} MpyIter;

/* A range: its start, stop and step, and the number of items it gives. */
typedef struct {
  const MpyType *type;
  int64_t start, stop, step;
  size_t len;
} MpyRange;

/* A dict (docs/notes/mpy-pathb.md, "Dicts") is MicroPython's mp_map_t (py/map.c), which the iteration order follows: a table of
 * alloc slots, with open addressing by linear probing from hash % alloc. A slot with key 0 is empty; a deleted slot holds the
 * sentinel key. The table grows by the sizes of py/map.c's hash_allocation_sizes when an insertion finds no free slot. */
typedef struct {
  mpv key, value;
} MpyEntry;

typedef struct {
  const MpyType *type;
  size_t alloc;            /* the table's slot count (map.c's alloc) */
  size_t used;             /* the live items */
  int all_keys_are_qstrs;  /* 1 while every key is an interned str (map.c's all_keys_are_qstrs) */
  MpyEntry *table;
} MpyDict;

/* The key of a deleted slot. It is never a value (the immediates are None, False and True only). */
#define MPY_SENTINEL ((mpv)0x1e)

/* A slice: its start, stop and step, each an int or None. */
typedef struct {
  const MpyType *type;
  mpv start, stop, step;
} MpySlice;

/* The builtins: len, str and range (str and range are types, called as functions), and the list methods append and pop
 * that LOAD_METHOD gives. A builtin is a static record {type, id}; the id is the index in mpy_builtins. */
enum { BI_LEN, BI_STR, BI_RANGE, BI_APPEND, BI_POP };
typedef struct {
  const MpyType *type;
  int id;
} MpyBuiltin;
static const MpyBuiltin mpy_builtins[] = {
  {&mpy_type_bfn, BI_LEN}, {&mpy_type_type, BI_STR}, {&mpy_type_type, BI_RANGE},
  {&mpy_type_bfn, BI_APPEND}, {&mpy_type_bfn, BI_POP},
};

static int is_list(mpv v) { return is_heap(v) && type_of(v) == &mpy_type_list; }
static int is_tuple(mpv v) { return is_heap(v) && type_of(v) == &mpy_type_tuple; }
static int is_iter(mpv v) { return is_heap(v) && type_of(v) == &mpy_type_iter; }
static int is_range(mpv v) { return is_heap(v) && type_of(v) == &mpy_type_range; }
static int is_dict(mpv v) { return is_heap(v) && type_of(v) == &mpy_type_dict; }
static int is_slice(mpv v) { return is_heap(v) && type_of(v) == &mpy_type_slice; }
static int is_builtin(mpv v) { return is_heap(v) && (type_of(v) == &mpy_type_bfn || type_of(v) == &mpy_type_type); }
static const MpyRange *range_of(mpv v) { return (const MpyRange *)(uintptr_t)v; }
static const MpyDict *dict_of(mpv v) { return (const MpyDict *)(uintptr_t)v; }
static const MpySlice *slice_of(mpv v) { return (const MpySlice *)(uintptr_t)v; }
static mpv builtin_obj(int id) { return (mpv)(uintptr_t)&mpy_builtins[id]; }

/* The builtin with this name, or -1. The module's globals are searched first, so a program can shadow these. */
static int builtin_index(const char *name, size_t len) {
  if (len == 3 && memcmp(name, "len", 3) == 0) return BI_LEN;
  if (len == 3 && memcmp(name, "str", 3) == 0) return BI_STR;
  if (len == 5 && memcmp(name, "range", 5) == 0) return BI_RANGE;
  return -1;
}

/* The item count and items of a list or tuple; 0 when v is neither. */
static int seq_items(mpv v, size_t *len, const mpv **items) {
  if (is_list(v)) {
    *len = ((const MpyList *)(uintptr_t)v)->len;
    *items = ((const MpyList *)(uintptr_t)v)->items;
    return 1;
  }
  if (is_tuple(v)) {
    *len = ((const MpyTuple *)(uintptr_t)v)->len;
    *items = ((const MpyTuple *)(uintptr_t)v)->items;
    return 1;
  }
  return 0;
}

/* The name of a value's type, as MicroPython's error messages give it. Booleans are reported as 'int' in operator errors. */
static const char *type_name(mpv v) {
  if (is_small(v) || is_bool(v)) return "int";
  if (v == MPY_NONE) return "NoneType";
  if (is_heap(v)) return type_of(v)->name;
  return "object";
}

/* The name of a value's type as its own error messages give it (a bool is 'bool'). */
static const char *real_type_name(mpv v) {
  if (is_bool(v)) return "bool";
  return type_name(v);
}

/* A growing text buffer, for the reprs and the messages that carry a value. */
typedef struct {
  char *p;
  size_t n, cap;
} Buf;

static void buf_put(Buf *b, const char *s, size_t n) {
  if (b->n + n + 1 > b->cap) {
    size_t cap = b->cap ? b->cap : 64;
    char *p;
    while (cap < b->n + n + 1) cap *= 2;
    p = (char *)realloc(b->p, cap);
    if (p == NULL) fail("out of memory");
    b->p = p;
    b->cap = cap;
  }
  memcpy(b->p + b->n, s, n);
  b->n += n;
  b->p[b->n] = '\0';
}

static void buf_str(Buf *b, const char *s) { buf_put(b, s, strlen(s)); }

static void buf_int(Buf *b, long long v) {
  char t[32];
  int k = snprintf(t, sizeof t, "%lld", v);
  buf_put(b, t, (size_t)k);
}

static void repr_into(Buf *b, mpv v);

/* Truth, as mp_obj_is_true: None and False are false; zero is false; an empty str is false; anything else is true. */
int mpy_truth(mpv v) {
  if (v == MPY_NONE || v == MPY_FALSE) return 0;
  if (v == MPY_TRUE) return 1;
  if (is_small(v)) return small_value(v) != 0;
  if (is_str(v)) return str_of(v)->len != 0;
  if (is_iter(v)) return 1;
  if (is_range(v)) return range_of(v)->len != 0;
  if (is_dict(v)) return dict_of(v)->used != 0;
  {
    size_t n;
    const mpv *items;
    if (seq_items(v, &n, &items)) return n != 0;
  }
  fail("truth of a value that is not a small int, bool, None, str, list, tuple or dict is not implemented");
  return 0;
}

static int64_t need_int(mpv v) {
  if (is_small(v)) return small_value(v);
  if (is_bool(v)) return v == MPY_TRUE ? 1 : 0;
  fail("unsupported operand type");
  return 0;
}

static MpyStr *alloc_str(size_t n) {
  MpyStr *s = (MpyStr *)malloc(sizeof(MpyStr) + n + 1);
  if (s == NULL) fail("out of memory");
  s->type = &mpy_type_str;
  s->len = n;
  s->interned = 0;
  s->data[n] = '\0';
  return s;
}

static mpv new_str(const char *bytes, size_t n) {
  MpyStr *s = alloc_str(n);
  memcpy(s->data, bytes, n);
  return (mpv)(uintptr_t)s;
}

/* The characters of a str: its bytes that do not continue a UTF-8 sequence (the same count for valid UTF-8). */
static size_t str_chars(const MpyStr *s) {
  size_t i, n = 0;
  for (i = 0; i < s->len; ++i) {
    if ((s->data[i] & 0xc0) != 0x80) ++n;
  }
  return n;
}

/* The byte offset of character k of s (k may be the character count, which gives s->len). */
static size_t byte_offset(const MpyStr *s, size_t k) {
  size_t i = 0, c = 0;
  while (i < s->len) {
    if (c == k) return i;
    ++c;
    ++i;
    while (i < s->len && (((unsigned char)s->data[i]) & 0xc0) == 0x80) ++i;
  }
  return s->len;
}

/* A list's item array, grown as needed. A new list has room for at least one item (see list_new). */
static MpyList *list_new(size_t cap) {
  MpyList *l = (MpyList *)malloc(sizeof *l);
  if (l == NULL) fail("out of memory");
  l->type = &mpy_type_list;
  l->len = 0;
  l->cap = cap ? cap : 1;
  l->items = (mpv *)malloc(l->cap * sizeof(mpv));
  if (l->items == NULL) fail("out of memory");
  return l;
}

static void list_append(MpyList *l, mpv v) {
  if (l->len == l->cap) {   /* cap is at least 1 */
    size_t cap = l->cap * 2;
    mpv *items = (mpv *)realloc(l->items, cap * sizeof(mpv));
    if (items == NULL) fail("out of memory");
    l->items = items;
    l->cap = cap;
  }
  l->items[l->len++] = v;
}

/* Equality for `in`: the same word (one object, or one immediate or small int), two strs with the same bytes, two numbers
 * (bools as 0 and 1) with the same value. Two lists or tuples that are different objects are not compared yet, so that
 * fails rather than answers. */
static int str_equal(mpv a, mpv b) {
  const MpyStr *x = str_of(a), *y = str_of(b);
  return x->len == y->len && memcmp(x->data, y->data, x->len) == 0;
}

static int values_equal(mpv a, mpv b) {
  if (a == b) return 1;
  if (is_str(a) || is_str(b)) return is_str(a) && is_str(b) && str_equal(a, b);
  if ((is_small(a) || is_bool(a)) && (is_small(b) || is_bool(b))) return need_int(a) == need_int(b);
  if ((is_list(a) || is_tuple(a)) && (is_list(b) || is_tuple(b))) {
    fail("TypeError: equality of lists and tuples is not lowered yet");
  }
  return 0;
}

/* Keys: the same word, two strs with the same bytes, or two numbers (bools as 0 and 1) with the same value. */
static int key_equal(mpv a, mpv b) {
  if (a == b) return 1;
  if (is_str(a) && is_str(b)) return str_equal(a, b);
  if ((is_small(a) || is_bool(a)) && (is_small(b) || is_bool(b))) return need_int(a) == need_int(b);
  return 0;
}

/* The hash of a key, as MicroPython's mp_map_lookup computes it: a small int or a bool is its value (a negative value
 * wraps, as mp_uint_t does), None is its word (6), and a str is qstr_compute_hash with the hash masked to 16 bits
 * (MICROPY_QSTR_BYTES_IN_HASH is 1 at the unix port's default ROM level). A list, dict or slice is unhashable. Any other
 * kind of key is not lowered yet. */
static size_t key_hash(mpv k) {
  char msg[120];
  if (is_small(k)) return (size_t)small_value(k);
  if (is_bool(k)) return k == MPY_TRUE ? 1 : 0;
  if (k == MPY_NONE) return 6;
  if (is_str(k)) {
    const MpyStr *s = str_of(k);
    size_t h = 5381, i;   /* djb2, as qstr_compute_hash */
    for (i = 0; i < s->len; ++i) h = ((h << 5) + h) ^ (unsigned char)s->data[i];
    h &= 0xffff;   /* MICROPY_QSTR_BYTES_IN_HASH is 2 in the reference build */
    return h == 0 ? 1 : h;
  }
  if (is_list(k) || is_dict(k) || is_slice(k)) {
    snprintf(msg, sizeof msg, "TypeError: unsupported type for __hash__: '%s'", type_of(k)->name);
    fail(msg);
  }
  fail("TypeError: a key of this type is not lowered yet");
  return 0;
}

/* py/map.c's hash_allocation_sizes: the table sizes a growing map takes. */
static const size_t hash_allocation_sizes[] = {
  0, 2, 4, 6, 8, 10, 12,
  17, 23, 29, 37, 47, 59, 73,
  97, 127, 167, 223, 293, 389, 521, 691, 919, 1223, 1627, 2161,
  3229, 4831, 7243, 10861, 16273, 24407, 36607, 54907,
};

static size_t hash_alloc_greater_or_equal_to(size_t x) {
  size_t i;
  for (i = 0; i < sizeof hash_allocation_sizes / sizeof hash_allocation_sizes[0]; ++i) {
    if (hash_allocation_sizes[i] >= x) return hash_allocation_sizes[i];
  }
  return (x + x / 2) | 1;
}

/* A map lookup kind (map.c's mp_map_lookup_kind_t). */
enum { MAP_LOOKUP, MAP_ADD, MAP_REMOVE };

static void map_rehash_table(MpyDict *d);

/* map.c's mp_map_lookup for a hash table: the slot index of key, or -1 when it is not there (MAP_LOOKUP and MAP_REMOVE), or
 * the slot it was added to (MAP_ADD, with the value 0). A MAP_REMOVE leaves the slot's key as the sentinel (or empty when
 * the next slot is empty). An empty table, and a key that cannot be in a table of interned strs, are answered without a
 * hash, so a load of an unhashable key from such a table is a KeyError, as in MicroPython. */
static long map_lookup(MpyDict *d, mpv key, int kind) {
  int compare_only_ptrs = d->all_keys_are_qstrs;
  size_t hash, pos, start;
  long avail = -1;
  if (compare_only_ptrs) {
    if (is_qstr(key)) {
      /* a pointer compare is enough */
    } else if (is_str(key)) {
      compare_only_ptrs = 0;
    } else if (kind != MAP_ADD) {
      return -1;
    }
  }
  if (d->alloc == 0) {
    if (kind != MAP_ADD) return -1;
    map_rehash_table(d);
  }
  hash = key_hash(key);
  pos = hash % d->alloc;
  start = pos;
  for (;;) {
    MpyEntry *slot = &d->table[pos];
    if (slot->key == 0) {
      long at = avail >= 0 ? avail : (long)pos;
      if (kind != MAP_ADD) return -1;
      d->used += 1;
      d->table[at].key = key;
      d->table[at].value = 0;
      if (!is_qstr(key)) d->all_keys_are_qstrs = 0;
      return at;
    } else if (slot->key == MPY_SENTINEL) {
      if (avail < 0) avail = (long)pos;
    } else if (slot->key == key || (!compare_only_ptrs && key_equal(slot->key, key))) {
      if (kind == MAP_REMOVE) {
        d->used--;
        if (d->table[(pos + 1) % d->alloc].key == 0) slot->key = 0;
        else slot->key = MPY_SENTINEL;
      }
      return (long)pos;
    }
    pos = (pos + 1) % d->alloc;
    if (pos == start) {
      if (kind != MAP_ADD) return -1;
      if (avail >= 0) {
        d->used += 1;
        d->table[avail].key = key;
        d->table[avail].value = 0;
        if (!is_qstr(key)) d->all_keys_are_qstrs = 0;
        return avail;
      }
      map_rehash_table(d);
      start = pos = hash % d->alloc;
    }
  }
}

/* map.c's mp_map_rehash: the table grows to the next size, and the live items are added to it in the old table's order. */
static void map_rehash_table(MpyDict *d) {
  size_t old_alloc = d->alloc, new_alloc = hash_alloc_greater_or_equal_to(d->alloc + 1), i;
  MpyEntry *old = d->table;
  d->table = (MpyEntry *)calloc(new_alloc, sizeof(MpyEntry));
  if (d->table == NULL) fail("out of memory");
  d->alloc = new_alloc;
  d->used = 0;
  d->all_keys_are_qstrs = 1;
  for (i = 0; i < old_alloc; ++i) {
    if (old[i].key != 0 && old[i].key != MPY_SENTINEL) {
      long at = map_lookup(d, old[i].key, MAP_ADD);
      d->table[at].value = old[i].value;
    }
  }
  free(old);
}

/* d[key] = value. An existing key keeps its place and its key object. */
static void dict_store(mpv dv, mpv key, mpv value) {
  MpyDict *d = (MpyDict *)(uintptr_t)dv;
  long at = map_lookup(d, key, MAP_ADD);
  d->table[at].value = value;
}

/* The text of a key in a KeyError: a str as its text, anything else as its repr (MicroPython prints the exception's argument
 * with str). */
static void key_text(Buf *b, mpv v) {
  if (is_str(v)) buf_put(b, str_of(v)->data, str_of(v)->len);
  else repr_into(b, v);
}

static void key_error(mpv key) {
  Buf b = {NULL, 0, 0};
  buf_str(&b, "KeyError: ");
  key_text(&b, key);
  fail(b.p);
}

static mpv dict_get(mpv dv, mpv key) {
  MpyDict *d = (MpyDict *)(uintptr_t)dv;
  long at = map_lookup(d, key, MAP_LOOKUP);
  if (at < 0) key_error(key);
  return d->table[at].value;
}

static void dict_delete(mpv dv, mpv key) {
  MpyDict *d = (MpyDict *)(uintptr_t)dv;
  long at = map_lookup(d, key, MAP_REMOVE);
  if (at < 0) key_error(key);
}

/* A new dict with a table of n slots (MicroPython's mp_obj_new_dict(n) sizes it by the number of items the literal has). */
mpv mpy_build_map(uint64_t n) {
  MpyDict *d = (MpyDict *)malloc(sizeof *d);
  if (d == NULL) fail("out of memory");
  d->type = &mpy_type_dict;
  d->alloc = (size_t)n;
  d->used = 0;
  d->all_keys_are_qstrs = 1;
  d->table = n ? (MpyEntry *)calloc((size_t)n, sizeof(MpyEntry)) : NULL;
  if (n && d->table == NULL) fail("out of memory");
  return (mpv)(uintptr_t)d;
}

/* STORE_MAP: dict[key] = value. */
void mpy_dict_store(mpv dv, mpv key, mpv value) { dict_store(dv, key, value); }

/* `x in c` is contains(c, x): a str holds a substring, a list or tuple an equal item, a dict a key. */
static int contains(mpv c, mpv x) {
  char msg[160];
  size_t n, i;
  const mpv *items;
  if (is_str(c)) {
    const MpyStr *hay, *needle;
    if (!is_str(x)) {
      snprintf(msg, sizeof msg, "TypeError: can't convert '%s' object to str implicitly", real_type_name(x));
      fail(msg);
    }
    hay = str_of(c);
    needle = str_of(x);
    for (i = 0; i + needle->len <= hay->len; ++i) {
      if (memcmp(hay->data + i, needle->data, needle->len) == 0) return 1;
    }
    return 0;
  }
  if (is_dict(c)) return map_lookup((MpyDict *)(uintptr_t)c, x, MAP_LOOKUP) >= 0;
  if (seq_items(c, &n, &items)) {
    for (i = 0; i < n; ++i) {
      if (values_equal(items[i], x)) return 1;
    }
    return 0;
  }
  if (is_small(c) || is_bool(c)) {
    snprintf(msg, sizeof msg, "TypeError: unsupported types for : '%s', '%s'", type_name(x), type_name(c));
    fail(msg);
  }
  if (is_range(c) || is_iter(c)) fail("TypeError: containment in a range or an iterator is not lowered yet");
  snprintf(msg, sizeof msg, "TypeError: '%s' object isn't iterable", real_type_name(c));
  fail(msg);
  return 0;
}

/* A str operator: == and != compare the bytes (a str never equals a non-str), + concatenates two strs. The other operators
 * on a str are not lowered yet, and they fail here rather than give a wrong answer. */
static mpv str_binop(int op, mpv a, mpv b) {
  char msg[160];
  if (op == MPY_OP_EQUAL || op == MPY_OP_NOT_EQUAL) {
    int eq = 0;
    if (is_str(a) && is_str(b)) {
      const MpyStr *x = str_of(a), *y = str_of(b);
      eq = x->len == y->len && memcmp(x->data, y->data, x->len) == 0;
    }
    return (eq == (op == MPY_OP_EQUAL)) ? MPY_TRUE : MPY_FALSE;
  }
  if (op == MPY_OP_ADD) {
    if (!is_str(a) || !is_str(b)) {
      snprintf(msg, sizeof msg, "TypeError: unsupported types for __add__: '%s', '%s'", type_name(a), type_name(b));
      fail(msg);
    }
    {
      const MpyStr *x = str_of(a), *y = str_of(b);
      MpyStr *r;
      if (x->len + y->len < x->len) fail("string too long");
      r = alloc_str(x->len + y->len);
      memcpy(r->data, x->data, x->len);
      memcpy(r->data + x->len, y->data, y->len);
      return (mpv)(uintptr_t)r;
    }
  }
  if (op == MPY_OP_LESS || op == MPY_OP_MORE || op == MPY_OP_LESS_EQUAL || op == MPY_OP_MORE_EQUAL) {
    fail("str ordering (<, >, <=, >=) is not lowered yet");
  }
  snprintf(msg, sizeof msg, "str operator (code %d) is not lowered yet", op);
  fail(msg);
  return MPY_NONE;
}

mpv mpy_small(int64_t n) { return make_small(n); }

/* A binary operator (the MP_BINARY_OP_* codes). Booleans take part as 0 and 1, as in Python. */
mpv mpy_binop(int op, mpv a, mpv b) {
  int64_t x, y, r = 0;
  /* The in-place forms (MP_BINARY_OP_INPLACE_OR = 9 .. INPLACE_POWER = 21) are the same operators on immutable ints:
   * INPLACE_X is X + 13 (runtime0.h). The in-place matrix multiply, true divide and power stay unsupported. */
  if (op >= 9 && op <= 21) op += 13;
  if (op == MPY_OP_IN) return contains(b, a) ? MPY_TRUE : MPY_FALSE;   /* a in b: the right operand is the container */
  if (op == MPY_OP_IS) return a == b ? MPY_TRUE : MPY_FALSE;           /* the same word: one immediate or one object */
  if (is_str(a) || is_str(b)) return str_binop(op, a, b);
  x = need_int(a);
  y = need_int(b);
  switch (op) {
    case MPY_OP_LESS: return x < y ? MPY_TRUE : MPY_FALSE;
    case MPY_OP_MORE: return x > y ? MPY_TRUE : MPY_FALSE;
    case MPY_OP_EQUAL: return x == y ? MPY_TRUE : MPY_FALSE;
    case MPY_OP_LESS_EQUAL: return x <= y ? MPY_TRUE : MPY_FALSE;
    case MPY_OP_MORE_EQUAL: return x >= y ? MPY_TRUE : MPY_FALSE;
    case MPY_OP_NOT_EQUAL: return x != y ? MPY_TRUE : MPY_FALSE;
    case MPY_OP_OR: r = x | y; break;
    case MPY_OP_XOR: r = x ^ y; break;
    case MPY_OP_AND: r = x & y; break;
    case MPY_OP_ADD:
      if (__builtin_add_overflow(x, y, &r)) fail("integer overflow (big ints are not implemented)");
      break;
    case MPY_OP_SUBTRACT:
      if (__builtin_sub_overflow(x, y, &r)) fail("integer overflow (big ints are not implemented)");
      break;
    case MPY_OP_MULTIPLY:
      if (__builtin_mul_overflow(x, y, &r)) fail("integer overflow (big ints are not implemented)");
      break;
    case MPY_OP_FLOOR_DIVIDE:
      if (y == 0) fail("ZeroDivisionError: divide by zero");
      r = x / y;
      if ((x % y != 0) && ((x < 0) != (y < 0))) r -= 1;   /* Python's floor */
      break;
    case MPY_OP_MODULO:
      if (y == 0) fail("ZeroDivisionError: modulo by zero");
      r = x % y;
      if (r != 0 && ((r < 0) != (y < 0))) r += y;   /* the sign of the divisor */
      break;
    case MPY_OP_LSHIFT:
      if (y < 0) fail("negative shift count");
      if (y >= 63) {
        if (x == 0) r = 0;
        else fail("integer overflow (big ints are not implemented)");
      } else {
        r = (int64_t)((uint64_t)x << y);
        if ((r >> y) != x) fail("integer overflow (big ints are not implemented)");
      }
      break;
    case MPY_OP_RSHIFT:
      if (y < 0) fail("negative shift count");
      r = y >= 63 ? (x < 0 ? -1 : 0) : (x >> y);
      break;
    default: fail("unsupported binary operator");
  }
  return make_small(r);
}

/* A unary operator (the MP_UNARY_OP_* codes). */
mpv mpy_unop(int op, mpv a) {
  switch (op) {
    case MPY_UOP_NOT: return mpy_truth(a) ? MPY_FALSE : MPY_TRUE;
    case MPY_UOP_POSITIVE: return make_small(need_int(a));
    case MPY_UOP_NEGATIVE: {
      int64_t x = need_int(a), r;
      if (__builtin_sub_overflow((int64_t)0, x, &r)) fail("integer overflow (big ints are not implemented)");
      return make_small(r);
    }
    case MPY_UOP_INVERT: return make_small(~need_int(a));
    default: fail("unsupported unary operator");
  }
  return MPY_NONE;
}

/* The module's globals: names and values, in creation order. */
typedef struct {
  char *name;
  size_t len;
  mpv value;
} Global;

static Global *globals = NULL;
static size_t n_globals = 0, cap_globals = 0;

static Global *find_global(const char *name, size_t len) {
  for (size_t i = 0; i < n_globals; ++i) {
    if (globals[i].len == len && memcmp(globals[i].name, name, len) == 0) return &globals[i];
  }
  return NULL;
}

void mpy_store_name(const char *name, size_t len, mpv value) {
  Global *g = find_global(name, len);
  if (g == NULL) {
    if (n_globals == cap_globals) {
      cap_globals = cap_globals ? cap_globals * 2 : 16;
      globals = (Global *)realloc(globals, cap_globals * sizeof(Global));
      if (globals == NULL) fail("out of memory");
    }
    g = &globals[n_globals++];
    g->name = (char *)malloc(len + 1);
    if (g->name == NULL) fail("out of memory");
    memcpy(g->name, name, len);
    g->name[len] = '\0';
    g->len = len;
  }
  g->value = value;
}

mpv mpy_load_name(const char *name, size_t len) {
  Global *g = find_global(name, len);
  int b;
  if (g != NULL) return g->value;
  b = builtin_index(name, len);
  if (b < 0) fail("NameError: name is not defined");
  return builtin_obj(b);
}

/* For the driver: the value of a global, or MPY_NONE and 0 when there is none. */
mpv mpy_get_global(const char *name, int *found) {
  Global *g = find_global(name, strlen(name));
  *found = g != NULL;
  return g != NULL ? g->value : MPY_NONE;
}

/* The value stack that calls take their arguments from: the lowered code pushes each argument, then calls. */
static mpv *vstk = NULL;
static size_t vtop = 0, vcap = 0;

/* Makes room for n values on the value stack. */
static void vstk_reserve(size_t n) {
  size_t cap = vcap ? vcap : 64;
  if (n <= vcap) return;
  while (cap < n) cap *= 2;
  vstk = (mpv *)realloc(vstk, cap * sizeof(mpv));
  if (vstk == NULL) fail("out of memory");
  vcap = cap;
}

void mpy_push(mpv v) {
  vstk_reserve(vtop + 1);
  vstk[vtop++] = v;
}

/* Functions. A function object is a heap record: the number of its IR function (mpy_dispatch's K), its positional
 * argument count (the count the caller passes), and the cells it captured (n_closed of them; 0 for a plain function). A
 * closure is the same record with captured cells. The pointer has its low two bits clear, so it is not a small int or an
 * immediate. */
typedef struct {
  const MpyType *type;
  uint64_t index;
  uint64_t nargs;
  uint64_t n_closed;
  mpv closed[]; /* C99 flexible array member: the captured cells, the first free variables of the function */
} MpyFunc;

/* Generated by the lowering (mpy_dispatch): calls function number idx with args[0..nargs-1], storing the result in ret. */
void mpy_dispatch(uint64_t idx, mpv *ret, const mpv *args, uint64_t nargs);

mpv mpy_make_function(uint64_t index, uint64_t nargs) {
  MpyFunc *f = (MpyFunc *)malloc(sizeof *f);
  if (f == NULL) fail("out of memory");
  f->type = &mpy_type_function;
  f->index = index;
  f->nargs = nargs;
  f->n_closed = 0;
  return (mpv)(uintptr_t)f;
}

/* A str literal: the bytes at bytes (len of them, NUL-terminated in the data). id numbers the literal sites of the module,
 * densely from 0, and the record of each one is allocated the first time its site runs. */
mpv mpy_str_lit(const char *bytes, size_t len, uint64_t id) {
  static mpv *lits = NULL;
  static size_t n_lits = 0;
  if (id >= n_lits) {
    size_t n = (size_t)id + 1, k;
    lits = (mpv *)realloc(lits, n * sizeof(mpv));
    if (lits == NULL) fail("out of memory");
    for (k = n_lits; k < n; ++k) lits[k] = 0;
    n_lits = n;
  }
  if (lits[id] == 0) {
    MpyStr *s = alloc_str(len);
    memcpy(s->data, bytes, len);
    s->interned = 1;
    lits[id] = (mpv)(uintptr_t)s;
  }
  return lits[id];
}

/* A closure: its n captured cells are the top n values of the value stack, which they leave (as MAKE_CLOSURE pops them). */
mpv mpy_make_closure(uint64_t index, uint64_t nargs, uint64_t n) {
  MpyFunc *f;
  if (n > vtop) fail("mpy_make_closure: the captured cells are not on the value stack");
  f = (MpyFunc *)malloc(sizeof *f + n * sizeof(mpv));
  if (f == NULL) fail("out of memory");
  f->type = &mpy_type_function;
  f->index = index;
  f->nargs = nargs;
  f->n_closed = n;
  if (n) memcpy(f->closed, vstk + (vtop - n), n * sizeof(mpv));
  vtop -= n;
  return (mpv)(uintptr_t)f;
}

/* Calls fn with the nargs values on top of the value stack, which they leave. A closure's captured cells go in front of
 * the arguments, as MicroPython's closure_call puts them, so the function sees its free variables as its first locals. */
static mpv builtin_call(int id, const mpv *args, uint64_t n);

mpv mpy_call(mpv fn, uint64_t nargs) {
  MpyFunc *f;
  size_t base, k;
  mpv ret = MPY_NONE;
  if (is_builtin(fn)) {
    if (nargs > vtop) fail("mpy_call: the arguments are not on the value stack");
    base = vtop - nargs;
    ret = builtin_call(((const MpyBuiltin *)(uintptr_t)fn)->id, nargs ? vstk + base : NULL, nargs);
    vtop = base;
    return ret;
  }
  if (!is_heap(fn) || type_of(fn) != &mpy_type_function) fail("TypeError: object is not callable");
  f = (MpyFunc *)(uintptr_t)fn;
  if (nargs != f->nargs) fail("TypeError: wrong number of arguments");
  base = vtop - nargs;
  k = (size_t)f->n_closed;
  if (k) {
    vstk_reserve(vtop + k);
    memmove(vstk + base + k, vstk + base, nargs * sizeof(mpv));
    memcpy(vstk + base, f->closed, k * sizeof(mpv));
    vtop += k;
  }
  mpy_dispatch(f->index, &ret, (nargs + k) ? vstk + base : NULL, nargs + k);
  vtop = base;
  return ret;
}

/* Container operations. Each returns a value or fails with the message MicroPython gives. The lowering passes the operands
 * on the value stack for the builders, and as arguments for the rest. */
mpv mpy_build_list(uint64_t n) {
  MpyList *l = (MpyList *)malloc(sizeof *l);
  size_t base = vtop - n, i;
  if (l == NULL) fail("out of memory");
  l->type = &mpy_type_list;
  l->len = n;
  l->cap = n ? n : 1;
  l->items = (mpv *)malloc(l->cap * sizeof(mpv));
  if (l->items == NULL) fail("out of memory");
  for (i = 0; i < n; ++i) l->items[i] = vstk[base + i];
  vtop = base;
  return (mpv)(uintptr_t)l;
}

mpv mpy_build_tuple(uint64_t n) {
  MpyTuple *t = (MpyTuple *)malloc(sizeof *t + n * sizeof(mpv));
  size_t base = vtop - n, i;
  if (t == NULL) fail("out of memory");
  t->type = &mpy_type_tuple;
  t->len = n;
  for (i = 0; i < n; ++i) t->items[i] = vstk[base + i];
  vtop = base;
  return (mpv)(uintptr_t)t;
}

/* LIST_APPEND of a list comprehension (STORE_COMP with kind 0): appends to the list. */
void mpy_list_append(mpv l, mpv v) {
  if (!is_list(l)) fail("internal: a list comprehension's collection is not a list");
  list_append((MpyList *)(uintptr_t)l, v);
}

/* A slice of start, stop and step (each an int or None): BUILD_SLICE. */
mpv mpy_make_slice(mpv start, mpv stop, mpv step) {
  MpySlice *s = (MpySlice *)malloc(sizeof *s);
  if (s == NULL) fail("out of memory");
  s->type = &mpy_type_slice;
  s->start = start;
  s->stop = stop;
  s->step = step;
  return (mpv)(uintptr_t)s;
}

/* The integer of a slice bound: an int or a bool. */
static int64_t slice_int(mpv v) {
  char msg[120];
  if (is_small(v) || is_bool(v)) return need_int(v);
  snprintf(msg, sizeof msg, "TypeError: can't convert %s to int", real_type_name(v));
  fail(msg);
  return 0;
}

static int64_t clamp_i(int64_t v, int64_t lo, int64_t hi) { return v < lo ? lo : (v > hi ? hi : v); }

/* The bounds of a slice over a sequence of len items, as MicroPython's mp_obj_slice_indices and
 * mp_seq_get_fast_slice_indexes give them: the items are start, start + step, ... while they are below stop (above it for a
 * negative step). Returns 1 when the step is 1. */
static int slice_indices(mpv sv, int64_t len, int64_t *out_start, int64_t *out_stop, int64_t *out_step) {
  const MpySlice *s = slice_of(sv);
  int64_t start, stop, step;
  if (s->step == MPY_NONE) {
    step = 1;
  } else {
    step = slice_int(s->step);
    if (step == 0) fail("ValueError: slice step can't be zero");
  }
  if (step > 0) {
    if (s->start == MPY_NONE) {
      start = 0;
    } else {
      start = slice_int(s->start);
      if (start < 0) start += len;
      start = clamp_i(start, 0, len);
    }
    if (s->stop == MPY_NONE) {
      stop = len;
    } else {
      stop = slice_int(s->stop);
      if (stop < 0) stop += len;
      stop = clamp_i(stop, 0, len);
    }
  } else {
    if (s->start == MPY_NONE) {
      start = len - 1;
    } else {
      start = slice_int(s->start);
      if (start < 0) start += len;
      start = clamp_i(start, -1, len - 1);
    }
    if (s->stop == MPY_NONE) {
      stop = -1;
    } else {
      stop = slice_int(s->stop);
      if (stop < 0) stop += len;
      stop = clamp_i(stop, -1, len - 1);
    }
  }
  /* mp_seq_get_fast_slice_indexes: a negative step's stop is one past the last item; an empty slice has stop at start. */
  if (step < 0) stop++;
  if (step > 0 && start > stop) stop = start;
  else if (step < 0 && start < stop) stop = start + 1;
  *out_start = start;
  *out_stop = stop;
  *out_step = step;
  return step == 1;
}

/* list[slice] and tuple[slice]: a new list or tuple. A tuple takes only a step of 1, as MicroPython does. */
static mpv seq_slice(mpv obj, mpv sv) {
  size_t len;
  const mpv *items;
  int64_t start, stop, step, i;
  int fast;
  seq_items(obj, &len, &items);
  fast = slice_indices(sv, (int64_t)len, &start, &stop, &step);
  if (is_tuple(obj)) {
    MpyTuple *t;
    size_t n;
    if (!fast) fail("NotImplementedError: only slices with step=1 (aka None) are supported");
    n = (size_t)(stop - start);
    t = (MpyTuple *)malloc(sizeof *t + n * sizeof(mpv));
    if (t == NULL) fail("out of memory");
    t->type = &mpy_type_tuple;
    t->len = n;
    for (i = 0; i < (int64_t)n; ++i) t->items[i] = items[start + i];
    return (mpv)(uintptr_t)t;
  }
  {
    MpyList *l = list_new(0);
    for (i = start; step > 0 ? i < stop : i >= stop; i += step) list_append(l, items[i]);
    return (mpv)(uintptr_t)l;
  }
}

/* list[slice] = value, or del list[slice] when value is 0: only a step of 1 is lowered (MicroPython's NotImplementedError
 * for the others). The value is copied first, since it may be the list itself. */
static void list_slice_store(MpyList *l, mpv sv, mpv value) {
  int64_t start, stop, step;
  size_t n = 0, newlen, i;
  mpv *tmp = NULL;
  char msg[120];
  if (!slice_indices(sv, (int64_t)l->len, &start, &stop, &step)) fail("NotImplementedError: ");
  if (value != 0) {
    size_t vl;
    const mpv *vi;
    if (!seq_items(value, &vl, &vi)) {
      snprintf(msg, sizeof msg, "TypeError: object '%s' isn't a tuple or list", real_type_name(value));
      fail(msg);
    }
    n = vl;
    tmp = (mpv *)malloc((n ? n : 1) * sizeof(mpv));
    if (tmp == NULL) fail("out of memory");
    for (i = 0; i < n; ++i) tmp[i] = vi[i];
  }
  newlen = l->len - (size_t)(stop - start) + n;
  if (newlen > l->cap) {
    mpv *items = (mpv *)realloc(l->items, newlen * sizeof(mpv));
    if (items == NULL) fail("out of memory");
    l->items = items;
    l->cap = newlen;
  }
  memmove(l->items + start + n, l->items + stop, (l->len - (size_t)stop) * sizeof(mpv));
  if (n) memcpy(l->items + start, tmp, n * sizeof(mpv));
  l->len = newlen;
  free(tmp);
}

/* An index into a sequence of len items: negative counts from the end. */
static size_t checked_index(mpv seq, mpv idx, size_t len, const char *out_of_range) {
  int64_t i;
  char msg[160];
  if (!is_small(idx) && !is_bool(idx)) {
    snprintf(msg, sizeof msg, "TypeError: %s indices must be integers, not %s", type_name(seq), type_name(idx));
    fail(msg);
  }
  i = need_int(idx);
  if (i < 0) i += (int64_t)len;
  if (i < 0 || i >= (int64_t)len) fail(out_of_range);
  return (size_t)i;
}

/* A str index (a str is indexed by character). The index is an int or a bool. */
static int64_t str_index_value(mpv idx, size_t n, int is_slice_bound) {
  int64_t i;
  char msg[160];
  if (!is_small(idx) && !is_bool(idx)) {
    snprintf(msg, sizeof msg, "TypeError: string indices must be integers, not %s", real_type_name(idx));
    fail(msg);
  }
  i = need_int(idx);
  if (i < 0) i += (int64_t)n;
  if (is_slice_bound) return clamp_i(i, 0, (int64_t)n);
  return i;
}

/* str[i]: the one-character str. */
static mpv str_item(const MpyStr *s, mpv idx) {
  size_t n = str_chars(s);
  int64_t i = str_index_value(idx, n, 0);
  size_t a, b;
  if (i < 0 || i >= (int64_t)n) fail("IndexError: string index out of range");
  a = byte_offset(s, (size_t)i);
  b = byte_offset(s, (size_t)i + 1);
  return new_str(s->data + a, b - a);
}

/* str[slice]: only a step of 1 (or None) is lowered. The bounds are clamped to the characters of the str, and a stop before
 * the start gives an empty str. */
static mpv str_slice(const MpyStr *s, mpv sv) {
  const MpySlice *sl = slice_of(sv);
  size_t n = str_chars(s);
  int64_t a, b;
  size_t ba, bb;
  if (sl->step != MPY_NONE && sl->step != (mpv)3) fail("NotImplementedError: only slices with step=1 (aka None) are supported");
  a = sl->start == MPY_NONE ? 0 : str_index_value(sl->start, n, 1);
  b = sl->stop == MPY_NONE ? (int64_t)n : str_index_value(sl->stop, n, 1);
  if (b < a) b = a;
  ba = byte_offset(s, (size_t)a);
  bb = byte_offset(s, (size_t)b);
  return new_str(s->data + ba, bb - ba);
}

mpv mpy_getitem(mpv obj, mpv idx) {
  size_t len;
  const mpv *items;
  char msg[120];
  if (is_dict(obj)) return dict_get(obj, idx);
  if (is_str(obj)) return is_slice(idx) ? str_slice(str_of(obj), idx) : str_item(str_of(obj), idx);
  if (!seq_items(obj, &len, &items)) {
    snprintf(msg, sizeof msg, "TypeError: '%s' object isn't subscriptable", type_name(obj));
    fail(msg);
  }
  if (is_slice(idx)) return seq_slice(obj, idx);
  return items[checked_index(obj, idx, len,
                             is_list(obj) ? "IndexError: list index out of range" : "IndexError: tuple index out of range")];
}

/* obj[idx] = value, or del obj[idx] when value is 0. */
void mpy_setitem(mpv obj, mpv idx, mpv value) {
  MpyList *l;
  size_t i;
  char msg[120];
  if (is_dict(obj)) {
    if (value == 0) dict_delete(obj, idx);
    else dict_store(obj, idx, value);
    return;
  }
  if (!is_list(obj)) {
    snprintf(msg, sizeof msg, "TypeError: '%s' object doesn't support item %s", type_name(obj),
             value == 0 ? "deletion" : "assignment");
    fail(msg);
  }
  l = (MpyList *)(uintptr_t)obj;
  if (is_slice(idx)) {
    list_slice_store(l, idx, value);
    return;
  }
  i = checked_index(obj, idx, l->len, "IndexError: list index out of range");
  if (value == 0) {
    memmove(l->items + i, l->items + i + 1, (l->len - i - 1) * sizeof(mpv));
    l->len -= 1;
  } else {
    l->items[i] = value;
  }
}

/* The value that unpacking n items of seq gives to the i-th slot from the bottom: the first item is on top. */
mpv mpy_unpack_get(mpv seq, uint64_t n, uint64_t i) {
  size_t len;
  const mpv *items;
  char msg[120];
  if (!seq_items(seq, &len, &items)) {
    snprintf(msg, sizeof msg, "TypeError: cannot unpack non-iterable %s object", type_name(seq));
    fail(msg);
  }
  if (len < n) {
    snprintf(msg, sizeof msg, "ValueError: need more than %d values to unpack", (int)len);
    fail(msg);
  }
  if (len > n) {
    snprintf(msg, sizeof msg, "ValueError: too many values to unpack (expected %d)", (int)n);
    fail(msg);
  }
  return items[n - 1 - i];
}

mpv mpy_get_iter(mpv obj) {
  MpyIter *it;
  size_t len;
  const mpv *items;
  char msg[120];
  if (is_iter(obj)) return obj;
  if (!is_range(obj) && !seq_items(obj, &len, &items)) {
    snprintf(msg, sizeof msg, "TypeError: '%s' object isn't iterable", type_name(obj));
    fail(msg);
  }
  it = (MpyIter *)malloc(sizeof *it);
  if (it == NULL) fail("out of memory");
  it->type = &mpy_type_iter;
  it->seq = obj;
  it->index = 0;
  return (mpv)(uintptr_t)it;
}

/* The next item, or 0 when the sequence is exhausted (0 is never a value). A list may grow while it is iterated. */
mpv mpy_iter_next(mpv iter) {
  MpyIter *it = (MpyIter *)(uintptr_t)iter;
  size_t len;
  const mpv *items;
  if (is_range(it->seq)) {
    const MpyRange *r = range_of(it->seq);
    int64_t v;
    if (it->index >= r->len) return 0;
    v = r->start + (int64_t)it->index * r->step;
    it->index++;
    return make_small(v);
  }
  seq_items(it->seq, &len, &items);
  if (it->index >= len) return 0;
  return items[it->index++];
}

/* Cells. A cell is a heap box holding one value; a closure and the function that owns the variable share it. The value 0
 * is unbound (the variable has not been assigned yet). Cells are never values a program can name: lowered code reaches them
 * only through its locals and the captured cells of a closure. */
typedef struct {
  mpv value;
} MpyCell;

mpv mpy_make_cell(mpv value) {
  MpyCell *c = (MpyCell *)malloc(sizeof *c);
  if (c == NULL) fail("out of memory");
  c->value = value;
  return (mpv)(uintptr_t)c;
}

mpv mpy_cell_get(mpv cell) {
  MpyCell *c = (MpyCell *)(uintptr_t)cell;
  if (c->value == 0) fail("NameError: local variable referenced before assignment");
  return c->value;
}

void mpy_cell_set(mpv cell, mpv value) {
  ((MpyCell *)(uintptr_t)cell)->value = value;
}

/* Builtins. A builtin's arguments are args[0..n-1] on the value stack (mpy_call leaves them there until it returns). */

/* range(start, stop, step): the number of items is that of the arithmetic sequence. */
static mpv new_range(int64_t start, int64_t stop, int64_t step) {
  MpyRange *r;
  if (step == 0) fail("ValueError: zero step");
  r = (MpyRange *)malloc(sizeof *r);
  if (r == NULL) fail("out of memory");
  r->type = &mpy_type_range;
  r->start = start;
  r->stop = stop;
  r->step = step;
  if (step > 0) r->len = start < stop ? (size_t)((stop - start - 1) / step + 1) : 0;
  else r->len = start > stop ? (size_t)((start - stop - 1) / -step + 1) : 0;
  return (mpv)(uintptr_t)r;
}

static mpv builtin_call(int id, const mpv *args, uint64_t n) {
  char msg[160];
  switch (id) {
    case BI_LEN: {
      size_t len;
      const mpv *items;
      if (n != 1) fail("TypeError: len() takes exactly one argument");
      if (is_str(args[0])) return make_small((int64_t)str_chars(str_of(args[0])));
      if (seq_items(args[0], &len, &items)) return make_small((int64_t)len);
      if (is_range(args[0])) return make_small((int64_t)range_of(args[0])->len);
      if (is_dict(args[0])) return make_small((int64_t)dict_of(args[0])->used);
      snprintf(msg, sizeof msg, "TypeError: object of type '%s' has no len()", real_type_name(args[0]));
      fail(msg);
      return MPY_NONE;
    }
    case BI_STR: {
      char buf[32];
      int k;
      if (n == 0) return new_str("", 0);
      if (n != 1) fail("TypeError: str() takes at most 1 argument");
      if (is_str(args[0])) return args[0];   /* str(s) is s, as in MicroPython */
      if (args[0] == MPY_NONE) return new_str("None", 4);
      if (args[0] == MPY_TRUE) return new_str("True", 4);
      if (args[0] == MPY_FALSE) return new_str("False", 5);
      if (is_small(args[0])) {
        k = snprintf(buf, sizeof buf, "%lld", (long long)small_value(args[0]));
        return new_str(buf, (size_t)k);
      }
      fail("str() of this value is not lowered yet");
      return MPY_NONE;
    }
    case BI_RANGE: {
      uint64_t i;
      if (n < 1 || n > 3) fail("TypeError: range expected 1 to 3 arguments");
      for (i = 0; i < n; ++i) {
        if (!is_small(args[i]) && !is_bool(args[i])) {
          snprintf(msg, sizeof msg, "TypeError: can't convert %s to int", real_type_name(args[i]));
          fail(msg);
        }
      }
      if (n == 1) return new_range(0, need_int(args[0]), 1);
      if (n == 2) return new_range(need_int(args[0]), need_int(args[1]), 1);
      return new_range(need_int(args[0]), need_int(args[1]), need_int(args[2]));
    }
    case BI_APPEND: {
      if (n != 2) fail("TypeError: append() takes exactly one argument");
      if (!is_list(args[0])) fail("TypeError: append() needs a list");
      list_append((MpyList *)(uintptr_t)args[0], args[1]);
      return MPY_NONE;
    }
    case BI_POP: {
      MpyList *l;
      size_t i;
      mpv v;
      if (n < 1 || n > 2) fail("TypeError: pop() takes at most 1 argument");
      if (!is_list(args[0])) fail("TypeError: pop() needs a list");
      l = (MpyList *)(uintptr_t)args[0];
      if (l->len == 0) fail("IndexError: pop from empty list");
      i = n == 2 ? checked_index(args[0], args[1], l->len, "IndexError: list index out of range") : l->len - 1;
      v = l->items[i];
      memmove(l->items + i, l->items + i + 1, (l->len - i - 1) * sizeof(mpv));
      l->len -= 1;
      return v;
    }
    default:
      fail("internal: unknown builtin");
  }
  return MPY_NONE;
}

/* LOAD_METHOD: the method of obj named name. The lowering passes only append and pop. A list has them; any other value
 * fails with MicroPython's attribute error. */
mpv mpy_load_method(mpv obj, const char *name, size_t len) {
  char msg[160];
  if (is_list(obj)) {
    if (len == 6 && memcmp(name, "append", 6) == 0) return builtin_obj(BI_APPEND);
    if (len == 3 && memcmp(name, "pop", 3) == 0) return builtin_obj(BI_POP);
  }
  snprintf(msg, sizeof msg, "AttributeError: '%s' object has no attribute '%.*s'", real_type_name(obj), (int)len, name);
  fail(msg);
  return MPY_NONE;
}

/* repr of a str, as MicroPython writes it: single quotes unless the text has a single quote and no double quote. */
static void repr_str(Buf *b, const MpyStr *s) {
  int has_sq = memchr(s->data, '\'', s->len) != NULL;
  int has_dq = memchr(s->data, '"', s->len) != NULL;
  char q = (has_sq && !has_dq) ? '"' : '\'';
  size_t i;
  buf_put(b, &q, 1);
  for (i = 0; i < s->len; ++i) {
    unsigned char c = (unsigned char)s->data[i];
    if (c == (unsigned char)q || c == '\\') {
      buf_put(b, "\\", 1);
      buf_put(b, (const char *)&c, 1);
    } else if (c == '\n') buf_str(b, "\\n");
    else if (c == '\r') buf_str(b, "\\r");
    else if (c == '\t') buf_str(b, "\\t");
    else if (c < 0x20 || c == 0x7f) {
      char t[8];
      snprintf(t, sizeof t, "\\x%02x", c);
      buf_str(b, t);
    } else buf_put(b, (const char *)&c, 1);
  }
  buf_put(b, &q, 1);
}

/* repr of a value: numbers, bools and None by name, str quoted, lists and tuples with their items' repr, and dicts as
 * key: value pairs in insertion order. */
static void repr_into(Buf *b, mpv v) {
  size_t n, i;
  const mpv *items;
  if (is_small(v)) buf_int(b, (long long)small_value(v));
  else if (v == MPY_TRUE) buf_str(b, "True");
  else if (v == MPY_FALSE) buf_str(b, "False");
  else if (v == MPY_NONE) buf_str(b, "None");
  else if (is_str(v)) repr_str(b, str_of(v));
  else if (is_range(v)) {
    const MpyRange *r = range_of(v);
    char t[96];
    int k;
    if (r->step == 1) k = snprintf(t, sizeof t, "range(%lld, %lld)", (long long)r->start, (long long)r->stop);
    else k = snprintf(t, sizeof t, "range(%lld, %lld, %lld)", (long long)r->start, (long long)r->stop, (long long)r->step);
    buf_put(b, t, (size_t)k);
  } else if (is_dict(v)) {
    const MpyDict *d = dict_of(v);
    size_t e;
    int first = 1;
    buf_put(b, "{", 1);
    for (e = 0; e < d->alloc; ++e) {   /* MicroPython prints the items in table order */
      if (d->table[e].key == 0 || d->table[e].key == MPY_SENTINEL) continue;
      if (!first) buf_str(b, ", ");
      first = 0;
      repr_into(b, d->table[e].key);
      buf_str(b, ": ");
      repr_into(b, d->table[e].value);
    }
    buf_put(b, "}", 1);
  } else if (is_slice(v)) {
    const MpySlice *s = slice_of(v);
    buf_str(b, "slice(");
    repr_into(b, s->start);
    buf_str(b, ", ");
    repr_into(b, s->stop);
    buf_str(b, ", ");
    repr_into(b, s->step);
    buf_put(b, ")", 1);
  } else if (seq_items(v, &n, &items)) {
    int is_l = is_list(v);
    buf_put(b, is_l ? "[" : "(", 1);
    for (i = 0; i < n; ++i) {
      if (i) buf_str(b, ", ");
      repr_into(b, items[i]);
    }
    if (!is_l && n == 1) buf_put(b, ",", 1);
    buf_put(b, is_l ? "]" : ")", 1);
  } else fail("repr of this value is not lowered yet");
}

/* Prints a value as the driver reports the result of the module: a str as its text, anything else as repr. */
void mpy_print_value(mpv v) {
  Buf b = {NULL, 0, 0};
  if (is_str(v)) {
    fwrite(str_of(v)->data, 1, str_of(v)->len, stdout);   /* the bytes may hold NULs */
  } else {
    repr_into(&b, v);
    fwrite(b.p, 1, b.n, stdout);
    free(b.p);
  }
  putchar('\n');
}
