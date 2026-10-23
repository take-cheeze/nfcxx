# frozen_string_literal: true

require 'set'

module RbsSignatures
  # One settled signature/hierarchy world; inferred arguments and query state stay per method.
  class IrContracts
    EMPTY = {}.freeze
    attr_reader :applied, :named_returns, :core_redefined

    # subclasses: ClosedWorld#known_subclasses (nil when the receiver set is open); method_missing_classes: the
    # classes whose dispatch may reach a method_missing; core_redefined: ClosedWorld#program_may_define? (nil: a core
    # root is never typed).
    def initialize(applied, superclass_of:, included_modules:, prepended_modules:, unknown_mixins:, subclasses: nil,
                   method_missing_classes: Set.new, core_redefined: nil)
      @applied = applied
      @subclasses = subclasses
      @core_redefined = core_redefined
      @method_missing_classes = method_missing_classes.to_set.freeze
      @superclass_of = superclass_of.transform_values { |parent| parent.is_a?(String) ? parent.dup.freeze : parent }.freeze
      @included_modules = included_modules.transform_values { |owners| Array(owners).map { |owner| owner.dup.freeze }.freeze }.freeze
      @prepended_modules = prepended_modules.transform_values { |owners| Array(owners).map { |owner| owner.dup.freeze }.freeze }.freeze
      @unknown_mixins = unknown_mixins.dup.freeze
      @methods = applied.ir_methods.map { |owner, name| [owner.dup.freeze, name.dup.freeze].freeze }.to_set.freeze
      @named_returns = applied.ir_named_returns.to_h do |(owner, name), types|
        [[owner.dup.freeze, name.dup.freeze].freeze, types == :self ? types : types.dup.freeze]
      end.freeze
      ivars = Hash.new { |hash, owner| hash[owner] = {} }
      elements = Hash.new { |hash, owner| hash[owner] = {} }
      applied.ir_ivar_types.each do |(owner, name), types|
        ivars[owner][name] = types.dup.freeze
        bound = applied.ir_ivar_elements[[owner, name]]
        elements[owner][name] = bound&.dup&.freeze
      end
      @ivars = ivars.transform_values(&:freeze).freeze
      @elements = elements.transform_values(&:freeze).freeze
      @owners = {}
      @inherited_ivars = {}
      @inherited_elements = {}
      @targets = Hash.new { |hash, owner| hash[owner] = {} }
      @receivers = {}
    end

    # SELF_RECEIVERS: memoized RbsSignatures.self_receivers for the owner's implicit-self sends.
    def receivers(owner)
      return @receivers[owner] if @receivers.key?(owner)

      @receivers[owner] = RbsSignatures.self_receivers(owner, lookup: ->(klass) { owners(klass) }, subclasses: @subclasses,
                                                               method_missing_classes: @method_missing_classes)
    end

    def owners(owner)
      @owners[owner] ||= RbsSignatures.contract_owners(owner, @superclass_of, included_modules: @included_modules,
                                                    prepended_modules: @prepended_modules, unknown_mixins: @unknown_mixins).map { |name| name.dup.freeze }.freeze
    end

    def ivars(owner)
      @inherited_ivars[owner] ||= owners(owner).reverse_each.each_with_object({}) { |ancestor, out| out.merge!(@ivars.fetch(ancestor, EMPTY)) }.freeze
    end

    def elements(owner)
      @inherited_elements[owner] ||= owners(owner).reverse_each.each_with_object({}) do |ancestor, out|
        @elements.fetch(ancestor, EMPTY).each do |name, bound|
          # Scalar declarations withdraw inherited bounds; replacements retain lookup order.
          out.delete(name)
          out[name] = bound if bound
        end
      end.freeze
    end

    def target(owner, name)
      targets = @targets[owner]
      return targets[name] if targets.key?(name)

      targets[name] = owners(owner).find { |candidate| @methods.include?([candidate, name]) }
    end
  end
end
