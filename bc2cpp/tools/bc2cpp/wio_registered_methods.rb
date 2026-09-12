#!/usr/bin/env ruby
# frozen_string_literal: true

# Real, no-duplication source of "what did this *-compiled gem's own real
# build actually register a C++ override for" -- consumed by
# strip_wio_bc2cpp_stubs.rb (via build_config.rb's wio_strip_bc2cpp_stubs)
# to know exactly which methods it may safely strip the interpreted
# bytecode body of. See docs/adr/0144 for the full design and measured
# result.
#
# Runs the *exact same* bc2cpp.rb invocation that gem's own mrbgem.rake
# performs for its real ONLY_OWNERS/OTHER_OWNERS/NATIVE_SRCS/closed-world
# source set (built from the very same compiled_gems.rb helpers --
# BC2CPP_COMPILED_GEMS, closed_world_mrblib_srcs, core_native_srcs,
# external_gem_native_srcs -- that mrbgem.rake itself calls, required
# below rather than re-typed), then parses ONLY bc2cpp.rb's own real,
# already-trustworthy "== compiled entry points ==" stderr diagnostic.
# This file never re-derives a MONO/POLY, visibility, arity, or embedding
# decision on its own -- doing so would risk silently drifting from
# bc2cpp.rb's own registry logic (build_registry) the moment a future
# round changes what compiles, exactly the duplication docs/adr/0144's own
# design explicitly rules out. A hand-copied `owners:` array (from
# compiled_gems.rb directly) would only give the *candidate* owner list --
# not the real, final per-method registration (which methods within that
# owner actually compiled clean, their real arity, visibility, and
# whether they are secretly a `.singleton` pseudo-owner) bc2cpp.rb itself
# decides only after really walking the bytecode.
#
# Usage: ruby wio_registered_methods.rb <gem-name> <repo-root> <mrbc-path>
# Prints one TSV line per real registered method to stdout:
#   owner<TAB>name<TAB>arity<TAB>visibility<TAB>singleton(0|1)
# `owner` is bc2cpp.rb's own owner label verbatim, including a trailing
# ".singleton" where present, so a consumer can decide for itself whether
# to touch a singleton-owned entry (today, strip_wio_bc2cpp_stubs.rb
# always refuses one -- see that file's own comment on why DEFS/SCLASS
# span-finding is out of scope for this round's bounded proof).

require 'open3'
require 'shellwords'
require 'tmpdir'
require_relative 'compiled_gems'

gem_name, repo_root, mrbc = ARGV
unless gem_name && repo_root && mrbc
  raise ArgumentError, "usage: #{$PROGRAM_NAME} <gem-name> <repo-root> <mrbc-path>"
end

this_gem = BC2CPP_COMPILED_GEMS.fetch(gem_name) do
  raise "wio_registered_methods: no such compiled gem #{gem_name.inspect} in " \
        'tools/bc2cpp/compiled_gems.rb'
end
other_gems = BC2CPP_COMPILED_GEMS.reject { |name, _| name == gem_name }
target_owners = this_gem[:owners]
other_owners = other_gems.values.flat_map { |g| g[:owners] }
closed_world_srcs = closed_world_mrblib_srcs(repo_root)
# mruby-rgss/src/*.cxx is the one closed-world native source every
# *-compiled gem's own mrbgem.rake feeds in today (see e.g.
# mruby-rpg2k-compiled/mrbgem.rake's own NATIVE_SRCS computation) --
# mirrored verbatim here rather than reading it back out of any one
# gem's own mrbgem.rake, so this script has no Rake/mrbgem.rake
# dependency of its own.
native_srcs = Dir["#{repo_root}/mruby-rgss/src/*.cxx"] + core_native_srcs("#{repo_root}/3rd/mruby") +
              external_gem_native_srcs(repo_root)

bc2cpp = File.expand_path('bc2cpp.rb', __dir__)

Dir.mktmpdir('bc2cpp_registered_probe') do |tmp|
  env = {
    'MRBC' => mrbc,
    'OUT_SYMBOL' => 'wio_registered_probe',
    'OUT_DIR' => tmp,
    'ONLY_OWNERS' => target_owners.join(','),
    'OTHER_OWNERS' => other_owners.join(','),
    'NATIVE_SRCS' => Shellwords.join(native_srcs),
    'SKIP_UNSUPPORTED' => '1',
  }
  cmd = [RbConfig.ruby, bc2cpp, *closed_world_srcs]
  _out, err, status = Open3.capture3(env, *cmd)
  unless status.success?
    warn err
    raise "wio_registered_methods: #{gem_name}'s own bc2cpp.rb run failed (see stderr above)"
  end

  in_section = false
  err.each_line do |line|
    if line.start_with?('== compiled entry points ==')
      in_section = true
      next
    elsif line.start_with?('==')
      in_section = false
      next
    end
    next unless in_section

    m = line.match(/\(([^#]+)#([^,]+), arity (\d+)\)(.*)$/)
    next unless m

    owner, name, arity, rest = m.captures
    visibility =
      if rest.include?('[private')
        'private'
      elsif rest.include?('[protected')
        'protected'
      else
        'public'
      end
    singleton = owner.end_with?('.singleton') ? '1' : '0'
    puts [owner, name, arity, visibility, singleton].join("\t")
  end
end
