# Identity keys for Hash and Set. Calling compare_by_identity moves the entries into an identity store on the object
# (keyed by object_id) and extends the object with the methods below, which take precedence over the core ones.
# Before extension the object's entries are read out and cleared, so they are re-added under identity.
#
# Scope: the methods bc2cpp and the Ruby code it runs call on these collections. Methods not listed fall back to the
# core versions, which see an empty table; `dup` and `clone` do not carry the identity over.

# The identity stores, by the object_id of the collection they belong to: mruby sets cannot hold instance variables.
CompareByIdentityStores = {}

module CompareByIdentityHash
  def compare_by_identity? = true

  def __identity_store = CompareByIdentityStores[object_id]

  def []=(key, value)
    entry = __identity_store[key.object_id]
    if entry
      entry[1] = value
    else
      __identity_store[key.object_id] = [key, value]
    end
    value
  end
  alias store []=

  def [](key)
    entry = __identity_store[key.object_id]
    entry ? entry[1] : default_value_for(key)
  end

  def default_value_for(key)
    default_proc ? default_proc.call(self, key) : default
  end
  private :default_value_for

  def key?(key) = __identity_store.key?(key.object_id)
  alias has_key? key?
  alias include? key?
  alias member? key?

  def fetch(key, *fallback, &block)
    entry = __identity_store[key.object_id]
    return entry[1] if entry
    return block.call(key) if block
    return fallback[0] unless fallback.empty?

    raise KeyError, "key not found: #{key.inspect}"
  end

  def delete(key)
    entry = __identity_store.delete(key.object_id)
    entry ? entry[1] : (block_given? ? yield(key) : nil)
  end

  def each
    return to_enum(:each) unless block_given?

    __identity_store.values.each { |key, value| yield [key, value] }
    self
  end

  def each_pair(&block)
    return to_enum(:each_pair) unless block

    __identity_store.values.each { |key, value| block.arity == 1 ? block.call([key, value]) : block.call(key, value) }
    self
  end

  def each_key
    return to_enum(:each_key) unless block_given?

    __identity_store.values.each { |key, _value| yield key }
    self
  end

  def each_value
    return to_enum(:each_value) unless block_given?

    __identity_store.values.each { |_key, value| yield value }
    self
  end

  def keys = __identity_store.values.map { |key, _value| key }
  def values = __identity_store.values.map { |_key, value| value }
  def values_at(*keys) = keys.map { |key| self[key] }
  def size = __identity_store.size
  alias length size
  def empty? = __identity_store.empty?
  def to_a = __identity_store.values.map { |key, value| [key, value] }
  def clear
    __identity_store.clear
    self
  end
end

module CompareByIdentitySet
  def compare_by_identity? = true

  def __identity_store = CompareByIdentityStores[object_id]

  def add(item)
    __identity_store[item.object_id] = item
    self
  end
  alias << add

  def add?(item)
    return nil if include?(item)

    add(item)
  end

  def include?(item) = __identity_store.key?(item.object_id)
  alias member? include?
  alias === include?

  def delete(item)
    __identity_store.delete(item.object_id)
    self
  end

  def each
    __identity_store.values.each { |item| yield item }
    self
  end

  def to_a = __identity_store.values
  def size = __identity_store.size
  alias length size
  def empty? = __identity_store.empty?
  def clear
    __identity_store.clear
    self
  end
end

class Hash
  def compare_by_identity
    return self if compare_by_identity?

    entries = to_a
    clear
    CompareByIdentityStores[object_id] = {}
    extend CompareByIdentityHash
    entries.each { |key, value| self[key] = value }
    self
  end

  def compare_by_identity? = false
end

class Set
  def compare_by_identity
    return self if compare_by_identity?

    items = to_a
    clear
    CompareByIdentityStores[object_id] = {}
    extend CompareByIdentitySet
    items.each { |item| add(item) }
    self
  end

  def compare_by_identity? = false
end
