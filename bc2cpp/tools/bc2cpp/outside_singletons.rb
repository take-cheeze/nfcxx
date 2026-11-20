# frozen_string_literal: true

require 'prism'
require_relative 'ruby_parse_cache'

# INSTANCE_SINGLETON_TAINT, outside Ruby: where an outside Ruby source gives an object a singleton class, read from its
# syntax tree rather than from its text (so a Symbol `:extend` that is only data, or "extend" in a string or a comment,
# is no maker).
#
# `maker` is the whole-world flag ClosedWorld#exact_instances_singleton_free? reads: the source names a
# singleton-making method or opens a singleton class anywhere, on a class object or not.
#
# `taint` places each maker. A maker whose `self` is a class or module object (a class or module body, `def self.x`,
# `class << self` at body level) gives no instance a singleton class and is left out. One whose `self` is an instance
# of a class (an instance method of `class X`, without a block in between) taints X, which ClosedWorld
# reads as X and its subclasses, with what that singleton may answer: the methods of the modules an `extend Const`
# names, the name of a `define_singleton_method(:x)` or `def self.x`, or :any. Anything else (another receiver, a
# module's instance method, a block, the main object, a computed name) cannot be placed, and `taint` is nil: every
# instance may then have a singleton class.
module OutsideSingletons
  # ClosedWorld::SINGLETON_MAKERS plus `extend` (repeated here: closed_world.rb requires this file).
  MAKERS = %w[singleton_class define_singleton_method instance_eval instance_exec].freeze
  EXTEND = 'extend'
  # Sends that call a method named by a value: with one in the file, a maker name as a Symbol or String may be sent.
  DYNAMIC_SENDS = %w[send __send__ public_send method public_method instance_method].freeze
  MIXINS = %w[include prepend].freeze
  # A module's own hooks that run on the extended object.
  EXTEND_HOOKS = %w[extended extend_object].freeze
  ANONYMOUS_CLASS_MAKERS = %w[Module Class Struct].freeze

  module_function

  # { maker:, taint: [[class path, :any | [names], [module refs]]] or nil, modules: { path => [names] },
  #   open_modules: [paths] } for one outside Ruby source. nil when it does not parse.
  def scan(path)
    parsed = RubyParseCache.parse_file(path)
    return nil unless parsed.errors.empty?

    collector = Collector.new
    collector.visit(parsed.value)
    collector.facts
  end

  # One lexical scope. kind: :class, :module, :sclass, :def, :block, :anonymous (a Module.new block). path: a class or
  # module body's full path. For
  # :def, receiver is nil, :self, or :other.
  Frame = Struct.new(:kind, :path, :receiver)

  class Collector < Prism::Visitor
    def initialize
      super
      @stack = []
      @maker = false
      @unplaced = false
      @taint = []
      @data_names = []
      @dynamic_send = false
      # Module path => the instance method names its bodies define; open modules may answer more (a mixin, a hook).
      @modules = Hash.new { |h, k| h[k] = [] }
      @open_modules = []
      # The blocks of `Module.new`/`Class.new`/`Struct.new`, whose self is the new class or module.
      @anonymous_bodies = []
    end

    def facts
      # A maker name held as data is a maker once something in the file can send a name.
      if @dynamic_send && !@data_names.empty?
        @maker = true
        @unplaced = true
      end
      { maker: @maker, taint: @unplaced ? nil : @taint.uniq, modules: @modules.transform_values(&:uniq),
        open_modules: @open_modules.uniq }
    end

    def visit_class_node(node)
      scoped(Frame.new(:class, nested(node.constant_path), nil)) { super }
    end

    def visit_module_node(node)
      scoped(Frame.new(:module, nested(node.constant_path), nil)) { super }
    end

    def visit_singleton_class_node(node)
      @maker = true
      if node.expression.is_a?(Prism::SelfNode)
        place(:any)
        # A hook a module defines on itself runs on whatever extends it.
        frame = @stack.last
        @open_modules << frame.path if frame&.kind == :module
      else
        @unplaced = true
      end
      scoped(Frame.new(:sclass, nil, nil)) { super }
    end

    def visit_def_node(node)
      receiver = node.receiver
      kind = if receiver.nil? then nil
             elsif receiver.is_a?(Prism::SelfNode) then :self
             else :other
             end
      frame = lexical_owner
      if kind.nil? && frame&.kind == :module
        @modules[frame.path] << node.name.to_s
      elsif kind == :self && frame&.kind == :module && EXTEND_HOOKS.include?(node.name.to_s)
        @open_modules << frame.path
      end
      case kind
      when :self then place([node.name.to_s])
      when :other
        # `def Const.x` is the old text scan's blind spot too (it spelled only a lowercase receiver); its owner is
        # still not placed.
        @maker = true unless constant?(receiver)
        @unplaced = true
      end
      scoped(Frame.new(:def, nil, kind)) { super }
    end

    def visit_alias_method_node(node)
      frame = lexical_owner
      name = node.new_name
      @modules[frame.path] << name.unescaped.to_s if frame&.kind == :module && name.respond_to?(:unescaped)
      super
    end

    def visit_block_node(node)
      kind = @anonymous_bodies.any? { |body| body.equal?(node) } ? :anonymous : :block
      scoped(Frame.new(kind, nil, nil)) { super }
    end

    def visit_lambda_node(node)
      scoped(Frame.new(:block, nil, nil)) { super }
    end

    def visit_symbol_node(node)
      name = node.unescaped.to_s
      if MAKERS.include?(name)
        # As ClosedWorld#scan_singleton_maker reads a Symbol of a maker name in bytecode.
        @maker = true
        @unplaced = true
      elsif name == EXTEND
        @data_names << name
      end
      super
    end

    def visit_string_node(node)
      name = node.unescaped.to_s
      @data_names << name if MAKERS.include?(name) || name == EXTEND
      super
    end

    def visit_block_argument_node(node)
      # `&:extend` sends the name to every element.
      expr = node.expression
      if expr.is_a?(Prism::SymbolNode) && (MAKERS + [EXTEND]).include?(expr.unescaped.to_s)
        @maker = true
        @unplaced = true
      end
      super
    end

    def visit_call_node(node)
      name = node.name.to_s
      @dynamic_send = true if DYNAMIC_SENDS.include?(name)
      frame = lexical_owner
      if frame&.kind == :module && node.receiver.nil?
        if MIXINS.include?(name)
          @open_modules << frame.path
        elsif %w[define_method alias_method attr_reader attr_writer attr_accessor attr module_function].include?(name)
          # Names a module body defines another way; OutsideRubyOwners reads them, this keeps the gain unbounded.
          @open_modules << frame.path
        end
      end
      call_maker(node, name) if MAKERS.include?(name) || name == EXTEND
      @anonymous_bodies << node.block if anonymous_class_body?(node, name)
      super
    end

    private

    def call_maker(node, name)
      @maker = true
      receiver = node.receiver
      unless receiver.nil? || receiver.is_a?(Prism::SelfNode)
        @unplaced = true
        return
      end
      place(gain(node, name))
    end

    # What a singleton class made by this call may answer: :any, [names], or [:modules, refs].
    def gain(node, name)
      args = node.arguments&.arguments || []
      case name
      when EXTEND
        return :any if args.empty? || node.block || !args.all? { |arg| constant?(arg) }

        [:modules, args.map { |arg| arg.slice.delete_prefix('::') }]
      when 'define_singleton_method'
        first = args.first
        literal = first.is_a?(Prism::SymbolNode) || first.is_a?(Prism::StringNode)
        literal ? [first.unescaped.to_s] : :any
      else :any
      end
    end

    # Records a singleton class on `self` here: nothing for a class or module object, the class for an instance of one.
    def place(gain)
      target = self_target
      return if target == :class_object

      @maker = true
      if target.nil?
        @unplaced = true
        return
      end
      if gain.is_a?(Array) && gain.first == :modules
        @taint << [target, nil, gain.last]
      else
        @taint << [target, gain == :any ? :any : gain, []]
      end
    end

    # :class_object, a class path (self is an instance of it), or nil (not placed).
    def self_target
      frame = @stack.last
      return nil if frame.nil? || frame.kind == :block
      return :class_object if %i[class module sclass anonymous].include?(frame.kind)

      # A def: what it is defined on.
      outer = @stack[-2]
      case frame.receiver
      when :self
        outer && %i[class module sclass anonymous].include?(outer.kind) ? :class_object : nil
      when nil
        case outer&.kind
        when :class then outer.path
        when :sclass then :class_object
        end
      end
    end

    # The frame whose class or module a `def`, `alias` or definer call here defines on: the nearest one that is not a
    # plain block (a block keeps its definition target, an `instance_eval` aside, which is a maker of its own).
    def lexical_owner
      @stack.reverse.find { |frame| frame.kind != :block }
    end

    # `Module.new { ... }` (or Class, Struct): the block runs with the new class or module as self.
    def anonymous_class_body?(node, name)
      receiver = node.receiver
      name == 'new' && node.block.is_a?(Prism::BlockNode) && receiver.is_a?(Prism::ConstantReadNode) &&
        ANONYMOUS_CLASS_MAKERS.include?(receiver.name.to_s)
    end

    def constant?(node)
      node.is_a?(Prism::ConstantReadNode) || node.is_a?(Prism::ConstantPathNode)
    end

    def scoped(frame)
      @stack.push(frame)
      yield
    ensure
      @stack.pop
    end

    # The full path of a class or module body, as OutsideRubyOwners spells it.
    def nested(path_node)
      text = path_node.slice
      return text.delete_prefix('::') if text.start_with?('::')

      outer = @stack.reverse.find { |frame| %i[class module].include?(frame.kind) }
      outer&.path ? "#{outer.path}::#{text}" : text
    end
  end
end
