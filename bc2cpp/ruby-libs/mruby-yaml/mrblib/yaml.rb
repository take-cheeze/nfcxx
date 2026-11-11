module YAML
  class SyntaxError < StandardError; end

  def self.safe_load_file(path, **_options)
    safe_load(File.read(path))
  end

  def self.safe_load(text, **_options)
    entries = []
    text.lines.each_with_index do |line, number|
      raw = line.chomp
      raise SyntaxError, "line #{number + 1}: tab indentation is not supported" if raw.lstrip.start_with?("\t") || raw.start_with?("\t")

      indent = raw.size - raw.lstrip.size
      content = strip_comment(raw.lstrip).rstrip
      next if content.empty?

      entries << [indent, content, number + 1]
    end
    return nil if entries.empty?

    parser = Parser.new(entries)
    value = parser.node(entries[0][0])
    raise SyntaxError, "line #{parser.line}: unexpected content" unless parser.done?

    value
  end

  # The text before a comment: a `#` that starts a word outside quotes.
  def self.strip_comment(text)
    quote = nil
    text.size.times do |i|
      char = text[i]
      if quote
        quote = nil if char == quote
      elsif char == '"' || char == "'"
        quote = char
      elsif char == '#' && (i == 0 || text[i - 1] == ' ')
        return text[0...i]
      end
    end
    text
  end

  # One document, read line by line: `node` reads the value that starts at the current line, at the given indent.
  class Parser
    def initialize(entries)
      @entries = entries
      @at = 0
    end

    def done? = @at >= @entries.size

    def line = @entries[[@at, @entries.size - 1].min][2]

    def node(indent)
      raise SyntaxError, "line #{line}: missing value" if done?

      ind, text, _number = @entries[@at]
      raise SyntaxError, "line #{line}: indentation #{ind} is less than #{indent}" if ind < indent
      return sequence(ind) if sequence_item?(text)
      return mapping(ind) if key_split(text)

      @at += 1
      scalar(text)
    end

    def sequence_item?(text) = text == '-' || text.start_with?('- ')

    def sequence(indent)
      list = []
      while !done? && @entries[@at][0] == indent && sequence_item?(@entries[@at][1])
        text = @entries[@at][1]
        rest = text == '-' ? '' : text[2..-1].strip
        raise SyntaxError, "line #{line}: a mapping inside a sequence item is not supported" if !rest.empty? && key_split(rest)

        @at += 1
        if rest.empty?
          list << (!done? && @entries[@at][0] > indent ? node(@entries[@at][0]) : nil)
        else
          list << scalar(rest)
        end
      end
      list
    end

    def mapping(indent)
      hash = {}
      while !done? && @entries[@at][0] == indent && !sequence_item?(@entries[@at][1])
        key, rest = key_split(@entries[@at][1])
        raise SyntaxError, "line #{line}: expected `key: value`" unless key
        raise SyntaxError, "line #{line}: duplicate key #{key.inspect}" if hash.key?(key)

        @at += 1
        if !rest.empty?
          hash[key] = scalar(rest)
        elsif !done? && (@entries[@at][0] > indent || (@entries[@at][0] == indent && sequence_item?(@entries[@at][1])))
          hash[key] = node(@entries[@at][0])
        else
          hash[key] = nil
        end
      end
      hash
    end

    # [key, rest] for `key: rest` (rest may be empty), or nil when the text is not a mapping entry.
    def key_split(text)
      colon = text.index(':')
      colon = text.index(':', colon + 1) while colon && colon + 1 < text.size && text[colon + 1] != ' '
      return nil unless colon && (colon + 1 == text.size || text[colon + 1] == ' ')

      key = unquote(text[0...colon].strip)
      [key, text[(colon + 1)..-1].strip]
    end

    def unquote(text)
      if text.size >= 2 && ((text.start_with?("'") && text.end_with?("'")) || (text.start_with?('"') && text.end_with?('"')))
        text[1...-1]
      else
        text
      end
    end

    def scalar(text)
      raise SyntaxError, "line #{line}: #{text[0]} is not supported" if %w[& * ! | > { ].include?(text[0])
      return flow(text) if text.start_with?('[')
      return unquote(text) if text.start_with?("'") || text.start_with?('"')

      case text
      when 'null', '~', '' then nil
      when 'true' then true
      when 'false' then false
      when /\A-?\d+\z/ then text.to_i
      else text
      end
    end

    def flow(text)
      raise SyntaxError, "line #{line}: unterminated flow sequence" unless text.end_with?(']')

      inner = text[1...-1].strip
      return [] if inner.empty?

      inner.split(',').map { |item| scalar(item.strip) }
    end
  end
end

MRubyRequire.provide('yaml') { defined?(YAML) } if defined?(MRubyRequire)
