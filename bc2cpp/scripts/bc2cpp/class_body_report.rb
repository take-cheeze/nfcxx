#!/usr/bin/env ruby
# frozen_string_literal: true

# CLASS_BODY_SCAN report: for every gem mrblib the closed build loads, what its class and module bodies
# contain, which statements keep a body bytecode (tools/bc2cpp/class_body_scan.rb), what the bytecode of the load
# phase is made of, and which of its opcodes bc2cpp's method compiler has no case for. Read-only; needs a host mrbc
# only for the bytecode half.
#
# Usage: [MRBC=path/to/mrbc] ruby scripts/bc2cpp/class_body_report.rb [--blockers] [--bytecode] [--world[=FILE]]
# --world: the class graph facts (tools/bc2cpp/class_world.rb): how much is exact, and as JSON in FILE.
require 'json'
require 'set'
require 'tmpdir'
require_relative '../../tools/bc2cpp/bc2cpp'
require_relative '../../tools/bc2cpp/class_body_scan'
require_relative '../../tools/bc2cpp/class_world'
require_relative '../../tools/bc2cpp/class_world_gate'

ROOT = File.expand_path('../..', __dir__)
MRUBY = "#{ROOT}/3rd/mruby"

# The gem mrblib roots of the closed build, in load order (tools/bc2cpp/class_world_gate.rb).
def closed_roots = ClassWorldGate.closed_roots(ROOT)

CATEGORIES = %i[declarative def const_literal const_pure class_ivar const_computed dsl_call proc runtime control other].freeze

def statement_table(roots)
  puts format('%-22s %6s %s %6s', 'gem root', 'bodies', CATEGORIES.map { |c| format('%6s', c.to_s[0, 6]) }.join(' '), 'whole')
  total = Hash.new(0)
  scans = {}
  roots.each do |name, files|
    root = ClassBodyScan.scan(files)
    scans[name] = root
    cats = Hash.new(0)
    bodies = 0
    whole = 0
    root.each_body do |body|
      bodies += 1
      body.statements.each { |s| cats[s.category] += 1 }
      whole += 1 if body.statements.all? { |s| ClassBodyScan::COMPILABLE.include?(s.category) }
    end
    puts format('%-22s %6d %s %6d', name, bodies, CATEGORIES.map { |c| format('%6d', cats[c]) }.join(' '), whole)
    cats.each { |c, n| total[c] += n }
    total[:bodies] += bodies
    total[:whole] += whole
  end
  puts format('%-22s %6d %s %6d', 'total', total[:bodies], CATEGORIES.map { |c| format('%6d', total[c]) }.join(' '), total[:whole])
  puts '  (columns: statements per category; "whole": bodies whose every statement is declarative, a def or a literal constant)'
  scans
end

def blockers(scans)
  puts "\nStatements that block compiling a whole body (category: count, then every site):"
  rows = Hash.new { |h, k| h[k] = [] }
  scans.each do |gem, root|
    root.each_body do |body|
      body.statements.each do |s|
        next if ClassBodyScan::COMPILABLE.include?(s.category)

        rows[s.category] << "#{gem} #{body.name}  #{File.basename(s.file)}:#{s.line}  #{s.detail}"
      end
    end
  end
  rows.each do |category, sites|
    puts "  #{category}: #{sites.size}"
    sites.first(ENV.fetch('SITES', '12').to_i).each { |site| puts "    #{site}" }
  end
end

# Opcodes compile_insn_op has a `when` for.
def handled_ops
  text = File.read("#{ROOT}/tools/bc2cpp/codegen_insn.rb")
  body = text[/def compile_insn_op.*?\n  end\n/m] || text
  ops = body.scan(/^    when ((?::\w+(?:,\s*)?)+)/).flatten.flat_map { |l| l.scan(/:(\w+)/).flatten }.map(&:to_sym).to_set
  # `when /^LOADI/` (the integer immediates) is a regex branch, not a symbol list, so it is spelled out here.
  ops.merge(%i[LOADI LOADI8 LOADI16 LOADI32 LOADI__1 LOADI_0 LOADI_1 LOADI_2 LOADI_3 LOADI_4 LOADI_5 LOADI_6 LOADI_7]) if body.include?('when /^LOADI/')
  ops
end

LOAD_ONLY = %i[CLASS MODULE SCLASS EXEC TDEF SDEF DEF METHOD ALIAS UNDEF TCLASS OCLASS].freeze

def bytecode_report(roots)
  mrbc = ENV['MRBC'] || 'mrbc'
  handled = handled_ops
  kinds = Hash.new { |h, k| h[k] = { ireps: 0, insns: 0, iseq: 0 } }
  load_ops = Hash.new(0)
  Dir.mktmpdir do |tmp|
    roots.each do |name, files|
      ireps, root = compile_ireps(files, name.tr(':-', '__'), tmp, mrbc: mrbc)
      kind = { root => :root }
      body_labels = Set[root]
      walk = lambda do |label|
        irep = ireps.fetch(label)
        BytecodeIR.class_bodies(irep, :CLASS, :MODULE, :SCLASS).each_value do |child|
          next unless child

          kind[child] = :body
          body_labels << child
          walk.call(child)
        end
        irep.each_with_op(:TDEF, :SDEF) do |insn, _|
          child = irep.reps[insn.def_child_index]
          kind[child] ||= :method
          walk.call(child) if child
        end
        irep.each_with_op(:METHOD) do |insn, _|
          child = irep.reps[insn.block_index]
          kind[child] ||= :method
          walk.call(child) if child
        end
        irep.reps.each do |child|
          next if kind[child]

          kind[child] = :block
          walk.call(child)
        end
      end
      walk.call(root)
      kind.each do |label, k|
        irep = ireps.fetch(label)
        kinds[k][:ireps] += 1
        kinds[k][:insns] += irep.instructions.size
        kinds[k][:iseq] += irep.instructions.last ? irep.instructions.last.addr + 1 : 0
      end
      body_labels.each { |label| ireps.fetch(label).instructions.each { |insn| load_ops[insn.op] += 1 } }
    end
  end
  puts "\nIreps of the load phase by kind (all #{roots.size} roots; iseq bytes approximated by the last address):"
  kinds.each { |k, v| puts format('  %-7s %5d ireps %8d insns %8d iseq bytes', k, v[:ireps], v[:insns], v[:iseq]) }
  puts "\nOpcodes in root and class-body code (n, and whether bc2cpp's compile_insn has a case):"
  load_ops.sort_by { |_, n| -n }.each do |op, n|
    note = if LOAD_ONLY.include?(op) then handled.include?(op) ? 'has a case' : 'LOAD-ONLY: no case'
           else handled.include?(op) ? 'has a case' : 'no case'
           end
    puts format('  %-10s %6d  %s', op, n, note)
  end
end

# --tags: each SETCONST in the load phase tagged by the source of its value (int and literal values are the
# const_literal shape class_body_scan compiles; alias, computed and unknown keep the statement), and each method body
# of a class body tagged compilable (every opcode has a compile_insn case), omittable (its Owner#name is in the leave-out
# lists named by BC2CPP_OMIT_LISTS) and direct (its owner is exact in the class graph). Tags are per body or per
# SETCONST and approximate the compiler's own decisions; they are for the leave-out and direct-call work, not codegen.
SETCONST_INT = %i[LOADI LOADI8 LOADI16 LOADI32 LOADI__1 LOADI_0 LOADI_1 LOADI_2 LOADI_3 LOADI_4 LOADI_5 LOADI_6 LOADI_7].freeze
SETCONST_LITERAL = %i[LOADL LOADNIL LOADTRUE LOADFALSE STRING SYMBOL].freeze
SETCONST_ALIAS = %i[GETCONST GETMCNST].freeze

def const_source_kind(sources)
  return 'unknown' if sources.nil? || sources.empty?

  kinds = sources.map do |src|
    if SETCONST_INT.include?(src.op) then 'int'
    elsif SETCONST_LITERAL.include?(src.op) then 'literal'
    elsif SETCONST_ALIAS.include?(src.op) then 'alias'
    else 'computed'
    end
  end
  kinds.uniq.size == 1 ? kinds.first : 'mixed'
end

# Whether the method compiler produces C++ for method `mname` of `owner` (its body is irep `child`).
def method_compiles?(gen, registry, owner, mname, child)
  d = (registry[mname] || []).find { |x| x.owner == owner && x.irep == child }
  return false unless d

  !gen.compile_method(child).nil?
rescue StandardError
  false
end

def tag_report(roots, scans, omit)
  mrbc = ENV['MRBC'] || 'mrbc'
  handled = handled_ops
  world = ClassWorld.build(scans.values)
  consts = Hash.new(0)
  unknown_consts = []
  methods = []
  Dir.mktmpdir do |tmp|
    roots.each do |name, files|
      ireps, root = compile_ireps(files, name.tr(':-', '__'), tmp, mrbc: mrbc)
      registry = build_registry(ireps, root)[0]
      gen = CodeGen.new(ireps, registry, {}, {}, {}, {}, {}, {}, {}, {}, {}, Set.new)
      walk = lambda do |label, owner|
        irep = ireps.fetch(label)
        irep.each_with_op(:SETCONST) do |insn, idx|
          reg = insn.regs.last
          kind = const_source_kind(reg ? reaching_sources(irep, idx, reg) : nil)
          consts[kind] += 1
          unknown_consts << "#{name} #{owner || 'Object'}::#{insn.const_name}" unless %w[int literal].include?(kind)
        end
        BytecodeIR.class_bodies(irep, :CLASS, :MODULE, :SCLASS).each do |idx, child|
          next unless child

          # A `class << self` body is `Owner.singleton` (CodeGen#child_body_path), not the class name.
          path = gen.child_body_path(BytecodeIR.for(irep), irep, idx, owner) || owner
          walk.call(child, path || owner)
        end
        # TDEF only: METHOD is `R[a] = lambda(Irep[b])` (vm.c), a block or lambda value, not a method definition.
        irep.each_with_op(:TDEF) do |insn, _|
          child = irep.reps[insn.def_child_index]
          next unless child && owner

          mname = insn.sym.to_s
          body = ireps.fetch(child)
          ops = body.instructions.map { |i| i.op }
          blocking_ops = ops.reject { |op| handled.include?(op) }.uniq
          # compilable: the method compiler (CodeGen#compile_method) produces C++ for the method. The opcode list above
          # is only the compile_insn view (block, send-with-block and rescue are emitted by other codegen files).
          compilable = method_compiles?(gen, registry, owner, mname, child)
          key = "#{owner}##{mname}"
          methods << { owner: owner, name: mname, compilable: compilable, blocking: blocking_ops, omittable: omit.include?(key),
                       direct: world.facts.dig(owner, 'exact') ? true : false, root: name }
        end
      end
      walk.call(root, nil)
    end
  end
  puts "\nSETCONST by value source (int and literal are compiled by class_body_scan's const_literal):"
  consts.sort_by { |_, n| -n }.each { |k, n| puts format('  %-9s %6d', k, n) }
  puts "  not compiled (first 12 of #{unknown_consts.size}):"
  unknown_consts.first(12).each { |c| puts "    #{c}" }
  blocking = Hash.new(0)
  methods.each { |m| m[:blocking].each { |op| blocking[op] += 1 } }
  puts "\nOpcodes that keep a method body from compiling (bodies containing each):"
  blocking.sort_by { |_, n| -n }.first(12).each { |op, n| puts format('  %-10s %6d', op, n) }
  puts "\nMethod bodies in class bodies (compilable, omittable, direct):"
  tally = methods.group_by { |m| [m[:compilable], m[:omittable], m[:direct]] }
  [[true, true, true], [true, true, false], [true, false, true], [true, false, false], [false, true, false], [false, false, true], [false, false, false], [false, true, true]].each do |key|
    puts format('  compilable=%-5s omittable=%-5s direct=%-5s %6d', *key, (tally[key] || []).size)
  end
  if (out = ENV['BC2CPP_TAGS_OUT'])
    File.write(out, (['owner\tname\tcompilable\tomittable\tdirect\troot'] +
                     methods.map { |m| [m[:owner], m[:name], m[:compilable], m[:omittable], m[:direct], m[:root]].join("\t") }).join("\n") + "\n")
    puts "  wrote #{out} (#{methods.size} method bodies)"
  end
end

OMIT_LIST_PATH = ENV['BC2CPP_OMIT_LISTS']
OMIT = if OMIT_LIST_PATH && File.exist?(OMIT_LIST_PATH)
         lists = JSON.parse(File.read(OMIT_LIST_PATH))
         (lists['open'] + lists['closed'] + lists['core_excluded'] + lists['core_left_out']).to_set
       else
         Set.new
       end

args = ARGV.dup
roots = closed_roots
scans = statement_table(roots)
blockers(scans) if args.empty? || args.include?('--blockers')
bytecode_report(roots) if args.empty? || args.include?('--bytecode')
tag_report(roots, scans, OMIT) if args.include?('--tags')
if (flag = args.find { |a| a.start_with?('--world') })
  world = ClassWorld.build(scans.values)
  File.write(flag.split('=', 2)[1], ClassWorld.to_json(world)) if flag.include?('=')
  sum = ClassWorld.summary(world)
  puts '', 'class graph facts (ClassWorld):'
  puts "  #{sum['classes']} classes and modules: #{sum['exact']} exact, #{sum['unknown']} unknown"
  puts "  bodies: #{sum['bodies_static']} evaluated statically, #{sum['bodies_bytecode']} left as bytecode"
  puts "  graph calls in methods with no nameable receiver: #{sum['unknown_sites']}; Class.new with a computed superclass: #{sum['subclass_unknown']}"
  sum['blockers'].sort_by { |_, n| -n }.first(12).each { |r, n| puts format('    %4d  %s', n, r) }
end
