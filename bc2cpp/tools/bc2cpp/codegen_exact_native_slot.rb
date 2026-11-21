# frozen_string_literal: true

require 'set'
require_relative 'outside_ruby_owners'

# EXACT_NATIVE_SLOT: an explicit-receiver send whose receiver the class flow proves exactly one class, whose name
# NAME_OWNER_SET names (so the owner call would be its dispatch) and whose lookup on that class reaches no Ruby
# definition, calls the method through the per-method-id slot of symbol_cache.rb's NATIVE_SLOT instead of the owner
# call. The slot looks the method up on the receiver's own class and keeps it while mruby's method cache agrees, so
# the proof only decides where it pays: a receiver of another class, a Ruby method or a private one takes the checked
# by-name send. BC2CPP_EXACT_NATIVE_SLOT=0 keeps the owner calls.
module ExactNativeSlot
  CORE_CLASS_OF = { 'INT' => 'Integer', 'FLT' => 'Float', 'ARR' => 'Array', 'HSH' => 'Hash', 'STR' => 'String',
                    'RNG' => 'Range' }.freeze
  # Classes whose instances a slot could not hand to their method as dispatch does (Proc#call is a yield).
  EXCLUDED = %w[Proc NilClass].freeze

  def compile_send(insn, kwargs)
    saved = @exact_native_slot_site
    @exact_native_slot_site = exact_native_slot_site(insn, kwargs)
    super
  ensure
    @exact_native_slot_site = saved
  end

  # FLOW_CORE_DIRECT's last resort: an exact core receiver whose name program classes also define would get a guard
  # chain over them, all dead for this receiver; the slot needs none. A program or RGSS class keeps its own native
  # paths (NATIVE_EXACT_DIRECT's entries call no lookup at all).
  def flow_core_direct_line(d, recv, name, argv)
    line = super
    return line if line

    site = @exact_native_slot_site
    site && CORE_CLASS_OF.value?(site[2]) ? exact_native_slot_line(d, recv, name, argv) : nil
  end

  # Every owner call over a name owner set is built here: a bare send's, a chain's else, a lifted nomethod's.
  def outside_owner_call_line(d, recv, name, argv, owners)
    exact_native_slot_line(d, recv, name, argv)&.chomp || super
  end

  private

  def exact_native_slot_enabled?
    ENV['BC2CPP_EXACT_NATIVE_SLOT'] != '0'
  end

  # [receiver text, name, class] of the send being compiled, or nil.
  def exact_native_slot_site(insn, kwargs)
    return nil unless exact_native_slot_enabled? && @closed_world&.exact_instances_singleton_free?
    return nil if kwargs[:self_implicit] || kwargs[:call_receiver] || insn.positional_splat? || insn.keyword_arguments?

    irep = kwargs[:irep]
    site = kwargs[:idx] || kwargs[:trace_idx]
    return nil unless irep && site

    reg = unshift_proof_reg(kwargs[:trace_receiver_reg] || insn.reg, kwargs[:trace_reg_offset] || 0)
    mask = reg && exact_flow_mask(irep, site, reg)
    return nil unless mask.is_a?(Integer) && mask.positive?

    mask = exact_flow_strip_nil(irep, site, reg.to_i, mask)
    return nil unless (mask & (NumericFlow::NIL | NumericFlow::OTHER | NumericFlow::CHECKED)).zero?

    classes = class_mask_classes(mask)
    return nil unless classes.size == 1 && classes.first != 'NONE'

    klass = CORE_CLASS_OF.fetch(classes.first, classes.first)
    return nil unless klass.match?(OutsideOwnerCall::OWNER_PATH) && !klass.end_with?('.singleton') && !EXCLUDED.include?(klass)

    [RegName[insn.reg], insn.sym.to_s, klass]
  end

  def exact_native_slot_line(d, recv, name, argv)
    site = @exact_native_slot_site
    return nil unless site && site[0] == recv && site[1] == name && !@call_block_expr
    return nil unless argv.size <= CodeGen::FUNCALL_ARGC_MAX && name_owner_set(name)
    return nil unless exact_native_slot_proven?(site[2], name)
    # OWNER_SET_DIRECT computes the owner call in place, or puts an audited inline arm for this class in front of it.
    return nil if OwnerSetDirect::OWNER_SET_ROWS.key?(name) && ENV['BC2CPP_OWNER_SET_DIRECT'] != '0'
    return nil if owner_set_arm_entries(name, argv.size).any? { |entry| entry.owner == site[2] }

    args = argv.map { |arg| ", #{arg}" }.join
    "r#{d} = bc2cpp_native_slot_named(M, #{recv}, \"#{name}\", #{argv.size}#{args}); " \
      "/* EXACT_NATIVE_SLOT: #{site[2]}##{name}, a C function on the receiver's one class */\n"
  end

  # The lookup of `name` on an exact `klass` finds no Ruby definition: none in the registry on its path, no compiled
  # core one, and no outside Ruby one on the class, its superclass chain or a module. Visibility must not change at run
  # time, nor the name be installed dynamically.
  def exact_native_slot_proven?(klass, name)
    @exact_native_slot_proven ||= {}
    key = [klass, name]
    return @exact_native_slot_proven[key] if @exact_native_slot_proven.key?(key)

    @exact_native_slot_proven[key] = exact_native_slot_decide(klass, name)
  end

  def exact_native_slot_decide(klass, name)
    return false if devirt_blocked_name?(name) || !@native_name_sources&.key?(name)
    return false unless @closed_world.visibility_stable?(name)

    installed = symbol_installed_names
    return false if installed.nil? || installed.include?(name)

    target, known = closed_world_lookup_target(name, klass, Set.new, any_visibility: true)
    return false unless known && (target.nil? || target.owner == '<native>')

    chain = exact_native_slot_chain(klass)
    return false unless chain
    return false if (self.class.core_hidden_defs || []).any? { |definition| definition.name == name && chain.include?(definition.owner) }

    outside = OutsideRubyOwners.scan(Array(@closed_world.ruby_paths))
    return false if outside.unknown.include?(:all) || outside.unknown.include?(name) || !outside.wild.empty?

    outside.names.fetch(name, Set.new).none? { |owner| chain.include?(owner) || !@superclass_of.key?(owner) }
  end

  # The class, its known superclasses, and the modules every object has; nil when a link is not known.
  def exact_native_slot_chain(klass)
    chain = []
    owner = klass
    while owner
      return nil if chain.include?(owner) || @unknown_mixins.include?(owner) || !Array(@prepended_modules[owner]).empty?

      chain << owner
      chain.concat(Array(@included_modules[owner]))
      owner = case owner
              when 'BasicObject' then nil
              when 'Object' then 'BasicObject'
              else @superclass_of[owner].is_a?(String) ? @superclass_of[owner] : 'Object'
              end
    end
    chain | %w[Object Kernel BasicObject]
  end
end

CodeGen.prepend(ExactNativeSlot)
