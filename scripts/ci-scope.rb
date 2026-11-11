#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'open3'

# Select CI coverage and validate the required aggregate check.
module CiScope
  # These trees have their own bc2cpp workflow. Every unlisted path keeps
  # the general compiler suites enabled; Markdown under docs is isolated too.
  ISOLATED_PREFIXES = %w[bc2cpp/ tests/bc2cpp/].freeze
  # Preserve the Path B selection, including all scripts and runtime code.
  # Byte matching and absolute anchors also handle unusual git filenames.
  PATHB = %r{\A(?:be/|3rd/(?:edg|qbe|cproc)\z|scripts/|nfcc/|lib/|tests/run\.sh\z|
    tests/realworld/|\.github/actions/|
    tests/(?:pathb/|pathb-|wasm/|sycl/|mruby/|cases/|cpp-features/|ehshim/|safeptr/)|
    tools/(?:pathb-spirv-emit|qbe-prep)/|nfcxx\z|\.github/workflows/ci\.yml\z)}nx
  FULL_JOBS = %w[build test arm-build arm-test macos-suites mrustc].freeze
  PATHB_JOBS = %w[pathb-build pathb-test].freeze

  class DiffError < StandardError; end

  module_function

  def select(event, paths)
    full = event != 'pull_request' || paths.empty? || paths.any? do |path|
      !path.start_with?(*ISOLATED_PREFIXES) && !(path.start_with?('docs/') && path.end_with?('.md'))
    end
    { 'full_ci' => full.to_s,
      'changed' => (paths.empty? || paths.any? { |path| PATHB.match?(path) }).to_s }
  end

  def changed_paths(base)
    # Include both sides of renames: moving compiler code into docs is still
    # a compiler change. NUL separation preserves spaces and newlines.
    output, error, status = Open3.capture3('git', 'diff', '--no-renames', '--name-only', '-z', base, 'HEAD',
                                          binmode: true)
    raise DiffError, error.strip unless status.success?

    output.split("\0")
  end

  def validate(needs)
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
  end

  def main(args = ARGV, env = ENV)
    case args
    when ['--gate']
      validate(JSON.parse(env.fetch('NEEDS_JSON')))
      puts 'Every selected CI job passed; unselected jobs were skipped'
    when []
      base = env.fetch('BASE', '')
      paths = base.empty? || base.match?(/\A0+\z/) ? [] : changed_paths(base)
      text = select(env.fetch('GITHUB_EVENT_NAME', ''), paths).map { |key, value| "#{key}=#{value}\n" }.join
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
