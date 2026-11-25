#!/usr/bin/env ruby
# frozen_string_literal: true

# CONST_PLAIN_LOAD (tools/bc2cpp/const_plain_load.rb): a constant read in a method no gem-init code can reach, of a
# slot whose bindings init makes unconditionally, is a plain slot load filled at the end of bc2cpp_gem_init. The
# analysis part checks which names a native by-name call is bounded by, which statements init makes, and which bodies
# init reaches; the generation part checks which sites go plain and that BC2CPP_CONST_PLAIN_LOAD=0 restores the
# checked reads; the runtime part runs the reads interpreted and compiled (a late binding from C, a nil constant, a
# conditional binding and a class body's own call among them) and compares the output. Needs MRBC; the runtime part
# also needs a full-core libmruby (BC2CPP_MRUBY_FULL, or rake and a C++ compiler).
ENV['BC2CPP_SIG_DIRS'] = ''

require 'tmpdir'
require_relative 'check_support'
require_relative 'fixture_runtime'
require_relative '../../tools/bc2cpp/irep'
require_relative '../../tools/bc2cpp/const_plain_load'
require_relative '../../tools/bc2cpp/bc2cpp'

suite = FixtureCheck.new('const_plain_load_check')
suite.require_mrbc!

bounded = ->(text) { ConstPlainLoad.native_bounded?(text) }
suite.check('NATIVE_BOUNDED: a literal symbol name is bounded',
            bounded.call('void f(mrb_state* M, mrb_value o) { mrb_funcall_id(M, o, MRB_SYM(press), 0); }'))
suite.check('NATIVE_BOUNDED: a ternary of literal symbols is bounded',
            bounded.call('void f(mrb_state* M, mrb_value o, bool p) { mrb_funcall_id(M, o, p ? MRB_SYM(press) : MRB_SYM(release), 0); }'))
suite.check('NATIVE_BOUNDED: a local assigned one literal symbol is bounded',
            bounded.call("void f(mrb_state* M, mrb_value o) {\n  const mrb_sym blt = MRB_SYM(blt);\n  mrb_funcall_argv(M, o, blt, 0, nullptr);\n}"))
suite.check('NATIVE_BOUNDED: a symbol parameter is not',
            !bounded.call('void f(mrb_state* M, mrb_value o, mrb_sym id) { mrb_funcall_id(M, o, id, 0); }'))
suite.check('NATIVE_BOUNDED: an interned string is not',
            !bounded.call('void f(mrb_state* M, mrb_value o, const char* s) { mrb_funcall_id(M, o, mrb_intern_cstr(M, s), 0); }'))

suite.compile(<<~RUBY) do |ireps, root_label|
  TOP = 1
  OPTIONAL = 2 if TOP == 0
  NOTHING = nil
  FROZEN = 'x'.freeze
  BUILT = Object.new
  CALLED = TOP.succ
  module Outer
    INNER = [1]
    class Inner; end
    begin
      GUARDED = 3
    rescue StandardError
      nil
    end
  end
  class Object
    include Outer
  end
  if TOP == 1
    class Maybe; end
  end
RUBY
  made = ConstPlainLoad.made_bindings(ireps, root_label, []).made
  own = ->(path) { made.fetch(path, Set.new).include?(:own) }
  suite.check('BOUND_AT_INIT: a top-level literal assignment is made', own.call('TOP'))
  suite.check('BOUND_AT_INIT: a conditional assignment is not', !own.call('OPTIONAL'))
  suite.check('BOUND_AT_INIT: a nil value is not', !own.call('NOTHING'))
  suite.check('BOUND_AT_INIT: a frozen literal and a new are made', own.call('FROZEN') && own.call('BUILT'))
  suite.check('BOUND_AT_INIT: another call result is not', !own.call('CALLED'))
  suite.check('BOUND_AT_INIT: a module body binds its own path', own.call('Outer::INNER') && own.call('Outer::Inner'))
  suite.check('BOUND_AT_INIT: an assignment a rescue range can cut short is not', !own.call('Outer::GUARDED'))
  suite.check('BOUND_AT_INIT: a class statement under an if is not', !own.call('Maybe'))
  mixins = ConstPlainLoad.made_bindings(ireps, root_label, []).mixins
  suite.check('BOUND_AT_INIT: an unconditional include into Object is recorded', mixins['Outer'].include?(:own))
end

SOURCE = <<~RUBY
  # Array values: an Integer constant folds to its value and has no site.
  W = [0]
  NIL_V = nil
  module PlOuter
    W = [1]
    SIZE = [10].freeze
    class PlA
      W = [2]
      def pl_w = W
      def pl_size = SIZE
      def pl_late = LATE
      def pl_nil_v = NIL_V
      def pl_maybe = MAYBE
      def pl_at_init = SIZE
    end
    class PlB
      def pl_w = W
      def pl_size = SIZE
    end
    MAYBE = [5] if W.empty?
    # A class body's own call: that method runs during init, so its read stays checked.
    TABLE = PlA.new.pl_at_init
  end
  class PlTop
    def pl_w = W
    def pl_outer = PlOuter
    def pl_late = LATE
  end
RUBY

OWNERS = %w[PlOuter::PlA PlOuter::PlB PlTop].freeze
impl = ->(code, owner, meth) { code[/^mrb_value #{owner}_#{meth}_impl\(mrb_state\* M.*?^}/m].to_s }

Dir.mktmpdir('bc2cpp-const-plain-load') do |dir|
  code, err = Bc2cppFixtureRuntime.generate(SOURCE, dir, core: true, only_owners: OWNERS)
  suite.check('INIT_REACH: the analysis ran with no refusal', err.include?('CONST_PLAIN_LOAD): ') && !err.include?('all checked: '))
  plain = ->(owner, meth) { impl.call(code, owner, meth).match?(/bc2cpp_cconstp_\d+\(\)/) }
  checked = ->(owner, meth) { impl.call(code, owner, meth).match?(/bc2cpp_cconst_\d+\(M\)/) }
  suite.check('a read of a binding init makes, in a method init cannot reach, is plain',
              plain.call('PlOuter__PlA', 'pl_w') && plain.call('PlOuter__PlB', 'pl_size') && plain.call('PlTop', 'pl_outer'))
  suite.check('a method a class body calls keeps the checked read', checked.call('PlOuter__PlA', 'pl_at_init'))
  suite.check('a binding made after init (from C) keeps the checked read',
              !plain.call('PlOuter__PlA', 'pl_late') && !plain.call('PlTop', 'pl_late'))
  suite.check('a nil and a conditional constant keep the checked read',
              !plain.call('PlOuter__PlA', 'pl_nil_v') && !plain.call('PlOuter__PlA', 'pl_maybe'))
  suite.check('the prefill runs last in bc2cpp_gem_init',
              code.match?(/bc2cpp_gem_init\(mrb_state\* M\) \{.*bc2cpp_cconst_prefill\(M\);\n\}/m) &&
              code.include?('static const uint16_t bc2cpp_cconst_plain[]'))

  off_dir = File.join(dir, 'off')
  FileUtils.mkdir_p(off_dir)
  saved = ENV['BC2CPP_CONST_PLAIN_LOAD']
  ENV['BC2CPP_CONST_PLAIN_LOAD'] = '0'
  off_code, off_err = Bc2cppFixtureRuntime.generate(SOURCE, off_dir, core: true, only_owners: OWNERS)
  ENV['BC2CPP_CONST_PLAIN_LOAD'] = saved
  suite.check('BC2CPP_CONST_PLAIN_LOAD=0: every read is checked and the prefill is empty',
              !off_code.include?('bc2cpp_cconstp_') && !off_code.include?('bc2cpp_cconst_plain[]') &&
              off_code.include?('bc2cpp_cconst_prefill(M);'))

  build = ENV['CC_GENERATED_ONLY'] == '1' ? nil : Bc2cppFixtureRuntime.full_or_build
  if build.nil?
    puts '  SKIP const plain load behaviour: needs a full-core libmruby (BC2CPP_MRUBY_FULL, or rake, g++ and 3rd/mruby)'
  else
    scenario = <<~CPP
      static void round(mrb_state* M, const char* when) {
        static const char* const classes[] = {"PlOuter::PlA", "PlOuter::PlB", "PlTop"};
        char label[96];
        for (const char* path : classes) {
          mrb_value c = mrb_obj_value(M->object_class);
          for (const char* p = path; *p;) {
            const char* end = std::strstr(p, "::");
            size_t len = end ? (size_t)(end - p) : std::strlen(p);
            c = mrb_const_get(M, c, mrb_intern(M, p, len));
            p += len + (end ? 2 : 0);
          }
          mrb_value obj = mrb_obj_new(M, mrb_class_ptr(c), 0, nullptr);
          for (const char* meth : {"pl_w", "pl_size", "pl_late", "pl_nil_v", "pl_maybe", "pl_at_init", "pl_outer"}) {
            if (!mrb_respond_to(M, obj, mrb_intern_cstr(M, meth))) continue;
            for (int i = 0; i < 2; ++i) {
              std::snprintf(label, sizeof label, "%s %s#%s %d", when, path, meth, i);
              call(M, label, obj, meth);
            }
          }
        }
      }
      static int scenario(mrb_state* M) {
        round(M, "before");
        mrb_define_const(M, M->object_class, "LATE", mrb_fixnum_value(4));
        round(M, "after");
        return 0;
      }
    CPP
    [['', dir, err], ['BC2CPP_CONST_PLAIN_LOAD=0: ', off_dir, off_err]].each do |tag, run_dir, run_err|
      built, output = Bc2cppFixtureRuntime.run(run_dir, run_err, OWNERS, "#include <cstring>\n#{scenario}", build: build, full: true)
      suite.check("#{tag}fixture builds and runs", built)
      sections = Bc2cppFixtureRuntime.sections(output)
      lines = ->(part) { sections[part].to_a.reject { |l| l.start_with?('  dispatches=') } }
      interpreted = lines.call('interpreted')
      compiled = lines.call('compiled')
      suite.check("#{tag}every read ran", !interpreted.empty? && interpreted.size == compiled.size)
      suite.check("#{tag}a late binding is found after it is made",
                  interpreted.include?('before PlTop#pl_late 0 => raised NameError') && interpreted.include?('after PlTop#pl_late 0 => 4'))
      suite.check("#{tag}the lexical scope's own binding wins", interpreted.include?('before PlOuter::PlB#pl_w 0 => [1]'))
      suite.check("#{tag}interpreted and compiled runs print the same", interpreted == compiled)
      interpreted.zip(compiled).reject { |a, b| a == b }.first(10).each do |a, b|
        puts "    interpreted: #{a}\n    compiled:    #{b}"
      end
    end
  end
end

suite.finish!
