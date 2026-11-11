#!/usr/bin/env ruby
# frozen_string_literal: true

# CTOR_ROWS (tools/bc2cpp/static_dispatch_registrations.rb): an `initialize` / `initialize_copy` entry becomes a
# constructor row only when nothing but a construction looks its name up.
#
#   - the rule, on hand-built closed-world facts: a plain native and a compiled entry are rows; a Symbol literal of the
#     name, a bytecode send of it, a `super` that may reach the owner, a `super` of unknown reach, and a native lookup
#     of the name on a class that is a superclass of the owner and an owner call of the generated code listing the
#     owner each keep the entry; a singleton owner is never a row;
#   - the outputs: the exclusion header defines a native constructor row to 2 (1 for any other name), and a verify
#     build removes no constructor row at run time.
#
# Usage: ruby scripts/bc2cpp/ctor_rows_check.rb

require_relative '../../tools/bc2cpp/world_root'
require 'set'
require 'tmpdir'
require_relative 'check_support'
require_relative '../../tools/bc2cpp/static_dispatch_registrations'

suite = FixtureCheck.new('ctor_rows_check')
SDR = StaticDispatchRegistrations

# A world with one native source that looks `initialize` up on instances of the class it defines (as mruby-io's
# file.c does for IO); outside_world_files reads it as the only native source.
Dir.mktmpdir('ctor-rows') do |root|
  native = File.join(root, 'native.c')
  File.write(native, <<~C)
    static mrb_value io_open(mrb_state *mrb, mrb_value self) {
      struct RClass *io = mrb_define_class(mrb, "Pipe", mrb->object_class);
      return mrb_funcall(mrb, self, "initialize", 0);
    }
  C
  SDR.singleton_class.send(:define_method, :outside_world_files) { |_root, **| [[], [native]] }
  ir = Struct.new(:op, :sym)
  program = Struct.new(:insns) do
    def each_source(&) = insns.each_with_index(&)
  end
  irep = Struct.new(:label)
  rows = lambda do |cands, sends: [], symbols: Set.new, super_reach: {}, super_unknown: Set.new, superclass_of: {}|
    ireps = { 'a' => irep.new('a') }
    BytecodeIR.define_singleton_method(:for) { |_irep| program.new(sends.map { |s| ir.new(:SEND, s) }) }
    SDR.ctor_rows(root, cands, ireps, superclass_of, symbols, super_reach, super_unknown)
  end
  native_init = { owner: 'Gfx::Color', name: 'initialize', native: true, rom: true }
  compiled_init = { owner: 'Game::Map', name: 'initialize' }
  copy = { owner: 'Gfx::Color', name: 'initialize_copy', native: true, rom: true }
  all = [native_init, compiled_init, copy]

  suite.check('a native and a compiled initialize, and an initialize_copy, become rows',
              rows.call(all) == Set['Gfx::Color#initialize', 'Game::Map#initialize', 'Gfx::Color#initialize_copy'])
  suite.check('no Symbol-literal lookup proof (nil) keeps every entry', SDR.ctor_rows(root, all, {}, {}, nil, {}, Set.new).empty?)
  suite.check('a Symbol literal of the name keeps it',
              rows.call(all, symbols: Set['initialize']) == Set['Gfx::Color#initialize_copy'])
  suite.check('a bytecode send of the name keeps it', rows.call(all, sends: ['initialize_copy']) ==
              Set['Gfx::Color#initialize', 'Game::Map#initialize'])
  suite.check('a super that may reach the owner keeps that owner only',
              rows.call(all, super_reach: { 'initialize' => Set['Game::Map'] }) ==
                Set['Gfx::Color#initialize', 'Gfx::Color#initialize_copy'])
  suite.check('a super of unknown reach keeps the name', rows.call(all, super_unknown: Set['initialize']) ==
              Set['Gfx::Color#initialize_copy'])
  suite.check('a native lookup of the name on a superclass of the owner keeps it',
              rows.call([{ owner: 'Gfx::Shell', name: 'initialize' }], superclass_of: { 'Gfx::Shell' => 'Pipe' }).empty?)
  suite.check('and an owner outside that class keeps its row',
              rows.call([{ owner: 'Gfx::Shell', name: 'initialize' }], superclass_of: { 'Gfx::Shell' => 'Object' }) ==
                Set['Gfx::Shell#initialize'])
  suite.check('a singleton owner is never a row',
              rows.call([{ owner: 'Gfx::Color.singleton', name: 'initialize' }]).empty?)
  suite.check('another name is never a row', rows.call([{ owner: 'Gfx::Color', name: 'dispose' }]).empty?)
  gen = %(  r1 = bc2cpp_owner_call(M, r1, 6, 0, BC2CPP_OWNERS("BasicObject", "Game::Map"), mrb_nil_value(), 0); /* CLOSED_WORLD owner-call: initialize */\n)
  BytecodeIR.define_singleton_method(:for) { |_irep| program.new([]) }
  suite.check('an owner call of the generated code that lists the owner keeps it',
              SDR.ctor_rows(root, all, { 'a' => irep.new('a') }, {}, Set.new, {}, Set.new, gens: [gen]) ==
                Set['Gfx::Color#initialize', 'Gfx::Color#initialize_copy'])
end

entries = [{ mt_class: 'Gfx__Color', owner: 'Gfx::Color', kind: 'SYM', cname: 'initialize', name: 'initialize' },
           { mt_class: 'Gfx__Color', owner: 'Gfx::Color', kind: 'SYM', cname: 'dispose', name: 'dispose' }]
header = CoreNativeCandidates.header([], [], %w[Gfx::Color#initialize Gfx::Color#dispose], entries)
suite.check('the exclusion header keeps a native constructor row (2) and drops another entry (1)',
            header.include?('#define MRB_MT_EXCLUDE_Gfx__Color_SYM__initialize 2') &&
              header.include?('#define MRB_MT_EXCLUDE_Gfx__Color_SYM__dispose 1'))
suite.finish!
