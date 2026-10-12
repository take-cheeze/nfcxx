#!/usr/bin/env ruby
# encoding: UTF-8
# frozen_string_literal: true

# BLOCK_SEMANTICS (docs/adr/0266): what a block, a `yield`, a `block_given?`
# and a block held as a Proc mean in compiled code must be what the interpreter
# says. Every scenario below is a method of one fixture class, compiled by
# bc2cpp in a closed world; the runner calls each one in its own process, once
# with the interpreter and once with the compiled entry points registered over
# it, and the two transcripts (value, or exception class and message) must be
# equal. A scenario that kills the process shows up as CRASH in that column.
#
# Needs MRBC and, for the run, BC2CPP_MRUBY_CORE (libmruby_core.a + include/)
# and g++; the generation checks run with MRBC alone.
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_CORE=dir] ruby scripts/bc2cpp/block_semantics_check.rb
# BS_ONLY=t_name,... limits the run; BS_KEEP=dir keeps the generated files;
# BS_DUMP=1 prints every interpreter transcript line.

require 'fileutils'
require 'tmpdir'
require_relative 'fixture_runtime'

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

# Only core natives and no mrblib exist in the harness VM: no Array#each, so
# the fixture yields from its own methods. Callees named after the
# BLOCK_FALLBACK_UPVAR_SAFE_METHODS entries (each, section, cached_bitmap,
# page_field) are the ones whose blocks may capture the caller's locals.
FIXTURE = <<~'RUBY'
  class BsToAry
    def to_ary
      [7, 8]
    end
  end

  class BsCase
    # --- callees ---
    def y0; yield; end
    def y1(a); yield a; end
    def y2(a, b); yield a, b; end
    def y3(a, b, c); yield a, b, c; end
    def yary(a, b); yield [a, b]; end
    def yblk(a, &b); yield a; end
    def each(a); yield a; end
    def section(a, b); yield a, b; end
    def cached_bitmap(a, b); r = yield a; [r, yield(b)]; end
    def page_field(a, log); yield a; ensure log << :ens; end
    def y_rescue(a); yield a; rescue ArgumentError => e; [:rescued, e.message]; end
    def y_in_rescue(a); raise 'x'; rescue; yield a; end
    def y_in_ensure(a, log); log << :body; ensure yield a; end
    def y_retry
      n = 0
      begin
        n += 1
        yield n
      rescue RuntimeError
        retry if n < 3
        :gave_up
      end
    end

    def bg0; block_given?; end
    def bg1(a); block_given? ? yield(a) : :none; end
    def bg_in_blk(a); y1(a) { block_given? }; end
    def bg_in_blk2(a); y1(a) { y1(a) { block_given? } }; end
    def bg_and(a, &b); [block_given?, b.nil?]; end
    def bg_fwd(a, &b); bg1(a, &b); end
    def bg_opt(a, b = 1); block_given? ? yield(a + b) : :none; end
    def bg_rest(*r); block_given? ? yield(r) : :none; end
    def bg_not(a); !block_given?; end

    def take(&b); b; end
    def take_call(a, &b); b.call(a); end
    def take_call_forms(a, &b); [b.call(a), b.(a)]; end
    def take_pass(a, &b); y1(a, &b); end
    def take_arity(&b); b.arity; end
    def take_nil(&b); b.nil?; end
    def take_twice(&b); [b.call(1), b.call(2)]; end
    def take_store(&b); @stored = b; :stored; end
    def pass_through(&b); v = each(0) { |x| b.call(x) }; [:pass_finished, v]; end
    def ret_pass(&b); each(1) { |x| b.call(x) }; :ret_pass_end; end
    def rec3(n, &b)
      return b.call if n == 0

      each(n) { |x| return :inner_return if x == 99 }
      rec3(n - 1, &b)
    end
    def ysplat(a); yield(*a); end
    def y_in_each(a); each(a) { |x| yield x }; end
    def y_in_y1(a); y1(a) { |x| yield x }; end
    def stored_call(a); @stored.call(a); end

    def ar_rest(a, *r); [a, r]; end
    def ar_opt(a, b = 2); [a, b]; end
    def ar_opt2(a, b = 2, c = 3); [a, b, c]; end
    def ar_two(a, b); [a, b]; end
    def ar_kw(a, k: 1); [a, k]; end
    def ar_blk(a, &b); [a, b.nil?]; end
    def ar_rest_blk(a, *r, &b); [a, r, b.nil?]; end

    # --- block parameters versus what is yielded ---
    def t_ar_1_of_2(o); y2(1, 2) { |a| a }; end
    def t_ar_2_of_1(o); y1(1) { |a, b| [a, b] }; end
    def t_ar_2_of_ary(o); y1([1, 2]) { |a, b| [a, b] }; end
    def t_ar_1_of_ary(o); y1([1, 2]) { |a| a }; end
    def t_ar_3_of_2(o); y2(1, 2) { |a, b, c| [a, b, c] }; end
    def t_ar_2_of_3(o); y3(1, 2, 3) { |a, b| [a, b] }; end
    def t_ar_1_of_3(o); y3(1, 2, 3) { |a| a }; end
    def t_ar_0_of_1(o); y1(1) { :none }; end
    def t_ar_0_of_0(o); y0 { 5 }; end
    def t_ar_1_of_0(o); y0 { |a| a }; end
    def t_ar_2_of_0(o); y0 { |a, b| [a, b] }; end
    def t_ar_1_of_yary(o); yary(1, 2) { |x| x }; end
    def t_ar_2_of_yary(o); yary(1, 2) { |x, y| [x, y] }; end
    def t_ar_3_of_yary(o); yary(1, 2) { |x, y, z| [x, y, z] }; end
    def t_ar_2_of_nil(o); y1(nil) { |a, b| [a, b] }; end
    def t_ar_2_of_nested_ary(o); y1([[1, 2], 3]) { |a, b| [a, b] }; end
    def t_ar_2_of_empty_ary(o); y1([]) { |a, b| [a, b] }; end
    def t_ar_2_of_hash(o); y1({ a: 1 }) { |a, b| [a, b] }; end
    def t_ar_2_of_to_ary(o); y1(BsToAry.new) { |a, b| [a.class, b] }; end
    def t_ar_2_of_ary_and_more(o); y2([1, 2], 3) { |a, b| [a, b] }; end
    def t_ar_1_of_2_upvar(o); n = 0; section(4, 5) { |a| n += a }; n; end
    def t_ar_3_of_1_upvar(o); n = []; each([1, 2, 3]) { |a, b, c| n << a << b << c }; n; end
    def t_ar_disp_1_of_2(o); o.y2(1, 2) { |a| a }; end
    def t_ar_disp_2_of_1(o); o.y1(1) { |a, b| [a, b] }; end
    def t_ar_disp_2_of_ary(o); o.y1([1, 2]) { |a, b| [a, b] }; end
    def t_ar_disp_0_of_2(o); o.y2(1, 2) { :z }; end
    def t_ar_yblk_1_of_ary(o); yblk([1, 2]) { |a| a }; end
    def t_ar_yblk_2_of_ary(o); yblk([1, 2]) { |a, b| [a, b] }; end
    def t_ar_lambda_ok(o); l = ->(a, b) { a + b }; l.call(1, 2); end
    def t_ar_lambda_few(o); l = ->(a, b) { a + b }; l.call(1); end
    def t_ar_lambda_many(o); l = ->(a) { a }; l.call(1, 2); end
    def t_ar_lambda_ary(o); l = ->(a, b) { [a, b] }; l.call([1, 2]); end
    def t_ar_proc_few(o); pr = Proc.new { |a, b| [a, b] }; pr.call(1); end
    def t_ar_proc_many(o); pr = Proc.new { |a| a }; pr.call(1, 2); end
    def t_ar_proc_ary(o); pr = Proc.new { |a, b| [a, b] }; pr.call([1, 2]); end
    def t_ar_proc_ary1(o); pr = Proc.new { |a| a }; pr.call([1, 2]); end
    def t_ar_proc_none(o); pr = Proc.new { |a, b| [a, b] }; pr.call; end

    # --- entry wrapper arity errors ---
    def t_wr_rest_none(o); o.__send__(:ar_rest); end
    def t_wr_rest_ok(o); o.__send__(:ar_rest, 1, 2, 3); end
    def t_wr_opt_none(o); o.__send__(:ar_opt); end
    def t_wr_opt_many(o); o.__send__(:ar_opt, 1, 2, 3); end
    def t_wr_opt2_many(o); o.__send__(:ar_opt2, 1, 2, 3, 4); end
    def t_wr_two_few(o); o.__send__(:ar_two, 1); end
    def t_wr_two_many(o); o.__send__(:ar_two, 1, 2, 3); end
    def t_wr_rest_blk_none(o); o.__send__(:ar_rest_blk); end
    def t_wr_blk_many(o); o.__send__(:ar_blk, 1, 2); end
    def t_wr_kw_few(o); o.__send__(:ar_kw); end
    def t_wr_kw_many(o); o.__send__(:ar_kw, 1, 2); end
    def t_wr_rest_direct(o); ar_rest; end
    def t_wr_opt_direct(o); ar_opt(1, 2, 3); end

    # --- block_given? ---
    def t_bg_none(o); bg0; end
    def t_bg_literal(o); bg0 { }; end
    def t_bg_yield(o); [bg1(2) { |x| x * 3 }, bg1(2)]; end
    def t_bg_in_blk(o); [bg_in_blk(1) { }, bg_in_blk(1)]; end
    def t_bg_in_blk2(o); [bg_in_blk2(1) { }, bg_in_blk2(1)]; end
    def t_bg_amp(o); [bg_and(1) { }, bg_and(1), bg_and(1, &nil), bg_and(1, &Proc.new { })]; end
    def t_bg_fwd(o); [bg_fwd(1) { |x| x + 1 }, bg_fwd(1)]; end
    def t_bg_opt(o); [bg_opt(1) { |x| x * 10 }, bg_opt(1), bg_opt(1, 2) { |x| x * 10 }]; end
    def t_bg_rest(o); [bg_rest(1, 2) { |r| r.size }, bg_rest(1, 2)]; end
    def t_bg_not(o); [bg_not(1) { }, bg_not(1)]; end
    def t_bg_disp(o); [o.bg0 { }, o.bg0, o.bg1(3) { |x| x + 1 }, o.bg1(3)]; end
    def t_bg_send(o); [o.__send__(:bg0) { }, o.__send__(:bg0), o.__send__(:bg_opt, 1) { |x| x }]; end
    def t_bg_own(o); block_given?; end
    def t_bg_own_blk(o); y1(1) { block_given? }; end
    def t_bg_fwd_disp(o); [o.bg_fwd(1) { |x| x + 1 }, o.bg_fwd(1)]; end

    # --- a block read as a value ---
    def t_take_call(o); take_call(3) { |x| x * 2 }; end
    def t_take_call_forms(o); take_call_forms(3) { |x| x * 2 }; end
    def t_take_pass(o); take_pass(3) { |x| x * 2 }; end
    def t_take_arity(o); take_arity { |a, b| }; end
    def t_take_arity0(o); take_arity { }; end
    def t_take_arity1(o); take_arity { |a| }; end
    def t_take_lambda_arg(o); take_arity(&lambda { |a| a }); end
    def t_take_nil(o); [take_nil { }, take_nil]; end
    def t_take_none(o); take; end
    def t_take_class(o); take { }.class; end
    def t_take_ret(o); pr = take { |x| x + 1 }; [pr.call(1), pr.call(2)]; end
    def t_take_twice(o); take_twice { |x| x * 7 }; end
    def t_take_store(o); take_store { |x| x + 40 }; stored_call(2); end
    def t_take_disp(o); [o.take_call(3) { |x| x * 2 }, o.take_twice { |x| x + 1 }]; end
    def t_take_lambda_yield(o); y2(1, 2, &lambda { |a, b| a - b }); end
    def t_take_lambda_yield_ary(o); yary(1, 2, &lambda { |a, b| a - b }); end
    def t_take_lambda_yield_few(o); y1(1, &lambda { |a, b| a - b }); end
    def t_take_proc_yield_few(o); y1(1, &Proc.new { |a, b| [a, b] }); end
    def t_take_break(o); take_call(1) { |x| break :b }; end
    def t_take_break_call(o); take_call_forms(1) { |x| next :n }; end
    def t_take_raise(o); take_call(1) { |x| raise 'boom' }; end
    def t_take_gc(o); pr = take { |x| [x, self.class] }; GC.start; pr.call(1); end

    # --- Proc objects built in compiled code ---
    def t_proc_call(o); pr = Proc.new { |x| x + 1 }; [pr.call(1), pr.(2)]; end
    def t_proc_call_with_block(o); pr = Proc.new { |x| x + 1 }; pr.call(1) { :ignored }; end
    def t_proc_eqq(o); big = Proc.new { |x| x > 3 }; [(case 5 when big then :big else :small end), (case 1 when big then :big else :small end)]; end
    def t_proc_new(o); Proc.new { |x| x * 2 }.call(4); end
    def t_proc_arity(o); [Proc.new { |a, b| }.arity, lambda { |a, b| }.arity, Proc.new { }.arity, Proc.new { |a| }.arity]; end
    def t_proc_break(o); pr = Proc.new { break 1 }; pr.call; end
    def t_proc_next(o); pr = Proc.new { next 5; 6 }; pr.call; end
    def t_proc_return(o); pr = Proc.new { return :from_proc }; pr.call; :after; end
    def t_proc_return_orphan(o); orphan_proc.call; end
    def orphan_proc; Proc.new { return :orphan }; end
    def t_lambda_return(o); l = lambda { return 5; 6 }; [l.call, :after]; end
    def t_lambda_break(o); l = lambda { break 5; 6 }; [l.call, :after]; end
    def t_lambda_next(o); l = lambda { next 5; 6 }; [l.call, :after]; end
    def t_lambda_upvar(o); n = 3; l = lambda { |x| x + n }; [l.call(1), l.call(2)]; end
    def t_proc_upvar(o); n = 3; pr = Proc.new { |x| n += x }; [pr.call(1), pr.call(2), n]; end
    def t_proc_self(o); pr = Proc.new { self.class }; pr.call; end
    def t_proc_in_proc(o); pr = Proc.new { |x| Proc.new { |y| x + y } }; pr.call(1).call(2); end
    def mk_counter; n = 0; Proc.new { n += 1 }; end
    def t_escape_upvar(o); c = mk_counter; [c.call, c.call, c.call]; end
    def mk_default_hash; hits = 0; Hash.new { |h, k| hits += 1; h[k] = hits }; end
    def t_escape_hash_default(o); h = mk_default_hash; GC.start; [h[:a], h[:b], h[:a]]; end
    def t_proc_yield_in_proc(o); y1(1) { |a| Proc.new { |b| a + b }.call(10) }; end

    # --- break / next / return ---
    def t_break_val(o); y1(1) { |x| break x + 100 }; end
    def t_break_nil(o); y1(1) { |x| break }; end
    def t_break_multi(o); y1(1) { |x| break 1, 2 }; end
    def t_next_val(o); y1(1) { |x| next x + 100; 0 }; end
    def t_next_nil(o); y1(1) { |x| next; 0 }; end
    def t_next_multi(o); y1(1) { |x| next 1, 2 }; end
    def t_break_nested_inner(o); y1(1) { |x| [y1(2) { |y| break :inner }, :after] }; end
    def t_break_nested_outer(o); y1(1) { |x| y1(2) { |y| 5 }; break :outer }; end
    def t_break_ens(o); log = []; r = page_field(1, log) { |x| break :b }; [r, log]; end
    def t_next_ens(o); log = []; r = page_field(1, log) { |x| next :n }; [r, log]; end
    def t_return_ens(o); log = []; page_field(1, log) { |x| return [:early, log] }; :late; end
    def t_return_deep(o); each(1) { |x| section(x, 2) { |a, b| return [:deep, a, b] } }; :late; end
    def t_return_deep_ens(o); log = []; page_field(1, log) { |x| page_field(2, log) { |y| return [:deep, log] } }; :late; end
    def t_return_plain(o); y1(1) { |x| return x + 1 }; :late; end
    def t_return_disp(o); o.y1(1) { |x| return x + 1 }; :late; end
    def t_return_nil(o); y1(1) { |x| return }; :late; end
    def t_return_multi(o); y1(1) { |x| return 1, 2 }; :late; end
    def t_raise_ens(o); log = []; begin; page_field(1, log) { raise 'x' }; rescue => e; [e.message, log]; end; end
    def t_raise_rescue(o); begin; y1(1) { raise 'x' }; rescue => e; e.message; end; end
    def t_ensure_outer(o); log = []; begin; y1(1) { |x| break }; ensure; log << :out; end; log; end
    def t_break_after_ens(o); log = []; begin; r = y1(1) { |x| break :b }; ensure; log << :out; end; [r, log]; end
    def t_yield_rescue_ok(o); y_rescue(1) { |x| x + 1 }; end
    def t_yield_rescue_raise(o); y_rescue(1) { |x| raise ArgumentError, 'bad' }; end
    def t_yield_rescue_other(o); begin; y_rescue(1) { |x| raise 'other' }; rescue => e; e.message; end; end
    def t_yield_rescue_break(o); y_rescue(1) { |x| break :b }; end
    def t_yield_in_rescue(o); y_in_rescue(3) { |a| a * 2 }; end
    def t_yield_in_rescue_break(o); y_in_rescue(3) { |a| break :b }; end
    def t_yield_in_ensure(o); log = []; r = y_in_ensure(3, log) { |a| log << a; :blockval }; [r, log]; end
    def t_yield_in_ensure_break(o); log = []; r = y_in_ensure(3, log) { |a| break :b }; [r, log]; end
    def t_retry(o); y_retry { |n| raise 'again' if n < 3; [:ok, n] }; end
    def t_retry_give_up(o); y_retry { |n| raise 'again' }; end
    def t_next_in_while(o); i = 0; s = 0; while i < 4; i += 1; s += y1(i) { |x| next 0 if x == 2; x }; end; s; end
    def t_break_in_while(o); i = 0; r = nil; while i < 4; i += 1; r = y1(i) { |x| break :blk }; end; [i, r]; end
    def t_while_break_in_blk(o); i = 0; while i < 4; i += 1; y1(i) { |x| break }; break if i == 2; end; i; end

    # --- block locals, shadowing, upvars ---
    def t_blocklocal(o); y1(5) { |a; t| t = a * 2; t }; end
    def t_blocklocal_outer(o); t = :outer; y1(5) { |a; t| t = a }; t; end
    def t_shadow(o); x = 10; y1(5) { |x| x }; [x]; end
    def t_upvar_multi(o); total = 0; cached_bitmap(1, 2) { |v| total += v; total }; total; end
    def t_upvar_nested(o); a = 1; each(2) { |x| section(x, 3) { |p, q| a += p * q } }; a; end
    def t_upvar_nested3(o); a = []; each(1) { |x| each(2) { |y| each(3) { |z| a << x << y << z } } }; a; end
    def t_upvar_set_get(o); a = 1; b = 2; section(10, 20) { |p, q| a = p; b += q }; [a, b]; end
    def t_upvar_block_local_mix(o); k = 5; each(1) { |x; k2| k2 = x + k; k = k2 }; k; end
    def t_upvar_after_loop(o); n = 0; i = 0; while i < 3; each(i) { |x| n += x }; i += 1; end; n; end
    def t_block_in_block_upvar(o); a = 1; each(1) { |x| each(x + 1) { |y| a += y } ; a += 100 }; a; end
    def t_self_in_block(o); y1(1) { self.class }; end
    def t_ivar_in_block(o); @iv = 4; y1(1) { |x| @iv += x }; @iv; end
    def t_break_passed_down(o); r = pass_through { |x| break :from_a }; [r, :after]; end
    def t_return_passed_down(o); ret_pass { |x| return :from_t }; :after; end
    def t_return_deep_frames(o); rec3(2) { return :from_t }; :after; end
    def t_break_deep_frames(o); r = rec3(2) { break :from_t }; [r, :after]; end
    def t_stored_break(o); take_store { |x| break :stored }; stored_call(1); end
    def t_stored_return(o); take_store { |x| return :stored }; stored_call(1); end
    def t_stored_next(o); take_store { |x| next x + 1; 0 }; stored_call(1); end
    def t_break_in_rescue(o); y1(1) { |x| begin; raise 'z'; rescue => e; break e.message; end }; end
    def t_return_in_rescue(o); y1(1) { |x| begin; raise 'z'; rescue => e; return e.message; end }; :late; end
    def t_next_in_rescue(o); y1(1) { |x| begin; raise 'z'; rescue => e; next e.message; end; :late }; end
    def t_yield_splat(o); [ysplat([1, 2]) { |x, y| [x, y] }, ysplat([[1, 2]]) { |x, y| [x, y] }, ysplat([]) { |x| x }]; end
    def t_yield_through_each(o); y_in_each(4) { |x| x * 3 }; end
    def t_yield_through_each_break(o); y_in_each(4) { |x| break :b }; end
    def t_yield_through_each_none(o); y_in_each(4); end
    def t_yield_through_y1(o); y_in_y1(4) { |x| x * 3 }; end
    def t_gc_in_blocks(o); r = []; each(1) { |x| GC.start; r << [x] << "s#{x}"; GC.start }; r; end
    def t_str_alloc_block(o); r = []; each(1) { |x| r << "s#{x}" << [x] << { x => x } }; r; end
  end

  class BsRunner
    def run(name)
      bc = BsCase.new
      v = bc.__send__(name, bc)
      "#{name}: #{v.inspect}"
    rescue Exception => e
      "#{name}: !#{e.class}: #{e.message}"
    end
  end
RUBY

# Needs the full-core gems (Enumerable, Symbol#to_proc, Kernel#proc, Kernel#method,
# Proc#lambda?): only run with BC2CPP_MRUBY_FULL.
FULL_FIXTURE = <<~'RUBY'
  class BsCase
    def y1(a); yield a; end
    def take_call(a, &b); b.call(a); end
    def take_arity(&b); [b.arity, b.lambda?]; end
    def double(x); x * 2; end
    def each_or_enum(a); return :no_block unless block_given?; a.each { |x| yield x }; end
    def each_twice(a); a.each { |x| yield x }; a.each { |x| yield x + 10 }; end

    def t_sym_call(o); take_call(5, &:to_s); end
    def t_sym_yield(o); y1(5, &:to_s); end
    def t_sym_arity(o); take_arity(&:to_s); end
    def t_method_call(o); take_call(3, &method(:double)); end
    def t_method_yield(o); y1(3, &method(:double)); end
    def t_method_arity(o); take_arity(&method(:double)); end
    def t_proc_forms(o); pr = proc { |x| x + 1 }; [pr.call(1), pr.(2), pr[3], pr.yield(4), pr === 5, pr.lambda?]; end
    def t_lambda_forms(o); l = lambda { |x| x + 1 }; [l.call(1), l.lambda?]; end
    def t_lambda_arity_error(o); l = lambda { |x| x }; l.call(1, 2); end
    def t_lambda_stab_arity_error(o); l = ->(x, y) { x }; l.call(1); end
    def t_proc_break(o); pr = proc { break 1 }; pr.call; end
    def t_proc_eqq(o); big = proc { |x| x > 3 }; [(case 5 when big then :big else :small end), (case 1 when big then :big else :small end)]; end
    def t_array_each_break(o); [1, 2, 3].each { |x| break x * 10 if x == 2 }; end
    def t_array_each_return(o); [1, 2, 3].each { |x| return x * 10 if x == 2 }; :none; end
    def t_array_each_next(o); s = []; [1, 2, 3].each { |x| next if x == 2; s << x }; s; end
    def t_array_map(o); [1, 2, 3].map { |x| x * 2 }; end
    def t_array_map_upvar(o); k = 3; [1, 2, 3].map { |x| x * k }; end
    def t_array_inject(o); [1, 2, 3].inject(0) { |a, x| a + x }; end
    def t_hash_each(o); s = []; { a: 1, b: 2 }.each { |k, v| s << [k, v] }; s; end
    def t_hash_each_pair_arg(o); s = []; { a: 1 }.each { |pair| s << pair }; s; end
    def t_each_with_index(o); s = []; %w[a b].each_with_index { |x, i| s << [x, i] }; s; end
    def t_each_destructure(o); s = []; [[1, [2, 3]]].each { |a, (b, c)| s << [a, b, c] }; s; end
    def t_times_break(o); 5.times { |i| break i if i == 3 }; end
    def t_select_sym(o); [1, 2, 3].select(&:odd?); end
    def t_map_sym(o); [1, 2].map(&:to_s); end
    def t_each_or_enum(o); [each_or_enum([1, 2]) { |x| x }, each_or_enum([1, 2])]; end
    def t_yield_through_each(o); r = []; each_twice([1, 2]) { |x| r << x }; r; end
    def t_yield_through_each_break(o); r = []; each_twice([1, 2]) { |x| r << x; break :b if x == 2 }; r; end
    def t_sort_block(o); [3, 1, 2].sort { |a, b| b <=> a }; end
  end

  class BsRunner
    def run(name)
      bc = BsCase.new
      v = bc.__send__(name, bc)
      "#{name}: #{v.inspect}"
    rescue Exception => e
      "#{name}: !#{e.class}: #{e.message}"
    end
  end
RUBY

# Scenarios the fixture expects to keep interpreted: lambda / Proc.new blocks that
# capture locals (their pointers would outlive the frame), and an ensure clause that
# yields. t_yield_in_ensure hands its block to a callee that only yields, which the by-name
# list does not name: BLOCK_FALLBACK_PROVEN (ADR 0316) compiles it unless BC2CPP_ESCAPE_ANALYSIS=0.
EXPECTED_INTERPRETED = (%w[t_lambda_upvar t_proc_upvar t_proc_in_proc t_proc_yield_in_proc] +
                        (ENV['BC2CPP_ESCAPE_ANALYSIS'] == '0' ? %w[t_yield_in_ensure] : [])).freeze

# Procs built from a BLOCK_FALLBACK block are cfunc-backed, and mruby answers -1
# for the arity of every one (proc.c `TODO cfunc aspec not implemented yet`).
# These must keep differing: when one starts agreeing the ADR's residual list
# is stale.
KNOWN_DIVERGENT = %w[t_take_arity t_take_arity0 t_take_arity1 t_take_lambda_arg t_proc_arity].freeze

runtime = Bc2cppFixtureRuntime
abort 'MRBC is required' unless ENV['MRBC']
only = ENV['BS_ONLY']&.split(',')

RUNNER = <<~CPP
  #include <cstdlib>
  static int scenario(mrb_state* M) {
    mrb_value runner = mrb_obj_new(M, mrb_class_get(M, "BsRunner"), 0, nullptr);
    mrb_value name = mrb_str_new_cstr(M, std::getenv("BS_CASE"));
    mrb_value text = mrb_funcall_argv(M, runner, mrb_intern_lit(M, "run"), 1, &name);
    if (M->exc) { mrb_print_error(M); return 3; }
    std::fwrite(RSTRING_PTR(text), 1, RSTRING_LEN(text), stdout);
    std::fputc('\\n', stdout);
    std::fflush(stdout);
    return 0;
  }
CPP

# Runs every scenario of `source` in its own process and compares the two
# transcripts. `known` are expected to differ.
differential = lambda do |dir, err, source, build, full, known|
  names = source.scan(/^\s+def (t_\w+)\(o\)/).flatten
  run_names = only ? names & only : names
  built, results = runtime.run(dir, err, %w[BsCase], RUNNER, build: build, full: full,
                                                             envs: run_names.map { |n| { 'BS_CASE' => n } })
  check.call('the fixture compiles against real mruby', built)
  next unless built

  FileUtils.cp_r(dir, ENV['BS_KEEP'], remove_destination: true) if ENV['BS_KEEP']
  bad = 0
  run_names.zip(results).each do |name, (output, _ok)|
    sections = runtime.sections(output)
    interpreted = sections['interpreted']&.join("\n")
    compiled = sections['compiled']&.join("\n")
    compiled = 'CRASH' if compiled.nil? || compiled.empty?
    puts "       #{interpreted}" if ENV['BS_DUMP']
    if interpreted.nil? || interpreted.empty?
      puts "  FAIL #{name}: the interpreter run itself failed: #{output.lines.last(3).join}"
      failures << name
      bad += 1
    elsif known.include?(name)
      check.call("#{name} still differs (known, see the ADR's residual list)", interpreted != compiled)
    elsif interpreted != compiled
      puts "  DIFF #{name}\n       interpreted: #{interpreted}\n       compiled:    #{compiled}"
      failures << name
      bad += 1
    end
  end
  check.call("all #{run_names.size - known.count { |n| run_names.include?(n) }} scenarios agree with the interpreter (#{bad} differ)", bad.zero?)
end

body_of = lambda do |code, function|
  code[/^mrb_value #{Regexp.escape(function)}_impl\(mrb_state\* M.*?(?=^(?:static )?mrb_value \w+\(mrb_state\* M|\z)/m].to_s
end
dispatch = /\bmrb_funcall(?:_with_block|_argv|_id)?\(|\bbc2cpp_send\(/

puts '-- generated code'
Dir.mktmpdir('bs', ENV['TMPDIR'] || Dir.tmpdir) do |dir|
  code, err = runtime.generate(FIXTURE, dir)
  names = FIXTURE.scan(/^\s+def (t_\w+)\(o\)/).flatten
  uncompiled = names.select { |n| body_of.call(code, "BsCase_#{n}").empty? || body_of.call(code, "BsCase_#{n}").include?('#error') }
  check.call("only #{EXPECTED_INTERPRETED.join(' ')} stay interpreted (got: #{uncompiled.join(' ')})",
             uncompiled.sort == EXPECTED_INTERPRETED.sort)
  check.call('block_given? in a compiled method reads the frame block, not a dispatch',
             !body_of.call(code, 'BsCase_bg0').match?(dispatch) && body_of.call(code, 'BsCase_bg0').include?('bc2cpp_blk'))
  check.call('a Proc.new block capturing locals keeps its method interpreted (the proc outlives the frame)',
             body_of.call(code, 'BsCase_mk_counter').empty? && body_of.call(code, 'BsCase_mk_default_hash').empty?)
  check.call('a site whose block never breaks has no catch and no frame token',
             !body_of.call(code, 'BsCase_t_next_val').include?('bc2cpp_block_break') &&
               !body_of.call(code, 'BsCase_t_next_val').include?('Bc2cppFrameGuard'))
  breaking = body_of.call(code, 'BsCase_t_break_val')
  check.call('a site whose block breaks catches only its own token',
             breaking.include?('Bc2cppFrameGuard bc2cpp_site_') && breaking.include?('bc2cpp_brk.token != bc2cpp_site_'))
  check.call('a method whose block returns owns a return frame and catches only its token',
             body_of.call(code, 'BsCase_t_return_plain').include?('Bc2cppFrameGuard bc2cpp_ret_guard') &&
               body_of.call(code, 'BsCase_t_return_plain').include?('bc2cpp_ret.token != bc2cpp_ret_guard.frame.token'))

  core = runtime.core
  if core.nil? || !runtime.compiler?
    puts '  SKIP run: no libmruby_core.a with include/ found (set BC2CPP_MRUBY_CORE)'
  else
    puts '-- differential run on the core-only VM'
    differential.call(dir, err, FIXTURE, core, false, KNOWN_DIVERGENT)
  end
end

full = runtime.full
if full.nil? || !runtime.compiler?
  puts '  SKIP full-core run: set BC2CPP_MRUBY_FULL (libmruby.a with the full-core gems) and have g++'
else
  puts '-- differential run on the full-core VM'
  Dir.mktmpdir('bsf', ENV['TMPDIR'] || Dir.tmpdir) do |dir|
    _code, err = runtime.generate(FULL_FIXTURE, dir)
    differential.call(dir, err, FULL_FIXTURE, full, true, [])
  end
end

if failures.empty?
  puts 'bc2cpp block semantics check: PASS'
else
  warn "bc2cpp block semantics check: #{failures.size} failure(s)"
  exit 1
end
