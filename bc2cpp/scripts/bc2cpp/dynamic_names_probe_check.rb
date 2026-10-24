#!/usr/bin/env ruby
# frozen_string_literal: true

# PROBE_ONLY (tools/bc2cpp/dynamic_names.rb): a Symbol literal whose every use is the name argument of
# `respond_to?` is not a dynamic name; any other use, an escape into a container, a Ruby respond_to_missing? or
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
