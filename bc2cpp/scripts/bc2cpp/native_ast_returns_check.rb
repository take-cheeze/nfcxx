#!/usr/bin/env ruby
# frozen_string_literal: true

# Checks tools/bc2cpp/native_ast_returns.rb: the return kind of each function in a small C++ fixture, from the clang AST
# (`clang -fsyntax-only -Xclang -ast-dump=json`). Covers a constructor, `self` (also through a copy), a local, a
# conditional, a join of two kinds, a call to a function in the same file, a recursive cycle, and an identity call
# (mrb_obj_freeze returns its self parameter, so the call takes the argument passed for it), and a string guard that narrows a local to String only where
# no later statement reassigns it. With `optional: true` (the base declarations' mode) a join of K and nil is `K?`;
# every other function keeps its kind. Skips when clang is not installed.
#
#   ruby scripts/bc2cpp/native_ast_returns_check.rb

require 'json'
require 'open3'
require 'tmpdir'
require_relative '../../tools/bc2cpp/native_ast_returns'
require_relative '../../tools/bc2cpp/native_ast_source'
require_relative '../../tools/bc2cpp/main_roots'

# Every producer available here is checked against the same expectations (clang, and nfcxx once
# scripts/setup-libclang-edg.sh has built its front end); BC2CPP_AST_PRODUCER=clang|nfcxx limits it to one.
producers = ENV['BC2CPP_AST_PRODUCER'] ? [ENV['BC2CPP_AST_PRODUCER']] : NativeAstSource::PRODUCERS
producers = producers.select { |name| NativeAstSource.available?(name) }
if producers.empty?
  puts 'SKIP native_ast_returns_check: neither clang nor the nfcxx front end is available'
  exit 0
end

FIXTURE = <<~CPP
  struct mrb_value { int v; };
  mrb_value mrb_fixnum_value(int);
  mrb_value mrb_nil_value();
  mrb_value mrb_ary_new(int);
  bool test(int);

  mrb_value int_fn(mrb_value self) { return mrb_fixnum_value(1); }
  mrb_value self_fn(mrb_value self) { return self; }
  mrb_value local_fn(mrb_value self) { mrb_value r = mrb_ary_new(0); return r; }
  mrb_value cond_fn(mrb_value self, int c) { return c ? mrb_fixnum_value(1) : mrb_fixnum_value(2); }
  mrb_value mixed_fn(mrb_value self, int c) { return c ? mrb_fixnum_value(1) : mrb_nil_value(); }
  mrb_value call_fn(mrb_value self) { return int_fn(self); }
  mrb_value rec_fn(mrb_value self) { return rec_fn(self); }
  struct mrb_state;
  mrb_value mrb_obj_freeze(struct mrb_state *mrb, mrb_value self) { return self; }
  mrb_value mrb_str_new(struct mrb_state *mrb, const char *p, int len);
  enum { MRB_TT_STRING = 7 };
  mrb_value get_thing(struct mrb_state *mrb);
  mrb_value mrb_str_new_cstr(struct mrb_state *mrb, const char *s);
  mrb_value guard_fn(struct mrb_state *mrb, mrb_value self) { mrb_value m = get_thing(mrb); if (!(m.v == MRB_TT_STRING)) { return mrb_str_new_cstr(mrb, 0); } return m; }
  mrb_value guard_late_fn(struct mrb_state *mrb, mrb_value self) { mrb_value m = get_thing(mrb); if (!(m.v == MRB_TT_STRING)) { return mrb_str_new_cstr(mrb, 0); } m = get_thing(mrb); return m; }
  mrb_value pre_fn(struct mrb_state *mrb, mrb_value self) { mrb_value m = get_thing(mrb); if (m.v == 1) { return m; } if (!(m.v == MRB_TT_STRING)) { return mrb_str_new_cstr(mrb, 0); } return m; }
  mrb_value class_name_str(struct mrb_state *mrb, mrb_value c);
  mrb_value named_fn(struct mrb_state *mrb, mrb_value self) { return class_name_str(mrb, self); }
  struct mrb_class;
  struct mrb_state { struct mrb_class *string_class; };
  struct mrb_class *mrb_obj_class_of(struct mrb_state *mrb, mrb_value v);
  mrb_value mrb_str_dup(struct mrb_state *mrb, mrb_value v);
  mrb_value self_str_fn(struct mrb_state *mrb, mrb_value self) { if (mrb_obj_class_of(mrb, self) != mrb->string_class) { return mrb_str_dup(mrb, self); } return self; }
  mrb_value frozen_fn(struct mrb_state *mrb, mrb_value self) { return mrb_obj_freeze(mrb, mrb_str_new(mrb, 0, 0)); }
  enum { MRB_Qnil = 0 };
  struct box { mrb_value obj, str; };
  struct box2 { mrb_value obj, str; };
  void fill_box(struct box *p) { p->str = mrb_str_new_cstr(0, 0); }
  mrb_value nil_else_fn(mrb_value self) { struct box b = { self, mrb_nil_value() }; fill_box(&b); if (b.str.v == MRB_Qnil) { return mrb_str_new_cstr(0, 0); } else { return b.str; } }
  mrb_value nil_unnarrowed_fn(mrb_value self) { struct box b = { self, mrb_nil_value() }; fill_box(&b); return b.str; }
  mrb_value nil_store_branch_fn(mrb_value self) { struct box b = { self, mrb_nil_value() }; fill_box(&b); if (!(b.str.v == MRB_Qnil)) { b.str = mrb_nil_value(); return b.str; } return mrb_str_new_cstr(0, 0); }
  mrb_value nil_escape_branch_fn(mrb_value self) { struct box b = { self, mrb_nil_value() }; fill_box(&b); if (!(b.str.v == MRB_Qnil)) { fill_box(&b); return b.str; } return mrb_str_new_cstr(0, 0); }
  mrb_value nil_copy_fn(mrb_value self) { struct box2 a = { self, mrb_nil_value() }; struct box2 c = a; if (!(c.str.v == MRB_Qnil)) { return c.str; } return mrb_str_new_cstr(0, 0); }
  mrb_value assign_guard_fn(struct mrb_state *mrb, mrb_value self) { mrb_value v = get_thing(mrb); if (!(v.v == MRB_TT_STRING)) { v = mrb_str_new_cstr(mrb, 0); } return v; }
  mrb_value assign_nested_fn(struct mrb_state *mrb, mrb_value self, int c) { mrb_value v = get_thing(mrb); if (!(v.v == MRB_TT_STRING)) { if (c) { v = mrb_str_new_cstr(mrb, 0); } } return v; }
  mrb_value assign_twice_fn(struct mrb_state *mrb, mrb_value self) { mrb_value v = get_thing(mrb); if (!(v.v == MRB_TT_STRING)) { v = mrb_str_new_cstr(mrb, 0); v = get_thing(mrb); } return v; }
  struct mrb_class *mrb_obj_class(struct mrb_state *mrb, mrb_value v);
  mrb_value mrb_obj_value(struct mrb_class *p);
  mrb_value class_fn(struct mrb_state *mrb, mrb_value self) { return mrb_obj_value(mrb_obj_class(mrb, self)); }
  mrb_value class_other_fn(struct mrb_state *mrb, mrb_value self) { return mrb_obj_value(mrb_obj_class_of(mrb, self)); }
CPP

EXPECTED = {
  'int_fn' => 'Integer', 'self_fn' => 'self', 'local_fn' => 'Array', 'cond_fn' => 'Integer',
  'mixed_fn' => nil, 'call_fn' => 'Integer', 'rec_fn' => nil, 'frozen_fn' => 'String',
  'guard_fn' => 'String', 'guard_late_fn' => nil, 'pre_fn' => nil, 'named_fn' => 'String', 'self_str_fn' => 'String', 'mrb_obj_freeze' => 'self',
  # A field read is the join of the file's stores into it; a nil test narrows it only in a branch that does not store
  # to the field or use its object bare, and a whole-record copy makes the record's fields unknown.
  'fill_box' => nil, 'nil_else_fn' => 'String', 'nil_unnarrowed_fn' => nil, 'nil_store_branch_fn' => nil,
  'nil_escape_branch_fn' => nil, 'nil_copy_fn' => nil,
  # A string guard whose branch assigns the local: the one unconditional String assignment makes it a String after the
  # branch, a conditional or a second assignment does not.
  'assign_guard_fn' => 'String', 'assign_nested_fn' => nil, 'assign_twice_fn' => nil,
  # mrb_obj_value of mrb_obj_class is a Class (a real class, class.c); of any other class-pointer call it is not proven.
  'class_fn' => 'Class', 'class_other_fn' => nil
}.freeze

# What `optional: true` changes: a K-or-nil join, through a conditional or a field's stores, is `K?`.
OPTIONAL = {
  'mixed_fn' => 'Integer?', 'nil_unnarrowed_fn' => 'String?', 'nil_store_branch_fn' => 'String?',
  'nil_escape_branch_fn' => 'String?'
}.freeze

# The host program's roots (tools/bc2cpp/main_roots.rb) over C++ the producers must read alike: member and static member
# calls, virtual methods, a mem-initializer, lambdas (captured variables), a template (instantiated and as a pattern), a
# default argument and a default member initializer, a range-for, a condition declaration, try / catch, bool conversions,
# a string array, a presym-like enumerator, an unnamed namespace and an exported (constructor-attribute) function.
MAIN_FIXTURE = <<~CPP
  struct mrb_state { int x; };
  struct mrb_value { int v; };
  enum mruby_presym { MRB_SYM__each = 1, MRB_SYM_Q__nil = 2 };
  typedef unsigned int mrb_sym;
  mrb_value mrb_funcall(mrb_state *, mrb_value, const char *, int, ...);
  mrb_value mrb_funcall_id(mrb_state *, mrb_value, mrb_sym, int, ...);
  struct Base { virtual ~Base() {} virtual int hook(mrb_state *m, mrb_value v) { mrb_funcall(m, v, "virtual_hook", 0); return 1; } };
  struct Derived : Base {
    const char *name = "default_member_init";
    Derived() : Base() {}
    int hook(mrb_state *m, mrb_value v) override { mrb_funcall(m, v, "derived_hook", 0); return 2; }
    void run(mrb_state *m, mrb_value v) const { mrb_funcall(m, v, "member_call", 0); }
    static void srun(mrb_state *m, mrb_value v) { mrb_funcall(m, v, "static_member", 0); }
  };
  template <typename T> void tcall(mrb_state *m, mrb_value v, T) { mrb_funcall(m, v, "templated_call", 0); }
  template <typename F> int callf(F f) { return f(1); }
  static void defaulted(mrb_state *m, mrb_value v, const char *n = "default_arg") { (void)n; mrb_funcall(m, v, "default_body", 0); }
  static void via(mrb_state *m, mrb_value v, bool flag) {
    mrb_funcall(m, v, flag ? "flag_on" : "flag_off", 0);
    bool b = 1; bool c = true; (void)b; (void)c;
    mrb_sym s = MRB_SYM__each;
    mrb_funcall_id(m, v, s, 0);
    mrb_funcall_id(m, v, MRB_SYM_Q__nil, 0);
  }
  namespace { void anon(mrb_state *m, mrb_value v) { mrb_funcall(m, v, "anon_ns_call", 0); } }
  extern "C" void exported(mrb_state *m) __attribute__((constructor));
  extern "C" void exported(mrb_state *m) { mrb_funcall(m, mrb_value{0}, "ctor_attr", 0); }
  static const char *lookup(int) { return "from_condition"; }
  int main(int argc, char **argv) {
    mrb_state st; mrb_state *m = &st; mrb_value self = {0};
    mrb_funcall(m, self, "main_call", 0);
    defaulted(m, self); via(m, self, argc > 1); anon(m, self);
    Derived d; d.run(m, self); Derived::srun(m, self); Base *b = &d; b->hook(m, self);
    tcall(m, self, 3);
    auto fn = [&]() { mrb_funcall(m, self, "lambda_call", 0); }; fn();
    auto lam = [m, self](int z) { mrb_funcall(m, self, "lambda_two", z); }; lam(1);
    callf([](int z) { return z; });
    const char *lit[] = {"arr_a", "arr_b"};
    for (const char *n : lit) mrb_funcall(m, self, n, 0);
    if (const char *c = lookup(argc)) mrb_funcall(m, self, c, 0);
    try { mrb_funcall(m, self, "in_try", 0); } catch (int) { mrb_funcall(m, self, "in_catch", 0); }
    mrb_funcall(m, self, argv[0], 0);
    mrb_funcall(m, self, "send", 1);
    return 0;
  }
CPP

failures = []
Dir.mktmpdir('native_ast_returns_check') do |dir|
  main_source = File.join(dir, 'main_fixture.cxx')
  File.write(main_source, MAIN_FIXTURE)
  roots = producers.to_h do |name|
    ast, err, status = NativeAstSource.dump(main_source, ['-std=gnu++17'], lang: :cxx, name: name)
    abort "#{name} failed on the main fixture: #{err}" unless status.success?

    result = MainRoots.analyze({ 'kind' => 'TranslationUnitDecl', 'inner' => [JSON.parse(ast)] })
    [name, { names: result.names.to_a.sort, refusals: result.refusals.sort }]
  end
  %w[main_call virtual_hook derived_hook member_call static_member templated_call lambda_call lambda_two default_arg
     flag_on flag_off anon_ns_call ctor_attr arr_a arr_b from_condition in_try in_catch each nil?
     default_member_init].each do |want|
    roots.each { |name, got| failures << "#{name}: main roots lack #{want.inspect}" unless got[:names].include?(want) }
  end
  reflective = ['native call to reflective method send', 'unresolved method name passed to mrb_funcall in main']
  roots.each { |name, got| failures << "#{name}: main refusals #{got[:refusals].inspect}" unless got[:refusals] == reflective }
  failures << "main roots differ between #{roots.keys.join(' and ')}" unless roots.values.uniq.size == 1
end

Dir.mktmpdir('native_ast_returns_check') do |dir|
  source = File.join(dir, 'fixture.cxx')
  File.write(source, FIXTURE)
  producers.each do |name|
    ast, err, status = NativeAstSource.dump(source, [], lang: :cxx, name: name)
    abort "#{name} failed: #{err}" unless status.success?

    kinds = NativeAstReturns.analyze(JSON.parse(ast), source)
    EXPECTED.each do |fn, want|
      got = kinds[fn]
      failures << "#{name}: #{fn}: expected #{want.inspect}, got #{got.inspect}" unless got == want
    end
    failures << "#{name}: functions found #{kinds.keys.sort.inspect}, expected #{EXPECTED.keys.sort.inspect}" unless kinds.keys.sort == EXPECTED.keys.sort

    optional = NativeAstReturns.analyze(JSON.parse(ast), source, optional: true)
    EXPECTED.merge(OPTIONAL).each do |fn, want|
      got = optional[fn]
      failures << "#{name}: optional #{fn}: expected #{want.inspect}, got #{got.inspect}" unless got == want
    end
  end
end

if failures.empty?
  puts "native AST returns check: #{EXPECTED.size} functions classified (#{producers.join(', ')})"
else
  failures.each { |failure| warn "  #{failure}" }
  abort "native AST returns check: #{failures.size} failure(s)"
end
