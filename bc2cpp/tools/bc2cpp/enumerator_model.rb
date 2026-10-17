# frozen_string_literal: true

require 'set'
require_relative 'core_defs'
require_relative 'source_text'
require_relative 'const_site_cache'
require_relative 'integer_constants'
require_relative 'core_fact_sigs'

# ENUMERATOR_MODEL (docs/adr/0418): what the compiler may assume about mruby's Enumerator machinery,
# proven from the bytecode of the program rather than from names.
#
# TO_ENUM_DIRECT: mruby-enumerator defines `Kernel#to_enum(meth = :each, *args, **kwd)` as
# `Enumerator.new self, meth, *args, **kwd` and `alias enum_for to_enum`. The 66 `return to_enum(:x)
# unless block` lines of mruby's own Ruby (Array, Hash, Range, String, Enumerable ...) are by-name
# sends of a method that has exactly one definition in the program. When the receiver is a proven
# exact core class, that definition is the only candidate, so the site builds the Enumerator itself
# (`Class#new` on the stable constant, i.e. what the body does) and skips the lookup of `to_enum`.
module EnumeratorModel
  FILE_SUFFIX = '/mruby-enumerator/mrblib/enumerator.rb'
  # Kernel's Enumerator makers, from sig/bc2cpp/declarations.rbs#core_enumerators.
  NAMES = CoreFactSigs.enumerator_makers
  # Names the direct construction relies on: a definition of any of them outside mruby's own Ruby (or a second one inside)
  # withdraws the model.
  CONSTRUCTION_NAMES = %w[to_enum enum_for new allocate initialize].freeze
  CONSTRUCTION_OWNERS = %w[Enumerator Enumerator.singleton Class Module Object Object.singleton Kernel BasicObject
                           BasicObject.singleton Kernel.singleton].freeze

  Result = Struct.new(:to_enum_direct, :reason, :constant_stable)

  module_function

  # registry: name => [MethodDef]; ireps: label => Irep; alias_sites: registry.rb's ALIAS records.
  # Call BEFORE the core filtering drops the interpreted definitions from the registry.
  def analyze(registry, ireps, alias_sites)
    return Result.new(false, 'disabled (BC2CPP_ENUMERATOR_MODEL=0)') if ENV['BC2CPP_ENUMERATOR_MODEL'] == '0'

    to_enum_defs = registry['to_enum'] || []
    return Result.new(false, 'to_enum is not defined once') unless to_enum_defs.size == 1

    definition = to_enum_defs.first
    return Result.new(false, 'to_enum is not Kernel#to_enum') unless definition.owner == 'Kernel' && definition.irep

    body = ireps[definition.irep]
    return Result.new(false, 'to_enum is not from mruby-enumerator') unless body && body.file.to_s.end_with?(FILE_SUFFIX)
    return Result.new(false, 'Kernel#to_enum has an unexpected body') unless to_enum_body?(body, ireps)

    # ALIAS_SITES (ADR 0474): the registry also holds an engine-side `alias enum_for to_enum` as a definition;
    # the alias itself is judged by the site check below.
    own_alias = ->(d) { d.installer == :alias && ireps[d.site.first.first]&.file.to_s.end_with?(FILE_SUFFIX) }
    enum_for = (registry['enum_for'] || []).reject(&own_alias)
    return Result.new(false, 'enum_for is defined by a method') unless enum_for.empty?

    sites = alias_sites.select { |s| NAMES.include?(s[:new]) || NAMES.include?(s[:old]) }
    unless sites.size == 1 && sites.first.values_at(:owner, :new, :old) == %w[Kernel enum_for to_enum] &&
           ireps[sites.first[:irep]].file.to_s.end_with?(FILE_SUFFIX)
      return Result.new(false, 'to_enum/enum_for are aliased elsewhere')
    end

    # The constructor chain: Enumerator.new -> Class#new -> Enumerator#initialize.
    CONSTRUCTION_NAMES.each do |name|
      (registry[name] || []).each do |other|
        next if other.equal?(definition) || own_alias.call(other)
        next unless CONSTRUCTION_OWNERS.include?(other.owner)
        next if other.irep.nil? && other.owner == '<native>'

        file = other.irep && ireps[other.irep]&.file.to_s
        return Result.new(false, "#{other.owner}##{name} redefines the construction") unless
          file&.end_with?(FILE_SUFFIX) && other.owner == 'Enumerator' && name == 'initialize'
      end
    end
    inits = (registry['initialize'] || []).select { |d| d.owner == 'Enumerator' }
    return Result.new(false, 'Enumerator#initialize is not defined once') unless inits.size == 1

    Result.new(true, nil, false)
  end

  # `Enumerator.new self, meth, *args, **kwd` and nothing else: the default :each, one constant read (Enumerator), the
  # argument packing, and one `new` send. Any other call, block, instance variable or branch makes the model refuse.
  BODY_OPS = %w[ENTER JMP LOADSYM GETCONST LOADSELF MOVE ARRAY ARYCAT HASH HASHCAT SEND RETURN].freeze

  def to_enum_body?(body, _ireps)
    return false unless body.reps.empty? && body.instructions.all? { |i| BODY_OPS.include?(i.op) }

    sends = body.instructions.select { |i| i.op == 'SEND' }
    consts = body.instructions.select { |i| i.op == 'GETCONST' }
    syms = body.instructions.select { |i| i.op == 'LOADSYM' }
    sends.size == 1 && sends.first.sym == 'new' && consts.size == 1 && consts.first.const_name == 'Enumerator' &&
      syms.all? { |i| i.sym == 'each' }
  end

  # Does the name `Enumerator` denote one class object for the life of the VM, as seen from Kernel#to_enum's body?
  # StableClassConstants refuses it because chain.rb and lazy.rb reopen `class Enumerator`; a reopening does not rebind
  # the constant. Required instead: every CLASS/MODULE statement naming it is in mruby's own Ruby (top level there),
  # nothing assigns it, no native source defines it, and the program never calls const_set / remove_const / autoload.
  # Returns nil when stable, else the reason it is not.
  def constant_unstable_reason(ireps, root_label, native_paths, foreign_paths)
    return 'disabled' if ENV['BC2CPP_ENUMERATOR_MODEL'] == '0'
    return 'no native/foreign inputs' unless native_paths && foreign_paths

    ireps.each_value do |irep|
      irep.instructions.each do |insn|
        case insn.op
        when 'CLASS', 'MODULE'
          # The compiled sources run as one script, whose own irep holds the top-level statements. A statement there
          # reopens or creates Object::Enumerator; one in a class body, a block or a method (`module Kernel; class
          # Enumerator`) defines a second constant that Kernel#to_enum's lexical lookup would find first.
          if insn.sym_token == 'Enumerator' && irep.label != root_label
            return "a nested class/module Enumerator statement (#{irep.label})"
          end
        when 'SETCONST' then return "assigned in #{irep.file}" if insn.const_name == 'Enumerator'
        when 'SETMCNST' then return "assigned in #{irep.file}" if insn.mcnst_name == 'Enumerator'
        when 'SEND', 'SEND0', 'SSEND', 'SSEND0', 'SENDB', 'SSENDB', 'LOADSYM'
          return "dynamic constant mutation (#{insn.sym}) in #{irep.file}" if insn.sym.to_s.match?(StableClassConstants::DYNAMIC_MUTATION)
        end
      end
    end
    foreign_paths.each do |path|
      text = SourceText.read(path, 'EnumeratorModel.constant_stable?') or return "unreadable #{path}"
      return "dynamic constant mutation in #{path}" if text.match?(StableClassConstants::DYNAMIC_MUTATION)
    end
    return 'defined by a native source' if IntegerConstants.native_defined_const_names(native_paths).include?('Enumerator')
    return 'reassigned in outside Ruby' if StableClassConstants.foreign_reassigned_names(foreign_paths).include?('Enumerator')

    nil
  end

end
