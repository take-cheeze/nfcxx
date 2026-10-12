#!/usr/bin/env ruby
# encoding: UTF-8
# frozen_string_literal: true

# Check GUARD_VIOLATION (docs/adr/0290): on a closed-world build the else arm of a guard whose
# register provably holds a stable class constant (`Klass.new`'s identity test, `is_a?(Klass)`'s
# class test, `Klass === x`'s type switch) is bc2cpp_guard_violation, not a dispatch.
#
# 1. Gate logic: the marker and the listing (violation sites are not NOMETHOD_REVIEWED sites).
# 2. Generated code (needs MRBC): the converted families carry the helper and no dispatch; sites
#    without the proof, numeric fast paths and the open world keep their dispatch; the kill
#    switch restores every dispatch one for one.
# 3. Behaviour on real mruby (needs MRBC, a mruby build and g++): programs inside the closed
#    set answer what the interpreter answers and log nothing; with a constant rebound behind the
#    analysis' back (the driver, which is outside the analysed world) the compiled code logs
#    `[RPG2k] closed-world guard violation` and raises BC2cppGuardViolation where the
#    interpreter carries on or raises a TypeError; -DBC2CPP_GUARD_VIOLATION_DISPATCH restores
#    the interpreter's answer and -DBC2CPP_NOMETHOD_VERIFY aborts.
#
# Usage: [MRBC=path/to/mrbc BC2CPP_MRUBY_FULL=dir] ruby scripts/bc2cpp/guard_violation_check.rb

require 'tmpdir'
require_relative 'fixture_runtime'
require_relative '../../tools/bc2cpp/nomethod_reviewed'
require_relative '../../tools/bc2cpp/symbol_cache'

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

runtime = Bc2cppFixtureRuntime

# -- 1. the gate --------------------------------------------------------------------

puts '== the listing'
marked = { owner: 'A', name: 'm', code: "r1 = x; #{NomethodReviewed.violation_marker('new')}\n" }
compiled = [marked]
check.call('a violation site is listed as "Owner#method -> name" and is not a NOMETHOD_REVIEWED site',
           NomethodReviewed.violation_sites(compiled) == ['A#m -> new'] && NomethodReviewed.sites(compiled).empty? &&
             NomethodReviewed.violations(NomethodReviewed.sites(compiled), compiled, reviewed: Set[]).empty?)
table = SymbolCache::Table.new
rewritten = SymbolCache.rewrite('r1 = bc2cpp_guard_violation_named(M, r1, "new", "A#m (NEW_IDENTITY)", 2, r2, r3);', table)
check.call('SymbolCache turns the named call into an indexed one and flags the helper',
           rewritten == 'r1 = bc2cpp_guard_violation(M, r1, 0, "A#m (NEW_IDENTITY)", 2, r2, r3);' && table.violation_used)
check.call('the helper is emitted only when a site uses it',
           SymbolCache.emit(table).include?('bc2cpp_guard_violation_raise') &&
             !SymbolCache.emit(SymbolCache::Table.new).include?('bc2cpp_guard_violation_raise'))

# -- fixture ---------------------------------------------------------------------------

FIXTURE = <<~'RUBY'
  class GvPoint
    def initialize(x, y)
      @x = x
      @y = y
    end

    def sum
      @x + @y
    end
  end

  class GvOther
  end

  module GvNs
    class Inner
    end
  end

  class GvImpostorRange
    def initialize(first, last)
      @first = first
      @last = last
    end
  end

  class GvUser
    def make_range(a, b)
      Range.new(a, b).class
    end

    def kind(x)
      x.is_a?(GvPoint)
    end

    def kind_of(x)
      x.kind_of?(GvPoint)
    end

    def eqq(x)
      GvPoint === x
    end

    def kind_ns(x)
      x.is_a?(GvNs::Inner)
    end

    def eqq_ns(x)
      GvNs::Inner === x
    end

    def kind_dyn(x, klass)
      x.is_a?(klass)
    end

    def eqq_dyn(klass, x)
      klass === x
    end

    def kind_cond(flag, x)
      klass = flag ? GvPoint : GvOther
      x.is_a?(klass)
    end

    def add(a, b)
      a + b
    end
  end
RUBY
OWNERS = %w[GvUser].freeze

# The text of one compiled method, from its header to the next one.
chunk = lambda do |code, owner_method|
  code[/^\/\/ #{Regexp.escape(owner_method)} \(compiled from.*?(?=^\/\/ \S+#\S+ \(compiled from|\z)/m].to_s
end
count = ->(text, needle) { text.scan(needle).size }

# -- 2. generated code -----------------------------------------------------------------

if ENV['MRBC']
  puts '== generated code'
  Dir.mktmpdir do |dir|
    code, err = runtime.generate(FIXTURE, dir, closed: true, only_owners: OWNERS)
    # ADR 0290's families only: CLASS_NARROWING (ADR 0375) has its own check and goes with its own kill switch.
    violation = /\bbc2cpp_guard_violation\(M,(?![^\n]*\(CLASS_NARROWING\))/
    # ADR 0293: an unproven `is_a?` argument raises its TypeError in place and an unproven `===`
    # receiver calls the shared bc2cpp_eqq helper; neither is a violation site.
    NO_PROOF_FALLBACK = /bc2cpp_send\(|"%v is not class\/module"|\bbc2cpp_eqq\(M,/
    DISPATCH = /\bbc2cpp_send\(M,|"%v is not class\/module"/
    %w[make_range kind kind_of eqq kind_ns eqq_ns].each do |m|
      text = chunk.call(code, "GvUser##{m}")
      check.call("GvUser##{m}: the proven guard's else arm is bc2cpp_guard_violation, with its marker and site",
                 text.match?(violation) && text.include?('CLOSED_WORLD guard-violation:') && text.include?("\"GvUser##{m} (") &&
                   !text.include?('bc2cpp_send('))
    end
    check.call('the three families are counted', err.include?('GUARD_VIOLATION NEW_IDENTITY: 1') &&
                                                 err.include?('GUARD_VIOLATION CLASS_ARGUMENT: 3') &&
                                                 err.include?('GUARD_VIOLATION CLASS_EQQ: 2'))
    check.call('the violation sites are listed on stderr, apart from the NOMETHOD sites',
               err.include?('  GUARD_VIOLATION_SITE GvUser#make_range -> new') &&
                 err.include?('  GUARD_VIOLATION_SITE GvUser#eqq -> ===') && !err.include?('  NOMETHOD GvUser#'))
    %w[kind_dyn eqq_dyn kind_cond].each do |m|
      text = chunk.call(code, "GvUser##{m}")
      check.call("NEG: GvUser##{m} has no constant proof, so it keeps its dispatch and emits no violation",
                 !text.match?(violation) && text.match?(NO_PROOF_FALLBACK))
    end
    add = chunk.call(code, 'GvUser#add')
    check.call('NEG: a numeric fast path keeps its dispatch arm (Float/Bignum/overflow are valid)',
               !add.match?(violation) && (add.include?('bc2cpp_send(') || add.include?('mrb_num_add(')))
    check.call('the helper is emitted', code.include?('static mrb_value bc2cpp_guard_violation(mrb_state* M') &&
                                        code.include?('BC2CPP_GUARD_VIOLATION_DISPATCH') &&
                                        code.include?('BC2CPP_NOMETHOD_VERIFY'))
    violations = count.call(code, violation)
    sends = count.call(code, DISPATCH)

    Dir.mktmpdir do |off_dir|
      off_code, off_err = ENV.fetch('BC2CPP_GUARD_VIOLATION', nil).then do |saved|
        ENV['BC2CPP_GUARD_VIOLATION'] = '0'
        runtime.generate(FIXTURE, off_dir, closed: true, only_owners: OWNERS)
      ensure
        saved ? ENV['BC2CPP_GUARD_VIOLATION'] = saved : ENV.delete('BC2CPP_GUARD_VIOLATION')
      end
      check.call('the kill switch (BC2CPP_GUARD_VIOLATION=0) emits no violation site and lists none',
                 !off_code.match?(violation) && !off_code.include?('bc2cpp_guard_violation_raise') &&
                   !off_err.include?('GUARD_VIOLATION_SITE'))
      check.call('the kill switch restores exactly one dispatch per converted site',
                 violations.positive? && count.call(off_code, DISPATCH) == sends + violations)
    end

    Dir.mktmpdir do |open_dir|
      open_code, = runtime.generate(FIXTURE, open_dir, closed: false, only_owners: OWNERS)
      check.call('the open world keeps every fallback (no violation site)',
                 !open_code.match?(violation) && !open_code.include?('guard-violation'))
    end
  end
else
  puts '-- SKIP generated code: set MRBC'
end

# -- 3. behaviour ----------------------------------------------------------------------

build = runtime.full || runtime.core
if ENV['MRBC'] && build && runtime.compiler?
  puts '== fixture on real mruby, interpreted and compiled'
  body = <<~'CPP'
    #include <cstdlib>
    #include <cstring>
    #include <mruby/string.h>
    static mrb_value gv_log_puts(mrb_state* M, mrb_value) {
      mrb_value line;
      mrb_get_args(M, "S", &line);
      std::printf("  LOG %.*s\n", (int)RSTRING_LEN(line), RSTRING_PTR(line));
      return mrb_nil_value();
    }
    // Shows the value, or the exception class and message.
    static void gv_call(mrb_state* M, const char* label, mrb_value obj, const char* meth, int argc = 0,
                        const mrb_value* argv = nullptr) {
      mrb_value r = (mrb_funcall_argv)(M, obj, mrb_intern_cstr(M, meth), argc, argv);
      if (M->exc) {
        mrb_value e = mrb_obj_value(M->exc);
        M->exc = nullptr;
        mrb_value msg = (mrb_funcall)(M, e, "message", 0);
        std::printf("%s => raised %s: %.*s\n", label, mrb_obj_classname(M, e), (int)RSTRING_LEN(msg), RSTRING_PTR(msg));
      } else {
        show(M, label, r);
      }
    }
    static int scenario(mrb_state* M) {
      const char* mode = std::getenv("GV_SCENARIO");
      bool violate = mode && !std::strcmp(mode, "violate");
      // mruby's mrblib (absent from a bare core) defines these.
      if (!mrb_class_defined(M, "NameError")) mrb_define_class(M, "NameError", M->eStandardError_class);
      if (!mrb_class_defined(M, "NoMethodError")) mrb_define_class(M, "NoMethodError", mrb_class_get(M, "NameError"));
      struct RClass* log = mrb_define_class(M, "GvLog", M->object_class);
      mrb_define_method(M, log, "puts", gv_log_puts, MRB_ARGS_REQ(1));
      mrb_gv_set(M, mrb_intern_lit(M, "$stderr"), mrb_obj_new(M, log, 0, nullptr));
      mrb_value obj = mrb_obj_value(M->object_class);
      if (violate) {
        // Rebound from outside the analysed world, as no program in it could: the proof
        // that these constants name their classes no longer holds.
        mrb_const_set(M, obj, mrb_intern_lit(M, "GvPoint"), mrb_obj_new(M, mrb_class_get(M, "GvOther"), 0, nullptr));
        mrb_const_set(M, obj, mrb_intern_lit(M, "Range"), mrb_obj_value(mrb_class_get(M, "GvImpostorRange")));
      }
      mrb_value user = mrb_obj_new(M, mrb_class_get(M, "GvUser"), 0, nullptr);
      mrb_value point = mrb_obj_new(M, mrb_class_get(M, "GvOther"), 0, nullptr);
      mrb_value one = mrb_fixnum_value(1), two = mrb_fixnum_value(2);
      mrb_value a1[] = { one, two };
      gv_call(M, "make_range", user, "make_range", 2, a1);
      mrb_value a2[] = { point };
      gv_call(M, "kind", user, "kind", 1, a2);
      gv_call(M, "kind_of", user, "kind_of", 1, a2);
      gv_call(M, "eqq", user, "eqq", 1, a2);
      mrb_value a3[] = { point, mrb_obj_value(mrb_class_get(M, "GvOther")) };
      gv_call(M, "kind_dyn", user, "kind_dyn", 2, a3);
      gv_call(M, "add", user, "add", 2, a1);
      return 0;
    }
  CPP
  # The class the `Range.new` and is_a? guards name when nothing is rebound.
  Dir.mktmpdir do |dir|
    _code, err = runtime.generate(FIXTURE, dir, closed: true, only_owners: OWNERS)
    full = File.exist?("#{build}/lib/libmruby.a")
    outputs = lambda do |flags = ''|
      # Append to the caller's flags: a 32-bit build passes -DMRB_INT32 here and must keep it.
      saved = ENV.fetch('BC2CPP_CXXFLAGS', nil)
      ENV['BC2CPP_CXXFLAGS'] = [saved, flags].compact.reject(&:empty?).join(' ')
      begin
        runtime.run(dir, err, OWNERS, body, build: build, full: full,
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
      check.call('a program inside the closed set answers what the interpreter answers',
                 ok_status && !interpreted.empty? && interpreted == compiled)
      check.call('  ... and logs no violation', !ok_out.include?('guard violation'))
      check.call('  ... with the answers the fixture is written for',
                 interpreted.include?('make_range => Range') && interpreted.include?('kind => false') &&
                   interpreted.include?('eqq => false') && interpreted.include?('add => 3'))

      puts bad_out if ENV['BC2CPP_CHECK_VERBOSE']
      interpreted, compiled = values.call(bad_out)
      check.call('NEG: rebound constants -- the interpreter carries on or raises its own TypeError',
                 bad_status && interpreted.include?('make_range => GvImpostorRange') &&
                   interpreted.any? { |l| l.start_with?('kind => raised TypeError') })
      %w[make_range kind kind_of eqq].each do |label|
        line = compiled.find { |l| l.start_with?("#{label} =>") }.to_s
        check.call("NEG: compiled #{label} raises BC2cppGuardViolation, it does not dispatch",
                   line.include?('raised BC2cppGuardViolation: closed-world guard violation:') && line.include?("at GvUser##{label} ("))
      end
      compiled_log = bad_out.split('== compiled').last.to_s.lines.grep(/^  LOG /)
      check.call('NEG: each violation logs `[RPG2k] closed-world guard violation: <Class>#<name> at <site>` to $stderr',
                 compiled_log.size == 4 &&
                   compiled_log.all? { |l| l.include?('[RPG2k] closed-world guard violation: ') } &&
                   compiled_log.any? { |l| l.include?('Class#new at GvUser#make_range (NEW_IDENTITY)') } &&
                   compiled_log.any? { |l| l.include?('GvOther#=== at GvUser#eqq (CLASS_EQQ)') })
      check.call('the interpreter run logs nothing', !bad_out.split('== compiled').first.include?('LOG '))
      check.call('a non-proven site (kind_dyn) and a numeric fast path still behave as dispatch',
                 compiled.include?(interpreted.find { |l| l.start_with?('kind_dyn =>') }) &&
                   compiled.include?(interpreted.find { |l| l.start_with?('add =>') }))
    end

    dispatch_built, dispatch_results = outputs.call('-DBC2CPP_GUARD_VIOLATION_DISPATCH')
    check.call('-DBC2CPP_GUARD_VIOLATION_DISPATCH builds', dispatch_built)
    if dispatch_built
      interpreted, compiled = values.call(dispatch_results.last.first)
      check.call('-DBC2CPP_GUARD_VIOLATION_DISPATCH: the rebound program answers what the interpreter answers',
                 !interpreted.empty? && interpreted == compiled && !dispatch_results.last.first.include?('guard violation'))
    end

    verify_built, verify_results = outputs.call('-DBC2CPP_NOMETHOD_VERIFY')
    check.call('-DBC2CPP_NOMETHOD_VERIFY builds', verify_built)
    if verify_built
      (ok_out, ok_status), (bad_out, bad_status) = verify_results
      check.call('verify mode: a program inside the closed set reaches no violation site',
                 ok_status && !ok_out.include?('NOMETHOD_VERIFY'))
      check.call('verify mode: a reached violation site aborts naming the class, name and site',
                 !bad_status && bad_out.include?('NOMETHOD_VERIFY: guard violation reached:') && bad_out.include?(' at GvUser#'))
    end
  end
else
  puts '-- SKIP run: set MRBC, BC2CPP_MRUBY_FULL (or BC2CPP_MRUBY_CORE) and have g++'
end

if failures.empty?
  puts 'bc2cpp guard violation check: PASS'
else
  warn "bc2cpp guard violation check: #{failures.size} failure(s)"
  exit 1
end
