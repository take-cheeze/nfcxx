# frozen_string_literal: true

require 'open3'

# CRUBY_JIT_RUNS: the CRuby side of compiled_run.rb's comparison, with its JIT state explicit. CRuby runs once as the
# plain interpreter (RUBY_YJIT_ENABLE=0, plus --disable=jit when that Ruby accepts it) and once with --yjit when that
# Ruby has YJIT, so a ratio never silently compares against whatever the calling shell enabled.
# OPTCARROT_CRUBY_YJIT=0 skips the YJIT run.
module CRubyRuns
  INTERPRETER_LABEL = 'CRuby (interpreter)'
  YJIT_LABEL = 'CRuby + YJIT'

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
    runs
  end

  # RUBY_DESCRIPTION as that run sees it ("+YJIT" appears when YJIT is on).
  def description(ruby, run)
    out, status = Open3.capture2e(run[:env], ruby, *run[:args], '-e', 'print RUBY_DESCRIPTION')
    status.success? ? out.strip : "unknown (#{out.strip})"
  end

  # Wall-time ratio lines for the summary: every non-CRuby row against every CRuby row, then bc2cpp against the
  # mruby interpreter. `results` are compiled_run.rb's benchmark hashes ({label:, seconds:}).
  def ratio_lines(results)
    cruby = results.select { |r| [INTERPRETER_LABEL, YJIT_LABEL].include?(r[:label]) }
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
