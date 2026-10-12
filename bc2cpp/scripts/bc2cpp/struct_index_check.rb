#!/usr/bin/env ruby
# encoding: UTF-8
# Check STRUCT_MEMBERS_ANALYSIS (build_registry's own struct_member_lists,
# tools/bc2cpp/bc2cpp.rb's detect_struct_new_members) and STRUCT_INDEX_CACHE
# (CodeGen#compile_struct_literal_index_read, wired into GETIDX's own
# INDEX_CHAIN tail): `event[:page]` on a real `Struct.new(:id, ..., :page,
# ..., keyword_init: true)` instance (RPG2k::Scene::Map::MapEventState/
# MessageState's own real shape) skips Struct's native linear member scan
# (mrb_struct_aref/struct_aref_sym, 3rd/mruby/mrbgems/mruby-struct/src/
# struct.c) and the mrb_funcall dispatch to reach it, going straight to the
# already-known storage index behind an exact-class guard.

require 'tmpdir'
require_relative '../../tools/bc2cpp/bc2cpp'

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

# --- STRUCT_MEMBERS_ANALYSIS -------------------------------------------------
SRC = <<~'RUBY'
  module Game
    class Map
      # Plain (no block) form, few members -- no ARRAY splat needed.
      Small = Struct.new(:a, :b, keyword_init: true)

      # Plain form, enough members to trip mrbc's own ARRAY-splat convention
      # (CALL_MAXARGS = 15, mrbgems/mruby-compiler/core/codegen.c) -- the
      # exact shape MapEventState's real 28 members use.
      Big = Struct.new(
        :m0, :m1, :m2, :m3, :m4, :m5, :m6, :m7, :m8, :m9,
        :m10, :m11, :m12, :m13, :m14, :m15,
        keyword_init: true
      )

      # Block-taking form (Game::Battle::Combatant's own real shape) --
      # member accessors still installed natively, invisible to the plain
      # DEF/TDEF walk the same way; struct_member_lists should see it too.
      WithBlock = Struct.new(:x, :y, keyword_init: true) do
        def sum
          x + y
        end
      end

      # No SETCONST names it -- an anonymous Struct our devirt cannot key an
      # exact-class guard on, so it must be left unrecognized (a safe miss,
      # never a wrong owner).
      def anon
        Struct.new(:z)
      end

      def read_a(s)
        s[:a]
      end

      def read_m10(s)
        s[:m10]
      end

      def read_dynamic(s, key)
        s[key]
      end

      def read_string_key(s)
        s['a']
      end
    end
  end
RUBY

Dir.mktmpdir do |dir|
  source = File.join(dir, 'struct_index.rb')
  File.write(source, SRC)
  ireps, root_label = compile_ireps(source, 'bc2cpp_struct_index', dir)
  order = dfs_order(ireps, root_label)
  registry, _superclass_of, _cc, _im, _pm, _um, struct_member_lists = build_registry(ireps, root_label)

  check.call('a plain (no block) small member list is recognized in declared order',
             struct_member_lists['Game::Map::Small'] == %w[a b])
  check.call('a plain (no block) member list past the ARRAY-splat threshold is recognized in order',
             struct_member_lists['Game::Map::Big'] == (0..15).map { |i| "m#{i}" })
  check.call('a block-taking Struct.new is recognized the same way',
             struct_member_lists['Game::Map::WithBlock'] == %w[x y])
  check.call('an anonymous Struct.new (no SETCONST) is left unrecognized',
             struct_member_lists.none? { |_, v| v == ['z'] })

  # --- GETIDX codegen ---------------------------------------------------
  CodeGen.struct_members = struct_member_lists
  gen = CodeGen.new(ireps, registry, {}, {}, {}, {}, {}, {}, {}, {}, {}, Set.new)
  compiled = lambda do |name|
    md = registry.fetch(name).find { |d| d.owner == 'Game::Map' }
    gen.compile_method(md.irep).fetch(:code)
  end

  read_a = compiled.call('read_a')
  check.call('a literal-key read of a small struct uses the exact-class fast path',
             read_a.include?('mrb_type(r3) == MRB_TT_STRUCT') &&
               read_a.match?(/RARRAY_LEN\(r3\)\) \? RARRAY_PTR\(r3\)\[0\] : mrb_nil_value\(\)/) &&
               # OUTLINED_INDEX_OPS (docs/adr/0216): every other receiver goes to the shared chain.
               read_a.include?('r3 = bc2cpp_getidx(M, r3, r4);'))
  read_m10 = compiled.call('read_m10')
  check.call('a literal-key read past the ARRAY-splat threshold resolves the same real index (10)',
             read_m10.match?(/RARRAY_LEN\(r3\)\) \? RARRAY_PTR\(r3\)\[10\] : mrb_nil_value\(\)/))
  read_dynamic = compiled.call('read_dynamic')
  check.call('a non-literal (variable) key never gets the struct fast path',
             !read_dynamic.include?('MRB_TT_STRUCT') && read_dynamic.include?('bc2cpp_getidx(M, r'))
  read_string_key = compiled.call('read_string_key')
  check.call('a String literal key (not a Symbol) never gets the struct fast path either',
             !read_string_key.include?('MRB_TT_STRUCT'))

  # A member name shared by two distinct struct owners chains both, in
  # program order, each with its own resolved index, before the funcall.
  two_owner_src = <<~'RUBY'
    module Game
      One = Struct.new(:id, :a, keyword_init: true)
      Two = Struct.new(:id, :b, keyword_init: true)
      class Reader
        def get(x)
          x[:id]
        end
      end
    end
  RUBY
  Dir.mktmpdir do |dir2|
    source2 = File.join(dir2, 'two_owners.rb')
    File.write(source2, two_owner_src)
    ireps2, root2 = compile_ireps(source2, 'bc2cpp_two_owners', dir2)
    order2 = dfs_order(ireps2, root2)
    registry2, _s2, _c2, _i2, _p2, _u2, members2 = build_registry(ireps2, root2)
    CodeGen.struct_members = members2
    gen2 = CodeGen.new(ireps2, registry2, {}, {}, {}, {}, {}, {}, {}, {}, {}, Set.new)
    get_md = registry2.fetch('get').find { |d| d.owner == 'Game::Reader' }
    code = gen2.compile_method(get_md.irep).fetch(:code)
    check.call('two owners sharing one member name each get their own guarded branch, in order',
               code.scan('MRB_TT_STRUCT').size == 2 &&
                 code.index('bc2cpp_owner_class_0(M)') < code.index('bc2cpp_owner_class_1(M)') &&
                 code.index('bc2cpp_owner_class_1(M)') < code.index('bc2cpp_getidx(M, r'))
  end

  # STRUCT_INDEX_MAX: past the cap, the chain is left out entirely (falls
  # back to the funcall for every receiver, same as an unrecognized name).
  CodeGen.struct_members = (0..CodeGen::STRUCT_INDEX_MAX).to_h { |i| ["Owner#{i}", ['shared']] }
  gen3 = CodeGen.new({}, {}, {}, {}, {}, {}, {}, {}, {}, {}, {}, Set.new)
  reg3 = { 'probe' => [MethodDef.new(name: 'probe', owner: 'X', irep: 'irep0', visibility: :public)] }
  Dir.mktmpdir do |dir3|
    source3 = File.join(dir3, 'capped.rb')
    File.write(source3, "class X\n  def probe(s)\n    s[:shared]\n  end\nend\n")
    ireps3, root3 = compile_ireps(source3, 'bc2cpp_capped', dir3)
    order3 = dfs_order(ireps3, root3)
    registry3 = build_registry(ireps3, root3)[0]
    gen3 = CodeGen.new(ireps3, registry3, {}, {}, {}, {}, {}, {}, {}, {}, {}, Set.new)
    probe_md = registry3.fetch('probe').find { |d| d.owner == 'X' }
    code3 = gen3.compile_method(probe_md.irep).fetch(:code)
    check.call('more candidate owners than STRUCT_INDEX_MAX leaves the whole chain out',
               !code3.include?('MRB_TT_STRUCT'))
  end
end

if failures.empty?
  puts 'bc2cpp struct index check: PASS'
else
  warn "bc2cpp struct index check: #{failures.size} failure(s)"
  exit 1
end
