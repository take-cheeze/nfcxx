#!/usr/bin/env ruby
# encoding: UTF-8
# SUPER_NO_CALLER_BLOCK (ADR 0332): `super` becomes a direct `_impl` call with no
# block because the build PROVES no caller ever passes one, rather than that
# being a hand-vetted allowlist entry (SUPER_TARGETS, ADR 0146).
#
# A compiled `_impl` has no block parameter, so OP_SUPER's forwarded block would
# be dropped. The proof must therefore refuse as readily as it admits: a
# block-carrying send of the same name to the class, to a subclass, or with an
# unproven receiver all keep the `#error`. `Base#go` reads its block, so a
# dropped one is an observable wrong answer (nil) rather than a silent no-op.
require 'tmpdir'
require 'open3'
require 'shellwords'
require_relative 'fixture_runtime'

runtime = Bc2cppFixtureRuntime
failures = []
check = lambda do |what, ok|
  puts "  #{ok ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless ok
end

# Base#go yields, so passing it a block is observable; Leaf#go supers with none
# of its own. `caller_*` decides whether a block arrives.
BASE = <<~'RUBY'
  class Base
    def go
      block_given? ? 'base[' + yield.to_s + ']' : 'base'
    end
  end

  class Leaf < Base
    def go
      'leaf->' + super
    end
  end

  class Probe
    def no_block(x); x.go; end

    def with_block(x); x.go { 7 }; end
  end
RUBY

# A subclass call still reaches Leaf#go, so it must count as a caller.
SUBCLASS_CALLER = <<~'RUBY'
  class Leaf2 < Leaf
  end

  class Probe
    def via_sub(x); Leaf2.new.go { 9 }; end
  end
RUBY

# A caller whose receiver class the flow cannot pin down.
UNPROVEN_RECEIVER = <<~'RUBY'
  class Probe
    def unproven(x); [x, nil].each { |y| y.go { 5 } }; end
  end
RUBY

OWNERS = %w[Base Leaf Probe].freeze
body = ->(code, fn) { code[/^mrb_value #{fn}_impl\(mrb_state\* M.*?(?=^\}$)/m].to_s }

# Bc2cppFixtureRuntime#generate builds the closed world (BC2CPP_CLOSED_WORLD=1,
# the wio gem set, the native sources) the proof needs: without it call_facts is
# off and every question is open, which refuses everything. BC2CPP_MODULE_SUPER=0
# isolates this path from ADR 0329's (which resolves a super THROUGH a module).
#
# generate_all drops SKIP_UNSUPPORTED, so a refusal shows as a `#error` inside the
# body rather than as a body the flag dropped whole.
generate_all = lambda do |source, owners = OWNERS, extra = {}|
  Dir.mktmpdir do |dir|
    saved = extra.to_h { |k, _v| [k, ENV[k]] }
    (extra.merge('BC2CPP_MODULE_SUPER' => '0')).each { |k, v| ENV[k] = v }
    begin
      code, = runtime.generate(source, dir, closed: true, only_owners: owners,
                                         skip_unsupported: false)
    ensure
      saved.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    end
    code
  end
end
generate = generate_all

# (1) No block-carrying call of `go` anywhere in the build: admitted, and the
#     call names the superclass body directly.
NO_CALLER = <<~'RUBY'
  class Base
    def go
      block_given? ? 'base[' + yield.to_s + ']' : 'base'
    end
  end

  class Leaf < Base
    def go
      'leaf->' + super
    end
  end

  class Probe
    def no_block(x); x.go; end
  end
RUBY

plain = generate.call(NO_CALLER, OWNERS)
leaf = body.call(plain, 'Leaf_go')
check.call('a super with no block-carrying caller compiles to a direct call',
           !leaf.empty? && !leaf.include?('#error') && leaf.include?('Base_go_impl(M, self'))

# (2) A block-carrying call of `go` in the same build: refused.
blocked = generate.call(BASE, OWNERS)
check.call('a block-carrying caller of the same name keeps the #error',
           body.call(blocked, 'Leaf_go').include?('#error'))

# (3) A block-carrying call through a SUBCLASS still reaches Leaf#go.
sub = generate.call("#{BASE}\n#{SUBCLASS_CALLER}", OWNERS + %w[Leaf2])
check.call('a block-carrying caller through a subclass keeps the #error',
           body.call(sub, 'Leaf_go').include?('#error'))

# (4) A caller whose receiver class cannot be pinned down.
unproven = generate.call("#{BASE}\n#{UNPROVEN_RECEIVER}", OWNERS)
check.call('a block-carrying caller with an unproven receiver keeps the #error',
           body.call(unproven, 'Leaf_go').include?('#error'))

# (5) Per-name, not global: a block-carrying caller of `go` must not block the
#     unrelated `alt`, whose name nobody calls with a block.
mixed = generate.call(<<~RUBY, OWNERS + %w[Other])
  class Base
    def go
      block_given? ? %q{base[]} + yield.to_s + %q{]} : %q{base}
    end

    def alt; %q{alt}; end
  end

  class Leaf < Base
    def go; %q{leaf->} + super; end

    def alt; %q{leaf->} + super; end
  end

  class Probe
    def with_block(x); x.go { 7 }; end
  end
RUBY
check.call(%q{the refusal is per-name: an unrelated super still compiles},
           body.call(mixed, %q{Leaf_alt}).include?(%q{Base_alt_impl(M, self}) &&
             body.call(mixed, %q{Leaf_go}).include?(%q{#error}))

# (6) The kill switch restores the previous behaviour.
killed = generate.call(BASE, OWNERS, 'BC2CPP_SUPER_DIRECT' => '0')
check.call('BC2CPP_SUPER_DIRECT=0 keeps the #error',
           body.call(killed, 'Leaf_go').include?('#error'))

abort "super direct proof: #{failures.size} failure(s): #{failures.join(', ')}" unless failures.empty?
puts 'bc2cpp super direct proof check: PASS'
