#!/usr/bin/env ruby
# frozen_string_literal: true

# CLASS_BODY_EMIT list: every class and module body of the closed build's gem roots, and whether the restricted
# class-body driver (CodeGen#compile_class_body) would compile it. A refusal names the opcodes that refuse it, so the
# list says what to support next. Read-only; needs MRBC (host mrbc) and prints the list to stdout.
#
#   MRBC=path/to/host/mrbc BC2CPP_STATIC_DISPATCH_LISTS=build/bc2cpp/static_dispatch_lists.json \
#     BC2CPP_BUILD_NAME=closed ruby scripts/bc2cpp/class_body_compile_list.rb [--refused]
#   The lists are the build's omittable set: without them every TDEF is refused, with them the omitted defs are skipped.

require 'set'
require 'tmpdir'
require_relative '../../tools/bc2cpp/bc2cpp'
require_relative '../../tools/bc2cpp/class_body_scan'
require_relative '../../tools/bc2cpp/class_world'
require_relative '../../tools/bc2cpp/class_world_gate'

ROOT = File.expand_path('../..', __dir__)
mrbc = ENV['MRBC'] || 'mrbc'
only_refused = ARGV.include?('--refused')

results = []
refusals = Hash.new(0)
Dir.mktmpdir do |tmp|
  ClassWorldGate.closed_roots(ROOT).each do |name, files|
    ireps, root = compile_ireps(files, name.tr(':-', '__'), tmp, mrbc: mrbc)
    built = build_registry(ireps, root)
    registry = built[0]
    # The same order as bc2cpp.rb: core shadowing and the core alias map first, then the closed world settles the alias sites.
    core_shadowed = CoreDefs.shadowed_labels(registry, ireps)
    core_shadowed_pairs = registry.values.flatten.select { |d| d.irep && core_shadowed.include?(d.irep) }
                                  .to_set { |d| [d.owner, d.name] }
    registry.each_value { |defs| defs.reject! { |d| d.irep && core_shadowed.include?(d.irep) } }
    registry.each_value { |defs| defs.each { |d| d.core = true if d.irep && CoreDefs.core_source?(ireps.fetch(d.irep).file) } }
    CodeGen.core_aliases = CoreDefs.alias_map(built[12], registry, ireps, core_shadowed_pairs)
    AliasSites.settle(registry, ireps, closed: true, method_trusted: true)
    gen = CodeGen.new(ireps, registry, {}, {}, {}, {}, {}, {}, {}, {}, {}, Set.new)
    # The build hands the units every compiled method (bc2cpp.rb); here each TDEF and SDEF body is compiled alone.
    gen.compiled_methods = ireps.each_value.flat_map do |irep|
      BytecodeIR.for(irep).each_source.filter_map do |insn, _|
        next unless %i[TDEF SDEF METHOD].include?(insn.op)
        child = insn.op == :METHOD ? insn.block_index : insn.def_child_index
        next unless child
        label = irep.reps[child]
        method = gen.compile_method(label)
        [label, method.merge(label: label)] if method
      end
    end.to_h
    walk = lambda do |label, namespace|
      irep = ireps.fetch(label)
      BytecodeIR.class_bodies(irep, :CLASS, :MODULE).each do |idx, child_label|
        next unless child_label

        path = BytecodeIR.class_body_path(irep, idx, namespace) || "(unresolved in #{name})"
        code, refused = gen.compile_class_body(ireps.fetch(child_label), path)
        results << [name, path, code ? 'compiled' : 'refused', refused.to_a.map(&:to_s).sort.join(' ')]
        refused.to_a.each { |op| refusals[op.to_s] += 1 } if refused
        walk.call(child_label, path)
      end
    end
    walk.call(root, nil)
  end
end

compiled = results.count { |r| r[2] == 'compiled' }
puts format('%-22s %-44s %-9s %s', 'gem', 'class body', 'status', 'refused by')
results.each do |name, path, status, why|
  next if only_refused && status == 'compiled'

  puts format('%-22s %-44s %-9s %s', name, path, status, why)
end
puts "\n#{compiled} of #{results.size} class and module bodies compile"
puts 'refusing opcodes (count of bodies each refuses):'
refusals.sort_by { |_, n| -n }.each { |op, n| puts format('  %-10s %d', op, n) }
