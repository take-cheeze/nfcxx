#!/usr/bin/env ruby
# frozen_string_literal: true

# The module-owner rule (docs/bc2cpp-ir-feedback.md, "Implicit self-calls"): ClosedWorld#known_includer_candidates
# answers the declared classes a module's includers are drawn from, or nil (open). A non-core native source that only
# defines or looks up a module's name cannot include it, so the name no longer closes the rule (the widened cases).
# Every include a native or outside Ruby source can make still closes it (the refusals), and the module receiver's
# same-name guard (RbsSignatures.self_call_types, module_owner:) refuses a send whose name a program source defines.
#
# Fixtures are native C++ sources and foreign Ruby sources written to a temp directory, read by a ClosedWorld whose
# class registry declares C (and D), and whose module list declares M and N. Host-only, no MRBC.
#
# Usage: ruby scripts/bc2cpp/module_includer_bound_check.rb

require 'set'
require 'tmpdir'
require 'fileutils'
require_relative '../../tools/bc2cpp/compiled_gems'
require_relative '../../tools/bc2cpp/closed_world'
require_relative '../../tools/bc2cpp/scan_cache'
require_relative '../../tools/bc2cpp/irep'
require_relative '../../tools/bc2cpp/bytecode_ir'
require_relative '../../tools/bc2cpp/rbs_signatures'

$failures = []
def check(label, condition)
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{label}"
  $failures << label unless condition
end

# A native source: the mruby header line, then the body (C++ text).
NATIVE_HEADER = "#include <mruby.h>\n"

# Candidates of module +mod+ for a world whose natives are +native+ (text) and whose foreign Ruby is +ruby+ (text).
def candidates(mod, native: [], ruby: [], modules: %w[M N], classes: %w[C D])
  Dir.mktmpdir('module-includer') do |dir|
    ScanCache.directory_override = File.join(dir, 'cache')
    native_paths = native.each_with_index.map do |text, i|
      path = File.join(dir, "native#{i}.cxx")
      File.write(path, NATIVE_HEADER + text)
      path
    end
    ruby_paths = ruby.each_with_index.map do |text, i|
      path = File.join(dir, "outside#{i}.rb")
      File.write(path, text)
      path
    end
    world = ClosedWorld.new(ireps: {}, registry: {}, class_decls: classes.to_h { |name| [name, [{ super: 'Object', outer_nil: true }]] },
                            walked: {}, native_paths: native_paths, ruby_paths: ruby_paths, module_names: Set.new(modules))
    world.known_includer_candidates(mod)
  ensure
    ScanCache.directory_override = nil
  end
end

# The fixture bodies. `M`, `N` are the modules; `C`, `D` the declared classes.
DEFINE_M = <<~CXX
  static mrb_value m_helper(mrb_state* M, mrb_value self) { return self; }
  void init(mrb_state* M) {
    RClass* m = mrb_define_module(M, "M");
    mrb_define_module_function(M, m, "helper", m_helper, MRB_ARGS_NONE());
  }
CXX

puts '-- widened: a native that defines or looks up the module name (no include) no longer closes the rule'
check('a native mrb_define_module + module_function leaves M bounded (C)',
      candidates('M', native: [DEFINE_M]) == %w[C D])
check('a native mrb_module_get lookup that is not an include leaves M bounded',
      candidates('M', native: ["void f(mrb_state* M) { RClass* m = mrb_module_get(M, \"M\"); (void)m; }\n"]) == %w[C D])
check('a callee of a literal name passed through a helper leaves M bounded',
      candidates('M', native: [<<~CXX]) == %w[C D])
        static mrb_value call(mrb_state* M, mrb_value recv, const char* name) { return mrb_funcall(M, recv, name, 0); }
        void f(mrb_state* M, mrb_value o) { call(M, o, "log_tail"); call(M, o, "message"); }
      CXX
check('a literal-valued constant write leaves M bounded',
      candidates('M', native: ["void f(mrb_state* M, mrb_value o) { mrb_const_set(M, o, mrb_intern_lit(M, \"K\"), mrb_fixnum_value(3)); }\n" + DEFINE_M]) == %w[C D])
check('a ternary of literal method names leaves M bounded',
      candidates('M', native: [<<~CXX]) == %w[C D])
        void f(mrb_state* M, mrb_value o, bool b) {
          const char* name = b ? "effect_probe" : nullptr;
          if (name) mrb_funcall(M, o, name, 0);
        }
      CXX

puts '-- refused: a native include of the module, by any spelling'
check('a native mrb_include_module of M by name refuses M',
      candidates('M', native: ["void f(mrb_state* M, RClass* c) { mrb_include_module(M, c, mrb_module_get(M, \"M\")); }\n" + DEFINE_M]) .nil?)
check('a native mrb_include_module of any module is refused by the existing dynamic-definition rule (every module)',
      candidates('N', native: ["void f(mrb_state* M, RClass* c) { mrb_include_module(M, c, mrb_module_get(M, \"Enumerable\")); }\n"]).nil?)
check('a native mrb_obj_extend of M by name refuses M',
      candidates('M', native: ["void f(mrb_state* M, mrb_value o) { mrb_obj_extend(M, o, mrb_module_get(M, \"M\")); }\n"]).nil?)
check('a native mrb_obj_extend of M by name leaves N bounded (the name is M only)',
      candidates('N', native: ["void f(mrb_state* M, mrb_value o) { mrb_obj_extend(M, o, mrb_module_get(M, \"M\")); }\n"]) == %w[C D])
check('a native include of M through a qualified path refuses M (last segment)',
      candidates('M', native: ["void f(mrb_state* M, RClass* c) { mrb_include_module(M, c, mrb_module_get(M, \"Outer::M\")); }\n"]).nil?)
check('a native include of M through a computed value refuses every module (N too)',
      candidates('N', native: ["void f(mrb_state* M, RClass* c, mrb_value v) { mrb_include_module(M, c, mrb_class_ptr(v)); }\n"]).nil?)
check('a native funcall of "include" with a module argument refuses every module',
      candidates('M', native: ["void f(mrb_state* M, mrb_value c, mrb_value m) { mrb_funcall(M, c, \"include\", 1, m); }\n" + DEFINE_M]).nil?)
check('a native funcall whose method name is computed (a helper argument) refuses every module',
      candidates('M', native: [<<~CXX]).nil?)
        static void g(mrb_state* M, mrb_value o, mrb_sym s, mrb_value v) { mrb_funcall_id(M, o, s, 1, v); }
        void f(mrb_state* M, mrb_value o, mrb_value v) { g(M, o, mrb_intern_lit(M, "include"), v); }
      CXX
check('a native funcall whose method name is a call result (not spelled, not a parameter) refuses every module',
      candidates('M', native: [<<~CXX]).nil?)
        static mrb_sym pick_sym(mrb_state* M, mrb_value v) { return mrb_symbol(v); }
        void f(mrb_state* M, mrb_value o, mrb_value v) { mrb_funcall_id(M, o, pick_sym(M, v), 1, v); }
      CXX
check('a helper whose name argument is computed at one caller refuses every module',
      candidates('M', native: [<<~CXX]).nil?)
        static mrb_value call(mrb_state* M, mrb_value recv, const char* name) { return mrb_funcall(M, recv, name, 0); }
        void f(mrb_state* M, mrb_value o, const char* n) { call(M, o, "log"); call(M, o, n); }
      CXX
check('a helper called with "include" by any caller refuses every module',
      candidates('M', native: [<<~CXX]).nil?)
        static mrb_value call(mrb_state* M, mrb_value recv, const char* name) { return mrb_funcall(M, recv, name, 0); }
        void f(mrb_state* M, mrb_value o, mrb_value c, mrb_value m) { call(M, o, "log"); call(M, c, "include"); }
      CXX
check('a helper whose function is used as a pointer (not called) refuses every module',
      candidates('M', native: [<<~CXX]).nil?)
        static mrb_value call(mrb_state* M, mrb_value recv, const char* name) { return mrb_funcall(M, recv, name, 0); }
        mrb_value (*g_call)(mrb_state*, mrb_value, const char*) = call;
        void f(mrb_state* M, mrb_value o) { call(M, o, "log"); }
      CXX
check('a native that defines a method named include (an override) refuses every module',
      candidates('M', native: ["void f(mrb_state* M, RClass* c) { mrb_define_method(M, c, \"include\", nullptr, MRB_ARGS_ANY()); }\n"]).nil?)
check('a constant alias of M (a non-literal const write in a source that spells M) refuses M',
      candidates('M', native: ["void f(mrb_state* M, mrb_value o) { mrb_const_set(M, o, mrb_intern_lit(M, \"Alias\"), mrb_obj_value(mrb_module_get(M, \"M\"))); }\n"]).nil?)
check('an alias of M in a source that does not spell M is refused by the computed write only where M is spelled (N is not)',
      candidates('N', native: ["void f(mrb_state* M, mrb_value o) { mrb_const_set(M, o, mrb_intern_lit(M, \"Alias\"), mrb_obj_value(mrb_module_get(M, \"M\"))); }\n"]) == %w[C D])

puts '-- refused: a foreign Ruby source that spells the module (its include sites are not classified)'
check('a foreign Ruby source that includes M refuses M',
      candidates('M', ruby: ["class X\n  include M\nend\n"]).nil?)
check('a foreign Ruby source that spells M in any other way also refuses M',
      candidates('M', ruby: ["ALIAS = M\n"]).nil?)
check('a foreign Ruby source that does not spell M leaves it bounded',
      candidates('M', ruby: ["class X\n  include Enumerable\nend\n"]) == %w[C D])

puts '-- refused: M is not a declared module, or nothing bounds it'
check('an undeclared name is never a module owner (nil)', candidates('Q', native: [DEFINE_M]).nil?)

# The receiver guard (RbsSignatures.self_call_types, module_owner:): a module's receivers are its includers, so a name a
# program source defines on one of them is untyped. Built on the same contract tables as self_call_override checks.
puts '-- the module receiver same-name guard'
def insn(addr, op, args) = Insn.new(lineno: 1, addr: addr, op: op, args: args, raw: "#{op} #{args}")
module_irep = Irep.new(label: 'via_mod', instructions: [insn(0, 'ENTER', '0:0:0:0:0:0:0:0 (0x0)'), insn(1, 'SSEND', 'R1 :greet n=0'),
                                                        insn(2, 'RETURN', 'R1')],
                       catch_handlers: [], nregs: 4, nlocals: 1, reps: [], pool: [])
applied = RbsSignatures::Applied.new(
  ir_methods: Set[['M', 'via_mod'], ['A', 'greet'], ['B', 'greet']], ir_named_returns: { ['A', 'greet'] => Set[:Symbol], ['B', 'greet'] => Set[:Integer] },
  ir_owners: { 'via_mod' => 'M' }, ir_arg_types: { 'via_mod' => {} }, ir_optional_types: {}, ir_keyword_types: {}, ir_arg_elements: {},
  ir_rest_elements: {}, ir_const_elements: {}, ir_return_types: {}, ir_ivar_types: {}, ir_ivar_elements: {}
)
hierarchy = { 'A' => :none, 'B' => :none, 'M' => :none }
subclasses = ->(klass) { { 'A' => ['A'], 'B' => ['B'], 'M' => ['M'] }[klass] }
module_candidates = ->(mod) { mod == 'M' ? %w[A B] : nil }
world = { superclass_of: hierarchy, included_modules: { 'A' => ['M'], 'B' => ['M'] }, prepended_modules: {}, unknown_mixins: Set.new }
join = lambda do |core_redefined|
  result = RbsSignatures.ir_types(applied, module_irep, **world, subclasses: subclasses, includer_candidates: module_candidates,
                                  core_redefined: core_redefined, call_results: false)
  result.fact_at(2, '1', refusal: {}).then { |fact| fact&.declared? ? fact.classes : nil }
end
check('a module with two includers and no program definition of greet joins (Symbol | Integer)',
      join.call(->(_owner, _name) { false }) == Set[:Symbol, :Integer])
check('a program source that defines greet on an includer makes the module send untyped',
      join.call(->(owner, name) { owner == 'A' && name == 'greet' }).nil?)

# End to end: the candidates a real ClosedWorld answers type the module's implicit-self send. The native source defines
# M by name only, so the send is typed; a native that includes M by a computed value leaves it untyped.
puts '-- end to end: the candidates of a ClosedWorld type the send'
world_fact = lambda do |native_text, lam_world|
  Dir.mktmpdir('module-includer-e2e') do |dir|
    ScanCache.directory_override = File.join(dir, 'cache')
    path = File.join(dir, 'native.cxx')
    File.write(path, NATIVE_HEADER + native_text)
    cw = ClosedWorld.new(ireps: {}, registry: {}, class_decls: %w[A B].to_h { |n| [n, [{ super: 'Object', outer_nil: true }]] },
                         walked: {}, native_paths: [path], ruby_paths: [], module_names: Set['M'])
    fact = RbsSignatures.ir_types(applied, module_irep, **lam_world, subclasses: subclasses,
                                  includer_candidates: ->(mod) { cw.known_includer_candidates(mod) }, call_results: false)
                        .fact_at(2, '1', refusal: {})
    fact&.declared? ? fact.classes : nil
  ensure
    ScanCache.directory_override = nil
  end
end
e2e_world = { superclass_of: { 'A' => :none, 'B' => :none, 'M' => :none }, included_modules: { 'A' => ['M'], 'B' => ['M'] },
              prepended_modules: {}, unknown_mixins: Set.new }
check('a native that only defines M by name: the send joins the includers (Symbol | Integer)',
      world_fact.call(DEFINE_M, e2e_world) == Set[:Symbol, :Integer])
check('a native that includes M by a computed value: the send is untyped',
      world_fact.call(DEFINE_M + "void g(mrb_state* M, RClass* c, mrb_value v) { mrb_include_module(M, c, mrb_class_ptr(v)); }\n", e2e_world).nil?)

if $failures.empty?
  puts 'module includer bound checks passed'
else
  puts "#{$failures.size} module includer bound check(s) FAILED:"
  $failures.each { |label| puts "  - #{label}" }
  exit 1
end
