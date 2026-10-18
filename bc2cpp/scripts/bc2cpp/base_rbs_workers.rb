# frozen_string_literal: true

require 'etc'
require 'tmpdir'

# Process isolation keeps per-file Clang ASTs and scanner state out of the parent (ADR 0488).
module BaseRbsWorkers
  DEFAULT_JOBS = [Etc.nprocessors, 2].min

  module_function

  def map(paths, jobs: DEFAULT_JOBS)
    raise ArgumentError, 'jobs must be a positive integer' unless jobs.is_a?(Integer) && jobs.positive?
    return paths.map { |path| yield path } if jobs == 1 || !Process.respond_to?(:fork)

    Dir.mktmpdir('base-rbs-workers') do |dir|
      workers = []
      active = {}
      statuses = {}
      begin
        until workers.size == paths.size && active.empty?
          while workers.size < paths.size && active.size < jobs
            index = workers.size
            path = paths[index]
            result = File.join(dir, "#{index}.result")
            errors = File.join(dir, "#{index}.stderr")
            pid = fork do
              $stderr.reopen(errors, 'w')
              $stderr.sync = true
              begin
                File.binwrite(result, Marshal.dump([:ok, yield(path)]))
                exit! 0
              rescue StandardError => e
                File.binwrite(result, Marshal.dump([:error, e]))
                exit! 1
              end
            end
            workers << [path, result, errors]
            active[pid] = index
          end
          active.keys.each do |pid|
            waited = Process.wait2(pid, Process::WNOHANG)
            next unless waited

            statuses[active.delete(pid)] = waited.last
          end
          sleep 0.005 if active.any? && (active.size == jobs || workers.size == paths.size)
        end
        workers.each { |_, _, errors| $stderr.write(File.binread(errors)) if File.file?(errors) }
        workers.each_with_index.map do |(path, result, _), index|
          status = statuses.fetch(index)
          raise "native RBS worker failed for #{path} (#{status}); no result" unless File.file?(result)

          kind, value = Marshal.load(File.binread(result)) # rubocop:disable Security/MarshalLoad
          raise value if kind == :error
          raise "native RBS worker failed for #{path} (#{status})" unless status.success?

          value
        end
      ensure
        # Only unreaped children remain here, including after a partial launch failure.
        active.each_key { |pid| Process.waitpid(pid) }
      end
    end
  end
end
