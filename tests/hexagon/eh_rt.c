/* Minimal EDG exception-handling runtime for the freestanding Hexagon test target.
   Appended (after stub.c, compiled with -DNFCXX_EH_RT) to the generated C of a case that references
   __throw_setup*; see
   docs/notes/hexagon.md "Exception handling". It implements the ABI EDG's C back end emits
   (a port of 3rd/edg/lib_src/throw.c, trimmed): an EH stack of function/try-block entries kept in
   the callers' frames, a throw stack of in-flight exceptions, two-pass search/cleanup, setjmp-based
   transfer to the catch.

   Limits (anything else terminates with exit status 134):
   - catch matching: exact type, `...`, single-level pointers (cv checked), void*, and derived-to-base
     through __si_class_type_info (single non-virtual base at offset 0). No __vmi_class_type_info
     (multiple/virtual bases), no multi-level pointer qualification conversions, no nullptr_t catch.
   - no throw specifications / noexcept violation handling (terminate), no array new/delete cleanup
     entries (__cleanup_vec_new_or_delete terminates).
   - exception objects live in a 16 KiB static arena used as a stack; overflow terminates. */

/* Globals shared with the generated C. The generated C declares them with its own struct types,
   so they are reached here through asm labels under private names. */
struct eh_entry;
extern struct eh_entry *rt_eh_top __asm__("__curr_eh_stack_entry");
extern unsigned short rt_eh_region __asm__("__eh_curr_region");
extern void *rt_caught_addr __asm__("__caught_object_address");
extern int rt_catch_clause __asm__("__catch_clause_number");
struct eh_entry *rt_eh_top;
unsigned short rt_eh_region;
void *rt_caught_addr;
int rt_catch_clause;

enum { K_FUNCTION = 1, K_THROW_SPEC = 2, K_MARKER = 3, K_VEC = 4, K_TRY = 5, K_NOEXCEPT = 6 };
enum { RDF_INDIRECT = 1, RDF_COND = 2, RDF_NEW = 4, RDF_ARRAY = 8, RDF_SUBVTBL = 0x20,
       RDF_BASE = 0x40, RDF_GUARD = 0x80 };
enum { ETS_PTR = 1, ETS_CONST = 2, ETS_VOL = 4, ETS_ELLIPSIS = 0x10, ETS_LAST = 0x20,
       ETS_PTR_DATA_MEM = 0x40, ETS_PTR_MEM_FN = 0x80 };
#define NO_REGION 0xFFFFu

struct rt_ti { const int *vptr; const char *name; };
struct rt_si_ti { struct rt_ti base; const struct rt_ti *base_type; };
struct rt_ets { const struct rt_ti *tinfo; unsigned flags; unsigned *ptr_flags; };
struct rt_region { void (*dtor)(); unsigned short handle; unsigned short next; unsigned char flags; };
struct rt_array { unsigned short handle; unsigned elem_size; long elem_count; };
struct eh_entry {
  struct eh_entry *next;
  unsigned char kind;
  union {
    struct { long long jb[36]; struct rt_ets *catch_entries; void *catch_info;
             unsigned short region_number; } try_block;
    struct { struct rt_region *regions; void **obj_table; struct rt_array *array_table;
             unsigned short saved_region; } function;
    struct rt_ets *throw_spec;
  } v;
};

struct tse {                     /* throw stack entry */
  struct tse *next;
  const struct rt_ti *type;
  void (*dtor)();
  unsigned flags;
  unsigned *ptr_flags;
  void *object;
  void *pointer_buffer;
  struct tse *primary;
  int use_count;
  unsigned char is_rethrow, is_internal, dtor_called, discard, in_handler, copy_done, eval_done;
  struct eh_entry *enclosing_try;
  struct eh_entry marker;
};
static struct tse *rt_throws;

__attribute__((noreturn)) static void rt_terminate(void) {
  for (;;) nfcxx_sys3(94, 134, 0, 0);          /* exit_group(134) */
}
void __call_terminate(void) { rt_terminate(); }
void __call_unexpected(void) { rt_terminate(); }
void rt_cleanup_vec(struct eh_entry *e) __asm__("__cleanup_vec_new_or_delete");
void rt_cleanup_vec(struct eh_entry *e) { (void)e; rt_terminate(); }
void rt_suppress_optim(void *p, ...) __asm__("__suppress_optim_on_vars_in_try");
void rt_suppress_optim(void *p, ...) { (void)p; }
void __eh_exit_processing(void) { rt_eh_top = 0; }

/* ---- setjmp/longjmp: r16-r27, lr, fp, sp saved in the 288-byte EDG jmp_buf ---- */
__asm__(".text\n.p2align 4\n"
        ".globl _setjmp\n.type _setjmp,@function\n_setjmp:\n"
        "  memd(r0+#0) = r17:16\n  memd(r0+#8) = r19:18\n  memd(r0+#16) = r21:20\n"
        "  memd(r0+#24) = r23:22\n  memd(r0+#32) = r25:24\n  memd(r0+#40) = r27:26\n"
        "  memd(r0+#48) = r31:30\n  memw(r0+#56) = r29\n"
        "  r0 = #0\n  jumpr r31\n"
        ".globl rt_longjmp\n.type rt_longjmp,@function\nrt_longjmp:\n"
        "  r17:16 = memd(r0+#0)\n  r19:18 = memd(r0+#8)\n  r21:20 = memd(r0+#16)\n"
        "  r23:22 = memd(r0+#24)\n  r25:24 = memd(r0+#32)\n  r27:26 = memd(r0+#40)\n"
        "  r31:30 = memd(r0+#48)\n  r29 = memw(r0+#56)\n"
        "  r0 = r1\n  jumpr r31\n");
__attribute__((noreturn)) void rt_longjmp(long long *jb, int val);


/* type_info objects for the fundamental types (normally in the C++ runtime library): { vptr, name }. */
#define RT_FTI(c) \
  ".globl _ZTI" c "\n_ZTI" c ":\n .word _ZTVN10__cxxabiv123__fundamental_type_infoE+8\n .word _ZTS" c "\n" \
  ".globl _ZTS" c "\n_ZTS" c ": .asciz \"" c "\"\n"
__asm__(".pushsection .data\n.p2align 3\n"
        ".globl _ZTVN10__cxxabiv123__fundamental_type_infoE\n"
        "_ZTVN10__cxxabiv123__fundamental_type_infoE: .space 16\n"
        RT_FTI("v") RT_FTI("b") RT_FTI("c") RT_FTI("a") RT_FTI("h") RT_FTI("s") RT_FTI("t")
        RT_FTI("i") RT_FTI("j") RT_FTI("l") RT_FTI("m") RT_FTI("x") RT_FTI("y") RT_FTI("f")
        RT_FTI("d") RT_FTI("e") RT_FTI("w") RT_FTI("Di") RT_FTI("Ds") RT_FTI("Dn")
        ".popsection");

/* ---- arena used as a stack for exception objects and throw entries ---- */
static char rt_arena[16384] __attribute__((aligned(8)));
static unsigned rt_arena_top;
static void *rt_alloc(unsigned n) {
  void *p;
  n = (n + 7u) & ~7u;
  if (rt_arena_top + n > sizeof rt_arena) rt_terminate();
  p = rt_arena + rt_arena_top;
  rt_arena_top += n;
  return p;
}
static void rt_free(void *p) { rt_arena_top = (unsigned)((char *)p - rt_arena); }

/* ---- type matching ---- */
static int rt_streq(const char *a, const char *b) {
  while (*a && *a == *b) { a++; b++; }
  return *a == *b;
}
static int rt_same(const struct rt_ti *a, const struct rt_ti *b) {
  return a == b || (a && b && rt_streq(a->name, b->name));
}
extern const int _ZTVN10__cxxabiv120__si_class_type_infoE[];
static int rt_derives(const struct rt_ti *d, const struct rt_ti *base) {
  while (d && d->vptr == _ZTVN10__cxxabiv120__si_class_type_infoE + 2) {
    d = ((const struct rt_si_ti *)d)->base_type;
    if (rt_same(d, base)) return 1;
  }
  return 0;
}
/* Index (1-based) of the matching catch entry, 0 if none. */
static int rt_match(const struct rt_ets *e, const struct rt_ti *type, unsigned flags,
                    unsigned *ptr_flags) {
  int idx = 0;
  int is_ptr = (flags & ETS_PTR) || ptr_flags;
  for (;; e++) {
    int eptr = (e->flags & ETS_PTR) || e->ptr_flags;
    int ok = 0;
    idx++;
    if ((e->flags & ETS_ELLIPSIS) && !(e->flags & (ETS_PTR | ETS_PTR_MEM_FN))) ok = 1;
    else if (eptr != is_ptr) ok = 0;
    else if (ptr_flags || e->ptr_flags) ok = 0;            /* multi-level pointers: unsupported */
    else if (rt_same(e->tinfo, type)) {
      ok = !is_ptr || !(~e->flags & flags & (ETS_CONST | ETS_VOL));
    } else if (is_ptr && !(~e->flags & flags & (ETS_CONST | ETS_VOL))) {
      /* catch (void *) or a pointer to a base class */
      ok = (e->tinfo && rt_streq(e->tinfo->name, "v")) || rt_derives(type, e->tinfo);
    } else if (!is_ptr) {
      ok = rt_derives(type, e->tinfo);
    }
    if (ok) return idx;
    if (e->flags & ETS_LAST) return 0;
  }
}

/* ---- throw stack ---- */
static void rt_destroy(struct tse *t) {
  struct tse *p = t->is_rethrow ? t->primary : t;
  if (!t->discard) {
    t->discard = 1;
    if (t->is_internal) p->discard = 1;
    p->use_count--;
  }
  if (p->use_count == 0 && !p->dtor_called) {
    p->dtor_called = 1;
    if (p->copy_done && !((p->flags & ETS_PTR) || p->ptr_flags) && p->dtor) p->dtor(p->object);
  }
}
static struct tse *rt_push(const struct rt_ti *type, void (*dtor)(), unsigned flags,
                           unsigned *ptr_flags, void *obj, int rethrow, int internal,
                           struct tse *primary) {
  struct tse *t = rt_alloc(sizeof *t);
  struct eh_entry *e = rt_eh_top;
  while (e && !((e->kind == K_TRY) && e->v.try_block.catch_info == 0)) e = e->next;
  t->enclosing_try = e;
  if (rt_throws && rt_throws->enclosing_try == e) rt_destroy(rt_throws);
  t->next = rt_throws; rt_throws = t;
  t->type = type; t->dtor = dtor; t->flags = flags; t->ptr_flags = ptr_flags; t->object = obj;
  t->pointer_buffer = 0; t->primary = primary; t->use_count = 0;
  if (internal) {} else if (rethrow) primary->use_count++; else t->use_count++;
  t->is_rethrow = (unsigned char)rethrow; t->is_internal = (unsigned char)internal;
  t->dtor_called = t->discard = t->in_handler = t->copy_done = t->eval_done = 0;
  t->marker.next = 0; t->marker.kind = K_MARKER;
  return t;
}
static void *rt_setup(const struct rt_ti *type, unsigned size, unsigned flags, unsigned *pf,
                      void (*dtor)()) {
  void *obj = rt_alloc(size);
  rt_push(type, dtor, flags, pf, obj, 0, 0, 0);
  return obj;
}
void *rt_throw_setup(const struct rt_ti *type, unsigned size, unsigned flags) __asm__("__throw_setup");
void *rt_throw_setup(const struct rt_ti *type, unsigned size, unsigned flags) {
  return rt_setup(type, size, flags, 0, 0);
}
void *rt_throw_setup_dtor(const struct rt_ti *type, unsigned size, int flags, void (*dtor)()) __asm__("__throw_setup_dtor");
void *rt_throw_setup_dtor(const struct rt_ti *type, unsigned size, int flags, void (*dtor)()) {
  return rt_setup(type, size, (unsigned)flags, 0, dtor);
}
void *rt_throw_setup_ptr(const struct rt_ti *type, unsigned size, unsigned *pf) __asm__("__throw_setup_ptr");
void *rt_throw_setup_ptr(const struct rt_ti *type, unsigned size, unsigned *pf) {
  return rt_setup(type, size, 0, pf, 0);
}
void __exception_started(void) {
  rt_throws->marker.next = rt_eh_top;
  rt_eh_top = &rt_throws->marker;
  rt_throws->eval_done = 1;
}
void __exception_caught(void) { rt_eh_top = rt_eh_top->next; }

void __free_thrown_object(void) {
  rt_destroy(rt_throws);
  while (rt_throws && rt_throws->discard) {
    struct tse *t = rt_throws;
    void *obj = t->object;
    int re = t->is_rethrow;
    rt_throws = t->next;
    rt_free(t);
    if (!re) rt_free(obj);
  }
}
void __destroy_exception_object(void) {
  struct tse *t;
  for (t = rt_throws; t; t = t->next)
    if (t->in_handler && !t->dtor_called && !t->discard) break;
  if (!t) rt_terminate();
  if (t == rt_throws) __free_thrown_object(); else rt_destroy(t);
}

/* ---- cleanup of one function's regions from `region` down to `stop` ---- */
static void rt_cleanup(struct eh_entry *e, unsigned region, unsigned stop) {
  void **objs = e->v.function.obj_table;
  while (region != stop) {
    struct rt_region *r = &e->v.function.regions[region];
    unsigned f = r->flags;
    unsigned next = r->next;
    char *obj;
    struct rt_array *arr = 0;
    void *vtbl = 0;
    int has_vtbl = 0, skip = 0;
    if (r->dtor == (void (*)())__destroy_exception_object) {
      __destroy_exception_object();
      region = next; continue;
    }
    if (f & RDF_COND) skip = !*(int *)objs[(r + 1)->handle];
    if (!skip) {
      if ((f & RDF_SUBVTBL) && (f & RDF_BASE) && !(f & RDF_ARRAY)) {
        struct rt_region *vr = r + 1 + ((f & RDF_COND) ? 1 : 0);
        has_vtbl = 1;
        vtbl = *(void **)(objs + vr->handle);
        if (vr->flags & RDF_INDIRECT) vtbl = *(void **)vtbl;
      }
      if (f & RDF_ARRAY) {
        arr = &e->v.function.array_table[r->handle];
        obj = objs[arr->handle];
      } else obj = objs[r->handle];
      if (f & RDF_INDIRECT) obj = *(char **)obj;
      if (f & RDF_GUARD) {
        *(int *)obj = 0;                       /* abandon local-static initialisation */
      } else if (!(f & RDF_NEW)) {
        if (f & RDF_ARRAY) {
          if (r->dtor) {
            long n = arr->elem_count;
            if (f & RDF_BASE) n = (long)*(unsigned *)objs[(r + 1)->handle];   /* VLA */
            while (n-- > 0) ((void (*)(void *))r->dtor)(obj + (unsigned long)n * arr->elem_size);
          }
        } else if (has_vtbl) ((void (*)(void *, void *))r->dtor)(obj, vtbl);
        else ((void (*)(void *))r->dtor)(obj);
      } else if (obj) {
        if (f & RDF_ARRAY) ((void (*)(void *, unsigned))r->dtor)(obj, arr->elem_size);
        else ((void (*)(void *))r->dtor)(obj);
      }
    }
    region = next;
  }
}

void __throw(void) {
  struct tse *t = rt_throws;
  struct eh_entry *e, *dest = 0, *real_dest = 0;
  int dest_clause = 0;
  void *obj_ptr, *obj_buf;
  int is_ptr;
  if (!t->eval_done) __exception_started();
  t->copy_done = 1;
  is_ptr = (t->flags & ETS_PTR) || t->ptr_flags;
  if (is_ptr) { obj_ptr = *(void **)t->object; obj_buf = &t->pointer_buffer; }
  else { obj_ptr = t->object; obj_buf = t->object; }
  /* pass 1: find the handler */
  for (e = rt_eh_top->next; e; e = e->next) {
    if (e->kind == K_TRY) {
      if (e->v.try_block.catch_info == 0) {
        int r = e->v.try_block.catch_entries
                    ? rt_match(e->v.try_block.catch_entries, t->type, t->flags, t->ptr_flags) : 1;
        if (r) {
          if (!dest) { dest = e; dest_clause = r; }
          if (e->v.try_block.catch_entries) { real_dest = e; break; }
        }
      }
    } else if (dest) {
      continue;
    } else if (e->kind == K_THROW_SPEC || e->kind == K_NOEXCEPT) {
      dest = e; break;
    }
  }
  if (!real_dest && !(dest && dest->kind != K_TRY)) {
    t->in_handler = 1; __exception_caught(); __call_terminate();
  }
  if (!dest) rt_terminate();
  /* pass 2: unwind to it */
  for (e = rt_eh_top->next; e != dest; e = e->next) {
    if (e->kind == K_FUNCTION) {
      rt_cleanup(e, rt_eh_region, NO_REGION);
      rt_eh_region = e->v.function.saved_region;
    } else if (e->kind == K_VEC) {
      rt_cleanup_vec(e);
    } else if (e->kind == K_TRY) {
      struct tse *q;
      for (q = rt_throws; q; q = q->next) if (q->enclosing_try == e) q->enclosing_try = 0;
    }
  }
  if (dest->kind == K_TRY && dest->v.try_block.region_number != rt_eh_region) {
    struct eh_entry *f = dest->next;
    while (f->kind != K_FUNCTION) f = f->next;
    rt_cleanup(f, rt_eh_region, dest->v.try_block.region_number);
    rt_eh_region = dest->v.try_block.region_number;
  }
  rt_eh_top->next = dest;
  t->in_handler = 1;
  if (dest->kind == K_TRY) {
    /* Re-run the match to get the (possibly base-adjusted) pointer; offsets are 0 here. */
    rt_catch_clause = dest_clause;
    if (is_ptr) { *(void **)obj_buf = obj_ptr; rt_caught_addr = obj_buf; }
    else rt_caught_addr = obj_ptr;
    dest->v.try_block.catch_info = t;
    rt_longjmp(dest->v.try_block.jb, 1);
  }
  rt_eh_top = rt_eh_top->next;
  rt_terminate();
}

static void rt_rethrow(int internal) {
  struct tse *t = rt_throws;
  while (t && !(t->in_handler && !t->is_rethrow)) t = t->next;
  if (!t) rt_terminate();
  rt_push(t->type, t->dtor, t->flags, t->ptr_flags, t->object, 1, internal, t);
  __throw();
}
void __rethrow(void) { rt_rethrow(0); }
void __internal_rethrow(void) { __exception_caught(); rt_rethrow(1); }
