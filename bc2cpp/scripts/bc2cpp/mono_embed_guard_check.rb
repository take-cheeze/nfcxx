#!/usr/bin/env ruby
# encoding: UTF-8
# Check MONO_EMBED_GUARD (tools/bc2cpp/bc2cpp.rb's own compile_send): a MONO
# call -- monomorphic_target's "exactly one compiled bytecode definition of
# this bare name anywhere in the program" proof -- says nothing about a class
# that answers the same name only through method_missing, which never adds an
# entry to the per-name registry at all and so is invisible to that count.
# Calling the wrong receiver through an unguarded direct C++ call is merely
# wrong (a stray iv_tbl read/write) for an ordinary class, but a real,
# reproduced crash once the MONO target's own class embeds any ivar as a real
# struct field: GETIV/SETIV for an embedded field cast DATA_PTR(self)
# unconditionally, and a receiver that never was that class makes that a real
# type-confused read (found reproducing Game::Actor#faceset_index, called via
# `@db_row.faceset_index` where @db_row is an LCF::Array1D method_missing
# row, never a Game::Actor).

require 'tmpdir'
require_relative '../../tools/bc2cpp/bc2cpp'

SRC = <<~'RUBY'
  module Game
    class Actor
      # bc2cpp: (fixnum)
      def initialize(level)
        @level = level
      end

      def level
        @level
      end
    end

    class Plain
      def initialize(name)
        @name = name
      end

      def name
        @name
      end
    end

    class Row
      def initialize(fields)
        @fields = fields
      end

      # The Array1D shape this hazard was found on: a bare name this class
      # answers only through method_missing, never a real method, so no
      # registry entry for :level/:name ever exists under Row at all.
      def method_missing(sym, *args)
        @fields[sym]
      end
    end

    class Reader
      def read_level(target); target.level; end
      def read_name(target); target.name; end
    end
  end
RUBY

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

Dir.mktmpdir do |dir|
  source = File.join(dir, 'mono_embed_guard.rb')
  File.write(source, SRC)
  ireps, root_label = compile_ireps(source, 'bc2cpp_mono_embed_guard', dir)
  order = dfs_order(ireps, root_label)
  registry, superclass_of = build_registry(ireps, root_label)
  annotations = Annotations.extract(ireps, registry)
  ivar_layout = IvarLayout.analyze(ireps, registry, {}, annotations)
  gen = CodeGen.new(ireps, registry, ivar_layout, {}, {}, {}, superclass_of, {}, {}, {}, {}, Set.new)

  check.call('Game::Actor#@level is a real embedding candidate in this fixture',
             gen.embed_type('Game::Actor', 'level') == :fixnum)
  check.call('Game::Plain#@name is NOT embedded (no `bc2cpp:` annotation)',
             gen.embed_type('Game::Plain', 'name').nil?)

  compile_call = lambda do |method_name, send_name|
    reader = registry.fetch(method_name).find { |md| md.owner == 'Game::Reader' }
    irep = ireps.fetch(reader.irep)
    idx = irep.instructions.index { |insn| insn.op.start_with?('SEND') && insn.args.include?(":#{send_name}") }
    raise "Reader##{method_name}: no :#{send_name} send found" unless idx

    gen.compile_send(irep.instructions[idx], self_implicit: false, irep: irep, idx: idx, owner_def: reader)
  end

  level_code = compile_call.call('read_level', 'level')
  check.call('a MONO call into an EMBEDDING class is guarded by an exact-class check',
             level_code.include?('MONO_EMBED_GUARD :level -> Game::Actor#level') &&
               level_code.include?('mrb_obj_class(M,'))
  check.call('the guarded call keeps the direct C++ call on the true branch',
             level_code.match?(/if \(.*\) \{\n\s*r\d+ = Game__Actor_level_impl\(M, r\d+\);/))
  check.call('the guarded call falls back to ordinary dynamic dispatch on the false branch ' \
             '(so a method_missing-answered receiver still reaches it)',
             level_code.include?('} else {') && level_code.include?('mrb_funcall'))

  name_code = compile_call.call('read_name', 'name')
  check.call('a MONO call into a NON-embedding class stays the plain, unguarded fast path',
             name_code.include?('MONO :name -> Game::Plain#name, direct C++ call (no mrb_funcall)') &&
               !name_code.include?('mrb_obj_class') && !name_code.include?('mrb_funcall_id(') &&
               !name_code.include?('mrb_funcall('))
end

if failures.empty?
  puts 'bc2cpp MONO embed guard check: PASS'
else
  warn "bc2cpp MONO embed guard check: #{failures.size} failure(s)"
  exit 1
end
