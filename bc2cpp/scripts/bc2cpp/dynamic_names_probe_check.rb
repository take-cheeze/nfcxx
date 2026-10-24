#!/usr/bin/env ruby
# frozen_string_literal: true

# PROBE_ONLY (tools/bc2cpp/dynamic_names.rb): a Symbol literal whose every use is the name argument of
# `respond_to?` is not a dynamic name (a self send overwriting its register is no use); any other use, an escape into a container, a Ruby respond_to_missing? or
# respond_to? (defined or aliased), or a literal spelling either keeps it one. A computed name elsewhere does not.
#
# Usage: MRBC=path/to/mrbc ruby scripts/bc2cpp/dynamic_names_probe_check.rb

unless ENV['MRBC']
  puts '  SKIP: set MRBC (a host mrbc built from the patched 3rd/mruby)'
  exit 0
end

# The fixtures declare no RBS; the repository's signatures name engine classes these fixtures lack.
ENV['BC2CPP_SIG_DIRS'] = ''
require_relative '../../tools/bc2cpp/bc2cpp'
require_relative 'fixture_runtime'

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end
stems_of = lambda do |source|
  Bc2cppFixtureRuntime.registry_snapshot(source) { |_registry, _ireps| nil } => [_registry, ireps, *]
  DynamicNames.analyze(ireps)
end

puts '-- probe-only literals'
stems, computed = stems_of.call(<<~RUBY)
  class DnA
    def a(o); o.respond_to?(:dn_plain); end
    def b(o); o.respond_to?(:dn_two, true); end
    def c(o); n = :dn_moved; m = n; o.respond_to?(m); end
    def d(o); o.respond_to?(:dn_called) && o.send(:dn_called); end
    def e(o); n = :dn_flows; o.respond_to?(n) && o.send(n); end
    def f(o); [:dn_escapes].each { |x| o.respond_to?(x) }; end
    def g; :dn_receiver.respond_to?(:to_s); end
    def h(o, x); o.respond_to?(:dn_computed_too) && o.send("\#{x}=", 1); end
    def i(c); c.actor.states = helper(c.states) if c.states && c.actor.respond_to?(:dn_slot=); nil; end
    def j(o); o.respond_to?(:dn_arg) && helper(:dn_arg); end
    def helper(v); v; end
  end
RUBY
check.call('a respond_to?(:x) argument is not a dynamic name', !stems.include?('dn_plain'))
check.call('respond_to?(:x, true) is a probe too', !stems.include?('dn_two'))
check.call('the probe sees through MOVE aliases', !stems.include?('dn_moved'))
check.call('a name also spelled at a send stays dynamic', stems.include?('dn_called'))
check.call('a value reaching a send as well as the probe stays dynamic', stems.include?('dn_flows'))
check.call('a literal that escapes into a container stays dynamic', stems.include?('dn_escapes'))
check.call('a Symbol receiver of respond_to? stays dynamic', stems.include?('dn_receiver'))
check.call('a computed name elsewhere does not bring a probe back', computed && !stems.include?('dn_computed_too'))
check.call('a self send reusing the probe register as its result slot reads nothing', !stems.include?('dn_slot='))
check.call('a self send taking the name as an argument stays dynamic', stems.include?('dn_arg'))

puts '-- the call-site index (ENTRY_ARG_CALLSITE_PROOF) treats a probe-only literal as no poison'
index_of = lambda do |source|
  Bc2cppFixtureRuntime.registry_snapshot(source) { |_registry, _ireps| nil } => [registry, ireps, *]
  CodeGen.new(ireps, registry, {}).send(:entry_arg_call_index)
end
_sites, poisoned = index_of.call(<<~RUBY)
  class DnC
    def probe(o); o.respond_to?(:dn_index_probe=) ? 1 : 0; end
    def named(o); o.respond_to?(:dn_index_sent) && o.public_send(:dn_index_sent); end
  end
RUBY
check.call('a probe-only literal does not poison its name', !poisoned.include?('dn_index_probe='))
check.call('a literal that also reaches a send still poisons', poisoned.include?('dn_index_sent'))
ENV['BC2CPP_PROBE_CALL_INDEX'] = '0'
_sites, poisoned = index_of.call("class DnD\n  def probe(o); o.respond_to?(:dn_index_off=) ? 1 : 0; end\nend\n")
check.call('BC2CPP_PROBE_CALL_INDEX=0 keeps the literal a poison', poisoned.include?('dn_index_off='))
ENV.delete('BC2CPP_PROBE_CALL_INDEX')

puts '-- a Ruby hook takes the probe name'
[['respond_to_missing? defined in Ruby', 'def respond_to_missing?(n, p = false); false; end'],
 ['respond_to? defined in Ruby', 'def respond_to?(n, p = false); true; end'],
 ['respond_to_missing? aliased', 'def dn_hook(n, p = false); false; end; alias respond_to_missing? dn_hook'],
 ['respond_to_missing? spelled as a literal', 'def dn_spell; [:respond_to_missing?]; end']].each do |what, hook|
  stems, = stems_of.call("class DnB\n  #{hook}\n  def a(o); o.respond_to?(:dn_hooked); end\nend\n")
  check.call("#{what}: a probe name stays dynamic", stems.include?('dn_hooked'))
end

puts(failures.empty? ? 'dynamic names probe check: PASS' : "dynamic names probe check: #{failures.size} failure(s)")
exit(failures.empty? ? 0 : 1)
