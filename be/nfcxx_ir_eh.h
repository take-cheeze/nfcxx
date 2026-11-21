/* nfcxx Path B: zero-cost exception handling in the IR (docs/notes/pathb-zero-cost-eh.md). Included by nfcxx_ir.c in a
   harness built with PATHB_EH=tables (scripts/setup-pathb.sh): EDG's partial EH lowering keeps try, catch and throw in
   the IL, describes the cleanups in the region table, and says which region is current with leck_cleanup_state nodes.

   A landing pad is identified by a region and the innermost try (or internal try) around the code: the calls after
   (eh-state N) unwind to pad N, whose code (eh-pad N ...) does what EDG's runtime (lib_src/throw.c, cleanup()) would do
   for the region chain, then dispatches to the try's catch clauses, then goes on outwards, and finally resumes the
   unwind (or calls std::terminate in a noexcept function). throw and catch are the Itanium C++ ABI's calls
   (__cxa_allocate_exception, __cxa_throw, __cxa_rethrow, __cxa_begin_catch, __cxa_end_catch: libstdc++). */
#if DO_IL_LOWERING && !DO_FULL_PORTABLE_EH_LOWERING && GENERATE_EH_TABLES
#define IR_EH_TABLES 1
#include "lower_il.h"
#include "lower_eh.h"

/* region table entry flags (EDG's runtime, lib_src/eh.h) */
enum {
  IR_RDF_INDIRECT = 0x01,
  IR_RDF_CONDITIONAL_FLAG = 0x02,
  IR_RDF_NEW_ALLOCATION = 0x04,
  IR_RDF_ARRAY = 0x08,
  IR_RDF_THIS_PARAM_OFFSET = 0x10,
  IR_RDF_SUBOBJECT_VTABLE = 0x20,
  IR_RDF_BASE_CLASS_SUBOBJECT = 0x40, /* also the VLA flag, with IR_RDF_ARRAY */
  IR_RDF_GUARD_VAR_FOR_LOCAL_STATIC = 0x80
};

typedef struct ir_eh_rte {        /* a region table entry */
  a_routine_ptr rout;             /* destructor or operator delete; NULL for a flag or VTT entry */
  a_constant_ptr handle;          /* the object (ck_stack_offset), or the array table index (ck_integer) */
  unsigned long next;             /* the next region, null_eh_region_number at the end */
  unsigned flags;
} ir_eh_rte;

typedef struct ir_eh_ate {        /* an array table entry */
  a_constant_ptr handle;
  unsigned long long elem_size;
  long long count;
} ir_eh_ate;

#define IR_EH_MAXH 64
typedef struct ir_eh_frame {
  struct ir_eh_frame *parent;
  unsigned long entry_region;     /* the region current where the frame begins */
  int id;
  an_expr_node_ptr action;        /* an internal try: the expression to evaluate when unwinding */
  int nh;                         /* a try: its catch clauses */
  int tid[IR_EH_MAXH];
  char *label[IR_EH_MAXH];
} ir_eh_frame;

typedef struct ir_eh_pad {
  unsigned long region;
  ir_eh_frame *frame;
} ir_eh_pad;

static int ir_eh_on;               /* the current function has exception tables to emit */
static int ir_eh_noexcept;         /* ... and an exception that leaves it calls std::terminate */
static unsigned long ir_eh_region; /* the current region */
static ir_eh_frame *ir_eh_cur;     /* the innermost try around the code */
static int ir_eh_last;             /* the pad of the last (eh-state N), -1 before the first */
static ir_eh_pad *ir_eh_pads;
static int ir_eh_npad, ir_eh_cappad;
static ir_eh_rte *ir_eh_rt;
static int ir_eh_nrt;
static ir_eh_ate *ir_eh_at;
static int ir_eh_nat;
static const char *ir_eh_type[256];   /* the type table: the typeinfo operand of type id i + 1, NULL for catch (...) */
static int ir_eh_ntype;
static int ir_eh_nframe;
static char *ir_eh_thrown;          /* the exception object of the throw being lowered (leck_thrown_object_address) */
static char *ir_eh_caught;          /* the caught object of the handler being lowered (leck_caught_object_address) */
static char ir_eh_k_exc, ir_eh_k_sel; /* keys of the pad slots */
static const char *ir_eh_why;       /* why the last cleanup could not be written */
static int ir_eh_spec[IR_EH_MAXH];  /* a dynamic exception specification (C++14 throw(T...)): the type ids it allows */
static int ir_eh_nspec;             /* their number: 0 for none (and for throw(), which is noexcept here) */

static a_type_ptr ir_eh_vptr_type(void) { return make_pointer_type(void_type()); }
static a_type_ptr ir_eh_long_type(void) { return integer_type((an_integer_kind)ik_long); }

static const char *ir_eh_exc_slot(void) { return ir_slot_op(&ir_eh_k_exc, "eh.exc", ir_eh_vptr_type(), 8); }
static const char *ir_eh_sel_slot(void) { return ir_slot_op(&ir_eh_k_sel, "eh.sel", ir_eh_long_type(), 8); }

static int ir_eh_type_id(a_variable_ptr ti);
static void ir_eh_sync(void);

/* the function begins: is it noexcept (noexcept, noexcept(true), throw()) */
static void ir_eh_begin(a_routine_ptr rout)
{
  a_type_ptr ft = skip_typerefs(rout->type);
  an_exception_specification_ptr esp = NULL;
  ir_eh_on = 0;
  ir_eh_noexcept = 0;
  if (ft->kind == tk_routine && ft->variant.routine.extra_info != NULL)
    esp = ft->variant.routine.extra_info->exception_specification;
  if (esp != NULL && !esp->throw_any && !esp->indeterminate && !esp->arg_cached && !esp->copy_from_prototype &&
      (esp->is_noexcept || esp->variant.exception_specification_type_list == NULL))
    ir_eh_noexcept = 1;
  ir_eh_region = null_eh_region_number;
  ir_eh_cur = NULL;
  ir_eh_last = -1;
  ir_eh_npad = 0;
  ir_eh_nrt = 0;
  ir_eh_nat = 0;
  ir_eh_ntype = 0;
  ir_eh_nframe = 0;
  ir_eh_thrown = NULL;
  ir_eh_caught = NULL;
  ir_eh_nspec = 0;
  if (esp != NULL && !ir_eh_noexcept && !esp->is_noexcept && !esp->throw_any && !esp->indeterminate && !esp->arg_cached &&
      !esp->copy_from_prototype) {
    /* throw(T...): an exception of another type that leaves the function calls std::unexpected
       (__cxa_call_unexpected, from every landing pad: each call has one, with the specification's filter last) */
    an_exception_specification_type_ptr espt;
    for (espt = esp->variant.exception_specification_type_list; espt != NULL; espt = espt->next) {
      a_type_ptr t = skip_typerefs(espt->type);
      if (is_reference_type(t)) t = skip_typerefs(type_pointed_to(t));
      t = skip_typerefs(make_unqualified_type(t));
      /* a pointer's typeinfo here is its own (__pointer_type_info) only when something made one: EDG's tables
         describe a pointer by its pointed-to type, so a pointer type of a specification alone has none */
      if (t->typeinfo_var == NULL || ir_eh_nspec == IR_EH_MAXH) {
        ir_line(1, "(unsupported dynamic exception specification of a type without typeinfo)");
        ir_eh_nspec = 0;
        break;
      }
      ir_eh_spec[ir_eh_nspec++] = ir_eh_type_id(t->typeinfo_var);
    }
    if (ir_eh_nspec > 0) {
      ir_eh_on = 1;
      ir_depth = 1;
      ir_eh_sync(); /* the calls before any cleanup state have the specification's pad too */
    }
  }
}

/* the type id of a catch clause's typeinfo variable (NULL: catch (...)) */
static int ir_eh_type_id(a_variable_ptr ti)
{
  const char *op = ti != NULL ? ir_global_op(ti) : NULL;
  int i;
  for (i = 0; i < ir_eh_ntype; i++)
    if ((op == NULL && ir_eh_type[i] == NULL) || (op != NULL && ir_eh_type[i] != NULL && strcmp(op, ir_eh_type[i]) == 0))
      return i + 1;
  if (ir_eh_ntype == (int)(sizeof ir_eh_type / sizeof ir_eh_type[0])) return -1;
  ir_eh_type[ir_eh_ntype++] = op;
  return ir_eh_ntype;
}

/* the pad of (region, frame): 0 when an exception just passes through */
static int ir_eh_pad_id(unsigned long region, ir_eh_frame *frame)
{
  int i;
  if (region == null_eh_region_number && frame == NULL && ir_eh_nspec == 0) return 0;
  for (i = 0; i < ir_eh_npad; i++)
    if (ir_eh_pads[i].region == region && ir_eh_pads[i].frame == frame) return i + 1;
  if (ir_eh_npad == ir_eh_cappad) {
    ir_eh_cappad = ir_eh_cappad ? 2 * ir_eh_cappad : 16;
    ir_eh_pads = (ir_eh_pad *)realloc(ir_eh_pads, ir_eh_cappad * sizeof ir_eh_pads[0]);
    if (ir_eh_pads == NULL) abort();
  }
  ir_eh_pads[ir_eh_npad].region = region;
  ir_eh_pads[ir_eh_npad].frame = frame;
  return ++ir_eh_npad;
}

/* (eh-state N) at each change. Not only when it differs from the last one in the text: the state is the state of the
   control flow (a block begins in its predecessor's state, scripts/pathb-ssa.rb), and the code after a branch that
   returned can be back in a state the text left before the branch. */
static void ir_eh_sync(void)
{
  int id = ir_eh_pad_id(ir_eh_region, ir_eh_cur);
  ir_eh_on = 1;
  ir_eh_last = id;
  ir_emit(ir_fmt("(eh-state %d)", id));
}

/* the integer of a constant (0 for anything else) */
static long long ir_eh_int(a_constant_ptr c)
{
  if (c == NULL || c->kind != ck_integer) return 0;
  return strtoll(ir_capture_constant(c), NULL, 10);
}

/* the static initializer of a function-local static (the region and array tables) */
static a_constant_ptr ir_eh_local_static_init(a_variable_ptr v)
{
  a_local_static_variable_init_ptr li;
  if (v == NULL) return NULL;
  if (v->init_kind == initk_static) return v->initializer.constant;
  if (ir_cur_scope != NULL)
    for (li = ir_cur_scope->local_static_variable_inits; li != NULL; li = li->next)
      if (li->variable == v && li->init_kind == initk_static) return li->initializer.constant;
  return NULL;
}

static int ir_eh_count(a_constant_ptr t)
{
  a_constant_ptr e;
  int n = 0;
  if (t != NULL && t->kind == ck_aggregate)
    for (e = t->variant.aggregate.first_constant; e != NULL; e = e->next) n++;
  return n;
}

/* leck_function_prologue: read the function's region and array tables */
static void ir_eh_prologue(an_eh_prologue_supplement_ptr psp)
{
  a_constant_ptr t, e, f;
  ir_eh_on = 1;
  t = ir_eh_local_static_init(psp->region_table);
  ir_eh_rt = (ir_eh_rte *)realloc(ir_eh_rt, (ir_eh_count(t) + 1) * sizeof ir_eh_rt[0]);
  ir_eh_nrt = 0;
  if (t != NULL && t->kind == ck_aggregate)
    for (e = t->variant.aggregate.first_constant; e != NULL; e = e->next) {
      ir_eh_rte *r = &ir_eh_rt[ir_eh_nrt++];
      memset(r, 0, sizeof *r);
      if (e->kind != ck_aggregate) continue;
      f = e->variant.aggregate.first_constant;
      if (f != NULL && f->kind == ck_address && f->variant.address.kind == abk_routine) r->rout = f->variant.address.variant.routine;
      f = f != NULL ? f->next : NULL;
      r->handle = f;
      f = f != NULL ? f->next : NULL;
      r->next = (unsigned long)ir_eh_int(f);
      f = f != NULL ? f->next : NULL;
      r->flags = (unsigned)ir_eh_int(f);
    }
  t = ir_eh_local_static_init(psp->array_table);
  ir_eh_at = (ir_eh_ate *)realloc(ir_eh_at, (ir_eh_count(t) + 1) * sizeof ir_eh_at[0]);
  ir_eh_nat = 0;
  if (t != NULL && t->kind == ck_aggregate)
    for (e = t->variant.aggregate.first_constant; e != NULL; e = e->next) {
      ir_eh_ate *a = &ir_eh_at[ir_eh_nat++];
      memset(a, 0, sizeof *a);
      if (e->kind != ck_aggregate) continue;
      f = e->variant.aggregate.first_constant;
      a->handle = f;
      f = f != NULL ? f->next : NULL;
      a->elem_size = (unsigned long long)ir_eh_int(f);
      f = f != NULL ? f->next : NULL;
      a->count = ir_eh_int(f);
    }
}

/* the function's this parameter */
static a_variable_ptr ir_eh_this(void)
{
  a_variable_ptr p;
  if (ir_cur_scope == NULL) return NULL;
  for (p = ir_cur_scope->variant.routine.parameters; p != NULL; p = p->next)
    if (p->is_this_parameter) return p;
  return NULL;
}

static char *ir_eh_offset(char *base, long long off)
{
  if (off == 0) return base;
  return ir_let("(ptr void)", ir_fmt("(offset %s %lld)", base, off));
}

/* The address a handle names: a stack offset (a variable and an offset), the address of a static (a local static's
   guard), or with RDF_THIS_PARAM_OFFSET an offset from this (a subobject in a constructor). NULL when it is another
   form. Writes nothing when write is 0 (the check before any code is written). */
static char *ir_eh_addr_f(a_constant_ptr h, unsigned fl, int write)
{
  if (h == NULL) return NULL;
  if (fl & IR_RDF_THIS_PARAM_OFFSET) {
    a_variable_ptr t = ir_eh_this();
    if (h->kind != ck_integer || t == NULL) return NULL;
    if (!write) return "";
    return ir_eh_offset(ir_let("(ptr void)", ir_fmt("(load (ptr void) %s)", ir_var_addr(t, t->type, 0).s)), ir_eh_int(h));
  }
  if (h->kind == ck_stack_offset && h->variant.stack_offset.variable != NULL) {
    if (!write) return "";
    return ir_eh_offset(ir_var_addr(h->variant.stack_offset.variable, h->variant.stack_offset.variable->type, 0).s,
                        (long long)h->variant.stack_offset.offset);
  }
  if (h->kind == ck_address && h->variant.address.kind == abk_variable && h->variant.address.variant.variable != NULL) {
    a_variable_ptr v = h->variant.address.variant.variable;
    if (!write) return "";
    return ir_eh_offset(ir_var_addr(v, v->type, 0).s, (long long)h->variant.address.offset);
  }
  return NULL;
}

static char *ir_eh_addr(a_constant_ptr h) { return ir_eh_addr_f(h, 0, 1); }

static char *ir_eh_rout_op(a_routine_ptr r)
{
  const char *why = NULL;
  const char *sym = r != NULL ? ir_rout_addr(r, &why) : NULL;
  return sym != NULL ? (char *)sym : NULL;
}

static int ir_eh_is_destroy_exc(a_routine_ptr r)
{
  return r != NULL && r->source_corresp.name != NULL && strcmp(r->source_corresp.name, "__destroy_exception_object") == 0;
}

/* The cleanup of region table entry i (lib_src/throw.c, cleanup()). Returns 0 when it cannot be written. */
static int ir_eh_cleanup(int i)
{
  ir_eh_rte *r;
  unsigned fl;
  char *flag = NULL, *vtt = NULL, *obj, *dtor;
  int next = i + 1, d = ir_depth;
  ir_eh_ate *a = NULL;
  ir_eh_why = ir_fmt("region %d of %d", i, ir_eh_nrt);
  if (i < 0 || i >= ir_eh_nrt) return 0;
  r = &ir_eh_rt[i];
  ir_eh_why = ir_fmt("region %d flags 0x%x handle kind %d rout %s", i, r->flags, r->handle != NULL ? (int)r->handle->kind : -1,
                     r->rout != NULL && r->rout->source_corresp.name != NULL ? r->rout->source_corresp.name : "-");
  fl = r->flags;
  if (ir_eh_is_destroy_exc(r->rout)) {
    ir_emit("(eval (call void &\"__cxa_end_catch\"))"); /* the caught exception, when its handler is left by a throw */
    return 1;
  }
  if (fl & IR_RDF_CONDITIONAL_FLAG) {
    if (next >= ir_eh_nrt || ir_eh_addr_f(ir_eh_rt[next].handle, ir_eh_rt[next].flags, 0) == NULL) return 0;
    next++;
  }
  if ((fl & IR_RDF_SUBOBJECT_VTABLE) && (fl & IR_RDF_BASE_CLASS_SUBOBJECT) && !(fl & IR_RDF_ARRAY)) {
    if (next >= ir_eh_nrt || ir_eh_addr_f(ir_eh_rt[next].handle, ir_eh_rt[next].flags, 0) == NULL) return 0;
  }
  if (fl & IR_RDF_ARRAY) {
    long long k = ir_eh_int(r->handle);
    if (k < 0 || k >= ir_eh_nat) return 0;
    a = &ir_eh_at[k];
    if (ir_eh_addr_f(a->handle, fl & IR_RDF_THIS_PARAM_OFFSET, 0) == NULL) return 0;
  } else if (ir_eh_addr_f(r->handle, fl, 0) == NULL) {
    return 0;
  }
  if ((fl & IR_RDF_ARRAY) && (fl & IR_RDF_BASE_CLASS_SUBOBJECT) && !(fl & IR_RDF_NEW_ALLOCATION) &&
      (i + 1 >= ir_eh_nrt || ir_eh_addr_f(ir_eh_rt[i + 1].handle, ir_eh_rt[i + 1].flags, 0) == NULL))
    return 0; /* a VLA without its element count */
  dtor = ir_eh_rout_op(r->rout);
  if (!(fl & IR_RDF_GUARD_VAR_FOR_LOCAL_STATIC) && dtor == NULL && !((fl & IR_RDF_ARRAY) && !(fl & IR_RDF_NEW_ALLOCATION)))
    return 0;
  /* everything is known: write it */
  if (fl & IR_RDF_CONDITIONAL_FLAG) {
    flag = ir_eh_addr_f(ir_eh_rt[i + 1].handle, ir_eh_rt[i + 1].flags, 1);
    ir_line(d, ir_fmt("(if %s", ir_let("bool", ir_fmt("(ne int %s (const int 0))", ir_let("int", ir_fmt("(load int %s)", flag))))));
    ir_line(d + 1, "(then");
    ir_depth = d + 2;
  }
  if ((fl & IR_RDF_SUBOBJECT_VTABLE) && (fl & IR_RDF_BASE_CLASS_SUBOBJECT) && !(fl & IR_RDF_ARRAY)) {
    char *va = ir_eh_addr_f(ir_eh_rt[next].handle, ir_eh_rt[next].flags, 1);
    vtt = ir_let("(ptr void)", ir_fmt("(load (ptr void) %s)", va));
    if (ir_eh_rt[next].flags & IR_RDF_INDIRECT) vtt = ir_let("(ptr void)", ir_fmt("(load (ptr void) %s)", vtt));
  }
  obj = a != NULL ? ir_eh_addr_f(a->handle, fl & IR_RDF_THIS_PARAM_OFFSET, 1) : ir_eh_addr_f(r->handle, fl, 1);
  if (fl & IR_RDF_INDIRECT) obj = ir_let("(ptr void)", ir_fmt("(load (ptr void) %s)", obj));
  if (fl & IR_RDF_GUARD_VAR_FOR_LOCAL_STATIC) {
    ir_emit(ir_fmt("(eval (call void &\"__cxa_guard_abort\" %s))", obj));
  } else if (!(fl & IR_RDF_NEW_ALLOCATION)) {
    if (fl & IR_RDF_ARRAY) {
      if (dtor != NULL) {
        char *count;
        if (fl & IR_RDF_BASE_CLASS_SUBOBJECT) { /* a VLA: its element count is in the next entry's object */
          char *ca = ir_eh_addr_f(ir_eh_rt[i + 1].handle, ir_eh_rt[i + 1].flags, 1);
          count = ir_let("unsigned_long", ir_fmt("(load unsigned_long %s)", ca));
        } else {
          count = ir_fmt("(const unsigned_long %lld)", a->count);
        }
        ir_emit(ir_fmt("(eval (call void &\"__cxa_vec_cleanup\" %s %s (const unsigned_long %llu) &\"%s\"))", obj, count,
                       a->elem_size, dtor));
      }
    } else if (vtt != NULL) {
      ir_emit(ir_fmt("(eval (call void &\"%s\" %s %s))", dtor, obj, vtt));
    } else {
      ir_emit(ir_fmt("(eval (call void &\"%s\" %s))", dtor, obj));
    }
  } else {
    int e = ir_depth;
    ir_line(e, ir_fmt("(if %s", ir_let("bool", ir_fmt("(ne (ptr void) %s (null (ptr void)))", obj))));
    ir_line(e + 1, "(then");
    ir_depth = e + 2;
    if (fl & IR_RDF_ARRAY) ir_emit(ir_fmt("(eval (call void &\"%s\" %s (const unsigned_long %llu)))", dtor, obj, a->elem_size));
    else ir_emit(ir_fmt("(eval (call void &\"%s\" %s))", dtor, obj));
    ir_close(2);
    ir_depth = e;
  }
  if (flag != NULL) {
    ir_close(2);
    ir_depth = d;
  }
  return 1;
}

/* The pads share their code, as gcc's do: each pad is a stub that keeps the exception and the selector, then jumps into
   a chain of nodes, each written once. A region node runs its region's cleanup and goes on to the next region's node; a
   frame node (a try's catch clauses, an internal try's action) goes on to the node of the region the frame began in;
   the end node resumes the unwind (or calls std::terminate, or std::unexpected first). Code then grows with the regions,
   not with regions times their depth. */
typedef struct ir_eh_node {
  unsigned long r;                /* a region node: (r, f); a frame node: (f->entry_region, f); the end: (null, NULL) */
  ir_eh_frame *f;
} ir_eh_node;

static ir_eh_node *ir_eh_nodes;
static int ir_eh_nnode, ir_eh_capnode;

static char *ir_eh_node_label(unsigned long r, ir_eh_frame *f)
{
  if (f == NULL && r == null_eh_region_number) return "eh.x";
  if (f != NULL && r == f->entry_region) return ir_fmt("eh.f.%d", f->id);
  return ir_fmt("eh.c.%lu.%d", r, f != NULL ? f->id : 0);
}

/* the node (r, f), added to the list of nodes to write when it is new */
static void ir_eh_node_want(unsigned long r, ir_eh_frame *f)
{
  int i;
  for (i = 0; i < ir_eh_nnode; i++)
    if (ir_eh_nodes[i].r == r && ir_eh_nodes[i].f == f) return;
  if (ir_eh_nnode == ir_eh_capnode) {
    ir_eh_capnode = ir_eh_capnode ? 2 * ir_eh_capnode : 32;
    ir_eh_nodes = (ir_eh_node *)realloc(ir_eh_nodes, ir_eh_capnode * sizeof ir_eh_nodes[0]);
    if (ir_eh_nodes == NULL) abort();
  }
  ir_eh_nodes[ir_eh_nnode].r = r;
  ir_eh_nodes[ir_eh_nnode].f = f;
  ir_eh_nnode++;
}

/* Pad n's action chain (its catch clauses' type ids, in order) and whether it cleans up; the nodes it reaches are
   wanted. 0 when the chain is malformed. */
static int ir_eh_pad_walk(int n, int *types, int *ntypes, int *cleanup)
{
  unsigned long r = ir_eh_pads[n].region;
  ir_eh_frame *f = ir_eh_pads[n].frame;
  int guard = 0, k;
  *ntypes = 0;
  *cleanup = ir_eh_noexcept;
  for (;;) {
    unsigned long bound = f != NULL ? f->entry_region : null_eh_region_number;
    while (r != bound && r != null_eh_region_number) {
      if (guard++ > 100000 || r >= (unsigned long)ir_eh_nrt) return 0;
      ir_eh_node_want(r, f);
      *cleanup = 1;
      r = ir_eh_rt[r].next;
    }
    if (f == NULL) break;
    ir_eh_node_want(f->entry_region, f);
    if (f->action != NULL) *cleanup = 1;
    for (k = 0; k < f->nh; k++)
      if (*ntypes < IR_EH_MAXH) types[(*ntypes)++] = f->tid[k];
    r = f->entry_region;
    f = f->parent;
  }
  ir_eh_node_want(null_eh_region_number, NULL);
  return 1;
}

/* the code of a node (at ir_depth); 0 when a cleanup cannot be written */
static int ir_eh_node_code(ir_eh_node *nd)
{
  ir_eh_frame *f = nd->f;
  int k;
  ir_line(ir_depth, ir_fmt("(label \"%s\")", ir_eh_node_label(nd->r, f)));
  if (f == NULL && nd->r == null_eh_region_number) {
    if (ir_eh_nspec > 0) {
      /* the specification's filter: a negative selector, when the exception is not one the specification allows */
      char *sel = ir_let("long", ir_fmt("(load long %s)", ir_eh_sel_slot()));
      ir_line(ir_depth, ir_fmt("(if %s", ir_let("bool", ir_fmt("(lt.s long %s (const long 0))", sel))));
      ir_line(ir_depth + 1, "(then");
      ir_depth += 2;
      ir_emit(ir_fmt("(eval (call void &\"__cxa_call_unexpected\" %s))",
                     ir_let("(ptr void)", ir_fmt("(load (ptr void) %s)", ir_eh_exc_slot()))));
      ir_emit("(unreachable)");
      ir_close(2);
      ir_depth -= 2;
    }
    if (ir_eh_noexcept) {
      ir_emit("(eval (call void &\"_ZSt9terminatev\"))");
      ir_emit("(unreachable)");
    } else {
      ir_emit(ir_fmt("(eh-resume %s)", ir_let("(ptr void)", ir_fmt("(load (ptr void) %s)", ir_eh_exc_slot()))));
    }
    return 1;
  }
  if (f != NULL && nd->r == f->entry_region) {
    if (f->action != NULL) (void)ir_rval(f->action);
    for (k = 0; k < f->nh; k++) {
      char *sel = ir_let("long", ir_fmt("(load long %s)", ir_eh_sel_slot()));
      /* (eh-tid N): the type id as a constant (scripts/pathb-ssa.rb), which the inliner renumbers in a caller's table */
      char *c = ir_let("bool", ir_fmt("(eq long %s (eh-tid %d))", sel, f->tid[k]));
      ir_line(ir_depth, ir_fmt("(if %s", c));
      ir_line(ir_depth + 1, ir_fmt("(then (goto \"%s\")))", f->label[k]));
    }
    ir_line(ir_depth, ir_fmt("(goto \"%s\")", ir_eh_node_label(f->entry_region, f->parent)));
    return 1;
  }
  if (!ir_eh_cleanup((int)nd->r)) return 0;
  {
    unsigned long next = ir_eh_rt[nd->r].next;
    unsigned long bound = f != NULL ? f->entry_region : null_eh_region_number;
    if (next == null_eh_region_number) next = bound; /* the chain ends: the frame's node, or the end */
    ir_line(ir_depth, ir_fmt("(goto \"%s\")", ir_eh_node_label(next, f)));
  }
  return 1;
}

/* the pads, after the body (at depth 1, in the body's buffer): each pad's stub, and the nodes after the last stub */
static void ir_eh_end_body(void)
{
  int n, i, types[IR_EH_MAXH], nt, cl, ok = 1;
  ir_buf code;
  if (!ir_eh_on || ir_eh_npad == 0) return;
  ir_eh_nnode = 0;
  ir_buf_open(&code);
  ir_buf_begin(&code);
  for (n = 0; n < ir_eh_npad && ok; n++) {
    ok = ir_eh_pad_walk(n, types, &nt, &cl);
    if (!ok) break;
    ir_line(1, ir_fmt("(eh-pad %d %d (", n + 1, cl));
    for (i = 0; i < nt; i++) fprintf(nf_out, "%s%d", i ? " " : "", types[i]);
    fputs(")", nf_out);
    ir_depth = 2;
    ir_emit(ir_fmt("(store (ptr void) %s %s)", ir_eh_exc_slot(), ir_let("(ptr void)", "(call (ptr void) &\"__nfcxx_eh_ptr\")")));
    ir_emit(ir_fmt("(store long %s %s)", ir_eh_sel_slot(), ir_let("long", "(call long &\"__nfcxx_eh_sel\")")));
    ir_line(2, ir_fmt("(goto \"%s\")", ir_eh_node_label(ir_eh_pads[n].region, ir_eh_pads[n].frame)));
    if (n + 1 < ir_eh_npad) fputs(")", nf_out);
  }
  /* the nodes (a list that grows only in the walks above), in the last pad's form */
  for (i = 0; i < ir_eh_nnode && ok; i++) ok = ir_eh_node_code(&ir_eh_nodes[i]);
  if (ok) fputs(")", nf_out);
  ir_buf_end(&code);
  if (ok) ir_buf_write(&code, nf_out);
  else ir_line(1, ir_fmt("(unsupported exception cleanup: %s)", ir_eh_why != NULL ? ir_eh_why : "?"));
  ir_buf_close(&code);
  ir_depth = 1;
}

/* the function's header forms: its type table, and noexcept */
static void ir_eh_header(FILE *out)
{
  int i;
  if (ir_eh_noexcept) fputs("\n  (eh-noexcept)", out);
  if (ir_eh_nspec > 0) {
    fputs("\n  (eh-spec", out);
    for (i = 0; i < ir_eh_nspec; i++) fprintf(out, " %d", ir_eh_spec[i]);
    fputs(")", out);
  }
  if (ir_eh_ntype == 0) return;
  fputs("\n  (eh-types", out);
  for (i = 0; i < ir_eh_ntype; i++) fprintf(out, " %s", ir_eh_type[i] != NULL ? ir_eh_type[i] : "0");
  fputs(")", out);
}

/* enk_lowered_eh_construct */
static ir_val ir_eh_construct(an_expr_node_ptr e)
{
  switch (e->variant.lowered_eh.kind) {
    case leck_cleanup_state:
    case leck_unreachable_cleanup_state:
      ir_eh_region = (unsigned long)e->variant.lowered_eh.variant.cleanup_region_number;
      ir_eh_sync();
      return ir_mk_void();
    case leck_function_prologue:
      ir_eh_prologue(e->variant.lowered_eh.variant.prologue_info);
      return ir_mk_void();
    case leck_thrown_object_address:
      if (ir_eh_thrown == NULL) return ir_gap(e->type, "thrown object address outside a throw", 2, (int)e->kind);
      return ir_mk_value(ir_eh_thrown, e->type);
    case leck_caught_object_address:
      if (ir_eh_caught == NULL) return ir_gap(e->type, "caught object address outside a handler", 2, (int)e->kind);
      return ir_mk_value(ir_eh_caught, e->type);
    case leck_catch_epilogue:
      ir_emit("(eval (call void &\"__cxa_end_catch\"))");
      return ir_mk_void();
    case leck_function_epilogue:
    case leck_try_epilogue:
    case leck_exception_caught:
    case leck_exception_started:
      return ir_mk_void();
    case leck_internal_try: {
      an_expr_node_ptr tryx = e->variant.lowered_eh.variant.try_and_catch_expr;
      ir_eh_frame *f;
      if (tryx == NULL || tryx->next == NULL) return ir_gap(e->type, "internal try", 2, (int)e->kind);
      f = (ir_eh_frame *)calloc(1, sizeof *f);
      f->parent = ir_eh_cur;
      f->entry_region = ir_eh_region;
      f->id = ++ir_eh_nframe;
      f->action = tryx->next;
      ir_eh_cur = f;
      ir_eh_sync();
      (void)ir_rval(tryx);
      ir_eh_cur = f->parent;
      ir_eh_sync();
      return ir_mk_void();
    }
    default:
      return ir_gap(e->type, "lowered exception construct", 2, (int)e->kind);
  }
}

/* enk_throw */
static ir_val ir_eh_throw(an_expr_node_ptr e)
{
  a_throw_supplement_ptr tsp = e->variant.throw_info;
  a_type_ptr t;
  unsigned long long size;
  char *saved = ir_eh_thrown, *ti;
  const char *dtor = NULL;
  ir_eh_on = 1;
  if (tsp == NULL) {
    ir_emit("(eval (call void &\"__cxa_rethrow\"))");
    ir_emit("(unreachable)");
    return ir_mk_void();
  }
  /* a lowered std::nullptr_t is a typeref to void *, with the nullptr type beneath: the thrown type is that one */
  t = is_or_was_nullptr_type(tsp->type) ? get_underlying_type(tsp->type) : skip_typerefs(tsp->type);
  if (t->typeinfo_var == NULL)
    return ir_gap(e->type, ir_fmt("throw of a type without typeinfo (type kind %d, nullptr %d)", (int)t->kind,
                                  (int)is_or_was_nullptr_type(t)), 2, (int)e->kind);
  ti = (char *)ir_global_op(t->typeinfo_var);
  if (tsp->destructor != NULL && (dtor = ir_eh_rout_op(tsp->destructor)) == NULL)
    return ir_gap(e->type, "throw: destructor", 2, (int)e->kind);
  size = ir_size_of(t);
  ir_eh_thrown = ir_let("(ptr void)", ir_fmt("(call (ptr void) &\"__cxa_allocate_exception\" (const unsigned_long %llu))",
                                              size ? size : 1));
  if (tsp->expr != NULL) (void)ir_rval(tsp->expr);
  ir_emit(ir_fmt("(eval (call void &\"__cxa_throw\" %s %s %s))", ir_eh_thrown, ti,
                 dtor != NULL ? ir_fmt("&\"%s\"", dtor) : "(null (ptr void))"));
  ir_emit("(unreachable)");
  ir_eh_thrown = saved;
  return ir_mk_void();
}

/* A catch clause of a pointer type, or of a reference to one (not a reference to a class: catch (D &d)) */
static int ir_eh_caught_is_pointer(a_type_ptr t)
{
  t = skip_typerefs(t);
  if (is_reference_type(t)) t = skip_typerefs(type_pointed_to(t));
  return is_pointer_type(t) && !is_ptr_to_member_type(t);
}

/* stmk_try_block */
static void ir_eh_try(a_statement_ptr s, int d)
{
  a_try_supplement_ptr tsp = s->variant.try_block;
  a_handler_ptr h;
  ir_eh_frame *f;
  int k, id;
  char *end;
  for (h = tsp->handlers, k = 0; h != NULL; h = h->next) k++;
  if (k == 0 || k > IR_EH_MAXH) {
    ir_line(d, "(unsupported stmt try_block (catch clauses))");
    return;
  }
  f = (ir_eh_frame *)calloc(1, sizeof *f);
  ir_eh_on = 1;
  f->parent = ir_eh_cur;
  f->entry_region = ir_eh_region;
  f->id = id = ++ir_eh_nframe;
  end = ir_fmt("eh.e.%d", id);
  for (h = tsp->handlers, k = 0; h != NULL; h = h->next, k++) {
    f->tid[k] = ir_eh_type_id(h->parameter != NULL || h->typeinfo_var != NULL ? h->typeinfo_var : NULL);
    f->label[k] = ir_fmt("eh.h.%d.%d", id, k);
  }
  f->nh = k;
  ir_eh_cur = f;
  ir_depth = d;
  ir_eh_sync();
  ir_stmt(tsp->statement, d);
  ir_eh_cur = f->parent;
  ir_eh_region = f->entry_region;
  ir_depth = d;
  ir_eh_sync();
  ir_line(d, ir_fmt("(goto \"%s\")", end));
  for (h = tsp->handlers, k = 0; h != NULL; h = h->next, k++) {
    char *saved = ir_eh_caught, *p;
    ir_line(d, ir_fmt("(label \"%s\")", f->label[k]));
    ir_depth = d;
    ir_eh_last = -1; /* the handler is entered from a pad: say its state */
    ir_eh_region = f->entry_region;
    ir_eh_sync();
    p = ir_let("(ptr void)", ir_fmt("(call (ptr void) &\"__cxa_begin_catch\" %s)",
                                    ir_let("(ptr void)", ir_fmt("(load (ptr void) %s)", ir_eh_exc_slot()))));
    if (h->parameter != NULL && ir_eh_caught_is_pointer(h->parameter->type)) {
      /* catch (T *p), catch (T *&p): __cxa_begin_catch gives the pointer itself; the lowered copy reads it from an object */
      ir_val tmp = ir_temp(ir_eh_vptr_type());
      ir_store(ir_eh_vptr_type(), tmp.s, p, 0);
      p = (char *)tmp.s;
    }
    ir_eh_caught = p;
    ir_stmt(h->statement, d);
    ir_eh_caught = saved;
    ir_eh_region = f->entry_region;
    ir_depth = d;
    ir_eh_sync();
    ir_line(d, ir_fmt("(goto \"%s\")", end));
  }
  ir_line(d, ir_fmt("(label \"%s\")", end));
  ir_depth = d;
  ir_eh_last = -1;
  ir_eh_sync();
}
#endif
