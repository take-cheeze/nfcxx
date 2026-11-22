#!/usr/bin/env ruby
# frozen_string_literal: true

# ENSURE_YIELD_RAISE: a method whose ensure restores state around `yield` (ScanCache.compute's shape) runs that
# ensure when the block raises, also when the block reaches it through other blocks' yields and when the raise is a
# rescue's re-raise. The counter it restores is read after the exception is rescued; compiled must match interpreted.
# RESUME_FROM_C_HANDLERS: compute is a resumable method here (a Fiber suspends in its block), the form a
# self-compiled bc2cpp gives ScanCache.compute, and called from C a raise in its block reaches its ensure.
# RESUME_FROM_C_UNWIND: so do a `break` and a block `return` (C++ unwinds), past rescue clauses and through nested ensures.
ENV['BC2CPP_SIG_DIRS'] = ''

require 'tmpdir'
require_relative 'check_support'
require_relative 'fixture_runtime'

suite = FixtureCheck.new('ensure_yield_raise_check')
suite.require_mrbc!

SOURCE = <<~RUBY
  class EyCache
    class << self
      def computing = @computing || 0

      def compute(env = nil)
        @computing = computing + 1
        (@allowed ||= []) << env
        yield
      ensure
        @allowed.pop
        @computing -= 1
      end

      def depth = (@allowed || []).size

      # A rescue, not an ensure, around a yield that may suspend (the Fiber below).
      def guarded
        yield
      rescue ArgumentError => e
        "rescued \#{e.message}"
      end
    end

    def self.entry(_name)
      yield
    end

    def self.fetch(name)
      value = entry(name) { EyCache.compute { yield } }
      value
    end
  end

  class EyProbe
    def state = [EyCache.computing, EyCache.depth]

    def run_ok
      [EyCache.fetch('a') { 1 }, state]
    end

    def run_raise
      begin
        EyCache.fetch('b') { raise ArgumentError, 'plain' }
      rescue ArgumentError => e
        [e.message, state]
      end
    end

    def run_reraise
      begin
        EyCache.fetch('c') do
          begin
            raise NoMethodError, 'inner'
          rescue StandardError => e
            raise ArgumentError, "re: \#{e.message}"
          end
        end
      rescue ArgumentError => e
        [e.message, state]
      end
    end

    class EyGuardError < StandardError; end
    class EyCompileError < StandardError; end

    def self.locked(path)
      File.open(path, File::RDWR | File::CREAT, 0o600) do |lock|
        lock.flock(File::LOCK_EX)
        yield
      end
    end

    def deep_compile(path)
      EyProbe.locked(path) { File.missing_singleton_method_for_check(path) }
    end

    def run_shape
      begin
        pairs = EyCache.fetch('d') do
          compiled, root = begin
            deep_compile('/tmp/ey_check.lock')
          rescue EyGuardError
            raise
          rescue StandardError => e
            raise EyCompileError, e.message.lines.first&.strip
          end
          [compiled, root]
        end
        [pairs, state]
      rescue EyCompileError => e
        [:compile_error, e.message.include?('missing_singleton_method_for_check'), state]
      end
    end

    # A Fiber that suspends inside the block makes compute a resumable method, the form a self-compiled bc2cpp gives
    # ScanCache.compute; every other run then drives it from C.
    def run_fiber
      fiber = Fiber.new { EyCache.compute { Fiber.yield(1) + 1 } }
      [fiber.resume, fiber.resume(2), state]
    end

    def run_fiber_break
      fiber = Fiber.new { EyCache.compute { Fiber.yield(1); break 4 } }
      [fiber.resume, fiber.resume, state]
    end

    def run_break
      [EyCache.compute { break 7 }, state]
    end

    def run_break_nested
      [EyCache.compute { EyCache.compute { break 5 } + 1 }, state]
    end

    def return_inner
      EyCache.compute { return 9 }
      0
    end

    def run_return
      [return_inner, state]
    end

    def run_next
      [EyCache.compute { next 8 }, state]
    end

    def run_rescue
      fiber = Fiber.new { EyCache.guarded { Fiber.yield(1) } }
      fiber.resume
      [EyCache.guarded { raise ArgumentError, 'r' }, fiber.resume(2), state]
    end

    def run_direct
      begin
        EyCache.compute { raise ArgumentError, 'direct' }
      rescue ArgumentError => e
        [e.message, state]
      end
    end

    def run_nested
      begin
        EyCache.compute { EyCache.compute { raise ArgumentError, 'nested' } }
      rescue ArgumentError => e
        [e.message, state]
      end
    end
  end
RUBY

OWNERS = %w[EyCache EyCache.singleton EyProbe].freeze
RUNS = %w[run_ok run_raise run_reraise run_shape run_fiber run_fiber_break run_break run_break_nested run_return run_next run_rescue run_direct run_nested].freeze

def compiled?(code, name)
  code.match?(/^mrb_value #{name}_impl\(mrb_state\* M/)
end

Dir.mktmpdir('bc2cpp-ensure-yield-raise') do |dir|
  code, err = Bc2cppFixtureRuntime.generate(SOURCE, dir, core: true, only_owners: OWNERS)
  File.write(File.join(ENV['BC2CPP_KEEP_DIR'], 'ensure_yield_raise.cxx'), code) if ENV['BC2CPP_KEEP_DIR']
  suite.check('the ensure around yield compiles', compiled?(code, 'EyCache_singleton_compute'))
  suite.check('as a resumable method (a block it yields to may suspend)', code.include?('EyCache_singleton_compute_step('))
  suite.check('its callers compile', RUNS.all? { |m| compiled?(code, "EyProbe_#{m}") })

  build = ENV['CC_GENERATED_ONLY'] == '1' ? nil : Bc2cppFixtureRuntime.full_or_build
  if build.nil?
    puts '  SKIP ensure yield raise behaviour: needs a full-core libmruby (BC2CPP_MRUBY_FULL, or rake and g++)'
  else
    scenario = <<~CPP
      static int scenario(mrb_state* M) {
        for (const char* m : {#{RUNS.map { |r| "\"#{r}\"" }.join(', ')}}) {
          mrb_value o = mrb_funcall_argv(M, mrb_obj_value(mrb_class_get(M, "EyProbe")), mrb_intern_lit(M, "new"), 0, nullptr);
          call(M, m, o, m);
        }
        return 0;
      }
    CPP
    built, output = Bc2cppFixtureRuntime.run(dir, err, OWNERS, scenario, build: build, full: true)
    suite.check('fixture builds and runs', built)
    sections = Bc2cppFixtureRuntime.sections(output)
    plain = ->(lines) { lines.to_a.reject { |l| l.start_with?('  dispatches=') } }
    interpreted = plain.call(sections['interpreted'])
    compiled = plain.call(sections['compiled'])
    suite.check('the interpreter restores the counter on every exit',
                RUNS.all? { |m| interpreted.any? { |l| l.start_with?("#{m} =>") && l.end_with?('[0, 0]]') } } &&
                interpreted.include?('run_break => [7, [0, 0]]') && interpreted.include?('run_return => [9, [0, 0]]') &&
                interpreted.include?('run_rescue => ["rescued r", 2, [0, 0]]'))
    suite.check('compiled matches interpreted', compiled == interpreted)
    warn "interpreted:\n  #{interpreted.join("\n  ")}\ncompiled:\n  #{compiled.join("\n  ")}" unless compiled == interpreted
  end
end

suite.finish!
