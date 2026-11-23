# frozen_string_literal: true

require 'set'
require 'zlib'
require_relative 'bytecode_ir'
require_relative 'const_def_elide'
require_relative 'const_site_cache'

# CONST_BINDING_DROP (BC2CPP_DROP_CONST_BINDINGS=0 keeps every binding): a value constant whose every read the
# generated code resolves statically is stored in a per-VM table instead of its owner's constant table. The write is
# bc2cpp_cdef_set (codegen_const_tables.rb): it raises FrozenError for a frozen owner as mrb_const_set does, still binds
# a class or module value (mruby names it from the binding), and stores the value in an Array hung off Object under a
# name no Ruby can spell, which also roots it. A read finds the value there, or misses and runs the lookup it ran
# before, which raises the same NameError (or calls const_missing) as a read before the definition. The soundness
# condition, enforced by analyze:
#   world: CONST_DEF_ELIDE's (ConstDefElide.world_refusal: no bytecode runs, constant bindings are static, nothing reads
#     or enumerates a constant table by a computed name, every native computed-name read is reviewed), and nothing lists
#     the global variables or counts the objects (REFLECTION); STATIC_CONSTANTS is on (a GETCONST read is a site-cache row).
#   name: one binding in the world (StableValueConstants: one SETCONST, no class/module, no native or foreign
#     definition); that SETCONST has a known lexical scope in a class/module body that runs once (ConstBindings
#     run_once_bodies, not the root, which every gem's TOP_LEVEL_STATEMENTS run); every GETCONST/GETMCNST of the name
#     resolves to that binding (LexicalConsts read_keys), so a hit is what the lookup would find; no other opcode and no
#     native source spells the name, and no reviewed native read reaches its owner.
# CodeGen#assert_const_drop_unnamed! then checks that the generated text of each run names no dropped constant.
module ConstBindingDrop
  # index: the name's slot in the per-VM table, the same in every gem of one world; owner: the binding's scope.
  Result = Struct.new(:names, :refusal, :kept, :fingerprint, keyword_init: true) do
    def drop?(name) = names.key?(name)
    def index(name) = names.fetch(name)[:index]
  end

  # CONST_DEF_ELIDE's methods, and the two that would see the per-VM table: it is a global variable and an Array.
  REFLECTION = (ConstDefElide::REFLECTION | %w[global_variables count_objects]).freeze

  module_function

  def enabled?
    ENV['BC2CPP_DROP_CONST_BINDINGS'] != '0' && ENV['BC2CPP_STATIC_CONSTANTS'] != '0'
  end

  # facts: the BYTECODE_CONSTANT_FACTS groups, for the plain writes (plain_write?).
  def analyze(ireps:, root_label:, stable_values:, elided:, lexical:, facts:, closed_world:, linked_native:,
              spelled_native:, mixins:)
    refusal = world_refusal(ireps, root_label, stable_values, closed_world, linked_native)
    reached, why = ConstDefElide.native_reached(linked_native, mixins)
    refusal ||= why
    return Result.new(names: {}, refusal: refusal, kept: {}, fingerprint: 0) if refusal

    spelled = ConstDefElide.spelled_names(spelled_native)
    once = ConstBindings.run_once_bodies(ireps, root_label)
    defs = Hash.new { |h, k| h[k] = [] }
    reads = Hash.new { |h, k| h[k] = [] }
    other = Set.new
    ireps.each do |label, irep|
      BytecodeIR.for(irep).each_source do |insn, _idx|
        case insn.op
        when :SETCONST then defs[insn.const_name] << [label, insn]
        when :SETMCNST then defs[insn.mcnst_name] << [label, nil]
        when :GETCONST then reads[insn.const_name] << insn
        when :GETMCNST then reads[insn.mcnst_name] << insn
        when :CLASS, :MODULE then other << insn.sym.to_s
        else
          sym = insn.sym
          other << sym.to_s if sym && !ConstDefElide::CONST_OPS.include?(insn.op)
        end
      end
    end
    names = {}
    kept = {}
    defs.each do |name, sites|
      next unless stable_values.include?(name)

      why = name_refusal(name, sites, reads[name], ireps, root_label, once, elided, lexical, other, spelled, reached)
      next kept[name] = why if why

      owner = lexical.site_keys[sites.first[1]].delete_suffix("::#{name}")
      names[name] = { owner: owner, plain: plain_write?(facts[name], owner, closed_world) }
    end
    names.keys.sort.each_with_index { |name, i| names[name][:index] = i }
    Result.new(names: names, refusal: nil, kept: kept, fingerprint: Zlib.crc32(names.keys.sort.join("\n")) & 0x3fff_ffff)
  end

  def world_refusal(ireps, root_label, stable_values, closed_world, linked_native)
    return 'BC2CPP_DROP_CONST_BINDINGS=0 or BC2CPP_STATIC_CONSTANTS=0' unless enabled?
    return 'no root irep or no stable value constants' unless root_label && stable_values

    ConstDefElide.world_refusal(ireps, closed_world, linked_native, switch: false, reflection: REFLECTION)
  end

  def name_refusal(name, sites, reads, ireps, root_label, once, elided, lexical, other, spelled, reached)
    return 'elided (CONST_DEF_ELIDE)' if elided&.include?(name)
    return 'not one SETCONST' unless sites.size == 1 && sites.first[1]

    label, insn = sites.first
    key = lexical.site_keys[insn]
    return 'a binding in an unknown lexical scope' unless key
    return 'a top-level binding' if label == root_label || !key.include?('::')
    return 'a binding in a body that may not run once' unless once.include?(label) &&
                                                              !ConstBindings.backward_branch?(ireps.fetch(label))
    return 'a read not resolved to the binding' unless reads.all? { |read| lexical.read_keys[read] == key }
    return 'spelled by another opcode' if other.include?(name)
    return 'spelled by native code' if spelled.include?(name)

    owner = key.delete_suffix("::#{name}")
    return "#{owner} is reached by a native constant read" if reached.include?(owner)

    nil
  end

  # PLAIN_WRITE: the write needs neither its owner nor its name, only the table store: every value the binding can hold
  # is of a known class that is not Class or Module (nothing to name), and its owner can never be frozen (no
  # FrozenError to raise). Otherwise bc2cpp_cdef_set checks both at run time.
  NAMED_CLASSES = %i[Class Module].freeze

  def plain_write?(fact, owner, closed_world)
    classes = fact&.classes
    return false if classes.nil? || classes.empty? || classes.any? { |c| NAMED_CLASSES.include?(c.to_sym) }

    !closed_world.class_object_freeze_possible?(owner.split('::').last)
  end

  def report(result)
    if result.refusal
      warn "== constant bindings dropped (CONST_BINDING_DROP): off (#{result.refusal}) =="
    else
      warn "== constant bindings dropped (CONST_BINDING_DROP): #{result.names.size} names, #{result.kept.size} kept =="
      result.names.sort.each { |name, row| warn "  CONST_BINDING_DROP #{row[:owner]}::#{name}#{' plain' if row[:plain]}" }
      result.kept.sort.each { |name, why| warn "  CONST_BINDING_KEPT #{name} (#{why})" }
    end
    warn ''
  end
end
