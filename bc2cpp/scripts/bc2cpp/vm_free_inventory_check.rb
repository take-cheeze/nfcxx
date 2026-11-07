#!/usr/bin/env ruby
# frozen_string_literal: true

# VM_FREE_INVENTORY (docs/bc2cpp-vm-free-runtime-plan.md, Phase 0): counts each VM dependency in the generated
# closed-build sources and fails when a count grows past its baseline. Counts only go down as the phases land.
#
#   ruby scripts/bc2cpp/vm_free_inventory_check.rb <generated-closed-build-dir>
#
# The directory is the closed build's generated tree (for example build-closed-bc2cpp/closed). Without it the check
# has nothing to count and fails, so it is never a silent pass.
require 'pathname'

# Each pattern is one VM dependency from the plan's table. `count` is the baseline measured on the closed-build
# sources of this tree; a count above it is a regression.
DEPENDENCIES = {
  'mrb_funcall' => { pattern: /\bmrb_funcall\w*/, count: 847 },
  'bc2cpp_owner_call' => { pattern: /\bbc2cpp_owner_call\w*/, count: 2208 },
  'mrb_proc_new_cfunc_with_env' => { pattern: /\bmrb_proc_new_cfunc_with_env\w*/, count: 471 },
  'mrb_protect' => { pattern: /\bmrb_protect\w*/, count: 199 },
  'mrb_gc_protect' => { pattern: /\bmrb_gc_protect\w*/, count: 178 },
  'mrb_yield' => { pattern: /\bmrb_yield\w*/, count: 33 },
  'mrb_method_search_vm' => { pattern: /\bmrb_method_search_vm\w*/, count: 57 },
  'mrb_exec_irep' => { pattern: /\bmrb_exec_irep\w*/, count: 5 },
  'bc2cpp_resumable_exec' => { pattern: /\bbc2cpp_resumable_exec\w*/, count: 0 }
}.freeze

GENERATED_SUFFIXES = %w[.cpp .cxx .c .h .hxx .inc].freeze

def count_dependencies(dir)
  counts = Hash.new(0)
  Pathname.new(dir).glob('**/*').each do |path|
    next unless path.file? && GENERATED_SUFFIXES.include?(path.extname)

    text = path.read
    DEPENDENCIES.each do |name, dependency|
      counts[name] += text.scan(dependency[:pattern]).size
    end
  end
  counts
end

def report(counts)
  DEPENDENCIES.map do |name, dependency|
    count = counts[name]
    status = count > dependency[:count] ? 'GREW' : 'ok'
    format('%-38s %6d  baseline %6d  %s', name, count, dependency[:count], status)
  end
end

if $PROGRAM_NAME == __FILE__
  dir = ARGV.fetch(0) { abort 'usage: vm_free_inventory_check.rb <generated-closed-build-dir>' }
  abort "vm_free_inventory: #{dir} is not a directory; nothing to count" unless File.directory?(dir)

  counts = count_dependencies(dir)
  puts report(counts)
  grown = DEPENDENCIES.select { |name, dependency| counts[name] > dependency[:count] }.keys
  abort "vm_free_inventory: grew past baseline: #{grown.join(', ')}" unless grown.empty?

  puts 'vm_free_inventory: every dependency is at or below its baseline'
end
