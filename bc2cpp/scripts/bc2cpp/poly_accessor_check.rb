#!/usr/bin/env ruby
# encoding: UTF-8
# Check POLY_SMALL_N's attr_reader/attr_writer candidates: a name backed only
# by accessors (or by accessors plus compiled defs) is chained as exact-class
# checked mrb_iv_get/mrb_iv_set with a dynamic fallback, and an owner that
# defines the name twice never joins the chain.

require 'tmpdir'
require_relative '../../tools/bc2cpp/bc2cpp'

SRC = <<~'RUBY'
  module Game
    class Left
      attr_accessor :label
    end
    class Right
      attr_accessor :label
    end
    class Compiled
      def label; :compiled; end
      def label=(value); @label = value; end
    end
    class Doubled
      attr_reader :shade
      def shade; :redefined; end
    end
    class Doubled2
      attr_reader :shade
    end
    class Reader
      def read(target); target.label; end
      def write(target, value); target.label = value; end
      def shade_of(target); target.shade; end
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
  source = File.join(dir, 'poly_accessor.rb')
  File.write(source, SRC)
  ireps, root_label = compile_ireps(source, 'bc2cpp_poly_accessor', dir)
  order = dfs_order(ireps, root_label)
  registry = build_registry(ireps, root_label)[0]
  gen = CodeGen.new(ireps, registry, {}, {}, {}, {}, {}, {}, {}, {}, {}, Set.new)

  emit = lambda do |method_name, op|
    method = registry.fetch(method_name).find { |md| md.owner == 'Game::Reader' }
    irep = ireps.fetch(method.irep)
    idx = irep.instructions.index { |insn| insn.op == op }
    raise "#{method_name}: no #{op} instruction found" unless idx

    gen.compile_insn(irep.instructions[idx], irep, method, idx)
  end

  reader = emit.call('read', 'SEND0')
  check.call('reader chain lists every accessor and compiled owner', reader.include?('POLY_SMALL_N :label ->') &&
             reader.include?('Game::Left') && reader.include?('Game::Right') && reader.include?('Game::Compiled'))
  check.call('accessor owners read the ivar directly behind an exact-class guard',
             reader.scan(/r(\d+) = mrb_iv_get\(M, r\1, mrb_intern_cstr\(M, "@label"\)\);/).size == 2 &&
               reader.scan('mrb_obj_class(M, r').size == 3)
  check.call('compiled owner keeps its direct _impl call', reader.match?(/Game__Compiled_+label_+impl\(M,/))
  check.call('every other class falls back to dynamic dispatch',
             reader.rstrip.end_with?('}') && reader.match?(/(?:mrb_funcall|bc2cpp_funcall_explicit)\(M, r/) && reader.include?('"label", 0'))

  writer = emit.call('write', 'SEND')
  check.call('writer stores the ivar and yields the assigned value',
             writer.scan(/mrb_iv_set\(M, r(\d+), mrb_intern_cstr\(M, "@label"\), r(\d+)\);\n\s+r\1 = r\2;/).size == 2 &&
               writer.include?('"label=", 1'))

  doubled = emit.call('shade_of', 'SEND0')
  check.call('an owner defining the name twice never joins the chain',
             !doubled.include?('Game::Doubled ') && !doubled.include?('Game::Doubled,') &&
               doubled.include?('Game::Doubled2'))
end

if failures.empty?
  puts 'bc2cpp POLY accessor check: PASS'
else
  warn "bc2cpp POLY accessor check: #{failures.size} failure(s)"
  exit 1
end
