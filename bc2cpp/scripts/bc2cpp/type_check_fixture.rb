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
end
