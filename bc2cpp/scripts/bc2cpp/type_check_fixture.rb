# frozen_string_literal: true

require 'json'
require 'open3'
require 'rbconfig'
require 'tmpdir'

# Each caller keeps its own closed world, signatures and feature controls.
module TypeCheckFixture
  def self.report(directory, files: ['fixture.rb'], env: {}, options: [], out: nil, label: 'type-check fixture')
    command = [RbConfig.ruby, File.expand_path('type_check.rb', __dir__),
               '--format', 'json', '--no-sends', *options, '--files', *files]
    command.concat(['--out', out]) if out
    environment = env.dup
    environment['MRBC'] = File.expand_path(ENV.fetch('MRBC')) if ENV['MRBC'] && !environment.key?('MRBC')
    stdout, stderr, status = Open3.capture3(environment, *command, chdir: directory)
    raise "#{label} failed (#{status.exitstatus}): #{stderr}\n#{stdout}" unless status.success?

    JSON.parse(out ? File.read(out) : stdout)
  end

  # Keep the compiler in a fresh subprocess; fixture variants can reuse only the report renderer.
  def self.facts_report(directory, files: ['fixture.rb'], env: {}, label: 'type-check fixture')
    if ENV['BC2CPP_FIXTURE_DIRECT_REPORT'] == '0' || ENV['BC2CPP_TOOLS_DIR'] || env['BC2CPP_TOOLS_DIR']
      return report(directory, files: files, env: env, label: label)
    end

    require_relative '../../tools/bc2cpp/type_check_run'
    require_relative '../../tools/bc2cpp/type_check_report'

    root = File.expand_path('../..', __dir__)
    directory = File.expand_path(directory)
    sources = files.map { |file| File.expand_path(file, directory) }
    mrbc = ENV['MRBC'] ? File.expand_path(ENV['MRBC']) : 'mrbc'
    Dir.mktmpdir('type-check-fixture') do |work|
      result = Dir.chdir(directory) do
        TypeCheckRun.run(root: root, mrbc: mrbc, workdir: work, sources: sources, sends: false,
                         display_root: directory, extra_env: env)
      end
      facts = JSON.parse(File.read(result.facts_path))
      diagnostics = TypeCheckReport.diagnostics(facts, [])
      status = TypeCheckReport.exit_status(diagnostics)
      raise "#{label} failed (#{status}):\n#{diagnostics.map(&:to_s).join("\n")}" unless status.zero?

      JSON.parse(TypeCheckReport.json(facts, [], diagnostics, TypeCheckReport.summary(facts)))
    end
  end
end
