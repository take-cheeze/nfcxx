#!/usr/bin/env ruby
# frozen_string_literal: true

require 'tmpdir'
require 'fileutils'
require 'rbconfig'
require 'yaml'
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
   .github/workflows/ci.yml .github/ci-test-matrix.yml].each do |path|
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

# The `test` job's matrix (.github/ci-test-matrix.yml): gcc-only entries exist only where the gcc backend runs.
matrix = YAML.safe_load_file(CiScope::TEST_MATRIX)
names = matrix.map { |entry| entry['name'] }
check.call('matrix entries have a name and a run') { matrix.all? { |entry| entry['name'] && entry['run'] } }
check.call('matrix names are unique') { names.uniq == names }
check.call('entries named (gcc backend) are gcc_only') do
  matrix.all? { |entry| entry['gcc_only'] || !entry['name'].include?('(gcc backend)') }
end
check.call('there are gcc-only entries') { matrix.any? { |entry| entry['gcc_only'] } }
with_gcc = CiScope.test_matrix(matrix, true)
without = CiScope.test_matrix(matrix, false)
check.call('with gcc every entry is kept') { with_gcc.map { |entry| entry['name'] } == names }
check.call('without gcc the gcc-only entries are left out') do
  without.map { |entry| entry['name'] } == matrix.reject { |entry| entry['gcc_only'] }.map { |entry| entry['name'] }
end
check.call('the gcc_only flag is not passed on') { (with_gcc + without).none? { |entry| entry.key?('gcc_only') } }
check.call('other keys are kept') { with_gcc.zip(matrix).all? { |kept, entry| kept == entry.reject { |key, _| key == 'gcc_only' } } }
{ 'refs/heads/main' => true, 'refs/pull/7/merge' => false, 'refs/heads/other' => false, '' => true }.each do |ref, want|
  check.call("gcc backend for GITHUB_REF #{ref.inspect}") { CiScope.gcc?({ 'GITHUB_REF' => ref }) == want }
end
check.call('gcc backend when GITHUB_REF is unset (local run)') { CiScope.gcc?({}) }
workflow = File.read(File.expand_path('../../.github/workflows/ci.yml', __dir__))
check.call('ci.yml takes the test matrix from the selection step') do
  workflow.include?('fromJSON(needs.pathb-changes.outputs.test_matrix)') && workflow.include?('test_matrix: ${{ steps.paths.outputs.test_matrix }}')
end
check.call('ci.yml has no gcc_only gating (comments aside)') do
  workflow.lines.reject { |line| line.lstrip.start_with?('#') }.none? { |line| line.include?('gcc_only') }
end

# The Ruby scripts the bc2cpp worlds compile are triggers of the bc2cpp workflow: a change to one is a change to its world, and a
# script that the interpreter takes but the compiled build does not (a backtick, ENV, a regexp) must not reach main unchecked.
# Every scripts/NAME.rb that a tests/bc2cpp/run_*.sh names has to be in the push and pull_request paths, and every script in them
# has to be one a run script names.
repo = File.expand_path('../..', __dir__)
world_scripts = Dir[File.join(repo, 'tests/bc2cpp/run_*.sh')].flat_map do |file|
  File.read(file).scan(%r{(?<![\w/.-])scripts/([A-Za-z0-9_-]+\.rb)}).flatten
end.uniq.select { |name| File.file?(File.join(repo, 'scripts', name)) }.sort
ci_workflow = YAML.safe_load(workflow)
bc2cpp_filter = YAML.safe_load(ci_workflow.fetch('jobs').fetch('bc2cpp-changes').fetch('steps')
                                          .map { |step| step.fetch('with', {})['filters'] }.compact.first)
listed = bc2cpp_filter.fetch('bc2cpp').grep(%r{\Ascripts/[^*/]+\.rb\z}).map { |path| path.delete_prefix('scripts/') }
check.call('bc2cpp worlds name scripts') { world_scripts.length > 10 }
check.call("bc2cpp paths include every script a world compiles (#{(world_scripts - listed).join(' ')})") { (world_scripts - listed).empty? }
check.call("bc2cpp paths name only scripts a world compiles (#{(listed - world_scripts).join(' ')})") { (listed - world_scripts).empty? }

LEGS = ['cases (QBE and gcc backends)', 'uop core and numpy (QBE backend)'].freeze

def outcomes(full, pathb)
  needs = { 'pathb-changes' => { 'result' => 'success', 'outputs' => {
    'full_ci' => full.to_s, 'changed' => pathb.to_s,
    'test_matrix' => JSON.generate(LEGS.map { |name| { 'name' => name, 'run' => 'true' } })
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

# The legs of the test matrix: each leg the selection names must have run in this run and succeeded.
jobs_of = ->(conclusions = {}) { LEGS.map { |name| { 'name' => name, 'conclusion' => conclusions.fetch(name, 'success') } } + [{ 'name' => 'build', 'conclusion' => 'success' }] }
check.call('gate accepts every leg succeeding') { CiScope.validate(outcomes(true, true), jobs_of.call); true }
check.call('gate without a job list checks the jobs only') { CiScope.validate(outcomes(true, true)); true }
check.call('gate accepts the legs of a run that left general coverage out') { CiScope.validate(outcomes(false, false), []); true }
LEGS.each do |leg|
  %w[failure cancelled skipped].each do |conclusion|
    rejects.call("leg #{leg}: #{conclusion}") { CiScope.validate(outcomes(true, true), jobs_of.call(leg => conclusion)) }
  end
  rejects.call("leg #{leg}: no conclusion yet") { CiScope.validate(outcomes(true, true), jobs_of.call(leg => nil)) }
  rejects.call("leg #{leg}: did not run") { CiScope.validate(outcomes(true, true), jobs_of.call.reject { |job| job['name'] == leg }) }
end
check.call('a leg that ran twice passes only when every run passed') do
  jobs = jobs_of.call + [{ 'name' => LEGS.first, 'conclusion' => 'failure' }]
  begin
    CiScope.validate(outcomes(true, true), jobs)
    false
  rescue ArgumentError
    true
  end
end
rejects.call('an empty job list') { CiScope.validate(outcomes(true, true), []) }
rejects.call('a job list that is not a list') { CiScope.validate(outcomes(true, true), { 'jobs' => [] }) }
[nil, '', 'not json', '[]', '{}', '[{"run":"x"}]', '[{"name":""}]', '[{"name":"a"},{"name":"a"}]', '[1]'].each do |value|
  needs = outcomes(true, true)
  needs['pathb-changes']['outputs']['test_matrix'] = value
  rejects.call("invalid test_matrix #{value.inspect}") { CiScope.validate(needs, jobs_of.call) }
end
check.call('test_matrix is not read when general coverage is left out') do
  needs = outcomes(false, false)
  needs['pathb-changes']['outputs'].delete('test_matrix')
  CiScope.validate(needs)
  true
end

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

Dir.mktmpdir('ci-scope-gate') do |directory|
  file = File.join(directory, 'jobs.json')
  gate = lambda do |needs, jobs|
    env = { 'NEEDS_JSON' => JSON.generate(needs), 'JOBS_FILE' => jobs.nil? ? '' : file }
    File.write(file, JSON.generate(jobs)) unless jobs.nil?
    Open3.capture3(env, RbConfig.ruby, SCRIPT, '--gate')
  end
  _, error, status = gate.call(outcomes(true, true), jobs_of.call)
  check.call('gate CLI accepts every selected job and leg') { status.success? && error.empty? }
  _, error, status = gate.call(outcomes(true, true), jobs_of.call(LEGS.last => 'failure'))
  check.call('gate CLI rejects a failed leg') { !status.success? && error.include?("test leg #{LEGS.last.inspect}: expected success") }
  _, error, status = gate.call(outcomes(true, true), jobs_of.call.reject { |job| job['name'] == LEGS.first })
  check.call('gate CLI rejects a leg that did not run') { !status.success? && error.include?("test leg #{LEGS.first.inspect}: it did not run") }
  _, error, status = gate.call(outcomes(true, true), nil)
  check.call('gate CLI rejects a run without its job list') { !status.success? && error.include?('the job list of this run (JOBS_FILE) is missing') }
  _, error, status = gate.call(outcomes(false, false), nil)
  check.call('gate CLI needs no job list when general coverage is left out') { status.success? && error.empty? }
end

workflow_gate = workflow[/^  build-and-test:.*?(?=^  \S)/m].to_s
check.call('ci.yml lists the jobs of the run for the gate') do
  workflow_gate.include?('actions: read') && workflow_gate.include?('filter=latest') && workflow_gate.include?('JOBS_FILE: ${{ runner.temp }}/jobs.json')
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
      status.success? && error.empty? && File.read(output_path).lines.first(2) == ["full_ci=true\n", "changed=true\n"] &&
        File.read(output_path).lines[2].to_s.start_with?('test_matrix=[')
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
