#!/usr/bin/env ruby
# encoding: UTF-8
# frozen_string_literal: true

# BLOCK_ABI stage 1 (docs/bc2cpp-stack-blocks.md, "The C++ block"): a block is a Bc2cppBlock (entry and env in the caller's
# frame, no allocation) wherever the callee only calls it, and now also when a nested block of the callee yields to it
# (`def each; @a.each { |x| yield x }; end`). The RProc wrapper is made by Bc2cppBlock::proc, where the code may keep the block.
#
#   generated code: the forwarding nested block is frame-local and holds the frame block as it is; a storing callee, a stored
#     nested block and a by-name else keep the heap wrapper.
#   behaviour (interpreted and compiled runs print the same): captured locals written by the block, nested blocks, a block
#     through two compiled callees, yield with several values and a splat, block_given?, `next`, GC stress with allocation in
#     the block, a Fiber body with a block step in the forwarding callee, an exception raised in the block and rescued outside.
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir | BC2CPP_FULL_BUILD_DIR=dir] ruby scripts/bc2cpp/block_abi_check.rb

require_relative 'fixture_runtime'

suite = Bc2cppStepCheck.new('bc2cpp block abi check')

SRC = <<~'RUBY'
  class AbFx
    def initialize; @a = [3, 1, 4, 1, 5]; @kept = nil; end
    def each; @a.each { |x| yield x }; self; end
    def each2; @a.each { |x| @a.each { |y| yield x, y } }; end
    def l2(a); b = a.to_a; i = 0; r = nil; while i < b.size; r = yield(b[i]); i += 1; end; b; end
    def l1(a); l2(a) { |x| yield x }; end
    def times3(n); n.times { |k| yield k }; end
    def twice(n); times3(n) { |k| yield k }; times3(n) { |k| yield k + 100 }; end
    def multi; [[1, 2], [3, 4]].each { |pr| yield pr[0], pr[1] }; end
    def splat; [[1, 2, 3], [4, 5, 6]].each { |arr| yield(*arr) }; end
    def maybe(a); return a.size unless block_given?; a.each { |x| yield x }; a.size; end
    def vals(a); r = []; a.each { |x| r << yield(x) }; r; end
    def keep_nested; @kept = proc { |x| yield x }; @kept; end
    def hold(&b); @held = b; end
    def stash; hold { |x| yield x }; end
    def ranged(r); r.each { |x| yield x }; end
    def gen(n); out = []; i = 0; while i < n; out << yield(i); i += 1; end; out; end
    def fgen(n); gen(n) { |x| yield x }; end
    def ffgen(n); fgen(n) { |x| yield x + 1 }; end
    def plain_gen(n); r = []; ffgen(n) { |x| r << x * 3 }; r; end
    def ensure_fwd(a); a.each { |x| yield x }; ensure; @ens = (@ens || 0) + 1; end
    def rescuer(d); yield 1; rescue StandardError => e; "rescued #{e.message} #{d}"; end
    def ensurer(log); yield log; ensure; log << :ens; end
    def first_arg(*args, &b); b.call(args[0]); end

    # `&blk` forwarding (stage 3): the forwarding send passes bc2cpp_env_block of the block register, so the callee still gets a
    # frame-local block; a target that keeps the block gets a heap copy.
    def fw_each(&b); @a.each(&b); self; end
    def fw_map(&b); @a.map(&b); end
    def fw_prog(&b); l2(@a, &b); end
    def fw_two(&b); fw_each(&b); fw_each(&b); end
    def fw_cond(f, &b); f ? @a.each(&b) : :skipped; end
    def fw_nested(&b); [1, 2].each { |_| @a.each(&b) }; end
    def fw_also_yield(&b); yield 0; @a.each(&b); end
    def fw_kw(&b); kwm(1, k: 2, &b); end
    def kwm(n, k: 0); yield n + k; end
    def fw_splat(*a, &b); splatm(*a, &b); end
    def splatm(x, y); yield x + y; end
    def fw_send(&b); send(:fw_each, &b); end
    def fw_keep(&b); hold(&b); end
    def fw_keep_enum(&b); Enumerator.new(&b); end
    def fw_rescue(&b); @a.each(&b); rescue ArgumentError => e; e.message; end
    def fw_ensure(&b); @a.each(&b); ensure; @ens = (@ens || 0) + 1; end
    def fw_ret(&b); b; end
    def fw_nil(&b); @a.each(&b); end

    def use_fw_each; s = 0; fw_each { |x| s += x }; s; end
    def use_fw_map; fw_map { |x| x * 2 }; end
    def use_fw_sym; fw_map(&:to_s); end
    def use_fw_prog; r = []; fw_prog { |x| r << x + 1 }; r; end
    def use_fw_two; n = 0; fw_two { |x| n += x }; n; end
    def use_fw_cond; n = 0; [fw_cond(true) { |x| n += x }, fw_cond(false) { |x| n += 100 }, n]; end
    def use_fw_nested; n = 0; fw_nested { |x| n += x }; n; end
    def use_fw_also; n = []; fw_also_yield { |x| n << x }; n; end
    def use_fw_kw; fw_kw { |v| v * 10 }; end
    def use_fw_splat; fw_splat(3, 4) { |v| v * 10 }; end
    def use_fw_send; n = 0; fw_send { |x| n += x }; n; end
    def use_fw_keep; fw_keep { |x| x.to_s * 2 }; GC.start; @held.call(21); end
    def use_fw_keep_enum; e = fw_keep_enum { |y| y << 1 << 2 }; GC.start; ("s" * 40) * 3; e.to_a; end
    def use_fw_rescue; fw_rescue { |x| raise ArgumentError, "fw #{x}" if x == 4; x }; end
    def use_fw_ensure; @ens = 0; r = (fw_ensure { |x| raise "fe#{x}" if x == 4 } rescue $!.message); [r, @ens]; end
    def mk_hold; n = 0; hold { |x| n += x }; end
    def mk_fw_keep; n = 0; fw_keep { |x| n += x }; end
    def use_fw_keep_cap; mk_fw_keep; GC.start; ("s" * 40) * 3; [@held.call(3), @held.call(4)]; end
    def use_hold_cap; mk_hold; GC.start; ("s" * 40) * 3; [@held.call(3), @held.call(4)]; end
    def use_fw_ens_break; @ens = 0; r = fw_ensure { |x| break [x, :out] if x == 4 }; [r, @ens]; end
    def use_fw_ens_return; @ens = 0; fw_ensure { |x| return [x, @ens] if x == 4 }; [:end, @ens]; end
    def use_fw_ret; b = fw_ret { |x| x + 1 }; GC.start; b.call(4); end
    def use_fw_nil; fw_nil; end
    def use_fw_break; fw_each { |x| break x * 7 if x == 4 }; end
    def use_fw_return; fw_each { |x| return x * 9 if x == 4 }; :none; end
    def use_fw_churn; r = []; fw_each { |x| 30.times { |k| r << "#{x}-#{k}" }; r.shift(25) }; r.size; end
    def use_fw_gc; s = 0; fw_each { |x| GC.start; s += x }; s; end

    def sum_each; s = 0; each { |x| s += x }; s; end
    def mutate; cnt = 0; names = []; each2 { |x, y| cnt += 1; names << x * y if x == y }; [cnt, names]; end
    def through2(a); r = []; l1(a) { |x| r << x * 2 }; r; end
    def through_ary(a); l1(a) { |x| next 0 if x.to_i.odd?; x }; end
    def nexts(a); vals(a) { |x| next :odd if x.to_i.odd?; x.to_i * 10 }; end
    def churn(a); r = []; l1(a) { |x| 30.times { |k| r << "#{x}-#{k}" }; r.shift(25) }; r.size; end
    def nest_deep(a); r = []; l1(a) { |x| l1(a) { |y| r << [x, y] if x == y } }; r; end
    def twice_sum(n); s = 0; twice(n) { |k| s += k }; s; end
    def use_multi; r = []; multi { |a, b| r << a + b }; r; end
    def use_splat; r = []; splat { |a, *b| r << [a, b] }; r; end
    def use_splat2; r = []; splat { |a, b, c| r << a + b + c }; r; end
    def use_maybe(a); [maybe(a), (s = 0; maybe(a) { |x| s += x.to_i }; s)]; end
    def raise_in(a); l1(a) { |x| raise ArgumentError, "at #{x}" if x == 4; x }; rescue ArgumentError => e; e.message; end
    def raise_ens(a); l1(a) { |x| raise "boom #{x}" if x == 5 }; rescue => e; [e.message, @ens]; end
    def use_ens(a); ensure_fwd(a) { |x| x }; ensure_fwd(a) { |x| raise "e#{x}" if x == 4 } rescue $!.message; end
    def kept_run(a); k = keep_nested { |x| x.to_s * 2 }; [k.call(a), k.call(7)]; end
    def stash_run(a); stash { |x| x.to_s * 3 }; GC.start; [@held.call(a), @held.call(4)]; end
    def ranged_run(r); s = []; ranged(r) { |x| s << x }; GC.start; s; end
    def use_rescuer(a); n = 0; r = rescuer(:d) { |x| n += x; raise "boom #{a}" if a == 4; n }; [r, n]; end
    def use_ensurer(a); log = []; ensurer(log) { |l| l << a }; log; end
    def use_ensurer_raise(a); log = []; r = (ensurer(log) { |l| l << a; raise "e#{a}" if a == 4 } rescue $!.message); [r, log]; end
    def use_first_arg(a); n = 0; first_arg(a, 2) { |x| n += x.to_i }; n; end
    # A block that breaks or returns has no direct entry; it is a cfunc proc over the same frame-local env.
    def ret_find(a); a.each { |x| return x if x.to_i > 2 }; :none; end
    def brk_find(a); a.each { |x| break x.to_i * 2 if x.to_i > 2 }; end
    def ret_fwd(a); l1(a) { |x| return x if x.to_i > 2 }; :none; end
    def brk_fwd(a); r = l1(a) { |x| break x.to_i * 10 if x.to_i > 2; x }; [r]; end
    def brk_ens(a); @ens = 0; r = ensure_fwd(a) { |x| break [x, :out] if x.to_i == 4 }; [r, @ens]; end
    def ret_ens(a); @ens = 0; ensure_fwd(a) { |x| return [x, @ens] if x.to_i == 4 }; [:end, @ens]; end
    def ret_nested(a); a.each { |x| a.each { |y| return [x, y] if x == y && x.to_i > 1 } }; nil; end
    def brk_idx(a); a.each_with_index { |x, i| break i if x.to_i == 1 }; end
    def brk_churn(a); r = []; a.each { |x| 30.times { |k| r << "#{x}-#{k}" }; break r.size if x.to_i > 2 }; end
    def brk_raise(a); a.each { |x| break x if x.to_i > 2; raise "r#{x}" if x.to_i == 1 }; rescue => e; e.message; end
    def brk_keep(&b); @bk = b; end
    def brk_kept_run(a); brk_keep { |x| break x }; a.each { |x| x }; :ok; end
    # A nested block that outlives the call holds the frame block (boxed cells): the caller must pass a heap block.
    def kept_enum(&b); Enumerator.new { |y| y << b.call(1) }; end
    def kept_enum_run(a); e = kept_enum { |x| x + a.size }; GC.start; ("s" * 40) * 3; e.next; end
    def kept_hash(&b); Hash.new { |h, k| h[k] = b.call(k) }; end
    def kept_hash_run(a); h = kept_hash { |x| x * a.size }; GC.start; ("s" * 40) * 3; [h[1], h[2]]; end
  end

  # IO.open in miniature: the ensure body runs in a guard destructor while a `return` unwinds past a cfunc block's VM frame.
  class AbSrc
    def each2; yield 5; end
  end
  class AbCl1
    def close2; 1; end
  end
  class AbCl2
    def close2; 2; end
  end
  class AbOpen
    def opener(x); yield x; ensure; x.close2; end
    def read_ret(i, x); opener(x) { |_| AbSrc.new.each2 { |l| return [l, i] if l }; :none }; end
    def read_brk(i, x); opener(x) { |_| AbSrc.new.each2 { |l| break [l, i] if l }; :none }; end
    def run_open(n); r = []; n.times { |i| r << read_ret(i, AbCl1.new) << read_ret(i, AbCl2.new) << read_brk(i, AbCl2.new); GC.start if i % 7 == 0 }; r.size; end
  end

  class AbColl
    include Enumerable
    def initialize(*a); @a = a; end
    def each; @a.each { |x| yield x }; self; end
    def inspect; 'COLL'; end
    def to_s; 'COLL'; end
  end
RUBY

FIBER_SRC = <<~'RUBY'
  class AbFib
    def gen(n); out = []; i = 0; while i < n; out << yield(i); i += 1; end; out; end
    def fgen(n); gen(n) { |x| yield x }; end
    def ffgen(n); fgen(n) { |x| yield x + 1 }; end
    def start_gen(n); @fiber = Fiber.new { gen(n) { |x| back = Fiber.yield x; back.to_i + 1 } }; end
    def start_fgen(n); @fiber = Fiber.new { fgen(n) { |x| back = Fiber.yield x; back.to_i + 1 } }; end
    def start_fiber(n); @fiber = Fiber.new { ffgen(n) { |x| back = Fiber.yield x; back.to_i + 1 } }; end
    def go; @fiber.resume; end
    def go_with(v); @fiber.resume(v); end
    def fiber_alive; @fiber.alive?; end
    def run_fiber(n, k = :start_fiber)
      send(k, n)
      out = [go]
      GC.start
      out << go_with(10) while fiber_alive
      out
    end
  end
RUBY

DRIVER = <<~'RUBY'
  fx = AbFx.new
  show = lambda do |name, &blk|
    out = begin
      blk.call.inspect
    rescue Exception => e
      "#{e.class}: #{e.message}"
    end
    puts "#{name}: #{out}"
  end
  coll = AbColl.new(2, 4, 6)
  show.call('sum_each') { fx.sum_each }
  show.call('mutate') { fx.mutate }
  show.call('twice_sum') { fx.twice_sum(3) }
  show.call('multi') { fx.use_multi }
  show.call('splat') { [fx.use_splat, fx.use_splat2] }
  [[1, 2, 3], [], [5], (1..30).to_a, { a: 1, b: 2 }, 1..4, coll, %w[7 8]].each_with_index do |a, i|
    %i[through2 through_ary nexts churn nest_deep use_maybe raise_in raise_ens use_ens kept_run stash_run
       use_rescuer use_ensurer use_ensurer_raise use_first_arg kept_enum_run kept_hash_run ret_find brk_find ret_fwd brk_fwd brk_ens ret_ens ret_nested brk_idx brk_churn brk_raise
       brk_kept_run].each do |m|
      show.call("#{m}/#{i}") { fx.send(m, a) }
    end
    show.call("ranged/#{i}") { fx.ranged_run(a) }
  end
  %i[use_fw_each use_fw_map use_fw_sym use_fw_prog use_fw_two use_fw_cond use_fw_nested use_fw_also use_fw_kw use_fw_splat
     use_fw_send use_fw_ens_break use_fw_ens_return use_fw_keep use_fw_keep_cap use_hold_cap use_fw_keep_enum use_fw_rescue use_fw_ensure use_fw_ret use_fw_nil use_fw_break use_fw_return
     use_fw_churn use_fw_gc].each { |m| show.call(m.to_s) { fx.send(m) } }
  show.call('open') { AbOpen.new.run_open(40) }
  show.call('coll') { [coll.map { |x| x + 1 }, coll.select(&:even?), coll.first(2), coll.include?(4), coll.each_with_index.to_a] }
  show.call('plain gen') { fx.plain_gen(4) }
  f = Fiber.new do
    out = [fx.sum_each, fx.through2([1, 2]), fx.mutate]
    Fiber.yield out
    [fx.nest_deep([1, 2]), fx.twice_sum(2)]
  end
  show.call('fiber') { [f.resume, f.resume] }
  GC.start
  show.call('gc stress') do
    GC.stress = true if GC.respond_to?(:stress=)
    r = [fx.sum_each, fx.through2([1, 2]), fx.churn([1, 2]), fx.nest_deep([1, 2]), fx.stash_run(7), fx.ranged_run(1..3),
         fx.twice_sum(2), fx.use_multi, fx.kept_run(3), fx.nexts([1, 2, 3]), fx.use_fw_each, fx.use_fw_prog, fx.use_fw_keep,
         fx.use_fw_keep_enum, fx.use_fw_churn]
    GC.stress = false if GC.respond_to?(:stress=)
    r
  end
  puts 'end'
RUBY

def body_of(code, name)
  code[/^mrb_value AbFx_#{name}_impl\(mrb_state\* M.*?(?=^(?:static )?(?:\[\[maybe_unused\]\] )?mrb_value \w+\(mrb_state\* M|\z)/m].to_s
end

code = suite.generate(SRC, %w[AbFx AbColl AbSrc AbCl1 AbCl2 AbOpen])
each = body_of(code, 'each')
suite.check('each: the nested block that yields to the frame block is frame-local and holds that block as it is',
            each.match?(/Bc2cppBlock bc2cpp_blk_stack_\d+\(M, \d+, bc2cpp_blk_env_\d+\)/) &&
              each.match?(/\{ self, bc2cpp_blk, /) && each.match?(/Array_each_impl\(M, r\d+, bc2cpp_blk_stack_\d+\.value\(\)\)/) &&
              !each.include?('bc2cpp_env_block(M, bc2cpp_blk)') && !each.include?('bc2cpp_heap_proc'))
suite.check('each: the by-name else wraps the block only when it runs (Bc2cppBlock::proc)',
            each.match?(/bc2cpp_owner_call\(.*bc2cpp_blk_stack_\d+\.proc\(\)/))
suite.check('l1: a program callee that yields takes the frame-local block, through two levels',
            body_of(code, 'l1').match?(/AbFx_l2_impl\(M, self, r\d+, bc2cpp_blk_stack_\d+\.value\(\)\)/) &&
              body_of(code, 'through2').match?(/AbFx_l1_impl\(M, self, r\d+, bc2cpp_blk_stack_\d+\.value\(\)\)/) &&
              body_of(code, 'ffgen').match?(/AbFx_fgen_impl\(M, self, r\d+, bc2cpp_blk_stack_\d+\.value\(\)\)/))
suite.check('twice: Integer#times arm and the inlined loop both run with the frame block',
            body_of(code, 'times3').match?(/Integer_times_impl\(M, r\d+, bc2cpp_blk_stack_\d+\.value\(\)\)/))
suite.check('keep_nested: a nested block stored in an ivar keeps the heap wrapper',
            !body_of(code, 'keep_nested').include?('Bc2cppBlock bc2cpp_blk_stack_'))
suite.check('kept_run: a callee that stores a block built from the frame block keeps the heap RProc',
            !body_of(code, 'kept_run').include?('Bc2cppBlock bc2cpp_blk_stack_'))
suite.check('a callee that yields inside a rescue, an ensure, or indexes its splat with [0] takes the frame-local block',
            %w[use_rescuer use_ensurer use_first_arg].all? do |name|
              body = body_of(code, name)
              body.match?(/Bc2cppBlock bc2cpp_blk_stack_\d+\(M, \d+, bc2cpp_blk_env_\d+\)/) && !body.include?('bc2cpp_heap_proc')
            end)
suite.check('a block that breaks or returns is a frame-local cfunc proc (a callee that only calls it)',
            %w[ret_find brk_find ret_fwd brk_fwd brk_idx brk_churn ret_nested].all? do |name|
              body_of(code, name).match?(/Bc2cppBlock bc2cpp_blk_stack_\d+\(M, \w+_block_fallback_\d+, \d+, bc2cpp_blk_env_\d+\)/)
            end)
suite.check('a cfunc block handed to a callee that keeps its block stays a heap RProc',
            !body_of(code, 'brk_kept_run').match?(/Bc2cppBlock bc2cpp_blk_stack_\d+\(M, \w+_block_fallback/))
suite.check('a callee whose nested block outlives the call (Enumerator.new, Hash.new) gets a heap block',
            %w[kept_enum_run kept_hash_run].all? { |name| !body_of(code, name).include?('Bc2cppBlock bc2cpp_blk_stack_') })
FRAME_LOCAL_SITE = /Bc2cppBlock bc2cpp_blk_stack_\d+\(M, (?:\w+, )?\d+, bc2cpp_blk_env_\d+\)/
FORWARDERS = %w[fw_each fw_map fw_prog fw_two fw_cond fw_nested fw_also_yield fw_kw fw_splat fw_send fw_keep fw_keep_enum fw_rescue
                fw_ensure fw_nil].freeze
suite.check('a `&blk` forwarding send hands a callee that only calls its block the block as it is (fw_each, fw_prog)',
            body_of(code, 'fw_each').match?(/Array_each_impl\(M, r\d+, bc2cpp_ebarg_blk_\d+\)/) &&
              body_of(code, 'fw_prog').match?(/AbFx_l2_impl\(M, self, r\d+, bc2cpp_ebarg_blk_\d+\)/))
suite.check('every other arm and the by-name else of a forwarding send take a heap copy (bc2cpp_env_block)',
            body_of(code, 'fw_each').match?(/bc2cpp_owner_call\(.*bc2cpp_env_block\(M, bc2cpp_ebarg_blk_\d+\)/) &&
              body_of(code, 'fw_keep').match?(/AbFx_hold_impl\(M, self, bc2cpp_env_block\(M, bc2cpp_ebarg_blk_\d+\)\)/))
suite.check('no forwarding send hands the VM a bare block register (direct, by-name, keyword, splat and send shapes)',
            (calls = FORWARDERS.flat_map do |name|
              body_of(code, name).lines.select { |l| l.match?(/\b(?:bc2cpp_owner_call|mrb_funcall_with_block|bc2cpp_funcall_kw|bc2cpp_owner_call_argv)\(/) }
            end).size >= 8 && calls.all? { |l| l.include?('bc2cpp_env_block(M, ') })
suite.check('a caller of a forwarding callee builds the block in its frame, with no heap RProc',
            %w[use_fw_each use_fw_map use_fw_prog use_fw_two use_fw_cond use_fw_nested use_fw_also use_fw_kw use_fw_splat use_fw_send
               use_fw_keep use_fw_rescue use_fw_break use_fw_return use_fw_churn use_fw_gc].all? do |name|
              body = body_of(code, name)
              body.match?(FRAME_LOCAL_SITE) && !body.include?('bc2cpp_heap_proc')
            end)
suite.check('a callee that returns its block, or a caller of one, keeps the heap RProc',
            body_of(code, 'use_fw_ret').include?('bc2cpp_heap_proc') && !body_of(code, 'use_fw_ret').include?('Bc2cppBlock bc2cpp_blk_stack_'))
suite.check('an ensure guard pops the callinfo frames an unwind left before it runs its body (a dead frame-local block)',
            code[/struct bc2cpp_ensure_guard \{.*?\n    \};/m].to_s.match?(/bc2cpp_ci_pop\(M\)/))
suite.check('every pop of the callinfo frames an unwind left runs with GC paused (the catch sites and the ensure guard)',
            [code[/static void bc2cpp_vm_restore.*?\n    \}/m], code[/static mrb_value bc2cpp_protect\(.*?\n    \}\n/m],
             code[/struct bc2cpp_ensure_guard \{.*?\n    \};/m]].all? { |body| body.to_s.include?('Bc2cppGcPause pause(M)') })
suite.check('the preamble has one Bc2cppBlock and no Bc2cppHeapBlock', code.include?('struct Bc2cppBlock {') && !code.include?('Bc2cppHeapBlock'))

suite.behaviour(DRIVER) do |interpreted, compiled|
  suite.check('a captured local written through the forwarder is seen after the call', interpreted&.include?('sum_each: 14'))
  suite.check('an exception raised in the block unwinds through two forwarders', interpreted&.include?('raise_in/0: "at 4"') || interpreted&.any? { |l| l.start_with?('raise_in/0') })
  suite.check('the run printed the plain-gen and GC-stress lines', compiled&.any? { |l| l.start_with?('plain gen:') } && compiled&.any? { |l| l.start_with?('gc stress:') })
end
suite.finish

# A VM frame with an env (AbVm#each_x, interpreted) sits above the callinfo of a frame-local block's call, and a `return` / `break` /
# raise unwinds past both: popping the VM frame unshares its env, which allocates, and a GC there (MRB_GC_STRESS) must not mark the
# dead block named by the callinfo below it. Built with the malloc'd block layout so a read of the dead block is a use-after-free.
VM_SRC = <<~'RUBY'
  class AbVm
    def each_x; y = 1; [1, 2].each { |v| yield v + y }; end
  end
  class AbOp
    def opener(x); yield x; end
  end
  class AbOp2
    def opener2(x); yield x; ensure; @ens = (@ens || 0) + 1; end
  end
  class AbVmOwn
    def ret; AbOp.new.opener(1) { |i| AbVm.new.each_x { |v| return [i, v] }; :no }; end
    def brk; AbOp.new.opener(1) { |i| AbVm.new.each_x { |v| break [i, v] }; :no }; end  # the break leaves each_x only
    def raise_in; AbOp.new.opener(1) { |i| AbVm.new.each_x { |v| raise "boom #{v}" } }; rescue => e; e.message; end
    def ret_ens; AbOp2.new.opener2(1) { |i| AbOp.new.opener(i) { |j| AbVm.new.each_x { |v| return [i, j, v] } } }; end
  end
RUBY
vm = Bc2cppStepCheck.new('bc2cpp block abi vm unwind check')
vm.generate(VM_SRC, %w[AbVmOwn AbOp AbOp2])
VM_DRIVER = <<~'RUBY'
  o = AbVmOwn.new
  3.times do
    p o.ret
    p o.brk
    p o.raise_in
    p o.ret_ens
  end
  puts 'end'
RUBY
flags = ENV['BC2CPP_CXXFLAGS']
ENV['BC2CPP_CXXFLAGS'] = [flags, '-DBC2CPP_STACK_BLOCK_MALLOC'].compact.join(' ')
vm.behaviour(VM_DRIVER, banner: 'unwinds past a VM frame with an env, malloc block layout') do |interpreted, compiled|
  vm.check('return, break, raise and an ensure guard unwind past it, as interpreted',
           interpreted&.first(4) == ['[1, 2]', ':no', '"boom 2"', '[1, 1, 2]'] && compiled == interpreted)
end
ENV['BC2CPP_CXXFLAGS'] = flags
vm.finish

# The forwarding callees under a C++ Fiber: a block step through two forwarders, and a Fiber body whose blocks never suspend.
fiber = Bc2cppStepCheck.new('bc2cpp block abi fiber check')
fiber.generate(FIBER_SRC, %w[AbFib])
FIBER_DRIVER = <<~'RUBY'
  fx = AbFib.new
  puts "run3: #{fx.run_fiber(3).inspect}"
  puts "run1: #{AbFib.new.run_fiber(1).inspect}"
  puts "gen: #{AbFib.new.run_fiber(2, :start_gen).inspect}"
  puts "fgen: #{AbFib.new.run_fiber(2, :start_fgen).inspect}"
  GC.start
  puts 'end'
RUBY
fiber.behaviour(FIBER_DRIVER) do |interpreted, _|
  fiber.check('the block step resumes through ffgen, fgen and gen', interpreted&.first == 'run3: [1, 2, 3, [11, 11, 11]]')
end
fiber.finish
