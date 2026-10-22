#!/usr/bin/env ruby
# encoding: UTF-8
# Removes the hand-written register.cxx line for every compiled entry named in
# tools/bc2cpp/static_dispatch_unregistered.rb. The generated
# registration for BC2CPP_WIRED_EMBEDDINGS owners already skips those names
# itself (bc2cpp.rb's emit_owner_registrations); this is the same for the
# hand-maintained lines of every other owner. Needs no mrbc: a line is removed
# only when BOTH its name literal is the listed method's name AND its entry
# symbol is the one bc2cpp.rb's own cpp_name spells for that owner
# (`"#{owner}_#{name}"` with every non-[A-Za-z0-9_] byte turned into `_`), so
# a mismatch can only ever leave a line in place, never take the wrong one.
#
# Usage: ruby scripts/bc2cpp/prune_static_dispatch_registrations.rb

require_relative '../../tools/bc2cpp/static_dispatch_unregistered'
require_relative '../../tools/bc2cpp/static_dispatch_registrations'

root = File.expand_path('../..', __dir__)
wanted = STATIC_DISPATCH_UNREGISTERED.to_set do |key|
  owner, name = key.split('#', 2)
  [name, "#{owner}_#{name}".gsub(/[^a-zA-Z0-9_]/, '_')]
end
removed = 0
StaticDispatchRegistrations::GEMS.each do |gem|
  path = File.join(root, gem, 'src', 'register.cxx')
  src = File.read(path, encoding: 'UTF-8')
  out = src.gsub(/^[ \t]*mrb_define_(?:private_|class_)?method\(\s*M\s*,\s*\w+\s*,\s*"((?:[^"\\]|\\.)*)"\s*,\s*([A-Za-z_][A-Za-z0-9_$]*)\s*,[^;]*\);\n/m) do |line|
    key = [StaticDispatchRegistrations.unescape(Regexp.last_match(1)), Regexp.last_match(2)]
    if wanted.include?(key)
      removed += 1
      ''
    else
      line
    end
  end
  File.write(path, out) unless out == src
end
puts "#{removed} hand registration line(s) removed"
