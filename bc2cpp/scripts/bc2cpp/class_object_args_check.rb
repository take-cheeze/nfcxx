#!/usr/bin/env ruby
# frozen_string_literal: true

# Check CLASS_OBJECT_ARGS: the receiver of a `klass.new(...)` that is a parameter of a method (read
# directly, or by a block through GETUPVAR) names the classes its callers pass, so one generic helper
# (`def table(id, klass, name) klass.new(r, path) end`) no longer withdraws every initialize that takes two arguments.
#
# 1. Host only (no mrbc): CodeGen's resolver on hand-built bytecode with a stub closed world. Positives: a parameter
#    every call site fills with class constants, a union of two constants, a parameter forwarded through a second
#    method, a block reading a never-rewritten parameter, a name with two definitions told apart by arity. Negatives:
#    an argument that is not a constant, a Symbol or alias naming the method, a splat or keyword call, a name an
#    outside source calls, a computed-name send, a rewritten or block-written parameter, a `super` into the body, a
#    constant that may bind a non-class, a method with a rest parameter, recursion, the kill switch.
# 2. With MRBC: the generated code of a closed-world fixture. The helper's classes are constructed with the pooled
#    arguments (the Array loses its class test and its by-name else); a fixture whose helper is also handed a
#    non-constant class, called through a Symbol, or reached by `super` keeps both.
#    COA_GENERATED_ONLY=1 stops here.
#
# Usage: [MRBC=path/to/mrbc] ruby scripts/bc2cpp/class_object_args_check.rb

# The fixture program defines none of the engine's classes, which sig/bc2cpp/declarations.rbs declares, so the
# shipped signatures would all be unusable (TC1003). Checked against no signature world, as block_iterator_direct_check does.
ENV['BC2CPP_SIG_DIRS'] = ''

require 'set'
require 'tmpdir'
require_relative 'fixture_runtime'

TOOLS = ENV['BC2CPP_TOOL'] ? File.dirname(ENV['BC2CPP_TOOL']) : File.expand_path('../../tools/bc2cpp', __dir__)
%w[irep bytecode_ir numeric_flow codegen dynamic_names codegen_numeric_proof codegen_numeric_args codegen_captured_locals
   codegen_class_object_args].each { |file| require File.join(TOOLS, file) }

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

def insn(addr, op, args)
  Insn.new(lineno: 1, addr: addr, op: op, args: args, raw: "#{op} #{args}")
end

# The slice of ClosedWorld the resolver asks. `classes` maps a constant to the classes it names; a name in `non_class`
# may be bound to a non-class; `outside` is what outside code calls.
class CoaWorld
  attr_accessor :classes, :non_class, :outside, :literals, :unknown

  def initialize
    @classes = {}
    @non_class = Set.new
    @outside = Set.new
    @literals = Set.new
    @unknown = Set.new
  end

  def class_valued_constant?(name) = @classes.key?(name) && !@non_class.include?(name)
  def classes_named(name) = @classes.fetch(name, [])
  def unknown_def?(name) = @unknown.include?(name)
  def outside_call_names(_files) = @outside
  def outside_native_literal?(name) = @literals.include?(name)
end

# A headless CodeGen over hand-built ireps: `defs` is [[owner, name, label], ...].
def coa_codegen(ireps, defs, world, capture: true)
  tree = ireps.to_h { |irep| [irep.label, irep] }
  ireps.each { |irep| irep.tree = tree }
  cg = CodeGen.allocate
  registry = Hash.new { |h, k| h[k] = [] }
  owner_of = {}
  defs.each do |owner, name, label|
    md = MethodDef.new(name: name, owner: owner, irep: label, core: nil)
    registry[name] << md
    owner_of[label] = md
  end
  cg.instance_variable_set(:@ireps, tree)
  cg.instance_variable_set(:@registry, registry)
  cg.instance_variable_set(:@owner_of, owner_of)
  cg.instance_variable_set(:@closed_world, world)
  cg.instance_variable_set(:@foreign_method_names, Set.new)
  cg.define_singleton_method(:captured_local_class_enabled?) { capture }
  cg
end

def coa_irep(label, list, reps: [])
  Irep.new(label: label, nlocals: 6, nregs: 10, pool: [], syms: [], reps: reps, instructions: list, catch_handlers: [], file: 'coa.rb')
end

# def table(id, klass, name); klass.new(1, 2); end   -- the `new` is instruction 2 (receiver R4).
def coa_table(label = 'T', body: nil)
  list = body || [insn(0, 'ENTER', "3:0:0:0:0:0:0:0\t(0x0)"), insn(2, 'MOVE', "R4\tR2"), insn(4, 'SEND', "R4\t:new\tn=2"), insn(7, 'RETURN', 'R4')]
  coa_irep(label, list)
end

# A caller: `table 1, <klass>, :x` with the class argument supplied by +klass_ops+ (instructions writing R3).
def coa_caller(label, klass_ops, name: 'table', call: 'SSEND', argc: 3)
  list = [insn(0, 'LOADSELF', "R1\t(R1)"), insn(2, 'LOADI_1', 'R2 (1)')] + klass_ops +
         [insn(20, call, "R1\t:#{name}\tn=#{argc}"), insn(24, 'RETURN', 'R1')]
  coa_irep(label, list)
end

def coa_const(name) = [insn(4, 'GETCONST', "R3\t#{name}"), insn(8, 'LOADSYM', "R4\t:x")]

# classes the `new` receiver of the table body resolves to.
def coa_resolve(cg, irep)
  index = irep.instructions.index { |i| i.op == 'SEND' && i.sym == 'new' }
  cg.class_object_receiver_classes(irep, index, irep.instructions[index])
end

puts '-- resolver on hand-built bytecode (host)'
world = CoaWorld.new
world.classes = { 'Title' => ['LCF::Title'], 'System' => ['LCF::System'], 'Plain' => ['Plain'] }
defs = [['Rec', 'table', 'T']]

table = coa_table
one = coa_caller('C1', coa_const('Title'))
cg = coa_codegen([table, one], defs + [['Host', 'run', 'C1']], world)
check.call('a parameter every caller fills with one constant names that class', coa_resolve(cg, table) == ['LCF::Title'])

two = coa_caller('C2', coa_const('System'))
cg = coa_codegen([coa_table, one, two], defs + [['Host', 'a', 'C1'], ['Host', 'b', 'C2']], world)
check.call('two callers give the union, sorted', coa_resolve(cg, cg.instance_variable_get(:@ireps)['T']) == ['LCF::System', 'LCF::Title'])

unknown_arg = coa_caller('C3', [insn(4, 'SEND0', "R3\t:klass_of"), insn(7, 'LOADSYM', "R4\t:x")])
cg = coa_codegen([coa_table, one, unknown_arg], defs + [['Host', 'a', 'C1'], ['Host', 'c', 'C3']], world)
check.call('one caller passing a call result leaves the receiver unresolved', coa_resolve(cg, cg.instance_variable_get(:@ireps)['T']).nil?)

nonclass = CoaWorld.new.tap { |w| w.classes = world.classes.dup; w.non_class << 'Title' }
cg = coa_codegen([coa_table, one], defs + [['Host', 'run', 'C1']], nonclass)
check.call('a constant that may bind a non-class is not a class', coa_resolve(cg, cg.instance_variable_get(:@ireps)['T']).nil?)

sym = coa_irep('CS', [insn(0, 'LOADSYM', "R2\t:table"), insn(3, 'RETURN', 'R2')])
cg = coa_codegen([coa_table, one, sym], defs + [['Host', 'a', 'C1'], ['Host', 's', 'CS']], world)
check.call('a Symbol naming the method poisons it', coa_resolve(cg, cg.instance_variable_get(:@ireps)['T']).nil?)

splat = coa_irep('CP', [insn(0, 'LOADSELF', "R1\t(R1)"), insn(2, 'SSEND', "R1\t:table\tn=*"), insn(6, 'RETURN', 'R1')])
cg = coa_codegen([coa_table, one, splat], defs + [['Host', 'a', 'C1'], ['Host', 'p', 'CP']], world)
check.call('a splat call poisons it', coa_resolve(cg, cg.instance_variable_get(:@ireps)['T']).nil?)

kw = coa_irep('CK', [insn(0, 'LOADSELF', "R1\t(R1)"), insn(2, 'SSEND', "R1\t:table\tn=2|nk=1"), insn(6, 'RETURN', 'R1')])
cg = coa_codegen([coa_table, one, kw], defs + [['Host', 'a', 'C1'], ['Host', 'k', 'CK']], world)
check.call('a keyword call poisons it', coa_resolve(cg, cg.instance_variable_get(:@ireps)['T']).nil?)

aliased = coa_irep('CA', [insn(0, 'ALIAS', "\t:other\ttable"), insn(3, 'RETURN', 'R1')])
cg = coa_codegen([coa_table, one, aliased], defs + [['Host', 'a', 'C1'], ['Host', 'l', 'CA']], world)
check.call('an alias of the method poisons it', coa_resolve(cg, cg.instance_variable_get(:@ireps)['T']).nil?)

outside = CoaWorld.new.tap { |w| w.classes = world.classes; w.outside << 'table' }
cg = coa_codegen([coa_table, one], defs + [['Host', 'run', 'C1']], outside)
check.call('a name an outside source calls is refused', coa_resolve(cg, cg.instance_variable_get(:@ireps)['T']).nil?)
literal = CoaWorld.new.tap { |w| w.classes = world.classes; w.literals << 'table' }
cg = coa_codegen([coa_table, one], defs + [['Host', 'run', 'C1']], literal)
check.call('a native string literal spelling it is refused', coa_resolve(cg, cg.instance_variable_get(:@ireps)['T']).nil?)
unknown = CoaWorld.new.tap { |w| w.classes = world.classes; w.unknown << 'table' }
cg = coa_codegen([coa_table, one], defs + [['Host', 'run', 'C1']], unknown)
check.call('a definition the registry cannot see is refused', coa_resolve(cg, cg.instance_variable_get(:@ireps)['T']).nil?)

cg = coa_codegen([coa_table, one], defs + [['Host', 'run', 'C1']], world, capture: true)
cg.instance_variable_get(:@foreign_method_names).add('table')
check.call('a method a foreign Ruby source also defines is refused', coa_resolve(cg, cg.instance_variable_get(:@ireps)['T']).nil?)

spelled = coa_irep('CC', [insn(0, 'STRING', "R2\tL[0]"), insn(3, 'RETURN', 'R2')])
spelled.pool = ['table']
cg = coa_codegen([coa_table, one, spelled], defs + [['Host', 'a', 'C1'], ['Host', 'c', 'CC']], world)
check.call('a name the program spells as a String (a computed-name send can reach it) is refused',
           coa_resolve(cg, cg.instance_variable_get(:@ireps)['T']).nil?)
unspelled = coa_irep('CU', [insn(0, 'STRING', "R2\tL[0]"), insn(3, 'RETURN', 'R2')])
unspelled.pool = ['elsewhere']
cg = coa_codegen([coa_table, one, unspelled], defs + [['Host', 'a', 'C1'], ['Host', 'c', 'CU']], world)
check.call('and an unrelated String does not refuse it', coa_resolve(cg, cg.instance_variable_get(:@ireps)['T']) == ['LCF::Title'])

# Two definitions of the name: the zero-argument one cannot take a three-argument call.
other = coa_irep('O', [insn(0, 'ENTER', "0:0:0:0:0:0:0:0\t(0x0)"), insn(2, 'RETNIL', '')])
zero_call = coa_irep('CZ', [insn(0, 'LOADSELF', "R1\t(R1)"), insn(2, 'SSEND0', "R1\t:table"), insn(5, 'RETURN', 'R1')])
cg = coa_codegen([coa_table, one, other, zero_call], defs + [['Other', 'table', 'O'], ['Host', 'a', 'C1'], ['Host', 'z', 'CZ']], world)
check.call('a name with two definitions is told apart by arity', coa_resolve(cg, cg.instance_variable_get(:@ireps)['T']) == ['LCF::Title'])
supering = coa_irep('OS', [insn(0, 'ENTER', "0:0:0:0:0:0:0:0\t(0x0)"), insn(2, 'SUPER', "R1\tn=*"), insn(5, 'RETNIL', '')])
cg = coa_codegen([coa_table, one, supering], defs + [['Other', 'table', 'OS'], ['Host', 'a', 'C1']], world)
check.call('another definition of the name that calls super withdraws it', coa_resolve(cg, cg.instance_variable_get(:@ireps)['T']).nil?)

# A parameter forwarded through a second method.
forward = coa_irep('F', [insn(0, 'ENTER', "1:0:0:0:0:0:0:0\t(0x0)"), insn(2, 'LOADSELF', "R2\t(R2)"), insn(4, 'LOADI_1', 'R3 (1)'),
                         insn(6, 'MOVE', 'R4 R1'), insn(8, 'SSEND', "R2\t:table\tn=3"), insn(12, 'RETURN', 'R2')])
fwd_call = coa_caller('FC', coa_const('Title'), name: 'wrap', argc: 1)
fwd_call.instructions[1] = insn(2, 'LOADI_1', 'R2 (1)')
cg = coa_codegen([coa_table, forward, fwd_call], defs + [['Rec', 'wrap', 'F'], ['Host', 'a', 'FC']], world)
check.call('a forwarding method with no resolvable caller stays unresolved', coa_resolve(cg, cg.instance_variable_get(:@ireps)['T']).nil?)
# A method with a rest parameter is not the plain-arity case this pass understands.
optional = coa_table('T', body: [insn(0, 'ENTER', "2:0:1:0:0:0:0:0\t(0x0)"), insn(2, 'MOVE', "R4\tR2"), insn(4, 'SEND', "R4\t:new\tn=2"), insn(7, 'RETURN', 'R4')])
two_args = coa_caller('C1', coa_const('Title'), argc: 2)
cg = coa_codegen([optional, two_args], defs + [['Host', 'run', 'C1']], world)
check.call('a method with a rest parameter is refused', coa_resolve(cg, optional).nil?)

# A block reading the parameter through GETUPVAR.
block = coa_irep('B', [insn(0, 'GETUPVAR', "R3\t2\t0"), insn(4, 'SEND', "R3\t:new\tn=0"), insn(8, 'RETURN', 'R3')])
rows = lambda do |extra|
  coa_irep('R', [insn(0, 'ENTER', "3:0:0:0:0:0:0:0\t(0x0)")] + extra +
                [insn(10, 'BLOCK', "R5\tI[0]"), insn(13, 'SENDB', "R4\t:each\tn=0"), insn(17, 'RETURN', 'R4')], reps: ['B'])
end
rows_defs = [['Rec', 'table', 'R']]
stable = rows.call([])
cg = coa_codegen([stable, block.dup, one], rows_defs + [['Host', 'run', 'C1']], world)
check.call('a block reading a never-rewritten parameter resolves it', coa_resolve(cg, cg.instance_variable_get(:@ireps)['B']) == ['LCF::Title'])
rewritten = rows.call([insn(4, 'LOADNIL', 'R2 (nil)')])
cg = coa_codegen([rewritten, block.dup, one], rows_defs + [['Host', 'run', 'C1']], world)
check.call('a rewritten parameter is refused', coa_resolve(cg, cg.instance_variable_get(:@ireps)['B']).nil?)
# `klass = other_param`: the MOVE chain ends at another parameter's entry value, which is not the parameter's own.
moved = rows.call([insn(4, 'MOVE', "R2\tR1")])
cg = coa_codegen([moved, block.dup, one], rows_defs + [['Host', 'run', 'C1']], world)
check.call('a parameter overwritten by a copy of another parameter is refused', coa_resolve(cg, cg.instance_variable_get(:@ireps)['B']).nil?)
cg = coa_codegen([stable, block.dup, one], rows_defs + [['Host', 'run', 'C1']], world, capture: false)
check.call('the capture precondition of CAPTURED_LOCAL_CLASS gates the block form', coa_resolve(cg, cg.instance_variable_get(:@ireps)['B']).nil?)
writer = coa_irep('W', [insn(0, 'LOADNIL', 'R1 (nil)'), insn(2, 'SETUPVAR', "R1\t2\t0"), insn(6, 'RETURN', 'R1')])
cg = coa_codegen([rows.call([]).tap { |r| r.reps = %w[B W] }, block.dup, writer, one], rows_defs + [['Host', 'run', 'C1']], world)
check.call('a nested block that writes the parameter is refused', coa_resolve(cg, cg.instance_variable_get(:@ireps)['B']).nil?)

# Recursion: the method passes its own parameter to itself (a cycle is not solved).
self_call = coa_table('T', body: [insn(0, 'ENTER', "3:0:0:0:0:0:0:0\t(0x0)"), insn(2, 'MOVE', "R4\tR2"), insn(4, 'SEND', "R4\t:new\tn=2"),
                                  insn(7, 'LOADSELF', "R5\t(R5)"), insn(9, 'MOVE', 'R6 R1'), insn(11, 'MOVE', 'R7 R2'), insn(13, 'MOVE', 'R8 R3'),
                                  insn(15, 'SSEND', "R5\t:table\tn=3"), insn(19, 'RETURN', 'R5')])
cg = coa_codegen([self_call, one], defs + [['Host', 'run', 'C1']], world)
check.call('a pass-through that reaches its own parameter again is refused, not looped on', coa_resolve(cg, self_call).nil?)

ENV['BC2CPP_CLASS_OBJECT_ARGS'] = '0'
cg = coa_codegen([coa_table, one], defs + [['Host', 'run', 'C1']], world)
check.call('BC2CPP_CLASS_OBJECT_ARGS=0 resolves nothing', coa_resolve(cg, cg.instance_variable_get(:@ireps)['T']).nil?)
ENV.delete('BC2CPP_CLASS_OBJECT_ARGS')

# -- generated code ---------------------------------------------------------------------------------
HELPER = <<~RUBY
  class CoaRec
    def initialize(rec, path); @rec = rec; @path = path; end
    def build(id, klass, name)
      klass.new(@rec, name)
    end
    def build_all(id, klass, name)
      [1].each { |i| klass.new(@rec, name) }
      id
    end
  end

  class CoaOne < CoaRec; end
  class CoaTwo < CoaRec; end

  # Only the helper above can build it, with two arguments: its Array argument loses its class test.
  class CoaVictim
    def initialize(items, n); @items = items; @n = n; end
    def count; @items.size; end
  end

  class CoaHost
    def run(x); CoaVictim.new([1, 2, x], 3).count; end
  end

  class CoaCaller < CoaRec
    def one; build 1, CoaOne, :a; end
    def two; build 2, CoaTwo, :b; end
    def all; build_all 3, CoaOne, :c; end
  end
RUBY

OWNERS = %w[CoaRec CoaOne CoaTwo CoaVictim CoaHost CoaCaller].freeze
runtime = Bc2cppFixtureRuntime

if ENV['MRBC'] && runtime.compiler?
  puts '== generated code'
  gen = lambda do |source, env = {}|
    Dir.mktmpdir('coa') do |dir|
      saved = env.to_h { |k, _| [k, ENV[k]] }
      env.each { |k, v| ENV[k] = v }
      begin
        code, err = runtime.generate(source, dir, only_owners: OWNERS, core: true)
        [code, err]
      ensure
        saved.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
      end
    end
  end
  body = lambda do |code, name|
    start = code.index(/^mrb_value #{Regexp.escape(name)}\(.*\) \{$/)
    start && code[start...(code.index("\n}\n", start) || -1)]
  end
  ctor_lines = ->(err) { err.lines.select { |l| l.include?('CTOR Coa') } }

  on_code, on_err = gen.call(HELPER)
  check.call('the helper is resolved to its constants (param_named sites counted)', on_err.include?('param_named='))
  check.call('the two-argument constructor of an unrelated class is pooled', ctor_lines.call(on_err).any? { |l| l.include?('CoaVictim#initialize pooled') })
  count = body.call(on_code, 'CoaVictim_count_impl')
  check.call('and its Array argument has no class test in front of size', count && !count.include?('bc2cpp_send') && !count.include?('MRB_TT_HASH'))

  off_code, off_err = gen.call(HELPER, 'BC2CPP_CLASS_OBJECT_ARGS' => '0')
  check.call('the kill switch brings the unresolved site back', off_err.include?('unresolved new with 2 arguments'))
  off_count = body.call(off_code, 'CoaVictim_count_impl')
  check.call('and the class test returns', off_count&.include?('bc2cpp_send'))

  # A caller that hands the helper a class it computed keeps every constructor withdrawn.
  dynamic = HELPER + <<~RUBY
    class CoaDyn < CoaRec
      def pick(k); build 4, k, :d; end
      def go; pick(CoaOne); end
    end
  RUBY
  dyn_code, = gen.call(dynamic.sub('%w[CoaRec', '%w[CoaRec'))
  dyn_count = body.call(dyn_code, 'CoaVictim_count_impl')
  check.call('a class passed through another parameter still resolves when its callers are constants', dyn_count && !dyn_count.include?('bc2cpp_send'))
  computed = HELPER + <<~RUBY
    class CoaDyn < CoaRec
      def pick; build 4, [CoaOne, CoaTwo].first, :d; end
    end
  RUBY
  comp_code, comp_err = gen.call(computed)
  check.call('a computed class argument keeps the site unresolved', comp_err.include?('unresolved new with 2 arguments'))
  check.call('and keeps the unrelated constructor unpooled', body.call(comp_code, 'CoaVictim_count_impl')&.include?('bc2cpp_send'))
  symbolic = HELPER + <<~RUBY
    class CoaSym < CoaRec
      def go; send(:build, 5, CoaOne, :e); end
    end
  RUBY
  _sym_code, sym_err = gen.call(symbolic)
  check.call('a Symbol naming the helper keeps the site unresolved', sym_err.include?('unresolved new with 2 arguments'))
  supered = HELPER + <<~RUBY
    class CoaSub < CoaRec
      def build(id, klass, name); super; end
    end
  RUBY
  _sup_code, sup_err = gen.call(supered)
  check.call('a subclass override that calls super keeps the site unresolved', sup_err.include?('unresolved new with 2 arguments'))
else
  puts '-- SKIP generated code: set MRBC (and have a C++ compiler)'
end

puts
if failures.empty?
  puts 'class_object_args_check: ok'
else
  puts "class_object_args_check: #{failures.size} FAILED"
  failures.each { |f| puts "  - #{f}" }
  exit 1
end
