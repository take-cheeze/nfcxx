#!/usr/bin/env ruby
# frozen_string_literal: true

require 'tmpdir'
require 'fileutils'
require 'rbconfig'
require_relative '../../scripts/ci-scope'

SCRIPT = File.expand_path('../../scripts/ci-scope.rb', __dir__)
checks = 0
check = lambda do |label, &test|
  checks += 1
  abort "FAIL #{label}" unless test.call
end
rejects = lambda do |label, &test|
  check.call(label) do
    begin
      test.call
      false
    rescue ArgumentError
      true
    end
  end
end

[%w[bc2cpp/tools/bc2cpp/bc2cpp.rb], %w[tests/bc2cpp/fetch.sh], %w[docs/notes/test.md],
 %w[bc2cpp/new.rb docs/new.md tests/bc2cpp/new.sh], ["docs/notes/\nbe/x.md"],
 ["docs/\xff.md".b]].each do |paths|
  check.call("isolated PR: #{paths.inspect}") do
    CiScope.select('pull_request', paths) == { 'full_ci' => 'false', 'changed' => 'false' }
  end
end

%w[be/new.cpp .github/workflows/ci.yml scripts/ci-scope.rb tests/ci/scope_check.rb
   Gemfile unknown bc2cpp-other/a docs/tool.rb docs/notes/source.patch].each do |path|
  check.call("mixed/unlisted path: #{path}") do
    CiScope.select('pull_request', ['bc2cpp/a.rb', path])['full_ci'] == 'true'
  end
end

%w[scripts/pathb-qbe-emit.rb scripts/new-helper be/a.cpp 3rd/edg 3rd/qbe 3rd/cproc
   nfcxx nfcc/driver.c lib/new.c tests/run.sh tests/pathb-ir/a.ir tests/cases/a.cpp
   tests/mruby/a.sh .github/actions/toolchain/action.yml tools/qbe-prep/main.cpp
   .github/workflows/ci.yml].each do |path|
  check.call("Path B dependency: #{path}") do
    CiScope.select('pull_request', [path]) == { 'full_ci' => 'true', 'changed' => 'true' }
  end
end

['push', 'workflow_dispatch', 'merge_group', ''].each do |event|
  check.call("full general coverage for #{event.inspect}") do
    CiScope.select(event, ['docs/a.md'])['full_ci'] == 'true'
  end
end
check.call('empty diff keeps both matrices') do
  CiScope.select('pull_request', []) == { 'full_ci' => 'true', 'changed' => 'true' }
end

def outcomes(full, pathb)
  needs = { 'pathb-changes' => { 'result' => 'success', 'outputs' => {
    'full_ci' => full.to_s, 'changed' => pathb.to_s
  } } }
  [[CiScope::FULL_JOBS, full], [CiScope::PATHB_JOBS, pathb]].each do |names, enabled|
    names.each { |name| needs[name] = { 'result' => enabled ? 'success' : 'skipped' } }
  end
  needs
end

[[true, true], [true, false], [false, false]].each do |full, pathb|
  original = outcomes(full, pathb)
  check.call("valid gate #{full}/#{pathb}") { CiScope.validate(original); true }
  original.each_key do |name|
    ['failure', 'cancelled', 'skipped', 'success', nil].each do |status|
      next if status == original[name]['result']

      needs = Marshal.load(Marshal.dump(original))
      needs[name]['result'] = status
      rejects.call("gate #{full}/#{pathb}: #{name} #{status.inspect}") { CiScope.validate(needs) }
    end
    needs = Marshal.load(Marshal.dump(original))
    needs.delete(name)
    rejects.call("missing #{name}") { CiScope.validate(needs) }
  end
end

%w[full_ci changed].each do |key|
  ['', 'unknown', nil, true].each do |value|
    needs = outcomes(true, true)
    needs['pathb-changes']['outputs'][key] = value
    rejects.call("invalid #{key}=#{value.inspect}") { CiScope.validate(needs) }
  end
end
rejects.call('inconsistent selection') { CiScope.validate(outcomes(false, true)) }

env = { 'NEEDS_JSON' => JSON.generate(outcomes(false, false)) }
_, error, status = Open3.capture3(env, RbConfig.ruby, SCRIPT, '--gate')
check.call('gate CLI accepts authorized skips') { status.success? && error.empty? }
needs = outcomes(true, true)
needs['test']['result'] = 'cancelled'
env['NEEDS_JSON'] = JSON.generate(needs)
_, error, status = Open3.capture3(env, RbConfig.ruby, SCRIPT, '--gate')
check.call('gate CLI rejects cancellation') do
  !status.success? && error.include?('test: expected success, got "cancelled"')
end

Dir.mktmpdir('ci-scope') do |directory|
  git = lambda do |*args|
    output, error, status = Open3.capture3(
      'git', '-c', 'user.name=CI', '-c', 'user.email=ci@example.invalid',
      '-c', 'commit.gpgsign=false', *args, chdir: directory
    )
    abort error unless status.success?
    output.strip
  end
  git.call('init')
  FileUtils.mkdir_p(File.join(directory, 'be'))
  File.write(File.join(directory, 'be/original.cpp'), "compiler code\n")
  git.call('add', '.')
  git.call('commit', '-qm', 'base')
  base = git.call('rev-parse', 'HEAD')
  FileUtils.mkdir_p(File.join(directory, 'docs'))
  File.rename(File.join(directory, 'be/original.cpp'), File.join(directory, "docs/new\nname.md"))
  git.call('add', '-A')
  git.call('commit', '-qm', 'rename')
  Dir.chdir(directory) do
    paths = CiScope.changed_paths(base)
    check.call('rename reports both names with newline preserved') do
      paths.sort == ['be/original.cpp', "docs/new\nname.md"].sort
    end
    check.call('rename into docs retains general coverage') do
      CiScope.select('pull_request', paths)['full_ci'] == 'true'
    end
    output_path = File.join(directory, 'outputs')
    env = { 'BASE' => base, 'GITHUB_EVENT_NAME' => 'pull_request', 'GITHUB_OUTPUT' => output_path }
    _, error, status = Open3.capture3(env, RbConfig.ruby, SCRIPT)
    check.call('selector CLI writes both outputs') do
      status.success? && error.empty? && File.read(output_path) == "full_ci=true\nchanged=true\n"
    end
    check.call('missing base fails the diff') do
      begin
        CiScope.changed_paths('missing-base')
        false
      rescue CiScope::DiffError
        true
      end
    end
  end
end

puts "CI scope: #{checks} checks passed"
