#!/usr/bin/env ruby
# frozen_string_literal: true

# The bc2cpp-self build kind (tools/bc2cpp/compiled_gems.rb; docs/bc2cpp-self-compile.md, step 3):
#
#   - the runner's gem list (host-libs/mruby-bc2cpp-runner/build_config.rb, minus the build-time gems) is accepted;
#   - BC2CPP_SELF_GEMS matches that build_config, so the two cannot drift apart;
#   - a gem missing from the list is named; each open-world gem, mruby-compiler and any mruby-bin-* is refused;
#   - the other kinds are unchanged: closed still wants the engine gems and refuses the same open-world gems, an unknown
#     kind is still refused, and the new kind is not an engine build for the review scope.
#
# Usage: ruby scripts/bc2cpp/self_build_kind_check.rb

require_relative '../../tools/bc2cpp/world_root'
require_relative 'check_support'
require_relative '../../tools/bc2cpp/compiled_gems'
require_relative '../../tools/bc2cpp/review_scope'

suite = FixtureCheck.new('self_build_kind_check')
ROOT = BC2CPP_WORLD_ROOT
KIND = 'bc2cpp-self'

def violations(kind, names)
  bc2cpp_closed_world_violations(kind, names.to_h { |n| [n, "/gems/#{n}"] }, ROOT, host_srcs: [])
end

# The gem names the runner build_config.rb lists, without the build-time gems (the bin gems and the compiler, which the
# executable does not link) and without the runner script gem itself.
config = File.read(File.join(BC2CPP_TREE_ROOT, 'host-libs/mruby-bc2cpp-runner/build_config.rb'))
listed = config.scan(/conf\.gem core: '(mruby-[a-z0-9-]+)'/).flatten +
         config.scan(/%w\[([^\]]+)\]/m).flat_map { |(words)| words.split } +
         config.scan(%r{conf\.gem File\.join\((?:BC2CPP_TREE_)?ROOT, '(?:[a-z0-9-]+/)(mruby-[a-z0-9-]+)'\)}).flatten
runner_gems = (listed - %w[mruby-bin-mruby mruby-bin-mrbc mruby-compiler mruby-bc2cpp-runner]).uniq

suite.check('the self kind is a closed-world build', BC2CPP_CLOSED_WORLD_BUILDS.include?(KIND))
suite.check('the existing kinds are still listed', %w[closed optcarrot-probe wio].all? { |k| BC2CPP_CLOSED_WORLD_BUILDS.include?(k) })
# mruby-env is not listed in the runner's build_config: mruby-bc2cpp-sources depends on it.
DEPENDENCY_ONLY = %w[mruby-env].freeze
suite.check('BC2CPP_SELF_GEMS is the runner build_config minus its build-time gems, plus its dependency-only gems',
            BC2CPP_SELF_GEMS.sort == (runner_gems + DEPENDENCY_ONLY).sort)
suite.check('the dependency-only gems are declared by mruby-bc2cpp-sources',
            DEPENDENCY_ONLY.all? { |g| File.read(File.join(BC2CPP_TREE_ROOT, 'host-libs/mruby-bc2cpp-sources/mrbgem.rake')).include?("'#{g}'") })

suite.check('the runner gem list is accepted', violations(KIND, BC2CPP_SELF_GEMS).empty?)
suite.check('the optional C main is accepted when present',
            violations(KIND, BC2CPP_SELF_GEMS + ['mruby-bc2cpp-main']).empty?)

missing = BC2CPP_SELF_GEMS - ['mruby-marshal']
suite.check('a missing gem is named',
            violations(KIND, missing).any? { |e| e.include?('gem list lacks') && e.include?('mruby-marshal') })

BC2CPP_OPEN_WORLD_GEMS.each do |gem|
  suite.check("#{gem} is refused", violations(KIND, BC2CPP_SELF_GEMS + [gem]).any? { |e| e.include?(gem) })
end
%w[mruby-compiler mruby-bin-mruby mruby-bin-mrbc mruby-bin-strip].each do |gem|
  suite.check("#{gem} is refused", violations(KIND, BC2CPP_SELF_GEMS + [gem]).any? { |e| e.include?(gem) })
end
suite.check('each refused gem is reported once',
            violations(KIND, BC2CPP_SELF_GEMS + %w[mruby-bin-mruby]).count { |e| e.include?('mruby-bin-mruby') } == 1)

engine = BC2CPP_CLOSED_WORLD_GEMS
suite.check('closed still wants the engine gems', violations('closed', BC2CPP_SELF_GEMS).any? { |e| e.include?('gem list lacks') })
suite.check('closed accepts the engine gems', violations('closed', engine).empty?)
suite.check('closed still refuses mruby-eval', violations('closed', engine + ['mruby-eval']).any? { |e| e.include?('mruby-eval') })
suite.check('closed still accepts mruby-compiler without a host source', violations('closed', engine + ['mruby-compiler']).empty?)
suite.check('an unknown kind is refused', violations('unknown', engine).any? { |e| e.include?("build 'unknown' is not one of") })
suite.check('the self kind is not an engine build for the review scope', !ReviewScope::ENGINE_BUILDS.include?(KIND))
suite.check('the other kinds keep their review scope', ReviewScope::ENGINE_BUILDS.sort == %w[closed wio])

suite.finish!
