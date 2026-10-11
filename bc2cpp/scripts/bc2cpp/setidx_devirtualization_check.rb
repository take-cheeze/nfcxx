#!/usr/bin/env ruby
# encoding: UTF-8
# Check guarded `[]=` codegen through an exact annotated receiver while
# preserving SETIDX's Array/Hash fast paths and dynamic fallback semantics.

require 'tmpdir'
require_relative '../../tools/bc2cpp/bc2cpp'

# `[]=` mangles to `_$5b$5d$3d`; a hand-written `$5b` inside a regex literal
# interpolates instead of matching, so derive the symbol from cpp_name.
CPP_NAME = CodeGen.instance_method(:cpp_name).bind(CodeGen.allocate)
CELLS_SETIDX_IMPL = "#{CPP_NAME.call('Game::Cells', '[]=')}_impl"

SRC = <<~'RUBY'
  module Game
    class Cells
      def []=(key, value); :stored; end
    end
    class OtherCells
      def []=(key, value); :other; end
    end
    class World
      def put(key, value); @cells[key] = value; end
    end
    class HashWorld
      # bc2cpp: (Hash, Symbol, Object)
      def put_hash(hash, key, value); hash[key] = value; end
    end
  end
RUBY

failures = []
check = lambda do |what, condition|
  if condition
    puts "  ok  #{what}"
  else
    puts "  FAIL #{what}"
    failures << what
  end
end

Dir.mktmpdir do |dir|
  source = File.join(dir, 'setidx.rb')
  File.write(source, SRC)
  ireps, root_label = compile_ireps(source, 'bc2cpp_setidx', dir)
  order = dfs_order(ireps, root_label)
  registry = build_registry(ireps, root_label)[0]
  owners = Set.new(registry.values.flatten.map(&:owner))
  annotations = ElementAnnotations.extract(ireps, registry, owners)
  class_annotations = ClassAnnotations.extract(ireps, registry, owners)
  class_layout = { 'Game::World' => { 'cells' => 'Cells' } }
  gen = CodeGen.new(ireps, registry, {}, class_layout, class_annotations, {}, {}, {}, annotations, {}, {}, Set.new)

  method = registry.fetch('put').find { |md| md.owner == 'Game::World' }
  irep = ireps.fetch(method.irep)
  idx = irep.instructions.index { |insn| insn.op == 'SETIDX' }
  raise 'put: no SETIDX instruction found' unless idx

  code = gen.compile_insn(irep.instructions[idx], irep, method, idx)
  check.call('SETIDX devirtualizes compiled []= behind an exact-class guard',
             code.include?('TYPED :[]= -> Game::Cells#[]=') && code.include?('mrb_obj_class(M, r'))
  # OUTLINED_INDEX_OPS (docs/adr/0216): the fallback is the bc2cpp_setidx helper.
  helper = gen.emit_index_helpers([code])
  check.call('guard fallback preserves Array/Hash built-in assignment and dynamic []=',
             code.match?(/\} else \{\n\s*r(\d+) = bc2cpp_setidx\(M, r\1, r\d+, r\d+\);/) &&
               helper.include?('mrb_ary_set(M,') && helper.include?('mrb_hash_set(M,') &&
               helper.include?('mrb_funcall(M, recv, "[]=", 2, idx, val)'))
  check.call('typed branch retains compiled []= method result semantics',
             code.include?('TYPED :[]= -> Game::Cells#[]=') && code.include?("#{CELLS_SETIDX_IMPL}(M,"))

  hash_method = registry.fetch('put_hash').find { |md| md.owner == 'Game::HashWorld' }
  hash_irep = ireps.fetch(hash_method.irep)
  hash_idx = hash_irep.instructions.index { |insn| insn.op == 'SETIDX' }
  raise 'put_hash: no SETIDX instruction found' unless hash_idx

  hash_code = gen.compile_insn(hash_irep.instructions[hash_idx], hash_irep, hash_method, hash_idx)
  check.call('Hash annotation SETIDX falls back for an incorrect runtime receiver type',
             hash_code.include?('mrb_hash_p(r') && hash_code.include?('mrb_hash_set(M,') &&
               hash_code.include?('mrb_funcall(M,') && !hash_code.include?('expected Hash receiver'))
end

if failures.empty?
  puts 'bc2cpp SETIDX devirtualization check: PASS'
else
  warn "bc2cpp SETIDX devirtualization check: #{failures.size} failure(s)"
  exit 1
end
