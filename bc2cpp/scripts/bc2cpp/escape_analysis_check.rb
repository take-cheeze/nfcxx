#!/usr/bin/env ruby
# encoding: UTF-8
#
# Check the shared escape analysis (tools/bc2cpp/escape_analysis.rb, docs/adr/0316) and its first consumer,
# BLOCK_FALLBACK_PROVEN: a literal block that captures locals by pointer may be handed to a callee that is
# not on BLOCK_FALLBACK_UPVAR_SAFE_METHODS when every definition the call can reach provably keeps neither
# the block nor anything that reaches it.
#
#   1. unit      the analysis on mrbc-compiled fixtures (each escape route a negative, each confined shape a
#                positive) and on hand-built bytecode, the callee summaries, the audited native tables;
#   2. generated the consumer's output, the worlds that withdraw it, the kill switch (BC2CPP_ESCAPE_ANALYSIS=0
#                must give the earlier output), the open world;
#   3. run       the compiled fixture against the interpreter on a full-core, a core-only and a 32-bit mrb_int
#                build (BC2CPP_BLOCK_DIRECT_ENTRY=0 on the last: ADR 0271 keeps a block's entry as an address
#                in a 32-bit slot, which this 64-bit host truncates).
#
# EA_MODE: all (default), static (unit and generated, no mruby build), unit, generated, run. EA_TOOL_DIR names a copy of tools/bc2cpp placed inside the
# repository (scripts/bc2cpp/escape_analysis_mutation_check.rb).
#
# Usage: MRBC=path/to/host/mrbc ruby scripts/bc2cpp/escape_analysis_check.rb

require 'etc'
require 'fileutils'
require 'open3'
require 'rbconfig'
require 'set'
require 'shellwords'
require 'tmpdir'

ROOT = File.expand_path('../..', __dir__)
TOOL_DIR = ENV['EA_TOOL_DIR'] || File.join(ROOT, 'tools/bc2cpp')
MRBC_PATH = ENV['MRBC'] || 'mrbc'
MODE = ENV['EA_MODE'] || 'all'
MRUBY = File.join(ROOT, '3rd/mruby')
ENV['MRBC'] = MRBC_PATH
require File.join(TOOL_DIR, 'bc2cpp')
require File.join(TOOL_DIR, 'escape_analysis')
require File.join(TOOL_DIR, 'compiled_gems')
require File.join(TOOL_DIR, 'nomethod_reviewed')
require File.join(TOOL_DIR, 'nomethod_reviewed_probe')
require_relative 'escape_fixture'

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

def tool?(name)
  system(name, '--version', out: File::NULL, err: File::NULL)
end

EA = EscapeAnalysis
have_mrbc = tool?(MRBC_PATH)
run_unit = %w[all static unit].include?(MODE)
run_generated = %w[all static generated].include?(MODE)
run_behaviour = %w[all run].include?(MODE)

# -- 1. unit -------------------------------------------------------------------------------------

if run_unit
  puts 'unit: hand-built bytecode'
  def insn(addr, op, args)
    Insn.new(lineno: 1, addr: addr, op: op, args: args, raw: "#{op} #{args}")
  end

  # A one-irep world whose single method holds +list+; `creation` analyses the instruction at +index+.
  build = lambda do |list, handlers = []|
    irep = Irep.new(label: 't', nlocals: 3, nregs: 8, pool: [], syms: [], reps: [], lv: [], instructions: list,
                    file: 't.rb', catch_handlers: handlers)
    irep.tree = { 't' => irep }
    analyzer = EA::Analyzer.new(EA::World.new(ireps: { 't' => irep }, defs: {}, native_names: Set.new))
    [irep, analyzer]
  end
  verdict_of = lambda do |list, index = 0, handlers = []|
    irep, analyzer = build.call(list, handlers)
    analyzer.creation(irep, index)
  end
  # ARRAY R1 0 builds the tracked value; `tail` follows it.
  after = lambda do |*tail|
    [insn(0, 'ARRAY', "R1\t0")] + tail.each_with_index.map { |(op, args), i| insn(2 + (2 * i), op, args) } +
      [insn(2 + (2 * tail.size), 'RETNIL', '')]
  end
  reason_of = ->(list, *rest) { verdict_of.call(list, *rest).reason }
  escape = lambda do |label, expected, *tail|
    check.call("#{label}: escapes as #{expected}", reason_of.call(after.call(*tail)) == expected)
  end
  confined = lambda do |label, *tail|
    check.call("#{label}: stays in the frame", !verdict_of.call(after.call(*tail)).escapes?)
  end

  confined.call('a register copy and a branch test', ['MOVE', "R2\tR1"], ['JMPIF', "R2\t6"])
  confined.call('overwritten before any use', ['LOADNIL', 'R1 (nil)'], ['SETIV', "@x\tR1"])
  escape.call('SETIV', :stored_ivar, ['SETIV', "@x\tR1"])
  escape.call('SETIV through a copy', :stored_ivar, ['MOVE', "R2\tR1"], ['SETIV', "@x\tR2"])
  escape.call('SETGV', :stored_global, ['SETGV', "$g\tR1"])
  escape.call('SETCV', :stored_classvar, ['SETCV', "@@c\tR1"])
  escape.call('SETCONST', :stored_constant, ['SETCONST', "K\tR1"])
  escape.call('SETUPVAR', :stored_upvar, ['SETUPVAR', "R1\t1\t0"])
  escape.call('RETURN', :returned, ['RETURN', 'R1'])
  escape.call('BREAK', :returned, ['BREAK', 'R1'])
  escape.call('RETURN_BLK', :returned, ['RETURN_BLK', 'R1'])
  escape.call('RAISEIF', :raised, ['RAISEIF', 'R1'])
  escape.call('RESCUE (as the matched class)', :rescue_operand, ['RESCUE', "R2\tR1"])
  escape.call('ASET', :stored_container, ['ASET', "R1\tR2\t0"])
  escape.call('ARRAY element', :stored_array, ['ARRAY', "R1\t1"])
  escape.call('HASH value', :stored_hash, ['HASH', "R0\t1"])
  escape.call('ARYPUSH', :stored_array, ['ARYPUSH', "R0\t1"])
  escape.call('RANGE_INC', :class_machinery, ['RANGE_INC', 'R1'])
  escape.call('ARYCAT', :spread_operand, ['ARYCAT', "R1\t(R2)"])
  escape.call('BLKCALL argument', :block_call_argument, ['BLKCALL', "R0\t1"])
  escape.call('an op the model does not name', :unmodelled_op, ['CALL', ''])
  confined.call('BLKCALL receiver', ['BLKCALL', "R1\t0"])
  confined.call('ARGARY of parameter slots the value is not in', ['ARGARY', "R2\t0:0:0:0\t(0)"])

  # Exception flow: the handler sees the register as it was entered.
  protected = [insn(0, 'ARRAY', "R1\t0"), insn(2, 'LOADNIL', 'R1 (nil)'), insn(4, 'RETNIL', ''),
               insn(6, 'EXCEPT', 'R2'), insn(8, 'SETIV', "@x\tR1"), insn(10, 'RETNIL', '')]
  handler = [CatchHandler.new(type: :rescue, begin_addr: 2, end_addr: 4, target: 6)]
  check.call('a handler edge carries the value in: SETIV in the handler escapes',
             reason_of.call(protected, 0, handler) == :stored_ivar)
  check.call('without the handler edge the same code is confined', !verdict_of.call(protected, 0, []).escapes?)
  unresolved = [insn(0, 'ARRAY', "R1\t0"), insn(2, 'JMP', '99'), insn(4, 'RETNIL', '')]
  check.call('a jump to a non-instruction is an escape', reason_of.call(unresolved) == :cfg_unresolved)
  loop_ = [insn(0, 'ARRAY', "R1\t0"), insn(2, 'MOVE', "R2\tR1"), insn(4, 'LOADNIL', 'R1 (nil)'),
           insn(6, 'JMPIF', "R3\t2"), insn(9, 'SETIV', "@x\tR2"), insn(11, 'RETNIL', '')]
  check.call('a copy made on a loop iteration stays tracked after the original is overwritten',
             reason_of.call(loop_) == :stored_ivar)
end

if run_unit && have_mrbc
  puts 'unit: mrbc-compiled fixtures'
  Dir.mktmpdir do |dir|
    File.write(File.join(dir, 'unit.rb'), EscapeFixture::UNIT)
    ireps, root = compile_ireps([File.join(dir, 'unit.rb')], 'unit', dir)
    reg, sup, _cc, inc, pre, unk, _sm, _cd, _w, _mb, _ca, mods, _alias = build_registry(ireps, root)
    world = EA::World.new(ireps: ireps, defs: reg, native_names: Set.new, superclass_of: sup, included: inc,
                          prepended: pre, unknown_mixins: unk, modules: mods)
    analyzer = EA::Analyzer.new(world)
    owners = {}
    reg.each_value { |list| list.each { |d| owners[d.irep] = d.owner if d.irep } }
    analyzer.self_class = ->(irep) { owners[irep.label] }
    methods = reg.values.flatten.select(&:irep).to_h { |d| [[d.owner, d.name], d] }
    site = lambda do |name|
      d = methods.fetch(['EaU', name])
      irep = ireps[d.irep]
      want = case name
             when /array/ then %w[ARRAY]
             when /string/ then %w[STRING]
             when /hash/ then %w[HASH]
             when /block/ then %w[BLOCK LAMBDA]
             else %w[LAMBDA BLOCK]
             end
      [irep, irep.instructions.index { |i| want.include?(i.op) }]
    end

    uses = lambda do |verdict|
      verdict.uses.map { |u| [u.kind, u.name] }
    end
    expected_uses = {
      'c_lambda_call' => [[:call, 'call']] * 2, 'c_lambda_alias' => [[:call, 'call']], 'c_lambda_loop' => [[:call, 'call']],
      'c_lambda_arg' => [[:pass_arg, 'run']], 'c_lambda_block_arg' => [[:pass_block, 'one']],
      'c_block_yield' => [[:pass_block, 'each_one']], 'c_block_two_frames' => [[:pass_block, 'two']]
    }
    EscapeFixture::UNIT.scan(/def (c_\w+)/).flatten.each do |name|
      irep, index = site.call(name)
      v = analyzer.creation(irep, index)
      check.call("#{name} is confined (#{v.reasons.inspect})", !v.escapes?)
      next unless expected_uses.key?(name)

      check.call("#{name} lists its uses #{expected_uses[name].inspect}", uses.call(v) == expected_uses[name])
    end
    expected_reason = {
      'e_return' => :returned, 'e_return_via_move' => :returned, 'e_ivar' => :stored_ivar, 'e_gvar' => :stored_global,
      'e_cvar' => :stored_classvar, 'e_array' => :returned, 'e_array_push' => :returned, 'e_hash' => :returned,
      'e_index_set' => :send_argument, 'e_range' => :class_machinery, 'e_arg_stored' => :send_argument,
      'e_arg_returned' => :send_argument, 'e_arg_unknown_callee' => :send_argument,
      'e_receiver_unknown' => :send_receiver, 'e_by_name_send' => :send_receiver, 'e_public_send_arg' => :send_argument,
      'e_method_object' => :send_receiver, 'e_ivar_set' => :send_argument, 'e_to_proc' => :send_receiver,
      'e_dup' => :send_receiver, 'e_raise' => :send_argument, 'e_call_with_self' => :send_argument,
      'e_closure_escapes' => :captured_by_escaping_closure, 'e_closure_returned' => :captured_by_escaping_closure,
      'e_block_stashed' => :send_block, 'e_block_returned' => :send_block, 'e_block_forwarded_to_stash' => :send_block,
      'e_block_through_each' => :send_block, 'e_block_unknown_callee' => :send_block, 'e_block_by_name' => :send_block,
      'e_block_proc_new' => :send_block, 'e_block_proc' => :send_block, 'e_block_lambda' => :send_block,
      'e_block_define_method' => :send_block, 'e_block_fiber' => :send_block, 'e_block_lambda_of_param' => :send_block,
      'e_array_element' => :returned, 'e_super' => :super_window, 'e_setupvar' => :returned,
      'e_string_cat' => :returned, 'e_class_body' => :captured_by_escaping_closure
    }
    EscapeFixture::UNIT.scan(/def (e_\w+)/).flatten.each do |name|
      irep, index = site.call(name)
      v = analyzer.creation(irep, index)
      check.call("#{name} escapes as #{expected_reason.fetch(name)} (got #{v.reason.inspect})", v.reason == expected_reason.fetch(name))
    end

    puts 'unit: callee summaries'
    summary = lambda do |owner, name, position|
      analyzer.captures?(methods.fetch([owner, name]), position)
    end
    {
      ['EaSink', 'run', [:arg, 0]] => false, ['EaSink', 'keep', [:arg, 0]] => true, ['EaSink', 'arg_ret', [:arg, 0]] => true,
      ['EaSink', 'chain', [:arg, 0]] => true, ['EaSink', 'quiet', [:arg, 0]] => false,
      ['EaSink', 'each_one', [:block]] => false, ['EaSink', 'stash', [:block]] => true, ['EaSink', 'give', [:block]] => true,
      ['EaSink', 'one', [:block]] => false, ['EaSink', 'two', [:block]] => false, ['EaSink', 'rec', [:block]] => false,
      ['EaSink', 'via_each', [:block]] => true, ['EaSink', 'forward', [:block]] => true,
      ['EaSink', 'block_to_proc', [:block]] => true, ['EaSink', 'with_block_arg', [:block]] => false,
      ['EaSink', 'self_ret', [:self]] => true, ['EaSink', 'self_keep', [:self]] => true, ['EaSink', 'self_call', [:self]] => true,
      ['EaSink', 'quiet', [:self]] => false, ['EaSink', 'run', [:self]] => false
    }.each do |(owner, name, position), captures|
      check.call("#{owner}##{name} #{position.inspect}: #{captures ? 'captures' : 'keeps nothing'}", summary.call(owner, name, position) == captures)
    end
    check.call('a position past the mandatory arguments is not modelled, so it captures',
               analyzer.captures?(methods.fetch(['EaSink', 'quiet']), [:arg, 3]))

    puts 'unit: receiver classes sharpen the callee set'
    shadow = <<~'RUBY'
      class EaA; def go(&b); b.call(1); end; end
      class EaB < EaA; def go(&b); @k = b; end; end
      class EaC; def go(&b); b.call(2); end; end
      class EaUse
        def one(a); t = 0; a.go { |x| t += x }; t; end
        def two; t = 0; EaC.new.go { |x| t += x }; t; end
      end
    RUBY
    File.write(File.join(dir, 'shadow.rb'), shadow)
    ireps2, root2 = compile_ireps([File.join(dir, 'shadow.rb')], 'shadow', dir)
    reg2, sup2, _a, inc2, pre2, unk2, _b, _c, _d, _e, _f, mods2, = build_registry(ireps2, root2)
    world2 = EA::World.new(ireps: ireps2, defs: reg2, native_names: Set.new, superclass_of: sup2, included: inc2,
                           prepended: pre2, unknown_mixins: unk2, modules: mods2)
    an2 = EA::Analyzer.new(world2)
    meth2 = reg2.values.flatten.select(&:irep).to_h { |d| [[d.owner, d.name], d] }
    block_site = lambda do |name|
      irep = ireps2[meth2.fetch(['EaUse', name]).irep]
      [irep, irep.instructions.index { |i| i.op == 'BLOCK' }]
    end
    irep, index = block_site.call('one')
    check.call('an unknown receiver reaches EaB#go, which keeps the block', an2.creation(irep, index).escapes?)
    an2.receiver_classes = ->(_irep, _idx, _reg) { %w[EaA] }
    check.call('a receiver the class flow places at EaA excludes EaB#go (exact class)', !an2.creation(irep, index).escapes?)
    an2.receiver_classes = ->(_irep, _idx, _reg) { %w[EaA EaB] }
    check.call('a class set that includes EaB keeps the escape', an2.creation(irep, index).escapes?)
    an3 = EA::Analyzer.new(world2)
    irep, index = block_site.call('two')
    check.call('a different class with the same method name does not interfere once the receiver is known',
               !(an3.receiver_classes = ->(_irep, _idx, _reg) { %w[EaC] }).nil? && !an3.creation(irep, index).escapes?)
    an4 = EA::Analyzer.new(world2)
    check.call('and an unknown receiver of that call reaches every go', an4.creation(irep, index).escapes?)

    puts 'unit: world facts'
    check.call('a name an invisible definer can make has no enumerable definitions',
               EA::World.new(ireps: ireps2, defs: reg2, invisible: ->(n) { n == 'go' }).defs_named('go').nil?)
    check.call('an alias adds the definitions of its target',
               EA::World.new(ireps: ireps2, defs: reg2, aliases: { 'other' => ['go'] }).defs_named('other').size == 3)
    check.call('an unknown mixin makes a class unplaceable, so every definition stays',
               EA::World.new(ireps: ireps2, defs: reg2, superclass_of: sup2, unknown_mixins: Set['EaA'])
                 .defs_for('go', %w[EaA], true).size == 3)
    check.call('a Struct-made class keeps Struct in its ancestry',
               EA::World.new(ireps: ireps2, defs: reg2, struct_classes: ['Pt']).send(:mro, 'Pt').include?('Enumerable'))
    refl = <<~'RUBY'
      class EaR; def go; binding; end; def mk; f = ->(n) { n }; f.call(1); end; end
    RUBY
    File.write(File.join(dir, 'refl.rb'), refl)
    ireps3, root3 = compile_ireps([File.join(dir, 'refl.rb')], 'refl', dir)
    reg3, = build_registry(ireps3, root3)
    world3 = EA::World.new(ireps: ireps3, defs: reg3, native_names: Set.new)
    an5 = EA::Analyzer.new(world3)
    mk = reg3.values.flatten.find { |d| d.name == 'mk' }
    irep = ireps3[mk.irep]
    check.call('a program that reads frames by name (binding) confines nothing',
               !world3.reflective_sites.empty? && an5.creation(irep, irep.instructions.index { |i| i.op == 'LAMBDA' }).reason == :reflection)
  end
end

if run_unit
  puts 'unit: audited native facts'
  native_srcs = core_native_srcs(MRUBY) + external_gem_native_srcs(ROOT) + Dir[File.join(ROOT, 'mruby-rgss/src/*.cxx')]
  if File.exist?(File.join(MRUBY, 'Rakefile'))
    sources = extract_native_method_sources(native_srcs)
    EA::NATIVE_MANIFEST.each do |name, files|
      found = (sources[name] || []).map { |f| f.sub("#{ROOT}/", '') }.uniq.sort
      check.call("native `#{name}` is registered by exactly the audited files #{files.inspect} (found #{found.inspect})",
                 found == files.sort)
    end
    check.call('every NATIVE_BLOCK_NO_CAPTURE name has a manifest entry',
               EA::NATIVE_BLOCK_NO_CAPTURE.to_a.sort == EA::NATIVE_MANIFEST.keys.sort)
    %w[each map times each_with_index inject reduce].each do |iterator|
      check.call("`#{iterator}` has no native definition: its summary comes from bytecode", !sources.key?(iterator))
    end
  else
    puts '  -- SKIP native manifest: needs 3rd/mruby'
  end
end

# -- 2. generated code ---------------------------------------------------------------------------

OWNERS = %w[EaFx EaSink EaOther].freeze
gems = NomethodReviewedProbe.wio_gems(ROOT)
native_srcs = core_native_srcs(MRUBY) + external_gem_native_srcs(ROOT)
core_srcs = core_compiled_mrblib_srcs(ROOT)

generate = lambda do |source, name, closed: true, core: false, extra_env: {}, outside_gem: nil, native: nil, owners: OWNERS|
  Dir.mktmpdir do |dir|
    path = File.join(dir, "#{name}.rb")
    File.write(path, source)
    natives = native_srcs.dup
    foreigns = foreign_mrblib_srcs(ROOT)
    if native
      File.write(File.join(dir, 'extra_native.c'), native)
      natives << File.join(dir, 'extra_native.c')
    end
    build_gems = gems.dup
    if outside_gem
      FileUtils.mkdir_p(File.join(dir, 'outside_gem/mrblib'))
      File.write(File.join(dir, 'outside_gem/mrblib/outside.rb'), outside_gem)
      build_gems['ea-outside'] = File.join(dir, 'outside_gem')
    end
    env = { 'MRBC' => MRBC_PATH, 'OUT_SYMBOL' => name, 'OUT_DIR' => dir, 'SKIP_UNSUPPORTED' => '1',
            'NATIVE_SRCS' => Shellwords.join(natives), 'FOREIGN_RUBY_SRCS' => Shellwords.join(foreigns),
            'ONLY_OWNERS' => owners.join(',') }
    if closed
      env.merge!('BC2CPP_CLOSED_WORLD' => '1', 'BC2CPP_BUILD_NAME' => 'wio',
                 'BC2CPP_BUILD_GEMS' => Shellwords.join(build_gems.map { |n, d| "#{n}=#{d}" }),
                 NomethodReviewed::ALLOW_ENV => 'allow')
    end
    srcs = (core ? core_srcs : []) + [path]
    out, err, status = Open3.capture3(env.merge(extra_env), RbConfig.ruby, File.join(TOOL_DIR, 'bc2cpp.rb'), '--annotated', *srcs)
    abort "bc2cpp.rb failed for #{name}:\n#{err[-3000..] || err}" unless status.success?
    out
  end
end

compiled = ->(code, method) { code.match?(/^mrb_value EaFx_#{Regexp.escape(method)}_impl\(mrb_state\* M/) }
captured = ->(code, method) { code[/^mrb_value EaFx_#{Regexp.escape(method)}_impl\(mrb_state\* M.*?(?=^mrb_value |\z)/m].to_s.include?('bc2cpp_upvar_') }
PROVEN = %w[p_sum p_nested p_two p_walk p_break p_return p_next p_mutate p_fwd p_gc p_destructure p_raise].freeze
# Compiled only because a proven method needs it: the helper whose own block yields to its caller's.
HELPERS = %w[twice_fwd].freeze
NOT_PROVEN = %w[n_stash n_give n_send n_unknown n_fiber_yield].freeze

if run_generated && have_mrbc
  puts 'generated code'
  program = EscapeFixture::PROGRAM
  new_code = generate.call(program, 'ea_new')
  off_code = generate.call(program, 'ea_off', extra_env: { 'BC2CPP_ESCAPE_ANALYSIS' => '0' })

  puts ' 1. blocks to callees the by-name list does not name'
  PROVEN.each do |m|
    check.call("#{m}: compiled with the captured locals", compiled.call(new_code, m) && captured.call(new_code, m))
    check.call("#{m}: the kill switch returns to the interpreter (method not emitted)", !compiled.call(off_code, m))
  end
  NOT_PROVEN.each do |m|
    check.call("#{m}: a callee that keeps the block, or a send the analysis cannot see through, stays interpreted",
               !compiled.call(new_code, m))
  end
  check.call('an existing confined lambda is unchanged by the switch',
             compiled.call(new_code, 'p_lambda') && compiled.call(off_code, 'p_lambda') &&
             new_code[/EaFx_p_lambda_impl.*?(?=^mrb_value )/m].to_s.scan('CONFINED_LAMBDA_CALL').size ==
             off_code[/EaFx_p_lambda_impl.*?(?=^mrb_value )/m].to_s.scan('CONFINED_LAMBDA_CALL').size)
  functions = ->(code) { code.scan(/^mrb_value (Ea\w+)_impl\(mrb_state\* M/).flatten.sort }
  check.call('the analysis adds exactly the proven methods to what the kill switch emits',
             (functions.call(new_code) - functions.call(off_code)).sort == (PROVEN + HELPERS).map { |m| "EaFx_#{m}" }.sort &&
             (functions.call(off_code) - functions.call(new_code)).empty?)

  puts ' 2. worlds that withdraw the proof'
  withdrawn = lambda do |label, source, methods, **options|
    code = generate.call(source, 'ea_world', **options)
    check.call("#{label}: #{methods.join(', ')} back to the interpreter", methods.none? { |m| compiled.call(code, m) })
    code
  end
  untouched = lambda do |label, code, methods|
    check.call("#{label}: #{methods.join(', ')} still compiled", methods.all? { |m| compiled.call(code, m) })
  end
  sub = withdrawn.call('a subclass override of the callee keeps the block', "#{program}\nclass EaFxKeep < EaFx\n  def spin(n, &b); @kept = b; n; end\nend\n",
                       %w[p_sum p_nested p_next p_mutate p_gc p_break p_return p_raise p_two p_fwd])
  untouched.call('a subclass override of `spin` does not touch the other callees', sub, %w[p_walk p_destructure])
  withdrawn.call('a module prepended to the class defines the callee ahead of it',
                 "#{program}\nmodule EaPre\n  def pair_up(&b); @kept = b; end\nend\nclass EaFx\n  prepend EaPre\nend\n", %w[p_destructure])
  shadowed = generate.call("#{program}\nmodule EaInc\n  def pair_up(&b); @kept = b; end\nend\nclass EaFx\n  include EaInc\nend\n", 'ea_world')
  untouched.call('a module included in the class sits behind its own definition and is never reached', shadowed, %w[p_destructure])
  shadowed_object = generate.call("#{program}\nclass Object\n  def pair_up(&b); @kept = b; end\nend\n", 'ea_world')
  untouched.call('a definition on Object sits behind the class\'s own', shadowed_object, %w[p_destructure])
  withdrawn.call('an alias of the callee name to a method that keeps its block',
                 "#{program}\nclass EaFx\n  alias_method :spin, :ea_keep\n  def ea_keep(n, &b); @kept = b; n; end\nend\n", %w[p_sum p_nested p_two])
  withdrawn.call('define_method of the callee name', "#{program}\nclass EaFx\n  define_method(:spin) { |n, &b| @kept = b; n }\nend\n", %w[p_sum p_nested])
  withdrawn.call('method_missing in the program (an unknown name can reach it with the block)',
                 "#{program}\nclass EaFx\n  def method_missing(n, *a, &b); @kept = b; end\nend\n", %w[p_sum p_walk p_destructure])
  withdrawn.call('an interpreted outside Ruby source defining the callee', program, %w[p_sum p_nested],
                 outside_gem: "class EaFx\n  def spin(n, &b); @kept = b; n; end\nend\n")
  withdrawn.call('a native registering the callee name', program, %w[p_sum p_nested],
                 native: "static void ea_init(mrb_state* M, struct RClass* c) { mrb_define_method(M, c, \"spin\", ea_spin, MRB_ARGS_REQ(1)); }\n")
  withdrawn.call('a program that reads frames by name (binding)', "#{program}\nclass EaFx\n  def peek; binding; end\nend\n", %w[p_sum p_nested p_walk])
  withdrawn.call('ObjectSpace in the program', "#{program}\nclass EaFx\n  def scan; ObjectSpace; end\nend\n", %w[p_sum p_walk])
  withdrawn.call('a computed define_method', "#{program}\nclass EaFx\n  def make(n); self.class.define_method(n) { 1 }; end\nend\n", %w[p_sum p_walk])
  withdrawn.call('define_method reached through send', "#{program}\nclass EaFx\n  def make; self.class.send(:define_method, :spin) { |n, &b| @kept = b }; end\nend\n", %w[p_sum p_nested])
  open_code = generate.call(program, 'ea_open', closed: false)
  check.call('without the closed world the proof is not offered',
             PROVEN.none? { |m| compiled.call(open_code, m) })
  untouched.call('and the closed-world run of the same program', new_code, PROVEN)
end

# -- 3. behaviour --------------------------------------------------------------------------------

ran_behaviour = false
if run_behaviour
  unless have_mrbc && tool?('rake') && tool?('g++') && File.exist?(File.join(MRUBY, 'Rakefile'))
    puts '-- SKIP behavioural comparison: needs a host mrbc, 3rd/mruby, rake and g++'
  else
    ran_behaviour = true
    GEM_RAKE = <<~'RAKE'
      require 'shellwords'
      ROOT = ENV.fetch('BC2CPP_ROOT')
      require "#{ROOT}/tools/bc2cpp/compiled_gems"
      require "#{ROOT}/tools/bc2cpp/nomethod_reviewed"
      require "#{ROOT}/tools/bc2cpp/nomethod_reviewed_probe"

      MRuby::Gem::Specification.new('bc2cpp-escape-test') do |spec|
        spec.license = 'MIT'
        spec.author = 'rpg-maker-clone'
        spec.summary = 'harness: a closed-world fixture compiled with the compiled core'

        (BC2CPP_CORE_MRBLIB_GEMS + BC2CPP_EXTERNAL_MRBLIB_GEMS).each do |gem_name|
          add_dependency gem_name if spec.build.gems.any? { |g| g.name == gem_name }
        end

        if ENV['BC2CPP_ESCAPE_COMPILED'] == '1'
          generated = "#{build_dir}/ea_gen.cpp"
          prerequisites = [*Dir["#{ROOT}/tools/bc2cpp/*.rb"], File.join(ROOT, 'tools/bc2cpp/core_refused.txt'), spec.build.mrbcfile]
          file generated => prerequisites do
            FileUtils.mkdir_p build_dir
            gems = NomethodReviewedProbe.wio_gems(ROOT)
            srcs = core_compiled_mrblib_srcs(ROOT, spec.build.gems.map(&:name)) + [ENV.fetch('BC2CPP_ESCAPE_FIXTURE')]
            native = core_native_srcs("#{ROOT}/3rd/mruby") + external_gem_native_srcs(ROOT)
            env = { 'MRBC' => spec.build.mrbcfile.to_s, 'OUT_SYMBOL' => 'ea', 'OUT_DIR' => build_dir,
                    'ONLY_OWNERS' => (BC2CPP_CORE_OWNERS + %w[EaFx EaSink EaOther]).join(','),
                    'NATIVE_SRCS' => Shellwords.join(native), 'FOREIGN_RUBY_SRCS' => Shellwords.join(foreign_mrblib_srcs(ROOT)),
                    'SKIP_UNSUPPORTED' => '1', 'BC2CPP_CLOSED_WORLD' => '1', 'BC2CPP_BUILD_NAME' => 'wio',
                    'BC2CPP_BUILD_GEMS' => Shellwords.join(gems.map { |n, d| "#{n}=#{d}" }),
                    NomethodReviewed::ALLOW_ENV => 'allow' }
            cmd = "#{RbConfig.ruby.shellescape} #{ROOT}/tools/bc2cpp/bc2cpp.rb --annotated #{srcs.map(&:shellescape).join(' ')} " \
                  "> #{generated.shellescape} 2> #{build_dir}/ea.diag"
            sh env, cmd
          end
          file "#{dir}/src/register.cxx" => generated
        end
        cxx.include_paths << build_dir
        cxx.include_paths << "#{ROOT}/include"
      end
    RAKE

    register_cxx = lambda do |compiled_build|
      <<~CPP
        #include <mruby.h>
        #include <mruby/class.h>
        #include <mruby/compile.h>
        #{compiled_build ? '#include "ea_gen.cpp"' : ''}

        static const char* const kFixture = R"EAFX(#{EscapeFixture::PROGRAM})EAFX";

        extern "C" void mrb_bc2cpp_escape_test_gem_init(mrb_state* M) {
          mrb_load_string(M, kFixture);
          if (M->exc) { mrb_print_error(M); M->exc = nullptr; }
        #{compiled_build ? '  bc2cpp_set_instance_tts(M);' : ''}
        #{compiled_build ? '  bc2cpp_register_owner_methods(M);' : ''}
        }

        extern "C" void mrb_bc2cpp_escape_test_gem_final(mrb_state*) {}
      CPP
    end

    # The core-only build is mruby's own mrblib with only mruby-io (for puts) on top: Fiber and the *-ext
    # methods are absent, so the driver tolerates what it lacks in both builds.
    VARIANTS = {
      'full-core' => ["conf.gembox 'full-core'\n  conf.gem \"\#{ENV.fetch('BC2CPP_ROOT')}/3rd/mruby-stringio\"", ''],
      'core-only' => ["conf.gem core: 'mruby-bin-mruby'\n  conf.gem core: 'mruby-bin-mrbc'\n  conf.gem core: 'mruby-io'", ''],
      'int32' => ["conf.gembox 'full-core'\n  conf.gem \"\#{ENV.fetch('BC2CPP_ROOT')}/3rd/mruby-stringio\"",
                  "[conf.cc, conf.cxx].each { |t| t.defines << 'MRB_32BIT' << 'MRB_INT32' }"]
    }.freeze

    config_for = lambda do |variant|
      variant_gems, defines = VARIANTS.fetch(variant)
      <<~RUBY
        MRuby::Build.new('host') do |conf|
          toolchain :gcc
          #{variant_gems}
          conf.gem ENV['BC2CPP_HARNESS_GEM']
          #{defines}
          conf.cxx.flags << '-std=gnu++17'
          enable_cxx_exception
          enable_debug
          [conf.cc, conf.cxx].each { |t| t.flags = t.flags.flatten.delete_if { |v| v == '-O0' } << '-O1' }
        end
      RUBY
    end

    work = ENV['EA_DIR'] || Dir.mktmpdir('bc2cpp_escape')
    FileUtils.mkdir_p(work)
    File.write(File.join(work, 'fixture.rb'), EscapeFixture::PROGRAM)
    File.write(File.join(work, 'driver.rb'), EscapeFixture::DRIVER)

    build_and_run = lambda do |variant, compiled_build|
      name = "#{variant}_#{compiled_build ? 'compiled' : 'interpreted'}"
      File.write(File.join(work, "config_#{variant}.rb"), config_for.call(variant))
      gem_dir = File.join(work, "gem_#{name}")
      FileUtils.mkdir_p(File.join(gem_dir, 'src'))
      File.write(File.join(gem_dir, 'mrbgem.rake'), GEM_RAKE)
      File.write(File.join(gem_dir, 'src/register.cxx'), register_cxx.call(compiled_build))
      build = File.join(work, name)
      FileUtils.mkdir_p(File.join(build, 'repos/host'))
      FileUtils.ln_sf(File.join(ROOT, '3rd/mgem-list'), File.join(build, 'repos/host/mgem-list'))
      env = { 'BC2CPP_ROOT' => ROOT, 'MRUBY_CONFIG' => File.join(work, "config_#{variant}.rb"), 'MRUBY_BUILD_DIR' => build,
              'BC2CPP_HARNESS_GEM' => gem_dir, 'BC2CPP_ESCAPE_COMPILED' => compiled_build ? '1' : '0',
              'BC2CPP_ESCAPE_FIXTURE' => File.join(work, 'fixture.rb') }
      env['BC2CPP_BLOCK_DIRECT_ENTRY'] = '0' if variant == 'int32'
      out, status = Open3.capture2e(env, 'rake', '-m', "-j#{[Etc.nprocessors, 16].min}", 'all', chdir: MRUBY)
      File.write(File.join(work, "#{name}.log"), out)
      bin = File.join(build, 'host/bin/mruby')
      result = status.success? && File.exist?(bin) ? Open3.capture2e(bin, File.join(work, 'driver.rb')).first : nil
      gen = File.join(build, 'host/mrbgems/bc2cpp-escape-test/ea_gen.cpp')
      code = File.exist?(gen) ? File.read(gen) : ''
      FileUtils.rm_rf(build) unless ENV['EA_DIR']
      [result, out, code]
    end

    (ENV['EA_VARIANTS'] || VARIANTS.keys.join(',')).split(',').each do |variant|
      puts "escape analysis (#{variant}): interpreted baseline"
      base_out, base_log, = build_and_run.call(variant, false)
      check.call("#{variant}: the interpreted build runs the driver", base_out && base_out.lines.last == "end\n")
      puts base_log.lines.last(15).join unless base_out
      puts "escape analysis (#{variant}): compiled fixture over the compiled core"
      comp_out, comp_log, gen_code = build_and_run.call(variant, true)
      check.call("#{variant}: the compiled build runs the driver", comp_out && comp_out.lines.last == "end\n")
      puts comp_log.lines.last(25).join unless comp_out
      next unless base_out && comp_out

      check.call("#{variant}: driver output, #{base_out.lines.size} lines, interpreted and compiled identical", base_out == comp_out)
      unless base_out == comp_out
        base_out.lines.zip(comp_out.lines).reject { |a, b| a == b }.first(10).each do |a, b|
          puts "    interpreted: #{a}    compiled:    #{b}"
        end
      end
      check.call("#{variant}: the harness compiled the proven methods with captured locals",
                 PROVEN.all? { |m| compiled.call(gen_code, m) && captured.call(gen_code, m) })
      unless variant == 'core-only'
        check.call("#{variant}: Array#combination, which only the analysis lets compile, is in the compiled core",
                   gen_code.include?('Array_combination_impl'))
      end
      check.call("#{variant}: the Fiber section ran and agreed", comp_out.include?('fiber: ')) if variant == 'full-core'
    end
    FileUtils.rm_rf(work) unless ENV['EA_DIR']
  end
end

if failures.empty?
  puts "bc2cpp escape analysis check: PASS#{ran_behaviour ? '' : ' (no behavioural run)'}"
else
  warn "bc2cpp escape analysis check: #{failures.size} failure(s)"
  exit 1
end
