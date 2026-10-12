#!/usr/bin/env ruby
# encoding: UTF-8
# frozen_string_literal: true

# RESCUE_ERRINFO: a compiled `rescue` must publish the exception it caught as `$!` (mrb->errinfo)
# the way vm.c's OP_EXCEPT does, so a bare `raise` re-raises it, `$!` reads it, and the frame's exit
# drops it. Each scenario is a method of one fixture class, compiled by bc2cpp in a closed
# world; the runner calls it in its own process once interpreted and once with the compiled
# entry points registered over it, and the two transcripts must be equal.
#
# Needs MRBC and, for the run, BC2CPP_MRUBY_CORE (libmruby_core.a + include/) and g++.
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_CORE=dir] ruby scripts/bc2cpp/rescue_errinfo_check.rb
# RE_ONLY=t_name,... limits the run; RE_DUMP=1 prints every interpreter transcript.

require 'fileutils'
require 'tmpdir'
require_relative 'fixture_runtime'

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

# The harness VM has no mrblib (no Array#each): the fixture yields from its own methods.
FIXTURE = <<~'RUBY'
  class ReErr < StandardError
    attr_reader :tag
    def initialize(msg = 'tagged', tag = :t); super(msg); @tag = tag; end
  end

  class ReCase
    # --- callees ---
    def y1(a); yield a; end
    def thrower(msg); raise ArgumentError, msg; end
    def peek; $!; end
    def bare_raise_in_handler(log)
      begin
        raise ArgumentError, 'inner'
      rescue => e
        log << e
        raise
      end
    end
    def rescue_and_return; begin; raise 'x'; rescue; :r; end; end
    def rescue_keep_bang; begin; raise 'x'; rescue => e; $!; end; end
    def reraise_after_call(log)
      raise 'outer'
    rescue => e
      log << e
      rescue_and_return
      raise
    end
    def multi(k)
      begin
        raise ReErr.new('m', k) if k == :re
        raise ArgumentError, 'm' if k == :arg
        raise 'plain'
      rescue ReErr => e
        [:re, $!.equal?(e), e.tag]
      rescue ArgumentError => e
        raise
      end
    end
    def ensure_bang(log)
      begin
        raise 'in-ensure'
      ensure
        log << $!.class
      end
    end
    def ensure_after_rescue(log)
      begin
        begin
          raise 'a'
        rescue => e
          raise
        ensure
          log << :ensure
        end
      rescue => e2
        log << e2.message
      end
    end
    def retry_loop
      n = 0
      begin
        n += 1
        raise 'again' if n < 3
        [n, $!.class]
      rescue
        retry
      end
    end

    # --- scenarios ---
    def t_bare_raise(o); begin; raise ArgumentError, 'a'; rescue => e; raise; end; end
    def t_bare_raise_same(o)
      log = []
      begin
        bare_raise_in_handler(log)
      rescue => e2
        [e2.equal?(log[0]), e2.class, e2.message]
      end
    end
    def t_bare_raise_no_rescue(o); raise; end
    def t_bare_raise_after_rescue(o); begin; raise 'a'; rescue; end; begin; raise; rescue => e; e.message; end; end
    def t_bang_in_handler(o); begin; raise 'a'; rescue => e; $!.equal?(e); end; end
    def t_bang_message(o); begin; raise 'a'; rescue; $!.message; end; end
    def t_bang_outside(o); $!; end
    def t_bang_after_call(o); rescue_and_return; $!; end
    def t_bang_returned(o); rescue_keep_bang.equal?($!) ? :leaked : rescue_keep_bang.class; end
    def t_bang_same_frame_after(o); begin; raise 'a'; rescue; end; $!.class; end
    def t_bang_in_callee(o); begin; raise 'a'; rescue => e; peek.equal?(e); end; end
    def t_bang_after_success(o); begin; 1; rescue; 2; end; $!; end
    def t_bang_thrower(o); begin; thrower('t'); rescue => e; [$!.equal?(e), $!.message]; end; end
    def t_reraise_thrower(o); begin; thrower('t'); rescue; raise; end; end
    def t_reraise_after_call(o)
      log = []
      begin
        reraise_after_call(log)
      rescue => e
        [e.equal?(log[0]), e.message]
      end
    end
    def t_nested_inner_bang(o)
      begin
        raise 'outer'
      rescue => e
        begin
          raise 'inner'
        rescue => i
          [$!.equal?(i), $!.message]
        end
      end
    end
    def t_nested_outer_after_inner(o)
      begin
        raise 'outer'
      rescue => e
        begin
          raise 'inner'
        rescue
        end
        [$!.message, e.message]
      end
    end
    def t_nested_reraise_outer(o)
      begin
        raise 'outer'
      rescue => e
        begin
          raise 'inner'
        rescue
        end
        raise
      end
    end
    def t_nested_in_body(o)
      begin
        begin
          raise 'inner'
        rescue => i
          raise TypeError, 'second'
        end
      rescue => e
        [e.message, $!.equal?(e)]
      end
    end
    def t_replace_in_handler(o); begin; raise 'a'; rescue; raise TypeError, 'new'; end; end
    def t_multi_re(o); multi(:re); end
    def t_multi_arg(o); multi(:arg); end
    def t_multi_other(o); multi(:other); end
    def t_no_match(o); begin; raise 'a'; rescue ArgumentError; :no; end; end
    def t_no_match_bang(o); begin; begin; raise 'a'; rescue ArgumentError; :no; end; rescue => e; [e.message, $!.equal?(e)]; end; end
    def t_modifier(o); (raise 'a' rescue $!.message); end
    def t_modifier_bang_after(o); x = (raise 'a' rescue 1); [x, $!.class]; end
    def t_ensure_bang(o); log = []; begin; ensure_bang(log); rescue; end; log; end
    def t_ensure_rescue_raise(o); log = []; ensure_after_rescue(log); log; end
    def t_retry(o); retry_loop; end
    def t_retry_reraise(o)
      n = 0
      begin
        n += 1
        raise 'r'
      rescue
        n < 3 ? retry : raise
      end
    end
    def t_block_raise(o); begin; y1(1) { raise 'q' }; rescue => e; [e.message, $!.equal?(e)]; end; end
    def t_block_raise_reraise(o); begin; y1(1) { raise 'q' }; rescue; raise; end; end
    def t_block_rescue_bare(o); y1(1) { begin; raise 'z'; rescue; raise; end }; end
    def t_block_rescue_bang(o); y1(1) { begin; raise 'z'; rescue => e; $!.equal?(e); end }; end
    def t_block_rescue_then_outer(o)
      begin
        y1(1) { begin; raise 'z'; rescue; raise; end }
      rescue => e
        [e.message, $!.equal?(e)]
      end
    end
    def t_block_in_handler(o); begin; raise 'a'; rescue => e; y1(1) { |x| raise }; end; end
    def t_block_bang_in_handler(o); begin; raise 'a'; rescue => e; y1(1) { |x| $!.equal?(e) }; end; end
    def t_block_bang_after(o); y1(1) { begin; raise 'z'; rescue; end }; $!; end
    def t_block_break_rescue(o); y1(1) { begin; raise 'z'; rescue => e; break e.message; end }; end
    def t_defined_const_bang(o); defined?(ReNoSuch::Thing); $!.class; end
    def t_defined_const_bang_outer(o); defined?(ReNoSuch); $!; end
    def t_custom_class(o); begin; raise ReErr.new('c', :x); rescue => e; raise; end; end
    def t_custom_tag(o); begin; begin; raise ReErr.new('c', :x); rescue; raise; end; rescue ReErr => e; e.tag; end; end
    def t_raise_explicit(o); begin; raise 'a'; rescue => e; raise e; end; end
    def t_raise_class_in_handler(o); begin; raise 'a'; rescue; raise ArgumentError; end; end
    def t_exc_state(o); begin; raise 'a'; rescue; end; begin; raise 'b'; rescue => e; $!.message; end; end
  end

  class ReRunner
    def run(name)
      bc = ReCase.new
      v = bc.__send__(name, bc)
      "#{name}: #{v.inspect} bang=#{$!.inspect}"
    rescue Exception => e
      "#{name}: !#{e.class}: #{e.message.inspect} bang=#{$!.equal?(e)}"
    end
  end
RUBY

runtime = Bc2cppFixtureRuntime
abort 'MRBC is required' unless ENV['MRBC']
only = ENV['RE_ONLY']&.split(',')

RUNNER = <<~CPP
  #include <cstdlib>
  static int scenario(mrb_state* M) {
    mrb_value runner = mrb_obj_new(M, mrb_class_get(M, "ReRunner"), 0, nullptr);
    mrb_value name = mrb_str_new_cstr(M, std::getenv("RE_CASE"));
    mrb_value text = mrb_funcall_argv(M, runner, mrb_intern_lit(M, "run"), 1, &name);
    if (M->exc) { mrb_print_error(M); return 3; }
    std::fwrite(RSTRING_PTR(text), 1, RSTRING_LEN(text), stdout);
    std::fputc('\\n', stdout);
    std::fflush(stdout);
    return 0;
  }
CPP

body_of = lambda do |code, function|
  code[/^mrb_value #{Regexp.escape(function)}_impl\(mrb_state\* M.*?(?=^(?:static )?mrb_value \w+\(mrb_state\* M|\z)/m].to_s
end

puts '-- generated code'
Dir.mktmpdir('re', ENV['TMPDIR'] || Dir.tmpdir) do |dir|
  code, err = runtime.generate(FIXTURE, dir)
  names = FIXTURE.scan(/^\s+def (t_\w+)\(o\)/).flatten
  uncompiled = names.select { |n| body_of.call(code, "ReCase_#{n}").empty? || body_of.call(code, "ReCase_#{n}").include?('#error') }
  puts "       (interpreted only: #{uncompiled.join(' ')})" unless uncompiled.empty?
  check.call('a compiled rescue publishes the caught exception as errinfo', code.include?('bc2cpp_set_errinfo('))
  check.call('a method with a rescue owns the errinfo scope a callinfo pop would give it',
             body_of.call(code, 'ReCase_rescue_and_return').include?('Bc2cppErrinfoScope bc2cpp_errinfo_scope(M);'))
  check.call('a method without a handler has no errinfo scope',
             !body_of.call(code, 'ReCase_peek').include?('Bc2cppErrinfoScope'))

  core = runtime.core
  if core.nil? || !runtime.compiler?
    puts '  SKIP run: no libmruby_core.a with include/ found (set BC2CPP_MRUBY_CORE)'
  else
    puts '-- differential run on the core-only VM'
    run_names = only ? names & only : names
    built, results = runtime.run(dir, err, %w[ReCase], RUNNER, build: core, full: false,
                                                                 envs: run_names.map { |n| { 'RE_CASE' => n } })
    check.call('the fixture compiles against real mruby', built)
    if built
      bad = 0
      run_names.zip(results).each do |name, (output, _ok)|
        sections = runtime.sections(output)
        interpreted = sections['interpreted']&.join("\n")
        compiled = sections['compiled']&.join("\n")
        compiled = 'CRASH' if compiled.nil? || compiled.empty?
        puts "       #{interpreted}" if ENV['RE_DUMP']
        if interpreted.nil? || interpreted.empty?
          puts "  FAIL #{name}: the interpreter run itself failed: #{output.lines.last(3).join}"
          failures << name
          bad += 1
        elsif interpreted != compiled
          puts "  DIFF #{name}\n       interpreted: #{interpreted}\n       compiled:    #{compiled}"
          failures << name
          bad += 1
        end
      end
      check.call("all #{run_names.size} scenarios agree with the interpreter (#{bad} differ)", bad.zero?)
    end
  end
end

if failures.empty?
  puts 'bc2cpp rescue errinfo check: PASS'
else
  warn "bc2cpp rescue errinfo check: #{failures.size} failure(s)"
  exit 1
end
