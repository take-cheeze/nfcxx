#!/usr/bin/env ruby
# frozen_string_literal: true

# CLASS_BODY_SCAN report: for every gem mrblib the closed build loads, what its class and module bodies
# contain, which statements keep a body bytecode (tools/bc2cpp/class_body_scan.rb), what the bytecode of the load
# phase is made of, and which of its opcodes bc2cpp's method compiler has no case for. Read-only; needs a host mrbc
# only for the bytecode half.
#
# Usage: [MRBC=path/to/mrbc] ruby scripts/bc2cpp/class_body_report.rb [--blockers] [--bytecode] [--world[=FILE]]
# --world: the class graph facts (tools/bc2cpp/class_world.rb): how much is exact, and as JSON in FILE.
require 'tmpdir'
require_relative '../../tools/bc2cpp/bc2cpp'
require_relative '../../tools/bc2cpp/class_body_scan'
require_relative '../../tools/bc2cpp/class_world'

ROOT = File.expand_path('../..', __dir__)
MRUBY = "#{ROOT}/3rd/mruby"

# The gem mrblib roots of the closed build, in load order: [name, files]. The engine's own roots are the ones
# the compiled gems cover; the core ones are mruby's.
def closed_roots
  core = bc2cpp_closed_core_gems(ROOT).map { |g| File.basename(g) }
  roots = [['core:mrblib', Dir["#{MRUBY}/mrblib/*.rb"].sort.reject { |p| p.end_with?('/10error.rb') }]]
  BC2CPP_CORE_MRBLIB_GEMS.each do |gem|
    next unless core.include?(gem)

    files = Dir["#{MRUBY}/mrbgems/#{gem}/mrblib/**/*.rb"].sort.reject { |p| p.end_with?('mruby-io/mrblib/kernel.rb') }
    roots << ["core:#{gem}", files] unless files.empty?
  end
  roots << ['ext:mruby-stringio', Dir["#{ROOT}/3rd/mruby-stringio/mrblib/**/*.rb"].sort]
  rpg2k = Dir["#{ROOT}/mruby-rpg2k/mrblib/**/*.rb"].reject { |p| p.end_with?('scene/map_tts.rb') }.sort
  roots << ['engine:mruby-rpg2k', rpg2k + ["#{ROOT}/mruby-rpg2k/mrblib_limited/map_tts_off.rb"]]
  roots << ['engine:mruby-lcf', Dir["#{ROOT}/mruby-lcf/mrblib/*.rb"].sort]
  roots << ['engine:mruby-rgss', Dir["#{ROOT}/mruby-rgss/mrblib/*.rb"].sort]
  roots.reject { |_, files| files.empty? }
end

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
  body.scan(/^    when ((?::\w+(?:,\s*)?)+)/).flatten.flat_map { |l| l.scan(/:(\w+)/).flatten }.map(&:to_sym).to_set
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

args = ARGV.dup
roots = closed_roots
scans = statement_table(roots)
blockers(scans) if args.empty? || args.include?('--blockers')
bytecode_report(roots) if args.empty? || args.include?('--bytecode')
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
