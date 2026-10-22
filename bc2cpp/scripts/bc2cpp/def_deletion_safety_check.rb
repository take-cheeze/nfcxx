#!/usr/bin/env ruby
# encoding: UTF-8
# A real near-miss, not a hypothetical: `LCF::Database#maker` shows up in
# tools/bc2cpp/bc2cpp.rb's own "never called" diagnostic (zero evidence in
# `closed_world_mrblib_srcs`/`NATIVE_SRCS` -- see tools/bc2cpp/
# never_called_registrations.rb), which is exactly the same evidence
# `Game::Character#front_tile` has. `front_tile` really is dead and its
# `def` was deleted outright. `#maker` is NOT dead: it is
# called from `mruby-lcf/test/lcf_test.rb`, `scripts/lcf/testbed_check.rb`
# and `scripts/rpg2k3/battle_command_check.rb` -- real callers bc2cpp.rb's
# own reachability scan has no visibility into at all, since it only ever
# reads `closed_world_mrblib_srcs` (the engine's own mrblib) and
# `NATIVE_SRCS`, by design (that scope is right for what it decides --
# whether an AOT override is worth registering -- because the interpreted
# `def` staying in place means a missed call site there is still correct,
# just uncompiled; deleting the `def` outright removes the only
# implementation, so a missed call site there is a real `NoMethodError`).
#
# This script is the mandatory second check before deleting a method's
# `def` permanently (never before just pruning its bc2cpp registration --
# that tier's own safety net is the interpreted `def` staying put, which
# is exactly what this check does not have once a `def` is really gone):
# a plain, repo-wide, case-sensitive text search for `name` across
# everything except vendored submodules (`3rd/`) and build output/scratch
# directories, so a call from a test file, a `scripts/**/*.rb` check harness,
# a doc example, or anywhere else outside the engine's own mrblib is
# caught before the deletion happens, not after.
#
# This is deliberately a blunt, whole-repo grep, not another whole-program
# bytecode/AST analysis: the point is to see everything bc2cpp.rb's own
# scan cannot, and a text search can look at file kinds (test/, scripts/,
# docs/) that scan was never built to parse at all. A false positive
# (the name appears as a comment, or as a substring of an unrelated
# identifier) only ever costs a manual look, never a wrong deletion --
# the same "a miss stays safe, a false match costs nothing but a second
# look" posture every other diagnostic in this codebase already uses.
#
# Usage: ruby scripts/bc2cpp/def_deletion_safety_check.rb <method_name> [<method_name> ...]
# Exits non-zero (and prints every match) if any method name has a real
# hit outside its own known definition site; 0 and silent otherwise.

require 'English'

ROOT = File.expand_path('../..', __dir__)
EXCLUDE_DIRS = %w[.git 3rd .pio build build-bc2cpp coverage].freeze

names = ARGV
if names.empty?
  raise ArgumentError, "usage: #{$PROGRAM_NAME} <method_name> [<method_name> ...]"
end

failures = []
Dir.chdir(ROOT) do
  names.each do |name|
    # Plain --fixed-strings, deliberately no --word-regexp: a method name
    # ending in `?`/`!`/`=` (open?, close?, font=) sits right at a
    # non-word/non-word boundary ripgrep's \b never fires on, which would
    # silently make --word-regexp miss exactly the names this check most
    # needs to catch. A substring match costs an occasional false
    # positive (safe, per this file's own header) rather than that.
    exclude_args = EXCLUDE_DIRS.flat_map { |d| ['--glob', "!#{d}/**"] }
    cmd = ['rg', '--line-number', '--fixed-strings', name, *exclude_args]
    out = IO.popen(cmd, &:read)
    status = $CHILD_STATUS
    next if status.exitstatus == 1 # no matches at all

    unless status.success?
      warn "#{name}: `rg` failed (exit #{status.exitstatus})"
      failures << name
      next
    end

    lines = out.lines
    puts "#{name}: #{lines.size} match(es) outside 3rd/ and build output --"
    lines.each { |l| puts "  #{l}" }
    failures << name
  end
end

if failures.empty?
  puts 'bc2cpp def deletion safety check: no references found -- safe to delete' if $stdout.tty?
  exit 0
else
  warn "\nbc2cpp def deletion safety check: #{failures.size} name(s) still referenced " \
       'somewhere -- do NOT delete their def (see this script\'s own header comment for why ' \
       'a real, live example -- LCF::Database#maker -- looked identically "never called" to ' \
       'bc2cpp.rb and was not)'
  exit 1
end
