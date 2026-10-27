#!/usr/bin/env ruby
# frozen_string_literal: true

# CONST_BINDING_CACHE (tools/bc2cpp/const_site_cache.rb): a bare name bound at several fixed paths gets a per-site
# cache that fills only once every binding exists, and a `Scope::NAME` read of an immutable name from an immutable
# scope caches per receiver. The analysis part checks which names qualify; the runtime part reads the names from
# every scope, interpreted and compiled, before and after a binding the program declares but has not made yet
# (defined from C, as a late class body would), and compares the output. Needs MRBC; the runtime part also needs a
# full-core libmruby (BC2CPP_MRUBY_FULL, or rake and a C++ compiler).
ENV['BC2CPP_SIG_DIRS'] = ''

require 'tmpdir'
require_relative 'check_support'
require_relative 'fixture_runtime'
require_relative '../../tools/bc2cpp/irep'
require_relative '../../tools/bc2cpp/const_site_cache'

suite = FixtureCheck.new('const_bindings_check')
suite.require_mrbc!

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
  end
  module CbOuter
    class CbA
      # Declared but not made: the scenario binds it from C, as a later class body would.
      LATE = 3 if W == 0
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
  end
RUBY

OWNERS = %w[CbOuter::CbA CbOuter::CbB CbOuter::CbC CbTop].freeze

Dir.mktmpdir('bc2cpp-const-bindings') do |dir|
  code, err = Bc2cppFixtureRuntime.generate(SOURCE, dir, core: true, only_owners: OWNERS)
  suite.check('a multi-binding read uses the guarded site cache', code.include?('bc2cpp_const_path_has(M, "CbOuter::CbA"'))
  suite.check('a scoped read of an immutable name uses the receiver cache', code.match?(/bc2cpp_mcnst_\d+\(M, r\d+\)/))
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
        static const char* const classes[] = {"CbOuter::CbA", "CbOuter::CbB", "CbOuter::CbC", "CbTop"};
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
      }
      static int scenario(mrb_state* M) {
        round(M, "before");
        mrb_value a = mrb_const_get(M, mrb_const_get(M, mrb_obj_value(M->object_class), mrb_intern_lit(M, "CbOuter")),
                                    mrb_intern_lit(M, "CbA"));
        mrb_define_const(M, mrb_class_ptr(a), "LATE", mrb_fixnum_value(3));
        round(M, "after");
        return 0;
      }
    CPP
    built, output = Bc2cppFixtureRuntime.run(dir, err, OWNERS, "#include <cstring>\n#{scenario}", build: build, full: true)
    suite.check('fixture builds and runs', built)
    sections = Bc2cppFixtureRuntime.sections(output)
    plain = ->(lines) { lines.to_a.reject { |l| l.start_with?('  dispatches=') } }
    interpreted = plain.call(sections['interpreted'])
    compiled = plain.call(sections['compiled'])
    suite.check('every read ran', !interpreted.empty? && interpreted.size == compiled.size)
    suite.check('the late binding changes the reads that reach it', interpreted.include?('after CbOuter::CbA#late 0 => 3'))
    suite.check('interpreted and compiled runs print the same', interpreted == compiled)
    interpreted.zip(compiled).reject { |a, b| a == b }.first(10).each do |a, b|
      puts "    interpreted: #{a}\n    compiled:    #{b}"
    end
  end
end

suite.finish!
