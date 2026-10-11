#!/usr/bin/env ruby
# encoding: UTF-8
# frozen_string_literal: true

# Check CORE_SELF_EXACT (docs/adr/0381): inside a compiled body of Array, Hash, String or Range, `self` is exactly
# that class once the program has no subclass of it, so a send on self takes the exact-class arm of ADR 0359 with its
# class test and its bc2cpp_guard_violation (docs/adr/0290) else, instead of the tag chain and a by-name send.
#
# 1. Generated code (needs MRBC): bare and explicit `self` sends in the four owners are checked sites with no
#    bc2cpp_send; each refusal (a block, a parameter, a module owner, a subclass anywhere in the program --
#    per owner --, a singleton maker, both kill switches, the open world) keeps the tag chain and its send.
# 2. Behaviour on real mruby (needs MRBC, BC2CPP_MRUBY_CORE and g++): an honouring program answers what the
#    interpreter answers and reaches no violation site (also under -DBC2CPP_NOMETHOD_VERIFY); an instance of a
#    subclass the analysis did not see (made by the driver) reaches the compiled body, which logs
#    `[RPG2k] closed-world guard violation: <Class>#<name> at <site>` and raises BC2cppGuardViolation; verify
#    mode aborts naming the class, the name and the site.
#
# Usage: [MRBC=path/to/mrbc BC2CPP_MRUBY_CORE=dir] ruby scripts/bc2cpp/core_self_exact_check.rb

require 'tmpdir'
require_relative 'fixture_runtime'

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

runtime = Bc2cppFixtureRuntime
CORE_PATH = '3rd/mruby/mrblib/gvs_core.rb'
OWNERS = %w[GvsEngine].freeze

CORE_FIXTURE = <<~'RUBY'
  class Array
    def gvs_size; size; end
    def gvs_length; self.length; end
    def gvs_param(a); a.size; end
    def gvs_block; n = 0; [1].each { |_x| n = size }; n; end
    def gvs_tap; tap { |_x| size }; end
    def gvs_alias_self; x = self; x.size; end
  end
  class Hash
    def gvs_keys; keys; end
  end
  class String
    def gvs_len; bytesize; end
  end
  class Range
    def gvs_begin; self.begin; end
  end
  module Comparable
    def gvs_mod; size; end
  end
RUBY

ENGINE_FIXTURE = <<~'RUBY'
  class GvsEngine
    def one; 1; end
  end
RUBY

SUBCLASS = ->(base) { "#{ENGINE_FIXTURE.sub(/^end\n\z/, '')}  class Gvs#{base}Sub < #{base}; end\nend\n" }
MAKER_FIXTURE = "#{ENGINE_FIXTURE.sub(/^end\n\z/, '')}  def maker(o); o.instance_eval { 1 }; end\nend\n"

PROVEN = %w[Array#gvs_size Array#gvs_length Hash#gvs_keys String#gvs_len Range#gvs_begin].freeze
KLASS = { 'Array' => 'array', 'Hash' => 'hash', 'String' => 'string', 'Range' => 'range' }.freeze

chunk = lambda do |code, owner_method|
  code[/^\/\/ #{Regexp.escape(owner_method)} \(compiled from.*?(?=^\/\/ \S+#\S+ \(compiled from|\z)/m].to_s
end
generate = lambda do |dir, engine: ENGINE_FIXTURE, closed: true, env: {}|
  saved = env.to_h { |k, _| [k, ENV.fetch(k, nil)] }
  env.each { |k, v| ENV[k] = v }
  begin
    runtime.generate(CORE_FIXTURE, dir, closed: closed, only_owners: OWNERS, path: CORE_PATH, core: true,
                                        extra: [['gvs_engine.rb', engine]])
  ensure
    saved.each { |k, v| v ? ENV[k] = v : ENV.delete(k) }
  end
end
checked = ->(text) { text.match?(/CORE_BODY_EXACT_CHECKED :\w+\??  *-> \w+/) || text.match?(/CORE_BODY_EXACT_CHECKED :\w+\?? -> \w+/) }

if ENV['MRBC']
  puts '== generated code'
  Dir.mktmpdir do |dir|
    code, err = generate.call(dir)
    PROVEN.each do |om|
      owner, = om.split('#')
      text = chunk.call(code, om)
      check.call("#{om}: a send on self is a checked site -- class test on self, violation else, no by-name send",
                 checked.call(text) &&
                   text.include?("if (mrb_#{KLASS[owner]}_p(self) && mrb_obj_ptr(self)->c == M->#{KLASS[owner]}_class) {") &&
                   text.include?("\"#{om} (CORE_BODY_EXACT)\"") && !text.include?('bc2cpp_send('))
    end
    check.call('NEG: a parameter receiver is no proof', !checked.call(chunk.call(code, 'Array#gvs_param')) &&
                                                         chunk.call(code, 'Array#gvs_param').include?('bc2cpp_send('))
    check.call('NEG: a block body is no proof (the block may run with another self)',
               !checked.call(chunk.call(code, 'Array#gvs_block')))
    tap_chunks = code.scan(/^\/\/ Array#gvs_tap\S* \(compiled from.*?(?=^\/\/ \S+#\S+ \(compiled from|\z)/m).join
    check.call('NEG: a block compiled apart (tap) is no proof either', !tap_chunks.empty? && !checked.call(tap_chunks))
    check.call('a MOVE copy of self is followed', checked.call(chunk.call(code, 'Array#gvs_alias_self')))
    check.call('NEG: a module owner (Comparable, any includer) is no proof', !checked.call(chunk.call(code, 'Comparable#gvs_mod')))
    check.call('the fixture methods are compiled as core bodies',
               (PROVEN + %w[Array#gvs_param Array#gvs_block Comparable#gvs_mod]).none? { |m| chunk.call(code, m).empty? })
    check.call('the violation sites are listed with the other CORE_BODY_EXACT sites',
               err.include?('GUARD_VIOLATION_SITE Array#gvs_size -> size') && err.include?('GUARD_VIOLATION_SITE Range#gvs_begin -> begin'))
    every = code.scan(/^\/\/ (\S+#\S+) \(compiled from[^\n]*\n(.*?)(?=^\/\/ \S+#\S+ \(compiled from|\z)/m)
    check.call("no unchecked 'unguarded proof' arm in a compiled core body (#{every.size} bodies scanned)",
               every.none? { |_name, text| text.include?('unguarded proof') && !text.include?('CORE_BODY_EXACT_CHECKED') })
  end

  Dir.mktmpdir do |dir|
    code, = generate.call(dir, env: { 'BC2CPP_CORE_SELF_EXACT' => '0' })
    texts = PROVEN.map { |m| chunk.call(code, m) }
    check.call('BC2CPP_CORE_SELF_EXACT=0: no proof on self, the tag chain and its send are back',
               texts.none? { |t| checked.call(t) } && texts.all? { |t| t.include?('bc2cpp_send(') })
  end

  { 'BC2CPP_CORE_BODY_EXACT' => '0', 'BC2CPP_GUARD_VIOLATION' => '0' }.each do |name, value|
    Dir.mktmpdir do |dir|
      code, = generate.call(dir, env: { name => value })
      texts = PROVEN.map { |m| chunk.call(code, m) }
      check.call("#{name}=#{value}: the ADR 0359 switch withdraws the self proof too",
                 texts.none? { |t| checked.call(t) } && texts.all? { |t| t.include?('bc2cpp_send(') })
    end
  end

  %w[Array Hash String Range].each do |base|
    Dir.mktmpdir do |dir|
      code, = generate.call(dir, engine: SUBCLASS.call(base))
      PROVEN.each do |om|
        owner, = om.split('#')
        text = chunk.call(code, om)
        if owner == base
          check.call("NEG: a subclass of #{base} in the program withdraws #{om}", !checked.call(text) && text.include?('bc2cpp_send('))
        else
          check.call("a subclass of #{base} leaves #{om} (another class) proven", checked.call(text))
        end
      end
    end
  end

  Dir.mktmpdir do |dir|
    code, = generate.call(dir, engine: MAKER_FIXTURE)
    check.call('a singleton-making engine (instance_eval) withdraws the self proof',
               PROVEN.none? { |m| checked.call(chunk.call(code, m)) })
  end

  Dir.mktmpdir do |dir|
    code, = generate.call(dir, closed: false)
    check.call('the open world proves nothing on self', !code.include?('CORE_BODY_EXACT'))
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
    #include <mruby/string.h>
    static mrb_value gv_log_puts(mrb_state* M, mrb_value) {
      mrb_value line;
      mrb_get_args(M, "S", &line);
      std::printf("  LOG %.*s\n", (int)RSTRING_LEN(line), RSTRING_PTR(line));
      return mrb_nil_value();
    }
    static void gv_call(mrb_state* M, const char* label, mrb_value obj, const char* meth) {
      mrb_value r = mrb_funcall_argv(M, obj, mrb_intern_cstr(M, meth), 0, nullptr);
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
      if (!mrb_class_defined(M, "NameError")) mrb_define_class(M, "NameError", M->eStandardError_class);
      if (!mrb_class_defined(M, "NoMethodError")) mrb_define_class(M, "NoMethodError", mrb_class_get(M, "NameError"));
      struct RClass* log = mrb_define_class(M, "GvLog", M->object_class);
      mrb_define_method(M, log, "puts", gv_log_puts, MRB_ARGS_REQ(1));
      mrb_gv_set(M, mrb_intern_lit(M, "$stderr"), mrb_obj_new(M, log, 0, nullptr));
      if (compiled) {
        // Only the fixture's own bodies replace the interpreted ones: a core-only mruby has no mrblib.
        mrb_define_method(M, M->array_class, "gvs_size", Array_gvs_size, MRB_ARGS_ANY());
        mrb_define_method(M, M->array_class, "gvs_length", Array_gvs_length, MRB_ARGS_ANY());
        mrb_define_method(M, M->hash_class, "gvs_keys", Hash_gvs_keys, MRB_ARGS_ANY());
        mrb_define_method(M, M->string_class, "gvs_len", String_gvs_len, MRB_ARGS_ANY());
        mrb_define_method(M, M->range_class, "gvs_begin", Range_gvs_begin, MRB_ARGS_ANY());
      }
      mrb_value ary = mrb_ary_new(M);
      mrb_ary_push(M, ary, mrb_fixnum_value(1));
      mrb_ary_push(M, ary, mrb_fixnum_value(2));
      mrb_value hash = mrb_hash_new(M);
      mrb_hash_set(M, hash, mrb_symbol_value(mrb_intern_lit(M, "a")), mrb_fixnum_value(1));
      mrb_value str = mrb_str_new_cstr(M, "abcd");
      mrb_value range = mrb_range_new(M, mrb_fixnum_value(3), mrb_fixnum_value(9), FALSE);
      gv_call(M, "gvs_size", ary, "gvs_size");
      gv_call(M, "gvs_length", ary, "gvs_length");
      gv_call(M, "gvs_keys", hash, "gvs_keys");
      gv_call(M, "gvs_len", str, "gvs_len");
      gv_call(M, "gvs_begin", range, "gvs_begin");
      if (violate) {
        // Subclasses the analysis did not see: their instances reach the compiled bodies.
        struct RClass* asub = mrb_define_class(M, "GvsLateArray", M->array_class);
        struct RClass* ssub = mrb_define_class(M, "GvsLateString", M->string_class);
        mrb_value late_ary = mrb_ary_new(M);
        mrb_obj_ptr(late_ary)->c = asub;
        mrb_value late_str = mrb_str_new_cstr(M, "xy");
        mrb_obj_ptr(late_str)->c = ssub;
        gv_call(M, "late_size", late_ary, "gvs_size");
        gv_call(M, "late_len", late_str, "gvs_len");
        gv_call(M, "after", ary, "gvs_size");
      }
      return 0;
    }
  CPP

  Dir.mktmpdir do |dir|
    _code, err = runtime.generate(CORE_FIXTURE, dir, closed: true, only_owners: BC2CPP_CORE_OWNERS + OWNERS, path: CORE_PATH,
                                                     extra: [['gvs_engine.rb', ENGINE_FIXTURE]])
    outputs = lambda do |flags = ''|
      saved = ENV.fetch('BC2CPP_CXXFLAGS', nil)
      ENV['BC2CPP_CXXFLAGS'] = [saved, flags].compact.reject(&:empty?).join(' ')
      begin
        runtime.run(dir, err, [], body, build: build, full: false,
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
                 interpreted.include?('gvs_size => 2') && interpreted.include?('gvs_length => 2') &&
                   interpreted.include?('gvs_keys => [:a]') && interpreted.include?('gvs_len => 4') &&
                   interpreted.include?('gvs_begin => 3'))
      check.call('  ... and reaches no violation site', !ok_out.include?('guard violation'))

      puts bad_out if ENV['BC2CPP_CHECK_VERBOSE']
      interpreted, compiled = values.call(bad_out)
      check.call('NEG: the interpreter answers for the late subclasses', bad_status &&
                                                                         interpreted.include?('late_size => 0') && interpreted.include?('late_len => 2'))
      %w[late_size late_len].each do |label|
        line = compiled.find { |l| l.start_with?("#{label} =>") }.to_s
        check.call("NEG: compiled #{label} raises BC2cppGuardViolation naming the late class, it does not read the object",
                   line.include?('raised BC2cppGuardViolation: closed-world guard violation: GvsLate') && line.include?('(CORE_BODY_EXACT)'))
      end
      check.call('NEG: the exact receivers after a violation still answer', compiled.include?('after => 2'))
      log = bad_out.split('== compiled').last.to_s.lines.grep(/^  LOG /)
      check.call('NEG: each violation logs `[RPG2k] closed-world guard violation: <Class>#<name> at <site>`',
                 log.size == 2 && log.all? { |l| l.include?('[RPG2k] closed-world guard violation: ') } &&
                   log.any? { |l| l.include?('GvsLateArray#size at Array#gvs_size (CORE_BODY_EXACT)') } &&
                   log.any? { |l| l.include?('GvsLateString#bytesize at String#gvs_len (CORE_BODY_EXACT)') })
    end

    verify_built, verify_results = outputs.call('-DBC2CPP_NOMETHOD_VERIFY')
    check.call('-DBC2CPP_NOMETHOD_VERIFY builds', verify_built)
    if verify_built
      (ok_out, ok_status), (bad_out, bad_status) = verify_results
      check.call('verify mode: an honouring program reaches no violation site', ok_status && !ok_out.include?('NOMETHOD_VERIFY'))
      check.call('verify mode: a reached self violation aborts naming the class, name and site',
                 !bad_status && bad_out.include?('NOMETHOD_VERIFY: guard violation reached:') &&
                   bad_out.include?('GvsLateArray#size') && bad_out.include?(' at Array#gvs_size'))
    end
  end
else
  puts '-- SKIP run: set MRBC, BC2CPP_MRUBY_CORE and have g++'
end

if failures.empty?
  puts 'bc2cpp core self exact check: PASS'
else
  warn "bc2cpp core self exact check: #{failures.size} failure(s)"
  exit 1
end
