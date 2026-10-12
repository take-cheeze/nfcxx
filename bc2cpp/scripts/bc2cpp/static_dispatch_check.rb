#!/usr/bin/env ruby
# encoding: UTF-8
# Regression check for STATIC_DISPATCH_UNREGISTRATION (docs/adr/0203).
#
# Every name in tools/bc2cpp/static_dispatch_unregistered.rb has no
# mrb_define_method registration: the proof is that no runtime method-table
# lookup can ever reach it (tools/bc2cpp/static_dispatch_registrations.rb's
# own header lists everything that counts as a lookup). That proof is only as
# good as the tree it ran on, so this re-runs it on every CI run and fails if:
#
#   - a listed name is no longer a compiled entry point of its owner (the
#     method was renamed/removed, or stopped compiling -- its bytecode `def`
#     would then be the only implementation, still unregistered but now also
#     possibly stripped), or
#   - a listed name has gained ANY dynamic reference: a send from bytecode
#     that can run, an interned name in generated C++, a symbol/string
#     literal, `super`, or a mention in core mrblib/native/test/script
#     sources. That would be a live NoMethodError the first time it ran, so
#     it is a hard failure, not a warning -- drop the name from the list
#     (re-run the tool with --write) and let it be registered again, or
#     remove the new dynamic reference.
#   - a hand-written register.cxx line still registers a listed name (a
#     wasted registration, not a correctness problem -- fixed by
#     scripts/bc2cpp/prune_static_dispatch_registrations.rb).
#
# Names that are eligible but not yet listed are reported, not failed: the
# list only ever needs to be a sound subset.
#
# Needs a host mrbc (MRBC), like the other bc2cpp checks; runs bc2cpp.rb once
# per compiled gem plus one closed-world parse.
#
# Usage: MRBC=/path/to/mrbc ruby scripts/bc2cpp/static_dispatch_check.rb

require_relative '../../tools/bc2cpp/static_dispatch_registrations'

root = File.expand_path('../..', __dir__)
mrbc = ENV['MRBC'] || 'mrbc'
analysis = StaticDispatchRegistrations.analyze(root, mrbc)
by_key = analysis[:registered].to_h { |m| ["#{m[:owner]}##{m[:name]}", m] }
eligible = StaticDispatchRegistrations.eligible(analysis).to_set { |m| "#{m[:owner]}##{m[:name]}" }

failures = []
STATIC_DISPATCH_UNREGISTERED.sort.each do |key|
  if !by_key.key?(key)
    failures << "#{key}: no longer a compiled entry point"
  elsif !eligible.include?(key)
    failures << "#{key}: now has a dynamic reference -- would be a NoMethodError unregistered"
  end
end

StaticDispatchRegistrations::GEMS.each do |gem|
  hand = File.read(File.join(root, gem, 'src', 'register.cxx'), encoding: 'UTF-8')
  StaticDispatchRegistrations.registrations(hand).each do |entry, name|
    key = STATIC_DISPATCH_UNREGISTERED.find do |k|
      owner, n = k.split('#', 2)
      n == name && "#{owner}_#{n}".gsub(/[^a-zA-Z0-9_]/, '_') == entry
    end
    failures << "#{key}: still hand-registered in #{gem}/src/register.cxx" if key
  end
end

unlisted = (eligible - STATIC_DISPATCH_UNREGISTERED).size
puts "  #{STATIC_DISPATCH_UNREGISTERED.size} listed name(s) re-proven against #{analysis[:registered].size} " \
     "compiled entries (#{unlisted} more eligible but unlisted)"
if failures.empty?
  puts 'bc2cpp static dispatch check: PASS'
else
  failures.each { |f| warn "  FAIL #{f}" }
  warn "bc2cpp static dispatch check: #{failures.size} failure(s)"
  exit 1
end
