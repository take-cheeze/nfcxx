#!/usr/bin/env ruby
# frozen_string_literal: true

# Check NATIVE_ARM_COVER (docs/adr/0378): a chain site whose receiver set is proven by the exact-class flow judges a
# native class of that set as covered when an exact-class native arm for it was emitted ahead of the chain's else
# (the zero-argument RGSS wrappers: Sprite/Viewport/Window `update`), because a receiver of exactly that class takes
# the arm and never reaches the else.
#
# Generated code (needs MRBC):
#   * positives: `@vp.update` (Viewport only) and `@both.update` (Viewport and Sprite, both with an arm)
#     lose the by-name else (it becomes the proven-dead nomethod tail);
#   * negatives keep it: an unproven receiver (a parameter), a set that holds a class without an emitted arm
#     (Tilemap registers `update` natively and has none), a set with a class the arms do not name (a Ruby class
#     whose `update` is not the one the chain lists is still judged by the existing gate), a world where a Ruby
#     override, a subclass or a method_missing class reaches the set, the kill switch and the open world.
#
# Usage: MRBC=path/to/mrbc ruby scripts/bc2cpp/native_arm_cover_check.rb

require 'tmpdir'
require_relative 'fixture_runtime'

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

runtime = Bc2cppFixtureRuntime

CLASSES = <<~RUBY
  module RGSS
    class Viewport; def initialize(*); end; end
    class Sprite; def initialize(*); end; end
    class Window; def initialize(*); end; end
    class Tilemap; def initialize(*); end; end
  end
  class NcKid < RGSS::Viewport; end
  # A Ruby definer of `update` next to the natives makes it a POLY chain with a by-name else.
  class NcThing; def update; :thing; end; end
  # The shape of mruby-rgss's `class << Graphics` probe: `update` becomes an installed name, which keeps
  # EXACT_NATIVE_WRAPPER (it needs an installer-free name) off and leaves the chain to the scoped gates.
  module NcTool; def self.update; :tool; end; end
  class << NcTool
    alias_method :_nc_update, :update
    def update; _nc_update; end
  end
RUBY

HOST = <<~RUBY
  class NcHost
    def initialize
      @vp = RGSS::Viewport.new
      @both = RGSS::Viewport.new
      @tm = RGSS::Tilemap.new
      @tmvp = RGSS::Viewport.new
      @thing = NcThing.new
    end

    def flip; @both = RGSS::Sprite.new; @tmvp = RGSS::Tilemap.new; end

    # -- positives
    def pos_viewport; @vp.update; end
    def pos_two_arms; @both.update; end
    # -- negatives
    def neg_param(x); x.update; end
    def neg_no_arm; @tm.update; end
    def neg_mixed_no_arm; @tmvp.update; end
    # the Ruby class of the set resolves in Ruby: the existing gate, unchanged by the cover
    def ctl_thing; @thing.update; end
  end
RUBY

OWNERS = %w[NcHost NcThing NcKid].freeze
POSITIVE = %w[pos_viewport pos_two_arms].freeze
NEGATIVE = %w[neg_param neg_no_arm neg_mixed_no_arm].freeze

# The method's body and, for a rescue, the closure its protected part compiles into.
body_of = lambda do |code, fn|
  code.scan(/^(?:static )?mrb_value NcHost_#{fn}_impl(?:_rescue_try)?\(mrb_state\* M.*?(?=^(?:static )?mrb_value \w+\(mrb_state\* |\z)/m).join
end
live_of = ->(code, fn) { body_of.call(code, fn).lines.reject { |l| l.lstrip.start_with?('//') }.join }
by_name = ->(code, fn) { live_of.call(code, fn).include?('bc2cpp_send(') }
dead_tail = ->(code, fn) { live_of.call(code, fn).include?('bc2cpp_nomethod') && !by_name.call(code, fn) }

generate = lambda do |source, dir, closed: true, env: {}, **options|
  saved = env.to_h { |k, _| [k, ENV.fetch(k, nil)] }
  env.each { |k, v| ENV[k] = v }
  begin
    runtime.generate(source, dir, closed: closed, only_owners: OWNERS, **options)
  ensure
    saved.each { |k, v| v ? ENV[k] = v : ENV.delete(k) }
  end
end

unless ENV['MRBC']
  puts '-- SKIP generated code: set MRBC'
  exit 0
end

puts '== generated code'
Dir.mktmpdir do |dir|
  code, = generate.call(CLASSES + HOST, dir)
  POSITIVE.each do |fn|
    check.call("NcHost##{fn}: every class of the proven set has an emitted native arm, the else is the dead tail",
               dead_tail.call(code, fn))
  end
  NEGATIVE.each do |fn|
    check.call("NEG NcHost##{fn}: keeps the by-name else", by_name.call(code, fn))
  end
  check.call('the arms are emitted ahead of the else (the cover reads what the code has)',
             body_of.call(code, 'pos_two_arms').include?('viewport_update_direct'))
  check.call('the installed name keeps EXACT_NATIVE_WRAPPER off, so the chain is what the cover judges',
             !body_of.call(code, 'pos_viewport').include?('EXACT_NATIVE_WRAPPER'))

  # variant => [extra Ruby, the positives that must keep their by-name else]
  variants = {
    'a Ruby override of Viewport#update' => ["class RGSS::Viewport\n  def update; :ruby; end\nend\n", POSITIVE],
    'a subclass instance is stored in the ivar of the two-arm set' => ["class NcHost\n  def sub; @both = NcKid.new; end\nend\n", %w[pos_two_arms]],
    'a method_missing class in the set' => ["class RGSS::Viewport\n  def method_missing(n, *a); :ghost; end\nend\n", POSITIVE],
    'a parameter is stored in the ivar' => ["class NcHost\n  def put(v); @vp = v; end\nend\n", %w[pos_viewport]],
    'a computed definition of the name on a class of the set' => ["class RGSS::Viewport\n  [:update].each { |n| define_method(n) { :c } }\nend\n", POSITIVE]
  }
  variants.each do |what, (extra, keeps)|
    d = File.join(dir, what.gsub(/\W+/, '_'))
    Dir.mkdir(d)
    vcode, = generate.call(CLASSES + HOST + extra, d)
    check.call("#{what}: withdrawn (#{keeps.join(', ')} keep the by-name else)", keeps.all? { |fn| by_name.call(vcode, fn) })
  end

  Dir.mktmpdir do |off|
    off_code, = generate.call(CLASSES + HOST, off, env: { 'BC2CPP_NATIVE_ARM_COVER' => '0' })
    check.call('the kill switch (BC2CPP_NATIVE_ARM_COVER=0): the positives keep the by-name else',
               POSITIVE.all? { |fn| by_name.call(off_code, fn) })
  end
  Dir.mktmpdir do |arms|
    arms_code, = generate.call(CLASSES + HOST, arms, env: { 'BC2CPP_NATIVE_CLASS_ARMS' => '0' })
    check.call('BC2CPP_NATIVE_CLASS_ARMS=0: the scoped set is off, so is the cover',
               POSITIVE.all? { |fn| by_name.call(arms_code, fn) })
  end
  Dir.mktmpdir do |open_dir|
    open_code, = generate.call(CLASSES + HOST, open_dir, closed: false)
    check.call('the open world proves nothing: no dead tail', POSITIVE.none? { |fn| dead_tail.call(open_code, fn) })
  end
end

if failures.empty?
  puts 'OK'
else
  puts "FAILED: #{failures.size}"
  exit 1
end
