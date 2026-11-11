# ENV: the process environment as a Hash-like object. Values are Strings or nil; writes go to the process, so a child
# process sees them. The methods are the ones the tools call; a key is a String.
class ENVClass
  include Enumerable

  def [](name)
    BC2CPPEnv.get(name.to_s)
  end

  def fetch(name, *default)
    value = BC2CPPEnv.get(name.to_s)
    return value unless value.nil?
    return yield(name) if block_given?
    return default[0] unless default.empty?

    raise KeyError, "key not found: #{name}"
  end

  def []=(name, value)
    BC2CPPEnv.set(name.to_s, value.nil? ? nil : value.to_s)
    value
  end

  def key?(name)
    !BC2CPPEnv.get(name.to_s).nil?
  end
  alias has_key? key?
  alias include? key?

  def delete(name)
    value = BC2CPPEnv.get(name.to_s)
    BC2CPPEnv.set(name.to_s, nil)
    value
  end

  def to_h
    h = {}
    BC2CPPEnv.pairs.each { |k, v| h[k] = v }
    h
  end

  def each(&block)
    return to_enum(:each) unless block

    BC2CPPEnv.pairs.each { |k, v| block.call([k, v]) }
    self
  end

  def keys
    BC2CPPEnv.pairs.map { |k, _| k }
  end

  def values
    BC2CPPEnv.pairs.map { |_, v| v }
  end

  def reject(&block)
    to_h.reject(&block)
  end

  def select(&block)
    to_h.select(&block)
  end

  def to_s
    'ENV'
  end
end

ENV = ENVClass.new unless defined?(ENV)
