# frozen_string_literal: true

# Shared by the bc2cpp mutation checks: each mutant is a copy of the generator run in its own
# subprocess and independent of the others, so they run concurrently instead of back to back
# (docs/ci.md, "Mutant pool"). Results are handed back in input order, so the log and the
# pass/fail lines read the same as a serial run.
#
# BC2CPP_JOBS bounds the concurrency (default: the core count, at most 4); 1 is the old serial run.
require 'etc'
require 'open3'
require 'rbconfig'

module Bc2cppMutantPool
  Result = Struct.new(:out, :success, :stopped)

  # A mutant is a copy of tools/bc2cpp alone, so the lint cross-check (ADR 0368) cannot find
  # scripts/rpg2k/closed_world_lint.rb beside it; the check owns that agreement, the mutant does not.
  MUTANT_ENV = { 'BC2CPP_LINT_CROSSCHECK' => '0' }.freeze

  module_function

  def jobs
    value = Integer(ENV.fetch('BC2CPP_JOBS') { [Etc.nprocessors, 4].min })
    raise ArgumentError, "BC2CPP_JOBS must be at least 1, got #{value}" if value < 1

    value
  end

  # Runs `argv` and returns a Result. With `stop_on`, the child is terminated at the first output
  # line matching it and `success` is false: a check prints a FAIL line only together with a
  # nonzero exit (every check here ends in `exit 1` when it recorded one), so a mutant it already
  # reports as caught need not run to the end.
  def run(env, argv, stop_on: nil)
    env = MUTANT_ENV.merge(env)
    # Piped Ruby stdout is buffered: flush failures before the check starts
    # another compiler run. Load only in this child, not its Ruby subprocesses.
    if stop_on && argv.first == RbConfig.ruby
      argv = [argv.first, '-r', File.join(__dir__, 'unbuffered_stdout.rb'), *argv.drop(1)]
    end
    out = +''
    stopped = false
    status = nil
    Open3.popen2e(env, *argv, pgroup: true) do |stdin, merged, waiter|
      stdin.close
      merged.each_line do |line|
        out << line
        next unless stop_on&.match?(line)

        stopped = true
        terminate(waiter.pid)
        break
      end
      status = waiter.value
    end
    Result.new(out, !stopped && status.success?, stopped)
  end

  # TERM to the child's whole process group (the check and the compilers it started).
  def terminate(pid)
    Process.kill('TERM', -pid)
  rescue Errno::ESRCH
    # Exited between printing the line and the kill; the caller still reads its exit status.
    nil
  end

  # Calls `work.call(item)` on every item, up to `jobs` at a time, and yields (item, result) in
  # input order as each prefix completes. An exception in `work` is re-raised here, in that order.
  def each_ordered(items, work:, jobs: self.jobs)
    slots = Array.new(items.size)
    lock = Mutex.new
    done = ConditionVariable.new
    next_index = 0
    workers = Array.new([jobs, items.size].min) do
      Thread.new do
        loop do
          index = lock.synchronize { next_index.tap { next_index += 1 } }
          break if index >= items.size

          slot = begin
            [:ok, work.call(items[index])]
          rescue StandardError => e
            # Forwarded to the thread that reports in order, which re-raises it.
            [:error, e]
          end
          lock.synchronize do
            slots[index] = slot
            done.broadcast
          end
        end
      end
    end
    items.each_index do |index|
      kind, value = lock.synchronize do
        done.wait(lock) while slots[index].nil?
        slots[index]
      end
      raise value if kind == :error

      yield items[index], value
    end
    workers.each(&:join)
  end
end
