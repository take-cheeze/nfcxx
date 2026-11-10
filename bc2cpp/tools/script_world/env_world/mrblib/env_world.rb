class ENVClass
  def fetch(name, *default)
    value = self[name]
    return value unless value.nil?
    return yield(name) if block_given?
    return default[0] unless default.empty?
    raise KeyError, "key not found: #{name}"
  end

  def key?(name)
    !self[name].nil?
  end

  def has_key?(name)
    key?(name)
  end

  def to_h
    h = {}
    __environ_pairs.each do |pair|
      i = pair.index("=")
      h[pair[0, i]] = pair[(i + 1)..-1] if i
    end
    h
  end

  def keys
    to_h.keys
  end
end

ENV = ENVClass.new
