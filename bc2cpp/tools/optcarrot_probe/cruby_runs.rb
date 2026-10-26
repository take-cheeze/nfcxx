# frozen_string_literal: true

require 'open3'

# CRUBY_JIT_RUNS: the CRuby side of compiled_run.rb's comparison, with its JIT state explicit. CRuby runs once as the
# plain interpreter (RUBY_YJIT_ENABLE=0, plus --disable=jit when that Ruby accepts it) and once with --yjit when that
# Ruby has YJIT, so a ratio never silently compares against whatever the calling shell enabled.
# OPTCARROT_CRUBY_YJIT=0 skips the YJIT run.
# TRUFFLERUBY_RUN: OPTCARROT_TRUFFLERUBY names a TruffleRuby `ruby` to time as one more reference, on the same bundle.
module CRubyRuns
  INTERPRETER_LABEL = 'CRuby (interpreter)'
  YJIT_LABEL = 'CRuby + YJIT'
  TRUFFLERUBY_LABEL = 'TruffleRuby'
  REFERENCE_LABELS = [INTERPRETER_LABEL, YJIT_LABEL, TRUFFLERUBY_LABEL].freeze
  # The runner runs under `bundle exec`; another Ruby must not load this Ruby's Bundler setup or gems.
  FOREIGN_RUBY_ENV = %w[RUBYOPT RUBYLIB GEM_HOME GEM_PATH BUNDLE_GEMFILE BUNDLE_BIN_PATH].to_h { |k| [k, nil] }.freeze

  module_function

  # Whether `ruby` accepts `args` and exits 0 for `script`; a probe that fails to start counts as false.
  def ruby_ok?(ruby, args, script, env = {})
    _out, status = Open3.capture2e(env, ruby, *args, '-e', script)
    status.success?
  rescue SystemCallError
    false
  end

  # The runs to make: [{label:, args:, env:}]. `probe` answers ruby_ok?-style questions, so the plan can be built
  # without a real Ruby.
  def plan(ruby, env: ENV, probe: method(:ruby_ok?))
    no_jit_flag = probe.call(ruby, ['--disable=jit'], 'exit 0', {}) ? ['--disable=jit'] : []
    runs = [{ label: INTERPRETER_LABEL, args: no_jit_flag, env: { 'RUBY_YJIT_ENABLE' => '0' } }]
    wanted = env.fetch('OPTCARROT_CRUBY_YJIT', '1') != '0'
    if wanted && probe.call(ruby, ['--yjit'], 'exit(defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled? ? 0 : 1)', {})
      runs << { label: YJIT_LABEL, args: ['--yjit'], env: { 'RUBY_YJIT_ENABLE' => '1' } }
    end
    truffle = env.fetch('OPTCARROT_TRUFFLERUBY', '')
    runs << { label: TRUFFLERUBY_LABEL, ruby: truffle, args: [], env: FOREIGN_RUBY_ENV } unless truffle.empty?
    runs
  end

  # RUBY_DESCRIPTION as that run sees it ("+YJIT" appears when YJIT is on). A run's own `ruby` wins over `ruby`.
  def description(ruby, run)
    # stdout only: TruffleRuby warns on stderr (about the locale, for one), which is not the description.
    out, err, status = Open3.capture3(run[:env], run[:ruby] || ruby, *run[:args], '-e', 'print RUBY_DESCRIPTION')
    status.success? ? out.strip : "unknown (#{(out + err).strip})"
  end

  # Wall-time ratio lines for the summary: every non-CRuby row against every CRuby row, then bc2cpp against the
  # mruby interpreter. `results` are compiled_run.rb's benchmark hashes ({label:, seconds:}).
  def ratio_lines(results)
    cruby = results.select { |r| REFERENCE_LABELS.include?(r[:label]) }
    interp = results.find { |r| r[:label] == 'mruby interpreter' }
    compiled = results.find { |r| r[:label].start_with?('mruby + bc2cpp') }
    lines = []
    [interp, compiled].compact.each do |row|
      parts = cruby.map { |c| format('%s/%s %.2fx', row[:label], c[:label], row[:seconds] / c[:seconds]) }
      lines << "#{parts.join('; ')}." unless parts.empty?
    end
    lines << format('bc2cpp/mruby interpreter %.2fx.', compiled[:seconds] / interp[:seconds]) if interp && compiled
    lines
  end
end
