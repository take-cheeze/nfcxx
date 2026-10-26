#!/usr/bin/env ruby
# frozen_string_literal: true

# YIELD_C_BOUNDARY: the yield analysis (tools/bc2cpp/yield_reach.rb) does not count a native's callback into Ruby as
# a path a Fiber.yield suspends through, because mruby raises FiberError across that C-boundary frame; and a computed
# send on self reaches only methods of self's class chain. Each rule is checked on a fixture in both directions, and
# with its switch (BC2CPP_YIELD_C_BOUNDARY=0, BC2CPP_YIELD_SPELLED_SENDS=0) turning it off.
# See docs/bc2cpp-yield-c-boundary.md.
#
# Usage: MRBC=path/to/mrbc ruby scripts/bc2cpp/yield_c_boundary_check.rb

require 'json'
require 'open3'
require 'rbconfig'
require 'tmpdir'

ROOT = File.expand_path('../..', __dir__)

FIXTURE = <<~RUBY
  class Waiter
    def pause
      Fiber.yield
    end

    def cb_target
      pause
    end

    def cb_only
      pause
    end
  end

  class Caller
    def via_native(x)
      x.native_m
    end

    def self_send(op)
      send(op)
    end

    def other_send(obj, op)
      obj.send(op)
    end

    def tag
      :pause
    end
  end

  Fiber.new do
    Waiter.new.cb_target
    c = Caller.new
    c.via_native(1)
    c.self_send(:tag)
    c.other_send(Waiter.new, :pause)
  end.resume
RUBY

METHODS = %w[pause cb_target cb_only via_native self_send other_send].freeze

# Child: compile the fixture, run the analysis under the inherited switches and print { name => yield_free? }.
if ARGV.first == '--probe'
  require_relative '../../tools/bc2cpp/irep'
  require_relative '../../tools/bc2cpp/yield_reach'

  Dir.mktmpdir('yield_c_boundary') do |dir|
    src = File.join(dir, 'fixture.rb')
    out = File.join(dir, 'fixture.mrb')
    File.write(src, FIXTURE)
    system(ENV.fetch('MRBC'), '-g', '-o', out, src, exception: true)
    image = Struct.new(:bytes).new(File.binread(out))
    ireps = load_ireps(image, cache: nil).first
    # `native_m` is defined by native code, which may call back into `cb_target` or `cb_only`.
    reach = YieldReach.new(ireps: ireps, sound: true, opaque_names: Set['cb_target', 'cb_only'],
                           native_names: Set['native_m'])
    result = METHODS.to_h do |name|
      node = reach.nodes.values.find { |n| n.kind == :method && n.name == name }
      [name, node && reach.yield_free?(node.label)]
    end
    cb_only = reach.nodes.values.find { |n| n.kind == :method && n.name == 'cb_only' }
    result['cb_only_unsafe'] = !reach.fiber_unsafe([cb_only.label]).empty?
    puts JSON.generate(result)
  end
  exit 0
end

mrbc = ENV['MRBC']
unless mrbc && File.executable?(mrbc)
  puts '  SKIP: no host mrbc (set MRBC)'
  exit 0
end

probe = lambda do |env|
  out, err, status = Open3.capture3(env, RbConfig.ruby, __FILE__, '--probe')
  raise "probe failed (#{env.inspect}):\n#{err}" unless status.success?

  JSON.parse(out.lines.last)
end

failures = []
check = lambda do |description, ok|
  puts "  #{ok ? 'ok  ' : 'FAIL'} #{description}"
  failures << description unless ok
end

default = probe.call({})
check.call('Fiber.yield makes its method may-yield', default['pause'] == false)
check.call('a Ruby call to a yielding method is may-yield', default['cb_target'] == false)
check.call('a native whose callback yields is not a yield path (C boundary)', default['via_native'] == true)
check.call('a computed send on self does not reach another class', default['self_send'] == true)
check.call('a computed send on another receiver may reach a spelled yielding method', default['other_send'] == false)

check.call('a yielding method reached from a Fiber only through a native callback is not Fiber-unsafe',
           default['cb_only'] == false && default['cb_only_unsafe'] == false)

boundary_off = probe.call('BC2CPP_YIELD_C_BOUNDARY' => '0')
check.call('BC2CPP_YIELD_C_BOUNDARY=0 counts the native callback again', boundary_off['via_native'] == false)
check.call('BC2CPP_YIELD_C_BOUNDARY=0 makes the callback-only method Fiber-unsafe again',
           boundary_off['cb_only_unsafe'] == true)

spelled_off = probe.call('BC2CPP_YIELD_SPELLED_SENDS' => '0')
check.call('BC2CPP_YIELD_SPELLED_SENDS=0 lets the self send reach every method again', spelled_off['self_send'] == false)

if failures.empty?
  puts 'bc2cpp yield C-boundary check: PASS'
else
  puts "bc2cpp yield C-boundary check: FAIL (#{failures.size})"
  exit 1
end
