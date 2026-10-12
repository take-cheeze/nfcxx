#!/usr/bin/env ruby
# encoding: UTF-8
#
# Checks for the compiled core mrblib (docs/adr/0264): mruby's own Ruby compiled by
# mruby-core-compiled next to the three engine gems.
#
# Static (needs MRBC only):
#   - every core class that core sources define methods on is a BC2CPP_CORE_OWNERS entry,
#     and no entry is stale;
#   - every core-source method the four compiled gems emit is emitted by exactly one gem
#     (no duplicate `_impl`), and only by mruby-core-compiled;
#   - none of them names the Fiber class, builds a lambda or comes from unaudited mruby-enumerator bodies;
#     each one that touches a block has the Fiber guard in its entry (a `Fiber.yield`
#     inside a block cannot cross a compiled frame, ADR 0269), saves its bytecode before it
#     is registered, is a hidden definition and is never called directly;
#   - mruby-rpgxp/rpgvx/wolf/mvjs, which load after mruby-core-compiled in desktop builds
#     and are not part of its world, define none of the compiled (owner, name) pairs;
#   - a hot-only build (its world holds no core Ruby) emits no core method;
#   - core_refused.txt names nothing that no longer exists.
#
# Runtime (needs BC2CPP_MRUBY_CORE, a host mruby core directory with lib/libmruby_core.a):
#   the compiled bodies answer exactly what the interpreter's bytecode answers, on edge
#   cases (0, negative zero, NaN, infinities, nil, bigint and non-numeric operands, empty and
#   endless ranges, wrong argument counts and types), through the registered entry points
#   and through direct calls from compiled callers.
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_CORE=dir] ruby scripts/bc2cpp/core_mrblib_check.rb

require 'fileutils'
require 'open3'
require 'rbconfig'
require 'set'
require 'shellwords'
require 'tmpdir'
require_relative '../../tools/bc2cpp/bc2cpp'
require_relative '../../tools/bc2cpp/compiled_gems'
require_relative '../../tools/bc2cpp/never_called_registrations'
require_relative 'cxx'

ROOT = File.expand_path('../..', __dir__)
BC2CPP = File.join(ROOT, 'tools/bc2cpp/bc2cpp.rb')
MRBC_ENV = ENV['MRBC'] || 'mrbc'

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

ALL_CORE_GEMS = BC2CPP_CORE_MRBLIB_GEMS + BC2CPP_EXTERNAL_MRBLIB_GEMS

# The registry of `files` compiled as one world (what bc2cpp.rb sees), with irep labels.
def world_registry(files)
  ireps, root = Dir.mktmpdir { |dir| compile_ireps(files, 'core_check', dir) }
  registry, = build_registry(ireps, root)
  [registry, ireps]
end

def core_defs(registry, ireps)
  registry.values.flatten.select { |d| d.irep && CoreDefs.core_source?(ireps.fetch(d.irep).file) }
end

puts 'core mrblib: static invariants'
full_world = core_compiled_mrblib_srcs(ROOT, ALL_CORE_GEMS)
registry, ireps = world_registry(full_world)
owners = registry.values.flatten.select { |d| d.irep && CoreDefs.core_source?(ireps.fetch(d.irep).file) }
                 .map(&:owner).to_set
check.call("BC2CPP_CORE_OWNERS lists every class core sources define methods on (missing: #{(owners - BC2CPP_CORE_OWNERS).to_a.sort.join(', ')})",
           (owners - BC2CPP_CORE_OWNERS).empty?)
check.call("BC2CPP_CORE_OWNERS has no stale entry (#{(BC2CPP_CORE_OWNERS - owners.to_a).join(', ')})",
           (BC2CPP_CORE_OWNERS - owners.to_a).empty?)

# One run per compiled gem, exactly as its mrbgem.rake performs it.
runs = BC2CPP_COMPILED_GEMS.keys.map do |gem_name|
  Thread.new do
    out, err = NeverCalledRegistrations.run_bc2cpp_full(gem_name, ROOT, MRBC_ENV)
    [gem_name, out, err]
  end
end.map(&:value)

impl_owner = {}
duplicates = []
core_keys = Set.new
runs.each do |gem_name, out, err|
  out.scan(/^mrb_value (\S+_impl)\(mrb_state\* M/) do |(impl)|
    duplicates << "#{impl} (#{impl_owner[impl]} and #{gem_name})" if impl_owner.key?(impl)
    impl_owner[impl] = gem_name
  end
  section = err[/== core-source compiled entry points \(\d+\) ==\n(.*?)(?=\n==|\z)/m, 1].to_s
  keys = section.lines.map(&:strip).reject(&:empty?)
  if gem_name == 'mruby-core-compiled'
    core_keys.merge(keys)
  else
    check.call("#{gem_name} emits no core-source method (#{keys.first(3).join(', ')})", keys.empty?)
  end
end
check.call("no `_impl` is emitted by two compiled gems (#{duplicates.first(3).join('; ')})", duplicates.empty?)
check.call('mruby-core-compiled compiles a non-empty set of core methods', !core_keys.empty?)
puts "  (#{core_keys.size} core-source methods compiled)"

# Engine definitions that share an owner with core (Array, StringIO) stay with their gem.
rgss = runs.find { |name, _, _| name == 'mruby-rgss-compiled' }
check.call('Array#include? (mruby-rgss) is emitted by mruby-rgss-compiled, not the core gem',
           rgss[1].include?('Array_include$3f_impl(mrb_state* M') && !core_keys.include?('Array#include?'))

# A compiled core body that touches a block sits on the C stack while the block runs, so its entry
# hands the call to the bytecode whenever a Fiber runs (CORE_BLOCK_GUARD, ADR 0269; a body that cannot
# suspend a Fiber stays compiled while its block is proved yield-free, ADR 0283). Nothing that
# names the Fiber class, builds a lambda or comes from unaudited mruby-enumerator bodies is compiled at all.
compiled_defs = core_defs(registry, ireps).select { |d| core_keys.include?("#{d.owner}##{d.name}") }
unsafe = compiled_defs.select do |d|
  irep = ireps.fetch(d.irep)
  CoreDefs.references_fiber?(irep, ireps) || CoreDefs.builds_lambda?(irep, ireps) ||
    (CoreDefs.fiber_gem?(irep.file) && !CoreMethods.enumerator_wrapper?(d, ireps))
end
check.call("no compiled core method names Fiber, builds a lambda or comes from unaudited mruby-enumerator bodies (#{unsafe.map { |d| "#{d.owner}##{d.name}" }.first(3).join(', ')})",
           unsafe.empty?)
core_run = runs.find { |name, _, _| name == 'mruby-core-compiled' }
# A later definition replaces an earlier one (shadowed), so count by name.
block_defs = compiled_defs.select { |d| CoreDefs.touches_block?(ireps.fetch(d.irep), ireps) || CoreMethods.enumerator_wrapper?(d, ireps) }.uniq { |d| "#{d.owner}##{d.name}" }
guard_entries = core_run[1].scan(/^static mrb_value (\S+)\(mrb_state\* M, mrb_value self\) \{\n  if \(mrb_unlikely\(\(?M->c != M->root_c/).flatten
check.call("compiled core methods that touch a block (#{block_defs.size}) all have the guard in their entry (#{guard_entries.size})",
           block_defs.size.positive? && block_defs.size == guard_entries.size)
saved = core_run[1].scan(/if \(bc2cpp_core_save_interpreted\(M, \w+, (?:true|false), "[^"]+", (\d+)\)\)/).flatten
check.call('every guarded entry saves its bytecode before it is registered, under its own index',
           saved.size == guard_entries.size && saved.uniq.size == saved.size)
# The forward declaration, the definition and the entry's own call are the only mentions of an `_impl`.
direct = guard_entries.select { |entry| core_run[1].scan(/(?<![\w$])#{Regexp.escape(entry)}_impl\(/).size > 3 }
check.call("no direct call reaches a guarded _impl (#{direct.first(3).join(', ')})", direct.empty?)
# A guarded method is never a registry definition: one would switch the name-keyed proofs off (ADR 0264
# finding 1) and is never a call target anyway.
check.call('guarded methods are hidden definitions',
           block_defs.all? { |d| core_run[2].include?("  HIDDEN #{d.owner}##{d.name}\n") })
CoreMethods::ENUMERATOR_WRAPPERS.each do |name|
  definition = compiled_defs.find { |d| d.owner == 'Enumerator' && d.name == name }
  check.call("Enumerator##{name} is compiled behind an unconditional root guard", definition &&
             core_run[1].match?(/static mrb_value Enumerator_#{name}_?\w*\(mrb_state\* M, mrb_value self\) \{\n  if \(mrb_unlikely\(M->c != M->root_c\)\) return bc2cpp_core_interpreted/))
end
# `proc.call(x)` from a C frame runs OP_CALL over that frame, which crashes for a compiled block
# (a cfunc proc): a core body yields to a plain Proc instead (CORE_PROC_CALL), and dispatches
# `call` only in the else arm.
sym_names = core_run[1][/bc2cpp_sym_names\[\d+\] = \{\n(.*?)\n\};/m, 1].to_s.lines.map { |l| l.strip.chomp(',') }
call_index = sym_names.index('"call"')
core_lines = core_run[1].lines
call_sends = core_lines.each_index.select do |i|
  call_index && core_lines[i].match?(/bc2cpp_send\(M, [^,]+, #{call_index},|bc2cpp_sym\(M, #{call_index}\)/)
end
unguarded = call_sends.reject { |i| core_lines[[i - 4, 0].max..i].join.include?('} else {') }
check.call("every `call` dispatch of a core body sits in the else arm of the Proc check (#{call_sends.size} sites, #{unguarded.size} unguarded)",
           unguarded.empty?)

# Open-world gems load after the compiled core and are not in its world: they must not redefine a compiled
# method, and (a compiled core name with no native definition is a static call target) must not define the
# same name on any class either.
open_world_defs = Hash.new { |h, k| h[k] = [] }
%w[mruby-rpgxp mruby-rpgvx mruby-wolf mruby-mvjs].each do |gem_name|
  files = Dir[File.join(ROOT, gem_name, 'mrblib/**/*.rb')].sort
  next if files.empty?

  gem_registry, gem_ireps = world_registry(files)
  gem_registry.values.flatten.each do |d|
    next unless d.irep && !CoreDefs.core_source?(gem_ireps.fetch(d.irep).file)

    open_world_defs["#{d.owner}##{d.name}"] << gem_name
    open_world_defs["##{d.name}"] << gem_name
  end
end
# Only a registry definition (no HIDDEN entry: a name natives share) is a static call target.
hidden = runs.find { |name, _, _| name == 'mruby-core-compiled' }[2].scan(/^  HIDDEN (\S+)/).flatten.to_set
clash = core_keys.select do |k|
  open_world_defs.key?(k) || (!hidden.include?(k) && open_world_defs.key?("##{k.split('#', 2).last}"))
end
check.call("no open-world gem defines a compiled core method's name (#{clash.first(3).join(', ')})", clash.empty?)

# A hot-only build's world has no core Ruby, so it compiles none.
hot_world = closed_world_mrblib_srcs(ROOT, core_gems: nil)
check.call('a hot-only world names no core mrblib file', hot_world.none? { |f| CoreDefs.core_source?(f) })

# Refused entries are live.
core_run_err = runs.find { |name, _, _| name == 'mruby-core-compiled' }[2]
stale = core_run_err.scan(/^  STALE (\S+)/).flatten
check.call("core_refused.txt has no stale entry (#{stale.join(', ')})", stale.empty?)

# ---------------------------------------------------------------------------------------
# Runtime: interpreted bytecode vs compiled bodies.
# ---------------------------------------------------------------------------------------
CASES = <<~'RUBY'
  class CoreProbe
    def pos(x); x.positive?; end
    def neg(x); x.negative?; end
    def nz(x); x.nonzero?; end
    def isint(x); x.integer?; end
    def bits(a, m); [a.allbits?(m), a.anybits?(m), a.nobits?(m)]; end
    def cdiv(a, b); a.ceildiv(b); end
    def btw(a, lo, hi); a.between?(lo, hi); end
    def ovl(a, b); a.overlap?(b); end
    def nxt(a); a.next; end
    def signs(a); [a.positive?, a.negative?, a.zero?]; end
    def chained(a); a.positive? && !a.negative?; end
  end

  class Money
    include Comparable
    attr_reader :v
    def initialize(v); @v = v; end
    def <=>(o); o.is_a?(Money) ? @v <=> o.v : nil; end
  end

  class Cell < Numeric
    def initialize(v); @v = v; end
    def <=>(o); @v <=> (o.is_a?(Cell) ? o.v : o); end
    def v; @v; end
    def coerce(o); [Cell.new(o), self]; end
    def ==(o); @v == (o.is_a?(Cell) ? o.v : o); end
    def >(o); @v > (o.is_a?(Cell) ? o.v : o); end
    def <(o); @v < (o.is_a?(Cell) ? o.v : o); end
  end

  BIG = 2**40
  # The largest power of two a 64-bit mrb_int holds; a gem-free core has no bigint to go past it.
  HUGE = 2**62
  P = CoreProbe.new

  NUMS = [0, 1, -1, 7, -7, BIG, -BIG, HUGE, -HUGE, 0.0, -0.0, 0.5, -0.5, 1e300, -1e300,
          Float::INFINITY, -Float::INFINITY, Float::NAN, nil, true, 'x', :s, [], {}, Object.new, Cell.new(3), Cell.new(-3), Cell.new(0)]

  def probe
    out = []
    NUMS.each_with_index do |x, i|
      %i[positive? negative? nonzero? integer? zero? abs next -@ +@].each do |m|
        out << ["#{m} #{i}", -> { x.send(m) }]
      end
      out << ["probe.pos #{i}", -> { P.pos(x) }] if x.is_a?(Numeric)
      out << ["probe.neg #{i}", -> { P.neg(x) }] if x.is_a?(Numeric)
      out << ["probe.nz #{i}", -> { P.nz(x) }] if x.is_a?(Numeric)
      out << ["probe.isint #{i}", -> { P.isint(x) }] if x.is_a?(Numeric)
      out << ["probe.signs #{i}", -> { P.signs(x) }] if x.is_a?(Numeric)
      out << ["probe.chained #{i}", -> { P.chained(x) }] if x.is_a?(Numeric)
    end
    ints = [0, 1, -1, 5, 6, 10, 12, -12, 255, -256, BIG, HUGE, 1.0, nil, 'a']
    ints.each_with_index do |a, i|
      ints.each_with_index do |b, j|
        %i[allbits? anybits? nobits? ceildiv].each do |m|
          out << ["#{m} #{i} #{j}", -> { a.send(m, b) }]
        end
        out << ["probe.bits #{i} #{j}", -> { P.bits(a, b) }] if a.is_a?(Integer)
        out << ["probe.cdiv #{i} #{j}", -> { P.cdiv(a, b) }] if a.is_a?(Integer)
      end
    end
    out << ['allbits? no args', -> { 1.allbits? }]
    out << ['allbits? 2 args', -> { 1.allbits?(1, 2) }]
    out << ['ceildiv zero', -> { 1.ceildiv(0) }]
    out << ['ceildiv min', -> { (-2**31).ceildiv(-1) }]
    out << ['ceildiv overflow', -> { [(-HUGE).ceildiv(-1), (HUGE * 2).ceildiv(3)] }]

    ranks = [1, 5, 10, 1.5, 5.5, 'b', 'a', :a, nil, Money.new(3), Money.new(9), Money.new(5)]
    ranks.each_with_index do |a, i|
      ranks.each_with_index do |lo, j|
        [1, 5, 10, 'z', Money.new(7)].each_with_index do |hi, k|
          out << ["between? #{i} #{j} #{k}", -> { a.between?(lo, hi) }]
          out << ["probe.btw #{i} #{j} #{k}", -> { P.btw(a, lo, hi) }] if a.respond_to?(:between?)
        end
      end
    end
    out << ['between? arity', -> { 1.between?(1) }]
    out << ['Money cmp', -> { [Money.new(1) < Money.new(2), Money.new(2) >= Money.new(2), Money.new(1) == Money.new(1), Money.new(1) == 1] }]
    out << ['Money cmp fail', -> { Money.new(1) < 3 }]
    out << ['Money ge fail', -> { Money.new(1) >= 'x' }]

    ranges = [1..5, 1...5, 5..1, 1..1, 1...1, 4..6, 7..9, 1.., ..5, (1..), 1.0..2.5, 'a'..'e', 'c'..'z', nil..nil, 0...0, -3..3, 2..2, 5...6]
    ranges.each_with_index do |a, i|
      ranges.each_with_index do |b, j|
        out << ["overlap? #{i} #{j}", -> { a.overlap?(b) }]
        out << ["probe.ovl #{i} #{j}", -> { P.ovl(a, b) }]
      end
      out << ["overlap? nonrange #{i}", -> { a.overlap?(3) }]
      out << ["last #{i}", -> { a.last }]
      out << ["last 0 #{i}", -> { a.last(0) }]
      out << ["last 2 #{i}", -> { a.last(2) }]
      out << ["last -1 #{i}", -> { a.last(-1) }]
      out << ["last 1,2 #{i}", -> { a.last(1, 2) }]
      out << ["last x #{i}", -> { a.last('x') }]
      out << ["hash #{i}", -> { [a.hash == a.dup.hash, a.hash == (a.first..a.last).hash] }]
    end

    nest = { a: [1, { b: [10, 20, { c: 3 }] }], 'k' => nil, 2 => 5 }
    out << ['Hash#dig', -> { [nest.dig(:a, 1, :b, 2, :c), nest.dig(:zz), nest.dig('k', :x), nest.dig(:a, 0)] }]
    out << ['Hash#dig bad', -> { nest.dig(2, 1) }]
    out << ['Hash#dig none', -> { nest.dig }]
    out << ['Array#dig', -> { [[1, [2, [3]]].dig(1, 1, 0), [].dig(0), [nil].dig(0, 1), [1].dig(5)] }]
    out << ['Array#dig bad', -> { [1, 2].dig(0, 1) }]
    out << ['Array#dig none', -> { [1].dig }]
    out << ['Array#dig type', -> { [1].dig('x') }]
    out << ['Hash#deconstruct_keys', -> { [nest.deconstruct_keys(nil).equal?(nest), { a: 1 }.deconstruct_keys([:a])] }]
    out << ['Array#deconstruct', -> { a = [1, 2]; a.deconstruct.equal?(a) }]

    hs = [{}, { a: nil }, { a: 1, b: nil, c: 2 }, { nil => nil }, { 1 => [nil], 2 => nil }, Hash.new(7).merge(a: nil, b: 1)]
    hs.each_with_index do |h, i|
      out << ["compact #{i}", -> { r = h.compact; [r, r.equal?(h), r.size] }]
      out << ["compact! #{i}", -> { c = h.dup; [c.compact!, c] }]
      out << ["flatten #{i}", -> { h.flatten }]
      out << ["flatten 2 #{i}", -> { h.flatten(2) }]
      out << ["flatten 0 #{i}", -> { h.flatten(0) }]
      out << ["flatten -1 #{i}", -> { h.flatten(-1) }]
      out << ["flatten x #{i}", -> { h.flatten('x') }]
      out << ["to_h #{i}", -> { r = h.to_h; [r, r.equal?(h)] }]
    end
    out << ['compact default', -> { h = Hash.new(5); h[:a] = nil; h.compact[:zz] }]
    out << ['compact! frozen', -> { { a: nil }.freeze.compact! }]
    out << ['compact frozen', -> { { a: nil }.freeze.compact }]

    out << ['`', -> { `echo` }]
    out << ['!~', -> { ['abc' !~ 'b', 1 !~ 1, nil !~ nil] }]
    out.concat(block_cases)
    out
  end

  # The block-taking core methods, compiled behind the Fiber guard (ADR 0269). This world has no
  # Fiber, so the compiled body is what runs: results, break/next/return/raise and argument
  # errors must match the bytecode. The Fiber side is scripts/bc2cpp/core_blocks_probe.rb.
  class BlockProbe
    def ret_each(a); a.each { |x| return x * 100 if x > 3 }; :none; end
    def ret_map(a); a.map { |x| return x if x > 3; x }; end
    def ret_times; 10.times { |i| return i if i > 2 }; end
    def ret_upto; 1.upto(9) { |i| return i if i > 3 }; end
    def ret_inject(a); a.inject(0) { |s, x| return s if x > 3; s + x }; end
    def ret_hash(h); h.each { |k, v| return k if v > 1 }; end
    def ret_sort_by(a); a.sort_by { |x| return :sb }; end
  end

  class Bag
    include Enumerable
    def initialize(*a); @a = a; end
    def each; @a.each { |x| yield x }; self; end
  end

  class Multi
    include Enumerable
    def each; yield 1, 2; yield 3; yield [4, 5]; yield; end
  end

  BP = BlockProbe.new

  def block_cases
    out = []
    a = [3, 1, 4, 1, 5, 9, 2, 6]
    h = { a: 1, b: 2, c: 3 }
    r = (1..6)
    collections = { 'array' => a, 'hash' => h, 'range' => r, 'bag' => Bag.new(5, 3, 8, 1), 'multi' => Multi.new,
                    'empty' => [], 'str' => %w[b a c] }
    collections.each do |kind, c|
      %i[map collect select reject find_all partition group_by flat_map sort_by min_by max_by minmax_by
         each_with_index each_slice each_cons each_with_object find detect find_index count sum inject
         any? all? none? one? take_while drop_while filter_map tally uniq sort min max minmax first
         each_entry reverse_each to_h zip include? entries].each do |m|
        out << ["#{kind}.#{m} blk", -> { c.send(m) { |x, y| x } }]
        out << ["#{kind}.#{m} splat", -> { c.send(m) { |*x| x.size } }]
        out << ["#{kind}.#{m} none", -> { c.send(m) }]
        out << ["#{kind}.#{m} 1", -> { c.send(m, 1) { |x| x } }]
        out << ["#{kind}.#{m} 2", -> { c.send(m, 2) { |x| x } }]
        out << ["#{kind}.#{m} break", -> { c.send(m) { |*x| break :broke } }]
        out << ["#{kind}.#{m} raise", -> { c.send(m) { |*x| raise 'in block' } }]
      end
    end
    [a, r, h].each_with_index do |c, i|
      out << ["each #{i}", -> { n = []; c.each { |*x| n << x }; n }]
      out << ["each ret #{i}", -> { c.each { |*x| x }.equal?(c) }]
      out << ["each break #{i}", -> { c.each { |*x| break x } }]
      out << ["each next #{i}", -> { n = []; c.each { |*x| next if x.size > 5; n << x }; n }]
      out << ["each args #{i}", -> { c.each(1) {} }]
    end
    out << ['each_index', -> { n = []; a.each_index { |i| n << i }; [n, a.each_index { |i| break i if i == 2 }] }]
    out << ['collect!', -> { b = a.dup; b.collect! { |x| x * 2 }; b }]
    out << ['select!/reject!/keep_if/delete_if', -> { [a.dup.select! { |x| x > 3 }, a.dup.reject! { |x| x > 3 }, a.dup.keep_if { |x| x > 3 }, a.dup.delete_if { |x| x > 3 }, a.dup.select! { true }, a.dup.reject! { false }] }]
    out << ['uniq', -> { b = a.dup; [b.uniq!, b, [1, 2].uniq!, a.uniq { |x| x % 3 }] }]
    out << ['bsearch', -> { [[1, 3, 5, 7].bsearch { |x| x >= 4 }, [1, 3, 5, 7].bsearch_index { |x| x >= 4 }, [1, 3].bsearch { |x| x >= 9 }] }]
    out << ['sort blk', -> { [a.sort { |x, y| y <=> x }, a.sort, [1, 'a'].sort] }]
    out << ['sort_by!', -> { b = a.dup; b.sort_by! { |x| -x }; b }]
    out << ['fetch/fill/transpose/product', -> { [a.fetch(1), a.fetch(99) { |i| i }, [1, 2, 3].fill { |i| i * i }, [[1, 2], [3, 4]].transpose, [1, 2].product([3, 4])] }]
    out << ['fetch err', -> { a.fetch(99) }]
    out << ['permutation/combination', -> { n = []; [1, 2, 3].permutation(2) { |x| n << x }; [1, 2, 3].combination(2) { |x| n << x }; n }]
    out << ['hash', -> { [h.select { |k, v| v > 1 }, h.reject { |k, v| v > 1 }, h.merge({ a: 5 }) { |k, x, y| x + y }, h.transform_values { |v| v * 2 }, h.transform_keys { |k| k.to_s }, h.fetch(:z) { |k| k }, h.invert, h.fetch_values(:a, :b), h.count { |k, v| v > 1 }, h.map { |k, v| [k, v] }] }]
    out << ['hash bang', -> { g = h.dup; [g.select! { |k, v| v > 1 }, g, g.reject! { |k, v| v > 5 }, g.keep_if { true }, g.delete_if { |k, v| v > 2 }, g.merge!({ z: 1 }), g.transform_values! { |v| v * 3 }, g.transform_keys! { |k| k.to_s }] }]
    out << ['hash each_key/each_value', -> { n = []; h.each_key { |k| n << k }; h.each_value { |v| n << v }; n }]
    out << ['range', -> { n = []; r.each { |i| n << i }; ('a'..'d').each { |c| n << c }; (1..3).step(2) { |i| n << i }; n }]
    out << ['range endless', -> { n = []; (1..).each { |i| n << i; break if i > 2 }; n }]
    out << ['range float', -> { (1.0..2.0).each {} }]
    out << ['range min/max', -> { [r.min, r.max, (1..0).min, (1...1).max, r.min { |x, y| y <=> x }, r.to_a, r.first(2), r.sum, r.sum { |x| x * 2 }] }]
    out << ['times/upto/downto/step', -> { n = []; 3.times { |i| n << i }; 1.upto(3) { |i| n << i }; 3.downto(1) { |i| n << i }; 1.step(10, 4) { |i| n << i }; 10.step(1, -4) { |i| n << i }; 1.0.step(2.0, 0.5) { |i| n << i }; n }]
    out << ['times break/neg', -> { [10.times { |i| break i if i == 3 }, -1.times { raise 'no' }, 5.times {}] }]
    out << ['upto bad', -> { 1.upto('a') {} }]
    out << ['step zero', -> { 1.step(10, 0) { break } }]
    out << ['loop', -> { i = 0; [loop { i += 1; break i if i > 3 }, loop { raise StopIteration }] }]
    out << ['str', -> { n = []; 'abc'.each_char { |c| n << c }; "a\nb".each_line { |l| n << l }; 'ab'.each_byte { |b| n << b }; 'a'.upto('c') { |c| n << c }; n }]
    out << ['str sub/gsub', -> { s = +'hello'; [s.gsub('l') { |m| m.upcase }, s.sub('l') { |m| m.upcase }, s.gsub!('l') { 'L' }, s, 'hello'.sub!('z') { 'y' }] }]
    out << ['str chars', -> { ['abc'.chars, 'abc'.bytes, "a\nb".lines, 'ab'.codepoints] }]
    out << ['return through', -> { [BP.ret_each(a), BP.ret_each([1]), BP.ret_map(a), BP.ret_times, BP.ret_upto, BP.ret_inject(a), BP.ret_hash(h), BP.ret_sort_by(a)] }]
    out << ['nested break', -> { a.each { |x| [1, 2].each { |y| break }; break :outer } }]
    out << ['ensure on break', -> { log = []; a.each { |x| begin; break; ensure; log << :e; end }; log }]
    out << ['ensure on raise', -> { log = []; begin; a.each { |x| begin; raise 'r'; ensure; log << :e; end }; rescue => e; log << e.message; end; log }]
    out << ['each mutation', -> { b = [1, 2, 3]; n = []; b.each { |x| n << x; b << 9 if b.size < 5 }; n }]
    out << ['frozen', -> { [[1].freeze.map { |x| x }, ([1].freeze.select! { |x| x } rescue $!.class), ([1].freeze.collect! { |x| x } rescue $!.class), ([1, 1].freeze.uniq! rescue $!.class)] }]
    out << ['proc args', -> { pr = proc { |x, y| [x, y] }; [[[1, 2]].map(&pr), h.map(&pr), a.each_slice(3).to_a.size] }]
    out << ['lambda arity', -> { [[[1, 2]].map(&->(x) { x }), ([[1, 2]].each(&->(x, y) { x }) rescue $!.class)] }]
    out << ['nil block', -> { a.each(&nil).equal?(a) }]
    out << ['alloc loop', -> { n = 0; 3000.times { |i| n += [i, i.to_s].map { |x| x.to_s }.size }; n }]
    out
  end

  def run_cases
    probe.map do |name, blk|
      r = begin
        blk.call.inspect
      rescue Exception => e
        "#{e.class}: #{e.message}"
      end
      "#{name}: #{r}"
    end
  end
RUBY

core = [ENV['BC2CPP_MRUBY_CORE'], *Dir[File.join(ROOT, 'build*/mruby/host/mrbc')]].compact.find do |dir|
  File.exist?(File.join(dir, 'lib/libmruby_core.a')) && File.directory?(File.join(dir, 'include'))
end

puts 'core mrblib: compiled bodies vs interpreter'
if core.nil? || !system('g++', '--version', out: File::NULL, err: File::NULL)
  puts '  SKIP runtime check: set BC2CPP_MRUBY_CORE to a host mruby core directory'
else
  # BC2CPP_CHECK_KEEP_DIR: leave the probe's sources and binary there for debugging.
  runtime_dir = lambda do |&block|
    keep = ENV['BC2CPP_CHECK_KEEP_DIR']
    keep ? block.call(FileUtils.mkdir_p(keep).first) : Dir.mktmpdir(&block)
  end
  runtime_dir.call do |dir|
    # Only the core files a gem-free mruby core can define (no io, dir, stringio, sprintf, struct, ...).
    core_files = core_compiled_mrblib_srcs(ROOT, %w[mruby-array-ext mruby-hash-ext mruby-enum-ext mruby-numeric-ext
                                                     mruby-range-ext mruby-string-ext])
    probe = File.join(dir, 'core_probe.rb')
    File.write(probe, CASES)
    generated = File.join(dir, 'core_probe_gen.cpp')
    only = (BC2CPP_CORE_OWNERS + %w[CoreProbe]).join(',')
    # NATIVE_SRCS is what makes `flatten` POLY here: without it Hash#flatten (Ruby) looks like the
    # name's only definition, and its body's `to_a.flatten` binds back to itself.
    native_srcs = core_native_srcs("#{ROOT}/3rd/mruby") + external_gem_native_srcs(ROOT)
    env = { 'MRBC' => MRBC_ENV, 'OUT_SYMBOL' => 'core_probe', 'OUT_DIR' => dir, 'ONLY_OWNERS' => only,
            'NATIVE_SRCS' => Shellwords.join(native_srcs), 'SKIP_UNSUPPORTED' => '1' }
    _out, err, status = Open3.capture3(env, "#{RbConfig.ruby.shellescape} #{BC2CPP.shellescape} " \
                                            "#{[*core_files, probe].map(&:shellescape).join(' ')} > #{generated.shellescape}")
    abort "bc2cpp.rb failed:\n#{err[-3000..]}" unless status.success?
    compiled = err[/== core-source compiled entry points \((\d+)\)/, 1].to_i
    check.call("the probe world compiles core methods (#{compiled})", compiled.positive?)
    File.write(File.join(dir, 'main.cpp'), <<~CPP)
      #include <mruby.h>
      #include <mruby/array.h>
      #include <mruby/irep.h>
      #include <mruby/string.h>
      #include <cstdio>
      #include <fstream>
      #include <iterator>
      #include <string>
      #include <vector>
      extern "C" void mrb_init_mrblib(mrb_state*) {}
      #include "core_probe_gen.cpp"
      // A registered aspec makes the VM reject a bad argument count before the wrapper runs, and it
      // spells the range "expected 1+" / "expected 1..2", where OP_ENTER's own check of the bytecode
      // said "expected 1" (vm.c argnum_error). The class and the counts agree; only that suffix differs.
      static std::string normalize(const std::string& s) {
        size_t at = s.find("expected ");
        if (s.find("wrong number of arguments") == std::string::npos || at == std::string::npos) return s;
        size_t end = at + 9;
        while (end < s.size() && s[end] >= '0' && s[end] <= '9') ++end;
        size_t stop = end;
        if (stop < s.size() && s[stop] == '+') ++stop;
        else if (s.compare(stop, 2, "..") == 0) { stop += 2; while (stop < s.size() && s[stop] >= '0' && s[stop] <= '9') ++stop; }
        return s.substr(0, end) + s.substr(stop);
      }
      static std::vector<std::string> run(mrb_state* M) {
        mrb_value r = mrb_funcall(M, mrb_top_self(M), "run_cases", 0);
        std::vector<std::string> out;
        if (M->exc) { mrb_print_error(M); M->exc = nullptr; return out; }
        for (mrb_int i = 0; i < RARRAY_LEN(r); ++i) {
          mrb_value s = mrb_ary_ref(M, r, i);
          out.emplace_back(RSTRING_PTR(s), RSTRING_LEN(s));
        }
        return out;
      }
      int main(int, char** argv) {
        mrb_state* M = mrb_open_core();
        std::ifstream in(argv[1], std::ios::binary);
        std::vector<uint8_t> bin((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
        mrb_load_irep_buf(M, bin.data(), bin.size());
        if (M->exc) { mrb_print_error(M); return 2; }
        std::vector<std::string> interpreted = run(M);
        bc2cpp_set_instance_tts(M);
        bc2cpp_register_owner_methods(M);
        std::vector<std::string> compiled = run(M);
        if (interpreted.empty() || interpreted.size() != compiled.size()) {
          std::printf("  FAIL result lists differ in size: %zu vs %zu\\n", interpreted.size(), compiled.size());
          return 1;
        }
        int wrong = 0;
        for (size_t i = 0; i < interpreted.size(); ++i) {
          if (normalize(interpreted[i]) != normalize(compiled[i])) {
            if (++wrong <= 20) std::printf("  WRONG\\n    interpreted: %s\\n    compiled:    %s\\n", interpreted[i].c_str(), compiled[i].c_str());
          }
        }
        std::printf("  %zu cases, %d differ\\n", interpreted.size(), wrong);
        mrb_close(M);
        return wrong ? 1 : 0;
      }
    CPP
    binary = File.join(dir, 'core_probe')
    built = Bc2cppCxx.system('-std=c++17', '-fexceptions', '-DMRB_USE_CXX_EXCEPTION', '-DMRB_NO_GEMS', '-w',
                   "-I#{dir}", "-I#{core}/include", "-I#{ROOT}/3rd/mruby/include", "-I#{ROOT}/include",
                   File.join(dir, 'main.cpp'), "#{core}/lib/libmruby_core.a", '-lm', '-o', binary)
    check.call('the probe compiles against real mruby', built)
    if built
      output = IO.popen([binary, File.join(dir, 'core_probe.mrb')], err: %i[child out], &:read)
      puts output
      puts "  (exit status #{$?.exitstatus || $?.termsig})" unless $?.success?
      check.call('compiled core methods answer exactly what the interpreter answers', $?.success?)
    end
  end
end

if failures.empty?
  puts 'bc2cpp core mrblib check: PASS'
else
  warn "bc2cpp core mrblib check: #{failures.size} failure(s)"
  exit 1
end
