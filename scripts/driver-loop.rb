#!/usr/bin/env ruby
# nfcc's option loop, ported from the bash in nfcc (the loop at its "args=(\"$@\")" line). This first slice covers the groups
# whose meaning is plain: -c -S -o -x, the preprocessor options (-D -U -I -isystem -iquote -idirafter -include -imacros, with
# -MD -MMD -MF -MT -MQ -MP), -l and -L, and the input files. Any other option is refused as "unported" (exit 3), so that a
# caller can tell "not done yet" from "refused by nfcc"; the groups still to port are listed in the branch's notes.
#
# Also: -O* -g* -pipe -v -time -w -W* (and -Wa,*, which goes to asf); -Wl,* and -Wp,* are not ported yet.
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

# Case patterns of the -f and -m groups, in the bash order (see nfcc, the loop's -f and -m cases). "*" is a glob, as in bash.
STACK_PROTECTOR = %w[-fstack-protector -fstack-protector-strong -fstack-protector-all -fstack-protector-explicit].freeze
INDIRECT_KEEP = %w[-mindirect-branch=keep -mfunction-return=keep -mharden-sls=none -mbranch-protection=none].freeze
INDIRECT_REFUSED = %w[-mindirect-branch=* -mfunction-return=* -mharden-sls=* -mbranch-protection=*].freeze
ISA_OPTIONS = %w[-march=* -msse* -mavx* -mfma -mbmi* -mpopcnt -mlzcnt -mf16c -mcx16 -mmmx -mrdrnd -mrdseed].freeze
M_NO_EFFECT = %w[-m64 -mtune=* -mcpu=* -mfpmath=* -mcmodel=* -mstackrealign -mpreferred-stack-boundary=*
                 -mtls-dialect=* -mrelax* -masm=* -mno-red-zone -mred-zone].freeze
INSTRUMENTATION = %w[-fopenmp* -fsanitize* -fprofile* -fcoverage* --coverage -ftest-coverage -fstack-check -fmudflap].freeze
FP_MATH = %w[-ffast-math -ffinite-math-only -funsafe-math-optimizations -fassociative-math -freciprocal-math
             -fno-signed-zeros -fno-math-errno].freeze
NO_EFFECT_F = %w[-fno-strict-aliasing -fwrapv -fno-strict-overflow].freeze
# Link options passed to the linker unchanged (the bash ld+= group after -l and -L).
LD_PASS = %w[-static -rdynamic -pie -no-pie -s -nostdlib -nostartfiles -nodefaultlibs -static-libgcc -shared-libgcc
             -pthread -Bstatic -Bdynamic -symbolic -r].freeze
LD_PATTERNS = %w[-Wl,* -fuse-ld=*].freeze

GCCONLY_PATTERNS = %w[
  -funsigned-char -fshort-enums -fpack-struct* -ftrapv -fgnu89-inline -fms-extensions -fplan9-extensions
  -fno-signed-char -fshort-wchar -fshort-double -fno-short-double -fleading-underscore
  -fno-leading-underscore -fnon-call-exceptions -fcheck-pointer-bounds -fsigned-bitfields
  -funsigned-bitfields -fno-asm -fno-gnu-keywords -ffreestanding -fhosted -fopenacc* -fgnu-tm -fcilkplus
  -fsplit-stack -fgnu-unique -fno-gnu-unique -fstack-reuse=* -fno-zero-initialized-in-bss -fgraphite*
  -fsel-sched* -fcall-used-* -fcall-saved-* -ffixed-* -finstrument-functions* -fwhole-program -fplugin*
  -fdump-* -fchecking*
].freeze

FOK_PATTERNS = %w[
  PIC pic PIE pie wrapv no-strict-aliasing strict-aliasing no-common common visibility=*
  no-omit-frame-pointer omit-frame-pointer exceptions no-exceptions asynchronous-unwind-tables
  no-asynchronous-unwind-tables unwind-tables stack-protector stack-protector-* no-stack-protector
  stack-clash-protection function-sections data-sections ident no-ident diagnostics-color=* color-diagnostics
  no-color-diagnostics diagnostics-show-option message-length=* max-errors=* no-builtin builtin no-builtin-*
  lto no-lto no-plt plt semantic-interposition no-semantic-interposition signed-char
  no-delete-null-pointer-checks no-strict-overflow strict-overflow trapping-math no-trapping-math math-errno
  merge-all-constants no-inline inline inline-functions no-inline-functions unroll-loops tree-vectorize
  no-tree-vectorize no-tree-* tree-* no-gcse gcse ipa-* no-ipa-* prefetch-loop-arrays align-functions=*
  align-loops=* align-jumps=* reorder-blocks no-reorder-blocks schedule-insns no-schedule-insns
  schedule-insns2 no-schedule-insns2 keep-inline-functions no-keep-static-consts permissive no-permissive
  no-rtti stack-protector-all cf-protection=* cf-protection no-cf-protection no-fat-lto-objects
  fat-lto-objects use-linker-plugin no-use-linker-plugin lto-partition=* file-prefix-map=* debug-prefix-map=*
  macro-prefix-map=* dwarf2-cfi-asm no-dwarf2-cfi-asm var-tracking no-var-tracking var-tracking-assignments
  no-var-tracking-assignments no-eliminate-unused-debug-types eliminate-unused-debug-types
  record-gcc-switches no-record-gcc-switches verbose-asm no-verbose-asm stack-usage no-stack-usage
].freeze

class LoopState
  attr_accessor :mode, :asm, :out, :sawout, :lang, :depmode, :dfile, :dp
  attr_accessor :optlvl, :spon, :pathb_pic, :pathb_pie
  attr_reader :pp, :ld, :inputs, :dts, :dbg, :asf, :isa, :picf, :spguard

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
    @optlvl = "-O2"
    @dbg = []
    @asf = []
    @spon = 0
    @pathb_pic = 0
    @pathb_pie = 0
    @isa = []
    @picf = []
    @spguard = []
  end
end

def die(message)
  raise LoopDie, message
end

# Bash's glob matching for case patterns and @(...) lists: "*" matches any string (including "/"), "?" one character.
def glob_match?(pattern, text)
  pi = 0
  ti = 0
  star_p = -1
  star_t = -1
  while ti < text.length
    if pi < pattern.length && (pattern[pi] == "?" || pattern[pi] == text[ti])
      pi += 1
      ti += 1
    elsif pi < pattern.length && pattern[pi] == "*"
      star_p = pi
      star_t = ti
      pi += 1
    elsif star_p >= 0
      pi = star_p + 1
      star_t += 1
      ti = star_t
    else
      return false
    end
  end
  pi += 1 while pi < pattern.length && pattern[pi] == "*"
  pi == pattern.length
end

def matches_any?(arg, patterns)
  patterns.any? { |pattern| glob_match?(pattern, arg) }
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
          a == "-Xlinker" || a == "-z" || a == "-u" || a == "-T" || PP_TAKES_ARG.include?(a)
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
      when "-l", "-L", "-Xlinker", "-z", "-u", "-T"
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
    elsif a == "-Ofast"
      die("#{a} is not supported (changes floating-point semantics)")
    elsif a == "-O" || a == "-O0" || a == "-O1" || a == "-O2" || a == "-O3" || a == "-Os" || a == "-Og"
      state.optlvl = a == "-O" ? "-O1" : a
    elsif a.start_with?("-O")
      die("unknown optimisation option '#{a}'")
    elsif a == "-g" || a.start_with?("-g")
      state.dbg << a
    elsif a == "-pipe" || a == "-v" || a == "-time"
      nil
    elsif a.start_with?("-std=c++") || a.start_with?("-std=gnu++")
      die("#{a}: C++ is not supported by nfcc (use nfcxx)")
    elsif a.start_with?("-std=") || a == "-ansi"
      state.pp << a
    elsif a == "-nostdinc" || a == "-undef" || a.start_with?("--sysroot=")
      state.pp << a
      state.ld << a
    elsif a == "-shared"
      state.pathb_pic = 1
      state.ld << a
    elsif LD_PASS.include?(a) || matches_any?(a, LD_PATTERNS)
      state.ld << a
    elsif a.start_with?("-Wa,")
      state.asf << a
    elsif a.start_with?("-Wp,")
      raise Unported, a
    elsif a == "-w" || a.start_with?("-W")
      nil
    elsif a == "-fstack-protector" || STACK_PROTECTOR.include?(a)
      state.spon = 1
    elsif a == "-fno-stack-protector"
      state.spon = 0
    elsif a.start_with?("-mstack-protector-guard")
      state.spguard << a
    elsif INDIRECT_KEEP.include?(a)
      nil
    elsif matches_any?(a, INDIRECT_REFUSED)
      die("#{a} is not supported")
    elsif a == "-fPIC" || a == "-fpic"
      state.pathb_pic = 1
      state.ld << a
      state.picf << a
    elsif a == "-fPIE" || a == "-fpie"
      state.pathb_pie = 1
      state.ld << a
      state.picf << a
    elsif a == "-m32" || a == "-mx32" || a == "-m16" || a == "-miamcu"
      die("#{a} is not supported (x86-64 only)")
    elsif matches_any?(a, ISA_OPTIONS) || a.start_with?("--param=") || a == "-fno-jump-tables"
      state.isa << a
    elsif a == "-fno-crossjumping"
      raise Unported, a
    elsif a == "--param"
      die("option '#{a}' requires an argument") unless i + 1 < n

      i += 1
      state.isa << a << args[i]
    elsif matches_any?(a, M_NO_EFFECT) || matches_any?(a, NO_EFFECT_F)
      nil
    elsif a.start_with?("-m")
      die("#{a} is not supported")
    elsif matches_any?(a, INSTRUMENTATION)
      die("#{a} is not supported (instrumentation would be dropped)")
    elsif matches_any?(a, FP_MATH)
      die("#{a} is not supported (changes floating-point semantics)")
    elsif matches_any?(a, GCCONLY_PATTERNS)
      die("#{a} is not supported (it changes semantics or code generation that this pipeline cannot honour)")
    elsif a.start_with?("-f")
      if matches_any?(a[2..], FOK_PATTERNS)
        nil
      else
        die("#{a} is not supported (not in nfcc's list of harmless -f options)")
      end
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
  $stdout.write("optlvl=#{state.optlvl}\n")
  $stdout.write("depmode=#{state.depmode}\n")
  $stdout.write("dfile=#{state.dfile}\n")
  $stdout.write("dp=#{state.dp}\n")
  $stdout.write("spon=#{state.spon}\n")
  $stdout.write("pathb_pic=#{state.pathb_pic}\n")
  $stdout.write("pathb_pie=#{state.pathb_pie}\n")
  state.inputs.each { |x| $stdout.write("inputs+=#{x}\n") }
  state.pp.each { |x| $stdout.write("pp+=#{x}\n") }
  state.ld.each { |x| $stdout.write("ld+=#{x}\n") }
  state.isa.each { |x| $stdout.write("isa+=#{x}\n") }
  state.asf.each { |x| $stdout.write("asf+=#{x}\n") }
  state.picf.each { |x| $stdout.write("picf+=#{x}\n") }
  state.dbg.each { |x| $stdout.write("dbg+=#{x}\n") }
  state.spguard.each { |x| $stdout.write("spguard+=#{x}\n") }
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
