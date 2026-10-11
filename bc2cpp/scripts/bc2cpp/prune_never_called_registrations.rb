#!/usr/bin/env ruby
# encoding: UTF-8
# Removes the register.cxx registration line of every compiled entry point
# tools/bc2cpp/never_called_registrations.rb finds both never-called (zero
# evidence anywhere in this program's own bytecode or NATIVE_SRCS -- bc2cpp.
# rb's own "== never called ==" diagnostic) and safe to stop registering
# (see that file's own header comment for the full owner-safety argument:
# Game::/RPG2k::/RPG2k3::/LCF:: only, never a wired-embedding or `.singleton`
# owner, never mruby-rgss-compiled -- RGSS is the real public scripting API
# a per-game "stock script" can call, invisible to any static analysis here).
#
# Only mruby-rpg2k-compiled and mruby-lcf-compiled are scanned:
# mruby-rgss-compiled owns no owner this file's own safety rule ever clears
# (Array/StringIO/RGSS::* all fail the namespace check), so running it there
# would only ever cost a wasted bc2cpp.rb invocation for zero candidates.
#
# This is a source-mutating tool, not a CI check (see the sibling
# scripts/bc2cpp/never_called_registrations_check.rb for the check that
# verifies its own output stays applied) -- run it by hand, inspect the
# real diff it produces (a removed registration still needs a human/AI
# sanity read: does the removed method's own name/owner really look like
# something no game could plausibly call?), and commit deliberately, the
# same way the registration-completeness batches that grew these files
# were applied by hand rather than as an automatic build step.
#
# Usage: MRBC=/path/to/mrbc ruby scripts/bc2cpp/prune_never_called_registrations.rb

require_relative '../../tools/bc2cpp/never_called_registrations'

repo_root = File.expand_path('../..', __dir__)
mrbc = ENV['MRBC'] || 'mrbc'

total_removed = 0
%w[mruby-rpg2k-compiled mruby-lcf-compiled].each do |gem_name|
  prunable = NeverCalledRegistrations.prunable_entries(gem_name, repo_root, mrbc)
  register_path = File.join(repo_root, gem_name, 'src', 'register.cxx')
  src = File.read(register_path, encoding: 'UTF-8')

  removed = []
  not_found = []
  prunable.each do |m|
    pattern = NeverCalledRegistrations.registration_line_pattern(m[:entry])
    if src.match?(pattern)
      src = src.sub(pattern, '')
      removed << m
    else
      # Not actually registered (e.g. a `.singleton` fn-nil case, or a name
      # this round's bc2cpp.rb run compiles but no register.cxx line has
      # been hand-added for yet) -- nothing to remove, not an error.
      not_found << m
    end
  end

  File.write(register_path, src) if removed.any?

  puts "#{gem_name}: removed #{removed.size} never-called registration(s)" \
       "#{prunable.size == removed.size ? '' : " (#{not_found.size} prunable but not currently registered)"}"
  removed.sort_by { |m| [m[:owner], m[:name]] }.each { |m| puts "  #{m[:owner]}##{m[:name]}" }
  total_removed += removed.size
end

puts "\n#{total_removed} registration(s) removed in total."
