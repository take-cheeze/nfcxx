#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'open3'
require 'yaml'

# Select CI coverage and validate the required aggregate check.
module CiScope
  # These trees have their own bc2cpp jobs (ci.yml, bc2cpp-changes). Every unlisted path keeps
  # the general compiler suites enabled; Markdown under docs is isolated too.
  ISOLATED_PREFIXES = %w[bc2cpp/ tests/bc2cpp/].freeze
  # Preserve the Path B selection, including all scripts and runtime code.
  # Byte matching and absolute anchors also handle unusual git filenames.
  PATHB = %r{\A(?:be/|3rd/(?:edg|qbe|cproc)\z|scripts/|nfcc/|lib/|tests/run\.sh\z|
    tests/realworld/|\.github/actions/|
    tests/(?:pathb/|pathb-|wasm/|sycl/|mruby/|cases/|cpp-features/|ehshim/|safeptr/)|
    tools/(?:pathb-spirv-emit|qbe-prep)/|nfcxx\z|\.github/workflows/ci\.yml\z|\.github/ci-test-matrix\.yml\z)}nx
  FULL_JOBS = %w[build test arm-build arm-test macos-suites mrustc].freeze
  PATHB_JOBS = %w[pathb-build pathb-test].freeze

  # The entries of the `test` job's matrix (ci.yml), one job each. An entry with `gcc_only: true` runs the gcc backend only, which
  # is for pushes to main (GCC_BACKEND in ci.yml): without gcc it is left out, so that leg never starts. The flag itself is not
  # passed on (the steps read the other keys as matrix.<key>).
  TEST_MATRIX = File.expand_path('../.github/ci-test-matrix.yml', __dir__)

  class DiffError < StandardError; end

  module_function

  def select(event, paths)
    full = event != 'pull_request' || paths.empty? || paths.any? do |path|
      !path.start_with?(*ISOLATED_PREFIXES) && !(path.start_with?('docs/') && path.end_with?('.md'))
    end
    { 'full_ci' => full.to_s,
      'changed' => (paths.empty? || paths.any? { |path| PATHB.match?(path) }).to_s }
  end

  def test_matrix(entries, gcc)
    entries.reject { |entry| entry['gcc_only'] && !gcc }.map { |entry| entry.reject { |key, _| key == 'gcc_only' } }
  end

  # The gcc backend runs on pushes to main (and manual runs of main); GITHUB_REF is set by Actions, and absent in a local run.
  def gcc?(env)
    ref = env['GITHUB_REF'].to_s
    ref.empty? || ref == 'refs/heads/main'
  end

  def changed_paths(base)
    # Include both sides of renames: moving compiler code into docs is still
    # a compiler change. NUL separation preserves spaces and newlines.
    output, error, status = Open3.capture3('git', 'diff', '--no-renames', '--name-only', '-z', base, 'HEAD',
                                          binmode: true)
    raise DiffError, error.strip unless status.success?

    output.split("\0")
  end

  def validate(needs, jobs = nil)
    selection = needs.fetch('pathb-changes', {})
    raise ArgumentError, 'CI selection did not succeed' unless selection['result'] == 'success'

    outputs = selection.fetch('outputs', {})
    full, pathb = outputs.values_at('full_ci', 'changed')
    unless [full, pathb].all? { |value| %w[true false].include?(value) }
      raise ArgumentError, 'CI selection outputs are missing or invalid'
    end
    if full == 'false' && pathb == 'true'
      raise ArgumentError, 'Path B coverage cannot run without general compiler coverage'
    end

    [[FULL_JOBS, full], [PATHB_JOBS, pathb]].each do |names, enabled|
      expected = enabled == 'true' ? 'success' : 'skipped'
      names.each do |name|
        actual = needs.fetch(name, {})['result']
        raise ArgumentError, "#{name}: expected #{expected}, got #{actual.inspect}" unless actual == expected
      end
    end
    return unless full == 'true'

    legs = expected_legs(outputs['test_matrix'])
    validate_legs(legs, jobs) if jobs
  end

  # The legs of the `test` job that this run was to start: the names in the `test_matrix` output of the selection step (the entries
  # of .github/ci-test-matrix.yml that apply to this ref; the job is named after each entry).
  def expected_legs(text)
    entries = JSON.parse(text.to_s)
    names = entries.is_a?(Array) ? entries.map { |entry| entry.is_a?(Hash) ? entry['name'] : nil } : []
    if names.empty? || names.any? { |name| !name.is_a?(String) || name.empty? } || names.uniq.length != names.length
      raise ArgumentError, 'CI selection test_matrix is missing, empty, or has unnamed or repeated legs'
    end

    names
  rescue JSON::ParserError
    raise ArgumentError, 'CI selection test_matrix is not JSON'
  end

  # Every expected leg ran in this run and succeeded. The result of the `test` job alone would also pass a matrix that had lost a
  # leg (a selection that left out an entry it should have kept); `jobs` is the run's job list, [{name, conclusion}, ...].
  def validate_legs(names, jobs)
    raise ArgumentError, 'the job list of this run is not a list' unless jobs.is_a?(Array)

    names.each do |name|
      runs = jobs.select { |job| job.is_a?(Hash) && job['name'] == name }
      raise ArgumentError, "test leg #{name.inspect}: it did not run" if runs.empty?

      bad = runs.find { |job| job['conclusion'] != 'success' }
      raise ArgumentError, "test leg #{name.inspect}: expected success, got #{bad['conclusion'].inspect}" if bad
    end
  end

  def main(args = ARGV, env = ENV)
    case args
    when ['--gate']
      needs = JSON.parse(env.fetch('NEEDS_JSON'))
      file = env.fetch('JOBS_FILE', '')
      jobs = file.empty? ? nil : JSON.parse(File.read(file))
      validate(needs, jobs)
      # With general coverage selected the legs are checked, so a run without its job list cannot pass (it fails closed).
      if jobs.nil? && needs.dig('pathb-changes', 'outputs', 'full_ci') == 'true'
        raise ArgumentError, 'the job list of this run (JOBS_FILE) is missing'
      end

      puts 'Every selected CI job and test leg passed; unselected jobs were skipped'
    when []
      base = env.fetch('BASE', '')
      paths = base.empty? || base.match?(/\A0+\z/) ? [] : changed_paths(base)
      selected = select(env.fetch('GITHUB_EVENT_NAME', ''), paths)
      selected['test_matrix'] = JSON.generate(test_matrix(YAML.safe_load_file(TEST_MATRIX), gcc?(env)))
      text = selected.map { |key, value| "#{key}=#{value}\n" }.join
      print text
      File.open(env.fetch('GITHUB_OUTPUT'), 'a') { |output| output.write(text) }
    else
      raise ArgumentError, 'usage: ci-scope.rb [--gate]'
    end
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    CiScope.main
  rescue ArgumentError, KeyError, JSON::ParserError, CiScope::DiffError => error
    abort error.message
  end
end
