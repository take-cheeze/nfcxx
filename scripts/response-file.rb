#!/usr/bin/env ruby
# Response files (@file) for nfcc, expanded with gcc's (libiberty buildargv) rules, as scripts/nfcc does in bash:
# arguments are separated by whitespace (space, tab, CR, LF, FF, VT); single or double quotes group them and are
# removed; a backslash makes the next byte literal, even inside quotes; @file inside a response file is expanded again,
# up to 32 levels. An argument that is not @file, or whose file is missing or unreadable, stays as it is.
#
# Written for bc2cpp as well as CRuby: byte strings only, no Regexp, no File.binread, no ENV.
#   ruby scripts/response-file.rb ARG...   prints the expanded arguments, each followed by a NUL byte
#   (the test in tests/nfcc/response-file.sh compares that with the bash expansion)

MAX_RESPONSE_DEPTH = 32

class ResponseFileError < StandardError
end

WHITESPACE_BYTES = [32, 9, 10, 13, 12, 11].freeze   # ' ', \t, \n, \r, \f, \v
BACKSLASH = 92
SINGLE_QUOTE = 39
DOUBLE_QUOTE = 34
AT_SIGN = 64

# The arguments in the text of one response file, in order.
def split_response_text(text)
  bytes = text.b
  size = bytes.bytesize
  words = []
  word = "".b
  have_word = false
  quote = nil
  j = 0
  while j < size
    ch = bytes.getbyte(j)
    if ch == BACKSLASH
      j += 1
      break if j >= size    # a trailing backslash ends the text; the word so far still counts
      word << bytes.getbyte(j)
      have_word = true
    elsif quote
      if ch == quote
        quote = nil
      else
        word << ch
      end
    elsif ch == SINGLE_QUOTE || ch == DOUBLE_QUOTE
      quote = ch
      have_word = true
    elsif WHITESPACE_BYTES.include?(ch)
      words << word if have_word
      word = "".b
      have_word = false
    else
      word << ch
      have_word = true
    end
    j += 1
  end
  words << word if have_word
  words
end

def read_response_file(path)
  File.open(path, "rb") { |io| io.read }
end

# Expands one argument into +out+. +depth+ is the response-file nesting of the argument.
def expand_argument(arg, depth, out)
  path = arg.byteslice(1, arg.bytesize - 1)
  unless arg.getbyte(0) == AT_SIGN && File.file?(path) && File.readable?(path)
    out << arg
    return out
  end
  if depth >= MAX_RESPONSE_DEPTH
    raise ResponseFileError, "response files nested too deeply (a loop?): #{path}"
  end
  split_response_text(read_response_file(path)).each do |word|
    expand_argument(word, depth + 1, out)
  end
  out
end

# All arguments, with every response file expanded in place.
def expand_response_args(args)
  out = []
  args.each { |arg| expand_argument(arg, 0, out) }
  out
end

def main(argv)
  expanded = expand_response_args(argv)
  expanded.each do |arg|
    $stdout.write(arg.b)
    $stdout.write("\0".b)
  end
  0
rescue ResponseFileError => e
  $stderr.write("nfcc: error: #{e.message}\n")
  1
end

rc = main(ARGV)
exit(rc) if rc != 0
