#!/usr/bin/env ruby
# encoding: UTF-8
# frozen_string_literal: true

# Regression check for two bugs PR #1935 listed as "known, not fixed":
#   (A) Proc#call of a BLOCK_FALLBACK proc (a block body compiled as a cfunc
#       RProc) from compiled code crashed;
#   (B) `block_given?` in compiled methods was always false.
# Both are covered by BLOCK_SEMANTICS (ADR 0266) and the direct block entries
# (ADR 0271); this drives the shapes the reports named -- procs captured with
# &blk and called as .call/.()/[]/yield, lambda(&blk), procs kept in ivars and
# arrays, procs that outlive the creating frame, break/next/return inside, and
# block_given? / iterator? / defined?(yield) at every block depth -- through a
# compiled fixture and the interpreter and requires identical transcripts.
#
# Needs MRBC and BC2CPP_MRUBY_FULL (libmruby.a with the full-core gems + include/)
# and g++; without them only the generated-code checks run.
#
# Usage: MRBC=path/to/mrbc BC2CPP_MRUBY_FULL=dir ruby scripts/bc2cpp/proc_call_block_given_check.rb
# PC_ONLY=t_name,... limits the run; PC_DUMP=1 prints every interpreter transcript.

require 'tmpdir'
require_relative 'fixture_runtime'

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

FIXTURE = <<~'RUBY'
  class PcCase
    def y0; yield; end
    def y1(a); yield a; end
    def y2(a, b); yield a, b; end
    def each_of(a); i = 0; while i < a.size; yield a[i]; i += 1; end; a; end

    # --- (A) procs captured with &blk ---
    def cap(&b); b; end
    def cap_call(a, &b); b.call(a); end
    def cap_dot(a, &b); b.(a); end
    def cap_idx(a, &b); b[a]; end
    def cap_yield(a, &b); b.yield(a); end
    def cap_forms(a, &b); [b.call(a), b.(a), b[a], b.yield(a)]; end
    def cap_call_noargs(&b); b.call; end
    def cap_call_two(a, c, &b); b.call(a, c); end
    def cap_call_splat(a, &b); b.call(*a); end
    def cap_twice(&b); [b.call(1), b.call(2)]; end
    def cap_lambda(&b); lambda(&b); end
    def cap_lambda_call(a, &b); l = lambda(&b); l.call(a); end
    def cap_via_each(a, &b); r = []; each_of(a) { |x| r << b.call(x) }; r; end
    def cap_pass(a, &b); y1(a, &b); end
    def cap_pass_call(a, &b); cap_call(a, &b); end
    def cap_nil(&b); b.nil?; end
    def cap_nil_call(&b); b ? b.call : :nil; end
    def cap_respond(&b); b.respond_to?(:call); end

    # --- procs stored and called later from another method ---
    def store(&b); @stored = b; :stored; end
    def stored_call(a); @stored.call(a); end
    def stored_dot(a); @stored.(a); end
    def stored_idx(a); @stored[a]; end
    def stored_twice; [@stored.call(1), @stored.call(2)]; end
    def store_in_array(&b); (@procs ||= []) << b; @procs.size; end
    def array_call(i, a); @procs[i].call(a); end
    def array_all(a); r = []; each_of(@procs) { |pr| r << pr.call(a) }; r; end
    def store_in_hash(k, &b); (@table ||= {})[k] = b; end
    def hash_call(k, a); @table[k].call(a); end
    def store_lambda(&b); @lam = lambda(&b); end
    def lam_call(a); @lam.call(a); end
    def after_gc(a); GC.start; @stored.call(a); end

    # --- escapes: the proc is returned out of the creating frame ---
    def esc_plain; cap { |x| x + 1 }; end
    def esc_upvar(n); cap { |x| x + n }; end
    def esc_ivar; @base = 100; cap { |x| x + @base }; end
    def esc_self; cap { |x| self.class.name + x.to_s }; end
    def esc_counter; n = 0; cap { n += 1 }; end
    def esc_nested(n); cap { |x| cap { |y| x + y + n } }; end
    def esc_chain(n); cap { |x| n = n + x }; end

    # --- break / next / return inside a called proc ---
    def cap_break(&b); [b.call(1), :after]; end
    def cap_next_body(&b); [b.call(1), :after]; end
    def stored_break_call; @stored.call(1); end
    def mk_return_proc; store { |x| return :ret }; end

    # --- (B) block_given? / iterator? / defined?(yield) ---
    def bg0; block_given?; end
    def bg_yield(a); block_given? ? yield(a) : :none; end
    def bg_yield_unless(a); return :none unless block_given?; yield a; end
    def bg_iter; iterator?; end
    def bg_iter_yield(a); iterator? ? yield(a) : :none; end
    def bg_defined; defined?(yield); end
    def bg_defined_yield(a); defined?(yield) ? yield(a) : :none; end
    def bg_amp(a, &b); [block_given?, b.nil?]; end
    def bg_amp_yield(a, &b); block_given? ? [yield(a), b.call(a)] : :none; end
    def bg_opt(a, c = 1); block_given? ? yield(a + c) : :none; end
    def bg_rest(*r); block_given? ? yield(r) : :none; end
    def bg_kw(a, k: 2); block_given? ? yield(a * k) : :none; end
    def bg_not(a); !block_given?; end
    def bg_and(a); block_given? && a; end
    def bg_fwd(a, &b); bg_yield(a, &b); end
    def bg_fwd_none(a); bg_yield(a); end
    def bg_fwd_nil(a); bg_yield(a, &nil); end
    def bg_fwd_own(a); bg_yield(a) { |x| x + 1 }; end
    def bg_fwd_lambda(a); bg_yield(a, &lambda { |x| x * 3 }); end
    def bg_fwd_proc(a); bg_yield(a, &Proc.new { |x| x * 4 }); end
    def bg_in_blk(a); y1(a) { block_given? }; end
    def bg_in_blk2(a); y1(a) { y1(a) { block_given? } }; end
    def bg_in_blk3(a); y1(a) { y1(a) { y1(a) { block_given? } } }; end
    def bg_yield_in_blk(a); y1(a) { |x| block_given? ? yield(x) : :none }; end
    def bg_yield_in_blk2(a); y1(a) { |x| y1(x) { |z| block_given? ? yield(z) : :none } }; end
    def bg_iter_in_blk(a); y1(a) { iterator? }; end
    def bg_defined_in_blk(a); y1(a) { defined?(yield) }; end
    def bg_in_each(a); r = []; each_of(a) { |x| r << (block_given? ? yield(x) : x) }; r; end
    def bg_in_lambda(a); l = lambda { |x| block_given? }; l.call(a); end
    def bg_in_stored(&b); store { |x| block_given? }; stored_call(1); end
    def bg_twice(a); [block_given?, block_given?]; end
    def bg_after_yield(a); r = block_given? ? yield(a) : nil; [r, block_given?]; end
    def bg_dispatch(o, a); [o.bg_yield(a) { |x| x + 5 }, o.bg_yield(a), o.bg0, o.bg0 { }]; end
    def bg_self_dispatch(a); [self.bg_yield(a), bg_yield(a) { |x| x }]; end
    def bg_rescue(a); raise 'x' if a; rescue; block_given?; end
    def bg_ensure(a, log); log << block_given?; ensure log << block_given?; end
    def bg_loop(a); r = []; 2.times { r << block_given? }; r; end

    # --- test entries (called with the case itself) ---
    def t_cap_call(o); cap_call(3) { |x| x * 2 }; end
    def t_cap_dot(o); cap_dot(3) { |x| x * 2 }; end
    def t_cap_idx(o); cap_idx(3) { |x| x * 2 }; end
    def t_cap_yield(o); cap_yield(3) { |x| x * 2 }; end
    def t_cap_forms(o); cap_forms(3) { |x| x * 2 }; end
    def t_cap_noargs(o); cap_call_noargs { :noargs }; end
    def t_cap_two(o); cap_call_two(1, 2) { |a, b| a + b }; end
    def t_cap_two_ary(o); cap_call_two(1, 2) { |a| a }; end
    def t_cap_splat(o); cap_call_splat([1, 2]) { |a, b| [a, b] }; end
    def t_cap_splat_one(o); cap_call_splat([[1, 2]]) { |a, b| [a, b] }; end
    def t_cap_twice(o); cap_twice { |x| x + 1 }; end
    def t_cap_upvar(o); n = 10; cap_call(1) { |x| x + n }; end
    def t_cap_upvar_write(o); n = 0; cap_twice { |x| n += x }; n; end
    def t_cap_ivar(o); @iv = 7; cap_call(1) { |x| x + @iv }; end
    def t_cap_self(o); cap_call(1) { |x| self.class.name }; end
    def t_cap_lambda(o); cap_lambda { |x| x + 1 }.call(1); end
    def t_cap_lambda_call(o); cap_lambda_call(2) { |x| x + 1 }; end
    def t_cap_lambda_lambda_p(o); cap_lambda { |x| x }.lambda?; end
    def t_cap_via_each(o); cap_via_each([1, 2, 3]) { |x| x * x }; end
    def t_cap_via_each_upvar(o); k = 5; cap_via_each([1, 2]) { |x| x + k }; end
    def t_cap_pass(o); cap_pass(4) { |x| x - 1 }; end
    def t_cap_pass_call(o); cap_pass_call(4) { |x| x - 1 }; end
    def t_cap_nil(o); [cap_nil { }, cap_nil, cap_nil(&nil)]; end
    def t_cap_nil_call(o); [cap_nil_call { :blk }, cap_nil_call]; end
    def t_cap_respond(o); cap_respond { }; end
    def t_cap_class(o); cap { }.class; end
    def t_cap_returned_call(o); pr = cap { |x| x + 1 }; [pr.call(1), pr.(2), pr[3], pr.yield(4)]; end
    def t_cap_returned_gc(o); pr = cap { |x| [x, "s#{x}"] }; GC.start; pr.call(1); end
    def t_cap_dispatch(o); [o.cap_call(3) { |x| x * 2 }, o.cap_twice { |x| x + 1 }]; end
    def t_cap_error_arity(o); cap_lambda { |a, b| a }.call(1); end
    def t_cap_raise(o); cap_call(1) { |x| raise ArgumentError, 'boom' }; end
    def t_cap_raise_rescue(o); begin; cap_call(1) { |x| raise ArgumentError, 'boom' }; rescue ArgumentError => e; e.message; end; end

    def t_store_call(o); store { |x| x + 40 }; stored_call(2); end
    def t_store_dot(o); store { |x| x + 40 }; stored_dot(2); end
    def t_store_idx(o); store { |x| x + 40 }; stored_idx(2); end
    def t_store_twice(o); store { |x| x * 2 }; stored_twice; end
    def t_store_upvar(o); n = 5; store { |x| x + n }; stored_call(1); end
    def t_store_ivar(o); @v = 9; store { |x| x + @v }; stored_call(1); end
    def t_store_self(o); store { |x| self.class.name }; stored_call(1); end
    def t_store_gc(o); store { |x| [x, "s#{x}"] }; after_gc(1); end
    def t_store_array(o); store_in_array { |x| x + 1 }; store_in_array { |x| x * 2 }; array_all(10); end
    def t_store_array_one(o); store_in_array { |x| x + 1 }; array_call(0, 1); end
    def t_store_hash(o); store_in_hash(:a) { |x| x - 1 }; store_in_hash(:b) { |x| x + 1 }; [hash_call(:a, 5), hash_call(:b, 5)]; end
    def t_store_lambda(o); store_lambda { |x| x + 1 }; lam_call(1); end
    def t_store_lambda_p(o); store_lambda { |x| x }.lambda?; end
    def t_store_replace(o); store { |x| 1 }; a = stored_call(0); store { |x| 2 }; [a, stored_call(0)]; end
    def t_store_break(o); store { |x| break :stored }; stored_call(1); end
    def t_store_next(o); store { |x| next x + 1; 0 }; stored_call(1); end
    def t_store_return(o); store { |x| return :stored }; stored_call(1); end
    def t_store_return_frame(o); mk_return_proc; stored_call(1); end
    def t_store_raise(o); store { |x| raise 'sb' }; begin; stored_call(1); rescue => e; e.message; end; end

    def t_esc_plain(o); pr = esc_plain; [pr.call(1), pr.call(2)]; end
    def t_esc_upvar(o); pr = esc_upvar(10); [pr.call(1), pr.call(2)]; end
    def t_esc_ivar(o); pr = esc_ivar; [pr.call(1), pr.call(2)]; end
    def t_esc_self(o); pr = esc_self; pr.call(1); end
    def t_esc_counter(o); pr = esc_counter; [pr.call, pr.call, pr.call]; end
    def t_esc_nested(o); pr = esc_nested(100); pr.call(1).call(2); end
    def t_esc_chain(o); pr = esc_chain(0); [pr.call(1), pr.call(2), pr.call(3)]; end
    def t_esc_gc(o); pr = esc_upvar(10); GC.start; y1(0) { [1] * 10 }; GC.start; pr.call(1); end
    def t_esc_two(o); a = esc_upvar(1); b = esc_upvar(2); [a.call(0), b.call(0), a.call(0)]; end

    def t_break_direct(o); cap_break { |x| break :brk }; end
    def t_next_direct(o); cap_next_body { |x| next :nxt; 9 }; end
    def t_next_value(o); cap_call(1) { |x| next x + 1 if x > 0; 0 }; end
    def t_return_direct(o); cap_call(1) { |x| return :returned }; :after; end
    def t_break_in_loop(o); r = []; each_of([1, 2, 3]) { |x| r << cap_call(x) { |y| next y * 2 } }; r; end
    def t_break_outer(o); each_of([1, 2, 3]) { |x| cap_call(x) { |y| break :inner } }; end
    def t_return_outer(o); each_of([1, 2, 3]) { |x| cap_call(x) { |y| return [:ret, y] if y == 2 } }; :done; end

    def t_bg0(o); bg0; end
    def t_bg0_blk(o); bg0 { }; end
    def t_bg_yield(o); [bg_yield(1) { |x| x + 1 }, bg_yield(1)]; end
    def t_bg_yield_unless(o); [bg_yield_unless(1) { |x| x + 1 }, bg_yield_unless(1)]; end
    def t_bg_iter(o); [bg_iter, bg_iter { }]; end
    def t_bg_iter_yield(o); [bg_iter_yield(1) { |x| x + 1 }, bg_iter_yield(1)]; end
    def t_bg_defined(o); [bg_defined, bg_defined { }]; end
    def t_bg_defined_yield(o); [bg_defined_yield(1) { |x| x + 1 }, bg_defined_yield(1)]; end
    def t_bg_amp(o); [bg_amp(1) { }, bg_amp(1), bg_amp(1, &nil), bg_amp(1, &Proc.new { })]; end
    def t_bg_amp_yield(o); [bg_amp_yield(2) { |x| x * 3 }, bg_amp_yield(2)]; end
    def t_bg_opt(o); [bg_opt(1) { |x| x }, bg_opt(1), bg_opt(1, 5) { |x| x }]; end
    def t_bg_rest(o); [bg_rest(1, 2) { |x| x }, bg_rest]; end
    def t_bg_kw(o); [bg_kw(3) { |x| x }, bg_kw(3), bg_kw(3, k: 4) { |x| x }]; end
    def t_bg_not(o); [bg_not(1) { }, bg_not(1)]; end
    def t_bg_and(o); [bg_and(1) { }, bg_and(1)]; end
    def t_bg_fwd(o); [bg_fwd(1) { |x| x + 1 }, bg_fwd(1)]; end
    def t_bg_fwd_none(o); bg_fwd_none(1); end
    def t_bg_fwd_nil(o); bg_fwd_nil(1); end
    def t_bg_fwd_own(o); bg_fwd_own(1); end
    def t_bg_fwd_lambda(o); bg_fwd_lambda(2); end
    def t_bg_fwd_proc(o); bg_fwd_proc(2); end
    def t_bg_in_blk(o); [bg_in_blk(1) { }, bg_in_blk(1)]; end
    def t_bg_in_blk2(o); [bg_in_blk2(1) { }, bg_in_blk2(1)]; end
    def t_bg_in_blk3(o); [bg_in_blk3(1) { }, bg_in_blk3(1)]; end
    def t_bg_yield_in_blk(o); [bg_yield_in_blk(1) { |x| x + 1 }, bg_yield_in_blk(1)]; end
    def t_bg_yield_in_blk2(o); [bg_yield_in_blk2(1) { |x| x + 1 }, bg_yield_in_blk2(1)]; end
    def t_bg_iter_in_blk(o); [bg_iter_in_blk(1) { }, bg_iter_in_blk(1)]; end
    def t_bg_defined_in_blk(o); [bg_defined_in_blk(1) { }, bg_defined_in_blk(1)]; end
    def t_bg_in_each(o); [bg_in_each([1, 2]) { |x| x * 10 }, bg_in_each([1, 2])]; end
    def t_bg_in_lambda(o); [bg_in_lambda(1) { }, bg_in_lambda(1)]; end
    def t_bg_in_stored(o); [bg_in_stored { }, bg_in_stored]; end
    def t_bg_twice(o); [bg_twice(1) { }, bg_twice(1)]; end
    def t_bg_after_yield(o); [bg_after_yield(1) { |x| x + 1 }, bg_after_yield(1)]; end
    def t_bg_dispatch(o); bg_dispatch(o, 1); end
    def t_bg_self_dispatch(o); bg_self_dispatch(1); end
    def t_bg_rescue(o); [bg_rescue(true) { }, bg_rescue(true)]; end
    def t_bg_ensure(o); l1 = []; l2 = []; bg_ensure(1, l1) { }; bg_ensure(1, l2); [l1, l2]; end
    def t_bg_loop(o); [bg_loop(1) { }, bg_loop(1)]; end
    def t_bg_own(o); block_given?; end
    def t_bg_own_blk(o); y1(1) { block_given? }; end
    def t_bg_own_iter(o); iterator?; end
    def t_bg_own_defined(o); defined?(yield); end
  end

  class PcRunner
    def run(name)
      bc = PcCase.new
      v = bc.__send__(name, bc)
      "#{name}: #{v.inspect}"
    rescue Exception => e
      "#{name}: !#{e.class}: #{e.message}"
    end
  end
RUBY

# Integer#times is an mrblib method: the core-only VM has none.
FULL_ONLY = %w[t_bg_loop].freeze

runtime = Bc2cppFixtureRuntime
abort 'MRBC is required' unless ENV['MRBC']
only = ENV['PC_ONLY']&.split(',')
names = FIXTURE.scan(/^\s+def (t_\w+)\(o\)/).flatten

body_of = lambda do |code, function|
  code[/^mrb_value #{Regexp.escape(function)}_impl\(mrb_state\* M.*?(?=^(?:static )?mrb_value \w+\(mrb_state\* M|\z)/m].to_s
end
dispatch = /\bmrb_funcall(?:_with_block|_argv|_id)?\(|\bbc2cpp_send\(/

RUNNER = <<~CPP
  #include <cstdlib>
  static int scenario(mrb_state* M) {
    mrb_value runner = mrb_obj_new(M, mrb_class_get(M, "PcRunner"), 0, nullptr);
    mrb_value name = mrb_str_new_cstr(M, std::getenv("PC_CASE"));
    mrb_value text = mrb_funcall_argv(M, runner, mrb_intern_lit(M, "run"), 1, &name);
    if (M->exc) { mrb_print_error(M); return 3; }
    std::fwrite(RSTRING_PTR(text), 1, RSTRING_LEN(text), stdout);
    std::fputc('\\n', stdout);
    std::fflush(stdout);
    return 0;
  }
CPP

Dir.mktmpdir('pc', ENV['TMPDIR'] || Dir.tmpdir) do |dir|
  puts '-- generated code'
  code, err = runtime.generate(FIXTURE, dir)
  uncompiled = names.select { |n| body_of.call(code, "PcCase_#{n}").empty? || body_of.call(code, "PcCase_#{n}").include?('#error') }
  puts "  note: kept interpreted: #{uncompiled.join(' ')}" unless uncompiled.empty?
  check.call('block_given? in a compiled method reads the frame block, not a dispatch',
             !body_of.call(code, 'PcCase_bg0').match?(dispatch) && body_of.call(code, 'PcCase_bg0').include?('bc2cpp_blk'))
  check.call('iterator? (kernel.c aliases it to block_given?) reads the frame block too',
             !body_of.call(code, 'PcCase_bg_iter').match?(dispatch) && body_of.call(code, 'PcCase_bg_iter').include?('bc2cpp_blk'))
  check.call('block_given? inside an inlined Integer#times body names a declared register',
             body_of.call(code, 'PcCase_bg_loop').include?('bc2cpp_times_n_'))
  check.call('a proc capturing locals stays interpreted (it outlives the frame); a self-only one is a real RProc',
             %w[esc_upvar esc_counter esc_nested esc_chain].all? { |n| body_of.call(code, "PcCase_#{n}").empty? } &&
               body_of.call(code, 'PcCase_esc_plain').include?('mrb_proc_new_cfunc_with_env'))
  check.call('the block-capturing methods are compiled, not left to the interpreter',
             %w[cap_call cap_dot cap_idx store stored_call].none? { |n| body_of.call(code, "PcCase_#{n}").empty? })

  full = runtime.full unless ENV['PC_CORE']
  build = full || runtime.core
  if build.nil? || !runtime.compiler?
    puts '  SKIP run: set BC2CPP_MRUBY_CORE or BC2CPP_MRUBY_FULL and have g++'
  else
    puts "-- differential run on the #{full ? 'full-core' : 'core-only'} VM"
    run_names = only ? names & only : names
    run_names -= FULL_ONLY unless full
    built, results = runtime.run(dir, err, %w[PcCase], RUNNER, build: build, full: !full.nil?,
                                                                envs: run_names.map { |n| { 'PC_CASE' => n } })
    check.call('the fixture compiles against real mruby', built)
    if built
      bad = 0
      run_names.zip(results).each do |name, (output, _ok)|
        sections = runtime.sections(output)
        interpreted = sections['interpreted']&.join("\n")
        compiled = sections['compiled']&.join("\n")
        compiled = 'CRASH' if compiled.nil? || compiled.empty?
        puts "       #{interpreted}" if ENV['PC_DUMP']
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
  puts 'bc2cpp proc call block_given check: PASS'
else
  warn "bc2cpp proc call block_given check: #{failures.size} failure(s)"
  exit 1
end
