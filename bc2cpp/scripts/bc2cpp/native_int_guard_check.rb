#!/usr/bin/env ruby
# encoding: utf-8
# Check ADR 0358: an :int argument of a NATIVE_DIRECT / NATIVE_DIRECT_EXACT arm drops its
# mrb_integer_p test when the Fixnum proof already covers it, which removes the arm's
# by-name else with it.
#
# The two sibling emitters have always asked native_int_arg_proven? for the same test --
# codegen_send.rb's `Bitmap.new` path (ADR 0318) and codegen_native_exact_direct.rb
# (NATIVE_EXACT_DIRECT) -- while these two did not, so an argument the proof covers kept a
# runtime tag test whose else dispatched by name. ADR 0318 deferred them because "an arm
# keeps its class test's else whatever its arguments are"; that no longer holds for
# NATIVE_DIRECT_EXACT, where the class test is already gone.
#
# The proof is native_int_arg_proven? itself (native_int_args_enabled?, a static constant
# world and fixnum_interval/proven_fixnum_operand?). So the checks here pin the emitters'
# shape for each answer, then pin the generated code for a real closed world.
require 'open3'
require 'set'
require 'shellwords'
require 'tmpdir'
require_relative '../../tools/bc2cpp/compiled_gems'
require_relative '../../tools/bc2cpp/nomethod_reviewed'
require_relative '../../tools/bc2cpp/nomethod_reviewed_probe'

root = File.expand_path('../..', __dir__)
failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end
abort 'SKIP: set MRBC' unless ENV['MRBC']
# This check drives the tag-test emitters in process; ADR 0372's unboxing replaces them for a proven name, so it is off.
ENV['BC2CPP_NATIVE_PARAM_UNBOX'] = '0'

# -- the emitters, driven directly -------------------------------------------------
#
# native_direct_exact_line is pure string emission, so one CodeGen with a stubbed proof
# covers every branch without a compile. The stub answers exactly what native_int_arg_proven?
# answers, so a change to the real proof is measured by the generated-code section below,
# not here.
require File.join(ENV['BC2CPP_TOOL'] ? File.dirname(ENV['BC2CPP_TOOL']) : File.join(root, 'tools/bc2cpp'), 'bc2cpp')
cg = CodeGen.allocate
SPRITE_Z = ['RGSS::Sprite', ['object_z_set_direct', [:int]]].freeze
SEND = "r3 = bc2cpp_send(M, r2, 1299, 1, r3);\n"
cg.define_singleton_method(:native_int_arg_proven?) { |_irep, _idx, _owner, _off, _argv, position| @proof_answer == position }
cg.instance_variable_set(:@native_construct_used, Set.new)
# The stub answers per position, exactly as the real proof does (it reads argv[position]), so
# a build that asked about the wrong position is caught rather than agreeing by accident.
cg.instance_variable_set(:@proof_answer, 0)
proven = cg.native_direct_exact_line(3, 'r2', 'z=', %w[r3], SPRITE_Z, SEND, [nil, 0, nil, 0])
cg.instance_variable_set(:@proof_answer, nil)
unproven = cg.native_direct_exact_line(3, 'r2', 'z=', %w[r3], SPRITE_Z, SEND, [nil, 0, nil, 0])
absent = cg.native_direct_exact_line(3, 'r2', 'z=', %w[r3], SPRITE_Z, SEND)
enabled = ENV['BC2CPP_NATIVE_INT_GUARDS'] != '0'
# The switch is read inside the gate, so it is read by calling it: a build whose condition was
# edited no longer consults the environment, and the proven case below diverges.
cg.instance_variable_set(:@proof_answer, 0)
check.call('the gate honours the kill switch',
           cg.native_int_guard_needed?([nil, 0, nil, 0], %w[r3], 0) == !enabled)
cg.instance_variable_set(:@proof_answer, nil)
check.call('a proven :int argument drops the tag test and the by-name else',
           enabled ? !proven.include?('mrb_integer_p') && !proven.include?('bc2cpp_send') : proven == unproven)
check.call('an unproven :int argument keeps the tag test and its dispatch',
           unproven.include?('mrb_integer_p(r3)') && unproven.include?('bc2cpp_send('))
check.call('a nil int_site keeps the tag test', absent == unproven)
check.call('the entry point call is unchanged either way', proven.include?('rgss::object_z_set_direct(M, r2, mrb_integer(r3))'))
check.call('an argument with no :int kind never gains a test',
           !cg.native_direct_exact_line(3, 'r2', 'contents=', %w[r3],
                                        ['RGSS::Window', ['window_contents_set_direct', []]], SEND,
                                        [nil, 0, nil, 0]).include?('mrb_integer_p'))

# native_direct_wrap is the class-tested arm (NATIVE_DIRECT). It only reaches its branches
# when no exact-core site matched, so it has no int_site and keeps every tag test: a proven
# receiver is routed to native_direct_exact_line above instead. Pinning that here keeps the
# proof from being threaded into a branch that can never have one.
WRAP_ARGS = %w[r3].freeze
arms = { 'RGSS::Sprite' => ['object_z_set_direct', [:int]] }
cg.define_singleton_method(:exact_core_site_for) { |_r, _n| nil }
cg.define_singleton_method(:dynamic_dispatch_line) { |*_a| SEND }
wrap = cg.native_direct_wrap(3, 'r2', 'z=', WRAP_ARGS, arms, "    r3 = bc2cpp_nomethod(M, r2, 647);\n")
check.call('the class-tested arm keeps every tag test: it has no int_site',
           wrap.include?('mrb_integer_p(r3)') && wrap.include?('rgss::native_sprite_class()'))
check.call('and still reaches the by-name dispatch its else needs', wrap.include?('bc2cpp_send('))

# A site whose class has an entry point routes to the exact line above, so the proof applies
# exactly once per send.
cg.define_singleton_method(:exact_core_site_for) { |_r, _n| { klass: 'RGSS::Sprite', int_site: [nil, 0, nil, 0] } }
cg.instance_variable_set(:@proof_answer, 0)
routed = cg.native_direct_wrap(3, 'r2', 'z=', WRAP_ARGS, arms, "    r3 = bc2cpp_nomethod(M, r2, 647);\n")
check.call('a matching site routes to the exact line, taking the proof with it',
           routed.include?('NATIVE_DIRECT_EXACT') && routed.include?('mrb_integer_p') == !enabled)

# A two-argument entry (`flash` is :value, :int): only the :int position is a candidate, and
# the class-tested arm still guards it (no int_site of its own).
flash_arms = { 'RGSS::Sprite' => ['sprite_flash_direct', [:value, :int]] }
cg.define_singleton_method(:exact_core_site_for) { |_r, _n| nil }
flash_wrap = cg.native_direct_wrap(3, 'r2', 'flash', %w[r3 r4], flash_arms, "    r3 = bc2cpp_nomethod(M, r2, 647);\n")
check.call('the class-tested two-argument arm guards its :int position',
           flash_wrap.include?('mrb_integer_p(r4)') && !flash_wrap.include?('mrb_integer_p(r3)'))
cg.define_singleton_method(:exact_core_site_for) { |_r, _n| { klass: 'RGSS::Sprite', int_site: [nil, 0, nil, 0] } }
cg.instance_variable_set(:@proof_answer, 1)
flash_exact = cg.native_direct_exact_line(3, 'r2', 'flash', %w[r3 r4],
                                          ['RGSS::Sprite', flash_arms['RGSS::Sprite']], SEND, [nil, 0, nil, 0])
check.call('the exact line drops that :int position, and with it the whole send',
           enabled ? !flash_exact.include?('mrb_integer_p') && !flash_exact.include?('bc2cpp_send')
                   : flash_exact.include?('mrb_integer_p') && flash_exact.include?('bc2cpp_send('))
check.call('the :value argument is still passed through', flash_exact.include?('rgss::sprite_flash_direct(M, r2, r3,'))
# ...but only while the proof answers for every :int position; one unproven :int keeps both.
cg.instance_variable_set(:@proof_answer, nil)
flash_partial = cg.native_direct_exact_line(3, 'r2', 'flash', %w[r3 r4],
                                            ['RGSS::Sprite', flash_arms['RGSS::Sprite']], SEND, [nil, 0, nil, 0])
check.call('an unproven position keeps its test and the send',
           flash_partial.include?('mrb_integer_p(r4)') && flash_partial.include?('bc2cpp_send('))
# The :int position is the second one: a proof that answers for position 0 instead must not
# free it, or an entry whose first argument is unproven loses the TypeError the binding raises.
cg.instance_variable_set(:@proof_answer, 0)
flash_misplaced = cg.native_direct_exact_line(3, 'r2', 'flash', %w[r3 r4],
                                              ['RGSS::Sprite', flash_arms['RGSS::Sprite']], SEND, [nil, 0, nil, 0])
check.call('a proof for another position does not free this one',
           flash_misplaced.include?('mrb_integer_p(r4)') && flash_misplaced.include?('bc2cpp_send('))

# -- generated code --------------------------------------------------------------
mrbc = ENV['MRBC']
gems = NomethodReviewedProbe.wio_gems(root)
rgss_srcs = Dir[File.join(root, 'mruby-rgss/src/*.cxx')]
native_srcs = rgss_srcs + core_native_srcs(File.join(root, '3rd/mruby')) + external_gem_native_srcs(root)
bc2cpp_tool = ENV['BC2CPP_TOOL'] || File.join(root, 'tools/bc2cpp/bc2cpp.rb')
generate = lambda do |source, name, closed|
  Dir.mktmpdir do |dir|
    path = File.join(dir, "#{name}.rb")
    File.write(path, source)
    # This check owns the tag-test machinery (the Fixnum proof dropping a test); ADR 0372's unboxing removes the test of a
    # proven name outright (scripts/bc2cpp/native_param_unbox_check.rb), so it is off here.
    env = { 'MRBC' => mrbc, 'OUT_SYMBOL' => name, 'OUT_DIR' => dir, 'SKIP_UNSUPPORTED' => '1',
            'NATIVE_SRCS' => Shellwords.join(native_srcs), 'BC2CPP_NATIVE_PARAM_UNBOX' => '0' }
    if closed
      env.merge!('BC2CPP_CLOSED_WORLD' => '1', 'BC2CPP_BUILD_NAME' => 'wio',
                 'BC2CPP_BUILD_GEMS' => Shellwords.join(gems.map { |n, d| "#{n}=#{d}" }),
                 NomethodReviewed::ALLOW_ENV => 'allow')
    end
    out, err, status = Open3.capture3(env, RbConfig.ruby, bc2cpp_tool, path)
    abort "bc2cpp.rb failed for #{name}:\n#{err[-3000..] || err}" unless status.success?

    out
  end
end
body_of = lambda do |code, fn|
  code[/^mrb_value #{fn}_impl\(mrb_state\* M.*?(?=^(?:static )?mrb_value \w+\(mrb_state\* M|\z)/m].to_s
end

# The class-tested arm in a real closed world: the receiver arrives as a parameter, so no
# proof can name its class and the arm keeps both the class test and the tag test.
WORLD = <<~'RUBY'
  class NiCaller
    def known(w, v); w.z = v; w.z; end
    def untyped(w, v); w.contents = v; w.contents; end
    def two_args(w, c, t); w.flash(c, t); w.visible; end
  end
RUBY
code = generate.call(WORLD, 'ni_closed', true)
known = body_of.call(code, 'NiCaller_known')
check.call('a class-tested arm reaches the entry point', known.include?('rgss::object_z_set_direct('))
check.call('its :int test is kept: the argument is a parameter',
           known.include?('mrb_integer_p(') && known.include?('bc2cpp_send('))
untyped = body_of.call(code, 'NiCaller_untyped')
check.call('an untyped argument is untouched', untyped.include?('rgss::window_contents_set_direct(') && !untyped.include?('mrb_integer_p'))
two = body_of.call(code, 'NiCaller_two_args')
check.call('a two-argument entry still guards its :int position', two.include?('mrb_integer_p('))
open_code = generate.call(WORLD, 'ni_open', false)
check.call('the open world is byte-identical for this change',
           body_of.call(open_code, 'NiCaller_known').include?('mrb_integer_p('))

# The real proof, on the engine's own shape: a Sprite the class flow proves exact, with a
# literal Integer duration. This is `spr.flash(Color.new(...), 20)` in
# RPG2k::Scene::Battle#rebuild_battler_sprite (mruby-rpg2k/mrblib/scene/battle.rb:1247), and
# it is one of the nine shipped sends this removes. Whether the class flow reaches the exact
# arm depends on that flow, not on this change, so these only pin that the argument-side
# facts still hold when it does: the entry point is reached, and an unproven argument keeps
# both its test and its dispatch.
CONST_WORLD = <<~'RUBY'
  module NiZ
    VIEWPORT_Z = 5
    HALF = 3
  end
  class NiConst
    def build(w)
      w.flash(nil, 20)
      w.z
    end

    def build_constant_z(w)
      w.z = NiZ::VIEWPORT_Z
      w.z
    end

    def build_arithmetic(w)
      w.z = NiZ::HALF + NiZ::HALF
      w.z
    end

    def build_unknown(w, value)
      w.z = value
      w.z
    end
  end
RUBY
const_code = generate.call(CONST_WORLD, 'ni_const', true)
%w[build build_constant_z build_arithmetic].each do |name|
  body = body_of.call(const_code, "NiConst_#{name}")
  check.call("#{name} reaches a native entry point", body.include?('rgss::'))
  # When the class flow proves the receiver exact the arm is emitted without a test; when it
  # does not, the class-tested arm keeps its test. Both are correct, so assert only that the
  # two shapes are the only ones produced.
  check.call("#{name} has no :int test unless the arm is class-tested",
             body.include?('NATIVE_DIRECT_EXACT') || body.include?('mrb_integer_p'))
end
unknown = body_of.call(const_code, 'NiConst_build_unknown')
check.call('a parameter argument keeps its tag test and dispatch',
           unknown.include?('mrb_integer_p(') && unknown.include?('bc2cpp_send('))
check.call('the interval still reaches a setter entry point',
           body_of.call(const_code, 'NiConst_build_arithmetic').include?('rgss::object_z_set_direct('))

# The real proof, over its own contract rather than a synthetic world: the gates it must
# refuse. Every refusal here is a case where dropping the tag test would let a non-Integer
# reach mrb_integer(), so the emitter's use of it is only as safe as these.
prover = CodeGen.allocate
prover.instance_variable_set(:@fixnum_proof_skip_constants, false)
prover.define_singleton_method(:static_constant_world?) { true }
prover.define_singleton_method(:unshift_proof_reg) { |reg, _off| reg }
prover.define_singleton_method(:fixnum_interval) { |*_a| @interval }
prover.define_singleton_method(:proven_fixnum_operand?) { |*_a| @operand }
ask = ->(argv, position = 0) do
  prover.native_int_arg_proven?(nil, 1, nil, 0, argv, position)
end
prover.instance_variable_set(:@interval, true)
prover.instance_variable_set(:@operand, false)
check.call('the interval proves an :int argument', ask.call(%w[r4]))
check.call('an argument that is not a register is refused', !ask.call(%w[self]))
check.call('an argument that is not a register is refused (a constant expression)',
           !ask.call(['mrb_fixnum_value(1)']))
check.call('a second position is asked about separately',
           ask.call(%w[r3 r4], 1) && ask.call(%w[r3 r4], 0))
check.call('a position past the argument list is refused', !ask.call(%w[r3], 1))
prover.instance_variable_set(:@interval, false)
prover.instance_variable_set(:@operand, false)
check.call('neither proof answering is not a proof', !ask.call(%w[r4]))
prover.instance_variable_set(:@operand, true)
check.call('the operand proof alone answers', ask.call(%w[r4]))
prover.instance_variable_set(:@operand, false)
check.call('an empty argument list has no position', !ask.call([]))
# The emitter reads the same predicate the two older call sites do, and it is the one method
# the kill switch lives in, so a mutant that bypasses it has nowhere else to land.
check.call('the emitter asks the proof through one gate',
           cg.respond_to?(:native_int_guard_needed?) &&
             cg.method(:native_int_guard_needed?).owner == NativeDirectFallback)
if ENV['BC2CPP_KEEP_DIR']
  require 'fileutils'
  FileUtils.mkdir_p(ENV['BC2CPP_KEEP_DIR'])
  File.write(File.join(ENV['BC2CPP_KEEP_DIR'], 'native_int_guard.cxx'), code)
end

puts "\n#{failures.size} check(s) failed" unless failures.empty?
exit(failures.empty? ? 0 : 1)
