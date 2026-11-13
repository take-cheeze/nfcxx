#!/usr/bin/env ruby
# frozen_string_literal: true

# ENGINE_ROWS (tools/bc2cpp/static_dispatch_registrations.rb): a compiled engine entry whose name only lookups that
# find rows reach (the core rows run's names) is kept as a row of its generated ROM table.
#
#   - the rule: a plain compiled entry of an engine owner (a module's singleton too) is a row; a name the rows run
#     reaches or a fragment may build, a `super` that may reach the owner or of unknown reach, a native, an accessor,
#     a guarded registration, a constructor name (CTOR_ROWS'), an outside owner and an operator each keep the entry,
#     and without the rows run nothing is a row;
#   - the outputs: the lists read without the key as empty, and the closed build's ROM tables mark an engine row
#     MRB_MT_ENTRY_CTOR_ (MRB_MT_CTOR_ROW) like a constructor row, while any other build marks none;
#   - the runtime, on the full-core mruby when one is built: a row of a ROM table answers mrb_method_search_rows
#     (bc2cpp_find_proven: owner and native singleton calls) and mrb_funcall, and is invisible to mrb_method_search_vm
#     and respond_to?, which the proof keeps from its name.
#
# Usage: ruby scripts/bc2cpp/engine_rows_check.rb

require_relative '../../tools/bc2cpp/world_root'
require 'json'
require 'open3'
require 'set'
require 'tmpdir'
require_relative 'check_support'
require_relative '../../tools/bc2cpp/static_dispatch_registrations'
require_relative '../../tools/bc2cpp/static_dispatch_lists'

suite = FixtureCheck.new('engine_rows_check')
SDR = StaticDispatchRegistrations

plain = { owner: 'Game::Map', name: 'update', entry: 'Game__Map_update' }
cands = [
  plain,
  { owner: 'RGSS.singleton', name: 'update', entry: 'RGSS_singleton_update' },
  { owner: 'Game::Map', name: 'refresh', entry: 'Game__Map_refresh' },
  { owner: 'Game::Map', name: 'map_data', entry: 'Game__Map_map_data' },
  { owner: 'RGSS::Sprite', name: 'flash', native: true, rom: true },
  { owner: 'Game::Map', name: 'mode', entry: nil, accessor: true },
  { owner: 'Game::Map', name: 'guarded', entry: 'Game__Map_guarded', guard: true },
  { owner: 'Game::Map', name: 'initialize', entry: 'Game__Map_initialize' },
  { owner: 'Array', name: 'update', entry: 'Array_update' },
  { owner: 'Game::Map', name: '==', entry: 'Game__Map_eq' }
]
rows = ->(names: Set.new, fragments: Set.new, reach: {}, unknown: Set.new, owners: Set['Game::Map']) do
  SDR.engine_rows(cands, [names, fragments], reach, unknown, owners)
end
suite.check('a plain compiled entry of an engine owner, a module singleton too, is a row',
            rows.call(names: Set['refresh'], fragments: Set['_data']) == Set['Game::Map#update', 'RGSS.singleton#update'])
suite.check('a name the rows run reaches keeps it', !rows.call(names: Set['update']).include?('Game::Map#update'))
suite.check('a fragment that may build the name keeps it', !rows.call(fragments: Set['_data']).include?('Game::Map#map_data') &&
                                                            rows.call.include?('Game::Map#map_data'))
suite.check('a super that may reach the owner keeps it', !rows.call(reach: { 'update' => Set['Game::Map'] }).include?('Game::Map#update'))
suite.check('a super reaching another class keeps a class owner a row, but not a singleton (it may sit anywhere)',
            rows.call(reach: { 'update' => Set['Game::Other'] }).then { |r| r.include?('Game::Map#update') && !r.include?('RGSS.singleton#update') })
suite.check('a super of unknown reach keeps the name', !rows.call(unknown: Set['update']).include?('RGSS.singleton#update'))
others = rows.call
suite.check('a native, an accessor and a guarded registration stay entries',
            (others & Set['RGSS::Sprite#flash', 'Game::Map#mode', 'Game::Map#guarded']).empty?)
suite.check('a constructor name is CTOR_ROWS\', an outside owner and an operator stay',
            (others & Set['Game::Map#initialize', 'Array#update', 'Game::Map#==']).empty?)
suite.check('without the rows run nothing is a row', SDR.engine_rows(cands, nil, {}, Set.new, Set.new).empty?)

lists = StaticDispatchLists.parse(JSON.generate(StaticDispatchLists::REQUIRED_KEYS.to_h { |k| [k, []] }.merge('digest' => 'x')))
suite.check('lists without engine_rows read it as empty', lists.engine_rows.empty?)
round = StaticDispatchLists.parse(StaticDispatchLists.dump(StaticDispatchLists::Lists.new(
  **StaticDispatchLists::KEYS.to_h { |k| [k.to_sym, Set.new] }, engine_rows: Set['Game::Map#update'], digest: 'x'
)))
suite.check('engine_rows survives a dump and parse', round.engine_rows == Set['Game::Map#update'])

# The emission: CodeGen#ctor_row_keys is what rom_method_table marks MRB_MT_ENTRY_CTOR_.
require_relative '../../tools/bc2cpp/codegen'
require_relative '../../tools/bc2cpp/codegen_emit'
listed = StaticDispatchLists::Lists.new(**StaticDispatchLists::KEYS.to_h { |k| [k.to_sym, Set.new] },
                                        ctor_rows: Set['Game::Map#initialize'], engine_rows: Set['Game::Map#update'], digest: 'x')
keys = lambda do |build|
  gen = CodeGen.allocate
  gen.define_singleton_method(:static_dispatch_lists) { listed }
  old = ENV['BC2CPP_BUILD_NAME']
  ENV['BC2CPP_BUILD_NAME'] = build
  gen.send(:ctor_row_keys)
ensure
  ENV['BC2CPP_BUILD_NAME'] = old
end
suite.check('the closed build marks engine rows and constructor rows', keys.call('closed') == Set['Game::Map#initialize', 'Game::Map#update'])
suite.check('another build marks none', keys.call('open').empty?)
table = +''
row = { name: 'update', key: 'MRB_SYM(update)', entry: 'Game__Map_update', aspec: 'MRB_ARGS_NONE()', ctor: true }
CodeGen.allocate.send(:rom_method_table, [table, 0], 'Game::Map', 'v', false, [row])
suite.check('a row is a MRB_MT_ENTRY_CTOR_ of its ROM table', table.include?('MRB_MT_ENTRY_CTOR_(Game__Map_update, MRB_SYM(update)'))

# The runtime premise the rule relies on, on the full-core mruby (mruby#20's row lookups).
require_relative 'fixture_runtime'
full = Bc2cppFixtureRuntime.full_or_build
lib = full && File.join(full, 'lib/libmruby.a')
if lib
  Dir.mktmpdir('engine-rows') do |dir|
    File.write(File.join(dir, 'main.cpp'), <<~CPP)
      #include <mruby.h>
      #include <mruby/class.h>
      #include <mruby/presym.h>
      #include <mruby/proc.h>
      #include <cstdio>
      static mrb_value row_m(mrb_state* M, mrb_value) { return mrb_int_value(M, 42); }
      int main() {
        mrb_state* M = mrb_open();
        struct RClass* c = mrb_define_class(M, "RowProbe", M->object_class);
        static mrb_mt_entry table[] = { MRB_MT_ENTRY_CTOR_(row_m, 0, MRB_ARGS_NONE()) };
        mrb_sym mid = mrb_intern_lit(M, "row_probe");
        table[0].key = mid;
        mrb_mt_init_rom(M, c, table, 1);
        mrb_value o = mrb_obj_new(M, c, 0, nullptr);
        struct RClass* k = c;
        bool rows = !MRB_METHOD_UNDEF_P(mrb_method_search_rows(M, &k, mid));
        k = c;
        bool vm = !MRB_METHOD_UNDEF_P(mrb_method_search_vm(M, &k, mid));
        mrb_value v = mrb_funcall_id(M, o, mid, 0);
        bool funcall = !M->exc && mrb_integer_p(v) && mrb_integer(v) == 42;
        bool responds = mrb_respond_to(M, o, mid);
        std::printf("rows=%d vm=%d funcall=%d respond_to=%d\\n", rows, vm, funcall, responds);
        mrb_close(M);
        return 0;
      }
    CPP
    cxx = ENV.fetch('CXX', 'c++')
    exe = File.join(dir, 'probe')
    _o, e, s = Open3.capture3(cxx, '-std=c++17', *Bc2cppFixtureRuntime.library_defines(full), "-I#{BC2CPP_WORLD_ROOT}/3rd/mruby/include",
                              "-I#{full}/include", File.join(dir, 'main.cpp'), lib, '-lm', '-o', exe)
    suite.check('the runtime probe builds', s.success?)
    warn e unless s.success?
    if s.success?
      out, = Open3.capture2(exe)
      suite.check('a row answers the row lookup and mrb_funcall', out.include?('rows=1') && out.include?('funcall=1'))
      suite.check('a row is invisible to the method search and respond_to?', out.include?('vm=0') && out.include?('respond_to=0'))
    end
  end
else
  puts '  SKIP runtime: no full-core mruby build (BC2CPP_MRUBY_FULL)'
end

suite.finish!
