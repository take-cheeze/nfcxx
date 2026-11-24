#!/usr/bin/env ruby
# frozen_string_literal: true

# CONST_BINDING_CACHE (tools/bc2cpp/const_site_cache.rb): a bare name bound at several fixed paths gets a per-site
# cache that fills only once every binding exists, and a `Scope::NAME` read of an immutable name from an immutable
# scope caches per receiver. The analysis part checks which names qualify; the runtime part reads the names from
# every scope, interpreted and compiled, before and after a binding the program declares but has not made yet
# (defined from C, as a late class body would), and compares the output, with CONST_SLOT_NIL_EMPTY (nil marks the empty
# slot, a zero mrb_value being nil in every boxing mode) on and off. Needs MRBC; the runtime part also needs a
# full-core libmruby (BC2CPP_MRUBY_FULL, or rake and a C++ compiler).
ENV['BC2CPP_SIG_DIRS'] = ''

require 'tmpdir'
require_relative 'check_support'
require_relative 'fixture_runtime'
require_relative '../../tools/bc2cpp/irep'
require_relative '../../tools/bc2cpp/const_site_cache'
require_relative '../../tools/bc2cpp/bc2cpp'

suite = FixtureCheck.new('const_bindings_check')
suite.require_mrbc!

scope_source = <<~C
  /* 日本語 before the function headers exercises character offsets. */
  void first(mrb_state* mrb) {
    RClass* scope = mrb_define_module(mrb, "First");
    first_site();
  }
  void second(mrb_state* mrb) {
    RClass* scope = mrb_define_module(mrb, "Second");
    second_site();
  }
C
scope_headers = {}.compare_by_identity
%w[second first second first].each do |name|
  pos = scope_source.index("#{name}_site")
  found = UniqueClassNames.native_module_binding([scope_source], scope_source, pos, 'scope', headers: scope_headers)
  suite.check("indexed native scope retains #{name}'s own function and offsets", found == name.capitalize)
end
suite.check('a position before every function has no native scope',
            UniqueClassNames.native_module_binding([scope_source], scope_source, 0, 'scope', headers: scope_headers).nil?)
suite.check('a position past the final closing brace has no native scope',
            UniqueClassNames.native_module_binding([scope_source], scope_source, scope_source.size, 'scope', headers: scope_headers).nil?)
lookup_source = scope_source.sub('mrb_define_module(mrb, "First")', 'mrb_module_get(mrb, "First")')
lookup_pos = lookup_source.index('first_site')
[false, true, false].each do |lookup|
  found = UniqueClassNames.native_module_binding([lookup_source], lookup_source, lookup_pos, 'scope',
                                                 lookup: lookup, headers: scope_headers)
  suite.check("a shared header index preserves lookup=#{lookup}'s binding policy", found == (lookup ? 'First' : nil))
end

Dir.mktmpdir('const-bindings') do |dir|
  native = File.join(dir, 'native.c')
  File.write(native, <<~C)
    void init(mrb_state* mrb) {
      mrb_define_const(mrb, mrb->object_class, "NATIVE_W", mrb_nil_value());
      RClass* nat = mrb_define_module(mrb, "Nat");
      mrb_define_class_under(mrb, nat, "Panel", mrb->object_class);
      mrb_define_class_under(mrb, mrb_module_get(mrb, "Nat"), "Hidden", mrb->object_class);
      RClass* got = mrb_module_get(mrb, "Nat");
      mrb_define_class_under(mrb, got, "Looked", mrb->object_class);
      RClass* amb = mrb_module_get(mrb, "Twice");
      mrb_define_class_under(mrb, amb, "Deep", mrb->object_class);
    }
  C
  suite.compile(<<~RUBY) do |ireps, root_label|
    W = 1
    NATIVE_W = 2
    module A
      W = 2
      NATIVE_W = 3
      class Twice; end
      LOOPED = 1
    end
    module B
      W = 3
      class Twice; end
      2.times { LOOPED = 2 }
    end
    module C
      MIXED = 1
    end
    module D
      MIXED = 2
    end
    class E
      include C
    end
    MIXED = 3
    module Nat
      class Panel; end
    end
    module Other
      class Panel; end
      class Hidden; end
      class Looked; end
      class Deep; end
    end
  RUBY
    bindings = ConstBindings.analyze(ireps, root_label, [native], [], static: true,
                                     included: { 'E' => ['C'] }, prepended: {}, unknown_mixins: Set.new)
    suite.check('a name assigned in three scopes has all three owners', bindings['W'] == ['', 'A', 'B'])
    suite.check('a class opened at two paths has both owners', bindings['Twice'] == %w[A B])
    suite.check('a native value constant is refused', !bindings.key?('NATIVE_W'))
    suite.check('a native class at a named path is one more owner', bindings['Panel'] == %w[Nat Other])
    suite.check('a native class under a scope it cannot name is refused', !bindings.key?('Hidden'))
    suite.check('a module_get outer with one top-level binding names its scope', bindings['Looked'] == %w[Nat Other])
    suite.check('a module_get outer without one top-level binding is refused', !bindings.key?('Deep'))
    dynamic = File.join(dir, 'dynamic.c')
    File.write(dynamic, <<~C)
      void init(mrb_state* mrb, mrb_sym id) {
        mrb_const_set(mrb, mrb_obj_value(mrb->object_class), id, mrb_nil_value());
      }
    C
    suite.check('a native binding with a computed name refuses every name',
                ConstBindings.analyze(ireps, root_label, [native, dynamic], [], static: true).empty?)
    suite.check('an assignment in a block body is refused', !bindings.key?('LOOPED'))
    suite.check('an owner included into a class is refused', !bindings.key?('MIXED'))
    unknown = ConstBindings.analyze(ireps, root_label, [native], [], static: true, unknown_mixins: Set['E'])
    suite.check('an unresolved mixin refuses every name', unknown.empty?)
    suite.check('a dynamic program refuses every name', ConstBindings.analyze(ireps, root_label, [native], [], static: false).empty?)
    two = ConstBindings.analyze(ireps, root_label, [native], [], static: true, included: { 'Object' => %w[C D] })
    suite.check('two owners included into Object are refused', !two.key?('MIXED'))
    one = ConstBindings.analyze(ireps, root_label, [native], [], static: true, included: { 'Object' => %w[C] })
    suite.check('one owner included into Object is kept', one['MIXED'] == ['', 'C', 'D'])
  end
end

SOURCE = <<~RUBY
  W = 0
  module CbOuter
    W = 1
    class CbA
      W = 2
      def w = W
      def late = LATE
    end
    class CbB
      def w = W
      def late = LATE
    end
    class CbC < CbA
      def w = W
    end
    class CbA
      K = 7
    end
    class CbD
      K = 8
    end
    # W shadowed in a subclass; K and ONLY_LATE reached through the superclass only.
    class CbE < CbA
      W = 5
      def w = W
      def late = LATE
    end
    class CbF < CbA
      def w = K
      def late = ONLY_LATE
    end
  end
  module CbOuter
    class CbA
      # Declared but not made: the scenario binds them from C, as a later class body would.
      LATE = 3 if W == 0
      ONLY_LATE = [9] if W == 0
    end
    # Not below CbA: ONLY_LATE is never in its lookup.
    class CbG
      def w = ONLY_LATE
      def late = LATE
    end
    # CONST_SLOT_NIL_EMPTY: a nil value is the empty slot, so it is looked up again; false is stored.
    class CbH
      NIL_V = nil
      FALSE_V = false
      def w = NIL_V
      def late = FALSE_V
    end
  end
  LATE = 4
  class CbTop
    def w = W
    def member = CbOuter::CbA::W
    def rescued
      CbOuter::CbA::W
    rescue NameError
      :none
    end
    def top = ::W
    def late = LATE
    def kind_a = CbOuter::CbA::K
    def kind_d = CbOuter::CbD::K
  end
RUBY

OWNERS = %w[CbOuter::CbA CbOuter::CbB CbOuter::CbC CbOuter::CbE CbOuter::CbF CbOuter::CbG CbOuter::CbH CbTop].freeze

Dir.mktmpdir('bc2cpp-const-bindings') do |dir|
  code, err = Bc2cppFixtureRuntime.generate(SOURCE, dir, core: true, only_owners: OWNERS)
  suite.check('a multi-binding read uses the guarded site cache', code.include?('bc2cpp_const_path_has(M, "CbOuter::CbA"') ||
                                                                  (code.include?('bc2cpp_cconst_tests') && code.include?('"CbOuter::CbA\\0"')))
  suite.check('a scoped read of an immutable name uses the receiver cache', code.match?(/bc2cpp_mcnst_\d+\(M, r\d+\)/))
  suite.check('CONST_SLOT_NIL_EMPTY: no have flags; nil marks the empty slot',
              !code.include?('bc2cpp_cconst_have') && !code.include?('bc2cpp_cdef_mhave') &&
              code.include?('static_assert(MRB_Qnil == 0') && code.include?('!mrb_nil_p(bc2cpp_cconst_slots[i])'))
  # One receiver cache per name: the two `::K` reads (different receivers) share a slot.
  last_mcnst = ->(meth) { code[/^mrb_value CbTop_#{meth}_impl\(mrb_state\* M.*?^}/m].to_s.scan(/bc2cpp_mcnst_(\d+)\(M, r\d+\)/).flatten.last }
  suite.check('the GETMCNST reads of one name share one receiver cache',
              !last_mcnst.call('kind_a').nil? && last_mcnst.call('kind_a') == last_mcnst.call('kind_d'))
  rescued = code[/^static mrb_value CbTop_rescued_impl_rescue_try\(mrb_state\* M.*?^}/m].to_s
  suite.check('a scoped read inside a rescue range uses the receiver cache',
              rescued.match?(/bc2cpp_mcnst_\d+\(M, r\d+\)/))

  build = ENV['CC_GENERATED_ONLY'] == '1' ? nil : Bc2cppFixtureRuntime.full_or_build
  if build.nil?
    puts '  SKIP const bindings behaviour: needs a full-core libmruby (BC2CPP_MRUBY_FULL, or rake, g++ and 3rd/mruby)'
  else
    scenario = <<~CPP
      static mrb_value make(mrb_state* M, const char* path) {
        mrb_value c = mrb_obj_value(M->object_class);
        for (const char* p = path; *p;) {
          const char* end = std::strstr(p, "::");
          size_t len = end ? (size_t)(end - p) : std::strlen(p);
          c = mrb_const_get(M, c, mrb_intern(M, p, len));
          p += len + (end ? 2 : 0);
        }
        return mrb_obj_new(M, mrb_class_ptr(c), 0, nullptr);
      }
      static void round(mrb_state* M, const char* when) {
        static const char* const classes[] = {"CbOuter::CbA", "CbOuter::CbB", "CbOuter::CbC", "CbOuter::CbE",
                                              "CbOuter::CbF", "CbOuter::CbG", "CbOuter::CbH", "CbTop"};
        char label[96];
        for (const char* path : classes) {
          mrb_value obj = make(M, path);
          for (const char* meth : {"w", "late"}) {
            for (int i = 0; i < 2; ++i) {
              std::snprintf(label, sizeof label, "%s %s#%s %d", when, path, meth, i);
              call(M, label, obj, meth);
            }
          }
        }
        mrb_value top = make(M, "CbTop");
        call(M, "member", top, "member");
        call(M, "member again", top, "member");
        call(M, "rescued", top, "rescued");
        call(M, "rescued again", top, "rescued");
        call(M, "top", top, "top");
        // The shared slot holds one receiver at a time: alternate them.
        for (int i = 0; i < 2; ++i) {
          call(M, "kind_a", top, "kind_a");
          call(M, "kind_d", top, "kind_d");
        }
      }
      static int scenario(mrb_state* M) {
        round(M, "before");
        mrb_value a = mrb_const_get(M, mrb_const_get(M, mrb_obj_value(M->object_class), mrb_intern_lit(M, "CbOuter")),
                                    mrb_intern_lit(M, "CbA"));
        mrb_define_const(M, mrb_class_ptr(a), "LATE", mrb_fixnum_value(3));
        mrb_define_const(M, mrb_class_ptr(a), "ONLY_LATE", mrb_fixnum_value(9));
        round(M, "after");
        return 0;
      }
    CPP
    # STATIC_CONSTANTS (codegen_const_tables.rb) on, as generated above, and off; CONST_SLOT_NIL_EMPTY off, with each.
    [['', dir, err, {}], ['BC2CPP_STATIC_CONSTANTS=0: ', nil, nil, { 'BC2CPP_STATIC_CONSTANTS' => '0' }],
     ['BC2CPP_CONST_SLOT_NIL_EMPTY=0: ', nil, nil, { 'BC2CPP_CONST_SLOT_NIL_EMPTY' => '0' }],
     ['both 0: ', nil, nil, { 'BC2CPP_STATIC_CONSTANTS' => '0', 'BC2CPP_CONST_SLOT_NIL_EMPTY' => '0' }]].each do |tag, run_dir, run_err, env|
      unless run_dir
        run_dir = File.join(dir, env.keys.join('-'))
        FileUtils.mkdir_p(run_dir)
        saved = env.keys.to_h { |k| [k, ENV[k]] }
        env.each { |k, v| ENV[k] = v }
        off_code, run_err = Bc2cppFixtureRuntime.generate(SOURCE, run_dir, core: true, only_owners: OWNERS)
        saved.each { |k, v| ENV[k] = v }
        if env.key?('BC2CPP_STATIC_CONSTANTS')
          suite.check("#{tag}the generated fills are back", off_code.include?('bc2cpp_cconst_fill_') && !off_code.include?('bc2cpp_cconst_rows'))
        end
        if env.key?('BC2CPP_CONST_SLOT_NIL_EMPTY')
          suite.check("#{tag}the have flags are back", off_code.include?('bc2cpp_cconst_have[') && !off_code.include?('static_assert(MRB_Qnil'))
        end
      end
      built, output = Bc2cppFixtureRuntime.run(run_dir, run_err, OWNERS, "#include <cstring>\n#{scenario}", build: build, full: true)
      suite.check("#{tag}fixture builds and runs", built)
      sections = Bc2cppFixtureRuntime.sections(output)
      plain = ->(lines) { lines.to_a.reject { |l| l.start_with?('  dispatches=') } }
      interpreted = plain.call(sections['interpreted'])
      compiled = plain.call(sections['compiled'])
      suite.check("#{tag}every read ran", !interpreted.empty? && interpreted.size == compiled.size)
      suite.check("#{tag}the late binding changes the reads that reach it", interpreted.include?('after CbOuter::CbA#late 0 => 3'))
      suite.check("#{tag}a read before its only binding raises, then finds it",
                  interpreted.include?('before CbOuter::CbF#late 0 => raised NameError') &&
                  interpreted.include?('after CbOuter::CbF#late 1 => 9') &&
                  interpreted.include?('after CbOuter::CbG#w 1 => raised NameError'))
      suite.check("#{tag}a subclass's own binding shadows its superclass's",
                  interpreted.include?('before CbOuter::CbE#w 0 => 5') && interpreted.include?('before CbOuter::CbF#w 0 => 7'))
      suite.check("#{tag}a nil and a false constant read as themselves",
                  interpreted.include?('after CbOuter::CbH#w 1 => nil') && interpreted.include?('after CbOuter::CbH#late 1 => false'))
      suite.check("#{tag}interpreted and compiled runs print the same", interpreted == compiled)
      interpreted.zip(compiled).reject { |a, b| a == b }.first(10).each do |a, b|
        puts "    interpreted: #{a}\n    compiled:    #{b}"
      end
    end
    # CONST_SLOT_NIL_EMPTY's premise in each boxing mode: a zero-initialised (static) mrb_value is nil, and the emitted
    # static_asserts compile.
    probe = File.join(dir, 'zero_nil.cc')
    File.write(probe, "#include <mruby.h>\n#{CodeGen::CONST_SLOT_NIL_ASSERTS}" \
                      "static mrb_value zero_slot;\nint main() { return mrb_nil_p(zero_slot) && !mrb_nil_p(mrb_false_value()) ? 0 : 1; }\n")
    %w[MRB_WORD_BOXING MRB_NAN_BOXING MRB_NO_BOXING].each do |mode|
      exe = File.join(dir, "zero_nil_#{mode}")
      made = Bc2cppCxx.system('-std=c++17', "-D#{mode}", "-I#{build}/include", "-I#{Bc2cppFixtureRuntime::ROOT}/3rd/mruby/include", probe, '-o', exe)
      suite.check("CONST_SLOT_NIL_EMPTY: a zero mrb_value is nil under #{mode}", made && system(exe))
    end
  end
end

# CONST_DEF_ELIDE (tools/bc2cpp/const_def_elide.rb): a program that enumerates constants keeps every constant
# definition, even where no bytecode runs. Generated as for a VM-free build, run interpreted and compiled.
REFLECT = <<~'RUBY'
  class CdHolder
    LIMIT = 3
    def limit = LIMIT
    def by_name = CdHolder.const_get(:LIMIT)
    def listed = CdHolder.constants.include?(:LIMIT)
  end
RUBY

Dir.mktmpdir('bc2cpp-const-def-elide') do |dir|
  saved = ENV['BC2CPP_VM_FREE']
  ENV['BC2CPP_VM_FREE'] = '1'
  code, err = Bc2cppFixtureRuntime.generate(REFLECT, dir, core: true, only_owners: %w[CdHolder])
  ENV['BC2CPP_VM_FREE'] = saved
  suite.check('CONST_DEF_ELIDE: Module#constants refuses the elision world-wide',
              err.include?('CONST_DEF_ELIDE): off (') && !code.include?('CONST_DEF_ELIDE LIMIT'))
  build = ENV['CC_GENERATED_ONLY'] == '1' ? nil : Bc2cppFixtureRuntime.full_or_build
  if build.nil?
    puts '  SKIP const definition behaviour: needs a full-core libmruby'
  else
    scenario = <<~CPP
      static int scenario(mrb_state* M) {
        mrb_value obj = mrb_obj_new(M, mrb_class_get(M, "CdHolder"), 0, nullptr);
        for (const char* meth : {"limit", "by_name", "listed"}) call(M, meth, obj, meth);
        return 0;
      }
    CPP
    built, output = Bc2cppFixtureRuntime.run(dir, err, %w[CdHolder], scenario, build: build, full: true)
    suite.check('CONST_DEF_ELIDE: the reflection fixture builds and runs', built)
    sections = Bc2cppFixtureRuntime.sections(output)
    plain = ->(lines) { lines.to_a.reject { |l| l.start_with?('  dispatches=') } }
    interpreted = plain.call(sections['interpreted'])
    suite.check('CONST_DEF_ELIDE: interpreted and compiled read the constant by name alike',
                interpreted.include?('by_name => 3') && interpreted.include?('listed => true') &&
                interpreted == plain.call(sections['compiled']))
  end
end

# CONST_BINDING_DROP (tools/bc2cpp/const_binding_drop.rb): a value constant whose every read is a generated one keeps no
# binding. Generated as for a VM-free build; the compiled VM loads no bytecode, so gem_init's class units make every
# class and constant, as the closed build does. Interpreted and compiled runs must print the same.
DROP = <<~'RUBY'
  class CdDrop
    def self.late = LATE
    def self.try_late
      late
    rescue NameError => e
      e.message
    end
    BEFORE = try_late
    LATE = [1, 'two', :three]
    AFTER = try_late
    NOTHING = nil
    KLASS = Class.new
    class Inner
      DEEP = 'deep'
    end
    def late = LATE
    def before = BEFORE
    def after = AFTER
    def nothing = NOTHING
    def scoped = CdDrop::LATE
    def deep = Inner::DEEP
    def klass = KLASS
    def inner = Inner
    def by_name = CdKept.const_get(:BY_NAME)
    def kept = CdKept::BY_NAME
    def defined = defined?(LATE)
  end
  class CdKept
    BY_NAME = 'by name'
  end
  # The owner mruby-lcf's reviewed native read reaches (ConstDefElide::NATIVE_COMPUTED_READS) must be known.
  module LCF
    module Schema; end
  end
RUBY

Dir.mktmpdir('bc2cpp-const-binding-drop') do |dir|
  generate = lambda do |run_dir, switch|
    saved = %w[BC2CPP_VM_FREE BC2CPP_DROP_CONST_BINDINGS].to_h { |k| [k, ENV[k]] }
    ENV['BC2CPP_VM_FREE'] = '1'
    ENV['BC2CPP_DROP_CONST_BINDINGS'] = switch
    FileUtils.mkdir_p(run_dir)
    # The full-core library the fixture links has no mruby-marshal, whose by-name class lookup is no reviewed read.
    Bc2cppFixtureRuntime.generate(DROP, run_dir, core: true, only_owners: %w[CdDrop CdDrop.singleton CdDrop::Inner CdKept],
                                                 drop_native: %w[/3rd/mruby-marshal/], drop_gems: %w[mruby-marshal])
  ensure
    saved.each { |k, v| ENV[k] = v }
  end
  code, err = generate.call(dir, nil)
  dropped = err.scan(/^  CONST_BINDING_DROP (\S+)(?: plain)?$/).flatten
  plain = err.scan(/^  CONST_BINDING_DROP (\S+) plain$/).flatten
  kept = err.scan(/^  CONST_BINDING_KEPT (\S+) \((.*)\)$/).to_h
  suite.check('CONST_BINDING_DROP: the value constants read only by generated code are dropped',
              (%w[CdDrop::LATE CdDrop::BEFORE CdDrop::AFTER CdDrop::KLASS CdDrop::Inner::DEEP] - dropped).empty?)
  suite.check('CONST_BINDING_DROP: a constant read by const_get keeps its binding', kept['BY_NAME'] == 'spelled by another opcode')
  suite.check('CONST_BINDING_DROP: a class keeps its binding', !dropped.include?('CdDrop::Inner') && !kept.key?('Inner'))
  suite.check('CONST_BINDING_DROP: an Array value is only stored; a value that may be a class keeps the checked write',
              plain.include?('CdDrop::LATE') && !plain.include?('CdDrop::KLASS') && code.include?('bc2cpp_cdef_put(M, '))
  suite.check('CONST_BINDING_DROP: a dropped definition makes no mrb_const_set',
              code.include?('bc2cpp_cdef_set') && !code.match?(/mrb_const_set\(M, [^;]*\b(?:MRB_SYM\(LATE\)|"LATE")/))
  # Reflection that sees a constant table refuses the drop world-wide: a Ruby Module#constants, and the same method
  # called from linked native code as a C function.
  reflect_dir = File.join(dir, 'reflect')
  FileUtils.mkdir_p(reflect_dir)
  saved = ENV['BC2CPP_VM_FREE']
  ENV['BC2CPP_VM_FREE'] = '1'
  _, ruby_err = Bc2cppFixtureRuntime.generate("#{DROP}class CdDrop\n  def listed = CdDrop.constants\nend\n", reflect_dir,
                                              core: true, only_owners: %w[CdDrop CdDrop.singleton CdDrop::Inner CdKept],
                                              drop_native: %w[/3rd/mruby-marshal/], drop_gems: %w[mruby-marshal])
  _, native_err = Bc2cppFixtureRuntime.generate(DROP, File.join(dir, 'reflect-native'), core: true,
                                                only_owners: %w[CdDrop CdDrop.singleton CdDrop::Inner CdKept],
                                                drop_native: %w[/3rd/mruby-marshal/], drop_gems: %w[mruby-marshal],
                                                native: [['enum.c', "void f(mrb_state* M, mrb_value m) { mrb_mod_constants(M, m); }\n"]])
  ENV['BC2CPP_VM_FREE'] = saved
  suite.check('CONST_BINDING_DROP: a Ruby Module#constants refuses the drop',
              ruby_err.match?(/CONST_BINDING_DROP\): off \(.*names :constants/))
  suite.check('CONST_BINDING_DROP: a native mrb_mod_constants call refuses the drop',
              native_err.include?('CONST_BINDING_DROP): off (') && native_err.match?(/CONST_BINDING_DROP\): off \([^\n]*calls mrb_mod_constants/))
  _, off_err = generate.call(File.join(dir, 'off'), '0')
  suite.check('CONST_BINDING_DROP: BC2CPP_DROP_CONST_BINDINGS=0 drops nothing',
              off_err.include?('CONST_BINDING_DROP): off (BC2CPP_DROP_CONST_BINDINGS=0'))
  build = ENV['CC_GENERATED_ONLY'] == '1' ? nil : Bc2cppFixtureRuntime.full_or_build
  if build.nil?
    puts '  SKIP constant binding drop behaviour: needs a full-core libmruby'
  else
    scenario = <<~CPP
      static int scenario(mrb_state* M) {
        mrb_value obj = mrb_obj_new(M, mrb_class_get(M, "CdDrop"), 0, nullptr);
        static const char* const reads[] = {"late", "before", "after", "nothing", "scoped", "deep", "klass", "inner",
                                            "by_name", "kept", "defined"};
        for (int round = 0; round < 3; ++round) {
          // The dropped values live only in the per-VM table: collect, with garbage in between, before each read.
          for (int i = 0; i < 200; ++i) mrb_ary_new_from_values(M, 0, nullptr), mrb_str_new_lit(M, "garbage");
          mrb_full_gc(M);
          for (const char* meth : reads) call(M, meth, obj, meth);
        }
        mrb_value cls = mrb_obj_value(mrb_class_get(M, "CdDrop"));
        call(M, "listed", cls, "constants");
        return 0;
      }
    CPP
    [['', dir], ['BC2CPP_DROP_CONST_BINDINGS=0: ', File.join(dir, 'off')]].each do |tag, run_dir|
      run_err = run_dir == dir ? err : off_err
      built, output = Bc2cppFixtureRuntime.run(run_dir, run_err, %w[CdDrop CdDrop.singleton CdDrop::Inner CdKept], scenario, build: build,
                                               full: true, compiled_load: false)
      suite.check("CONST_BINDING_DROP: #{tag}the fixture builds and runs", built)
      sections = Bc2cppFixtureRuntime.sections(output)
      plain = ->(lines) { lines.to_a.reject { |l| l.start_with?('  dispatches=') } }
      interpreted = plain.call(sections['interpreted'])
      compiled = plain.call(sections['compiled'])
      suite.check("CONST_BINDING_DROP: #{tag}a read before the definition raises the interpreter's NameError",
                  interpreted.include?('before => "uninitialized constant CdDrop::LATE"'))
      suite.check("CONST_BINDING_DROP: #{tag}a heap value survives collections", interpreted.include?('late => [1, "two", :three]'))
      suite.check("CONST_BINDING_DROP: #{tag}a class value is still named by its constant", interpreted.include?('klass => CdDrop::KLASS'))
      listed = compiled.find { |l| l.start_with?('listed => ') }.to_s
      suite.check("CONST_BINDING_DROP: #{tag}#{tag.empty? ? 'the dropped names are not in the table' : 'every name is in the table'}",
                  tag.empty? ? !listed.include?(':LATE') && listed.include?(':KLASS') : listed.include?(':LATE'))
      # The scenario's Module#constants is C test code outside the world (a world that calls it refuses the drop, checked
      # above); it shows the bindings the drop removes, so it is the one line left out of the comparison.
      same = ->(lines) { lines.reject { |l| l.start_with?('listed => ') } }
      suite.check("CONST_BINDING_DROP: #{tag}interpreted and compiled runs print the same", same.call(interpreted) == same.call(compiled))
      same.call(interpreted).zip(same.call(compiled)).reject { |a, b| a == b }.first(10).each do |a, b|
        puts "    interpreted: #{a}\n    compiled:    #{b}"
      end
    end
  end
end

suite.finish!
