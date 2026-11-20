# frozen_string_literal: true

# Keep timing state outside the large driver scope: mrbc allows only 255 locals
# per scope, including its implicit slots. Variants reset both phase clocks.
module Bc2cppTimings
  def self.callbacks
    profile_started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    profile_last = profile_started
    # NFCXX_TIME_LOG (set by the nfcxx driver, docs/notes/tracing.md): each phase is also appended to that file as a
    # time-log line, "SECONDS<Tab>bc2cpp<Tab>PHASE<Tab>UNIT", the format scripts/trace.sh writes. UNIT is the source the
    # driver compiles (NFCXX_TRACE_UNIT), else the build name.
    time_log = ENV['NFCXX_TIME_LOG'].to_s
    time_log_unit = ENV['NFCXX_TRACE_UNIT'] || ENV['BC2CPP_BUILD_NAME'] || ''
    profile_phase = lambda do |name|
      profiling = ENV['BC2CPP_PROFILE_TIMINGS'] == '1'
      next unless profiling || !time_log.empty?

      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      if profiling
        # Resident memory (Linux), so a run shows where its memory grows; -1 where /proc is not there.
        rss_kb = begin
          File.read('/proc/self/status').lines.grep(/\AVmRSS:/).first.to_s.split[1].to_i
        rescue StandardError
          -1
        end
        warn format('BC2CPP_TIME %-32s %8.3fs (total %8.3fs) rss %d MB', name, now - profile_last, now - profile_started,
                    rss_kb / 1024)
      end
      unless time_log.empty?
        micros = ((now - profile_last) * 1_000_000).round
        line = format("%d.%06d\tbc2cpp\t%s\t%s\n", micros / 1_000_000, micros % 1_000_000, name, time_log_unit)
        # A time log that cannot be written must not fail the build it times.
        begin
          File.open(time_log, 'a') { |file| file.write(line) }
        rescue StandardError
          nil
        end
      end
      profile_last = now
    end
    profile_call = lambda do |name, &block|
      next block.call unless ENV['BC2CPP_PROFILE_TIMINGS'] == '1'

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      value = block.call
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      warn format('BC2CPP_DETAIL %-40s %8.3fs', name, elapsed)
      value
    end

    reset = lambda do
      profile_started = profile_last = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
    [profile_phase, profile_call, reset]
  end
end
