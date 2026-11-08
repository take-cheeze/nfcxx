#!/usr/bin/env ruby
# frozen_string_literal: true

# BLOCK_SELF: BlockSelf.plain_yielder_why (tools/bc2cpp/block_self.rb), the proof that a method only tests, copies,
# calls or yields its block. STACK_BLOCK hands a frame-local RProc to the methods it accepts, so a block that can
# leave through any read must be refused. The cases cover the operand windows the proof models by count (ARRAY,
# ARRAY2, ARYPUSH, HASH, ARYCAT, STRCAT, ARYSPLAT) and the sends it models by their argument spec (a splat, keywords,
# `**`, a block argument), on the accepting and on the refusing side. Needs MRBC; without it the check prints SKIP.
#
#   MRBC=path/to/host/mrbc ruby scripts/bc2cpp/plain_yielder_check.rb

require_relative 'check_support'
require_relative '../../tools/bc2cpp/bc2cpp'

suite = FixtureCheck.new('plain_yielder_check')
suite.require_mrbc!

PLAIN = {
  'calls its block' => 'def m(&b); b.call(1); end',
  'yields' => 'def m; yield 1; end',
  'builds an empty Array next to the block' => 'def m(&b); ary = []; ary.push(b.call(1)); ary; end',
  # Enumerable#collect: the `unless b` test leaves a copy of the block in the register above `ary = []` (ARRAY R3 0).
  'tests it, then builds an empty Array below the copy' =>
    'def m(&b); return :e unless b; ary = []; [[1]].each { |*v| ary.push(b.call(*v)) }; ary; end',
  'builds an Array from other registers' => 'def m(x, &b); r = [x, x]; b.call(r); end',
  'calls it with a splat from a nested block' => 'def m(&b); ary = []; [[1]].each { |*v| ary.push(b.call(*v)) }; ary; end',
  'calls it with a splat and keywords' => 'def m(&b); b.call(*[1], k: 2); end',
  'tests it' => 'def m(&b); return :none unless b; b.call; end',
  'builds a Hash of other values' => 'def m(&b); h = { a: 1 }; b.call(h); end',
  # GETIDX0 reads only its receiver: Enumerable#inject's `args[0]` next to the block register.
  'indexes another Array with [0]' => 'def m(*args, &b); r = args[0]; b.call(r); end',
  'indexes with [0] after a yield' => 'def m(a); yield; a[0]; end',
  'rescues around a yield' => 'def m(d); yield; rescue StandardError => e; d.f(e.message); d; end',
  'rescues around a block call' => 'def m(d, &b); b.call; rescue ArgumentError, TypeError; d; end',
  'yields inside an ensure' => 'def m(o); yield o; ensure; o.close; end',
  'IO.open shape' => 'def m(*a, &b); io = a[0]; return io unless b; begin; yield io; ensure; begin; io.close unless io.closed?; rescue StandardError; end; end; end'
}.freeze

ESCAPING = {
  'an Array element' => 'def m(&b); [b]; end',
  'an Array element after another' => 'def m(x, &b); [x, b]; end',
  'a pushed element' => 'def m(&b); a = []; a << b; a; end',
  'an Array concatenated with a splat' => 'def m(x, &b); [*x, b]; end',
  'a Hash value' => 'def m(&b); { k: b }; end',
  'a splat argument' => 'def m(o, &b); o.f(*[b]); end',
  'a positional argument of a splat send' => 'def m(o, x, &b); o.f(b, *x); end',
  'a keyword argument' => 'def m(o, &b); o.f(k: b); end',
  'a double-splat argument' => 'def m(o, &b); o.f(**{ k: b }); end',
  'the block of a splat send' => 'def m(o, x, &b); o.f(*x, &b); end',
  'an interpolated String' => 'def m(&b); "#{b}"; end',
  'a splatted value' => 'def m(&b); x = *b; x; end',
  'a nested block capture passed on' => 'def m(o, &b); [1].each { |v| o.f(b) }; end',
  'super' => 'def m(&b); super; end',
  'the receiver of [0]' => 'def m(&b); b[0]; end',
  'an Array element indexed with [0]' => 'def m(&b); a = [b]; a[0]; end',
  'a rescue handler storing it' => 'def m(&b); yield; rescue StandardError; @k = b; end',
  'a rescue handler returning it' => 'def m(&b); b.call; rescue StandardError => e; [e, b]; end',
  'a rescue handler passing it' => 'def m(o, &b); o.f; rescue StandardError; o.g(b); end',
  'a rescue clause naming it' => 'def m(&b); yield; rescue b; 0; end',
  'an ensure body storing it' => 'def m(&b); yield; ensure; @k = b; end'
}.freeze

def method_why(ireps, root, name)
  registry = build_registry(ireps, root)[0]
  definition = (registry[name] || []).find { |d| d.owner == 'PyFx' } or return :missing
  BlockSelf.plain_yielder_why(ireps[definition.irep], ireps)
end

(PLAIN.to_a + ESCAPING.to_a).each_with_index do |(what, body), index|
  plain = index < PLAIN.size
  suite.compile("class PyFx\n  #{body}\nend\n") do |ireps, root|
    why = method_why(ireps, root, 'm')
    if plain
      suite.check("#{what}: a plain yielder", why.nil?)
    else
      suite.check("#{what}: refused (#{why})", why.is_a?(String))
    end
  end
end

suite.finish!
