#!/usr/bin/env ruby
# encoding: UTF-8
#
# Check CORE_EXACT_DIRECT (docs/adr/0314): a send with no block on a receiver proven an exact Array/Hash
# (ADR 0280) is a direct call of the compiled mruby core body, with no dispatch left; the else arm of
# the inline Array#min/#max (ADR 0261) is such a send.
#
#   1. generated code: the positives, the sites that must keep their by-name send, the kill switch
#      (BC2CPP_CORE_EXTEND=0), and the worlds that withdraw the proof (open world, no core, a Ruby
#      override of the name or of `each`, a prepend, a dynamic installer, a singleton maker, a
#      comparator that yields to a Fiber);
#   2. behaviour: the fixture compiled over the compiled core against the interpreter on a full-core, a
#      core-only and a 32-bit mrb_int mruby, each also under incremental-GC stress; a second world with a
#      comparator that yields, run inside a Fiber; and "late:" lines that redefine the core methods after
#      the compiled code is registered, which a direct call must not see (zero dispatches).
#
# Modes (CX_MODE): all (default), generated (no mruby build), run (behaviour only).
# CX_TOOL_DIR names a copy of tools/bc2cpp (the mutants below); the copy must live inside the repository
# (tools/bc2cpp-mutant-*), or the closed world is empty and a mutant dies for the wrong reason.
#
# Usage: MRBC=path/to/host/mrbc ruby scripts/bc2cpp/core_exact_direct_check.rb

require 'etc'
require 'fileutils'
require 'open3'
require 'rbconfig'
require 'shellwords'
require 'tmpdir'

ROOT = File.expand_path('../..', __dir__)
TOOL_DIR = ENV['CX_TOOL_DIR'] || File.join(ROOT, 'tools/bc2cpp')
require_relative '../../tools/bc2cpp/compiled_gems'
require_relative '../../tools/bc2cpp/nomethod_reviewed'
require_relative '../../tools/bc2cpp/nomethod_reviewed_probe'
require_relative 'mutant_pool'

MRUBY = File.join(ROOT, '3rd/mruby')
MRBC_PATH = ENV['MRBC'] || 'mrbc'
MODE = ENV['CX_MODE'] || 'all'

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

def tool?(name)
  system(name, '--version', out: File::NULL, err: File::NULL)
end

FIXTURE = <<~'RUBY'
  CX_LOG = []

  class CxCmp
    attr_reader :v
    def initialize(v); @v = v; end
    def <=>(o); CX_LOG << [@v, o.v]; @v <=> o.v; end
    def hash; @v.hash; end
    def eql?(o); o.is_a?(CxCmp) && @v == o.v; end
    def to_s; "C#{@v}"; end
  end

  # Two project classes sharing the name `delete` give the Hash#delete sites a user-class poly chain to skip (ADR 0327).
  class CxDeleter
    def delete(k); k; end
  end

  class CxDeleter2
    def delete(k); [k]; end
  end

  class CxBoom
    def <=>(o); raise "boom"; end
  end

  class CxStop
    def <=>(o); raise StopIteration, "stop"; end
  end

  class CxThrow
    def <=>(o); throw :cx_out, :thrown; end
  end

  class CxFx
    NAMES = %w[pear apple fig].freeze
    # -- exact literal Array receivers: the else arm of the inline min/max, and the plain sends
    def mx(a, b); [a, b].max; end
    def mn(a, b); [a, b].min; end
    def mx3(a, b, c); [a, b, c].max; end
    def mn3(a, b, c); [a, b, c].min; end
    def mx_frozen; NAMES.max; end
    def mn_frozen; NAMES.min; end
    def uq(a, b); [a, b, a].uniq; end
    def cnt(a, b); [a, b, a].count; end
    def sm(a, b); [a, b].sum; end
    # -- exact literal Hash receivers
    def fch(k); { 'a' => 1, 'b' => 2 }.fetch(k, :miss); end
    def fch_raise(k); { 'a' => 1 }.fetch(k); end
    def fch3(k); { 'a' => 1 }.fetch(k, 1, 2); end
    def hto(a); { a => 1, :z => 2 }.to_a; end
    def initialize; @cache = { 'a' => 1, 'b' => 2 }; end
    def pooled_delete(k); @cache.delete(k); end
    def pooled_fetch(k); @cache.fetch(k, :miss); end
    def nilable_delete(k); h = k ? @cache : nil; h.delete(k); end
    # -- receivers that are not proven
    def unknown_max(a); a.max; end
    def unknown_min(a); a.min; end
    def unknown_uniq(a); a.uniq; end
    def unknown_to_a(a); a.to_a; end
    # -- the late-override probe: Integer and Float elements leave the inline arm for the else
    def mix_max; [1, 2.5].max; end
    def dup_uniq; [3, 3, 4].uniq; end
    def one_fetch; { 'k' => 7 }.fetch('k', :none); end
  end
RUBY

DRIVER = <<~'RUBY'
  fx = CxFx.new
  class CxArr < Array; end
  user = Object.new
  def user.each; yield 3; yield 9; yield 4; end
  user.extend(Enumerable)
  big = (2**70 rescue 2**30)
  nan = Float::NAN
  norm = lambda do |x|
    case x
    when CxCmp then x.to_s
    when Array then x.map { |e| norm.call(e) }
    when Float then x.nan? ? :nan : x
    when CxBoom, CxStop, CxThrow then x.class.to_s
    else x
    end
  end
  show = lambda do |label, &blk|
    out = begin
      norm.call(blk.call)
    rescue Exception => e
      [e.class, e.message]
    end
    log = CX_LOG.map { |a, b| [a, b] }
    CX_LOG.clear
    puts "#{label}: #{out.inspect}#{log.empty? ? '' : " log=#{log.inspect}"}"
  end
  pairs = [[1, 2], [2, 1], [1, 1], [1, 2.5], [2.5, 1], [2.5, 2.5], [nan, 1.0], [1.0, nan], [-0.0, 0.0],
           ['a', 'b'], ['b', 'a'], [:a, :b], [nil, 1], [1, nil], [1, 'a'], [[1, 2], [1, 3]], [big, 3], [3, big],
           [CxCmp.new(1), CxCmp.new(2)], [CxCmp.new(2), CxCmp.new(1)], [CxBoom.new, CxBoom.new], [CxStop.new, CxStop.new],
           [1073741823, 1073741824 - 1], [-2147483647, 2147483647], [0.1, 0.2]]
  run = lambda do |tag|
    pairs.each_with_index do |(a, b), i|
      %w[mx mn uq cnt sm].each { |m| show.call("#{tag} #{m}/#{i}") { fx.send(m, a, b) } }
      show.call("#{tag} unknown_max/#{i}") { fx.unknown_max([a, b]) }
      show.call("#{tag} unknown_min/#{i}") { fx.unknown_min([a, b]) }
      show.call("#{tag} unknown_uniq/#{i}") { fx.unknown_uniq([a, b, a]) }
    end
    [[1, 2, 3], [3, 2, 1], [1, 2.5, 2], [2, 1.5, 2], ['b', 'a', 'c'], [nil, 1, 2], [1, 3, 2]].each_with_index do |(a, b, c), i|
      show.call("#{tag} mx3/#{i}") { fx.mx3(a, b, c) }
      show.call("#{tag} mn3/#{i}") { fx.mn3(a, b, c) }
    end
    show.call("#{tag} mx_frozen") { fx.mx_frozen }
    show.call("#{tag} mn_frozen") { fx.mn_frozen }
    show.call("#{tag} thrown") { catch(:cx_out) { fx.mx(CxThrow.new, CxThrow.new) } }
    show.call("#{tag} after thrown") { fx.mx(1, 2.5) }
    show.call("#{tag} stop then ok") { [(fx.mx(CxStop.new, CxStop.new) rescue :stopped), fx.mx(4, 2.5)] }
    %w[a b zz].each do |k|
      show.call("#{tag} pooled_fetch/#{k}") { fx.pooled_fetch(k) }
      show.call("#{tag} pooled_delete/#{k}") { fx.pooled_delete(k) }
    end
    show.call("#{tag} nilable_delete") { fx.nilable_delete(nil) }
    %w[a b zz].each { |k| show.call("#{tag} fch/#{k}") { fx.fch(k) } }
    [1, nil, :a, 2.0].each_with_index { |k, i| show.call("#{tag} fch_other/#{i}") { fx.fch(k) } }
    %w[a b].each { |k| show.call("#{tag} fch_raise/#{k}") { fx.fch_raise(k) } }
    show.call("#{tag} fch3") { fx.fch3('a') }
    [:k, 1, nil].each_with_index { |k, i| show.call("#{tag} hto/#{i}") { fx.hto(k) } }
    [[1, 5, 2], [], [2.5, 1], [CxCmp.new(1), CxCmp.new(3)], 1..4, { 1 => 2 }, user, CxArr.new([3, 9, 4]), 5, nil].each_with_index do |r, i|
      show.call("#{tag} unknown_max2/#{i}") { fx.unknown_max(r) }
      show.call("#{tag} unknown_min2/#{i}") { fx.unknown_min(r) }
      show.call("#{tag} unknown_uniq2/#{i}") { fx.unknown_uniq(r) }
      show.call("#{tag} unknown_to_a/#{i}") { fx.unknown_to_a(r) }
    end
    show.call("#{tag} big loop") { s = 0; 300.times { |i| s += fx.mx(i, i + 0.5).to_i + fx.mn(i.to_s, (i + 1).to_s).size }; s }
    show.call("#{tag} gc loop") { 200.times { |i| fx.uq("s#{i}" * 20, "t#{i}" * 20); GC.start if i % 50 == 0 }; :done }
  end
  run.call('plain')
  if Object.const_defined?(:Fiber)
    f = Fiber.new do
      puts "fiber mx: #{fx.mx(1, 2.5).inspect} #{fx.mn(CxCmp.new(2), CxCmp.new(1)).to_s} #{fx.uq(1, 1).inspect}"
      Fiber.yield :mid
      puts "fiber after yield: #{fx.mx('a', 'b').inspect} #{fx.fch('a').inspect}"
      :done
    end
    puts "fiber resume: #{f.resume.inspect} #{f.resume.inspect}"
    en = [3, 1, 2].each
    puts "enumerator next: #{en.next.inspect} #{fx.mx(en.next, 9).inspect} #{en.next.inspect}"
  end
  if GC.respond_to?(:interval_ratio=)
    GC.interval_ratio = 100
    GC.step_ratio = 200
    GC.generational_mode = false
  end
  run.call('stress')
  # A direct call does not look the method up, so a definition made after the compiled code was registered
  # is not reached: the compiled build answers with the core body, the interpreter with the override.
  class Array
    def max(&b); :DISPATCHED; end
    def uniq(&b); :DISPATCHED; end
  end
  class Hash
    def fetch(*a); :DISPATCHED; end
  end
  puts "late max: #{fx.mix_max.inspect}"
  puts "late uniq: #{fx.dup_uniq.inspect}"
  puts "late fetch: #{fx.one_fetch.inspect}"
  puts "end"
RUBY

# The same world plus a comparator that yields to a Fiber: nothing may call the Enumerable body outside
# its entry guard there.
YIELD_FIXTURE = <<~'RUBY'
  class CxYield
    def <=>(o); Fiber.yield :cmp; 0; end
  end

  class CxFx
    def ymax(a, b); [a, b].max; end
    def ymin(a, b); [a, b].min; end
    # The Fiber is in the world, so the analysis sees the method it runs (ADR 0283) and keeps it bytecode.
    def fy; f = Fiber.new { ymax(CxYield.new, CxYield.new) }; [f.resume, f.resume.class]; end
  end
RUBY

YIELD_DRIVER = <<~'RUBY'
  fx = CxFx.new
  puts "yield fiber: #{fx.fy.inspect}"
  puts "yield plain: #{fx.ymin(1, 2.5).inspect} #{fx.ymax(1, 2.5).inspect}"
  puts "end"
RUBY

FIXTURE_OWNERS = %w[CxFx CxCmp CxBoom CxStop CxThrow CxYield CxDeleter CxDeleter2].freeze
OWNERS = BC2CPP_CORE_OWNERS + FIXTURE_OWNERS

# -- generation ------------------------------------------------------------------------------

gems = NomethodReviewedProbe.wio_gems(ROOT)
native_srcs = core_native_srcs(MRUBY) + external_gem_native_srcs(ROOT)
core_srcs = core_compiled_mrblib_srcs(ROOT)

generate = lambda do |source, name, closed: true, core: true, extra_env: {}|
  Dir.mktmpdir do |dir|
    path = File.join(dir, "#{name}.rb")
    File.write(path, source)
    env = { 'MRBC' => MRBC_PATH, 'OUT_SYMBOL' => name, 'OUT_DIR' => dir, 'SKIP_UNSUPPORTED' => '1',
            'NATIVE_SRCS' => Shellwords.join(native_srcs),
            'FOREIGN_RUBY_SRCS' => Shellwords.join(foreign_mrblib_srcs(ROOT)),
            'ONLY_OWNERS' => OWNERS.join(',') }
    if closed
      env.merge!('BC2CPP_CLOSED_WORLD' => '1', 'BC2CPP_BUILD_NAME' => 'wio',
                 'BC2CPP_BUILD_GEMS' => Shellwords.join(gems.map { |n, d| "#{n}=#{d}" }),
                 NomethodReviewed::ALLOW_ENV => 'allow')
    end
    srcs = (core ? core_srcs : []) + [path]
    out, err, status = Open3.capture3(env.merge(extra_env), RbConfig.ruby, File.join(TOOL_DIR, 'bc2cpp.rb'), *srcs)
    abort "bc2cpp.rb failed for #{name}:\n#{err[-3000..] || err}" unless status.success?
    out
  end
end

# The method's own body (file-scope helper functions of it excluded).
FN_RE = '^(?:static )?mrb_value \w+\(mrb_state\* M'
body_of = lambda do |code, fn|
  code[/^mrb_value CxFx_#{fn}_impl\(mrb_state\* M.*?(?=#{FN_RE}|\z)/m].to_s
end
live = ->(text) { text.lines.reject { |l| l.strip.start_with?('//') }.join }
dispatches = ->(text) { live.call(text).scan(/bc2cpp_send\(|mrb_funcall\w*\(|bc2cpp_funcall_argv\(/).size }

run_generated = MODE != 'run' && tool?(MRBC_PATH)
puts '-- SKIP generated code: needs a host mrbc (set MRBC)' if MODE != 'run' && !run_generated

DIRECT_MAX = /CORE_EXACT_DIRECT :max -- proven Array receiver: calls the compiled Enumerable#max body, no dispatch\n\s+r\d+ = Enumerable_max_impl\(M, r\d+, mrb_nil_value\(\)\);/
DIRECT_MIN = /CORE_EXACT_DIRECT :min -- proven Array receiver: calls the compiled Enumerable#min body, no dispatch\n\s+r\d+ = Enumerable_min_impl\(M, r\d+, mrb_nil_value\(\)\);/

if run_generated
  puts 'generated code'
  new_code = generate.call(FIXTURE, 'cx_new')
  off_code = generate.call(FIXTURE, 'cx_off', extra_env: { 'BC2CPP_CORE_EXTEND' => '0' })
  nb = ->(fn) { body_of.call(new_code, fn) }
  ob = ->(fn) { body_of.call(off_code, fn) }

  puts ' 1. exact receivers are direct calls'
  %w[mx mx3 mx_frozen mix_max].each do |fn|
    check.call("#{fn}: the else of the inline max is the compiled Enumerable#max body", nb.call(fn).match?(DIRECT_MAX))
  end
  %w[mn mn3 mn_frozen].each do |fn|
    check.call("#{fn}: the else of the inline min is the compiled Enumerable#min body", nb.call(fn).match?(DIRECT_MIN))
  end
  check.call('mx: nothing is dispatched by name (zero bc2cpp_send / mrb_funcall)', dispatches.call(nb.call('mx')).zero?)
  check.call('mx_frozen: nothing is dispatched by name', dispatches.call(nb.call('mx_frozen')).zero?)
  check.call('uniq on a literal Array is the compiled Array#uniq body, nothing dispatched',
             nb.call('uq').match?(/CORE_EXACT_DIRECT :uniq -- proven Array receiver: calls the compiled Array#uniq body/) &&
             dispatches.call(nb.call('uq')).zero?)
  check.call('count and sum on a literal Array are direct calls of the Enumerable bodies',
             nb.call('cnt').include?('Enumerable_count_impl(M,') && nb.call('sm').include?('Enumerable_sum_impl(M,') &&
             dispatches.call(nb.call('cnt')).zero? && dispatches.call(nb.call('sm')).zero?)
  check.call('fetch on a literal Hash is the compiled Hash#fetch body with its optional argument',
             nb.call('fch').match?(/Hash_fetch_impl\(M, r\d+, r\d+, r\d+, mrb_nil_value\(\), 1\)/) &&
             dispatches.call(nb.call('fch')).zero? && nb.call('fch_raise').include?('Hash_fetch_impl(M,'))
  check.call('a call with an argument count the callee does not take stays a by-name send (it raises ArgumentError there)',
             !nb.call('fch3').include?('CORE_EXACT_DIRECT') && dispatches.call(nb.call('fch3')).positive?)
  check.call('to_a on a literal Hash is Enumerable#entries (a blockless callee that touches a block), nothing dispatched',
             nb.call('hto').include?('Enumerable_entries_impl(M,') && dispatches.call(nb.call('hto')).zero?)
  check.call('a direct site is not left marked as a real dynamic dispatch',
             !nb.call('uq').include?('// POLY :uniq') && !nb.call('uq').include?('POLY_DIAG'))
  # FLOW_CORE_DIRECT (ADR 0323) takes exact core sites before the poly path; the kill switch brings that path back.
  arms_off_uq = body_of.call(generate.call(FIXTURE, 'cx_arms_off', extra_env: { 'BC2CPP_NATIVE_CLASS_ARMS' => '0' }), 'uq')
  check.call('with the class arms off, a direct site reached through the poly path is not marked as a dynamic dispatch',
             arms_off_uq.include?('CORE_EXACT_DIRECT :uniq') && !arms_off_uq.include?('// POLY :uniq') && !arms_off_uq.include?('POLY_DIAG'))

  check.call('pooled Hash delete and fetch call the compiled core without dispatch',
             nb.call('pooled_delete').include?('Hash_delete_impl(M,') &&
             nb.call('pooled_fetch').include?('Hash_fetch_impl(M,') &&
             dispatches.call(nb.call('pooled_delete')).zero? && dispatches.call(nb.call('pooled_fetch')).zero?)
  check.call('a Hash-or-nil receiver keeps its nil error path',
             nb.call('nilable_delete').include?('mrb_nil_p('))

  puts ' 2. receivers that are not proven keep the by-name send'
  check.call('a.max on an unknown receiver keeps the inline arm and its by-name else',
             nb.call('unknown_max').include?('CORE_MIN_MAX :max') && !nb.call('unknown_max').include?('CORE_EXACT_DIRECT') &&
             dispatches.call(nb.call('unknown_max')) == 1)
  check.call('a.min on an unknown receiver keeps its by-name else', !nb.call('unknown_min').include?('CORE_EXACT_DIRECT') && dispatches.call(nb.call('unknown_min')) == 1)
  check.call('a.uniq / a.to_a on an unknown receiver are not direct',
             !nb.call('unknown_uniq').include?('CORE_EXACT_DIRECT') && !nb.call('unknown_to_a').include?('CORE_EXACT_DIRECT') &&
             dispatches.call(nb.call('unknown_uniq')).positive? && dispatches.call(nb.call('unknown_to_a')).positive?)

  puts ' 3. the kill switch'
  check.call('BC2CPP_CORE_EXTEND=0 emits no CORE_EXACT_DIRECT anywhere', !off_code.include?('CORE_EXACT_DIRECT'))
  %w[mx mn mx_frozen mix_max uq cnt sm fch hto pooled_delete pooled_fetch].each do |fn|
    check.call("#{fn}: with the kill switch the site is a by-name send again", dispatches.call(ob.call(fn)).positive?)
  end
  # Symbol indexes number the by-name sends of the whole file, so they shift when a site stops being one.
  mask = ->(text) { text.gsub(/(bc2cpp_send\(M, \w+, )\d+/, '\\1N').gsub(/bc2cpp_sym\(M, \d+\)/, 'bc2cpp_sym(M, N)') }
  check.call('the switch changes no site that is not an exact receiver (indexes masked)',
             %w[unknown_max unknown_min unknown_uniq unknown_to_a].all? { |fn| mask.call(nb.call(fn)) == mask.call(ob.call(fn)) })

  puts ' 4. worlds that withdraw the proof'
  open_code = generate.call(FIXTURE, 'cx_open', closed: false)
  check.call('without the closed world nothing is direct', !open_code.include?('CORE_EXACT_DIRECT'))
  nocore = generate.call(FIXTURE, 'cx_nocore', core: false)
  check.call('without the compiled core nothing is direct', !nocore.include?('CORE_EXACT_DIRECT'))
  no_pools = generate.call(FIXTURE, 'cx_no_pools', extra_env: { 'BC2CPP_CLASS_POOLS' => '0' })
  check.call('without class pools the ivar calls retain dispatch',
             !body_of.call(no_pools, 'pooled_delete').include?('CORE_EXACT_DIRECT') &&
             !body_of.call(no_pools, 'pooled_fetch').include?('CORE_EXACT_DIRECT'))
  override = generate.call("#{FIXTURE}\nclass Array\n  def max(&b); :mine; end\nend\n", 'cx_max_override')
  check.call('a Ruby Array#max is called, not bypassed: mx has no direct max and the Array receiver reaches the definition',
             !body_of.call(override, 'mx').include?('Enumerable_max_impl') && body_of.call(override, 'mx').include?('Array_max_impl'))
  uniq_override = generate.call("#{FIXTURE}\nclass Array\n  def uniq; :mine; end\nend\n", 'cx_uniq_override')
  check.call('a Ruby Array#uniq withdraws the Array#uniq direct call (the name is defined on the chain)',
             !body_of.call(uniq_override, 'uq').include?('CORE_EXACT_DIRECT :uniq') && body_of.call(uniq_override, 'uq').include?('Array_uniq_impl(M,'))
  enum_override = generate.call("#{FIXTURE}\nmodule Enumerable\n  def max(&b); :mine; end\nend\n", 'cx_enum_override')
  check.call('a Ruby Enumerable#max withdraws the direct call', !body_of.call(enum_override, 'mx').include?('CORE_EXACT_DIRECT :max'))
  each_override = generate.call("#{FIXTURE}\nclass Array\n  def each; yield 1; end\nend\n", 'cx_each_override')
  check.call('a Ruby Array#each withdraws the Enumerable bodies (max, count, sum) but is not what Array#uniq runs',
             %w[mx cnt sm].none? { |fn| body_of.call(each_override, fn).include?('CORE_EXACT_DIRECT') })
  prepend = generate.call("#{FIXTURE}\nmodule CxShadow; def max; :shadow; end; end\nclass Array\n  prepend CxShadow\nend\n", 'cx_prepend')
  check.call('a prepend on Array withdraws every direct call on an Array', !prepend.include?('CORE_EXACT_DIRECT :max') && !prepend.include?('CORE_EXACT_DIRECT :uniq'))
  installer = generate.call("#{FIXTURE}\nclass CxFx\n  def install(n); Array.send(:define_method, n) { 1 }; end\nend\n", 'cx_installer')
  check.call('a dynamic installer withdraws every direct call', !installer.include?('CORE_EXACT_DIRECT'))
  singleton = generate.call("#{FIXTURE}\nclass CxFx\n  def mix(o); o.extend(Comparable); end\nend\n", 'cx_singleton')
  check.call('a singleton maker withdraws the exact-receiver proof, so every direct call', !singleton.include?('CORE_EXACT_DIRECT'))
  hash_override = generate.call("#{FIXTURE}\nclass Hash\n  def fetch(*a); :mine; end\nend\n", 'cx_hash_override')
  check.call('a Ruby Hash#fetch withdraws the Hash#fetch direct call', !body_of.call(hash_override, 'fch').include?('CORE_EXACT_DIRECT :fetch') &&
             !body_of.call(hash_override, 'pooled_fetch').include?('CORE_EXACT_DIRECT :fetch'))
  yielding = generate.call("#{FIXTURE}\n#{YIELD_FIXTURE}", 'cx_yield')
  check.call('a comparator that yields to a Fiber makes the Enumerable#max body suspendable: ymin (not run by the Fiber) stays dispatched',
             !body_of.call(yielding, 'ymax').include?('CORE_EXACT_DIRECT') && !body_of.call(yielding, 'ymin').include?('CORE_EXACT_DIRECT') &&
             dispatches.call(body_of.call(yielding, 'ymin')).positive?)
  # The proof is about the names a body can reach, not about the world having a Fiber at all.
  unrelated = generate.call("#{FIXTURE}\nclass CxFx\n  def pause; Fiber.yield :p; end\nend\n", 'cx_unrelated_yield')
  check.call('a Fiber.yield in a method no core body can reach keeps the direct calls',
             body_of.call(unrelated, 'mx').match?(DIRECT_MAX) && body_of.call(unrelated, 'mn').match?(DIRECT_MIN))
end

# -- behaviour -------------------------------------------------------------------------------

ran_behaviour = false
if MODE != 'generated'
  unless tool?(MRBC_PATH) && tool?('rake') && tool?('g++') && File.exist?(File.join(MRUBY, 'Rakefile'))
    puts '-- SKIP behavioural comparison: needs a host mrbc, 3rd/mruby, rake and g++'
  else
    ran_behaviour = true
    GEM_RAKE = <<~'RAKE'
      require 'shellwords'
      ROOT = ENV.fetch('BC2CPP_ROOT')
      require "#{ROOT}/tools/bc2cpp/compiled_gems"
      require "#{ROOT}/tools/bc2cpp/nomethod_reviewed"
      require "#{ROOT}/tools/bc2cpp/nomethod_reviewed_probe"

      MRuby::Gem::Specification.new('bc2cpp-cx-test') do |spec|
        spec.license = 'MIT'
        spec.author = 'rpg-maker-clone'
        spec.summary = 'harness: a closed-world fixture compiled with the compiled core'

        (BC2CPP_CORE_MRBLIB_GEMS + BC2CPP_EXTERNAL_MRBLIB_GEMS).each do |gem_name|
          add_dependency gem_name if spec.build.gems.any? { |g| g.name == gem_name }
        end

        if true
          generated = "#{build_dir}/cx_gen.cpp"
          prerequisites = [*Dir["#{ROOT}/tools/bc2cpp/*.rb"], File.join(ROOT, 'tools/bc2cpp/core_refused.txt'), spec.build.mrbcfile]
          file generated => prerequisites do
            FileUtils.mkdir_p build_dir
            gems = NomethodReviewedProbe.wio_gems(ROOT)
            srcs = core_compiled_mrblib_srcs(ROOT, spec.build.gems.map(&:name)) + [ENV.fetch('BC2CPP_CX_FIXTURE')]
            native = core_native_srcs("#{ROOT}/3rd/mruby") + external_gem_native_srcs(ROOT)
            env = { 'MRBC' => spec.build.mrbcfile.to_s, 'OUT_SYMBOL' => 'cx', 'OUT_DIR' => build_dir,
                    'ONLY_OWNERS' => ENV.fetch('BC2CPP_CX_OWNERS'), 'NATIVE_SRCS' => Shellwords.join(native),
                    'FOREIGN_RUBY_SRCS' => Shellwords.join(foreign_mrblib_srcs(ROOT)), 'SKIP_UNSUPPORTED' => '1',
                    'BC2CPP_CLOSED_WORLD' => '1', 'BC2CPP_BUILD_NAME' => 'wio',
                    'BC2CPP_BUILD_GEMS' => Shellwords.join(gems.map { |n, d| "#{n}=#{d}" }),
                    NomethodReviewed::ALLOW_ENV => 'allow' }
            cmd = "#{RbConfig.ruby.shellescape} #{ROOT}/tools/bc2cpp/bc2cpp.rb #{srcs.map(&:shellescape).join(' ')} " \
                  "> #{generated.shellescape} 2> #{build_dir}/cx.diag"
            sh env, cmd
            # bc2cpp registers only the engine's wired owners and mruby's own: the fixture's classes are registered here,
            # or their methods would stay bytecode and nothing below would run the compiled code.
            owners = ENV.fetch('BC2CPP_CX_FIXTURE_OWNERS').split(',')
            entry_re = /\A  (\S+) \/ \S+  \((\S+)#([^,]+), arity (\d+)\)/
            registrations = File.readlines("#{build_dir}/cx.diag").filter_map do |line|
              m = line.match(entry_re)
              next unless m && owners.include?(m[2])

              define = line.include?('[private') ? 'mrb_define_private_method' : 'mrb_define_method'
              "#{define}(M, mrb_class_ptr(mrb_const_get(M, mrb_obj_value(M->object_class), mrb_intern_lit(M, \"#{m[2]}\"))), " \
                "\"#{m[3]}\", #{m[1]}, MRB_ARGS_REQ(#{m[4]}));"
            end
            File.write("#{build_dir}/cx_register.inc", registrations.join("\n") + "\n")
          end
          file "#{dir}/src/register.cxx" => generated
        end
        cxx.include_paths << build_dir
        cxx.include_paths << "#{ROOT}/include"
      end
    RAKE

    # One build serves both sides: BC2CPP_CX_INTERPRET=1 skips every registration, which leaves mruby's own
    # bytecode and the fixture's bytecode, i.e. the interpreter.
    register_cxx = lambda do |fixture|
      <<~CPP
        #include <stdlib.h>
        #include <mruby.h>
        #include <mruby/class.h>
        #include <mruby/compile.h>
        #include "cx_gen.cpp"

        static const char* const kFixture = R"CXFX(#{fixture})CXFX";

        extern "C" void mrb_bc2cpp_cx_test_gem_init(mrb_state* M) {
          mrb_load_string(M, kFixture);
          if (M->exc) { mrb_print_error(M); M->exc = nullptr; }
          if (getenv("BC2CPP_CX_INTERPRET")) return;
          bc2cpp_set_instance_tts(M);
          bc2cpp_register_owner_methods(M);
        #include "cx_register.inc"
        }

        extern "C" void mrb_bc2cpp_cx_test_gem_final(mrb_state*) {}
      CPP
    end

    # name => [gems, extra defines]. The core-only build is mruby's own mrblib with only mruby-io (for puts) on top: Fiber,
    # Enumerable#sum and the other *-ext methods are absent, so the driver compares what each build raises.
    VARIANTS = {
      'full-core' => ["conf.gembox 'full-core'\n  conf.gem \"\#{ENV.fetch('BC2CPP_ROOT')}/3rd/mruby-stringio\"", ''],
      'core-only' => ["conf.gem core: 'mruby-bin-mruby'\n  conf.gem core: 'mruby-bin-mrbc'\n  conf.gem core: 'mruby-io'", ''],
      'int32' => ["conf.gembox 'full-core'\n  conf.gem \"\#{ENV.fetch('BC2CPP_ROOT')}/3rd/mruby-stringio\"",
                  "[conf.cc, conf.cxx].each { |t| t.defines << 'MRB_32BIT' << 'MRB_INT32' }"]
    }.freeze

    config_for = lambda do |variant|
      gems, defines = VARIANTS.fetch(variant)
      <<~RUBY
        MRuby::Build.new('host') do |conf|
          toolchain :gcc
          #{gems}
          conf.gem ENV['BC2CPP_HARNESS_GEM']
          #{defines}
          conf.cxx.flags << '-std=gnu++17'
          enable_cxx_exception
          enable_debug
          [conf.cc, conf.cxx].each { |t| t.flags = t.flags.flatten.delete_if { |v| v == '-O0' } << '-O1' }
        end
      RUBY
    end

    work = ENV['BC2CPP_CX_DIR'] || Dir.mktmpdir('bc2cpp_core_exact')
    FileUtils.mkdir_p(work)

    # [compiled output, interpreted output, build log, generated C++] of one build of the fixture.
    build_and_run = lambda do |variant, fixture, driver, tag|
      name = "#{tag}_#{variant}"
      File.write(File.join(work, "config_#{variant}.rb"), config_for.call(variant))
      File.write(File.join(work, "fixture_#{tag}.rb"), fixture)
      File.write(File.join(work, "driver_#{tag}.rb"), driver)
      gem_dir = File.join(work, "gem_#{name}")
      FileUtils.mkdir_p(File.join(gem_dir, 'src'))
      File.write(File.join(gem_dir, 'mrbgem.rake'), GEM_RAKE)
      File.write(File.join(gem_dir, 'src/register.cxx'), register_cxx.call(fixture))
      build = File.join(work, name)
      FileUtils.mkdir_p(File.join(build, 'repos/host'))
      FileUtils.ln_sf(File.join(ROOT, '3rd/mgem-list'), File.join(build, 'repos/host/mgem-list'))
      env = { 'BC2CPP_ROOT' => ROOT, 'MRUBY_CONFIG' => File.join(work, "config_#{variant}.rb"), 'MRUBY_BUILD_DIR' => build,
              'BC2CPP_HARNESS_GEM' => gem_dir, 'BC2CPP_CX_OWNERS' => OWNERS.join(','),
              'BC2CPP_CX_FIXTURE_OWNERS' => FIXTURE_OWNERS.join(','), 'BC2CPP_CX_FIXTURE' => File.join(work, "fixture_#{tag}.rb") }
      # ADR 0271 keeps a block's entry as an address in a 32-bit mrb_int slot; this 64-bit host truncates it.
      env['BC2CPP_BLOCK_DIRECT_ENTRY'] = '0' if variant == 'int32'
      out, status = Open3.capture2e(env, 'rake', '-m', "-j#{[Etc.nprocessors, 16].min}", 'all', chdir: MRUBY)
      File.write(File.join(work, "#{name}.log"), out)
      bin = File.join(build, 'host/bin/mruby')
      runs = [{}, { 'BC2CPP_CX_INTERPRET' => '1' }].map do |run_env|
        status.success? && File.exist?(bin) ? Open3.capture2e(run_env, bin, File.join(work, "driver_#{tag}.rb")).first : nil
      end
      gen = File.join(build, 'host/mrbgems/bc2cpp-cx-test/cx_gen.cpp')
      code = File.exist?(gen) ? File.read(gen) : ''
      FileUtils.rm_rf(build) unless ENV['BC2CPP_CX_DIR']
      [runs[0], runs[1], out, code]
    end

    # The lines that must differ between the builds, by design: a definition made after the compiled code was registered.
    late = ->(text) { text.lines.select { |l| l.start_with?('late ') } }

    (ENV['CX_VARIANTS'] || VARIANTS.keys.join(',')).split(',').each do |variant|
      puts "core exact direct (#{variant}): the fixture compiled over the compiled core, and the same build interpreted"
      comp_out, base_out, comp_log, gen_code = build_and_run.call(variant, FIXTURE, DRIVER, 'main')
      check.call("#{variant}: the interpreted run of the build runs the driver", base_out && base_out.lines.last == "end\n")
      check.call("#{variant}: the compiled run of the build runs the driver", comp_out && comp_out.lines.last == "end\n")
      puts comp_log.lines.last(25).join unless comp_out
      next unless base_out && comp_out

      same = ->(text) { text.lines.reject { |l| l.start_with?('late ') }.join }
      check.call("#{variant}: driver output, #{same.call(base_out).lines.size} lines, interpreted and compiled identical",
                 same.call(base_out) == same.call(comp_out))
      unless same.call(base_out) == same.call(comp_out)
        same.call(base_out).lines.zip(same.call(comp_out).lines).reject { |a, b| a == b }.first(10).each do |a, b|
          puts "    interpreted: #{a}    compiled:    #{b}"
        end
      end
      check.call("#{variant}: the harness compiled direct core calls (#{gen_code.scan('CORE_EXACT_DIRECT').size} sites)",
                 gen_code.scan("CORE_EXACT_DIRECT").size >= 6)
      # The core-only build has no mruby-array-ext / mruby-hash-ext, so only the Enumerable#max body exists there.
      bypassed = variant == 'core-only' ? ['late max'] : ['late max', 'late uniq', 'late fetch']
      check.call("#{variant}: the late-defined overrides are seen by the interpreter and bypassed by the compiled direct calls (zero dispatches)",
                 late.call(base_out).size == 3 && late.call(base_out).all? { |l| l.include?(':DISPATCHED') } &&
                 bypassed.all? { |prefix| late.call(comp_out).any? { |l| l.start_with?(prefix) && !l.include?(':DISPATCHED') } })
      next unless variant == 'full-core'

      check.call('full-core: the Fiber and Enumerator#next section ran and agreed',
                 comp_out.include?('fiber resume:') && comp_out.include?('enumerator next:'))
      puts 'core exact direct (full-core): a world whose comparator yields to a Fiber'
      yfx = "#{FIXTURE}\n#{YIELD_FIXTURE}"
      ycomp, ybase, ylog, ygen = build_and_run.call(variant, yfx, YIELD_DRIVER, 'yield')
      check.call('full-core: the yielding world runs interpreted and compiled', ybase && ycomp && ybase.lines.last == "end\n" && ycomp.lines.last == "end\n")
      puts ylog.lines.last(10).join unless ycomp
      check.call("full-core: the yielding world's Fiber steps are identical (#{ybase.to_s.lines.size} lines)", ybase && ycomp && ybase == ycomp)
      check.call('full-core: the yielding world has no direct max/min', !body_of.call(ygen, 'ymax').include?('CORE_EXACT_DIRECT') && !body_of.call(ygen, 'ymin').include?('CORE_EXACT_DIRECT'))
    end
    FileUtils.rm_rf(work) unless ENV['BC2CPP_CX_DIR']
  end
end

# -- mutants ---------------------------------------------------------------------------------
#
# Each mutant is a copy of tools/bc2cpp with one soundness condition of ADR 0314 removed. The copy lives
# next to the original (tools/bc2cpp-mutant-*): bc2cpp.rb finds the repository from its own location, and a
# copy under /tmp has an empty closed world, so every mutant would die for that reason. The generated-code
# half of this script must fail against each, and pass against an unmutated copy (the control).

MUTANTS = {
  'a guarded body is called whether or not it can suspend a Fiber' =>
    ['codegen_core_exact_direct.rb', 'return nil if core_guarded_def?(target) && !core_body_relaxable?(target.irep)', 'nil'],
  'an Enumerable body is called whatever Array#each is' =>
    ['codegen_core_exact_direct.rb', "return nil if target.owner == 'Enumerable' && !core_each_builtin?(klass, chain)", 'nil'],
  'the kill switch is ignored' =>
    ['codegen_core_exact_direct.rb', "ENV['BC2CPP_CORE_EXTEND'] != '0'", 'true'],
  'an unproven receiver is taken for an exact Array' =>
    ['codegen_core_exact_direct.rb', 'site = exact_core_site_for(recv, name)', "site = exact_core_site_for(recv, name) || { klass: 'Array' }"],
  'the else of the inline min/max is called for any receiver' =>
    ['codegen_core_exact_direct.rb', 'site = core_extend_enabled? && !self_implicit && irep &&',
     "site = { klass: 'Array', recv: recv, name: name } if true || core_extend_enabled? && !self_implicit && irep &&"],
  'a callee that takes no block parameter is refused' =>
    ['codegen_block_core_direct.rb', "unless blockless || takes_block_param?(irep)", 'unless takes_block_param?(irep)'],
  'a flow-proven core receiver is not resolved ahead of the poly chain' =>
    ['codegen_send.rb', 'return flow_core if flow_core', 'nil'],
  'a prepend on the receiver class is not looked at' =>
    ['codegen_block_core_direct.rb', 'return false if Array(@prepended_modules[owner]).any? || @unknown_mixins.include?(owner)',
     'return false if @unknown_mixins.include?(owner)'],
  'the target is looked up for the wrong number of arguments' =>
    ['codegen_core_exact_direct.rb',
     'target = core_exact_target(site[:klass], spec[:chain], name, argv.size, private_ok: site[:implicit_self])',
     'target = core_exact_target(site[:klass], spec[:chain], name, 0, private_ok: site[:implicit_self])']
}.freeze

if ENV['CX_MUTANTS'] == '1' && MODE != 'run' && tool?(MRBC_PATH)
  run_copy = lambda do |dir_label, file, from, to|
    dir = File.join(ROOT, 'tools', "bc2cpp-mutant-#{Process.pid}-#{dir_label}")
    begin
      FileUtils.cp_r(File.join(ROOT, 'tools/bc2cpp'), dir)
      if file
        path = File.join(dir, file)
        text = File.read(path)
        return [:site_gone, "the mutated text is not in #{file}"] unless text.include?(from)

        File.write(path, text.sub(from) { to })
      end
      Bc2cppMutantPool.run({ 'CX_TOOL_DIR' => dir, 'CX_MODE' => 'generated', 'CX_MUTANTS' => '0', 'MRBC' => MRBC_PATH },
                           [RbConfig.ruby, __FILE__])
    ensure
      FileUtils.rm_rf(dir)
    end
  end
  puts 'mutants'
  # The control runs first and alone: it is what says the copy-and-run path itself still works, so
  # running it beside a mutant would attribute a broken path to that mutant.
  control = run_copy.call('control', nil, nil, nil)
  check.call('control: an unmutated copy of the generator passes the generated-code checks',
             control.respond_to?(:out) && control.success && control.out.to_s.include?('PASS'))
  puts control.out.to_s.lines.grep(/FAIL|rror/).first(6).join unless control.respond_to?(:out) && control.success

  # Each mutant is a copy of the generator with one soundness condition broken, run as its own
  # subprocess, so the pool runs several at a time (BC2CPP_JOBS; docs/ci.md, "Mutant pool"). This
  # was the slowest single command in the bc2cpp check matrix as a serial loop.
  # MUTANTS is a Hash; the pool indexes its items, so hand it the pairs in declaration order.
  # Unique dir per mutant: the pool runs them concurrently and two mutants may edit the same
  # file, so a label derived from the file alone would have them share (and delete) one dir.
  mutant_seq = Mutex.new
  seen = 0
  mutate = lambda do |(_name, (file, from, to))|
    index = mutant_seq.synchronize { seen += 1 }
    run_copy.call("m#{index}-#{file}", file, from, to)
  end

  Bc2cppMutantPool.each_ordered(MUTANTS.to_a, work: mutate) do |(name, _spec), run|
    if run.is_a?(Array) && run.first == :site_gone
      check.call("mutant #{name}: #{run.last}", false)
      next
    end
    caught = !run.success && run.out.include?('FAIL')
    check.call("mutant killed: #{name}", caught)
    puts run.out.lines.grep(/FAIL|rror/).first(4).join unless caught
  end
end

if failures.empty?
  puts "bc2cpp core exact direct check: PASS#{ran_behaviour ? '' : ' (generated code only)'}"
else
  warn "bc2cpp core exact direct check: #{failures.size} failure(s)"
  exit 1
end
