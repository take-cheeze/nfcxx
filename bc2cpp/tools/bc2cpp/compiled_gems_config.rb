# frozen_string_literal: true

require 'yaml'

# COMPILED_GEMS_CONFIG: reads and validates tools/bc2cpp/compiled_gems.yml, the per-gem table behind
# BC2CPP_COMPILED_GEMS (compiled_gems.rb turns it into owners). Dependency-free beyond YAML, so build_config.rb (mruby's
# rake), the tools and the check script load it the same way. Every problem raises: a typo in the file must stop the
# build, not leave a gem quietly without owners or sharing an OUT_SYMBOL.
module Bc2cppCompiledGemsConfig
  PATH = File.expand_path('compiled_gems.yml', __dir__).freeze
  Entry = Struct.new(:name, :owners_from, :out_symbol, :native_namespaces, keyword_init: true)
  Error = Class.new(StandardError)

  TOP_KEYS = %w[version gems].freeze
  GEM_KEYS = %w[owners_from out_symbol native_namespaces].freeze
  REQUIRED_GEM_KEYS = %w[owners_from out_symbol].freeze
  CORE = 'core'
  GEM_NAME = /\Amruby-[a-z0-9]+(?:-[a-z0-9]+)*-compiled\z/
  BASE_GEM = /\Amruby-[a-z0-9]+(?:-[a-z0-9]+)*\z/
  SYMBOL = /\A[a-z_][a-z0-9_]*\z/
  NAMESPACE = /\A[A-Z]\w*(?:::[A-Z]\w*)*\z/

  module_function

  # Returns [Entry] in file order. `gems_root`: when given, a base gem named by owners_from must exist under it.
  def load(path = PATH, gems_root: nil)
    raise Error, "#{path}: no such file" unless File.file?(path)

    fail_dup_keys!(path, Psych.parse_file(path))
    data = YAML.safe_load_file(path)
    validate(data, path, gems_root)
  rescue Psych::Exception => e
    raise Error, "#{path}: #{e.message}"
  end

  # Psych keeps the last of two equal keys, which would silently drop a gem entry.
  def fail_dup_keys!(path, node)
    if node.is_a?(Psych::Nodes::Mapping)
      keys = node.children.each_slice(2).map { |k, _| k.respond_to?(:value) ? k.value : nil }.compact
      dup = keys.find { |k| keys.count(k) > 1 }
      raise Error, "#{path}: duplicate key #{dup.inspect}" if dup
    end
    node.children&.each { |c| fail_dup_keys!(path, c) }
  end

  def validate(data, path, gems_root)
    raise Error, "#{path}: top level must be a mapping" unless data.is_a?(Hash)

    extra = data.keys - TOP_KEYS
    raise Error, "#{path}: unknown top-level keys #{extra.inspect}" unless extra.empty?
    raise Error, "#{path}: version must be 1" unless data['version'] == 1

    gems = data['gems']
    raise Error, "#{path}: gems must be a non-empty mapping" unless gems.is_a?(Hash) && !gems.empty?

    entries = gems.map { |name, spec| entry(path, name, spec, gems_root) }
    symbols = entries.map(&:out_symbol)
    dup = symbols.find { |s| symbols.count(s) > 1 }
    raise Error, "#{path}: duplicate out_symbol #{dup.inspect}" if dup

    entries
  end

  def entry(path, name, spec, gems_root)
    where = "#{path}: #{name.inspect}"
    raise Error, "#{where}: gem name must match #{GEM_NAME.inspect}" unless name.is_a?(String) && name.match?(GEM_NAME)
    raise Error, "#{where}: must be a mapping" unless spec.is_a?(Hash)

    extra = spec.keys - GEM_KEYS
    raise Error, "#{where}: unknown keys #{extra.inspect} (allowed: #{GEM_KEYS.join(', ')})" unless extra.empty?

    missing = REQUIRED_GEM_KEYS - spec.keys
    raise Error, "#{where}: missing #{missing.join(', ')}" unless missing.empty?

    from = spec['owners_from']
    unless from == CORE || (from.is_a?(String) && from.match?(BASE_GEM))
      raise Error, "#{where}: owners_from must be `#{CORE}` or a base gem name (mruby-...), got #{from.inspect}"
    end
    if from != CORE && gems_root && !File.directory?(File.join(gems_root, from))
      raise Error, "#{where}: owners_from #{from.inspect} is not a gem directory under #{gems_root}"
    end

    symbol = spec['out_symbol']
    raise Error, "#{where}: out_symbol must match #{SYMBOL.inspect}, got #{symbol.inspect}" unless symbol.is_a?(String) && symbol.match?(SYMBOL)

    Entry.new(name: name, owners_from: from, out_symbol: symbol, native_namespaces: namespaces(where, spec['native_namespaces']))
  end

  def namespaces(where, list)
    return nil if list.nil?

    ok = list.is_a?(Array) && !list.empty? && list.all? { |n| n.is_a?(String) && n.match?(NAMESPACE) } && list.uniq.size == list.size
    raise Error, "#{where}: native_namespaces must be a non-empty list of distinct constant names, got #{list.inspect}" unless ok

    list
  end
end
