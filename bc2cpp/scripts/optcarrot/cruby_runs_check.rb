#!/usr/bin/env ruby
# frozen_string_literal: true

# CRUBY_JIT_RUNS / TRUFFLERUBY_RUN (tools/optcarrot_probe/cruby_runs.rb): which reference runs compiled_run.rb makes,
# with a stub probe so no real Ruby is started, the wall-time ratio lines over them, and HOT_PATH_FPS.

require_relative '../../tools/optcarrot_probe/cruby_runs'

failures = 0
check = lambda do |label, ok|
  puts "  #{ok ? 'ok  ' : 'FAIL'} #{label}"
  failures += 1 unless ok
end

with_yjit = ->(_ruby, _args, _script, _env) { true }
no_jit = ->(_ruby, args, _script, _env) { !args.include?('--yjit') }

plan = CRubyRuns.plan('ruby', env: {}, probe: with_yjit)
check.call('a Ruby with YJIT gets the interpreter and the YJIT run',
           plan.map { |r| r[:label] } == [CRubyRuns::INTERPRETER_LABEL, CRubyRuns::YJIT_LABEL])
check.call('a Ruby without YJIT gets the interpreter run only',
           CRubyRuns.plan('ruby', env: {}, probe: no_jit).map { |r| r[:label] } == [CRubyRuns::INTERPRETER_LABEL])
check.call('OPTCARROT_CRUBY_YJIT=0 skips the YJIT run',
           CRubyRuns.plan('ruby', env: { 'OPTCARROT_CRUBY_YJIT' => '0' }, probe: with_yjit).size == 1)

truffle = CRubyRuns.plan('ruby', env: { 'OPTCARROT_TRUFFLERUBY' => '/opt/tr/bin/ruby' }, probe: with_yjit).last
check.call('OPTCARROT_TRUFFLERUBY adds a TruffleRuby run with its own binary',
           truffle[:label] == CRubyRuns::TRUFFLERUBY_LABEL && truffle[:ruby] == '/opt/tr/bin/ruby')
check.call('the TruffleRuby run clears the Bundler environment',
           %w[RUBYOPT RUBYLIB GEM_HOME GEM_PATH BUNDLE_GEMFILE].all? { |k| truffle[:env].key?(k) && truffle[:env][k].nil? })
check.call('an empty OPTCARROT_TRUFFLERUBY adds nothing',
           CRubyRuns.plan('ruby', env: { 'OPTCARROT_TRUFFLERUBY' => '' }, probe: with_yjit).size == 2)

results = [
  { label: CRubyRuns::INTERPRETER_LABEL, seconds: 4.0 }, { label: CRubyRuns::YJIT_LABEL, seconds: 1.0 },
  { label: CRubyRuns::TRUFFLERUBY_LABEL, seconds: 2.0 }, { label: 'mruby interpreter', seconds: 8.0 },
  { label: 'mruby + bc2cpp (sealed)', seconds: 1.5 }
]
lines = CRubyRuns.ratio_lines(results)
check.call('bc2cpp is compared against TruffleRuby too',
           lines.any? { |l| l.include?('mruby + bc2cpp (sealed)/TruffleRuby 0.75x') })
check.call('bc2cpp against the interpreter is still the last line', lines.last == 'bc2cpp/mruby interpreter 0.19x.')

check.call('the warmup run defaults to a tenth of the frames', CRubyRuns.warmup_frames(1800, env: {}) == 180)
check.call('OPTCARROT_WARMUP_FRAMES sets the warmup run',
           CRubyRuns.warmup_frames(1800, env: { 'OPTCARROT_WARMUP_FRAMES' => '300' }) == 300)
check.call('OPTCARROT_WARMUP_FRAMES=0 skips the warmup run',
           CRubyRuns.warmup_frames(1800, env: { 'OPTCARROT_WARMUP_FRAMES' => '0' }).nil?)
check.call('a warmup no shorter than the full run is skipped',
           CRubyRuns.warmup_frames(180, env: { 'OPTCARROT_WARMUP_FRAMES' => '180' }).nil? &&
             CRubyRuns.warmup_frames(5, env: {}).nil?)
check.call('a negative OPTCARROT_WARMUP_FRAMES is refused',
           begin
             CRubyRuns.warmup_frames(1800, env: { 'OPTCARROT_WARMUP_FRAMES' => '-1' })
             false
           rescue ArgumentError
             true
           end)
check.call('hot-path fps subtracts the short run', (CRubyRuns.hot_fps(1800, 9.45, 180, 2.91) - 247.7).abs < 0.1)
check.call('a short run no faster than the full one gives no hot-path fps', CRubyRuns.hot_fps(200, 1.0, 20, 1.0).nil?)

if failures.zero?
  puts 'cruby_runs_check: all checks passed'
else
  puts "cruby_runs_check: #{failures} check(s) failed"
  exit 1
end
