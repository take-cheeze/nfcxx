# frozen_string_literal: true

require 'shellwords'
require_relative 'compiled_gems'
require_relative 'nomethod_reviewed'
require_relative 'nomethod_reviewed_probe'

# docs/adr/0466: bc2cpp compiles closed-world programs only, so every run names its build, the build's gem list and
# the outside native and Ruby sources. This is the closed world the checks and tools compile a fixture or a
# probe in: the real closed gem list, the core and gem natives, and every foreign mrblib. `env` wins over these
# defaults, except a nil for one of the four closed-world inputs, which keeps the default (a run cannot drop one).
# Fixture-owned sites are outside the reviewed scope (review_scope.rb); the real gems are judged.
# Not bc2cpp_closed_world_env (compiled_gems.rb): that one derives the same inputs from a real build's spec.
def bc2cpp_closed_world_probe_env(env = {}, root = File.expand_path('../..', __dir__))
  natives = Dir["#{root}/mruby-rgss/src/*.cxx"] + core_native_srcs("#{root}/3rd/mruby") + external_gem_native_srcs(root)
  base = {
    'NATIVE_SRCS' => Shellwords.join(natives),
    'FOREIGN_RUBY_SRCS' => Shellwords.join(foreign_mrblib_srcs(root)),
    'BC2CPP_BUILD_NAME' => 'closed',
    'BC2CPP_BUILD_GEMS' => Shellwords.join(NomethodReviewedProbe.closed_gems(root).map { |n, d| "#{n}=#{d}" }),
  }
  required = %w[NATIVE_SRCS FOREIGN_RUBY_SRCS BC2CPP_BUILD_NAME BC2CPP_BUILD_GEMS]
  base.merge(env) { |key, default, given| given.nil? && required.include?(key) ? default : given }
end
