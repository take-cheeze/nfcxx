# JSON: generate, pretty_generate and parse, with CRuby's output format for the value types bc2cpp writes
# (nil, true, false, Integer, Float, String, Symbol, Array, Hash). Other objects are written as their to_s string.
module JSON
  class ParserError < StandardError
  end

  ESCAPES = { "\"" => "\\\"", "\\" => "\\\\", "\b" => "\\b", "\f" => "\\f", "\n" => "\\n", "\r" => "\\r", "\t" => "\\t" }.freeze

  def self.generate(value)
    emit(value, nil, "")
  end

  def self.pretty_generate(value)
    emit(value, "  ", "")
  end

  # indent nil: compact output. Otherwise each nested level is indented by indent, as CRuby's pretty_generate.
  def self.emit(value, indent, depth)
    case value
    when nil then "null"
    when true then "true"
    when false then "false"
    when Integer then value.to_s
    when Float
      raise ArgumentError, "JSON does not allow NaN or Infinity" unless value.finite?

      value.to_s
    when String then quote(value)
    when Symbol then quote(value.to_s)
    when Array then container(value.map { |item| emit(item, indent, depth + indent.to_s) }, "[", "]", indent, depth)
    when Hash
      items = value.map do |key, item|
        "#{quote(key.to_s)}:#{indent ? ' ' : ''}#{emit(item, indent, depth + indent.to_s)}"
      end
      container(items, "{", "}", indent, depth)
    else quote(value.to_s)
    end
  end

  def self.container(items, open, close, indent, depth)
    return open + close if items.empty?
    return open + items.join(",") + close unless indent

    inner = depth + indent
    open + "\n" + items.map { |item| inner + item }.join(",\n") + "\n" + depth + close
  end

  def self.quote(text)
    out = +"\""
    text.each_char do |char|
      escaped = ESCAPES[char]
      if escaped
        out << escaped
      elsif char.ord < 0x20
        out << format("\\u%04x", char.ord)
      else
        out << char
      end
    end
    out << "\""
  end

  def self.parse(text)
    parser = Parser.new(text)
    value = parser.value
    parser.skip_space
    raise ParserError, "unexpected token at #{parser.position}" unless parser.done?

    value
  end

  # A recursive-descent parser over the characters of the text.
  class Parser
    def initialize(text)
      @chars = text.chars
      @i = 0
    end

    def position
      @i
    end

    def done?
      @i >= @chars.size
    end

    def skip_space
      @i += 1 while !done? && " \t\r\n".include?(@chars[@i])
    end

    def value
      skip_space
      raise ParserError, "unexpected end of input" if done?

      char = @chars[@i]
      case char
      when "{" then object
      when "[" then array
      when "\"" then string
      when "t" then literal("true", true)
      when "f" then literal("false", false)
      when "n" then literal("null", nil)
      else
        raise ParserError, "unexpected token at #{@i}" unless char == "-" || ("0".."9").include?(char)

        number
      end
    end

    def literal(word, result)
      word.each_char do |char|
        raise ParserError, "unexpected token at #{@i}" unless @chars[@i] == char

        @i += 1
      end
      result
    end

    def number
      start = @i
      @i += 1 if @chars[@i] == "-"
      @i += 1 while !done? && ("0".."9").include?(@chars[@i])
      float = false
      if @chars[@i] == "."
        float = true
        @i += 1
        @i += 1 while !done? && ("0".."9").include?(@chars[@i])
      end
      if @chars[@i] == "e" || @chars[@i] == "E"
        float = true
        @i += 1
        @i += 1 if @chars[@i] == "+" || @chars[@i] == "-"
        @i += 1 while !done? && ("0".."9").include?(@chars[@i])
      end
      text = @chars[start...@i].join
      raise ParserError, "unexpected token at #{start}" if text == "-" || text.empty?

      float ? text.to_f : text.to_i
    end

    def string
      @i += 1
      out = +""
      loop do
        raise ParserError, "unterminated string" if done?

        char = @chars[@i]
        @i += 1
        return out if char == "\""

        if char == "\\"
          out << escape
        else
          out << char
        end
      end
    end

    def escape
      char = @chars[@i]
      @i += 1
      case char
      when "\"", "\\", "/" then char
      when "b" then "\b"
      when "f" then "\f"
      when "n" then "\n"
      when "r" then "\r"
      when "t" then "\t"
      when "u"
        code = hex4
        if code >= 0xd800 && code <= 0xdbff && @chars[@i] == "\\" && @chars[@i + 1] == "u"
          @i += 2
          low = hex4
          code = 0x10000 + ((code - 0xd800) << 10) + (low - 0xdc00)
        end
        [code].pack("U")
      else raise ParserError, "invalid escape at #{@i - 1}"
      end
    end

    def hex4
      digits = @chars[@i, 4]
      raise ParserError, "invalid unicode escape at #{@i}" unless digits.size == 4

      @i += 4
      digits.join.to_i(16)
    end

    def array
      @i += 1
      out = []
      skip_space
      if @chars[@i] == "]"
        @i += 1
        return out
      end
      loop do
        out << value
        skip_space
        char = @chars[@i]
        @i += 1
        return out if char == "]"
        raise ParserError, "expected , or ] at #{@i - 1}" unless char == ","
      end
    end

    def object
      @i += 1
      out = {}
      skip_space
      if @chars[@i] == "}"
        @i += 1
        return out
      end
      loop do
        skip_space
        raise ParserError, "expected a string key at #{@i}" unless @chars[@i] == "\""

        key = string
        skip_space
        raise ParserError, "expected : at #{@i}" unless @chars[@i] == ":"

        @i += 1
        out[key] = value
        skip_space
        char = @chars[@i]
        @i += 1
        return out if char == "}"
        raise ParserError, "expected , or } at #{@i - 1}" unless char == ","
      end
    end
  end
end

MRubyRequire.provide('json') { defined?(JSON::Parser) } if defined?(MRubyRequire)
