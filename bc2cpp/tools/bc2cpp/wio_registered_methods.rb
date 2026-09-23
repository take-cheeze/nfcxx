#!/usr/bin/env ruby
# frozen_string_literal: true

# What a *-compiled gem's real build registers a C++ override for, consumed
# by strip_wio_bc2cpp_stubs.rb (via build_config.rb's wio_strip_bc2cpp_stubs)
# to decide which interpreted bytecode bodies it may strip (docs/adr/0144).
#
# Runs the exact bc2cpp.rb invocation the gem's mrbgem.rake performs (built
# from the same compiled_gems.rb helpers) and parses only its
# "== compiled entry points ==" diagnostic. It never re-derives MONO/POLY,
# visibility, arity or embedding itself, which would drift from bc2cpp.rb's
# build_registry; the owners list alone would not say which methods compiled.
#
# Usage: ruby wio_registered_methods.rb <gem-name> <repo-root> <mrbc-path>
# Prints one TSV line per real registered method to stdout:
#   owner<TAB>name<TAB>arity<TAB>visibility<TAB>singleton(0|1)
# `owner` is bc2cpp.rb's owner label verbatim, including a trailing
# ".singleton" (strip_wio_bc2cpp_stubs.rb refuses those).
#
# NEVER_CALLED_EXCLUSION: an entry never_called_registrations.rb marks
# never-called and safe to unregister is left out: once
# scripts/bc2cpp_prune_never_called_registrations.rb removes its register.cxx
# line, nothing installs the override any more, and stripping its bytecode
# `def` would delete the method's only implementation.

require 'shellwords'
require_relative 'compiled_gems'
require_relative 'never_called_registrations'
require_relative 'static_dispatch_unregistered'

module WioRegisteredMethods
  module_function

  # May strip_wio_bc2cpp_stubs.rb delete compiled entry `m`'s bytecode `def`?
  # An excluded method is not a compiled entry, so its bytecode always stays.
  def strippable?(m, installed:, never_called:, hot_only: false)
    key = "#{m[:owner]}##{m[:name]}"
    # INSTALLED_ONLY: "compiled" is not "installed". bc2cpp.rb lists every
    # method it can translate, but for an owner outside
    # BC2CPP_WIRED_EMBEDDINGS only the gem's hand-written register.cxx installs
    # the override, and it lags behind (RGSS::Audio.singleton's private
    # play_packed/find_encrypted_loose/... and
    # RGSS::Graphics.singleton#brightness_sprite compile but were never added
    # there). Stripping such a method's bytecode `def` left no implementation
    # at all -- a live "undefined method 'find_encrypted_loose' for Module" on
    # every sound effect. Only an entry some registration call really names
    # is printed.
    #
    # A STATIC_DISPATCH_UNREGISTERED name (docs/adr/0203) stays in this list
    # even though nothing registers it: no runtime lookup can ever reach it, so
    # its bytecode `def` is dead in every build and still safe to strip. Not
    # in a hot-only build, where bc2cpp registers it again (ADR 0214).
    static_only = !hot_only && STATIC_DISPATCH_UNREGISTERED.include?(key)
    return false unless installed.include?(m[:entry]) || static_only
    return false if never_called.include?(key) && NeverCalledRegistrations.safe_to_unregister?(m[:owner]) &&
                    !STATIC_DISPATCH_UNREGISTERED.include?(key)

    true
  end
end

if $PROGRAM_NAME == __FILE__
  gem_name, repo_root, mrbc = ARGV
  unless gem_name && repo_root && mrbc
    raise ArgumentError, "usage: #{$PROGRAM_NAME} <gem-name> <repo-root> <mrbc-path>"
  end

  # A hot-only build passes its list, so the probe sees what that build compiles.
  hot_methods = ENV['BC2CPP_HOT_METHODS']
  generated, err = NeverCalledRegistrations.run_bc2cpp_full(gem_name, repo_root, mrbc, hot_methods: hot_methods)
  never_called = NeverCalledRegistrations.parse_never_called_names(err)
  installed = NeverCalledRegistrations.installed_entries(
    File.read(File.join(repo_root, gem_name, 'src', 'register.cxx')), generated
  )

  NeverCalledRegistrations.parse_compiled_entries(err).each do |m|
    next unless WioRegisteredMethods.strippable?(m, installed: installed, never_called: never_called,
                                                    hot_only: !hot_methods.nil?)

    singleton = m[:owner].end_with?('.singleton') ? '1' : '0'
    puts [m[:owner], m[:name], m[:arity], m[:visibility], singleton].join("\t")
  end
end
