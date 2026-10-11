#!/usr/bin/env ruby
# encoding: UTF-8
# Exercise annotated return-class tracing through mrbc's dedicated GETIDX
# and GETIDX0 opcodes. Assert the index operation and a following call both
# use guarded TYPED codegen, with the indexed fallback retaining builtin
# container fast paths.

require 'tmpdir'
require_relative '../../tools/bc2cpp/bc2cpp'

# The generated symbol for `Game::EqTarget#==`, derived through the real
# CodeGen#cpp_name rather than spelled out. `==` mangles to `$3d$3d`, and
# writing that by hand inside a double-quoted string does not work: `$3d`
# interpolates. Spelling it out the old way (`Game__EqTarget____impl`) is
# worse -- that is what the non-injective mangling used to produce, so it
# stopped matching the moment sanitize changed.
CPP_NAME = CodeGen.instance_method(:cpp_name).bind(CodeGen.allocate)
EQ_TARGET_EQ_IMPL = "#{CPP_NAME.call('Game::EqTarget', '==')}_impl"

SRC = <<~'RUBY'
  class Array
    def bc2cpp_test_array_owner; end
  end
  class Hash
    def bc2cpp_test_hash_owner; end
  end
  module Game
    class Actor
      def name; :actor; end
    end
    class Picture
      def picture_only; :picture; end
    end
    class OtherPicture
      def picture_only; :other_picture; end
    end
    class Other
      def name; :other; end
      def alive?; true; end
      def drop_id; 0; end
      def drop_prob; 0; end
    end
    class OtherActors
      def [](id); nil; end
    end
    class Enemy
      def drop_id; 1; end
      def drop_prob; 100; end
    end
    class Troop
      # bc2cpp: (Array<Game::Enemy>)
      def initialize(members); @members = members; end
      # bc2cpp: () -> Array<Game::Enemy>
      def live_members; @members; end
      def drops(rng)
        live_members.each_with_object([]) do |enemy, out|
          next unless enemy.drop_id && enemy.drop_id > 0
          out << enemy.drop_id if rng.random(100) < enemy.drop_prob
        end
      end
    end
    class Actors
      # bc2cpp: (fixnum) -> Game::Actor
      def [](id); nil; end
      # bc2cpp: (fixnum) -> Game::Actor
      def existing(id); nil; end
    end
    class Battle
      Combatant = Struct.new(:hp) do
        def alive?; hp > 0; end
      end
    end
    class EmptyRoute
      def empty?; false; end
    end
    class EmptyRouteCaller
      def fresh_route_empty?; Game::EmptyRoute.new.empty?; end
      def unknown_empty?(value); value.empty?; end
    end
    class NativeValuesCaller
      def values_for(hash); hash.values; end
    end
    class NativeHashKeyCaller
      def hash_key?(hash, key); hash.key?(key); end
    end
    class NumericCompareCaller
      def equal?(left, right); left == right; end
      def less?(left, right); left < right; end
      def less_equal?(left, right); left <= right; end
      def greater?(left, right); left > right; end
      def greater_equal?(left, right); left >= right; end
    end
    class EqTarget
      def ==(other); other == 1; end
    end
    # A second `==` owner keeps the name polymorphic, so only a receiver whose
    # class is proven (EqTargetCaller) resolves; unknown receivers stay sends.
    class EqOther
      def ==(other); false; end
    end
    class EqTargetCaller
      def typed_eq; Game::EqTarget.new == 2; end
    end
    class HashKeySubclass < Hash
      def key?(key); :subclass_override; end
    end
    class HashValueOwner
      def initialize
        @sprites = {}
        @sprites[1] = Game::Actor.new
        @unknown = {}
      end
      def sprite_names_fallback
        @sprites.each_value do |sprite|
          sprite.name
          begin
            1 / 0
          rescue ZeroDivisionError
            nil
          end
        end
      end
      def unknown_names_fallback
        @unknown.each_value do |sprite|
          sprite.name
          begin
            1 / 0
          rescue ZeroDivisionError
            nil
          end
        end
      end
    end
    class HashPictureOwner
      # bc2cpp: (Hash<Game::Picture>, fixnum, fixnum)
      def picture_name(pictures, id, unused); pictures[id].picture_only; end
      # bc2cpp: (Hash<Game::Picture>, fixnum)
      def first_picture(pictures, id); pictures[id].picture_only; end
      # bc2cpp: (Hash<Game::Picture>)
      def sorted_picture_names(pictures)
        pictures.keys.sort.each do |id|
          pictures[id].picture_only
        end
      end
      # An untyped hash must retain dynamic result dispatch.
      def unknown_picture_name(pictures, id); pictures[id].picture_only; end
    end
    class FilterMapOwner
      def initialize
        @filtered = []
        @heterogeneous = []
      end
      # bc2cpp: (Array<Game::Picture>)
      def store_filtered_picture(pictures)
        @filtered = pictures.filter_map do |picture|
          next picture if picture.picture_only
          nil
        end
      end
      # bc2cpp: (Array<Game::Picture>)
      def filtered_picture_call
        @filtered.each { |picture| picture.picture_only }
      end
      # bc2cpp: (Array<Game::Picture>)
      def store_heterogeneous_filter_map(pictures)
        @heterogeneous = pictures.filter_map do |picture|
          if picture.picture_only
            next picture
          else
            next Game::OtherPicture.new
          end
        end
      end
      def heterogeneous_filter_map_call
        @heterogeneous.each { |picture| picture.picture_only }
      end
    end
    class Party
      # bc2cpp: (Array<Game::Battle::Combatant>)
      def initialize(combatants); @combatants = combatants; end
      def fetch(id); @roster[id].name; end
      def first; @roster[0].name; end
      # bc2cpp: () -> Array<Game::Actor>
      def targets; @actors; end
      def target_names_each; targets.each { |actor| actor.name }; end
      def target_names_any; targets.any? { |actor| actor.name }; end
      def target_names_fallback
        targets.each do |actor|
          actor.name
          begin
            1 / 0
          rescue ZeroDivisionError
            nil
          end
        end
      end
      def target_names_each_with_object_fallback
        targets.each_with_object([]) do |actor, out|
          actor.name
          out.size
          begin
            1 / 0
          rescue ZeroDivisionError
            out
          end
        end
      end
      def untyped_names_fallback
        @untyped.each do |actor|
          actor.name
          begin
            1 / 0
          rescue ZeroDivisionError
            nil
          end
        end
      end
      def target_names_each_with_index_fallback
        targets.each_with_index do |actor, index|
          actor.name
          begin
            1 / 0
          rescue ZeroDivisionError
            index
          end
        end
      end
      def untyped_names_each_with_index_fallback
        @untyped.each_with_index do |actor, index|
          actor.name
          begin
            1 / 0
          rescue ZeroDivisionError
            index
          end
        end
      end
      def untyped_each_with_object_fallback
        @untyped.each_with_object([]) do |actor, out|
          actor.name
          out.size
          begin
            1 / 0
          rescue ZeroDivisionError
            out
          end
        end
      end
      def existing_name; @roster.existing(1).name; end
      def combatant_alive; @combatants.each { |combatant| combatant.alive? }; end
    end
  end
RUBY

failures = []
check = lambda do |what, actual, expected|
  if actual == expected
    puts "  ok  #{what}"
  else
    puts "  FAIL #{what}: expected #{expected.inspect}, got #{actual.inspect}"
    failures << what
  end
end

Dir.mktmpdir do |dir|
  source = File.join(dir, 'retclass.rb')
  File.write(source, SRC)
  ireps, root_label = compile_ireps(source, 'bc2cpp_retclass', dir)
  order = dfs_order(ireps, root_label)
  registry = build_registry(ireps, root_label)[0]
  owners = Set.new(registry.values.flatten.map(&:owner))
  annotations = ElementAnnotations.extract(ireps, registry, owners)
  class_layout = { 'Game::Party' => { 'roster' => 'Actors', 'actors' => 'Array', 'untyped' => 'Array',
                                     'combatants' => 'Array' },
                  'Game::HashValueOwner' => { 'sprites' => 'Hash', 'unknown' => 'Hash' },
                  'Game::FilterMapOwner' => { 'filtered' => 'Array', 'heterogeneous' => 'Array' } }
  class_annotations = ClassAnnotations.extract(ireps, registry, owners)
  party_init = registry['initialize'].find { |md| md.owner == 'Game::Party' }
  check.call('Array<Klass> argument keeps the Array receiver type',
             class_annotations.fetch(party_init.irep).args.first == 'Array', true)
  check.call('Array<Klass> argument records its element class',
             annotations.fetch(party_init.irep).arg_elements.first == 'Game::Battle::Combatant', true)
  picture_method = registry['picture_name'].find { |md| md.owner == 'Game::HashPictureOwner' }
  check.call('Hash<Klass> argument records exact Hash/value types',
             class_annotations.fetch(picture_method.irep).args.first == 'Hash' &&
             annotations.fetch(picture_method.irep).arg_elements.first == 'Game::Picture' &&
               annotations.fetch(picture_method.irep).arg_containers.first == 'Hash', true)
  element_layout = ArrayElementLayout.known(
    ArrayElementLayout.analyze(ireps, registry, class_layout, class_annotations, annotations)
  )
  hash_element_layout = HashElementLayout.known(
    HashElementLayout.analyze(ireps, registry, class_layout, class_annotations, annotations, element_layout)
  )
  gen = CodeGen.new(ireps, registry, {}, class_layout, class_annotations, {}, {}, element_layout, annotations, {},
                    hash_element_layout, Set.new)

  picture_irep = ireps.fetch(picture_method.irep)
  picture_send_idx = picture_irep.instructions.index { |insn| insn.op == 'SEND0' && insn.args.include?(':picture_only') }
  picture_code = gen.compile_send(picture_irep.instructions[picture_send_idx], self_implicit: false,
                                  irep: picture_irep, idx: picture_send_idx, owner_def: picture_method)
  check.call('Hash<Klass> indexed value calls use guarded typed accessor dispatch',
             picture_code.include?('TYPED :picture_only -> Game::Picture') &&
               picture_code.include?('mrb_obj_class(M, r') && picture_code.match?(/(?:mrb_funcall|bc2cpp_funcall_explicit)\(M,/), true)

  sorted_method = registry['sorted_picture_names'].find { |md| md.owner == 'Game::HashPictureOwner' }
  sorted_code = gen.compile_method(sorted_method.irep).fetch(:code)
  check.call('captured Hash<Klass> values devirtualize inside an inlined each block',
             sorted_code.include?('TYPED :picture_only -> Game::Picture') &&
               sorted_code.include?('mrb_obj_class(M, r') && sorted_code.match?(/(?:mrb_funcall|bc2cpp_funcall_explicit)\(M,/), true)

  picture_getidx_idx = picture_irep.instructions.index { |insn| insn.op == 'GETIDX' }
  picture_index_code = gen.compile_insn(picture_irep.instructions[picture_getidx_idx], picture_irep,
                                        picture_method, picture_getidx_idx)
  check.call('Hash<Klass> GETIDX falls back for an incorrect runtime receiver type',
             picture_index_code.include?('mrb_hash_p(r') && picture_index_code.include?('mrb_hash_get(M,') &&
               picture_index_code.match?(/(?:mrb_funcall|bc2cpp_funcall_explicit)\(M,/) && !picture_index_code.include?('expected Hash receiver'), true)

  first_picture_method = registry['first_picture'].find { |md| md.owner == 'Game::HashPictureOwner' }
  first_picture_irep = ireps.fetch(first_picture_method.irep)
  getidx0_idx = first_picture_irep.instructions.index { |insn| insn.op == 'GETIDX' }
  raise 'first_picture: expected GETIDX instruction' unless getidx0_idx

  receiver_reg = first_picture_irep.instructions[getidx0_idx].reg
  getidx0_insn = Insn.new(lineno: 1, addr: 0, op: 'GETIDX0', args: "R4 R#{receiver_reg}[0]", raw: '')
  getidx0_code = gen.compile_insn(getidx0_insn, first_picture_irep, first_picture_method, getidx0_idx)
  check.call('Hash<Klass> GETIDX0 falls back for an incorrect runtime receiver type',
             getidx0_code.include?('mrb_hash_p(r') && getidx0_code.include?('mrb_hash_get(M,') &&
               getidx0_code.match?(/(?:mrb_funcall|bc2cpp_funcall_explicit)\(M,/) && !getidx0_code.include?('expected Hash receiver'), true)

  unknown_method = registry['unknown_picture_name'].find { |md| md.owner == 'Game::HashPictureOwner' }
  unknown_irep = ireps.fetch(unknown_method.irep)
  unknown_send_idx = unknown_irep.instructions.index { |insn| insn.op == 'SEND0' && insn.args.include?(':picture_only') }
  unknown_code = gen.compile_send(unknown_irep.instructions[unknown_send_idx], self_implicit: false,
                                  irep: unknown_irep, idx: unknown_send_idx, owner_def: unknown_method)
  check.call('untyped Hash indexed values retain ordinary dispatch',
             !unknown_code.include?('TYPED :picture_only -> Game::Picture#picture_only') &&
               unknown_code.match?(/(?:mrb_funcall|bc2cpp_funcall_explicit)\(M,/), true)

  filtered_call = registry['filtered_picture_call'].find { |md| md.owner == 'Game::FilterMapOwner' }
  filtered_code = gen.compile_method(filtered_call.irep).fetch(:code)
  check.call('filter_map preserves filtered element class through a subsequent each block',
             filtered_code.include?('ELEMENT :picture_only -> Game::Picture') &&
               filtered_code.include?('mrb_obj_class(M, r') && filtered_code.match?(/(?:mrb_funcall|bc2cpp_funcall_explicit)\(M,/), true)

  heterogeneous = registry['heterogeneous_filter_map_call'].find { |md| md.owner == 'Game::FilterMapOwner' }
  heterogeneous_code = gen.compile_method(heterogeneous.irep).fetch(:code)
  check.call('heterogeneous filter_map results retain dynamic dispatch',
             !heterogeneous_code.include?('TYPED :picture_only -> Game::Picture') &&
               heterogeneous_code.match?(/(?:mrb_funcall|bc2cpp_funcall_explicit)\(M,/), true)

  %w[fetch first].each do |method_name|
    method = registry[method_name].find { |md| md.owner == 'Game::Party' }
    irep = ireps.fetch(method.irep)
    getidx_idx = irep.instructions.index { |insn| insn.op == 'GETIDX' }
    raise "#{method_name}: no GETIDX instruction found" unless getidx_idx

    index_insn = if method_name == 'first'
                   receiver = irep.instructions[getidx_idx].reg
                   Insn.new(lineno: 1, addr: 0, op: 'GETIDX0', args: "R4 R#{receiver}[0]", raw: '')
                 else
                   irep.instructions[getidx_idx]
                 end
    index_op = index_insn.op
    index_code = gen.compile_insn(index_insn, irep, method, getidx_idx)
    check.call("#{method_name}: #{index_op} devirtualizes annotated [] with guard/fallback",
               index_code.include?('TYPED :[] -> Game::Actors#[]') &&
                 index_code.include?('mrb_obj_class(M, r') &&
                 # OUTLINED_INDEX_OPS: the guard's else arm is the generic chain's helper.
                 index_code.include?("bc2cpp_#{index_op.downcase}(M, r"), true)

    idx = irep.instructions.index { |insn| insn.op == 'SEND0' && insn.args.include?(':name') }
    raise "#{method_name}: no #name send found" unless idx

    code = gen.compile_send(irep.instructions[idx], self_implicit: false, irep: irep, idx: idx,
                            owner_def: method)
    check.call("#{method_name}: annotated indexed result devirtualizes with guard/fallback",
               code.include?('TYPED :name -> Game::Actor#name') &&
                 code.include?('mrb_obj_class(M, r') && code.match?(/(?:mrb_funcall|bc2cpp_funcall_explicit)\(M,/), true)
  end
  %w[target_names_each target_names_any].each do |method_name|
    method = registry[method_name].find { |md| md.owner == 'Game::Party' }
    irep = ireps.fetch(method.irep)
    code = gen.compile_method(method.irep).fetch(:code)
    check.call("#{method_name}: typed array return devirtualizes block element with guard/fallback",
               code.include?('ELEMENT :name -> Game::Actor#name') &&
                 code.include?('mrb_obj_class(M, r') && code.match?(/(?:mrb_funcall|bc2cpp_funcall_explicit)\(M,/), true)
  end

  fallback = registry['target_names_fallback'].find { |md| md.owner == 'Game::Party' }
  fallback_code = gen.compile_method(fallback.irep).fetch(:code)
  check.call('fallback Array#each devirtualizes typed elements with guard/fallback',
             fallback_code.include?('BLOCK_FALLBACK :each') &&
               fallback_code.include?('ELEMENT :name -> Game::Actor#name') &&
               fallback_code.include?('mrb_obj_class(M, r') && fallback_code.match?(/(?:mrb_funcall|bc2cpp_funcall_explicit)\(M,/), true)

  untyped = registry['untyped_names_fallback'].find { |md| md.owner == 'Game::Party' }
  untyped_code = gen.compile_method(untyped.irep).fetch(:code)
  check.call('fallback Array#each leaves unknown elements dynamic',
             untyped_code.include?('BLOCK_FALLBACK :each') &&
               !untyped_code.include?('ELEMENT :name -> Game::Actor#name'), true)

  indexed_fallback = registry['target_names_each_with_index_fallback'].find { |md| md.owner == 'Game::Party' }
  indexed_fallback_code = gen.compile_method(indexed_fallback.irep).fetch(:code)
  check.call('fallback Array#each_with_index devirtualizes typed elements with guard/fallback',
             indexed_fallback_code.include?('BLOCK_FALLBACK :each_with_index') &&
               indexed_fallback_code.include?('ELEMENT :name -> Game::Actor#name') &&
               indexed_fallback_code.include?('mrb_obj_class(M, r') &&
               indexed_fallback_code.match?(/(?:mrb_funcall|bc2cpp_funcall_explicit)\(M,/), true)

  untyped_indexed_fallback = registry['untyped_names_each_with_index_fallback'].find do |md|
    md.owner == 'Game::Party'
  end
  untyped_indexed_fallback_code = gen.compile_method(untyped_indexed_fallback.irep).fetch(:code)
  check.call('fallback Array#each_with_index leaves unknown elements dynamic',
             untyped_indexed_fallback_code.include?('BLOCK_FALLBACK :each_with_index') &&
             !untyped_indexed_fallback_code.include?('ELEMENT :name -> Game::Actor#name'), true)

  each_with_object = registry['target_names_each_with_object_fallback'].find { |md| md.owner == 'Game::Party' }
  each_with_object_code = gen.compile_method(each_with_object.irep).fetch(:code)
  check.call('fallback Array#each_with_object devirtualizes typed elements only',
             each_with_object_code.include?('BLOCK_FALLBACK :each_with_object') &&
               each_with_object_code.include?('ELEMENT :name -> Game::Actor#name') &&
               each_with_object_code.include?('mrb_obj_class(M, r') &&
               each_with_object_code.match?(/(?:mrb_funcall|bc2cpp_funcall_explicit)\(M,/), true)

  drops = registry['drops'].find { |md| md.owner == 'Game::Troop' }
  drops_code = gen.compile_method(drops.irep).fetch(:code)
  check.call('fallback each_with_object resolves a bare annotated Array return',
             drops_code.include?('BLOCK_FALLBACK :each_with_object') &&
               drops_code.include?('ELEMENT :drop_id -> Game::Enemy#drop_id') &&
               drops_code.include?('ELEMENT :drop_prob -> Game::Enemy#drop_prob') &&
               drops_code.include?('mrb_obj_class(M, r') && drops_code.match?(/(?:mrb_funcall|bc2cpp_funcall_explicit)\(M,/), true)

  untyped_each_with_object = registry['untyped_each_with_object_fallback'].find { |md| md.owner == 'Game::Party' }
  untyped_each_with_object_code = gen.compile_method(untyped_each_with_object.irep).fetch(:code)
  check.call('fallback Array#each_with_object leaves unknown elements dynamic',
             untyped_each_with_object_code.include?('BLOCK_FALLBACK :each_with_object') &&
             !untyped_each_with_object_code.include?('ELEMENT :name -> Game::Actor#name'), true)
  # The real build's mruby core registry contributes this native marker.
  # Keep it local to these checks so the known receiver exercises the same
  # empty? intrinsic ordering as a shipped build.
  empty_registry = registry.transform_values(&:dup)
  (empty_registry['empty?'] ||= []) << MethodDef.new(name: 'empty?', owner: '<native>', irep: nil,
                                                      visibility: :public)
  native_sources = Dir[
    File.expand_path('../3rd/mruby/src/**/*.{c,cxx}', __dir__),
    File.expand_path('../3rd/mruby/mrbgems/**/src/**/*.{c,cxx}', __dir__)
  ]
  native_exact_class_expressions = NativeExpressionDevirt.analyze_exact_class_expressions(native_sources)
  empty_gen = CodeGen.new(ireps, empty_registry, {}, class_layout, class_annotations, {}, {}, element_layout,
                          annotations, {}, {}, Set.new,
                          native_registered_expressions: native_exact_class_expressions)
  fresh_empty = empty_registry['fresh_route_empty?'].find { |md| md.owner == 'Game::EmptyRouteCaller' }
  fresh_empty_code = empty_gen.compile_method(fresh_empty.irep).fetch(:code)
  check.call('typed Ruby empty? target takes priority over built-in container intrinsic',
             fresh_empty_code.include?('TYPED :empty? -> Game::EmptyRoute#empty?') &&
               fresh_empty_code.include?('mrb_obj_class(M, r') && fresh_empty_code.match?(/(?:mrb_funcall|bc2cpp_funcall_explicit)\(M,/), true)

  unknown_empty = empty_registry['unknown_empty?'].find { |md| md.owner == 'Game::EmptyRouteCaller' }
  unknown_empty_code = empty_gen.compile_method(unknown_empty.irep).fetch(:code)
  check.call('unknown empty? receiver retains built-in container intrinsic and fallback',
             unknown_empty_code.include?('empty? -- generated from native registrations and C method bodies') &&
               unknown_empty_code.match?(/(?:mrb_funcall|bc2cpp_funcall_explicit)\(M,/), true)

  values_registry = registry.transform_values(&:dup)
  (values_registry['values'] ||= []) << MethodDef.new(name: 'values', owner: '<native>', irep: nil,
                                                       visibility: :public)
  values_gen = CodeGen.new(ireps, values_registry, {}, class_layout, class_annotations, {}, {}, element_layout,
                           annotations, {}, {}, Set.new)
  values_method = values_registry['values_for'].find { |md| md.owner == 'Game::NativeValuesCaller' }
  values_code = values_gen.compile_method(values_method.irep).fetch(:code)
  check.call('Hash#values uses guarded native implementation with Ruby fallback',
             values_code.include?('mrb_hash_values(M,') && values_code.include?('mrb_hash_p(r') &&
               values_code.include?('M->hash_class') && values_code.match?(/(?:mrb_funcall|bc2cpp_funcall_explicit)\(M,/), true)

  key_registry = registry.transform_values(&:dup)
  (key_registry['key?'] ||= []) << MethodDef.new(name: 'key?', owner: '<native>', irep: nil,
                                                  visibility: :public)
  key_gen = CodeGen.new(ireps, key_registry, {}, class_layout, class_annotations, {}, {}, {}, {}, {}, {}, Set.new)
  key_method = key_registry.fetch('hash_key?').find { |md| md.owner == 'Game::NativeHashKeyCaller' }
  key_code = key_gen.compile_method(key_method.irep).fetch(:code)
  check.call('Hash#key? uses guarded native implementation with Ruby fallback',
             key_code.include?('mrb_hash_key_p(M,') && key_code.include?('mrb_hash_p(r') &&
               key_code.include?('M->hash_class') && key_code.match?(/(?:mrb_funcall|bc2cpp_funcall_explicit)\(M,/), true)

  compare_methods = {
    'equal?' => '==', 'less?' => '<', 'less_equal?' => '<=', 'greater?' => '>',
    'greater_equal?' => '>='
  }
  compare_methods.each do |method_name, operator|
    method = registry.fetch(method_name).find { |md| md.owner == 'Game::NumericCompareCaller' }
    code = gen.compile_method(method.irep).fetch(:code)
    check.call("OP_CMP #{operator} mirrors Integer/Float tags and keeps dynamic fallback",
               code.include?('MRB_TT_INTEGER') && code.include?('MRB_TT_FLOAT') &&
                 code.include?('mrb_integer(r') && code.include?('mrb_float(r') &&
                 code.match?(/(?:mrb_funcall|bc2cpp_funcall_explicit)\(M,/), true)
    if operator == '=='
      check.call('OP_EQ preserves identity before numeric comparison',
                 code.index('mrb_obj_eq(M,') < code.index('MRB_TT_INTEGER'), true)
      # OP_EQ: a non-identical Symbol receiver is unequal without any send, and
      # the shortcut sits between the identity test and the numeric arms.
      check.call('OP_EQ answers a non-identical Symbol receiver false without dispatch',
                 code.index('mrb_obj_eq(M,') < code.index('mrb_symbol_p(r') &&
                   code.index('mrb_symbol_p(r') < code.index('MRB_TT_INTEGER') &&
                   code.include?('mrb_false_value()'), true)
      # The fallback stores the `==` method's own result (OP_CMP's L_SEND_SYM)
      # rather than re-testing identity and coercing to a boolean.
      check.call('OP_EQ fallback sends == once and keeps its raw result',
                 !code.include?('|| mrb_test(mrb_funcall') &&
                   code.match?(/r\d+ = mrb_funcall\(M, r\d+, "==", 1, r\d+\);/), true)
    end
  end

  eq_caller = registry.fetch('typed_eq').find { |md| md.owner == 'Game::EqTargetCaller' }
  eq_code = gen.compile_method(eq_caller.irep).fetch(:code)
  check.call('OP_EQ fallback goes through the MONO/TYPED resolver like the other comparisons',
             eq_code.include?('TYPED :== -> Game::EqTarget#==') && eq_code.include?("#{EQ_TARGET_EQ_IMPL}(M, r") &&
               eq_code.include?('mrb_funcall(M, r2, "==", 1, r3)'), true)

  overridden_key_registry = key_registry.transform_values(&:dup)
  overridden_key_registry['key?'] << MethodDef.new(name: 'key?', owner: 'Hash', irep: nil,
                                                     visibility: :public)
  overridden_key_gen = CodeGen.new(ireps, overridden_key_registry, {}, class_layout, class_annotations, {}, {},
                                   {}, {}, {}, {}, Set.new)
  overridden_key_method = overridden_key_registry.fetch('hash_key?').find do |md|
    md.owner == 'Game::NativeHashKeyCaller'
  end
  overridden_key_code = overridden_key_gen.compile_method(overridden_key_method.irep).fetch(:code)
  check.call('Hash#key? keeps dynamic lookup when Hash defines a Ruby override',
             !overridden_key_code.include?('mrb_hash_key_p(M,') && overridden_key_code.match?(/(?:mrb_funcall|bc2cpp_funcall_explicit)\(M,/),
             true)

  hash_values = registry['sprite_names_fallback'].find { |md| md.owner == 'Game::HashValueOwner' }
  hash_values_code = gen.compile_method(hash_values.irep).fetch(:code)
  check.call('fallback Hash#each_value devirtualizes proven values with guard/fallback',
             hash_values_code.include?('BLOCK_FALLBACK :each_value') &&
               hash_values_code.include?('ELEMENT :name -> Game::Actor#name') &&
               hash_values_code.include?('mrb_obj_class(M, r') &&
               hash_values_code.match?(/(?:mrb_funcall|bc2cpp_funcall_explicit)\(M,/), true)

  unknown_hash_values = registry['unknown_names_fallback'].find { |md| md.owner == 'Game::HashValueOwner' }
  unknown_hash_values_code = gen.compile_method(unknown_hash_values.irep).fetch(:code)
  check.call('fallback Hash#each_value leaves unknown values dynamic',
             unknown_hash_values_code.include?('BLOCK_FALLBACK :each_value') &&
               !unknown_hash_values_code.include?('ELEMENT :name -> Game::Actor#name'), true)

  method = registry['existing_name'].find { |md| md.owner == 'Game::Party' }
  code = gen.compile_method(method.irep).fetch(:code)
  check.call('annotated cached lookup devirtualizes subsequent Actor dispatch',
             code.include?('TYPED :name -> Game::Actor#name') &&
               code.include?('mrb_obj_class(M, r') && code.match?(/(?:mrb_funcall|bc2cpp_funcall_explicit)\(M,/), true)

  method = registry['combatant_alive'].find { |md| md.owner == 'Game::Party' }
  code = gen.compile_method(method.irep).fetch(:code)
  check.call('typed array argument devirtualizes a Struct element with guard/fallback',
             code.include?('ELEMENT :alive? -> Game::Battle::Combatant#alive?') &&
               code.include?('mrb_obj_class(M, r') && code.match?(/(?:mrb_funcall|bc2cpp_funcall_explicit)\(M,/), true)

  inherited_source = File.join(dir, 'inherited_retclass.rb')
  File.write(inherited_source, <<~'RUBY')
    class RetActor; def actor?; true; end; end
    class RetBase
      # bc2cpp: () -> RetActor
      def produce; RetActor.new; end
    end
    class RetChild < RetBase; end
    class RetOther
      def produce; String.new; end
    end
    class RetHolder
      def initialize; @child = RetChild.new; @items = [@child.produce]; end
    end
  RUBY
  inherited_ireps, inherited_root = compile_ireps(inherited_source, 'bc2cpp_inherited_retclass', dir)
  inherited_order = dfs_order(inherited_ireps, inherited_root)
  inherited_registry, inherited_supers, _cc, inherited_includes, inherited_prepends, inherited_unknown,
    _structs, inherited_decls, inherited_walked = build_registry(inherited_ireps, inherited_root)
  inherited_owners = Set.new(inherited_registry.values.flatten.map(&:owner))
  inherited_annotations = ClassAnnotations.extract(inherited_ireps, inherited_registry, inherited_owners)
  inherited_element_annotations = ElementAnnotations.extract(inherited_ireps, inherited_registry, inherited_owners)
  inherited_world = ClosedWorld.new(ireps: inherited_ireps, registry: inherited_registry,
                                    class_decls: inherited_decls, walked: inherited_walked,
                                    native_paths: [], ruby_paths: [])
  inherited_ctx = { registry: inherited_registry, ireps: inherited_ireps, class_layout: {},
                    known_owners: inherited_owners,
                    element_annotations: inherited_element_annotations, class_annotations: inherited_annotations,
                    closed_world: inherited_world, superclass_of: inherited_supers,
                    included_modules: inherited_includes, prepended_modules: inherited_prepends,
                    unknown_mixins: inherited_unknown }
  inherited_base_method = inherited_registry.fetch('produce').find { |md| md.owner == 'RetBase' }
  inherited_ctx[:owner] = inherited_base_method.owner
  inherited_ctx[:ivar_classes] = {}
  inherited_ctx[:mand] = 0
  inherited_ctx[:arg_classes] = nil
  check.call('inherited lookup computes the ancestor method return class',
             class_scoped_return_class('RetChild', 'produce', inherited_ctx, 0), 'RetActor')
  inherited_ctx_without_world = inherited_ctx.merge(closed_world: nil)
  check.call('inherited return class stays unknown without closed-world proof',
             class_scoped_return_class('RetChild', 'produce', inherited_ctx_without_world, 0).nil?, true)
  inherited_ctx_with_mixin = inherited_ctx.merge(included_modules: { 'RetChild' => Set['RetMixin'] })
  check.call('inherited return class refuses a mixed-in receiver',
             class_scoped_return_class('RetChild', 'produce', inherited_ctx_with_mixin, 0).nil?, true)
  inherited_with_direct_native = inherited_registry.transform_values(&:dup)
  inherited_with_direct_native['produce'] << MethodDef.new(name: 'produce', owner: 'RetChild', irep: nil,
                                                            visibility: :public)
  inherited_ctx_with_native = inherited_ctx.merge(registry: inherited_with_direct_native)
  check.call('a direct native definition prevents bypassing it for an ancestor return proof',
             class_scoped_return_class('RetChild', 'produce', inherited_ctx_with_native, 0).nil?, true)
end

if failures.empty?
  puts 'bc2cpp annotated return/container-argument devirtualization check: PASS'
else
  warn "bc2cpp annotated return/container-argument devirtualization check: #{failures.size} failure(s)"
  exit 1
end
