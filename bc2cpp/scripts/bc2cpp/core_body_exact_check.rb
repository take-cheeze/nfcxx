#!/usr/bin/env ruby
# encoding: UTF-8
# frozen_string_literal: true

# Check CORE_BODY_EXACT (docs/adr/0359): a literal or `*rest` receiver inside a compiled core body is
# proven exact by the program's world, so the arm drops its dispatch -- but the proof is CHECKED. The
# site keeps one class test and its else arm is bc2cpp_guard_violation (docs/adr/0290), where the
# engine's own unguarded proofs (ADR 0280) stay as they are.
#
# 1. Generated code (needs MRBC): every proven core-body site is wrapped in the class test with the
#    violation as its else, an engine site is not, and each way of losing the proof (a parameter, the
#    kill switches, a singleton-making engine, the open world) leaves the tag chain with its send.
# 2. Behaviour on real mruby (needs MRBC, BC2CPP_MRUBY_CORE and g++): an honouring program answers what
#    the interpreter answers and reaches no violation site (also under -DBC2CPP_NOMETHOD_VERIFY); a
#    receiver whose class no longer is the proven one (the driver swaps the Array class behind the
#    analysis' back, or hands a rest slot that is not an Array to the compiled body) logs
#    `[RPG2k] closed-world guard violation: <Class>#<name> at <site>` and raises BC2cppGuardViolation,
#    and verify mode aborts naming the class, the name and the site.
#
# Usage: [MRBC=path/to/mrbc BC2CPP_MRUBY_CORE=dir] ruby scripts/bc2cpp/core_body_exact_check.rb

require 'tmpdir'
require_relative 'fixture_runtime'

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

runtime = Bc2cppFixtureRuntime
CORE_PATH = '3rd/mruby/mrblib/gvc_core.rb'
OWNERS = %w[GvcCore GvcEngine].freeze

CORE_FIXTURE = <<~'RUBY'
  class GvcCore
    def lit_size; a = [1, 2, 3]; a.size; end
    def lit_values; h = { a: 1, b: 2 }; h.values; end
    def rest_size(*xs); xs.size; end
    def gap_size; a = [1, 2]; yield; a.size; end
    def param_size(a); a.size; end
  end
RUBY

# Engine Ruby next to it: the same shapes keep their unguarded proof (ADR 0280), untouched by ADR 0359.
ENGINE_FIXTURE = <<~'RUBY'
  class GvcEngine
    def lit_size; a = [1, 2, 3]; a.size; end
    def lit_join; [1, 2].join; end
  end
RUBY

MAKER_FIXTURE = "#{ENGINE_FIXTURE.sub(/^end\n\z/, '')}  def maker(o); o.instance_eval { 1 }; end\nend\n"

# -- 1. generated code ----------------------------------------------------------------------

chunk = lambda do |code, owner_method|
  code[/^\/\/ #{Regexp.escape(owner_method)} \(compiled from.*?(?=^\/\/ \S+#\S+ \(compiled from|\z)/m].to_s
end
generate = lambda do |dir, engine: ENGINE_FIXTURE, closed: true, env: {}|
  saved = env.to_h { |k, _| [k, ENV.fetch(k, nil)] }
  env.each { |k, v| ENV[k] = v }
  begin
    runtime.generate(CORE_FIXTURE, dir, closed: closed, only_owners: OWNERS, path: CORE_PATH, core: true,
                                        extra: [['gvc_engine.rb', engine]])
  ensure
    saved.each { |k, v| v ? ENV[k] = v : ENV.delete(k) }
  end
end
CHECKED = /CORE_BODY_EXACT_CHECKED :(\w+\??) -> (\w+)/
VIOLATION = /bc2cpp_guard_violation\(M, r\d+, \d+, "GvcCore#(\w+) \(CORE_BODY_EXACT\)"/

if ENV['MRBC']
  puts '== generated code'
  Dir.mktmpdir do |dir|
    code, err = generate.call(dir)
    %w[lit_size lit_values rest_size gap_size].each do |m|
      text = chunk.call(code, "GvcCore##{m}")
      check.call("GvcCore##{m}: the proven arm sits behind a class test, the else is bc2cpp_guard_violation naming the site",
                 text.match?(CHECKED) && text.match?(/if \(mrb_(?:array|hash)_p\(r\d+\) && mrb_obj_ptr\(r\d+\)->c == M->(?:array|hash)_class\) \{/) &&
                   text.match?(VIOLATION) && text.include?("\"GvcCore##{m} (CORE_BODY_EXACT)\"") && !text.include?('bc2cpp_send('))
    end
    gap = chunk.call(code, 'GvcCore#gap_size')
    check.call('the test is made at the call (after the yield), not at the literal',
               gap.index('yield') ? gap.index(/CORE_BODY_EXACT_CHECKED/) > gap.index(/yield|mrb_yield/) : gap.match?(CHECKED))
    check.call('NEG: a parameter receiver is no proof (tag chain, send, no violation)',
               !chunk.call(code, 'GvcCore#param_size').match?(CHECKED) && chunk.call(code, 'GvcCore#param_size').include?('bc2cpp_send('))
    engine = chunk.call(code, 'GvcEngine#lit_size') + chunk.call(code, 'GvcEngine#lit_join')
    check.call('an engine site keeps its unguarded ADR 0280 proof: no class test, no violation site',
               engine.include?('unguarded proof') && !engine.match?(CHECKED) && !engine.include?('guard_violation'))
    fixture_methods = %w[lit_size lit_values rest_size gap_size param_size].map { |m| chunk.call(code, "GvcCore##{m}") }
    check.call('the fixture methods are compiled as core bodies (5)', fixture_methods.none?(&:empty?))
    check.call('exactly the four proven fixture sites are checked, each with its own violation arm',
               fixture_methods.sum { |t| t.scan(CHECKED).size } == 4 && code.scan(VIOLATION).size == 4)
    # The whole core compiled with the fixture: every arm that says "unguarded proof" is an engine
    # arm (ADR 0280); the ones a core body gained from ADR 0359 all carry the test.
    every = code.scan(/^\/\/ (\S+#\S+) \(compiled from[^\n]*\n(.*?)(?=^\/\/ \S+#\S+ \(compiled from|\z)/m)
    core_unguarded = every.select { |_name, text| text.include?('unguarded proof') && !text.include?('CORE_BODY_EXACT_CHECKED') }
    check.call("no unchecked 'unguarded proof' arm in a compiled core body (#{every.size} bodies scanned)",
               core_unguarded.all? { |name, _| name.start_with?('GvcEngine#') })
    check.call('the violation sites are listed apart from the NOMETHOD sites',
               err.include?('GUARD_VIOLATION_SITE GvcCore#lit_size -> size') && err.scan(/GUARD_VIOLATION_SITE GvcCore#/).size == 4 &&
                 !err.include?('NOMETHOD GvcCore#'))
  end

  switches = { 'BC2CPP_CORE_BODY_EXACT' => '0', 'BC2CPP_GUARD_VIOLATION' => '0' }
  switches.each do |name, value|
    Dir.mktmpdir do |dir|
      code, = generate.call(dir, env: { name => value })
      core = %w[lit_size lit_values rest_size gap_size].map { |m| chunk.call(code, "GvcCore##{m}") }.join
      check.call("#{name}=#{value}: no proof, no class test, no violation, the tag chain and its send are back",
                 !core.match?(CHECKED) && !core.include?('CORE_BODY_EXACT') && core.include?('bc2cpp_send('))
    end
  end

  Dir.mktmpdir do |dir|
    code, = generate.call(dir, engine: MAKER_FIXTURE)
    core = %w[lit_size lit_values rest_size gap_size].map { |m| chunk.call(code, "GvcCore##{m}") }.join
    check.call('a singleton-making engine (instance_eval) withdraws every core-body proof', !core.match?(CHECKED) && core.include?('bc2cpp_send('))
  end

  Dir.mktmpdir do |dir|
    code, = generate.call(dir, closed: false)
    check.call('the open world proves nothing in a core body', !code.match?(CHECKED) && !code.include?('CORE_BODY_EXACT'))
  end
else
  puts '-- SKIP generated code: set MRBC'
end

# -- 2. behaviour ---------------------------------------------------------------------------

build = runtime.core
if ENV['MRBC'] && build && runtime.compiler?
  puts '== fixture on real mruby, interpreted and compiled'
  body = <<~'CPP'
    #include <cstdlib>
    #include <cstring>
    #include <mruby/proc.h>
    #include <mruby/string.h>
    static mrb_value gv_log_puts(mrb_state* M, mrb_value) {
      mrb_value line;
      mrb_get_args(M, "S", &line);
      std::printf("  LOG %.*s\n", (int)RSTRING_LEN(line), RSTRING_PTR(line));
      return mrb_nil_value();
    }
    // The block the driver passes to gap_size: after the literal was built and before it is read, the
    // class the proof names stops being the receiver's class (a world the analysis did not see).
    static mrb_value gv_swap_array_class(mrb_state* M, mrb_value) {
      mrb_define_class(M, "GvcImpostor", M->array_class);
      M->array_class = mrb_class_get(M, "GvcImpostor");
      return mrb_nil_value();
    }
    static mrb_value gv_rest_direct(mrb_state* M, mrb_value self) {
      return GvcCore_rest_size_impl(M, self, mrb_fixnum_value(1));
    }
    static void gv_report(mrb_state* M, const char* label, mrb_value r) {
      if (M->exc) {
        mrb_value e = mrb_obj_value(M->exc);
        M->exc = nullptr;
        mrb_value msg = (mrb_funcall)(M, e, "message", 0);
        std::printf("%s => raised %s: %.*s\n", label, mrb_obj_classname(M, e), (int)RSTRING_LEN(msg), RSTRING_PTR(msg));
      } else {
        show(M, label, r);
      }
    }
    static void gv_call(mrb_state* M, const char* label, mrb_value obj, const char* meth, int argc = 0,
                        const mrb_value* argv = nullptr, mrb_value blk = mrb_nil_value()) {
      mrb_value r = mrb_funcall_with_block(M, obj, mrb_intern_cstr(M, meth), argc, argv, blk);
      gv_report(M, label, r);
    }
    static int scenario(mrb_state* M) {
      const char* mode = std::getenv("GV_SCENARIO");
      bool violate = mode && !std::strcmp(mode, "violate");
      if (!mrb_class_defined(M, "NameError")) mrb_define_class(M, "NameError", M->eStandardError_class);
      if (!mrb_class_defined(M, "NoMethodError")) mrb_define_class(M, "NoMethodError", mrb_class_get(M, "NameError"));
      struct RClass* log = mrb_define_class(M, "GvLog", M->object_class);
      mrb_define_method(M, log, "puts", gv_log_puts, MRB_ARGS_REQ(1));
      mrb_gv_set(M, mrb_intern_lit(M, "$stderr"), mrb_obj_new(M, log, 0, nullptr));
      mrb_value core = mrb_obj_new(M, mrb_class_get(M, "GvcCore"), 0, nullptr);
      mrb_value one = mrb_fixnum_value(1), two = mrb_fixnum_value(2);
      mrb_value args[] = { one, two };
      gv_call(M, "lit_size", core, "lit_size");
      gv_call(M, "lit_values", core, "lit_values");
      gv_call(M, "rest_size", core, "rest_size", 2, args);
      gv_call(M, "rest_size_empty", core, "rest_size");
      mrb_value ary = mrb_ary_new(M);
      mrb_value param[] = { ary };
      gv_call(M, "param_size", core, "param_size", 1, param);
      struct RClass* original = M->array_class;
      mrb_value blk = mrb_nil_value();
      if (violate) {
        blk = mrb_obj_value(mrb_proc_new_cfunc(M, gv_swap_array_class));
      } else {
        blk = mrb_obj_value(mrb_proc_new_cfunc(M, [](mrb_state*, mrb_value) { return mrb_nil_value(); }));
      }
      gv_call(M, "gap_size", core, "gap_size", 0, nullptr, blk);
      M->array_class = original;
      if (violate && compiled) {
        // A compiled body entered with a rest slot that is no Array: what a broken caller would do.
        mrb_define_method(M, mrb_class_get(M, "GvcCore"), "rest_direct", gv_rest_direct, MRB_ARGS_NONE());
        gv_call(M, "rest_size_direct", core, "rest_direct");
      }
      return 0;
    }
  CPP

  Dir.mktmpdir do |dir|
    # The core owners are named without the core Ruby itself (a core-only mruby has no mrblib to run it): the
    # fixture file is core Ruby by its path, and that is what makes its bodies compile as core bodies.
    _code, err = runtime.generate(CORE_FIXTURE, dir, closed: true, only_owners: BC2CPP_CORE_OWNERS + OWNERS, path: CORE_PATH,
                                                     extra: [['gvc_engine.rb', ENGINE_FIXTURE]])
    outputs = lambda do |flags = ''|
      saved = ENV.fetch('BC2CPP_CXXFLAGS', nil)
      ENV['BC2CPP_CXXFLAGS'] = [saved, flags].compact.reject(&:empty?).join(' ')
      begin
        runtime.run(dir, err, OWNERS, body, build: build, full: false,
                                            envs: [{ 'GV_SCENARIO' => 'ok' }, { 'GV_SCENARIO' => 'violate' }])
      ensure
        saved ? ENV['BC2CPP_CXXFLAGS'] = saved : ENV.delete('BC2CPP_CXXFLAGS')
      end
    end
    values = lambda do |output|
      sections = runtime.sections(output)
      [sections.fetch('interpreted', []).reject { |l| l.start_with?('  dispatches') },
       sections.fetch('compiled', []).reject { |l| l.start_with?('  dispatches') }]
    end

    built, results = outputs.call
    check.call('the fixture compiles and runs against real mruby', built)
    if built
      (ok_out, ok_status), (bad_out, bad_status) = results
      interpreted, compiled = values.call(ok_out)
      puts ok_out if interpreted != compiled || ENV['BC2CPP_CHECK_VERBOSE']
      check.call('an honouring program answers what the interpreter answers', ok_status && !interpreted.empty? && interpreted == compiled)
      check.call('  ... with the answers the fixture is written for',
                 interpreted.include?('lit_size => 3') && interpreted.include?('lit_values => [1, 2]') &&
                   interpreted.include?('rest_size => 2') && interpreted.include?('gap_size => 2'))
      check.call('  ... and reaches no violation site', !ok_out.include?('guard violation'))

      puts bad_out if ENV['BC2CPP_CHECK_VERBOSE']
      interpreted, compiled = values.call(bad_out)
      check.call('NEG: the interpreter carries on with the swapped Array class', bad_status && interpreted.include?('gap_size => 2'))
      line = compiled.find { |l| l.start_with?('gap_size =>') }.to_s
      check.call('NEG: compiled gap_size raises BC2cppGuardViolation naming class, name and site, it does not read the object',
                 line.include?('raised BC2cppGuardViolation: closed-world guard violation: Array#size') &&
                   line.include?('at GvcCore#gap_size (CORE_BODY_EXACT)'))
      line = compiled.find { |l| l.start_with?('rest_size_direct =>') }.to_s
      check.call('NEG: a rest slot that is no Array raises the same, naming the integer receiver',
                 line.include?('raised BC2cppGuardViolation:') && line.include?('Integer#size at GvcCore#rest_size (CORE_BODY_EXACT)'))
      %w[lit_size lit_values rest_size].each do |label|
        check.call("NEG: the sites the driver did not break (#{label}) still answer the interpreter's value",
                   compiled.include?(interpreted.find { |l| l.start_with?("#{label} =>") }))
      end
      log = bad_out.split('== compiled').last.to_s.lines.grep(/^  LOG /)
      check.call('NEG: each violation logs `[RPG2k] closed-world guard violation: <Class>#<name> at <site>` to $stderr',
                 log.size == 2 && log.all? { |l| l.include?('[RPG2k] closed-world guard violation: ') } &&
                   log.any? { |l| l.include?('Array#size at GvcCore#gap_size (CORE_BODY_EXACT)') })
      check.call('the interpreter run logs nothing', !bad_out.split('== compiled').first.include?('LOG '))
    end

    verify_built, verify_results = outputs.call('-DBC2CPP_NOMETHOD_VERIFY')
    check.call('-DBC2CPP_NOMETHOD_VERIFY builds', verify_built)
    if verify_built
      (ok_out, ok_status), (bad_out, bad_status) = verify_results
      check.call('verify mode: an honouring program reaches no violation site', ok_status && !ok_out.include?('NOMETHOD_VERIFY'))
      check.call('verify mode: a reached core-body violation aborts naming the class, name and site',
                 !bad_status && bad_out.include?('NOMETHOD_VERIFY: guard violation reached:') &&
                   bad_out.include?('Array#size') && bad_out.include?(' at GvcCore#gap_size'))
    end
  end
else
  puts '-- SKIP run: set MRBC, BC2CPP_MRUBY_CORE and have g++'
end

if failures.empty?
  puts 'bc2cpp core body exact check: PASS'
else
  warn "bc2cpp core body exact check: #{failures.size} failure(s)"
  exit 1
end
