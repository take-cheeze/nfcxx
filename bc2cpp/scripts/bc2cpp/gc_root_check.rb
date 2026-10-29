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

suite = FixtureCheck.new('gc_root_check')
suite.require_mrbc!

SOURCE = <<~RUBY
  class GcRoot
    KEEP = []
    attr_accessor :cur

    def initialize
      @list = Array.new(4) { |i| "item\#{i}" }
      @table = { a: "va" + "x", b: "vb" + "y" }
      @cells = ["c0" + "x", "c1" + "x", "c2" + "x"]
      @cur = "cur" + "x"
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

    def hash_store_by_name
      h = @table
      r = h[:a]
      h.send(:[]=, :a, 1)
      churn
      r.inspect
    end

    def attr_overwrite
      r = cur
      self.cur = nil
      churn
      r.inspect
    end
  end
RUBY

OWNERS = %w[GcRoot].freeze
CASES = %w[ivar_return ivar_local gvar_overwrite ary_overwrite hash_overwrite ary_clear ary_replace
           attr_overwrite ary_clear_by_name ary_store_by_name hash_clear_by_name hash_store_by_name
           each_clear_by_name map_clear_by_name map_proc_clear arg_clear_by_name].freeze

SCENARIO = <<~CPP
  static int scenario(mrb_state* M) {
    const char* which = getenv("GCR_CASE");
    mrb_value obj = mrb_funcall_argv(M, mrb_obj_value(mrb_class_get(M, "GcRoot")), mrb_intern_lit(M, "new"), 0, nullptr);
    call(M, which, obj, which);
    return 0;
  }
CPP

# [{case => [interpreted line, compiled line]}, built]: every case in its own process.
def run_cases(dir, build)
  code, err = Bc2cppFixtureRuntime.generate(SOURCE, dir, core: true, only_owners: OWNERS)
  built, results = Bc2cppFixtureRuntime.run(dir, err, OWNERS, "#include <cstdlib>\n#{SCENARIO}", build: build, full: true,
                                            envs: CASES.map { |c| { 'GCR_CASE' => c } })
  return [code, nil, false] unless built

  per_case = CASES.zip(results).to_h do |name, (output, ok)|
    sections = Bc2cppFixtureRuntime.sections(output)
    plain = ->(lines) { lines.to_a.reject { |l| l.start_with?('  dispatches=') } }
    [name, { interpreted: plain.call(sections['interpreted']), compiled: plain.call(sections['compiled']), ok: ok }]
  end
  [code, per_case, true]
end

build = ENV['CC_GENERATED_ONLY'] == '1' ? nil : Bc2cppFixtureRuntime.full_or_build

Dir.mktmpdir('bc2cpp-gc-root') do |dir|
  code, = Bc2cppFixtureRuntime.generate(SOURCE, dir, core: true, only_owners: OWNERS)
  suite.check('an embedded ivar store roots the value it replaces', code.include?('bc2cpp_keep_old(M, ((GcRoot_ivars*)'))
  suite.check('the global, element and attr_writer stores root theirs',
              code.include?('bc2cpp_gv_set(M,') && code.include?('bc2cpp_keep_old(M, ARY_PTR(a)[n]);') &&
              code.include?('bc2cpp_keep_old(M, ((GcRoot_ivars*)DATA_PTR(self))->ivar_cur);'))
  suite.check('a Hash store looks the old value up first', code.include?('bc2cpp_hash_aset(M,'))
  suite.check('an element read is rooted where a by-name call may unlink it',
              code.match?(/bc2cpp_ary_entry\(M, r\d+, 0\);.*?bc2cpp_keep\(M, r\d+\);/m))

  if build.nil?
    puts '  SKIP gc root behaviour: needs a full-core libmruby (BC2CPP_MRUBY_FULL, or rake and g++)'
  else
    _, rooted, built = run_cases(dir, build)
    suite.check('fixture builds and runs', built)
    if built
      CASES.each do |name|
        r = rooted.fetch(name)
        suite.check("#{name}: the process survives and compiled matches interpreted",
                    r[:ok] && r[:interpreted].size == 1 && r[:compiled] == r[:interpreted])
      end
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
