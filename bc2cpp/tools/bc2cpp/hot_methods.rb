# frozen_string_literal: true

require 'set'

# HOT_ONLY (ADR 0214): the profiled hot-method list (hot_methods.txt, one
# `Owner#name` / `Owner.singleton#name` per line). bc2cpp treats every unlisted
# method as uncompilable, so it stays bytecode and callers dispatch to it.
module HotMethods
  DEFAULT_PATH = File.expand_path('hot_methods.txt', __dir__)
  ENTRY = /\A[A-Z][\w:]*(?:\.singleton)?#\S+\z/

  module_function

  # The listed "Owner#name" keys. Raises on a line that is not one entry, so a
  # typo fails the build instead of silently excluding a hot method.
  def load(path)
    File.readlines(path, chomp: true).each_with_index.with_object(Set.new) do |(line, i), set|
      entry = line.strip
      next if entry.empty? || entry.start_with?('#')

      entry = entry.split(/\s+#/, 2).first
      raise ArgumentError, "#{path}:#{i + 1}: not an Owner#name entry: #{line.inspect}" unless entry.match?(ENTRY)

      set << entry
    end
  end

  def key(method_def)
    "#{method_def.owner}##{method_def.name}"
  end

  # Irep labels of every bytecode method (MethodDef with an irep) `hot` does not
  # list. Native and attr_* MethodDefs have no bytecode and never compile.
  def excluded_labels(registry, hot)
    defs = registry.values.flatten
    copied_hot_ireps = defs.each_with_object(Set.new) do |d, out|
      out << d.copy_irep if d.kind == :module_function && d.copy_irep && hot.include?(key(d))
    end
    defs.each_with_object(Set.new) do |d, out|
      out << d.irep if d.irep && !hot.include?(key(d)) && !copied_hot_ireps.include?(d.irep)
    end
  end

  # Listed entries no bytecode method in the closed world answers to (renamed or
  # deleted since the profile was taken).
  def stale(registry, hot)
    defs = registry.values.flatten
    known = defs.select(&:irep).to_set { |d| key(d) }
    defs.each do |d|
      known << key(d) if d.kind == :module_function && d.copy_irep
    end
    hot.reject { |k| known.include?(k) }.sort
  end
end
