#!/usr/bin/env ruby
# nfcc's option loop, ported from the bash in nfcc (the loop at its "args=(\"$@\")" line). This first slice covers the groups
# whose meaning is plain: -c -S -o -x, the preprocessor options (-D -U -I -isystem -iquote -idirafter -include -imacros, with
# -MD -MMD -MF -MT -MQ -MP), -l and -L, and the input files. Any other option is refused as "unported" (exit 3), so that a
# caller can tell "not done yet" from "refused by nfcc"; the groups still to port are listed in the branch's notes.
#
# Checked against the bash loop by tests/nfcc/loop-state.sh, which compares the state this prints with the state the bash
# loop leaves (tests/nfcc/option-state.sh). Written for bc2cpp as well as CRuby: no Regexp, no ENV, no File.readable?.
#
#   ruby scripts/driver-loop.rb ARG...   prints the state, one line per variable (name=value, or name+=value per element);
#                                        an error as bash prints it ("nfcc: error: ..." on stderr, status 1)

class LoopDie < StandardError
end

class Unported < StandardError
end

C_LANGS = %w[c none assembler assembler-with-cpp].freeze
CXX_SUFFIXES = %w[.cc .cpp .cxx .C .c++ .ii .m .mm .f .f90 .F .go .d .rs].freeze
PP_TAKES_ARG = %w[-D -U -I -isystem -iquote -idirafter -include -imacros].freeze

class LoopState
  attr_accessor :mode, :asm, :out, :sawout, :lang, :depmode, :dfile, :dp
  attr_reader :pp, :ld, :inputs, :dts

  def initialize
    @mode = "link"
    @asm = 0
    @out = ""
    @sawout = 0
    @lang = ""
    @depmode = ""
    @dfile = ""
    @dp = 0
    @pp = []
    @ld = []
    @inputs = []
    @dts = []
  end
end

def die(message)
  raise LoopDie, message
end

def check_lang(lang)
  return if C_LANGS.include?(lang)

  die("-x #{lang} is not supported (C only; use nfcxx for C++)")
end

def input_kind(arg, state)
  if arg == "-"
    "c"
  elsif arg.end_with?(".c") || arg.end_with?(".i")
    %w[assembler assembler-with-cpp].include?(state.lang) ? "s" : "c"
  elsif arg.end_with?(".s") || arg.end_with?(".S")
    "s"
  elsif CXX_SUFFIXES.any? { |suffix| arg.end_with?(suffix) }
    die("#{arg}: not a C source (use nfcxx for C++)") unless state.lang == "c"

    "c"
  elsif state.lang == "c"
    "c"
  elsif %w[assembler assembler-with-cpp].include?(state.lang)
    "s"
  else
    "o"
  end
end

# Applies the loop to the arguments. Returns the state; raises LoopDie for an error bash would die on, Unported for an
# option this slice does not cover.
def run_loop(args)
  state = LoopState.new
  n = args.length
  i = 0
  while i < n
    a = args[i]
    # need: the option takes the next argument
    if a == "-c"
      state.mode = "compile"
    elsif a == "-S"
      state.asm = 1
    elsif a == "-o" || a == "-x" || a == "-MF" || a == "-MT" || a == "-MQ" || a == "-l" || a == "-L" ||
          PP_TAKES_ARG.include?(a)
      die("option '#{a}' requires an argument") unless i + 1 < n

      i += 1
      value = args[i]
      case a
      when "-o"
        state.out = value
        state.sawout = 1
      when "-x"
        check_lang(value)
        state.lang = value
      when "-MF"
        state.dfile = value
      when "-MT", "-MQ"
        state.dts << a << value
      when "-l", "-L"
        state.ld << a << value
      else
        state.pp << a << value
      end
    elsif a.start_with?("-o") && a.length > 2
      state.out = a[2..]
      state.sawout = 1
    elsif a.start_with?("-x") && a.length > 2
      check_lang(a[2..])
      state.lang = a[2..]
    elsif a == "-MD" || a == "-MMD"
      state.depmode = a
    elsif a.start_with?("-MF") && a.length > 3
      state.dfile = a[3..]
    elsif (a.start_with?("-MT") || a.start_with?("-MQ")) && a.length > 3
      state.dts << a[0, 3] << a[3..]
    elsif a == "-MP"
      state.dp = 1
    elsif PP_TAKES_ARG.any? { |flag| a.start_with?(flag) && a.length > flag.length }
      state.pp << a
    elsif (a.start_with?("-l") || a.start_with?("-L")) && a.length > 2
      state.ld << a
    elsif a == "-"
      state.inputs << "c:-"
    elsif a.start_with?("-") || a.start_with?("@")
      raise Unported, a
    else
      state.inputs << "#{input_kind(a, state)}:#{a}"
    end
    i += 1
  end
  state
end

def emit(state)
  $stdout.write("mode=#{state.mode}\n")
  $stdout.write("asm=#{state.asm}\n")
  $stdout.write("out=#{state.out}\n")
  $stdout.write("sawout=#{state.sawout}\n")
  $stdout.write("lang=#{state.lang}\n")
  $stdout.write("backend=gcc\n")
  $stdout.write("optlvl=-O2\n")
  $stdout.write("depmode=#{state.depmode}\n")
  $stdout.write("dfile=#{state.dfile}\n")
  $stdout.write("dp=#{state.dp}\n")
  $stdout.write("spon=0\n")
  $stdout.write("pathb_pic=0\n")
  $stdout.write("pathb_pie=0\n")
  state.inputs.each { |x| $stdout.write("inputs+=#{x}\n") }
  state.pp.each { |x| $stdout.write("pp+=#{x}\n") }
  state.ld.each { |x| $stdout.write("ld+=#{x}\n") }
  state.dts.each { |x| $stdout.write("dts+=#{x}\n") }
end

def main(argv)
  die("no input files") if argv.empty?

  emit(run_loop(argv))
  0
rescue LoopDie => e
  $stderr.write("nfcc: error: #{e.message}\n")
  1
rescue Unported => e
  $stderr.write("unported: #{e.message}\n")
  3
end

rc = main(ARGV)
exit(rc) if rc != 0
