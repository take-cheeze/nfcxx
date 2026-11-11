class Dir
  def self.glob(pattern, *_flags)
    patterns = pattern.is_a?(Array) ? pattern : [pattern]
    patterns.flat_map do |one|
      DirGlob.expand_braces(one).flat_map { |expanded| DirGlob.matches(expanded) }
    end
  end

  def self.[](*patterns)
    glob(patterns.flatten)
  end
end

module DirGlob
  MAGIC = ['*', '?'].freeze

  # The patterns that `{a,b}` alternatives stand for: one per combination, in the order written.
  def self.expand_braces(pattern)
    open = pattern.index('{')
    return [pattern] unless open

    close = pattern.index('}', open)
    return [pattern] unless close

    head = pattern[0...open]
    tail = pattern[(close + 1)..-1]
    pattern[(open + 1)...close].split(',', -1).flat_map { |alt| expand_braces(head + alt + tail) }
  end

  def self.magic?(segment)
    MAGIC.any? { |char| segment.include?(char) }
  end

  # The paths matching one brace-free pattern.
  def self.matches(pattern)
    absolute = pattern.start_with?('/')
    segments = pattern.split('/').reject(&:empty?)
    base = absolute ? '/' : ''
    out = []
    walk(base, segments, out)
    out
  end

  def self.join(base, name)
    return name if base.empty?
    return "#{base}#{name}" if base.end_with?('/')

    "#{base}/#{name}"
  end

  def self.list(base)
    entries = Dir.entries(base.empty? ? '.' : base).reject { |name| name == '.' || name == '..' }
    entries.sort
  end

  def self.walk(base, segments, out)
    if segments.empty?
      out << base unless base.empty?
      return
    end

    segment = segments.first
    rest = segments[1..-1]
    if segment == '**'
      walk(base, rest, out)
      list(base).each do |name|
        child = join(base, name)
        walk(child, segments, out) if !name.start_with?('.') && File.directory?(child)
      end
    elsif magic?(segment)
      list(base).each do |name|
        next if name.start_with?('.') && !segment.start_with?('.')
        next unless match?(segment, name)

        walk(join(base, name), rest, out)
      end
    else
      path = join(base, segment)
      walk(path, rest, out) if File.exist?(path)
    end
  end

  # Whether `name` matches the wildcard `pattern` (`*` any run, `?` any one character).
  def self.match?(pattern, name, pi = 0, ni = 0)
    while pi < pattern.size
      char = pattern[pi]
      if char == '*'
        return true if pi + 1 == pattern.size

        (ni..name.size).each { |skip| return true if match?(pattern, name, pi + 1, skip) }
        return false
      end
      return false if ni >= name.size
      return false unless char == '?' || char == name[ni]

      pi += 1
      ni += 1
    end
    ni == name.size
  end
end
