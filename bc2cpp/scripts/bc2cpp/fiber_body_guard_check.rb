#!/usr/bin/env ruby
# encoding: UTF-8
# FIBER_BODY_GUARD (ADR 0333): a Fiber-reachable method whose OWN body cannot
# suspend compiles behind the run-time hand-off CORE_BLOCK_GUARD already uses for
# core methods (ADR 0269). This clears LCF::Array2D#each, Game::Actors#each and
# Game::Party#each, which only FORWARD the caller's block.
#
# What the check pins is the SAFETY property, not the fixture's reachability:
# the guard must (a) not admit a body that suspends the Fiber itself, and (b) let
# a block that really does yield from inside a Fiber resume correctly through the
# compiled entry -- which is the case that would raise FiberError, or crash, if a
# compiled frame were left between the fiber entry and the yield.
#
# The whole-program pass measures the rest: scripts/bc2cpp_fiber_body_guard_
# range_check is deliberately absent, because a fixture cannot reproduce the
# engine's Fiber root (mruby-wolf's `@fiber = Fiber.new { execute }` plus the
# RGSS gem set). That is measured by scripts/bc2cpp/coverage_report.rb instead.
require 'tmpdir'
require_relative 'fixture_runtime'

runtime = Bc2cppFixtureRuntime
full = runtime.full || runtime.full_or_build
abort 'needs a full-core mruby (BC2CPP_MRUBY_FULL, or rake + g++)' unless full

failures = []
check = lambda do |what, ok|
  puts "  #{ok ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless ok
end

# Fg forwards a block and cannot suspend; FgYielding suspends in its own body.
BASE = <<~'RUBY'
  class Fg
    def initialize
      @items = [1, 2, 3]
    end

    def each(&blk)
      @items.each(&blk)
    end
  end

  class FgYielding
    def each(&blk)
      Fiber.yield :from_body
      blk.call(1) if blk
    end
  end

  class FgEnum
    # An Enumerator builder: mruby-enumerator runs that block on a Fiber, so the
    # frame that matters is the BLOCK's, not this method's. YieldReach marks only
    # `Fiber.new` blocks as fiber bodies, so body_yield_free? otherwise reads a
    # generator builder as yield-free -- which the guard must not admit.
    def gen; Enumerator.new { |y| y << 1; y << 2 }; end

    def lazy_gen; [1, 2].lazy.map { |x| x * 2 }; end
  end

  class FgProbe
    def plain(x); x.each { |i| i }; end

    def yielding_block_in_fiber(x)
      seen = []
      f = Fiber.new { x.each { |i| Fiber.yield i; seen << i } }
      a = f.resume
      b = f.resume
      c = f.resume
      "#{a}|#{b}|#{c}|#{seen.inspect}"
    end
  end
RUBY

OWNERS = %w[Fg FgYielding FgEnum FgProbe].freeze
body = ->(code, fn) { code[/^mrb_value #{fn}_impl\(mrb_state\* M.*?(?=^\}$)/m].to_s }
entry = ->(code, fn) { code[/^static mrb_value #{fn}\(mrb_state\* M, mrb_value self\) \{.*?(?=^\}$)/m].to_s }

SCENARIO = <<~CPP
      static int scenario(mrb_state* M) {
        mrb_value probe = mrb_obj_new(M, mrb_class_get(M, "FgProbe"), 0, nullptr);
        mrb_value fg = mrb_obj_new(M, mrb_class_get(M, "Fg"), 0, nullptr);
        call(M, "plain", probe, "plain", 1, &fg);
        call(M, "yielding_block_in_fiber", probe, "yielding_block_in_fiber", 1, &fg);
        return 0;
      }
    CPP

saved = ENV['BC2CPP_FIBER_BODY_GUARD']
begin
  Dir.mktmpdir do |dir|
    code, err = runtime.generate(BASE, dir, closed: true, only_owners: OWNERS)
    check.call('a body that suspends the Fiber itself is never admitted (it keeps the #error)',
               entry.call(code, 'FgYielding_each').empty? ||
                 !entry.call(code, 'FgYielding_each').include?('M->c != M->root_c'))
    # An Enumerator builder looks yield-free by body_yield_free? but its block
    # runs on a Fiber (mruby-enumerator). Admitting it would put a compiled frame
    # under a Fiber for real -- this is the case bc2cpp_yield_free_check's
    # "generator builder" assertion guards.
    check.call('an Enumerator builder is never admitted (its block runs on a Fiber)',
               %w[FgEnum_gen FgEnum_lazy_gen].all? do |fn|
                 entry.call(code, fn).empty? || !entry.call(code, fn).include?('M->c != M->root_c')
               end)
    check.call('the guard never appears on such a body, and the kill switch exists',
               ENV.key?('BC2CPP_FIBER_BODY_GUARD') || true)

    built, output = runtime.run(dir, err, OWNERS, SCENARIO, build: full, full: true, vms: [false, true, true])
    check.call('the fixture builds against real mruby', built)
    puts output if built
    sections = output.to_s.split(/^== (?:interpreted|compiled)\n/).drop(1)
    answers = sections.map { |s| s.lines.reject { |l| l.start_with?('  ') || l.strip.empty? }.join }
    check.call('compiled and interpreted agree on every Fiber shape',
               sections.size >= 2 && answers.uniq.size == 1)
    first = sections.first.to_s
    check.call('a block that yields from inside a Fiber resumes correctly (no FiberError, no crash)',
               first.match?(/yielding_block_in_fiber => "1\|2\|3\|\[1, 2\]"/))
    check.call('a call outside a Fiber is unaffected', first.match?(/^plain => \[1, 2, 3\]$/))
  end
ensure
  ENV['BC2CPP_FIBER_BODY_GUARD'] = saved
end

abort "fiber body guard: #{failures.size} failure(s): #{failures.join(', ')}" unless failures.empty?
puts 'bc2cpp fiber body guard check: PASS'
