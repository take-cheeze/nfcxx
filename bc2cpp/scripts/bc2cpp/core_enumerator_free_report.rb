#!/usr/bin/env ruby
# frozen_string_literal: true

# CORE_ENUMERATOR_FREE report: runs the proof of tools/bc2cpp/core_enumerator_free.rb over the closed world and prints what
# it found: whether it holds, every site of an iterator that can make an Enumerator and how it was settled (a block, a
# no-argument native, a receiver proven by the class facts), and, when it does not hold, each site or condition it could
# not account for with file, line and why. The build leaves the mruby-enumerator methods in the method tables until it
# holds (docs/bc2cpp-unregistered-methods.md, "The Enumerator machinery"). Then the same for CORE_FIBER_FREE.
#
# Usage: MRBC=path/to/mrbc [BC2CPP_STATIC_DISPATCH_LISTS=lists.json] ruby scripts/bc2cpp/core_enumerator_free_report.rb [--sites]
#   --sites  also lists every checked engine site, not only the unproven ones

require_relative '../../tools/mrbc_rb/mrbc_default.rb'
require_relative '../../tools/bc2cpp/world_root'
require_relative '../../tools/bc2cpp/static_dispatch_registrations'

root = BC2CPP_WORLD_ROOT
result = StaticDispatchRegistrations.enumerator_free_result(root, ENV.fetch('MRBC', MrbcRbDefault.command))
engine = result.sites.select(&:engine)
puts "proof #{result.holds ? 'holds' : 'does not hold'}: #{result.creators.map(&:name).uniq.size} creator names, " \
     "#{engine.size} engine sites and #{result.sites.size - engine.size} core sites checked"
puts "  settled by a block or an argument: #{result.proven[:given]}, by the receiver's class: #{result.proven[:receiver]}, " \
     "unproven: #{result.unproven.size}"
result.creators.select { |c| c.mode == :always }.each { |c| puts "  makes one for any call: #{c.owner}##{c.name}" }
if ARGV.include?('--sites')
  engine.sort_by { |s| [s.name, s.file, s.line] }.each do |s|
    classes = s.classes && (s.classes.empty? ? ' [no value reaches it]' : " [#{s.classes.to_a.sort.first(3).join(', ')}#{', ...' if s.classes.size > 3}]")
    puts "  #{s.verdict.to_s.ljust(9)} #{s.name.ljust(14)} #{s.file.sub(%r{.*/(mruby-[^/]+/)}, '\1')}:#{s.line} #{s.where}#{classes}"
  end
end
result.unproven.each do |u|
  where = u.file ? "#{u.file.sub(%r{.*/(mruby-[^/]+/|3rd/)}, '\1')}:#{u.line}" : '-'
  puts "UNPROVEN #{where} #{u.where} #{u.name}: #{u.why}"
end
# CORE_FIBER_FREE (tools/bc2cpp/core_fiber_free.rb), which builds on it: no Fiber is made, so the resumable variants go.
# The left-out core methods are those of the lists BC2CPP_STATIC_DISPATCH_LISTS names, none without it.
native = StaticDispatchRegistrations.outside_world_files(root, closed_only: true).last
fiber = StaticDispatchRegistrations.fiber_free_proof(-> { result }, native, StaticDispatchLists.current.core_left_out)
puts "fiber-free proof #{fiber.holds ? 'holds' : 'does not hold'}"
fiber.unproven.each { |why| puts "UNPROVEN fiber: #{why}" }
exit(result.holds && fiber.holds ? 0 : 1)
