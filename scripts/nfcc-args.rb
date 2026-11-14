#!/usr/bin/env ruby
# Response files of nfcc (the bash nfcc's add_arg, ported): an argument @FILE is replaced by the arguments in FILE, with
# gcc's (libiberty buildargv) rules: arguments are separated by whitespace; single or double quotes group (and are
# removed); a backslash makes the next character literal, even inside quotes; @FILE inside a response file is expanded
# again (at most 32 levels). A file that cannot be read stays an "@FILE" argument (gcc does the same) and is rejected by
# the driver. The driver calls expand_args; `ruby scripts/nfcc-args.rb ARG...` prints the expanded arguments, NUL-separated.

module NfccArgs
  module_function

  WHITESPACE = [" ", "\t", "\n", "\r", "\f", "\v"].freeze

  # the expanded arguments of ARGS
  def expand_args(args)
    out = []
    args.each { |arg| expand_one(arg, 0, out) }
    out
  end

  def expand_one(arg, depth, out)
    f = arg[1..].to_s
    unless arg.start_with?("@") && File.file?(f) && File.readable?(f)
      out << arg
      return
    end
    if depth >= 32
      warn "nfcc: error: response files nested too deeply (a loop?): #{f}"
      exit 1
    end
    text = File.binread(f).force_encoding("UTF-8")
    parsed = []
    cur = +""
    have = false
    quote = nil
    chars = text.chars
    j = 0
    while j < chars.length
      ch = chars[j]
      if ch == "\\"
        j += 1
        break if j >= chars.length
        cur << chars[j]
        have = true
      elsif quote
        if ch == quote then quote = nil else cur << ch end
      elsif ch == "'" || ch == '"'
        quote = ch
        have = true
      elsif WHITESPACE.include?(ch)
        parsed << cur if have
        cur = +""
        have = false
      else
        cur << ch
        have = true
      end
      j += 1
    end
    parsed << cur if have
    parsed.each { |k| expand_one(k, depth + 1, out) }
  end
end

if $PROGRAM_NAME == __FILE__
  $stdout.write(NfccArgs.expand_args(ARGV).map { |a| "#{a}\0" }.join)
end
