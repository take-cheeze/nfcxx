# frozen_string_literal: true

# A Hash that rejects mistyped keys loudly in dev, and is just Hash in
# production (zero overhead, identical semantics).
#
# Opcode tables (SCHEMAS, LITERAL_TYPES, ...) are keyed by Symbol since the
# opcode interning; a String key (a leftover from before the migration, or a
# `.to_s`'d op) looks up as a miss and returns nil, which the caller then
# treats as "unknown op" far from the mistake. StrictKeyHash raises TypeError
# at the lookup instead, pointing at the call site that fed the wrong type.
#
# Production (`BC2CPP_STRICT_KEYS=0`) aliases StrictKeyHash to Hash: no
# subclass, no method overrides, no cost. The constructor takes no arguments
# so `StrictKeyHash.new.merge!(literal)` builds the table identically in both
# modes. The generated C++ never runs this Ruby, so the gate only matters
# for bc2cpp's own dev/CI runs.
if ENV['BC2CPP_STRICT_KEYS'] == '0'
  StrictKeyHash = Hash
else
  # Opcode-keyed Hash: every read and write with a non-Symbol key raises
  # TypeError. Index tables keyed by Integer register/pool numbers use
  # StrictIntHash below.
  class StrictKeyHash < Hash
    def [](key)
      check_key!(key)
      super
    end

    def fetch(key, *args, &block)
      check_key!(key)
      super
    end

    def key?(key)
      check_key!(key)
      super
    end
    alias has_key? key?
    alias include? key?
    alias member? key?

    def []=(key, value)
      check_key!(key)
      super
    end

    def fetch_values(*keys)
      keys.each { |key| check_key!(key) }
      super
    end

    private

    def check_key!(key)
      return if key.is_a?(Symbol)

      raise TypeError, "StrictKeyHash: #{key.inspect} (#{key.class}) is not a Symbol"
    end
  end

  # Integer-keyed Hash: every read and write with a non-Integer key raises
  # TypeError. For tables indexed by number (pool slots, register files).
  class StrictIntHash < Hash
    def [](key)
      check_key!(key)
      super
    end

    def fetch(key, *args, &block)
      check_key!(key)
      super
    end

    def key?(key)
      check_key!(key)
      super
    end
    alias has_key? key?
    alias include? key?
    alias member? key?

    def []=(key, value)
      check_key!(key)
      super
    end

    def fetch_values(*keys)
      keys.each { |key| check_key!(key) }
      super
    end

    private

    def check_key!(key)
      return if key.is_a?(Integer)

      raise TypeError, "StrictIntHash: #{key.inspect} (#{key.class}) is not an Integer"
    end
  end
end
# Production aliases both names to Hash so `StrictIntHash.new.merge!(...)`
# builds the table identically in both modes.
StrictIntHash = Hash if ENV['BC2CPP_STRICT_KEYS'] == '0'
