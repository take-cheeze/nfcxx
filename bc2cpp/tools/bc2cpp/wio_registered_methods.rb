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
#
# NEVER_CALLED_EXCLUSION: a compiled entry point that
# tools/bc2cpp/never_called_registrations.rb's own safety rule marks both
# never-called and safe to stop registering is left out of this TSV
# entirely, never printed as "registered" -- scripts/
# bc2cpp_prune_never_called_registrations.rb is what actually deletes such
# an entry's register.cxx line, and once that has run, compile_all can
# still happily recompile the method (bc2cpp.rb has no way to know
# register.cxx stopped calling it) while nothing installs a real C++
# override for it any more. Printing it here anyway would make
# strip_wio_bc2cpp_stubs.rb delete the one real implementation that
# method still has -- its own interpreted bytecode body -- for a live
# correctness regression on the narrow chance this file's own static
# analysis missed a real call site. The same filter this file's own
# probe run already needs for that exclusion is reused directly, rather
# than run twice: see never_called_registrations.rb's own header comment
# for why the exclusion itself is scoped the way it is.

require 'shellwords'
require_relative 'compiled_gems'
require_relative 'never_called_registrations'
require_relative 'static_dispatch_unregistered'

gem_name, repo_root, mrbc = ARGV
unless gem_name && repo_root && mrbc
  raise ArgumentError, "usage: #{$PROGRAM_NAME} <gem-name> <repo-root> <mrbc-path>"
end

err = NeverCalledRegistrations.run_bc2cpp(gem_name, repo_root, mrbc)
never_called = NeverCalledRegistrations.parse_never_called_names(err)

NeverCalledRegistrations.parse_compiled_entries(err).each do |m|
  key = "#{m[:owner]}##{m[:name]}"
  # A STATIC_DISPATCH_UNREGISTERED name (docs/adr/0203) stays in this list
  # even though nothing registers it: no runtime lookup can ever reach it, so
  # its bytecode `def` is dead in every build and still safe to strip.
  next if never_called.include?(key) && NeverCalledRegistrations.safe_to_unregister?(m[:owner]) &&
          !STATIC_DISPATCH_UNREGISTERED.include?(key)

  singleton = m[:owner].end_with?('.singleton') ? '1' : '0'
  puts [m[:owner], m[:name], m[:arity], m[:visibility], singleton].join("\t")
end
