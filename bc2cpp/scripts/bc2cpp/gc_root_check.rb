#!/usr/bin/env ruby
# frozen_string_literal: true

# GC_KEEP_OVERWRITTEN (bc2cpp.rb's prelude): a compiled register is a C local, which the collector does not scan,
# where the interpreter's register is a VM stack slot it does. So a value read out of a slot and still held by a
# register must be rooted when the store replaces it, or the next GC step in the same method frees it:
#   r = @list; @list = []; ...GC...; r         (Interpreter#take_move_route_requests, whose caller iterated it)
# The check generates a fixture whose methods read a value, overwrite or empty its slot, force a full GC and
# allocate (so a freed cell is reused), then use the value (built in the constructor, so no arena entry
# of the method itself keeps them alive); it runs each method interpreted and compiled, one
# process per method, and compares. It then builds the same fixture with BC2CPP_GC_KEEP_OVERWRITTEN=0 and demands
# that every method diverges, so the check cannot pass for a build that roots nothing and each root is needed.
# Needs MRBC and a full-core libmruby (BC2CPP_MRUBY_FULL / BC2CPP_FULL_BUILD_DIR, or rake and a C++ compiler).
ENV['BC2CPP_SIG_DIRS'] = ''

require 'tmpdir'
require_relative 'check_support'
require_relative 'fixture_runtime'
require_relative '../../tools/bc2cpp/keep_summary'

suite = FixtureCheck.new('gc_root_check')
suite.require_mrbc!

# The call-name scan decides which callees may unlink a live element. Match the original NAME rule at identifier
# boundaries, through every ASCII whitespace byte, and next to arbitrary bytes in the binary generated text.
prefixes = ['', '1', '$', 'prefix', '_', '::', '.', '->', "\xff".b, '日本語'.b]
names = ['callee', '_callee', 'callee$part', 'callee2', '1callee', '$callee', 'a' * 512]
spaces = ['', ' ', "\t", "\n", "\r", "\v", "\f", " \t\n", "\0", "\xa0".b]
call_scans = prefixes.product(names, spaces).map { |prefix, name, space| "#{prefix}#{name}#{space}(nested());".b }
call_scans.concat(['(', '()()', 'outer(inner(a), b)', 'x ( y ( z (', 'f/* gap */(', 'f $ ('].map(&:b))
call_scans.each do |body|
  actual = []
  KeepSummary.each_call_name(body) { |name| actual << name }
  raise "call-name scan differs for #{body.inspect}" unless actual == body.scan(KeepSummary::NAME).flatten
end
suite.check("the call-name scanner preserves #{call_scans.size} lexical cases", true)

# LOOP_ARENA: a numeric op's scoped temporary does not refuse the method's loops; any other mrb_value local does.
require_relative '../../tools/bc2cpp/loop_arena'
scoped = "{ mrb_value bc2cpp_nt;\nif (!mrb_undef_p(bc2cpp_nt = bc2cpp_num_add_float(M, r3, r4))) {\n  r3 = bc2cpp_nt;\n}\n}\n"
suite.check("a loop's numeric temporary is scoped to its instruction (LOOP_ARENA)",
            !LoopArena.foreign_locals?(scoped, []) &&
            LoopArena.foreign_locals?("mrb_value bc2cpp_nt;\nr3 = bc2cpp_nt;\n", []) &&
            LoopArena.foreign_locals?("{ mrb_value bc2cpp_tmp;\n}\n", []))

SOURCE = <<~RUBY
  class GcRoot
    KEEP = []
    attr_accessor :cur

    def initialize
      @list = Array.new(4) { |i| "item\#{i}" }
      @table = { a: "va" + "x", b: "vb" + "y" }
      @cells = ["c0" + "x", "c1" + "x", "c2" + "x"]
      @cur = "cur" + "x"
      # IMMEDIATE_OLD: @flag only ever holds immediates; @mode also holds a String, so it keeps its root.
      @flag = :on
      @mode = "busy" + "x"
      # Built here, so the funcall that ran #new has already dropped its arena entries: the slot is the only owner.
      $gcr_slot = ["g0" + "x", "g1" + "x"]
      # A proc block: Array#map hands each element to it directly (no VM stack), and it clears the Array by name.
      @clear_blk = proc { |e| $gcr_slot.send(:clear); churn; e.inspect }
    end

    # A full collection, then enough allocation that a freed cell is handed out again and stays referenced.
    def churn
      GC.start
      n = 0
      while n < 400
        KEEP << [n, n, "s\#{n}"]
        n += 1
      end
      nil
    end

    def take_list
      r = @list
      @list = []
      r
    end

    # The shipped bug: the old value comes back from a callee and is iterated, with a GC inside the loop.
    def ivar_return
      got = take_list
      seen = []
      got.each do |e|
        churn
        seen << e
      end
      [got.size, seen.size, got.inspect]
    end

    def ivar_local
      r = @list
      @list = nil
      churn
      r.inspect
    end

    def gvar_overwrite
      r = $gcr_slot
      $gcr_slot = nil
      churn
      r.inspect
    end

    def ary_overwrite
      a = @cells
      r = a[1]
      a[1] = nil
      churn
      r.inspect
    end

    def hash_overwrite
      h = @table
      r = h[:a]
      h[:a] = 1
      churn
      r.inspect
    end

    def ary_clear
      a = @cells
      r = a[0]
      a.clear
      churn
      r.inspect
    end

    def ary_replace
      a = @cells
      r = a[2]
      a.replace([1])
      churn
      r.inspect
    end

    # By name: `send` dispatches at run time to the core native, which does not root the element it unlinks.
    # The compiled read of the element is what keeps it alive across that call (ELEMENT_READ_ROOTS).
    def ary_clear_by_name
      a = @cells
      r = a[0]
      a.send(:clear)
      churn
      r.inspect
    end

    def ary_store_by_name
      a = @cells
      r = a[1]
      a.send(:[]=, 1, nil)
      churn
      r.inspect
    end

    def hash_clear_by_name
      h = @table
      r = h[:a]
      h.send(:clear)
      churn
      r.inspect
    end

    # An inlined loop over the live Array: each iteration's element is used after a by-name call that clears the Array.
    def each_clear_by_name
      a = @cells
      seen = []
      a.each do |e|
        a.send(:clear)
        churn
        seen << e
      end
      seen.inspect
    end

    # The element is an argument: the callee holds it in a C local, and the caller no longer uses it after the call.
    def take_and_clear(x)
      @cells.send(:clear)
      churn
      x.inspect
    end

    def arg_clear_by_name
      r = @cells[0]
      take_and_clear(r)
    end

    def map_proc_clear
      $gcr_slot = @cells
      mapped = $gcr_slot.map(&@clear_blk)
      mapped.inspect
    end

    def map_clear_by_name
      a = @cells
      mapped = a.map do |e|
        a.send(:clear)
        churn
        e.inspect
      end
      mapped.inspect
    end

    # The same read in bodies compiled outside the method's own pass: a rescue's try body, a block that stays a
    # function, a rescue inside such a block, a block inside a rescue, a nested rescue and an inlined loop body.
    def rescue_clear_by_name
      a = @cells
      r = a[0]
      a.send(:clear)
      churn
      r.inspect
    rescue StandardError => e
      e.message
    end

    def with_block = yield

    def block_clear_by_name
      with_block do
        a = @cells
        r = a[0]
        a.send(:clear)
        churn
        r.inspect
      end
    end

    def block_rescue_clear_by_name
      with_block do
        a = @cells
        r = a[0]
        a.send(:clear)
        churn
        r.inspect
      rescue StandardError => e
        e.message
      end
    end

    def rescue_block_clear_by_name
      with_block do
        a = @cells
        r = a[0]
        a.send(:clear)
        churn
        r.inspect
      end
    rescue StandardError => e
      e.message
    end

    def nested_rescue_clear_by_name
      begin
        a = @cells
        r = a[0]
        a.send(:clear)
        churn
        r.inspect
      rescue ArgumentError => e
        e.message
      end
    rescue StandardError => e
      e.message
    end

    def ensure_clear_by_name
      a = @cells
      r = a[0]
      a.send(:clear)
      churn
      r.inspect
    ensure
      @m1 = :done
    end

    def loop_body_clear_by_name
      out = nil
      [1].each do
        a = @cells
        r = a[0]
        a.send(:clear)
        churn
        out = r.inspect
      end
      out
    end

    # ELEMENT_READ_BODIES: reads the liveness test in those bodies must still root. The value outlives the call that
    # unlinks it through a copy, an outer register the try body aliases, a register the enclosing method keeps, a
    # break value, or the next iteration.
    def rescue_alias_clear_by_name
      r = nil
      begin
        a = @cells
        r = a[0]
        a.send(:clear)
        churn
      rescue StandardError => e
        e.message
      end
      r.inspect
    end

    def block_copy_clear_by_name
      with_block do
        a = @cells
        r = a[0]
        s = r
        a.send(:clear)
        churn
        s.inspect
      end
    end

    def loop_inline_clear_by_name
      out = nil
      [1].each do |i|
        a = @cells
        r = a[0]
        a.send(:clear)
        churn
        out = [i, r.inspect]
      end
      out
    end

    def loop_out_clear_by_name
      out = nil
      [1].each { |i| out = @cells[i - 1] }
      @cells.send(:clear)
      churn
      out.inspect
    end

    def loop_break_clear_by_name
      v = [1].each { |i| break @cells[i - 1] }
      @cells.send(:clear)
      churn
      v.inspect
    end

    def loop_next_iter_clear_by_name
      prev = nil
      [1, 2].each do |i|
        if i == 1
          prev = @cells[0]
        else
          @cells.send(:clear)
          churn
        end
      end
      prev.inspect
    end

    # Reads whose value is dead before any call: the body's liveness test leaves them unrooted.
    def rescue_dead_read
      a = @cells
      x = a[0] ? 1 : 2
      churn
      x
    rescue StandardError => e
      e.message
    end

    def block_dead_read
      with_block do
        a = @cells
        x = a[0] ? 1 : 2
        churn
        x
      end
    end

    def loop_dead_read
      n = 0
      [1].each do |i|
        n += @cells[0] ? i : 2
        churn
      end
      n
    end

    def hash_store_by_name
      h = @table
      r = h[:a]
      h.send(:[]=, :a, 1)
      churn
      r.inspect
    end

    # Only PURE_CALLS run between the read and its use (an ivar read, allocations): nothing can unlink the element.
    def pure_between
      a = @cells
      r = a[2]
      pair = [@cur, :k]
      [r, pair]
    end

    def flip_flag
      @flag = @flag == :on ? true : nil
    end

    # The slot's pool is immediates only: the replaced value needs no root, and the case matches with roots off too.
    def imm_flag_overwrite
      flip_flag
      r = @flag
      @flag = :off
      churn
      r.inspect
    end

    # The store is of an immediate, but the value it replaces is the String the constructor stored.
    def mixed_slot_overwrite
      r = @mode
      @mode = :idle
      churn
      r.inspect
    end

    # KEEP_OLD_BATCH: two stores in a row root both replaced values with one call before the first store.
    def batch_overwrite
      a = @list
      m = @mode
      @list = nil
      @mode = :idle
      churn
      [a, m].inspect
    end

    def attr_overwrite
      r = cur
      self.cur = nil
      churn
      r.inspect
    end

    # ELEMENT_READ_SUMMARY: a compiled callee (a `$`-escaped name) that unlinks the element by name and collects. The
    # caller's only call between the read and the use is that direct call, and its root must stay.
    def zap!
      @cells.send(:clear)
      churn
    end

    def callee_unlinks
      r = @cells[0]
      zap!
      r.inspect
    end

    # The callee between the read and the use runs no Ruby code and unlinks nothing (its stores replace immediates
    # and restore no arena), so the read is not rooted. Long enough not to be inlined (INLINE_CALL_MAX_INSNS).
    def mark_all
      @m1 = :a; @m2 = :b; @m3 = :c; @m4 = :d; @m5 = :e; @m6 = :f; @m7 = :g
      @m8 = :h; @m9 = :i; @m10 = :j; @m11 = :k; @m12 = :l; @m13 = :m
      nil
    end

    def clean_callee_between
      r = @cells[2]
      mark_all
      [r, @m13]
    end

    # CALLEE_ARENA (callee_arena.rb): a direct callee gives back its arena entries on return. These callees overwrite
    # or unlink a value their caller still holds and allocate, so the exit has entries to drop; the store's root is
    # what must survive it. Each has a block or a loop, so it stays a direct call (not inlined).
    def reset_list
      @list = Array.new(3) { |i| "new\#{i}" }
      @tmp = [1, 2, 3]
      nil
    end

    def callee_store_kept
      r = @list
      reset_list
      churn
      r.inspect
    end

    def drop_cell
      n = 0
      while n < 2
        @tmp = [n, n]
        n += 1
      end
      @cells.pop
      nil
    end

    def callee_pop_kept
      r = @cells[2]
      drop_cell
      churn
      r.inspect
    end

    # The result of a callee that made garbage first: the exit roots it again after dropping the rest.
    def fresh_pair
      junk = Array.new(3) { |i| "junk\#{i}" }
      ["pair" + "x", junk.size]
    end

    def callee_result
      r = fresh_pair
      churn
      r.inspect
    end

    def garbage(n)
      a = Array.new(2) { |i| "g\#{i}" }
      [a, n].size
    end

    # The arena across many direct calls that each allocate: flat when each call gives its entries back. The index
    # comes from a C Proc the scenario stores in $gcr_arena.
    def arena_flat
      before = $gcr_arena.call
      i = 0
      while i < 300
        garbage(i)
        i += 1
      end
      $gcr_arena.call - before
    end

    # LOOP_ARENA (loop_arena.rb): the element read is rooted each iteration (the callee may unlink it), so the loop's
    # backward jump is what gives those entries back.
    def touch(e)
      n = 0
      while n < 2
        n += 1
      end
      e.inspect
    end

    def loop_flat
      list = @cells
      before = $gcr_arena.call
      i = 0
      while i < 300
        touch(list[i % 3])
        i += 1
      end
      $gcr_arena.call - before
    end
  end
RUBY

OWNERS = %w[GcRoot].freeze
CASES = %w[ivar_return ivar_local gvar_overwrite ary_overwrite hash_overwrite ary_clear ary_replace
           attr_overwrite ary_clear_by_name ary_store_by_name hash_clear_by_name hash_store_by_name
           each_clear_by_name map_clear_by_name map_proc_clear arg_clear_by_name mixed_slot_overwrite
           batch_overwrite callee_unlinks rescue_clear_by_name block_clear_by_name block_rescue_clear_by_name
           rescue_block_clear_by_name nested_rescue_clear_by_name ensure_clear_by_name loop_body_clear_by_name
           rescue_alias_clear_by_name block_copy_clear_by_name loop_inline_clear_by_name loop_out_clear_by_name loop_break_clear_by_name
           loop_next_iter_clear_by_name callee_store_kept].freeze
# CALLEE_ARENA: a value a callee's store root keeps across that callee's arena exit (BC2CPP_CALLEE_ARENA_KEPT=0
# drops it).
KEPT_CASES = %w[callee_store_kept].freeze
# Cases that need no store root, so they match with the roots switched off too. callee_pop_kept's root is
# GC_KEEP_REMOVED's, which stays on; callee_result's is its callee's arena exit (CALLEE_ARENA).
UNROOTED_CASES = %w[pure_between imm_flag_overwrite clean_callee_between rescue_dead_read block_dead_read
                    loop_dead_read callee_pop_kept callee_result].freeze

SCENARIO = <<~CPP
  static mrb_value gcr_arena_idx(mrb_state* M, mrb_value) { return mrb_fixnum_value(M->gc.arena_idx); }
  static int scenario(mrb_state* M) {
    const char* which = getenv("GCR_CASE");
    mrb_gv_set(M, mrb_intern_lit(M, "$gcr_arena"), mrb_obj_value(mrb_proc_new_cfunc(M, gcr_arena_idx)));
    mrb_value obj = mrb_funcall_argv(M, mrb_obj_value(mrb_class_get(M, "GcRoot")), mrb_intern_lit(M, "new"), 0, nullptr);
    call(M, which, obj, which);
    return 0;
  }
CPP

# [{case => [interpreted line, compiled line]}, built]: every case in its own process.
def run_cases(dir, build, names = CASES + UNROOTED_CASES)
  code, err = Bc2cppFixtureRuntime.generate(SOURCE, dir, core: true, only_owners: OWNERS)
  built, results = Bc2cppFixtureRuntime.run(dir, err, OWNERS, "#include <cstdlib>\n#{SCENARIO}", build: build, full: true,
                                            envs: names.map { |c| { 'GCR_CASE' => c } })
  return [code, nil, false] unless built

  per_case = names.zip(results).to_h do |name, (output, ok)|
    sections = Bc2cppFixtureRuntime.sections(output)
    plain = ->(lines) { lines.to_a.reject { |l| l.start_with?('  dispatches=') } }
    [name, { interpreted: plain.call(sections['interpreted']), compiled: plain.call(sections['compiled']), ok: ok }]
  end
  [code, per_case, true]
end

build = ENV['CC_GENERATED_ONLY'] == '1' ? nil : Bc2cppFixtureRuntime.full_or_build

Dir.mktmpdir('bc2cpp-gc-root') do |dir|
  code, err = Bc2cppFixtureRuntime.generate(SOURCE, dir, core: true, only_owners: OWNERS)
  # EMBED_STORE_OUTLINED: bc2cpp_embed_store keeps the old slot value itself (bc2cpp.rb).
  embedded_store = lambda do |field|
    code.include?("bc2cpp_keep_old(M, ((GcRoot_ivars*)DATA_PTR(self))->#{field});") ||
      code.match?(/bc2cpp_embed_store(?:_unfrozen)?\(M, self, &\(\(GcRoot_ivars\*\)DATA_PTR\(self\)\)->#{field}, /)
  end
  suite.check('an embedded ivar store roots the value it replaces',
              code.include?('bc2cpp_keep_old(M, ((GcRoot_ivars*)') || code.include?('bc2cpp_embed_store'))
  suite.check('the global, element and attr_writer stores root theirs',
              code.include?('bc2cpp_gv_set(M,') && code.include?('bc2cpp_keep_old(M, ARY_PTR(a)[n]);') &&
              embedded_store.call('ivar_cur'))
  suite.check('a Hash store looks the old value up first', code.include?('bc2cpp_hash_aset(M,'))
  suite.check('an element read is rooted where a by-name call may unlink it',
              code.match?(/bc2cpp_ary_entry\(M, r\d+, 0\);.*?bc2cpp_keep\(M, r\d+\);/m))
  pure_body = ->(text) { text[/GcRoot_pure_between_impl\(mrb_state\* M, mrb_value self\) \{.*?\n\}\n/m].to_s }
  suite.check('an element read followed only by PURE_CALLS is not rooted',
              pure_body.call(code).include?('bc2cpp_ary_entry(M,') && !pure_body.call(code).include?('bc2cpp_keep('))
  suite.check('a slot holding only immediates replaces its value unrooted (IMMEDIATE_OLD)',
              !embedded_store.call('ivar_flag') && code.include?('/* IMMEDIATE_OLD */'))
  suite.check('a slot that also holds a String roots the value an immediate store replaces',
              embedded_store.call('ivar_mode'))
  body_of = ->(text, name) { text[/GcRoot_#{name}_impl\(mrb_state\* M, mrb_value self\) \{.*?\n\}\n/m].to_s }
  suite.check('a read held across a direct call that unlinks it keeps its root',
              body_of.call(code, 'callee_unlinks').include?('bc2cpp_keep(M, ') &&
              body_of.call(code, 'callee_unlinks').include?('GcRoot_zap$21_impl(M, '))
  suite.check('a read held only across clean direct calls is not rooted (ELEMENT_READ_SUMMARY)',
              body_of.call(code, 'clean_callee_between').include?('GcRoot_mark_all_impl(M, ') &&
              !body_of.call(code, 'clean_callee_between').include?('bc2cpp_keep(') && !code.include?('KEEP_SUMMARY'))
  try_body = code[/GcRoot_rescue_clear_by_name_impl_rescue_try\(mrb_state\* M, void\* ud\) \{.*?\n\}\n/m].to_s
  suite.check('a try body roots its element read, and the method around it does not',
              try_body.match?(/bc2cpp_ary_entry\(M, r\d+, 0\);.*?bc2cpp_keep\(M, r\d+\);/m) &&
              !body_of.call(code, 'rescue_clear_by_name').include?('bc2cpp_keep('))
  # ELEMENT_READ_BODIES: the read whose value only feeds a branch is not rooted in a try body, a block function or an
  # inlined loop body; BC2CPP_ELEMENT_READ_BODIES=0 roots each again.
  dead_bodies = lambda do |text|
    try = text[/GcRoot_rescue_dead_read_impl_rescue_try\(mrb_state\* M, void\* ud\) \{.*?\n\}\n/m].to_s
    block = text[/^static mrb_value GcRoot_block_dead_read_block_fallback_\d+_impl\(mrb_state\* M, mrb_value self\) \{.*?\n\}\n/m].to_s
    loop = body_of.call(text, 'loop_dead_read')
    [try, block, loop]
  end
  # The `@cells[0]` read's destination is never rooted (a loop's own element root is another register).
  read_rooted = lambda do |body|
    dest = body[/(r\d+) = bc2cpp_ary_entry\(M, r\d+, (?!bc2cpp_each_i)[^;]*\);/, 1]
    dest && body.include?("bc2cpp_keep(M, #{dest});")
  end
  dead = dead_bodies.call(code)
  suite.check('a dead read in a try body, a block function and a loop body is not rooted (ELEMENT_READ_BODIES)',
              dead.all? { |body| body.include?('bc2cpp_ary_entry(M,') && !read_rooted.call(body) })
  Dir.mktmpdir('bc2cpp-gc-root-bodies') do |bodies_dir|
    ENV['BC2CPP_ELEMENT_READ_BODIES'] = '0'
    begin
      unnarrowed, = Bc2cppFixtureRuntime.generate(SOURCE, bodies_dir, core: true, only_owners: OWNERS)
    ensure
      ENV.delete('BC2CPP_ELEMENT_READ_BODIES')
    end
    suite.check('BC2CPP_ELEMENT_READ_BODIES=0 roots them again',
                dead_bodies.call(unnarrowed).all? { |body| read_rooted.call(body) })
  end
  batch_body = ->(text) { text[/GcRoot_batch_overwrite_impl\(mrb_state\* M, mrb_value self\) \{.*?\n\}\n/m].to_s }
  suite.check('a run of slot stores roots the values it replaces in one call (KEEP_OLD_BATCH)',
              batch_body.call(code).include?('bc2cpp_keep_olds2(((GcRoot_ivars*)DATA_PTR(self))->ivar_list, ' \
                                             '((GcRoot_ivars*)DATA_PTR(self))->ivar_mode, M);'))
  Dir.mktmpdir('bc2cpp-gc-root-imm-old') do |imm_dir|
    ENV['BC2CPP_IMMEDIATE_OLD'] = '0'
    ENV['BC2CPP_KEEP_OLD_BATCH'] = '0'
    begin
      imm_off, = Bc2cppFixtureRuntime.generate(SOURCE, imm_dir, core: true, only_owners: OWNERS)
    ensure
      ENV.delete('BC2CPP_IMMEDIATE_OLD')
      ENV.delete('BC2CPP_KEEP_OLD_BATCH')
    end
    suite.check('BC2CPP_KEEP_OLD_BATCH=0 roots each store on its own',
                !batch_body.call(imm_off).include?('bc2cpp_keep_olds') &&
                batch_body.call(imm_off).scan('bc2cpp_keep_old(M, ').size == 2)
    suite.check('BC2CPP_IMMEDIATE_OLD=0 roots it again', !imm_off.include?('/* IMMEDIATE_OLD */') &&
                (imm_off.include?('bc2cpp_keep_old(M, ((GcRoot_ivars*)DATA_PTR(self))->ivar_flag);') ||
                 imm_off.include?('&((GcRoot_ivars*)DATA_PTR(self))->ivar_flag, ')))
  end
  Dir.mktmpdir('bc2cpp-gc-root-summary') do |summary_dir|
    ENV['BC2CPP_ELEMENT_READ_SUMMARY'] = '0'
    begin
      unsummarised, = Bc2cppFixtureRuntime.generate(SOURCE, summary_dir, core: true, only_owners: OWNERS)
    ensure
      ENV.delete('BC2CPP_ELEMENT_READ_SUMMARY')
    end
    suite.check('BC2CPP_ELEMENT_READ_SUMMARY=0 roots it again',
                body_of.call(unsummarised, 'clean_callee_between').include?('bc2cpp_keep('))
  end
  Dir.mktmpdir('bc2cpp-gc-root-impure') do |impure_dir|
    ENV['BC2CPP_ELEMENT_READ_PURE'] = '0'
    begin
      impure, = Bc2cppFixtureRuntime.generate(SOURCE, impure_dir, core: true, only_owners: OWNERS)
    ensure
      ENV.delete('BC2CPP_ELEMENT_READ_PURE')
    end
    suite.check('BC2CPP_ELEMENT_READ_PURE=0 roots that read again', pure_body.call(impure).include?('bc2cpp_keep('))
  end

  if build.nil?
    puts '  SKIP gc root behaviour: needs a full-core libmruby (BC2CPP_MRUBY_FULL, or rake and g++)'
  else
    arena_scenario = <<~CPP
      static int scenario(mrb_state* M) {
        int ai = mrb_gc_arena_save(M);
        mrb_value value = mrb_str_new_lit(M, "retained");
        mrb_gc_arena_restore(M, ai);
        #ifdef MRB_GC_RED
        // Exercise the ROM-object fast path without requiring a ROM fixture.
        unsigned color = mrb_basic_ptr(value)->gc_color;
        mrb_basic_ptr(value)->gc_color = MRB_GC_RED;
        bc2cpp_root(M, value);
        if (M->gc.arena_idx != ai) return 6;
        mrb_basic_ptr(value)->gc_color = color;
        #endif
        bc2cpp_root(M, value);
        if (M->gc.arena_idx != ai + 1) return 1;
        for (int n = 0; n < 1000; ++n) bc2cpp_root(M, value);
        bc2cpp_root(M, mrb_fixnum_value(1));
        if (M->gc.arena_idx != ai + 1) return 2;
        mrb_value other = mrb_str_new_lit(M, "other");
        int before = M->gc.arena_idx;
        bc2cpp_root(M, value);
        if (M->gc.arena_idx != before + 1) return 3;
        bc2cpp_root(M, other);
        mrb_gc_arena_restore(M, ai);
        bc2cpp_root(M, value);
        if (M->gc.arena_idx != ai + 1) return 4;
        mrb_full_gc(M);
        if (RSTRING_LEN(value) != 8 || memcmp(RSTRING_PTR(value), "retained", 8)) return 5;
        #ifndef MRB_GC_FIXED_ARENA
        // Fill the arena through the compiled helper, including its API
        // fallback when the existing buffer runs out of room.
        int count = M->gc.arena_capa + 16;
        mrb_value values = mrb_ary_new_capa(M, count);
        int keep = mrb_gc_arena_save(M);
        for (int n = 0; n < count; ++n) {
          mrb_ary_push(M, values, mrb_str_new_lit(M, "growth"));
          mrb_gc_arena_restore(M, keep);
        }
        for (int n = 0; n < count; ++n)
          bc2cpp_root(M, mrb_ary_entry(values, n));
        mrb_ary_clear(M, values);
        mrb_full_gc(M);
        if (M->gc.arena_idx < keep + count) return 7;
        for (int n = 0; n < count; ++n) {
          mrb_value item = mrb_obj_value(M->gc.arena[keep + n]);
          if (RSTRING_LEN(item) != 6 || memcmp(RSTRING_PTR(item), "growth", 6)) return 8;
        }
        #endif
        return 0;
      }
    CPP
    arena_ok, = Bc2cppFixtureRuntime.run(dir, err, OWNERS, arena_scenario, build: build, full: true, vms: [true])
    suite.check('duplicate arena roots are bounded and a restore requires a fresh root', arena_ok)
    code, rooted, built = run_cases(dir, build, CASES + UNROOTED_CASES + %w[arena_flat loop_flat])
    suite.check('fixture builds and runs', built)
    # The arena growth arena_flat reports, compiled: how many entries 300 direct calls left behind.
    flat_growth = ->(results, name = 'arena_flat') { results&.dig(name, :compiled)&.first.to_s[/=> (\d+)\z/, 1]&.to_i }
    if built
      (CASES + UNROOTED_CASES).each do |name|
        r = rooted.fetch(name)
        suite.check("#{name}: the process survives and compiled matches interpreted",
                    r[:ok] && r[:interpreted].size == 1 && r[:compiled] == r[:interpreted])
      end
      exit_open = 'return bc2cpp_arena_exit(M, bc2cpp_ai, [&]() __attribute__((always_inline)) -> mrb_value {'
      suite.check('a direct callee gives its arena back on return (CALLEE_ARENA)',
                  body_of.call(code, 'callee_store_kept').include?('GcRoot_reset_list_impl(') &&
                  body_of.call(code, 'reset_list').include?(exit_open))
      growth = flat_growth.call(rooted)
      suite.check("300 allocating direct calls leave the arena flat (grew #{growth.inspect})",
                  rooted['arena_flat'][:ok] && growth && growth < 16)
      loop_growth = flat_growth.call(rooted, 'loop_flat')
      suite.check("a loop of 300 rooted element reads leaves the arena flat (LOOP_ARENA, grew #{loop_growth.inspect})",
                  rooted['loop_flat'][:ok] && loop_growth && loop_growth < 16)
    end

    Dir.mktmpdir('bc2cpp-gc-root-kept-off') do |kept_dir|
      ENV['BC2CPP_CALLEE_ARENA_KEPT'] = '0'
      begin
        _, unkept, kept_built = run_cases(kept_dir, build, KEPT_CASES)
      ensure
        ENV.delete('BC2CPP_CALLEE_ARENA_KEPT')
      end
      suite.check('the build whose arena exits keep no store roots compiles', kept_built)
      if kept_built
        lost = KEPT_CASES.reject { |name| unkept[name][:ok] && unkept[name][:compiled] == unkept[name][:interpreted] }
        suite.check('without the kept records each callee store loses the value its caller holds',
                    lost.sort == KEPT_CASES.sort)
      end
    end
    Dir.mktmpdir('bc2cpp-gc-root-callee-arena-off') do |arena_dir|
      ENV['BC2CPP_CALLEE_ARENA'] = '0'
      begin
        _, grown, grown_built = run_cases(arena_dir, build, ['arena_flat'])
      ensure
        ENV.delete('BC2CPP_CALLEE_ARENA')
      end
      growth = grown_built && flat_growth.call(grown)
      suite.check("BC2CPP_CALLEE_ARENA=0 keeps every callee's entries (grew #{growth.inspect})",
                  grown_built && growth && growth >= 300)
    end
    Dir.mktmpdir('bc2cpp-gc-root-loop-arena-off') do |loop_dir|
      ENV['BC2CPP_LOOP_ARENA'] = '0'
      begin
        _, grown, grown_built = run_cases(loop_dir, build, ['loop_flat'])
      ensure
        ENV.delete('BC2CPP_LOOP_ARENA')
      end
      growth = grown_built && flat_growth.call(grown, 'loop_flat')
      suite.check("BC2CPP_LOOP_ARENA=0 keeps each iteration's root (grew #{growth.inspect})",
                  grown_built && growth && growth >= 300)
    end

    Dir.mktmpdir('bc2cpp-gc-root-off') do |off_dir|
      ENV['BC2CPP_GC_KEEP_OVERWRITTEN'] = '0'
      begin
        _, unrooted, off_built = run_cases(off_dir, build)
      ensure
        ENV.delete('BC2CPP_GC_KEEP_OVERWRITTEN')
      end
      suite.check('the switched-off build compiles', off_built)
      if off_built
        UNROOTED_CASES.each do |name|
          r = unrooted.fetch(name)
          suite.check("#{name}: needs no root, so it matches switched off too",
                      r[:ok] && r[:interpreted].size == 1 && r[:compiled] == r[:interpreted])
        end
        diverged = CASES.reject do |name|
          r = unrooted.fetch(name)
          r[:ok] && r[:compiled] == r[:interpreted]
        end
        suite.check('without the roots every case loses its value (each site needs its root)',
                    diverged.sort == CASES.sort)
        puts "  (switched off, these diverge: #{diverged.join(', ')})"
      end
    end
  end
end

suite.finish!
