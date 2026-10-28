#!/usr/bin/env ruby
# frozen_string_literal: true

# CORE_NATIVE_CANDIDATES (tools/bc2cpp/core_native_candidates.rb): which core ROM method-table entries the closed
# build may leave out of its tables, and the exclusion header it gets.
#
#   entries
#     - an entry's key is its table's MRB_MT_CLASS and its Ruby name (SYM_Q/B/E add ?/!/=);
#     - a table installed into another class than MRB_MT_CLASS, or into two classes, is no candidate's;
#   reachable
#     - an irep symbol, an identifier pool string, a native literal or presym use, a generated literal all count;
#     - a table entry's or registration's own name operand does not;
#   candidates
#     - an operator name, a name some table of the class keeps, an ALWAYS_DYNAMIC or fragment-built name stay;
#   header
#     - one MRB_MT_EXCLUDE_<Class>_<presym C name> 1 per listed entry;
#   ram_candidates
#     - an unreachable run-time registration is listed; a reachable one, or one a ROM entry shares, is not.
#
# Usage: ruby scripts/bc2cpp/core_native_candidates_check.rb

require 'set'
require 'tmpdir'
require_relative 'check_support'
require_relative '../../tools/bc2cpp/static_dispatch_registrations'

suite = FixtureCheck.new('core_native_candidates_check')

NATIVE = <<~'C'
  #define MRB_MT_CLASS Widget
  static const mrb_mt_entry widget_rom_entries[] = {
    MRB_MT_ENTRY(w_spin, MRB_SYM(spin), MRB_ARGS_NONE())
    MRB_MT_ENTRY(w_empty, MRB_SYM_Q(empty), MRB_ARGS_NONE())
    MRB_MT_ENTRY(w_size, MRB_SYM_E(size), MRB_ARGS_REQ(1))
    MRB_MT_ENTRY(w_add, MRB_OPSYM(add), MRB_ARGS_REQ(1))
    MRB_MT_ENTRY(w_called, MRB_SYM(called), MRB_ARGS_NONE())
    MRB_MT_ENTRY(w_literal, MRB_SYM(literal), MRB_ARGS_NONE())
    MRB_MT_ENTRY(w_shared, MRB_SYM(shared), MRB_ARGS_NONE())
    MRB_MT_ENTRY(w_built_x, MRB_SYM(built_x), MRB_ARGS_NONE())
    MRB_MT_ENTRY(w_inspect, MRB_SYM(inspect), MRB_ARGS_NONE())
  };
  static const mrb_mt_entry widget_class_rom_entries[] = {
    MRB_MT_ENTRY(w_shared_s, MRB_SYM(shared), MRB_ARGS_NONE())
  };
  #undef MRB_MT_CLASS
  #define MRB_MT_CLASS Gadget
  static const mrb_mt_entry gadget_rom_entries[] = {
    MRB_MT_ENTRY(g_two, MRB_SYM(two), MRB_ARGS_NONE())
  };
  #undef MRB_MT_CLASS

  void
  mrb_init_widget(mrb_state *mrb)
  {
    struct RClass *w = mrb_define_class_id(mrb, MRB_SYM(Widget), mrb->object_class);
    MRB_MT_INIT_ROM(mrb, w, widget_rom_entries);
    MRB_MT_INIT_ROM(mrb, mrb_class_ptr(mrb_singleton_class(mrb, mrb_obj_value(w))), widget_class_rom_entries);
    struct RClass *g = mrb_define_class_id(mrb, MRB_SYM(Gadget), mrb->object_class);
    struct RClass *h = mrb_define_class_id(mrb, MRB_SYM(Holder), mrb->object_class);
    MRB_MT_INIT_ROM(mrb, g, gadget_rom_entries);
    MRB_MT_INIT_ROM(mrb, h, gadget_rom_entries);
    mrb_funcall_id(mrb, mrb_obj_value(w), MRB_SYM(called), 0);
    mrb_define_method(mrb, w, "lonely", w_spin, MRB_ARGS_NONE());
    mrb_define_method(mrb, w, "spin", w_spin, MRB_ARGS_NONE());
    mrb_define_method(mrb, w, "string_name", w_spin, MRB_ARGS_NONE());
  }
C

FakeIrep = Struct.new(:syms, :pool)
IREPS = { 'a' => FakeIrep.new(%i[from_ruby], ['built_', 'string_name']) }.freeze

Dir.mktmpdir('core-native') do |dir|
  path = File.join(dir, 'widget.c')
  File.write(path, NATIVE)
  entries = CoreNativeCandidates.entries([path])
  keys = entries.to_h { |e| ["#{e[:mt_class]}##{e[:name] || e[:cname]}", e[:installed]] }
  suite.check('Ruby names from the presym kind',
              keys.key?('Widget#spin') && keys.key?('Widget#empty?') && keys.key?('Widget#size='))
  suite.check('a table installed into its MRB_MT_CLASS is installed; a singleton or two-class table is not',
              keys['Widget#spin'] == 'Widget' && entries.count { |e| e[:name] == 'shared' && e[:installed].nil? } == 1 &&
              keys['Gadget#two'].nil?)

  names, fragments = CoreNativeCandidates.reachable(IREPS, [path], ['f("literal")'])
  suite.check('irep symbols, pool identifiers, native lookups and generated literals count',
              %w[from_ruby string_name called literal].all? { |n| names.include?(n) })
  suite.check("an entry's or registration's own name operand does not",
              !names.include?('spin') && !names.include?('lonely') && !names.include?('two'))

  listed = CoreNativeCandidates.candidates(entries, names, fragments)
  suite.check("only unreachable entries of their own class's tables are listed (#{listed.join(', ')})",
              listed == %w[Widget#empty? Widget#size= Widget#spin])
  header = CoreNativeCandidates.header(listed, entries)
  suite.check('the header names each listed entry by its presym C name',
              header.lines.grep(/\A#define/).sort ==
                ["#define MRB_MT_EXCLUDE_Widget_SYM_E__size 1\n", "#define MRB_MT_EXCLUDE_Widget_SYM_Q__empty 1\n",
                 "#define MRB_MT_EXCLUDE_Widget_SYM__spin 1\n"])
  ram = CoreNativeCandidates.ram_candidates(NativeOwnerMap.build([path]), names, fragments, entries)
  suite.check("run-time registrations: only the unreachable one no ROM entry shares (#{ram.join(', ')})",
              ram == %w[Widget#lonely])
end

suite.finish!
