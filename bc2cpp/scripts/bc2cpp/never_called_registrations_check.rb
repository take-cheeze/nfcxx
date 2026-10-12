#!/usr/bin/env ruby
# encoding: UTF-8
# Regression check for scripts/bc2cpp/prune_never_called_registrations.rb: if
# a later round hand-adds a register.cxx registration for a method that is
# (still, or newly) never-called and owned by a class
# tools/bc2cpp/never_called_registrations.rb's own safety rule clears, this
# fails loudly with the exact name(s) rather than letting the wasted flash
# back in silently. A clean run means every such candidate has already been
# pruned -- see that file's own header comment for the full owner-safety
# argument (Game::/RPG2k::/RPG2k3::/LCF:: only, never wired-embedding or
# `.singleton`, never mruby-rgss-compiled).
#
# Needs a host mrbc (MRBC), like the other bc2cpp checks; takes about as long
# as bc2cpp_wired_embedding_check.rb per gem (one real bc2cpp.rb run each for
# mruby-rpg2k-compiled and mruby-lcf-compiled).
#
# Usage: MRBC=/path/to/mrbc ruby scripts/bc2cpp/never_called_registrations_check.rb

require_relative '../../tools/bc2cpp/never_called_registrations'

repo_root = File.expand_path('../..', __dir__)
mrbc = ENV['MRBC'] || 'mrbc'

failures = []
%w[mruby-rpg2k-compiled mruby-lcf-compiled].each do |gem_name|
  # prunable_entries only answers "bc2cpp.rb could compile this and nothing
  # calls it" -- it says nothing about whether register.cxx still has a
  # line for it (most won't, once this check is green), so cross-check
  # against the real, current register.cxx before calling anything a
  # regression.
  candidates = NeverCalledRegistrations.prunable_entries(gem_name, repo_root, mrbc)
  register_src = File.read(File.join(repo_root, gem_name, 'src', 'register.cxx'), encoding: 'UTF-8')
  still_registered = candidates.select { |m| NeverCalledRegistrations.registered_in_source?(register_src, m[:entry]) }

  if still_registered.empty?
    puts "  ok   #{gem_name}: no never-called, safe-to-unregister entries currently registered"
  else
    names = still_registered.map { |m| "#{m[:owner]}##{m[:name]}" }
    puts "  FAIL #{gem_name}: #{names.size} never-called registration(s) should be pruned: #{names.join(', ')}"
    failures.concat(names)
  end
end

if failures.empty?
  puts 'bc2cpp never-called registrations check: PASS'
else
  warn "bc2cpp never-called registrations check: #{failures.size} registration(s) should be removed -- " \
       'run scripts/bc2cpp/prune_never_called_registrations.rb'
  exit 1
end
