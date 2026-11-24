#!/usr/bin/env ruby
# frozen_string_literal: true

# ENGINE_SENDS_COMPILED and CLASS_REACH (tools/bc2cpp/core_rows.rb, tools/bc2cpp/class_reach.rb): the run that decides
# which core entries the closed build removes reads the engine through the lookups its generated code keeps, and an
# owner call or a nil-receiver site's name only on the owners that site can reach.
#
#   - a symbol table entry only inert lines use (a Symbol value) is blanked; one a by-name send, a bare index or an
#     unreadable site uses stays, and a number in a string or comment is no use;
#   - an owner call's slot gives its name and listed owners (BC2CPP_OWNERS, _D after its direct rows, SHARED after its
#     key) and no bare use; a site whose owners are not plain class paths keeps its slot; a macro definition is no site;
#   - a nil-receiver site reaches nil's chain and every module or unknown owner, not another known class;
#   - the entry candidates keep what a site reaches and leave out an unlisted owner's entry; an INDEX_CLOSED name keeps
#     its verdict; BC2CPP_CLASS_REACH=0 and BC2CPP_ENGINE_SENDS_COMPILED=0 turn each reading off.
#
# Usage: ruby scripts/bc2cpp/class_reach_check.rb

require 'set'
require_relative 'check_support'
require_relative '../../tools/bc2cpp/static_dispatch_registrations'

suite = FixtureCheck.new('class_reach_check')

# The first entries pad the table: small numbers (argument counts, levels) spell their indexes everywhere.
NAMES = (%w[p0 p1 p2 p3 p4 p5 p6 p7 p8 p9] + %w[gone kept bare listed nilled odd commented]).freeze
table = "static constexpr const char* bc2cpp_sym_names[#{NAMES.size}] = {\n" +
        NAMES.map { |n| "  \"#{n}\",\n" }.join + "};\n"
src = table + <<~CPP
  #define BC2CPP_OWNERS(I, L, ...) (I)
  r1 = mrb_symbol_value(bc2cpp_sym(M, 10));
  r2 = bc2cpp_send(M, r1, 11, 0);
  r3 = helper(M, r2, 12);
  r4 = bc2cpp_owner_call(M, r3, BC2CPP_OWNERS(13, 0, "Array", "Enumerable"), mrb_nil_value(), 0);
  r4 = bc2cpp_owner_call(M, r3, BC2CPP_OWNERS_D(13, 2, BC2CPP_OWNER_DIRECT("Range", range_x, MRB_ARGS_NONE(), 0), "Range"), mrb_nil_value(), 0);
  r4 = bc2cpp_owner_call(M, r3, BC2CPP_SHARED(0x1f, 13, 0, "Struct"), mrb_nil_value(), 0);
  r5 = bc2cpp_nil_receiver_id(M, 14); /* map.rb:16 */
  r6 = bc2cpp_owner_call(M, r3, BC2CPP_OWNERS(15, 0, owner_name), mrb_nil_value(), 0);
  r7 = mrb_str_new_lit(M, "16 apples"); // 16
CPP

kept = lambda do |text|
  t = text[/bc2cpp_sym_names\[\d+\] = \{\n(.*?)^\};/m, 1]
  t.scan(/^\s*"([^"]*)",/).flatten.grep_v(/\Ap\d\z/)
end

plain = CoreRows.blank_inert_sym_entries(src)
suite.check("without typed sites a Symbol value's entry goes and every other use stays (kept: #{kept.call(plain).join(' ')})",
            kept.call(plain) == %w[kept bare listed nilled odd])
typed = {}
read = CoreRows.blank_inert_sym_entries(src, typed: typed)
suite.check("owner and nil sites give their names to `typed` instead (kept: #{kept.call(read).join(' ')})",
            kept.call(read) == %w[kept bare odd])
suite.check('the owner sites list their owners, after a direct row and a shared key too',
            typed['listed'] == Set['Array', 'Enumerable', 'Range', 'Struct'])
suite.check('a nil site reaches nil', typed['nilled'] == Set[ClassReach::NIL])
suite.check('a site whose owners are not literal class paths gives no name', !typed.key?('odd'))
suite.check('the text keeps its length', read.size == src.size)

ClassReach.classes = Set['Array', 'Hash', 'Range', 'Object', 'BasicObject', 'NilClass'].freeze
suite.check('a listed owner is reached, an unlisted one is not',
            ClassReach.reaches?(typed, 'listed', 'Enumerable') && !ClassReach.reaches?(typed, 'listed', 'Hash'))
suite.check('a nil site reaches nil\'s chain, a module and an unknown owner, not another class',
            %w[NilClass Object BasicObject Kernel Comparable Mystery].all? { |o| ClassReach.reaches?(typed, 'nilled', o) } &&
            !ClassReach.reaches?(typed, 'nilled', 'Array'))
suite.check('a ROM entry is matched by its table token',
            ClassReach.reaches_token?({ 'x' => Set['Integer.singleton'] }, 'x', 'Integer_singleton') &&
            !ClassReach.reaches_token?({ 'x' => Set['Integer.singleton'] }, 'x', 'Integer'))

map = Struct.new(:registrations, :aliases, :computed).new(
  [['Array', 'listed', 'fa'], ['Hash', 'listed', 'fh'], ['Hash', 'nilled', 'fn'], ['Kernel', 'nilled', 'fk'], ['Hash', '[]', 'fi']],
  [], Set.new
)
names = Set.new
left = CoreNativeCandidates.ram_candidates(map, names, Set.new, [], {}, typed: typed)
suite.check("the candidates leave out what no site reaches (#{left.join(' ')})",
            left.include?('Hash#listed') && !left.include?('Array#listed') && left.include?('Hash#nilled') &&
            !left.include?('Kernel#nilled'))
proven_typed = typed.merge('[]' => Set[ClassReach::NIL, 'Array'])
proven = CoreNativeCandidates.ram_candidates(map, names, Set.new, [], { '[]' => true }, typed: proven_typed)
suite.check('an INDEX_CLOSED name keeps its verdict', proven.include?('Hash#[]'))

saved = ENV.to_h.slice('BC2CPP_CLASS_REACH', 'BC2CPP_ENGINE_SENDS_COMPILED')
ENV['BC2CPP_CLASS_REACH'] = '0'
suite.check('BC2CPP_CLASS_REACH=0 turns the site reading off', !ClassReach.enabled?)
ENV['BC2CPP_ENGINE_SENDS_COMPILED'] = '0'
suite.check('BC2CPP_ENGINE_SENDS_COMPILED=0 reads every engine symbol again', !CoreRows.engine_sends_compiled?(true, false))
ENV.delete('BC2CPP_ENGINE_SENDS_COMPILED')
suite.check('the engine reading needs a VM-free world', CoreRows.engine_sends_compiled?(true, false) &&
                                                         !CoreRows.engine_sends_compiled?(false, false) &&
                                                         !CoreRows.engine_sends_compiled?(true, true))
%w[BC2CPP_CLASS_REACH BC2CPP_ENGINE_SENDS_COMPILED].each { |k| saved.key?(k) ? ENV[k] = saved[k] : ENV.delete(k) }
generated = CoreRows.engine_names({}, [src], Set.new, Set.new, rows: false)
suite.check('the unblanked engine reading keeps a generated by-name send', generated.include?('kept'))
suite.finish!
