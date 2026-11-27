/* mrbrt: the runtime of the mruby bytecode producer (mrbrt.h). C99, -Wall -Wextra clean. The messages are the ones of the
 * pinned mruby 4.0.0 (probed with build/mruby-tool/bin/mruby; docs/notes/mrbbc-pathb.md, "Runtime errors"). */
#if MRBBC_VALUE == 4 && defined(__x86_64__)
#define _GNU_SOURCE /* MAP_32BIT, see raw_alloc */
#include <sys/mman.h>
#endif
#include "mrbrt.h"
#if MRBBC_LIBUV
#include "mrbrt_uv.h"
#endif

#include <setjmp.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

const char *mrbbc_progname = "mrbbc";

/* The checked 64-bit multiply of the IR (scripts/pathb-qbe-emit.rb calls it for cmul): the same function as in
 * be/nfcxx_ldrt.c, defined here so the test links without that runtime. Nonzero when the product overflows. */
int __nfcxx_smul64_ovf(long a, long b) {
  long r;
  return __builtin_mul_overflow(a, b, &r);
}

/* Every heap object is allocated by gc_alloc, which puts a GCHdr in front of it: the object's address (the int64 of its MV)
 * is the word after the header, so the MV keeps the address the object was allocated at. The kind says how the collector
 * traverses the object and which buffers it owns (freed with it). size is what the object counts for the threshold: its
 * payload and the buffers it owns, which grow with them (gc_grow). See "the collector" below. */
typedef struct GCHdr {
  struct GCHdr *next;  /* every object, newest first */
  uint32_t size;
  uint8_t kind;
  uint8_t marked;
  uint16_t block; /* the arena's size class of the block (raw_free) */
} GCHdr;

enum { GC_STR = 1, GC_ARY, GC_HASH, GC_VEC, GC_OBJ, GC_IVAR, GC_DEF, GC_CLS, GC_INT, GC_CLO };

static void *gc_alloc(uint8_t kind, size_t size);
/* The innermost frame the lowered code registered (mrbbc_gc_enter), and the values a helper protects while it allocates:
 * precise roots (MRBBC_GC_CONSERVATIVE 0, the default), see "the collector". */
static MrbbcGCFrame *gc_top = NULL;
#define PROTECT_MAX 64
static const MV *protected[PROTECT_MAX];
static int protect_n = 0;
static int gc_protect(const MV *v) {
  if (protect_n == PROTECT_MAX) mrbbc_raise("RuntimeError", "too many values protected from the collector");
  protected[protect_n++] = v;
  return protect_n - 1;
}
static void gc_unprotect(int mark) { protect_n = mark; }
static void gc_grow(const void *p, size_t n);
static void gc_collect(void);

/* Strings and arrays own growable buffers; their object addresses stay stable when an alias appends to them. */
typedef struct MStr {
  long len;
  size_t cap;
  char *p;
} MStr;

/* A growable byte buffer for inspect and to_s. */
typedef struct Buf {
  char *p;
  size_t n, cap;
} Buf;

static void inspect_value(Buf *b, const MV *v);
static MV to_s_string(const MV *v);
static void join_value(MV *dst, const MV *recv);

typedef struct MAry {
  long len, cap;
  MV *items;
} MAry;

/* A hash of the program: pairs of keys and values in order (a key set again keeps its place). */
typedef struct MHash {
  long len, cap;
  MV *keys, *vals;
} MHash;
static MHash *hash_of(const MV *v);

/* Classes and objects. A method of the program is an MDef in the list of its class (newest first, so a redefinition wins),
 * and a top-level one is in object_class's list. A class has its name (the full one, A::B for a nested class), the key
 * GETCONST and CLASS find it by (the plain name), its class-level instance variables, and the next class of the registry.
 * An object is its class and its instance variables. Each of these is a collected object (see "the collector" below). */
typedef struct MDef {
  const char *name;
  int id;
  long min;  /* the required and post parameters: the fewest arguments */
  long max;  /* the most arguments: the required, optional and post parameters, or -1 with a rest parameter */
  int kd;    /* the method has keyword parameters (its keyword hash is not a positional argument) */
  int fast;  /* only required parameters (vm.c's ENTER fast path): an empty `**h` splat is a positional argument */
  struct MDef *next;
} MDef;

typedef struct MIvar {
  const char *name;
  MV val;
  struct MIvar *next;
} MIvar;

typedef struct MClass {
  const char *key, *name;
  char *owned_name;  /* the buffer of a full name (A::B), freed with the class; NULL when name is the producer's string */
  MDef *defs;
  MIvar *ivars;
  struct MClass *super; /* the superclass: Object for a class made without one, NULL for Object itself */
  struct MClass *next;
} MClass;

typedef struct MObj {
  MClass *cls;
  MIvar *ivars;
} MObj;

static MClass *object_cls(void);
static MClass *class_registry = NULL;
static int host_argc;
static char **host_argv;
static MV host_args, host_streams[3];
static int host_args_ready;
static int host_constant(MV *dst, const char *name);

/* The class each method body is defined on, by the method's number (the TDEF's class; Object for a top-level def). A SUPER
 * looks from the superclass of that class. */
static MClass **owners = NULL;
static int owners_n = 0;

static void set_owner(int id, MClass *c) {
  int k;
  if (id >= owners_n) {
    MClass **p = realloc(owners, (size_t)(id + 1) * sizeof *p);
    if (p == NULL) mrbbc_raise("NoMemoryError", "failed to allocate memory");
    owners = p;
    for (k = owners_n; k <= id; k++) owners[k] = NULL;
    owners_n = id + 1;
  }
  owners[id] = c;
}

void mrbbc_raise(const char *cls, const char *message) {
  fflush(stdout);
  fprintf(stderr, "%s: %s (%s)\n", mrbbc_progname, message, cls);
  exit(1);
}

/* A raw malloc'd buffer: the items of an array, the keys and values of a hash, a class's full name, or a temporary of one
 * call. It is owned by its object (freed when the object is swept) or by the call; it is never a collected object. */
static void *alloc(size_t n) {
  void *p = malloc(n);
  if (p == NULL) mrbbc_raise("NoMemoryError", "failed to allocate memory");
  return p;
}

/* The C stack holds the helpers' pointers, and a derived pointer (an element's address) can outlive its base in a register.
 * Passing the base here keeps it live until this point, so a collection in between cannot free what the derived one reads. */
static void keep_alive(const void *p) { __asm__ volatile("" : : "g"(p) : "memory"); }

/* Memory for the objects. Under the 4-byte layout on a 64-bit host (MRBBC_VALUE 4 on x86-64), a value holds a 32-bit
 * address, so the objects come from an arena mapped below 2 GB (MAP_32BIT), with free lists by size class; everywhere else
 * they come from malloc. gc_alloc and free_object call these. */
#if MRBBC_VALUE == 4 && UINTPTR_MAX > 0xffffffffu
#if !defined(__x86_64__)
#error "MRBBC_VALUE 4 on a 64-bit host needs MAP_32BIT (x86-64 Linux)"
#endif
#define ARENA_SMALL 2048 /* classes of 16 bytes up to this size, then powers of two */
static char *arena_next, *arena_end;
static void *arena_free_small[ARENA_SMALL / 16 + 1];
static void *arena_free_big[33];

static size_t arena_class(size_t n, int *big) {
  size_t k = 12;
  if (n <= ARENA_SMALL) {
    *big = 0;
    return (n + 15) / 16;
  }
  *big = 1;
  while (((size_t)1 << k) < n) k++;
  return k;
}

static void *raw_alloc(size_t n, unsigned *block) {
  int big;
  size_t k = arena_class(n, &big), sz = big ? (size_t)1 << k : k * 16;
  void **list = big ? &arena_free_big[k] : &arena_free_small[k];
  void *p;
  *block = (unsigned)(big ? 256 + k : k);
  if (*list != NULL) {
    p = *list;
    *list = *(void **)p;
    return p;
  }
  if (arena_next == NULL) {
    size_t len = (size_t)1 << 30;
    void *m = mmap(NULL, len, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_32BIT | MAP_NORESERVE, -1, 0);
    while (m == MAP_FAILED && len > ((size_t)1 << 24)) {
      len >>= 1;
      m = mmap(NULL, len, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_32BIT | MAP_NORESERVE, -1, 0);
    }
    if (m == MAP_FAILED) return NULL;
    arena_next = m;
    arena_end = arena_next + len;
  }
  if ((size_t)(arena_end - arena_next) < sz) return NULL;
  p = arena_next;
  arena_next += sz;
  return p;
}

static void raw_free(void *p, unsigned block) {
  void **list = block >= 256 ? &arena_free_big[block - 256] : &arena_free_small[block];
  *(void **)p = *list;
  *list = p;
}
#else
static void *raw_alloc(size_t n, unsigned *block) {
  *block = 0;
  return malloc(n);
}
static void raw_free(void *p, unsigned block) {
  (void)block;
  free(p);
}
#endif

#if MRBBC_VALUE != 16
/* The tag of the values that point to an object of a kind (only these kinds are values). */
static int kind_tag(int kind) {
  switch (kind) {
    case GC_STR: return MRBBC_STR;
    case GC_ARY: return MRBBC_ARY;
    case GC_HASH: return MRBBC_HASH;
    case GC_OBJ: return MRBBC_OBJ;
    case GC_CLS: return MRBBC_CLS;
    case GC_CLO: return MRBBC_BLK;
    default: return MRBBC_INT;
  }
}
#endif

/* The value representation (mrbrt.h, MRBBC_VALUE). The rest of the runtime reads and makes values only through these. */
#if MRBBC_VALUE == 16
static int tag_of(const MV *v) { return v->tag; }
static int64_t int_of(const MV *v) { return v->i; }
static void *ptr_of(const MV *v) { return (void *)(intptr_t)v->i; }
static int same_value(const MV *a, const MV *b) { return a->tag == b->tag && a->i == b->i; }
static MV make_value(int tag, int64_t i) {
  MV v;
  v.tag = (uint8_t)tag;
  v.i = i;
  return v;
}
static MV nil_value(void) { return make_value(MRBBC_NIL, 0); }
static MV bool_value(int truth) { return make_value(truth ? MRBBC_TRUE : MRBBC_FALSE, 0); }
static MV int_value(int64_t i) { return make_value(MRBBC_INT, i); }
static MV ptr_value(int tag, const void *p) { return make_value(tag, (int64_t)(intptr_t)p); }
static MV sym_value(long index) { return make_value(MRBBC_SYM, index); }
static long sym_index(const MV *v) { return (long)v->i; }
#else
/* A word: an integer in the small range is (i << 1) | 1, a symbol (index << 2) | 2, nil, false and true the constants of
 * mrbrt.h, and anything else the address of an object (8-aligned), whose header has its tag. An integer outside the small
 * range is a boxed one (an object of tag MRBBC_INT), so the integers are exact to 64 bits in every layout. */
typedef MRBBC_SWORD SWord;
#define SMALL_BITS (MRBBC_VALUE * 8 - 1)
#define SMALL_MAX (((int64_t)1 << (SMALL_BITS - 1)) - 1)
#define SMALL_MIN (-((int64_t)1 << (SMALL_BITS - 1)))
static int tag_of(const MV *v) {
  MRBBC_WORD w = v->w;
  if (w & 1) return MRBBC_INT;
  if ((w & 3) == 2) return MRBBC_SYM;
  if (w == MRBBC_W_NIL) return MRBBC_NIL;
  if (w == MRBBC_W_FALSE) return MRBBC_FALSE;
  if (w == MRBBC_W_TRUE) return MRBBC_TRUE;
  return kind_tag(((const GCHdr *)(uintptr_t)w - 1)->kind);
}
static int64_t int_of(const MV *v) {
  if (v->w & 1) return (int64_t)((SWord)v->w >> 1);
  return *(const int64_t *)(uintptr_t)v->w;
}
static void *ptr_of(const MV *v) { return (void *)(uintptr_t)v->w; }
static int same_value(const MV *a, const MV *b) { return a->w == b->w; }
static MV word_value(MRBBC_WORD w) {
  MV v;
  v.w = w;
  return v;
}
static MV nil_value(void) { return word_value(MRBBC_W_NIL); }
static MV bool_value(int truth) { return word_value(truth ? MRBBC_W_TRUE : MRBBC_W_FALSE); }
static MV ptr_value(int tag, const void *p) {
  (void)tag; /* the object's header has it */
  return word_value((MRBBC_WORD)(uintptr_t)p);
}
static MV int_value(int64_t i) {
  int64_t *b;
  if (i >= SMALL_MIN && i <= SMALL_MAX) return word_value(((MRBBC_WORD)i << 1) | 1);
  b = gc_alloc(GC_INT, sizeof *b); /* a boxed integer */
  *b = i;
  return ptr_value(MRBBC_INT, b);
}
static MV sym_value(long index) { return word_value(((MRBBC_WORD)index << 2) | 2); }
static long sym_index(const MV *v) { return (long)(v->w >> 2); }
#endif

void mrbbc_int_new(MV *dst, long long i) { *dst = int_value((int64_t)i); }

int mrbbc_tag(const MV *v) { return tag_of(v); }

/* Symbols are interned by name: a value holds the index, and the names are the module's static strings. */
static const char **sym_names;
static long sym_count, sym_cap;
static long *sym_table; /* open addressing: index + 1, or 0 for an empty entry */
static long sym_table_cap;

static unsigned long name_hash(const char *s) {
  unsigned long h = 2166136261u;
  for (; *s; s++) h = (h ^ (unsigned char)*s) * 16777619u;
  return h;
}

static void sym_rehash(void) {
  long cap = sym_table_cap ? sym_table_cap * 2 : 64, k;
  long *t = calloc((size_t)cap, sizeof *t);
  if (t == NULL) mrbbc_raise("NoMemoryError", "failed to allocate memory");
  for (k = 0; k < sym_count; k++) {
    unsigned long i = name_hash(sym_names[k]) & (unsigned long)(cap - 1);
    while (t[i]) i = (i + 1) & (unsigned long)(cap - 1);
    t[i] = k + 1;
  }
  free(sym_table);
  sym_table = t;
  sym_table_cap = cap;
}

static long intern(const char *name) {
  unsigned long i;
  if (2 * (sym_count + 1) > sym_table_cap) sym_rehash();
  i = name_hash(name) & (unsigned long)(sym_table_cap - 1);
  for (; sym_table[i]; i = (i + 1) & (unsigned long)(sym_table_cap - 1)) {
    const char *n = sym_names[sym_table[i] - 1];
    if (n == name || strcmp(n, name) == 0) return sym_table[i] - 1;
  }
  if (sym_count == sym_cap) {
    long cap = sym_cap ? sym_cap * 2 : 32;
    const char **p = realloc(sym_names, (size_t)cap * sizeof *p);
    if (p == NULL) mrbbc_raise("NoMemoryError", "failed to allocate memory");
    sym_names = p;
    sym_cap = cap;
  }
  sym_names[sym_count] = name;
  sym_table[i] = sym_count + 1;
  return sym_count++;
}

static const char *sym_of(const MV *v) { return sym_names[sym_index(v)]; }

static MStr *str_of(const MV *v) { return (MStr *)ptr_of(v); }
static MAry *ary_of(const MV *v) { return (MAry *)ptr_of(v); }

static void set_obj(MV *dst, int tag, const void *p) { *dst = ptr_value(tag, p); }

static MStr *new_str_storage(long n) {
  MStr *s;
  if (n < 0 || (uint64_t)n > UINT32_MAX - sizeof(MStr) - 1) mrbbc_raise("ArgumentError", "argument too big");
  s = gc_alloc(GC_STR, sizeof(MStr));
  s->cap = (size_t)n + 1;
  s->p = alloc(s->cap);
  gc_grow(s, s->cap);
  s->len = n;
  s->p[n] = '\0';
  return s;
}

static MV new_str_value(const char *p, long n) {
  MStr *s = new_str_storage(n);
  MV v;
  if (n > 0) memcpy(s->p, p, (size_t)n);
  set_obj(&v, MRBBC_STR, s);
  return v;
}

void mrbbc_set_bool(MV *dst, int truth) { *dst = bool_value(truth); }

void mrbbc_str_new(MV *dst, const char *p, long n) {
  MV v = new_str_value(p, n);
  *dst = v;
}

void mrbbc_sym(MV *dst, const char *name) { *dst = sym_value(intern(name)); }

/* Object, the root class: made on first use (a root of the collector), so that under the 4-byte layout its address is the
 * arena's. */
static MClass *object_cls(void) {
  static MClass *object;
  if (object == NULL) {
    object = gc_alloc(GC_CLS, sizeof *object);
    object->key = object->name = "Object";
  }
  return object;
}

static const char *class_name(const MV *v);

/* The methods and classes of the program (see MDef and MClass above). mrbbc_def and mrbbc_def_in add an entry to the list
 * of Object or of a class, so a redefinition wins. A self call (mrbbc_find) looks in the class of self when self is an
 * object, then in Object. An explicit receiver's call (mrbbc_find_send) looks in the receiver's class only: a top-level
 * method is private, so reaching one of those with an explicit receiver is a NoMethodError. A wrong argument count is an
 * ArgumentError and a name nothing defines a NoMethodError. */
/* A redefinition of a name in the same list takes the entry's place: find_def returns the first entry of a name, so the
 * newest definition is what a lookup gets either way, and a program that defines a method in a loop does not grow the list. */
static void add_def(MDef **head, const char *name, int id, long min, long max, int flags) {
  MDef *d;
  for (d = *head; d != NULL && strcmp(d->name, name) != 0; d = d->next) {
  }
  if (d == NULL) {
    d = gc_alloc(GC_DEF, sizeof *d);
    d->next = *head;
    *head = d;
  }
  d->name = name;
  d->id = id;
  d->min = min;
  d->max = max;
  d->kd = flags & 1;
  d->fast = (flags & 2) != 0;
}

static MDef *find_def(MDef *d, const char *name) {
  for (; d != NULL; d = d->next) {
    if (strcmp(d->name, name) == 0) return d;
  }
  return NULL;
}

/* A count outside min..max is mruby's ArgumentError, whose message names the required count only (vm.c's ENTER gives
 * argnum_error(m1+m2)), even when the method has optional parameters. The keyword hash of a call counts as a positional
 * argument when the method has no keyword parameters (vm.c's check_argument_count and ENTER). */
static int check_arity(const MDef *d, long argc, long kw) {
  /* kw: 0 for no keyword argument, 1 for keywords, 2 for an empty `**h` splat (see mrbbc_kw_flag). Keywords count as a
   * positional argument of a method without keyword parameters; an empty splat does so only for the fast path of ENTER. */
  long count = argc + (kw == 1 && !d->kd ? 1 : 0), given;
  if (kw == 2 && !d->kd && d->fast) count = argc + 1;
  if (count < d->min || (d->max >= 0 && count > d->max)) {
    char msg[128];
    /* the count mruby's message gives (vm.c's argnum_error reads ci->n): a body of required parameters only (the fast path of
     * ENTER, where the count is checked before the keyword hash is counted) and a body with keyword parameters give the
     * positional arguments, and a call of no positional arguments but keywords counts the hash as one; any other body
     * (optional, rest or post parameters) gives the count with the keyword hash */
    if (!d->kd && d->max != d->min) given = count;
    else given = argc + (argc == 0 && kw == 1 ? 1 : 0);
    snprintf(msg, sizeof msg, "wrong number of arguments (given %ld, expected %ld)", given, d->min);
    mrbbc_raise("ArgumentError", msg);
  }
  return d->id;
}

static MClass *cls_of(const MV *v) { return (MClass *)ptr_of(v); }
static MObj *obj_of(const MV *v) { return (MObj *)ptr_of(v); }

/* The first method of the name on c or its superclasses (every chain ends at Object). where gets the class it is found in. */
static MDef *find_chain(MClass *c, const char *name, MClass **where) {
  for (; c != NULL; c = c->super) {
    MDef *d = find_def(c->defs, name);
    if (d != NULL) {
      if (where != NULL) *where = c;
      return d;
    }
  }
  return NULL;
}

void mrbbc_def(const char *name, int id, long min, long max, int flags) {
  add_def(&object_cls()->defs, name, id, min, max, flags);
  set_owner(id, object_cls());
}

void mrbbc_def_in(const MV *cls, const char *name, int id, long min, long max, int flags) {
  if (tag_of(cls) != MRBBC_CLS) mrbbc_raise("TypeError", "a method is defined on a class");
  add_def(&cls_of(cls)->defs, name, id, min, max, flags);
  set_owner(id, cls_of(cls));
}

int mrbbc_find(const MV *self, const char *name, long argc, long kw) {
  MClass *start = tag_of(self) == MRBBC_OBJ ? obj_of(self)->cls : object_cls();
  MDef *d = find_chain(start, name, NULL);
  if (d != NULL) return check_arity(d, argc, kw);
  {
    char msg[256];
    const char *cname = tag_of(self) == MRBBC_OBJ ? obj_of(self)->cls->name : "Object";
    snprintf(msg, sizeof msg, "undefined method '%s' for %s", name, cname);
    mrbbc_raise("NoMethodError", msg);
  }
}

static void private_error(const MV *recv, const char *name) __attribute__((noreturn));

static void private_error(const MV *recv, const char *name) {
  char msg[256];
  snprintf(msg, sizeof msg, "private method '%s' called for %s", name, class_name(recv));
  mrbbc_raise("NoMethodError", msg);
}

int mrbbc_find_send(const MV *recv, const char *name, long argc, long kw) {
  if (tag_of(recv) == MRBBC_OBJ) {
    MClass *where = NULL;
    MDef *d = find_chain(obj_of(recv)->cls, name, &where);
    if (d == NULL) return -1;
    if (where == object_cls()) private_error(recv, name);  /* a top-level def is a private method of Object */
    return check_arity(d, argc, kw);
  }
  if (tag_of(recv) == MRBBC_CLS && find_def(object_cls()->defs, name) != NULL) private_error(recv, name);
  return -1;
}

int mrbbc_find_super(const MV *self, int method, const char *name, long argc, long kw) {
  MClass *owner = method >= 0 && method < owners_n ? owners[method] : NULL;
  MDef *d = owner != NULL ? find_chain(owner->super, name, NULL) : NULL;
  if (d != NULL) return check_arity(d, argc, kw);
  if (strcmp(name, "initialize") == 0) {
    if (argc + (kw == 1) != 0) {
      char msg[128];
      snprintf(msg, sizeof msg, "wrong number of arguments (given %ld, expected 0)", argc + (kw == 1));
      mrbbc_raise("ArgumentError", msg);
    }
    return -1;
  }
  {
    /* the methods of Object, Kernel and Comparable that mruby has builtin: not lowered, so not a NoMethodError */
    static const char *const builtins[] = {
        "to_s", "inspect", "==", "!=", "!", "equal?", "eql?", "hash", "class", "nil?", "is_a?", "kind_of?", "instance_of?",
        "respond_to?", "send", "method", "methods", "freeze", "frozen?", "dup", "clone", "object_id", "p", "puts", "print",
        "raise", "loop", "format", "sprintf", "lambda", "proc", "block_given?", "require"};
    char msg[256];
    const char *cname = tag_of(self) == MRBBC_OBJ ? obj_of(self)->cls->name : "Object";
    size_t k;
    for (k = 0; k < sizeof builtins / sizeof builtins[0]; k++) {
      if (strcmp(builtins[k], name) == 0) {
        snprintf(msg, sizeof msg, "super of the builtin method '%s' is not lowered yet", name);
        mrbbc_raise("NotImplementedError", msg);
      }
    }
    snprintf(msg, sizeof msg, "super: no superclass method '%s' for %s", name, cname);
    mrbbc_raise("NoMethodError", msg);
  }
}

/* SUPER and ARGARY outside a method (the main program, a class body, or a block of one): vm.c raises NoMethodError. */
void mrbbc_no_super(void) { mrbbc_raise("NoMethodError", "super called outside of method"); }

void mrbbc_super_nil(MV *dst) {
  *dst = nil_value();
}

int mrbbc_find_init(const MV *obj, long argc, long kw) {
  MDef *d = find_chain(obj_of(obj)->cls, "initialize", NULL);
  if (d != NULL) return check_arity(d, argc, kw);
  if (argc + (kw == 1) != 0) {
    char msg[128];
    snprintf(msg, sizeof msg, "wrong number of arguments (given %ld, expected 0)", argc + (kw == 1));
    mrbbc_raise("ArgumentError", msg);
  }
  return -1;
}

static MClass *find_class(const char *key) {
  MClass *c;
  for (c = class_registry; c != NULL; c = c->next) {
    if (strcmp(c->key, key) == 0) return c;
  }
  return NULL;
}

/* The names of the classes and modules of mruby's core: the program does not reopen or read them (not lowered). */
static int core_name(const char *name) {
  static const char *const names[] = {
      "Object",    "BasicObject", "Module",    "Class",          "Kernel",    "Comparable", "Enumerable",
      "NilClass",  "TrueClass",   "FalseClass", "Integer",        "Float",     "String",     "Symbol",
      "Array",     "Hash",        "Range",     "Proc",           "Exception", "StandardError", "NameError",
      "NoMethodError", "ArgumentError", "TypeError", "ZeroDivisionError", "IndexError", "RuntimeError",
      "LocalJumpError", "NotImplementedError", "Math", "Struct", "Time", "File", "IO", "Dir"};
  size_t i;
  for (i = 0; i < sizeof names / sizeof names[0]; i++) {
    if (strcmp(names[i], name) == 0) return 1;
  }
  return 0;
}

void mrbbc_class(MV *dst, const MV *cbase, const MV *super, const char *name, const MV *target) {
  MClass *outer = object_cls(), *c, *sup = NULL;
  if (strcmp(name, "File") == 0 || strcmp(name, "IO") == 0 || strcmp(name, "Dir") == 0)
    mrbbc_raise("NotImplementedError", "reopening a host class is not lowered yet");
  if (tag_of(super) != MRBBC_NIL) {
    char msg[160];
    if (tag_of(super) != MRBBC_CLS) {
      Buf b = {NULL, 0, 0};
      if (tag_of(super) == MRBBC_OBJ) mrbbc_raise("NotImplementedError", "a superclass that is an instance is not lowered yet");
      inspect_value(&b, super);
      snprintf(msg, sizeof msg, "superclass must be a Class (%s given)", b.p);
      free(b.p);
      mrbbc_raise("TypeError", msg);
    }
    sup = cls_of(super);
  }
  if (tag_of(cbase) == MRBBC_CLS) {
    outer = cls_of(cbase);
  } else if (tag_of(target) == MRBBC_CLS) {
    outer = cls_of(target);
  }
  c = find_class(name);
  if (c == NULL) {
    if (core_name(name)) mrbbc_raise("NotImplementedError", "reopening a core class is not lowered yet");
    c = gc_alloc(GC_CLS, sizeof *c);
    c->key = name;
    if (outer == object_cls()) {
      c->name = name;
    } else {
      size_t n = strlen(outer->name) + 2 + strlen(name) + 1;
      char *full = alloc(n);
      snprintf(full, n, "%s::%s", outer->name, name);
      c->name = full;
      c->owned_name = full;
      gc_grow(c, n);
    }
    c->defs = NULL;
    c->ivars = NULL;
    c->super = sup != NULL ? sup : object_cls();
    c->next = class_registry;
    class_registry = c;
  } else if (sup != NULL && c->super != sup) {
    char msg[256];
    snprintf(msg, sizeof msg, "superclass mismatch for %s", c->name);
    mrbbc_raise("TypeError", msg);
  }
  set_obj(dst, MRBBC_CLS, c);
}

void mrbbc_object_class(MV *dst) { set_obj(dst, MRBBC_CLS, object_cls()); }

void mrbbc_getconst(MV *dst, const char *name) {
  if (host_constant(dst, name)) return;
  MClass *c = find_class(name);
  if (c == NULL && strcmp(name, "Object") == 0) c = object_cls();
  if (c != NULL) {
    set_obj(dst, MRBBC_CLS, c);
    return;
  }
  if (core_name(name)) mrbbc_raise("NotImplementedError", "a core constant is not lowered yet");
  {
    char msg[256];
    snprintf(msg, sizeof msg, "uninitialized constant %s", name);
    mrbbc_raise("NameError", msg);
  }
}

void mrbbc_alloc(MV *dst, const MV *cls) {
  MObj *o;
  if (tag_of(cls) != MRBBC_CLS) mrbbc_no_method(cls, "new");
  if (strcmp(cls_of(cls)->name, "IO") == 0 || strcmp(cls_of(cls)->name, "File") == 0 || strcmp(cls_of(cls)->name, "Dir") == 0)
    mrbbc_raise("NotImplementedError", "constructing host handles is not lowered yet");
  o = gc_alloc(GC_OBJ, sizeof *o);
  o->cls = cls_of(cls);
  o->ivars = NULL;
  set_obj(dst, MRBBC_OBJ, o);
}

static MIvar **ivars_of(const MV *self) {
  if (tag_of(self) == MRBBC_OBJ) return &obj_of(self)->ivars;
  if (tag_of(self) == MRBBC_CLS) return &cls_of(self)->ivars;
  return NULL;
}

void mrbbc_getiv(MV *dst, const MV *self, const char *name) {
  MIvar **head = ivars_of(self), *v;
  MV out;
  out = nil_value();
  if (head != NULL) {
    for (v = *head; v != NULL; v = v->next) {
      if (strcmp(v->name, name) == 0) {
        out = v->val;
        break;
      }
    }
  }
  *dst = out;
}

void mrbbc_setiv(const MV *self, const char *name, const MV *val) {
  MIvar **head = ivars_of(self), *v;
  if (head == NULL) mrbbc_raise("NotImplementedError", "an instance variable of this value is not lowered yet");
  for (v = *head; v != NULL; v = v->next) {
    if (strcmp(v->name, name) == 0) {
      v->val = *val;
      return;
    }
  }
  v = gc_alloc(GC_IVAR, sizeof *v);
  v->name = name;
  v->val = *val;
  v->next = *head;
  *head = v;
}


/* A block value (MRBBC_BLK) points to the Clo that mrbbc_block makes, a collected object (the clo argument, the slot the
 * lowering reserves, is not used). A closure is yielded while its frame is alive: a block is passed to a method and not
 * kept (a block parameter is refused). home is the frame of the method the block was made in (the frame a return out of
 * the block leaves). */
typedef struct Clo {
  long id;
  MV self;
  MV *frame;
  MV *home;
  /* The frames of the enclosing scopes past the creator: disp[L-1] is the frame at upvar level L >= 1 (level 0 is frame, the
   * frame the block was made in). A block made by a method or the main program has none. A block made by a block takes its
   * creator's own creator frame (the creator's %3) first, then the creator's disp (see mrbbc_block_nested). */
  MV *disp[MRBBC_MAX_DEPTH];
} Clo;

static Clo *clo_of(const MV *v) { return (Clo *)ptr_of(v); }

void mrbbc_block(MV *dst, void *clo, long id, const MV *self, MV *frame, MV *home) {
  Clo *c = gc_alloc(GC_CLO, sizeof(Clo));
  (void)clo;
  c->id = id;
  c->self = *self;
  c->frame = frame;
  c->home = home;
  set_obj(dst, MRBBC_BLK, c);
}

/* A block made by a block: outer is the creator's %3 (the frame the creator was made in, the level 1 frame of the new block)
 * and pdisp is the creator's disp, of nd entries (its depth minus one): the new block's disp is outer, then pdisp. */
void mrbbc_block_nested(MV *dst, void *clo, long id, const MV *self, MV *frame, MV *home, MV *outer, const MV *pdisp,
                        long nd) {
  Clo *c;
  long k;
  if (nd + 1 > MRBBC_MAX_DEPTH) mrbbc_raise("NotImplementedError", "a block nested too deep is not lowered yet");
  mrbbc_block(dst, clo, id, self, frame, home);
  c = clo_of(dst);
  c->disp[0] = outer;
  for (k = 0; k < nd; k++) c->disp[k + 1] = ((MV *const *)pdisp)[k];
}

/* The disp array of a block value (its frames past the creator), for the block's function. */
MV *mrbbc_blk_disp(const MV *blk) {
  if (tag_of(blk) != MRBBC_BLK) mrbbc_raise("LocalJumpError", "unexpected yield");
  return (MV *)clo_of(blk)->disp;
}

/* The frame at upvar level k+1 of a block whose disp is disp (see Clo). */
MV *mrbbc_upframe(const MV *disp, long k) { return ((MV *const *)disp)[k]; }

long mrbbc_blk_id(const MV *blk) {
  if (tag_of(blk) != MRBBC_BLK) mrbbc_raise("LocalJumpError", "unexpected yield");
  return clo_of(blk)->id;
}

MV *mrbbc_blk_frame(const MV *blk) {
  if (tag_of(blk) != MRBBC_BLK) mrbbc_raise("LocalJumpError", "unexpected yield");
  return clo_of(blk)->frame;
}

MV *mrbbc_blk_home(const MV *blk) {
  if (tag_of(blk) != MRBBC_BLK) mrbbc_raise("LocalJumpError", "unexpected yield");
  return clo_of(blk)->home;
}

/* A return out of a block. The value is pending for home: every call on the way returns at once (mrbbc_unwinding is
 * checked after each call of a method or a block) until the function whose frame is home takes it (mrbbc_unwind_take),
 * and that function returns the value. */
static int unwind_pending = 0;
static int unwind_break = 0; /* the pending exit is a break (its home is the frame of the call the block was passed to) */
static MV *unwind_home = NULL;
static MV unwind_value;

void mrbbc_return_block(const MV *value, MV *home) {
  unwind_pending = 1;
  unwind_break = 0;
  unwind_home = home;
  unwind_value = *value;
}

/* A break out of a block: the call that the block was passed to (the frame that made the block, home) returns value. */
void mrbbc_break(const MV *value, MV *home) {
  unwind_pending = 1;
  unwind_break = 1;
  unwind_home = home;
  unwind_value = *value;
}

int mrbbc_unwinding(void) { return unwind_pending; }

void mrbbc_unwind_take(MV *ret, MV *frame) {
  if (unwind_pending && !unwind_break && unwind_home == frame) {
    *ret = unwind_value;
    unwind_pending = 0;
  }
}

/* Takes a pending break whose home is frame: dst gets its value, and the caller goes on after the call. */
int mrbbc_break_take(MV *dst, MV *frame) {
  if (unwind_pending && unwind_break && unwind_home == frame) {
    *dst = unwind_value;
    unwind_pending = 0;
    unwind_break = 0;
    return 1;
  }
  return 0;
}

void mrbbc_ary_elt(MV *dst, const MV *ary, long i) {
  const MAry *a = ary_of(ary);
  MV out;
  out = nil_value();
  if (i < a->len) out = a->items[i];
  *dst = out;
}

/* OP_AREF as vm.c does it: an array gives its element i (nil past its end); any other value is itself at i = 0 and nil
 * otherwise (the destructuring `a, b = x` of a value that is not an array). */
void mrbbc_aref(MV *dst, const MV *v, long i) {
  MV src = *v;
  if (tag_of(&src) == MRBBC_ARY) {
    mrbbc_ary_elt(dst, &src, i);
    return;
  }
  if (i == 0) *dst = src;
  else {
    *dst = nil_value();
  }
}

void mrbbc_blk_args(MV *argv, const MV *blk) {
  if (tag_of(blk) != MRBBC_BLK) mrbbc_raise("LocalJumpError", "unexpected yield");
  argv[0] = clo_of(blk)->self;
}

void mrbbc_blk_load(MV *dst, const MV *blk) {
  if (tag_of(blk) == MRBBC_NIL) mrbbc_raise("LocalJumpError", "unexpected yield");
  *dst = *blk;
}

void mrbbc_blk_given(MV *dst, const MV *blk) {
  *dst = bool_value(tag_of(blk) != MRBBC_NIL);
}

/* The class of a value, as NoMethodError and ArgumentError name it. */
static const char *class_name(const MV *v) {
  switch (tag_of(v)) {
    case MRBBC_NIL: return "NilClass";
    case MRBBC_TRUE: return "TrueClass";
    case MRBBC_FALSE: return "FalseClass";
    case MRBBC_STR: return "String";
    case MRBBC_ARY: return "Array";
    case MRBBC_HASH: return "Hash";
    case MRBBC_SYM: return "Symbol";
    case MRBBC_OBJ: return obj_of(v)->cls->name;
    case MRBBC_CLS: return "Class";
    case MRBBC_BLK: return "Proc";
    default: return "Integer";
  }
}

/* What a TypeError shows for an operand: nil, true and false by their names, anything else by its class. */
static const char *type_text(const MV *v) {
  switch (tag_of(v)) {
    case MRBBC_NIL: return "nil";
    case MRBBC_TRUE: return "true";
    case MRBBC_FALSE: return "false";
    default: return class_name(v);
  }
}

static const char *op_method(int op) {
  switch (op) {
    case MRBBC_OP_ADD: return "+";
    case MRBBC_OP_SUB: return "-";
    case MRBBC_OP_MUL: return "*";
    case MRBBC_OP_DIV: return "/";
    case MRBBC_OP_LT: return "<";
    case MRBBC_OP_LE: return "<=";
    case MRBBC_OP_GT: return ">";
    case MRBBC_OP_GE: return ">=";
    case MRBBC_OP_NEQ: return "!=";
    default: return "==";
  }
}

static void no_method(const char *name, const MV *recv) __attribute__((noreturn));

static void no_method(const char *name, const MV *recv) {
  char msg[160];
  snprintf(msg, sizeof msg, "undefined method '%s' for %s", name, class_name(recv));
  mrbbc_raise("NoMethodError", msg);
}

void mrbbc_no_method(const MV *recv, const char *name) { no_method(name, recv); }

/* The program's method of the name for an instance, found on its class and the superclasses (-1 when there is none, and
 * for any other value: only an instance of a program class has methods of the program). A wrong count is an ArgumentError. */
static int user_method(const MV *recv, const char *name, long argc) {
  MDef *d;
  if (tag_of(recv) != MRBBC_OBJ) return -1;
  d = find_chain(obj_of(recv)->cls, name, NULL);
  return d == NULL ? -1 : check_arity(d, argc, 0);
}

/* Calls the program's method id on recv, with the argument arg (none when arg is NULL). The result goes to ret, which may
 * be recv's own slot: the arguments are copied first. */
static void call_user(MV *ret, int id, const MV *recv, const MV *arg) {
  MV argv[2], blk;
  argv[0] = *recv;
  argv[1] = arg != NULL ? *arg : *recv;
  blk = nil_value();
  mrbbc_user_call(id, ret, argv, &blk, arg != NULL ? 1 : 0);
}

static void buf_put(Buf *b, const char *s, size_t n) {
  if (b->n + n + 1 > b->cap) {
    size_t cap = b->cap ? b->cap : 64;
    char *p;
    while (b->n + n + 1 > cap) cap *= 2;
    p = alloc(cap);
    if (b->n) memcpy(p, b->p, b->n);
    free(b->p);
    b->p = p;
    b->cap = cap;
  }
  if (n) memcpy(b->p + b->n, s, n);
  b->n += n;
  b->p[b->n] = '\0';
}

static void buf_str(Buf *b, const char *s) { buf_put(b, s, strlen(s)); }

static void buf_char(Buf *b, char c) { buf_put(b, &c, 1); }

/* String#inspect of this build (byte strings): the named escapes, \# before #{ #$ #@, \xHH for other bytes that are
 * not printable ASCII. */
static void inspect_bytes(Buf *b, const char *s, long n) {
  long k;
  buf_char(b, '"');
  for (k = 0; k < n; k++) {
    unsigned char c = (unsigned char)s[k];
    switch (c) {
      case '"': buf_str(b, "\\\""); break;
      case '\\': buf_str(b, "\\\\"); break;
      case '\n': buf_str(b, "\\n"); break;
      case '\r': buf_str(b, "\\r"); break;
      case '\t': buf_str(b, "\\t"); break;
      case '\f': buf_str(b, "\\f"); break;
      case '\v': buf_str(b, "\\v"); break;
      case '\b': buf_str(b, "\\b"); break;
      case '\a': buf_str(b, "\\a"); break;
      case 0x1b: buf_str(b, "\\e"); break;
      case '#':
        if (k + 1 < n && (s[k + 1] == '{' || s[k + 1] == '$' || s[k + 1] == '@')) buf_str(b, "\\#");
        else buf_char(b, '#');
        break;
      default:
        if (c >= 0x20 && c < 0x7f) {
          buf_char(b, (char)c);
        } else {
          char h[8];
          snprintf(h, sizeof h, "\\x%02x", (unsigned)c);
          buf_str(b, h);
        }
    }
  }
  buf_char(b, '"');
}

/* The arrays being inspected, so that an array that contains itself prints as mruby prints it ("[...]"). */
#define INSPECT_DEPTH 64
static const MAry *inspecting[INSPECT_DEPTH];
static int inspect_depth;

static void inspect_value(Buf *b, const MV *v) {
  switch (tag_of(v)) {
    case MRBBC_NIL: buf_str(b, "nil"); break;
    case MRBBC_TRUE: buf_str(b, "true"); break;
    case MRBBC_FALSE: buf_str(b, "false"); break;
    case MRBBC_INT: {
      char h[32];
      snprintf(h, sizeof h, "%lld", (long long)int_of(v));
      buf_str(b, h);
      break;
    }
    case MRBBC_STR: inspect_bytes(b, str_of(v)->p, str_of(v)->len); break;
    case MRBBC_SYM:
      buf_char(b, ':');
      buf_str(b, sym_of(v));
      break;
    case MRBBC_CLS: buf_str(b, cls_of(v)->name); break;
    case MRBBC_OBJ: {
      /* the program's inspect, as the p of an instance calls it; the default one prints an address, which is not lowered */
      MV r;
      MV s;
      int pm;
      int id = user_method(v, "inspect", 0);
      if (id < 0) mrbbc_raise("NotImplementedError", "inspect of an instance is not lowered yet");
      call_user(&r, id, v, NULL);
      pm = gc_protect(&r); /* to_s_string may allocate */
      s = to_s_string(&r);
      gc_unprotect(pm);
      buf_put(b, str_of(&s)->p, (size_t)str_of(&s)->len);
      break;
    }
    case MRBBC_ARY: {
      const MAry *a = ary_of(v);
      long k;
      int i, seen = 0, pushed;
      for (i = 0; i < inspect_depth; i++) {
        if (inspecting[i] == a) seen = 1;
      }
      if (seen) {
        buf_str(b, "[...]");
        break;
      }
      buf_char(b, '[');
      pushed = inspect_depth < INSPECT_DEPTH;
      if (pushed) inspecting[inspect_depth++] = a;
      for (k = 0; k < a->len; k++) {
        if (k) buf_str(b, ", ");
        inspect_value(b, &a->items[k]);
      }
      if (pushed) inspect_depth--;
      buf_char(b, ']');
      break;
    }
    case MRBBC_HASH: {
      /* mruby 4's form: `{k: 1, "s" => 2}` (a symbol key is written as its name and a colon) */
      const MHash *h = hash_of(v);
      long k;
      if (h->len == 0) {
        buf_str(b, "{}");
        break;
      }
      buf_char(b, '{');
      for (k = 0; k < h->len; k++) {
        if (k) buf_str(b, ", ");
        if (tag_of(&h->keys[k]) == MRBBC_SYM) {
          buf_str(b, sym_of(&h->keys[k]));
          buf_str(b, ": ");
        } else {
          inspect_value(b, &h->keys[k]);
          buf_str(b, " => ");
        }
        inspect_value(b, &h->vals[k]);
      }
      buf_char(b, '}');
      break;
    }
    default: mrbbc_raise("RuntimeError", "unknown value tag");
  }
}

void mrbbc_print(const MV *v) {
  Buf b = {NULL, 0, 0};
  inspect_value(&b, v);
  buf_char(&b, '\n');
  fwrite(b.p, 1, b.n, stdout);
  free(b.p);
}

/* a == b (mruby's ==, for these values). Arrays compare element by element. An instance is equal to itself (rb_equal checks
 * identity first), and otherwise its class's == decides when the program defines one (a truthy result is equal). */
static int value_eq(const MV *a, const MV *b) {
  if (tag_of(a) == MRBBC_OBJ) {
    MV r;
    int id;
    if (same_value(a, b)) return 1;
    id = user_method(a, "==", 1);
    if (id < 0) return 0;
    call_user(&r, id, a, b);
    return tag_of(&r) != MRBBC_NIL && tag_of(&r) != MRBBC_FALSE;
  }
  if (tag_of(a) != tag_of(b)) return 0;
  switch (tag_of(a)) {
    case MRBBC_HASH: mrbbc_raise("NotImplementedError", "== of a Hash is not lowered yet");
    case MRBBC_INT: return int_of(a) == int_of(b);
    case MRBBC_STR: return str_of(a)->len == str_of(b)->len && memcmp(str_of(a)->p, str_of(b)->p, (size_t)str_of(a)->len) == 0;
    case MRBBC_SYM: return strcmp(sym_of(a), sym_of(b)) == 0;
    case MRBBC_CLS: return same_value(a, b);  /* identity */
    case MRBBC_ARY: {
      const MAry *x = ary_of(a), *y = ary_of(b);
      long k;
      if (x == y) return 1;
      if (x->len != y->len) return 0;
      for (k = 0; k < x->len; k++) {
        if (!value_eq(&x->items[k], &y->items[k])) return 0;
      }
      return 1;
    }
    default: return 1;  /* nil, true, false */
  }
}

/* The order of two strings (memcmp, then the lengths), as String#<=> gives its sign. */
static int str_order(const MV *a, const MV *b) {
  long n = str_of(a)->len < str_of(b)->len ? str_of(a)->len : str_of(b)->len;
  int c = n ? memcmp(str_of(a)->p, str_of(b)->p, (size_t)n) : 0;
  if (c) return c;
  return str_of(a)->len < str_of(b)->len ? -1 : str_of(a)->len > str_of(b)->len;
}

static int compare_result(int op, int c) {
  switch (op) {
    case MRBBC_OP_LT: return c < 0;
    case MRBBC_OP_LE: return c <= 0;
    case MRBBC_OP_GT: return c > 0;
    default: return c >= 0;  /* GE */
  }
}

/* Array storage: room for at least need items. */
static void ary_reserve(MAry *a, long need) {
  if (need <= a->cap) return;
  long cap = a->cap ? a->cap : 4;
  MV *items;
  while (cap < need) cap *= 2;
  items = realloc(a->items, (size_t)cap * sizeof(MV));
  if (items == NULL) mrbbc_raise("NoMemoryError", "failed to allocate memory");
  gc_grow(a, (size_t)(cap - a->cap) * sizeof(MV));
  a->items = items;
  a->cap = cap;
}

static MV new_ary_value(long cap) {
  MAry *a = gc_alloc(GC_ARY, sizeof(MAry));
  MV v;
  a->len = 0;
  a->cap = 0;
  a->items = NULL;
  ary_reserve(a, cap > 0 ? cap : 0);
  set_obj(&v, MRBBC_ARY, a);
  return v;
}

void mrbbc_ary_new(MV *dst, long cap) {
  MV v = new_ary_value(cap);
  *dst = v;
}

void mrbbc_ary_push(MV *ary, const MV *v) {
  MAry *a;
  MV item = *v;
  if (tag_of(ary) != MRBBC_ARY) mrbbc_raise("TypeError", "expected Array");
  a = ary_of(ary);
  ary_reserve(a, a->len + 1);
  a->items[a->len++] = item;
}


/* A splat (vm.c's mrb_ary_splat): an array is copied, nil is the empty array, and any other value is the array of itself,
 * except that an instance of a program class with a to_a of its own gives that. dst may be v. */
void mrbbc_splat(MV *dst, const MV *v) {
  MV src = *v, out;
  int id = tag_of(&src) == MRBBC_OBJ ? user_method(&src, "to_a", 0) : -1;
  long k;
  if (tag_of(&src) == MRBBC_ARY) {
    const MAry *a = ary_of(&src);
    out = new_ary_value(a->len);
    for (k = 0; k < a->len; k++) mrbbc_ary_push(&out, &a->items[k]);
  } else if (tag_of(&src) == MRBBC_NIL) {
    out = new_ary_value(0);
  } else if (id >= 0) {
    MV r;
    int pm;
    call_user(&r, id, &src, NULL);
    if (tag_of(&r) != MRBBC_ARY) mrbbc_raise("TypeError", "can't convert to Array");
    pm = gc_protect(&r); /* the array the new one copies */
    out = new_ary_value(ary_of(&r)->len);
    gc_unprotect(pm);
    for (k = 0; k < ary_of(&r)->len; k++) mrbbc_ary_push(&out, &ary_of(&r)->items[k]);
  } else {
    out = new_ary_value(1);
    mrbbc_ary_push(&out, &src);
  }
  *dst = out;
}

/* ARYCAT: dst is an array to which the splat of src is appended, or the splat itself when dst is nil. */
void mrbbc_ary_cat(MV *dst, const MV *src) {
  MV s;
  long k;
  mrbbc_splat(&s, src);
  if (tag_of(dst) == MRBBC_NIL) {
    *dst = s;
    return;
  }
  if (tag_of(dst) != MRBBC_ARY) mrbbc_raise("TypeError", "expected Array");
  for (k = 0; k < ary_of(&s)->len; k++) mrbbc_ary_push(dst, &ary_of(&s)->items[k]);
}

/* The argument vector of a splat call: self, then the elements of the array (its length is the count). A collected object of
 * its own (GC_VEC, traced as its elements): the caller's pointer is its address, and it is unreachable once the call is made. */
MV *mrbbc_splat_argv(const MV *self, const MV *ary) {
  const MAry *a;
  MV *argv;
  long k, n;
  if (tag_of(ary) != MRBBC_ARY) mrbbc_raise("TypeError", "expected Array");
  a = ary_of(ary);
  n = a->len;
  argv = gc_alloc(GC_VEC, (size_t)(n + 1) * sizeof(MV));
  argv[0] = *self;
  for (k = 0; k < n; k++) argv[k + 1] = a->items[k];
  /* the caller holds the vector only in a register: it is a root of the caller's frame until the frame's next splat call
   * (a frame makes one call at a time) or its return */
  if (gc_top != NULL) gc_top->pin = argv;
  return argv;
}

long mrbbc_ary_len(const MV *ary) {
  if (tag_of(ary) != MRBBC_ARY) mrbbc_raise("TypeError", "expected Array");
  return ary_of(ary)->len;
}

/* The bind of the parameters (see mrbbc_bind in mrbrt.h). This is vm.c's ENTER: the arguments are src[0..n), with
 * n = argc (plus the keyword hash, src[argc], when it counts as positional), and a block's one array argument is splatted
 * when two or more parameters take it. A count short of the required ones leaves nil (a block) or is checked by the caller
 * (a method). The optional parameters that are given are the first ones after the required; the rest takes the middle, and
 * the post parameters the last m2 of the arguments. */
long mrbbc_bind(MV *r1, const MV *argv, long argc, long kw, long m1, long o, long r, long m2, long kd, long strict, long fast) {
  const long len = m1 + o + r + m2;
  const MV *src = argv + 1;
  long n = argc, k, mlen, g;
  if (!strict && len >= 2 && argc == 1 && tag_of(&argv[1]) == MRBBC_ARY) {
    src = ary_of(&argv[1])->items;
    n = ary_of(&argv[1])->len;
  } else if (!kd && (kw == 1 || (kw == 2 && fast))) {
    /* the keyword hash is the last positional argument of a method without keyword parameters (an empty `**h` one only on
     * the fast path of ENTER) */
    n = argc + 1;
  }
  for (k = 0; k < len + kd; k++) r1[k] = nil_value();
  if (n < len) {
    mlen = m2;
    if (n < m1 + m2) mlen = m1 < n ? n - m1 : 0;
    for (k = 0; k < n - mlen; k++) r1[k] = src[k];
    for (k = 0; k < mlen; k++) r1[len - m2 + k] = src[n - mlen + k];
    if (r) {
      MV rest = new_ary_value(0);
      r1[m1 + o] = rest;
    }
    g = n - m1 - m2;
  } else {
    long rnum = n - m1 - o - m2;
    for (k = 0; k < m1 + o; k++) r1[k] = src[k];
    if (r) {
      MV rest = new_ary_value(rnum);
      for (k = 0; k < rnum; k++) mrbbc_ary_push(&rest, &src[m1 + o + k]);
      r1[m1 + o] = rest;
    }
    for (k = 0; k < m2; k++) r1[len - m2 + k] = src[m1 + o + rnum + k];
    g = o;
  }
  if (g < 0) g = 0;
  if (g > o) g = o;
  if (kd) {
    /* the keyword hash: the call's, or a new empty one */
    if (kw) r1[len] = src[argc];
    else mrbbc_hash_new(&r1[len], 0);
  }
  keep_alive(argv);  /* src points into argv (or into the array argv[1]), and the rest arrays above may collect */
  return g;
}

/* KEY_P, KARG and KEYEND on the kdict, a hash of symbols by their names. */
static MHash *hash_of(const MV *v) { return (MHash *)ptr_of(v); }


static long hash_index(const MHash *h, const MV *key) {
  long k;
  for (k = 0; k < h->len; k++) {
    const MV *x = &h->keys[k];
    if (tag_of(x) != tag_of(key)) continue;
    switch (tag_of(key)) {
      case MRBBC_SYM:
        if (strcmp(sym_of(x), sym_of(key)) == 0) return k;
        break;
      case MRBBC_INT:
        if (int_of(x) == int_of(key)) return k;
        break;
      case MRBBC_STR:
        if (str_of(x)->len == str_of(key)->len && memcmp(str_of(x)->p, str_of(key)->p, (size_t)str_of(key)->len) == 0) return k;
        break;
      case MRBBC_NIL:
      case MRBBC_TRUE:
      case MRBBC_FALSE: return k;
      default:
        if (same_value(x, key)) return k;
        break;
    }
  }
  return -1;
}

static void hash_check(const MV *v) {
  if (tag_of(v) != MRBBC_HASH) mrbbc_raise("TypeError", "a keyword argument hash is expected");
}

void mrbbc_key_p(MV *dst, const MV *kdict, const char *name) {
  MV key;
  hash_check(kdict);
  mrbbc_sym(&key, name);
  *dst = bool_value(hash_index(hash_of(kdict), &key) >= 0);
}

void mrbbc_karg(MV *dst, const MV *kdict, const char *name) {
  MHash *h;
  MV key;
  long k;
  hash_check(kdict);
  h = hash_of(kdict);
  mrbbc_sym(&key, name);
  k = hash_index(h, &key);
  if (k < 0) {
    char msg[160];
    snprintf(msg, sizeof msg, "missing keyword: %s", name);
    mrbbc_raise("ArgumentError", msg);
  }
  *dst = h->vals[k];
  memmove(&h->keys[k], &h->keys[k + 1], (size_t)(h->len - k - 1) * sizeof(MV));
  memmove(&h->vals[k], &h->vals[k + 1], (size_t)(h->len - k - 1) * sizeof(MV));
  h->len--;
}

void mrbbc_keyend(const MV *kdict) {
  const MHash *h;
  char msg[160];
  hash_check(kdict);
  h = hash_of(kdict);
  if (h->len == 0) return;
  /* vm.c's KEYEND formats the first key with %v (its to_s): a symbol's name */
  if (tag_of(&h->keys[0]) == MRBBC_SYM) snprintf(msg, sizeof msg, "unknown keyword: %s", sym_of(&h->keys[0]));
  else snprintf(msg, sizeof msg, "unknown keyword");
  mrbbc_raise("ArgumentError", msg);
}

void mrbbc_hash_new(MV *dst, long cap) {
  MHash *h = gc_alloc(GC_HASH, sizeof *h);
  MV v;
  h->len = 0;
  h->cap = cap > 0 ? cap : 0;
  h->keys = alloc((size_t)(h->cap + 1) * sizeof(MV));
  h->vals = alloc((size_t)(h->cap + 1) * sizeof(MV));
  gc_grow(h, (size_t)(h->cap + 1) * 2 * sizeof(MV));
  set_obj(&v, MRBBC_HASH, h);
  *dst = v;
}

static void hash_grow(MHash *h) {
  long oldcap;
  if (h->len < h->cap) return;
  oldcap = h->cap;
  h->cap = h->cap ? h->cap * 2 : 4;
  h->keys = realloc(h->keys, (size_t)(h->cap + 1) * sizeof(MV));
  h->vals = realloc(h->vals, (size_t)(h->cap + 1) * sizeof(MV));
  if (h->keys == NULL || h->vals == NULL) mrbbc_raise("NoMemoryError", "failed to allocate memory");
  gc_grow(h, (size_t)(h->cap - oldcap) * 2 * sizeof(MV));
}

void mrbbc_hash_set(MV *hash, const MV *key, const MV *value) {
  MHash *h;
  long k;
  MV roots[4];
  MrbbcGCFrame frame;
  hash_check(hash);
  mrbbc_gc_enter(&frame, roots, 4);
  roots[0] = *hash;
  roots[1] = *key;
  roots[2] = *value;
  h = hash_of(&roots[0]);
  k = hash_index(h, &roots[1]);
  if (k < 0) {
    /* mruby snapshots a String key. Mutating the caller's alias must not rename an entry. */
    roots[3] = tag_of(&roots[1]) == MRBBC_STR ? new_str_value(str_of(&roots[1])->p, str_of(&roots[1])->len) : roots[1];
    hash_grow(h);
    h->keys[h->len] = roots[3];
    h->vals[h->len] = roots[2];
    h->len++;
  } else {
    h->vals[k] = roots[2];
  }
  mrbbc_gc_leave(&frame);
}

/* HASHCAT (`**h` in a call): the pairs of src are set into hash, a later key taking the value (vm.c's mrb_hash_merge). A
 * value that is not a hash is a TypeError: nil and the others alike (the program defines no to_hash, see the lowering). */
void mrbbc_hash_cat(MV *hash, const MV *src) {
  const MHash *from;
  long k;
  hash_check(hash);
  if (tag_of(src) != MRBBC_HASH) {
    char msg[160];
    snprintf(msg, sizeof msg, "%s cannot be converted to Hash", type_text(src));
    mrbbc_raise("TypeError", msg);
  }
  from = hash_of(src);
  for (k = 0; k < from->len; k++) mrbbc_hash_set(hash, &from->keys[k], &from->vals[k]);
}

/* The keyword flag of a `**h` splat: 1 when the hash has a key; 2 for an empty one, which vm.c still passes (a positional hash
 * to a method of only required parameters, and nothing to the others). */
long mrbbc_kw_flag(const MV *h) {
  hash_check(h);
  return hash_of(h)->len > 0 ? 1 : 2;
}

/* `&nil` in a parameter list (vm.c's ENTER): a block given to the method is an ArgumentError. */
void mrbbc_noblock(const MV *blk) {
  if (tag_of(blk) != MRBBC_NIL) mrbbc_raise("ArgumentError", "no block accepted");
}

static int64_t floor_div(int64_t x, int64_t y) {
  int64_t q = x / y;
  if ((x % y != 0) && ((x < 0) != (y < 0))) q -= 1;
  return q;
}

/* Integer on the left. The integer operators are exact up to overflow, which traps (see the header). */
static void int_op(int op, MV *dst, const MV *a, const MV *b) {
  char msg[160];
  int64_t r = 0;
  MV out;

  if (tag_of(b) != MRBBC_INT) {
    if (op >= MRBBC_OP_LT) {
      snprintf(msg, sizeof msg, "comparison of Integer with %s failed", class_name(b));
      mrbbc_raise("ArgumentError", msg);
    }
    if (op == MRBBC_OP_ADD || op == MRBBC_OP_SUB) {
      if (tag_of(b) == MRBBC_NIL) mrbbc_raise("TypeError", "can't convert nil into Float");
      snprintf(msg, sizeof msg, "%s cannot be converted to Float", type_text(b));
      mrbbc_raise("TypeError", msg);
    }
    snprintf(msg, sizeof msg, "can't convert %s into Integer", type_text(b));
    mrbbc_raise("TypeError", msg);
  }

  switch (op) {
    case MRBBC_OP_ADD:
      if (__builtin_add_overflow(int_of(a), int_of(b), &r)) break;
      *dst = int_value(r);
      return;
    case MRBBC_OP_SUB:
      if (__builtin_sub_overflow(int_of(a), int_of(b), &r)) break;
      *dst = int_value(r);
      return;
    case MRBBC_OP_MUL:
      if (__builtin_mul_overflow(int_of(a), int_of(b), &r)) break;
      *dst = int_value(r);
      return;
    case MRBBC_OP_DIV:
      if (int_of(b) == 0) mrbbc_raise("ZeroDivisionError", "divided by 0");
      if (int_of(a) == INT64_MIN && int_of(b) == -1) break;
      *dst = int_value(floor_div(int_of(a), int_of(b)));
      return;
    default:
      out = bool_value(compare_result(op, int_of(a) < int_of(b) ? -1 : int_of(a) > int_of(b)));
      *dst = out;
      return;
  }
  /* Only an integer overflow gets here. mruby promotes it to a Bignum (or a Float); this producer does not. */
  mrbbc_raise("NotImplementedError", "integer overflow: mrbbc does not promote to Bignum");
}

/* String on the left: + (concatenation), * (repetition) and the comparisons. */
static void str_op(int op, MV *dst, const MV *a, const MV *b) {
  char msg[160];
  MV out;
  if (op == MRBBC_OP_ADD) {
    long la, lb;
    MStr *t;
    if (tag_of(b) != MRBBC_STR) {
      snprintf(msg, sizeof msg, "%s cannot be converted to String", type_text(b));
      mrbbc_raise("TypeError", msg);
    }
    la = str_of(a)->len;
    lb = str_of(b)->len;
    if (lb > LONG_MAX - la) mrbbc_raise("ArgumentError", "argument too big");
    t = new_str_storage(la + lb);
    memcpy(t->p, str_of(a)->p, (size_t)la);
    memcpy(t->p + la, str_of(b)->p, (size_t)lb);
    t->p[la + lb] = '\0';
    t->len = la + lb;
    set_obj(&out, MRBBC_STR, t);
    *dst = out;
    return;
  }
  if (op == MRBBC_OP_MUL) {
    long n, len, k;
    MStr *t;
    if (tag_of(b) != MRBBC_INT) {
      snprintf(msg, sizeof msg, "%s cannot be converted to Integer", type_text(b));
      mrbbc_raise("TypeError", msg);
    }
    if (int_of(b) < 0) mrbbc_raise("ArgumentError", "negative argument");
    n = (long)int_of(b);
    len = str_of(a)->len;
    if (n != 0 && len > (long)(((size_t)-1 >> 1) / (size_t)n)) mrbbc_raise("ArgumentError", "argument too big");
    t = new_str_storage(len * n);
    for (k = 0; k < n; k++) memcpy(t->p + k * len, str_of(a)->p, (size_t)len);
    t->p[len * n] = '\0';
    t->len = len * n;
    set_obj(&out, MRBBC_STR, t);
    *dst = out;
    return;
  }
  if (op >= MRBBC_OP_LT) {
    if (tag_of(b) != MRBBC_STR) {
      snprintf(msg, sizeof msg, "comparison of String with %s failed", class_name(b));
      mrbbc_raise("ArgumentError", msg);
    }
    out = bool_value(compare_result(op, str_order(a, b)));
    *dst = out;
    return;
  }
  no_method(op_method(op), a);
}

/* Array on the left: + (concatenation). The other operators of Array are not in this runtime. */
static void ary_op(int op, MV *dst, const MV *a, const MV *b) {
  char msg[160];
  if (op == MRBBC_OP_ADD) {
    MV r;
    MAry *x, *y, *z;
    long k;
    if (tag_of(b) != MRBBC_ARY) {
      snprintf(msg, sizeof msg, "%s cannot be converted to Array", type_text(b));
      mrbbc_raise("TypeError", msg);
    }
    x = ary_of(a);
    y = ary_of(b);
    r = new_ary_value(x->len + y->len);
    z = ary_of(&r);
    for (k = 0; k < x->len; k++) z->items[z->len++] = x->items[k];
    for (k = 0; k < y->len; k++) z->items[z->len++] = y->items[k];
    *dst = r;
    return;
  }
  if (op == MRBBC_OP_SUB || op == MRBBC_OP_MUL) {
    snprintf(msg, sizeof msg, "Array#%s is not implemented by mrbbc", op_method(op));
    mrbbc_raise("NotImplementedError", msg);
  }
  no_method(op_method(op), a);
}

/* Symbol on the left: the comparisons (by name), as Symbol includes Comparable. */
static void sym_op(int op, MV *dst, const MV *a, const MV *b) {
  char msg[160];
  if (op >= MRBBC_OP_LT) {
    int c;
    if (tag_of(b) != MRBBC_SYM) {
      snprintf(msg, sizeof msg, "comparison of Symbol with %s failed", class_name(b));
      mrbbc_raise("ArgumentError", msg);
    }
    c = strcmp(sym_of(a), sym_of(b));
    *dst = bool_value(compare_result(op, c));
    return;
  }
  no_method(op_method(op), a);
}

/* An operator on an instance: the program's method of the operator's name (its result is the operator's, as mruby's
 * dispatch gives it). Without one, == and != are identity (and != negates a == the program defines), and the rest is a
 * NoMethodError. */
static void obj_op(int op, MV *dst, const MV *a, const MV *b) {
  int id = user_method(a, op_method(op), 1);
  if (id >= 0) {
    call_user(dst, id, a, b);
    return;
  }
  if (op == MRBBC_OP_EQ || op == MRBBC_OP_NEQ) {
    int eq = value_eq(a, b);
    *dst = bool_value(op == MRBBC_OP_EQ ? eq : !eq);
    return;
  }
  no_method(op_method(op), a);
}

void mrbbc_binop(int op, MV *dst, const MV *a, const MV *b) {
  if (tag_of(a) == MRBBC_OBJ) {
    obj_op(op, dst, a, b);
    return;
  }
  if (op == MRBBC_OP_EQ || op == MRBBC_OP_NEQ) {
    int eq = value_eq(a, b);
    *dst = bool_value(op == MRBBC_OP_EQ ? eq : !eq);
    return;
  }
  switch (tag_of(a)) {
    case MRBBC_INT: int_op(op, dst, a, b); return;
    case MRBBC_STR: str_op(op, dst, a, b); return;
    case MRBBC_ARY: ary_op(op, dst, a, b); return;
    case MRBBC_SYM: sym_op(op, dst, a, b); return;
    default: no_method(op_method(op), a);  /* nil, true, false */
  }
}

/* The index of an element: a negative index counts from the end. Returns false when it is below zero after that. */
static int ary_index(const MAry *a, long idx, long *out) {
  long i = idx;
  if (i < 0) i += a->len;
  if (i < 0) return 0;
  *out = i;
  return 1;
}

void mrbbc_getidx(MV *dst, const MV *recv, const MV *idx) {
  MV r;
  r = nil_value();
  if (tag_of(recv) == MRBBC_ARY && tag_of(idx) == MRBBC_INT) {
    const MAry *a = ary_of(recv);
    long i;
    if (ary_index(a, (long)int_of(idx), &i) && i < a->len) r = a->items[i];
    *dst = r;
    return;
  }
  if (tag_of(recv) == MRBBC_STR && tag_of(idx) == MRBBC_INT) {
    const MStr *s = str_of(recv);
    long i = (long)int_of(idx);
    if (i < 0) i += s->len;
    if (i >= 0 && i < s->len) r = new_str_value(s->p + i, 1);
    *dst = r;
    return;
  }
  if (tag_of(recv) == MRBBC_ARY || tag_of(recv) == MRBBC_STR) {
    mrbbc_raise("NotImplementedError", "[] with a non-integer index is not implemented by mrbbc");
  }
  no_method("[]", recv);
}

void mrbbc_getidx0(MV *dst, const MV *recv) {
  MV zero = int_value(0);
  mrbbc_getidx(dst, recv, &zero);
}

void mrbbc_setidx(const MV *recv, const MV *idx, const MV *v) {
  MAry *a;
  long i;
  MV item = *v;
  if (tag_of(recv) != MRBBC_ARY) {
    if (tag_of(recv) == MRBBC_STR) mrbbc_raise("NotImplementedError", "String#[]= is not implemented by mrbbc");
    no_method("[]=", recv);
  }
  if (tag_of(idx) != MRBBC_INT) mrbbc_raise("NotImplementedError", "[]= with a non-integer index is not implemented by mrbbc");
  a = ary_of(recv);
  i = (long)int_of(idx);
  if (i < 0) {
    char msg[96];
    if (i + a->len < 0) {
      snprintf(msg, sizeof msg, "index %ld out of array", i);
      mrbbc_raise("IndexError", msg);
    }
    i += a->len;
  }
  if (i >= a->len) {
    long k;
    ary_reserve(a, i + 1);
    for (k = a->len; k <= i; k++) {
      a->items[k] = nil_value();
    }
    a->len = i + 1;
  }
  a->items[i] = item;
}

void mrbbc_strcat(MV *dst, const MV *src) {
  Buf b = {NULL, 0, 0};
  MV roots[3];
  MrbbcGCFrame frame;
  if (tag_of(dst) != MRBBC_STR) mrbbc_raise("TypeError", "expected String");
  mrbbc_gc_enter(&frame, roots, 3);
  roots[0] = *dst;
  roots[1] = *src;
  /* the operand as a string: itself, or its to_s (mrb_obj_as_string) */
  roots[2] = to_s_string(&roots[1]);
  if (mrbbc_unwinding()) { mrbbc_gc_leave(&frame); return; }
  buf_put(&b, str_of(&roots[0])->p, (size_t)str_of(&roots[0])->len);
  buf_put(&b, str_of(&roots[2])->p, (size_t)str_of(&roots[2])->len);
  *dst = new_str_value(b.p ? b.p : "", (long)b.n);
  free(b.p);
  mrbbc_gc_leave(&frame);
}

void mrbbc_send0(MV *dst, const MV *recv, int m) {
  MV r;
  switch (m) {
    case MRBBC_M_TO_S:
      switch (tag_of(recv)) {
        case MRBBC_STR: r = *recv; break;
        case MRBBC_NIL: r = new_str_value("", 0); break;
        case MRBBC_TRUE: r = new_str_value("true", 4); break;
        case MRBBC_FALSE: r = new_str_value("false", 5); break;
        case MRBBC_SYM: r = new_str_value(sym_of(recv), (long)strlen(sym_of(recv))); break;
        case MRBBC_CLS: r = new_str_value(cls_of(recv)->name, (long)strlen(cls_of(recv)->name)); break;
        case MRBBC_OBJ: {
          /* the program's to_s; the default one prints an address, which is not lowered */
          int id = user_method(recv, "to_s", 0);
          MV out;
          if (id < 0) mrbbc_raise("NotImplementedError", "to_s of an instance is not lowered yet");
          call_user(&out, id, recv, NULL);
          r = out;
          break;
        }
        case MRBBC_INT: {
          char h[32];
          int n = snprintf(h, sizeof h, "%lld", (long long)int_of(recv));
          r = new_str_value(h, n);
          break;
        }
        default: {  /* Array#to_s is inspect */
          Buf b = {NULL, 0, 0};
          inspect_value(&b, recv);
          r = new_str_value(b.p, (long)b.n);
          free(b.p);
          break;
        }
      }
      break;
    case MRBBC_M_SIZE:
    case MRBBC_M_LENGTH:
      if (tag_of(recv) == MRBBC_STR) r = int_value(str_of(recv)->len);
      else if (tag_of(recv) == MRBBC_ARY) r = int_value(ary_of(recv)->len);
      else if (tag_of(recv) == MRBBC_SYM) r = int_value((int64_t)strlen(sym_of(recv)));
      else if (m == MRBBC_M_SIZE && tag_of(recv) == MRBBC_INT) r = int_value(8);  /* sizeof(mrb_int) */
      else no_method(m == MRBBC_M_SIZE ? "size" : "length", recv);
      break;
    case MRBBC_M_NOT:
      r = bool_value(tag_of(recv) == MRBBC_NIL || tag_of(recv) == MRBBC_FALSE);
      break;
    case MRBBC_M_INSPECT: {
      Buf b = {NULL, 0, 0};
      inspect_value(&b, recv);
      r = new_str_value(b.p ? b.p : "", (long)b.n);
      free(b.p);
      break;
    }
    case MRBBC_M_FIRST:
      if (tag_of(recv) != MRBBC_ARY) no_method("first", recv);
      r = ary_of(recv)->len ? ary_of(recv)->items[0] : nil_value();
      break;
    case MRBBC_M_JOIN:
      join_value(dst, recv);
      return;
    default: mrbbc_raise("RuntimeError", "unknown method code");
  }
  *dst = r;
}

/* The string of a value as mrb_obj_as_string gives it (an interpolation, a p of a value): a string itself, else its to_s.
 * A to_s that gives no string falls back to mruby's default one, which prints an address: not lowered. */
static MV to_s_string(const MV *v) {
  MV r;
  if (tag_of(v) == MRBBC_STR) return *v;
  mrbbc_send0(&r, v, MRBBC_M_TO_S);
  if (tag_of(&r) != MRBBC_STR) mrbbc_raise("NotImplementedError", "to_s of an instance that gives no string is not lowered yet");
  return r;
}

/* A block is either a closure of the module or a Symbol as vm.c's SENDB accepts (&:first, for example). */
void mrbbc_yield(MV *ret, const MV *blk, MV *argv, long argc) {
  MV roots[1];
  MrbbcGCFrame frame;
  mrbbc_gc_enter(&frame, roots, 1);
  roots[0] = *blk;
  if (tag_of(&roots[0]) == MRBBC_SYM) {
    const char *name = sym_of(&roots[0]);
    int id, method = -1;
    if (argc == 0) mrbbc_raise("ArgumentError", "no receiver given");
    /* Symbol#to_proc uses funcall, including private Object methods, as mruby's generated proc does. */
    id = user_method(&argv[1], name, argc - 1);
    if (id >= 0) {
      MV nil = nil_value();
      mrbbc_user_call(id, ret, argv + 1, &nil, argc - 1);
    } else {
      if (strcmp(name, "first") == 0) method = MRBBC_M_FIRST;
      else if (strcmp(name, "size") == 0) method = MRBBC_M_SIZE;
      else if (strcmp(name, "length") == 0) method = MRBBC_M_LENGTH;
      else if (strcmp(name, "to_s") == 0) method = MRBBC_M_TO_S;
      else if (strcmp(name, "inspect") == 0) method = MRBBC_M_INSPECT;
      else if (strcmp(name, "!") == 0) method = MRBBC_M_NOT;
      else if (strcmp(name, "join") == 0) method = MRBBC_M_JOIN;
      if (method < 0 || argc != 1) mrbbc_raise("NotImplementedError", "this Symbol block call is not lowered yet");
      mrbbc_send0(ret, &argv[1], method);
    }
  } else {
    if (tag_of(&roots[0]) != MRBBC_BLK) {
      char message[128];
      if (tag_of(&roots[0]) == MRBBC_NIL) mrbbc_raise("LocalJumpError", "unexpected yield");
      snprintf(message, sizeof message, "can't convert %s into Proc", class_name(&roots[0]));
      mrbbc_raise("TypeError", message);
    }
    mrbbc_blk_args(argv, &roots[0]);
    mrbbc_user_yield(ret, &roots[0], argv, argc);
  }
  mrbbc_gc_leave(&frame);
}

void mrbbc_iter(MV *dst, const MV *recv, const MV *blk, int method) {
  MV roots[7];
  MrbbcGCFrame frame;
  long i;
  const char *name = method == MRBBC_I_MAP ? "map" : method == MRBBC_I_FIND ? "find" : "each";
  /* SENDB validates an explicit block even for an empty array. A nil block would return an Enumerator. */
  if (tag_of(blk) != MRBBC_BLK && tag_of(blk) != MRBBC_SYM && tag_of(blk) != MRBBC_NIL) {
    char message[128];
    if (tag_of(blk) == MRBBC_OBJ && user_method(blk, "to_proc", 0) >= 0)
      mrbbc_raise("NotImplementedError", "block to_proc coercion is not lowered yet");
    snprintf(message, sizeof message, "can't convert %s into Proc", class_name(blk));
    mrbbc_raise("TypeError", message);
  }
  if (tag_of(recv) != MRBBC_ARY) {
    if (tag_of(recv) == MRBBC_HASH) mrbbc_raise("NotImplementedError", "Hash iteration is not lowered yet");
    no_method(name, recv);
  }
  if (tag_of(blk) == MRBBC_NIL) mrbbc_raise("NotImplementedError", "blockless Array iteration is not lowered yet");
  mrbbc_gc_enter(&frame, roots, 7);
  roots[0] = *recv;
  roots[1] = *blk;
  /* A map result must stay rooted while the block allocates; argv and its result are roots as well. */
  if (method == MRBBC_I_MAP) roots[2] = new_ary_value(ary_of(&roots[0])->len);
  for (i = 0; i < ary_of(&roots[0])->len; i++) {
    roots[3] = ary_of(&roots[0])->items[i];
    roots[6] = roots[3];
    mrbbc_yield(&roots[4], &roots[1], &roots[5], 1);
    if (mrbbc_unwinding()) break;
    if (method == MRBBC_I_MAP) mrbbc_ary_push(&roots[2], &roots[4]);
    if (method == MRBBC_I_FIND && tag_of(&roots[4]) != MRBBC_NIL && tag_of(&roots[4]) != MRBBC_FALSE) {
      roots[2] = roots[3];
      break;
    }
  }
  *dst = method == MRBBC_I_EACH ? roots[0] : roots[2];
  mrbbc_gc_leave(&frame);
}

static void str_reserve(MStr *s, size_t need) {
  size_t cap = s->cap;
  char *p;
  const size_t limit = UINT32_MAX - sizeof(MStr);
  if (need <= cap) return;
  if (need > limit) mrbbc_raise("ArgumentError", "argument too big");
  while (cap < need) cap = cap > limit / 2 ? need : cap * 2;
  p = realloc(s->p, cap);
  if (p == NULL) mrbbc_raise("NoMemoryError", "failed to allocate memory");
  s->p = p;
  gc_grow(s, cap - s->cap);
  s->cap = cap;
}

void mrbbc_append(MV *dst, const MV *recv, const MV *value) {
  MV roots[3];
  MrbbcGCFrame frame;
  MStr *s;
  long n;
  char byte = 0;
  int integer;
  mrbbc_gc_enter(&frame, roots, 3);
  roots[0] = *recv;
  roots[1] = *value;
  if (tag_of(&roots[0]) == MRBBC_ARY) {
    mrbbc_ary_push(&roots[0], &roots[1]);
    *dst = roots[0];
    mrbbc_gc_leave(&frame);
    return;
  }
  if (tag_of(&roots[0]) != MRBBC_STR) {
    if (tag_of(&roots[0]) == MRBBC_INT) mrbbc_raise("NotImplementedError", "Integer#<< is not lowered yet");
    no_method("<<", &roots[0]);
  }
  integer = tag_of(&roots[1]) == MRBBC_INT;
  if (integer) {
    int64_t code = int_of(&roots[1]);
    if (code < 0 || code > 255) {
      char message[96];
      snprintf(message, sizeof message, "%lld out of char range", (long long)code);
      mrbbc_raise("RangeError", message);
    }
    byte = (char)code;
  } else {
    /* mruby's String#<< accepts a String directly; it does not invoke an object's to_str. */
    if (tag_of(&roots[1]) != MRBBC_STR) {
      char message[128];
      snprintf(message, sizeof message, "%s cannot be converted to String", type_text(&roots[1]));
      mrbbc_raise("TypeError", message);
    }
  }
  s = str_of(&roots[0]);
  n = integer ? 1 : str_of(&roots[1])->len;
  if (n > LONG_MAX - s->len) mrbbc_raise("ArgumentError", "argument too big");
  str_reserve(s, (size_t)(s->len + n) + 1);
  /* Read the source buffer after reserve: self-append may have moved that same buffer. */
  if (n) memmove(s->p + s->len, integer ? &byte : str_of(&roots[1])->p, (size_t)n);
  s->len += n;
  s->p[s->len] = '\0';
  *dst = roots[0];
  mrbbc_gc_leave(&frame);
}

typedef struct JoinFrame {
  const MAry *array;
  const struct JoinFrame *prev;
} JoinFrame;

static void join_into(Buf *buffer, const MV *value, const JoinFrame *prev) {
  MV roots[2];
  MrbbcGCFrame frame;
  JoinFrame here;
  const JoinFrame *p;
  long i;
  mrbbc_gc_enter(&frame, roots, 2);
  roots[0] = *value;
  here.array = ary_of(&roots[0]);
  here.prev = prev;
  for (p = prev; p != NULL; p = p->prev) {
    if (p->array == here.array) mrbbc_raise("ArgumentError", "recursive array join");
  }
  for (i = 0; i < here.array->len; i++) {
    roots[1] = here.array->items[i];
    if (tag_of(&roots[1]) == MRBBC_ARY) {
      join_into(buffer, &roots[1], &here);
    } else {
      /* mruby's Array#join uses to_s here, not CRuby's to_str/to_ary coercion protocol. */
      roots[1] = to_s_string(&roots[1]);
      if (!mrbbc_unwinding()) buf_put(buffer, str_of(&roots[1])->p, (size_t)str_of(&roots[1])->len);
    }
    if (mrbbc_unwinding()) break;
  }
  mrbbc_gc_leave(&frame);
}

static void join_value(MV *dst, const MV *recv) {
  Buf buffer = {NULL, 0, 0};
  if (tag_of(recv) != MRBBC_ARY) no_method("join", recv);
  join_into(&buffer, recv, NULL);
  if (!mrbbc_unwinding()) *dst = new_str_value(buffer.p ? buffer.p : "", (long)buffer.n);
  free(buffer.p);
}

/* ---- optional hosted operations ---- */
void mrbbc_set_args(int argc, char **argv) {
  host_argc = argc;
  host_argv = argv;
  host_args_ready = 0;
  host_args = nil_value();
}

#if MRBBC_LIBUV
static MClass *host_class(const char *name) {
  MClass *c = find_class(name);
  if (c == NULL) {
    MClass *root = object_cls();
    c = gc_alloc(GC_CLS, sizeof *c);
    c->key = c->name = name;
    c->super = root;
    c->next = class_registry;
    class_registry = c;
  }
  return c;
}
#endif

static int host_constant(MV *dst, const char *name) {
  if (strcmp(name, "STDIN") == 0 || strcmp(name, "STDOUT") == 0 || strcmp(name, "STDERR") == 0) {
    mrbbc_getglobal(dst, strcmp(name, "STDIN") == 0 ? "$stdin" : strcmp(name, "STDOUT") == 0 ? "$stdout" : "$stderr");
    return 1;
  }
  if (strcmp(name, "ARGV") == 0) {
    if (!host_args_ready) {
      MV item = nil_value();
      int mark = gc_protect(&item), i;
      host_args = new_ary_value(host_argc > 0 ? host_argc - 1 : 0);
      for (i = 1; i < host_argc; i++) {
        item = new_str_value(host_argv[i], (long)strlen(host_argv[i]));
        mrbbc_ary_push(&host_args, &item);
      }
      gc_unprotect(mark);
      host_args_ready = 1;
    }
    *dst = host_args;
    return 1;
  }
  if (strcmp(name, "File") != 0 && strcmp(name, "IO") != 0 && strcmp(name, "Dir") != 0) return 0;
#if MRBBC_LIBUV
  /* Class registry names must outlive a call, even when a caller supplies a temporary C string. */
  name = strcmp(name, "File") == 0 ? "File" : strcmp(name, "Dir") == 0 ? "Dir" : "IO";
  set_obj(dst, MRBBC_CLS, host_class(name));
#else
  (void)dst;
  mrbbc_raise("NotImplementedError", "host I/O requires the libuv runtime (MRBBC_LIBUV=1)");
#endif
  return 1;
}

void mrbbc_getglobal(MV *dst, const char *name) {
  int fd;
  if (strcmp(name, "$0") == 0 || strcmp(name, "$PROGRAM_NAME") == 0) {
    *dst = new_str_value(mrbbc_progname, (long)strlen(mrbbc_progname));
    return;
  }
  fd = strcmp(name, "$stdin") == 0 ? 0 : strcmp(name, "$stdout") == 0 ? 1 : strcmp(name, "$stderr") == 0 ? 2 : -1;
  if (fd < 0) mrbbc_raise("NotImplementedError", "this global is not lowered yet");
#if MRBBC_LIBUV
  if (tag_of(&host_streams[fd]) == MRBBC_NIL) {
    MClass *cls = host_class("IO");
    MObj *stream = gc_alloc(GC_OBJ, sizeof *stream);
    stream->cls = cls;
    set_obj(&host_streams[fd], MRBBC_OBJ, stream);
  }
  *dst = host_streams[fd];
#else
  (void)dst;
  mrbbc_raise("NotImplementedError", "host I/O requires the libuv runtime (MRBBC_LIBUV=1)");
#endif
}

#if MRBBC_LIBUV
static void host_error(int code) {
  char cls[96];
  snprintf(cls, sizeof cls, "Errno::%s", mrbbc_uv_error_name(code));
  mrbbc_raise(cls, mrbbc_uv_error(code));
}

static const char *host_string(const MV *v, int path) {
  if (tag_of(v) != MRBBC_STR)
    mrbbc_raise("NotImplementedError", "host I/O String coercion is not lowered yet");
  if (path && memchr(str_of(v)->p, '\0', (size_t)str_of(v)->len) != NULL)
    mrbbc_raise("ArgumentError", "path name contains null byte");
  return str_of(v)->p;
}

static void host_read(MV *dst, int fd, int owned) {
  Buf b = {NULL, 0, 0};
  char chunk[16384];
  long n;
  int closed = 0;
  while ((n = mrbbc_uv_read(fd, chunk, sizeof chunk)) > 0) buf_put(&b, chunk, (size_t)n);
  if (owned) closed = mrbbc_uv_close(fd);
  if (n < 0 || closed < 0) {
    free(b.p);
    host_error(n < 0 ? (int)n : closed);
  }
  *dst = new_str_value(b.p ? b.p : "", (long)b.n);
  free(b.p);
}

static void host_write(MV *dst, int fd, const MV *data, int owned) {
  const MStr *s = str_of(data);
  long sent = 0, n = 1;
  int closed = 0;
  while (sent < s->len) {
    unsigned int chunk = (unsigned int)(s->len - sent > 1048576 ? 1048576 : s->len - sent);
    n = mrbbc_uv_write(fd, s->p + sent, chunk);
    if (n <= 0) break;
    sent += n;
  }
  if (owned) closed = mrbbc_uv_close(fd);
  if (n < 0 || closed < 0) host_error(n < 0 ? (int)n : closed);
  if (sent != s->len) mrbbc_raise("IOError", "write made no progress");
  *dst = int_value(sent);
}
#endif

void mrbbc_host_send(MV *dst, const MV *recv, const MV *args, long argc, const char *name) {
#if MRBBC_LIBUV
  MV roots[3];
  MrbbcGCFrame frame;
  int fd = -1, i;
  const char *cls = tag_of(recv) == MRBBC_CLS ? cls_of(recv)->name : "";
  mrbbc_gc_enter(&frame, roots, 3);
  roots[0] = *recv;
  for (i = 0; i < argc && i < 2; i++) roots[i + 1] = args[i];
  if (strcmp(cls, "File") == 0 || strcmp(cls, "Dir") == 0) {
    const char *path;
    int is_file = strcmp(cls, "File") == 0;
    if (argc < 1) mrbbc_raise("NotImplementedError", "this host call form is not lowered yet");
    path = host_string(&roots[1], 1);
    if (is_file && strcmp(name, "read") == 0 && argc == 1) {
      fd = mrbbc_uv_open(path, 0);
      if (fd < 0) host_error(fd);
      host_read(dst, fd, 1);
    } else if (is_file && strcmp(name, "write") == 0 && argc == 2) {
      host_string(&roots[2], 0); /* validate before opening/truncating the destination */
      fd = mrbbc_uv_open(path, 1);
      if (fd < 0) host_error(fd);
      host_write(dst, fd, &roots[2], 1);
    } else if (argc == 1 && (strcmp(name, "exist?") == 0 ||
               (is_file && (strcmp(name, "file?") == 0 || strcmp(name, "directory?") == 0 || strcmp(name, "executable?") == 0)))) {
      *dst = bool_value(mrbbc_uv_test(path, is_file ? name : "directory?"));
    } else no_method(name, &roots[0]);
  } else {
    for (i = 0; i < 3; i++) {
      if (tag_of(&host_streams[i]) != MRBBC_NIL && same_value(&roots[0], &host_streams[i])) fd = i;
    }
    if (fd < 0) no_method(name, &roots[0]);
    if (strcmp(name, "read") == 0 && argc == 0) {
      if (fd != 0) mrbbc_raise("IOError", "not opened for reading");
      host_read(dst, fd, 0);
    } else if (strcmp(name, "write") == 0 && argc == 1) {
      if (fd == 0) mrbbc_raise("IOError", "not opened for writing");
      host_string(&roots[1], 0);
      host_write(dst, fd, &roots[1], 0);
    } else mrbbc_raise("NotImplementedError", "this IO call form is not lowered yet");
  }
  mrbbc_gc_leave(&frame);
#else
  (void)dst; (void)recv; (void)args; (void)argc; (void)name;
  mrbbc_raise("NotImplementedError", "host I/O requires the libuv runtime (MRBBC_LIBUV=1)");
#endif
}

/* ---- the collector: mark and sweep (the design of lua54rt.c's collector) ----
 * Every heap object is allocated by gc_alloc (strings, arrays, hashes, argument vectors, instances, classes, method and
 * instance-variable records, boxed integers, closures) with a GCHdr, linked into one list. A collection marks from the
 * roots and then frees the unmarked objects together with the buffers they own (an array's items, a hash's keys and values,
 * a class's full name). The roots are:
 *   - precise (the default): the frames the lowered functions registered (mrbbc_gc_enter: every register and slot of the
 *     function), with each frame's pinned splat vector, and the values the helpers protect (gc_protect) while they hold a
 *     new value in a local across an allocation;
 *   - or, under MRBBC_GC_CONSERVATIVE, the C stack, from the collector's frame up to stack_base (the frame of mrbbc_run,
 *     under which the program runs), with the callee-saved registers spilled first. A stack word counts only when it is the
 *     address of an object in a set of the objects' addresses (a stale word can only keep an object one cycle longer);
 *   - class_registry: every class the program defines (a class is never garbage: the class table holds it), with its
 *     methods, instance variables and superclass;
 *   - Object (object_cls): Object's methods and its class instance variables;
 *   - owners: the class of each method number (its classes are in the registry; marked again for the record);
 *   - unwind_value: a pending return or break value, held until its home takes it;
 *   - inspecting: the arrays being inspected;
 *   - host_args and host_streams: the shared ARGV array and borrowed standard-stream objects;
 *   - entry_ret: the result slot of the entry, which the program writes when it returns.
 * The traversal follows each kind's fields: an array's items, a hash's keys and values, an argument vector's items, an
 * object's class and instance variables, an instance variable's value and next, a method's next, a class's methods,
 * instance variables, superclass and next; a closure's self. Symbols are interned names and immediates hold no pointer.
 * The threshold: a collection runs before an allocation once the bytes allocated since the last one would pass it. By default
 * it is max(2 * live, 4 MiB). MRBBC_GC_THRESHOLD=N in the environment forces it to N bytes, so 1 collects before every
 * allocation (the tests use it); mrbbc_gc_set_threshold does the same from the program. The collector is off until mrbbc_run
 * starts the entry, and again after it returns (the result is printed then, and nothing there can move or free it). */
#define GC_MIN_THRESHOLD ((size_t)4 << 20)
#define GC_TOMB ((void *)1)
#define HDR(p) (((GCHdr *)(p)) - 1)

static GCHdr *all_objects = NULL;
static long gc_count = 0;             /* the objects allocated and not yet swept */
static size_t gc_allocated = 0;       /* bytes allocated since the last collection */
static size_t gc_live = 0;            /* bytes that survived the last collection */
static size_t gc_peak = 0;            /* the most bytes of objects at once (MRBBC_GC_STATS) */
static size_t gc_total = 0;           /* every byte allocated (MRBBC_GC_STATS) */
static long gc_runs = 0;              /* the collections (MRBBC_GC_STATS) */
static size_t gc_threshold = GC_MIN_THRESHOLD;
static int gc_forced = 0;             /* the threshold is forced (MRBBC_GC_THRESHOLD, mrbbc_gc_set_threshold) */
static int gc_busy = 0;               /* a collection is running */
static void *stack_base = NULL;       /* the frame of mrbbc_run: the top of the C stack that the collector scans */
static MV *entry_ret = NULL;          /* the result slot of the entry, while the entry runs */

void mrbbc_gc_enter(MrbbcGCFrame *f, MV *frame, long n) {
  long k;
  for (k = 0; k < n; k++) frame[k] = nil_value();
  f->prev = gc_top;
  f->base = frame;
  f->n = n;
  f->pin = NULL;
  gc_top = f;
}

void mrbbc_gc_leave(MrbbcGCFrame *f) { gc_top = f->prev; }

#if MRBBC_GC_CONSERVATIVE
/* The set of object addresses (the payloads): linear probing; a removed slot holds GC_TOMB. obj_used counts the slots that
 * are not NULL, removed ones included, and a rehash to a size for the live objects clears the removed ones. */
static void **obj_set = NULL;
static size_t obj_cap = 0, obj_used = 0;

static size_t set_hash(const void *p) { return (size_t)((uintptr_t)p >> 4) * (size_t)2654435761u; }

static int set_has(const void *p) {
  size_t mask, i;
  if (obj_cap == 0) return 0;
  mask = obj_cap - 1;
  for (i = set_hash(p) & mask;; i = (i + 1) & mask) {
    void *q = obj_set[i];
    if (q == NULL) return 0;
    if (q == p && q != GC_TOMB) return 1;  /* a removed slot is not a member, even for a word equal to its marker */
  }
}

static void set_insert_raw(void *p) {
  size_t mask = obj_cap - 1, i = set_hash(p) & mask;
  while (obj_set[i] != NULL && obj_set[i] != GC_TOMB) i = (i + 1) & mask;
  if (obj_set[i] == NULL) obj_used++;
  obj_set[i] = p;
}

static void set_rehash(size_t cap) {
  void **old = obj_set;
  size_t oldcap = obj_cap, i;
  obj_set = calloc(cap, sizeof(void *));
  if (obj_set == NULL) mrbbc_raise("NoMemoryError", "failed to allocate memory");
  obj_cap = cap;
  obj_used = 0;
  for (i = 0; i < oldcap; i++) {
    if (old[i] != NULL && old[i] != GC_TOMB) set_insert_raw(old[i]);
  }
  free(old);
}

static void set_insert(void *p) {
  if ((obj_used + 1) * 2 > obj_cap) {
    size_t want = 256;
    while (want < (size_t)(gc_count + 1) * 4) want *= 2;
    set_rehash(want);
  }
  set_insert_raw(p);
}

static void set_remove(const void *p) {
  size_t mask, i;
  if (obj_cap == 0) return;
  mask = obj_cap - 1;
  for (i = set_hash(p) & mask;; i = (i + 1) & mask) {
    void *q = obj_set[i];
    if (q == NULL) return;
    if (q == p) {
      obj_set[i] = GC_TOMB;
      return;
    }
  }
}

#endif

/* Allocates an object of kind with size bytes, zeroed. A collection runs first when the threshold is passed. The object
 * is in the set before the caller fills it: the caller fills it before any other allocation. */
static void *gc_alloc(uint8_t kind, size_t size) {
  size_t need = sizeof(GCHdr) + size;
  unsigned block;
  GCHdr *h;
  if (stack_base != NULL && !gc_busy && gc_allocated + need > gc_threshold) gc_collect();
  if (need > UINT32_MAX) mrbbc_raise("NoMemoryError", "failed to allocate memory");
  h = raw_alloc(need, &block);
  if (h == NULL) mrbbc_raise("NoMemoryError", "failed to allocate memory");
  memset(h, 0, need);
  h->block = (uint16_t)block;
  h->kind = kind;
  h->size = (uint32_t)size;
  h->next = all_objects;
  all_objects = h;
#if MRBBC_GC_CONSERVATIVE
  set_insert(h + 1);
#endif
  gc_count++;
  gc_allocated += need;
  gc_total += need;
  if (gc_live + gc_allocated > gc_peak) gc_peak = gc_live + gc_allocated;
  return h + 1;
}

/* A buffer that an object owns grew by n bytes: the object counts for them (and they count for the threshold). */
static void gc_grow(const void *p, size_t n) {
  HDR(p)->size += (uint32_t)n;
  gc_allocated += n;
  gc_total += n;
  if (gc_live + gc_allocated > gc_peak) gc_peak = gc_live + gc_allocated;
}

static void **gray = NULL;     /* the marked objects not yet traversed */
static size_t gray_n = 0, gray_cap = 0;

static void mark_obj(const void *p) {
#if MRBBC_GC_CONSERVATIVE
  if (p == NULL || !set_has(p) || HDR(p)->marked) return;
#else
  if (p == NULL || HDR(p)->marked) return;
#endif
  HDR(p)->marked = 1;
  if (gray_n == gray_cap) {
    gray_cap = gray_cap == 0 ? 256 : gray_cap * 2;
    gray = realloc(gray, gray_cap * sizeof(void *));
    if (gray == NULL) mrbbc_raise("NoMemoryError", "failed to allocate memory");
  }
  gray[gray_n++] = (void *)p;
}

static void mark_value(const MV *v) {
  switch (tag_of(v)) {
    case MRBBC_STR:
    case MRBBC_ARY:
    case MRBBC_HASH:
    case MRBBC_OBJ:
    case MRBBC_CLS:
    case MRBBC_BLK: mark_obj(ptr_of(v)); break;
#if MRBBC_VALUE != 16
    case MRBBC_INT:
      if (!(v->w & 1)) mark_obj(ptr_of(v)); /* a boxed integer */
      break;
#endif
    default: break;  /* nil, booleans, small integers, and symbols (their names are static) */
  }
}

/* The fields of one object, by its kind. */
static void traverse(const void *p) {
  switch (HDR(p)->kind) {
    case GC_ARY: {
      const MAry *a = p;
      long k;
      for (k = 0; k < a->len; k++) mark_value(&a->items[k]);
      break;
    }
    case GC_HASH: {
      const MHash *h = p;
      long k;
      for (k = 0; k < h->len; k++) {
        mark_value(&h->keys[k]);
        mark_value(&h->vals[k]);
      }
      break;
    }
    case GC_VEC: {
      const MV *items = p;
      size_t k, n = HDR(p)->size / sizeof(MV);
      for (k = 0; k < n; k++) mark_value(&items[k]);
      break;
    }
    case GC_OBJ: {
      const MObj *o = p;
      mark_obj(o->cls);
      mark_obj(o->ivars);
      break;
    }
    case GC_IVAR: {
      const MIvar *v = p;
      mark_value(&v->val);
      mark_obj(v->next);
      break;
    }
    case GC_DEF: mark_obj(((const MDef *)p)->next); break;
    case GC_CLS: {
      const MClass *c = p;
      mark_obj(c->defs);
      mark_obj(c->ivars);
      mark_obj(c->super);
      mark_obj(c->next);
      break;
    }
    case GC_CLO: mark_value(&((const Clo *)p)->self); break;
    default: break;  /* a string or a boxed integer: its bytes are all of it */
  }
}

static void propagate(void) {
  while (gray_n > 0) traverse(gray[--gray_n]);
}

#if MRBBC_GC_CONSERVATIVE
/* The scan reads every word of the stack, the padding between locals included: AddressSanitizer would flag those reads, so
 * the scan is not instrumented. Run under ASan with detect_stack_use_after_return=0: that mode moves the address-taken locals
 * of a frame off the C stack, where this scan cannot see them. */
#if defined(__has_attribute)
#if __has_attribute(no_sanitize_address)
#define MRBBC_NO_ASAN __attribute__((no_sanitize_address))
#endif
#endif
#ifndef MRBBC_NO_ASAN
#define MRBBC_NO_ASAN
#endif

/* A value of the 4-byte layout is a 4-byte word of the frame, so the scan reads every 4 bytes (the low half of a pointer in a
 * helper's local, under the arena below 2 GB, is its address too). */
#define SCAN_STEP (MRBBC_VALUE == 4 ? 4 : sizeof(uintptr_t))

/* The C stack, from here up to stack_base: the callee-saved registers are spilled to the stack first (__builtin_unwind_init
 * and setjmp), so a pointer that lives only in a register is found too. */
MRBBC_NO_ASAN static void scan_c_stack(void) {
  jmp_buf regs;
  volatile int here = 0;
  uintptr_t lo, hi, p;
  __builtin_unwind_init();
  setjmp(regs);
  lo = (uintptr_t)&here;
  if ((uintptr_t)&regs < lo) lo = (uintptr_t)&regs;
  hi = (uintptr_t)stack_base;
  for (p = lo & ~(uintptr_t)(SCAN_STEP - 1); p + SCAN_STEP <= hi; p += SCAN_STEP) {
    uintptr_t w = SCAN_STEP == 4 ? *(volatile uint32_t *)p : *(volatile uintptr_t *)p;
    if (w != 0 && set_has((const void *)w)) mark_obj((const void *)w);
  }
  (void)here;
}

#else
/* The frames the lowered functions registered (mrbbc_gc_enter), each with the argument vector of its last splat call, and
 * the values the helpers protect while they allocate (gc_protect). */
static void scan_frames(void) {
  const MrbbcGCFrame *f;
  int i;
  for (f = gc_top; f != NULL; f = f->prev) {
    long k;
    for (k = 0; k < f->n; k++) mark_value(&f->base[k]);
    if (f->pin != NULL) mark_obj(f->pin);
  }
  for (i = 0; i < protect_n; i++) mark_value(protected[i]);
}
#endif

static void mark_roots(void) {
  size_t i;
  mark_obj(object_cls());
  mark_obj(class_registry);
  mark_obj(object_cls()->defs);
  mark_obj(object_cls()->ivars);
  for (i = 0; i < (size_t)owners_n; i++) mark_obj(owners[i]);
  mark_value(&unwind_value);
  mark_value(&host_args);
  for (i = 0; i < 3; i++) mark_value(&host_streams[i]);
  for (i = 0; i < (size_t)inspect_depth; i++) mark_obj(inspecting[i]);
  if (entry_ret != NULL) mark_value(entry_ret);
#if MRBBC_GC_CONSERVATIVE
  scan_c_stack();
#else
  scan_frames();
#endif
  propagate();
}

/* Frees an unmarked object and the buffers it owns. */
static void free_object(GCHdr *h) {
  void *p = h + 1;
#if MRBBC_GC_CONSERVATIVE
  set_remove(p);
#endif
  switch (h->kind) {
    case GC_STR: free(((MStr *)p)->p); break;
    case GC_ARY: free(((MAry *)p)->items); break;
    case GC_HASH:
      free(((MHash *)p)->keys);
      free(((MHash *)p)->vals);
      break;
    case GC_CLS: free(((MClass *)p)->owned_name); break;
    default: break;
  }
  gc_count--;
  raw_free(h, h->block);
}

static void sweep(void) {
  GCHdr **pp = &all_objects;
  size_t live = 0;
  while (*pp != NULL) {
    GCHdr *h = *pp;
    if (h->marked) {
      h->marked = 0;
      live += sizeof(GCHdr) + h->size;
      pp = &h->next;
    } else {
      *pp = h->next;
      free_object(h);
    }
  }
  gc_live = live;
}

static size_t auto_threshold(void) { return gc_live * 2 > GC_MIN_THRESHOLD ? gc_live * 2 : GC_MIN_THRESHOLD; }

static void gc_collect(void) {
  if (stack_base == NULL || gc_busy) return;
  gc_busy = 1;
  gc_runs++;
  gray_n = 0;
  mark_roots();
  sweep();
  if (!gc_forced) gc_threshold = auto_threshold();
  gc_allocated = 0;
  gc_busy = 0;
}

void mrbbc_gc_collect(void) { gc_collect(); }

long mrbbc_gc_count(void) { return gc_count; }

void mrbbc_gc_set_threshold(long bytes) {
  gc_forced = bytes > 0;
  gc_threshold = gc_forced ? (size_t)bytes : auto_threshold();
}

/* The program's entry, under the collector. MRBBC_GC_THRESHOLD forces the threshold (see above). The result slot is a root
 * while the entry runs; the collector is off once it returns. */
/* MRBBC_GC_STATS=1: at exit, the heap's numbers on stderr (tests/mrbbc/lower/measure.sh reads them):
 *   mrbbc-gc: total BYTES peak BYTES collections N
 * total is every byte the objects took, peak the most at once (headers and owned buffers included). */
static void gc_report(void) {
  fprintf(stderr, "mrbbc-gc: total %lu peak %lu collections %ld\n", (unsigned long)gc_total, (unsigned long)gc_peak, gc_runs);
}

void mrbbc_run(void (*entry)(MV *ret), MV *ret) {
  const char *env = getenv("MRBBC_GC_THRESHOLD");
  const char *stats = getenv("MRBBC_GC_STATS");
  long n;
  if (env != NULL && (n = strtol(env, NULL, 10)) > 0) mrbbc_gc_set_threshold(n);
  if (stats != NULL && *stats != '\0' && *stats != '0') atexit(gc_report);
  stack_base = __builtin_frame_address(0);
  entry_ret = ret;
  entry(ret);
  entry_ret = NULL;
  stack_base = NULL;
}
