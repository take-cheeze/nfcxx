# frozen_string_literal: true

require 'set'

# A Set that rejects mistyped members loudly in dev, and is just Set in
# production (zero overhead, identical semantics).
#
# The reg migration turned silent String/Integer mix-ups into the dominant
# bug class: `Set['0'].include?(0)` is false, and `{1, '1'}` dedupes to two
# entries, so a poisoned opaque set quietly disables a proof instead of
# raising. StrictKeySet raises TypeError at insertion/membership time,
# pointing at the call site that fed the wrong type.
#
# Validate at the dataflow boundary with `StrictKeySet.coerce(set)` in dev
# (guarded by STRICT_KEYS, a load-time constant, so production pays one
# constant lookup per entry point and nothing else). In production
# (`BC2CPP_STRICT_KEYS=0`) the calls are skipped entirely: no subclass,
# no method overrides, no extra objects. The generated C++ never runs
# this Ruby, so the gate only matters for bc2cpp's own dev/CI runs.
# Set literals (`Set[1, 2]`) and `Set.new` keep working unchanged.
STRICT_KEYS = ENV['BC2CPP_STRICT_KEYS'] != '0'

if STRICT_KEYS
  # Integer-element Set (opaque/upvar register sets). Every read and write
  # with a non-Integer member raises TypeError.
  #
  # This is a wrapper, not a Set subclass: mruby's Set is MRB_TT_SET, which
  # cannot hold instance variables (mrb_iv_set raises "cannot set instance
  # variable"), so `@key_type` cannot live on a Set subclass under mruby.
  # The wrapper keeps the key type in its own ivar and delegates the set
  # operations to a plain Set.
  class StrictKeySet
    include Enumerable

    # Validate +set+'s members and return it (dev) — a plain alias in
    # production, so call sites read identically in both modes.
    def self.coerce(set, key_type: Integer)
      return set if set.nil?

      set.each { |member| check!(member, key_type) }
      set
    end

    def self.check!(member, key_type)
      return if member.is_a?(key_type)

      raise TypeError, "StrictKeySet: #{member.inspect} (#{member.class}) is not a #{key_type}"
    end

    def initialize(enum = nil, key_type: Integer, &block)
      @key_type = key_type
      @set = Set.new(enum, &block)
      @set.each { |member| self.class.check!(member, @key_type) }
    end

    def each(&block)
      return enum_for(:each) unless block

      @set.each(&block)
      self
    end

    def add(member)
      mutable!
      self.class.check!(member, @key_type)
      @set.add(member)
      self
    end
    alias << add

    def add?(member)
      mutable!
      self.class.check!(member, @key_type)
      @set.add?(member) ? self : nil
    end

    def include?(member)
      self.class.check!(member, @key_type)
      @set.include?(member)
    end
    alias member? include?
    alias === include?

    def delete(member)
      mutable!
      self.class.check!(member, @key_type)
      @set.delete(member)
      self
    end

    def merge(enum)
      mutable!
      enum.each { |member| self.class.check!(member, @key_type) }
      @set.merge(enum)
      self
    end

    def |(other)
      other.each { |member| self.class.check!(member, @key_type) } if other.is_a?(Enumerable)
      StrictKeySet.new(@set | other, key_type: @key_type)
    end

    # mruby's Set#add does not raise on a frozen set (CRuby's does), so the wrapper raises for both.
    def mutable!
      raise FrozenError, "can't modify frozen StrictKeySet: #{inspect}" if frozen?
    end
    private :mutable!

    def size
      @set.size
    end
    alias length size

    def empty?
      @set.empty?
    end

    def to_a
      @set.to_a
    end

    def freeze
      @set.freeze
      self
    end

    def frozen?
      @set.frozen?
    end

    # Any other Set method (count via Enumerable aside) is forwarded to the set.
    def method_missing(name, *args, &block)
      return @set.send(name, *args, &block) if @set.respond_to?(name)

      super
    end

    def respond_to_missing?(name, include_private = false)
      @set.respond_to?(name, include_private) || super
    end
  end
else
  # Production: StrictKeySet.coerce is a no-op pass-through and .new
  # builds a plain Set, so call sites read identically in both modes.
  module StrictKeySet
    def self.coerce(set, key_type: Integer)
      set
    end

    def self.new(enum = nil, key_type: Integer, &block)
      Set.new(enum, &block)
    end
  end
end
