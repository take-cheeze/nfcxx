# frozen_string_literal: true

require 'prism'
require 'set'

module MrbcRb
  # The symbol id the C mrbc gives each input file name (cdump.c writes it per irep with -g -S).
  #
  # mrbc interns the first file name before it parses, and the name of every further file in the partial hook, which the
  # lexer calls when it runs out of a file: after it has lexed (and so interned: identifiers, constants, @ivars, @@cvars,
  # $gvars, labels, keywords after `.`/`def`, symbols) everything of the previous files. A symbol that is one of the mrbc
  # build's presyms keeps its fixed id and takes no number (nor does a name of up to 4 characters of [_A-Za-z0-9]: symbol.c
  # packs it into the symbol itself); every other new symbol takes the next one. So the id of file
  # k is PRESYM_MAX + 1 + (the number of distinct non-presym symbols interned before it, file names included).
  # Symbols the parser makes in its actions (:"a b", "a b": labels) are interned in token order here too (mrbc
  # does it one reduction later: the same count unless one such symbol is the last thing of a file).
  #
  # The presym set is a property of the mrbc build: presym_fork.txt is the fork's host mrbc (1474), presym_bootstrap.txt
  # is mruby's own bootstrap mrbc (282); MRBC_RB_PRESYM=bootstrap|fork|<file: one name per line, or a presym/table.h>.
  module FileSyms
    DIR = __dir__
    NAMED = %i[IDENTIFIER CONSTANT INSTANCE_VARIABLE CLASS_VARIABLE GLOBAL_VARIABLE METHOD_NAME].freeze

    module_function

    # [Set of names, count] of a presym set (see above).
    def presyms(spec = ENV.fetch('MRBC_RB_PRESYM', 'fork'))
      @cache ||= {}
      @cache[spec] ||= begin
        path = %w[fork bootstrap].include?(spec) ? File.join(DIR, "presym_#{spec}.txt") : spec
        text = File.read(path)
        names = if text.include?('\\0"')
                  text.scan(/^  "(.*?)\\0"$/).flatten
                else
                  text.split("\n")
                end
        [names.to_set, names.size]
      end
    end

    # The names the lexer/parser of mrbc interns for +src+, in order.
    def interned(src)
      names = []
      tokens = Prism.lex(src).value.map { |t, _| t }
      i = 0
      while i < tokens.size
        t = tokens[i]
        case t.type
        when *NAMED then names << t.value
        when :LABEL then names << t.value.chomp(':')
        when :SYMBOL_BEGIN, :STRING_BEGIN
          # string symbols: :"a b", %s(a b), "a b": -- the parser interns the literal text (%i[] words: codegen, later)
          j = i + 1
          parts = []
          plain = true
          while j < tokens.size && !%i[STRING_END LABEL_END].include?(tokens[j].type)
            case tokens[j].type
            when :STRING_CONTENT then parts << tokens[j].value
            when :WORDS_SEP then parts << nil
            when :EMBEXPR_BEGIN, :EMBVAR
              plain = false
              break
            else break
            end
            j += 1
          end
          is_sym = (t.type == :SYMBOL_BEGIN && t.value != ':') ||
                   (t.type == :STRING_BEGIN && tokens[j]&.type == :LABEL_END)
          if is_sym && plain
            names << parts.join
          end
        end
        i += 1
      end
      names
    end

    # symbol.c packs a name of at most 4 characters of [_A-Za-z0-9] into the symbol itself: it takes no number.
    def inline?(name)
      name.bytesize <= 4 && name.match?(/\A[_A-Za-z0-9]+\z/)
    end

    PACK = '_abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'

    def inline_id(name)
      name.each_char.with_index.sum { |c, i| (PACK.index(c) + 1) << (20 - i * 6) }
    end

    # { file name => symbol id } for the inputs [[source, name] ...] in command line order.
    def ids(files, set: nil)
      presym, base = set || presyms
      seen = {}
      next_id = base
      take = lambda do |name|
        next if presym.include?(name) || inline?(name) || seen.key?(name)

        seen[name] = (next_id += 1)
      end
      out = {}
      files.each do |src, name|
        take.call(name)
        out[name] ||= inline?(name) ? inline_id(name) : seen.fetch(name)
        interned(src).each { |n| take.call(n) }
      end
      out
    end
  end
end
