#!/usr/bin/env ruby
# nfcc, ported from the bash in nfcc: its option handling and its compile stage. Covered: the @file expansion; the pre-loop
# decisions that run the host compiler (-E, -M, -MM, -MG, -fsyntax-only, -dumpmachine and friends, -print-*, -v), printed as
# "EXEC"; every option of the loop's case statement, with the Path B helper (pathb_option), the QBE
# gcc-only and passthrough rules, and the -fno-crossjumping host check; the post-loop
# checks; the Path B reason checks (pathb_reason, with the -fshort-wchar answer as an input); the compile of each input
# (compile_one: the Path B command, its -S copy, the gcc fallback, the qbe and cil commands, the dependency commands) and the
# link. The commands are printed as "RUN argv..." (copies as CP, CAT, LN) and not run; tests/nfcc/option-state.sh runs nfcc's
# own code with the same commands stubbed, so the output can be compared.
#
# Also covered: the bundle wrapper (scripts/bundle-wrap.sh: the --bundle- options, the driver re-run, the nfcbundle link step) and
# the CUDA driver wrapper (scripts/cuda-driver-wrap.sh: --cuda-driver=, the libcuda rewrite, the shim, the refusals and the
# note). Their probes of the file system (the CUDA home's headers and lib64, the shim build, the nfcbundle tool's state, ninja)
# and the host's answers are inputs here (--nfcc-cuda-*, --nfcc-bundle-tool, --nfcc-ninja-fails, --nfcc-shim).
#
# Nothing is refused as unported now: the empty source name gets realpath's message, and a libcuda with no CUDA_HOME gets the
# home nfcc derives from the library path (the port reads the home's files itself). The remaining exits are nfcc's own.
#
# Configuration, which nfcc reads from its environment: --nfcc-backend=cil|gcc|pathb (default gcc),
# --nfcc-passthrough=0|1 (NFCXX_GCC_PASSTHROUGH) and --nfcc-host-gnu-gcc=0|1. They come first on the command line.
#
# Checked against the bash loop by tests/nfcc/loop-state.sh, which compares the state this prints with the state the bash
# loop leaves (tests/nfcc/option-state.sh). Written for bc2cpp as well as CRuby: no Regexp, no ENV, no File.readable?.
#
#   ruby scripts/driver-loop.rb ARG...   prints the state, one line per variable (name=value, or name+=value per element);
#                                        an error as bash prints it ("nfcc: error: ..." on stderr, status 1)

class LoopDie < StandardError
end

# nfcc expands @file arguments before its loop (add_arg): the same rules as scripts/response-file.rb (gcc's buildargv:
# whitespace separates, quotes group, a backslash escapes, nested @file up to 32 levels). An @file that is not a readable
# regular file stays as it is; the loop then refuses it.
MAX_RESPONSE_DEPTH = 32
RESPONSE_WHITESPACE = [32, 9, 10, 13, 12, 11].freeze

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
    if ch == 92
      j += 1
      break if j >= size

      word << bytes.getbyte(j)
      have_word = true
    elsif quote
      if ch == quote
        quote = nil
      else
        word << ch
      end
    elsif ch == 39 || ch == 34
      quote = ch
      have_word = true
    elsif RESPONSE_WHITESPACE.include?(ch)
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
  return nil unless File.file?(path)

  File.open(path, "rb") { |io| io.read }
rescue StandardError
  nil
end

def expand_argument(arg, depth, out)
  path = arg.byteslice(1, arg.bytesize - 1)
  text = arg.getbyte(0) == 64 ? read_response_file(path) : nil
  if text.nil?
    out << arg
    return out
  end
  die("response files nested too deeply (a loop?): #{path}") if depth >= MAX_RESPONSE_DEPTH
  split_response_text(text).each { |word| expand_argument(word, depth + 1, out) }
  out
end

def expand_response_args(args)
  out = []
  args.each { |arg| expand_argument(arg, 0, out) }
  out
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



# Path B (backend pathb) options, bash's pathb_option: flags with an effect, the options with no effect on QBE's code.
PATHB_PBF_FLAGS = %w[-funsigned-char -fno-signed-char -fsigned-char -fno-unsigned-char -ffreestanding].freeze
PATHB_TRIVIAL = %w[-ftrivial-auto-var-init=zero -ftrivial-auto-var-init=uninitialized].freeze
PATHB_NOFP = %w[-mno-sse -mno-sse2 -mno-80387 -msoft-float].freeze
PATHB_NOPIE = %w[-fno-PIE -fno-pie -fno-PIC -fno-pic].freeze
PATHB_NO_EFFECT = %w[-fno-stack-check -fno-stack-clash-protection -fno-allow-store-data-races -fno-optimize-sibling-calls
                     -foptimize-sibling-calls -fno-function-sections -fno-data-sections -fstrict-flex-arrays=* -fconserve-stack
                     -falign-labels=* -mno-mmx -mno-3dnow -mno-avx -mno-avx2 -mno-avx512* -mno-ssse3 -mno-sse3 -mno-sse4*
                     -mno-fma -mno-bmi* -mno-popcnt -mno-fp-ret-in-387 -mskip-rax-setup -mno-red-zone -mred-zone].freeze

# The loop's state, and the configuration nfcc reads from the environment (backend, passthrough, host_gnu_gcc).
class LoopState
  attr_accessor :mode, :asm, :out, :sawout, :lang, :depmode, :dfile, :dp, :optlvl, :spon, :pathb_pic, :pathb_pie
  attr_accessor :pb_m16, :pb_regparm, :nofp, :nounwind, :wchar16
  attr_accessor :backend, :passthrough, :host_gnu_gcc
  attr_accessor :k, :pb_std, :pb_gnu, :pb_opts, :pb_reason
  attr_reader :pp, :ld, :inputs, :dts, :dbg, :asf, :isa, :picf, :spguard, :gccf, :kqf, :pbf, :needgcc

  def initialize(backend, passthrough, host_gnu_gcc)
    @mode = "link"
    @asm = 0
    @out = ""
    @sawout = 0
    @lang = ""
    @depmode = ""
    @dfile = ""
    @dp = 0
    @optlvl = "-O2"
    @spon = 0
    @pathb_pic = 0
    @pathb_pie = 0
    @pb_m16 = 0
    @pb_regparm = 0
    @nofp = 0
    @nounwind = 0
    @wchar16 = 0
    @backend = backend
    @passthrough = passthrough
    @host_gnu_gcc = host_gnu_gcc
    @pp = []
    @ld = []
    @inputs = []
    @dts = []
    @dbg = []
    @asf = []
    @isa = []
    @picf = []
    @spguard = []
    @gccf = []
    @kqf = []
    @pbf = []
    @needgcc = []
    @k = 0
    @pb_std = "-std=c11"
    @pb_gnu = 1
    @pb_opts = []
    @pb_reason = ""
  end
end

# What the compile stage needs from the environment. The driver's real run takes these from the shell; the port takes them
# as options (see main): the root and the temporary directory and the working directory (for realpath), the OS (uname -s),
# the output of scripts/pathb-ldrt, the EDG build directory, and whether the host preprocessor finds a wide literal in the
# unit (the -fshort-wchar check, which runs the host preprocessor and greps its output).
class Env
  attr_accessor :root, :tmp, :cwd, :os, :ldrt, :edg_build, :wide_literal, :pathb_status, :pathb_fallback, :host
  attr_accessor :dumpfullversion, :host_version_line, :pathb_log, :bundle_tool, :ninja_fails
  # the CUDA driver wrapper's environment and probes (the driver's real run takes them from the shell and the file system)
  attr_accessor :cuda_home, :cuda_driver_env, :cuda_h, :cuda_typedefs, :cudart_version, :lib64, :machine, :shim, :shim_error
  attr_accessor :cuda_header
  def initialize
    @root = Dir.pwd
    @tmp = "/tmp/nfcc"
    @cwd = Dir.pwd
    @os = "Linux"
    @ldrt = ""
    @edg_build = nil
    @wide_literal = false
    @pathb_status = 0
    @pathb_fallback = false
    @host = "cc"
    @dumpfullversion = "0"
    @host_version_line = ""
    @pathb_log = nil
    @bundle_tool = "missing"
    @ninja_fails = false
    @cuda_home = ""
    @cuda_driver_env = "auto"
    @cuda_h = false
    @cuda_typedefs = false
    @cudart_version = 0
    @lib64 = false
    @machine = "x86_64"
    @shim = ""
    @shim_error = nil
    @cuda_header = true
  end
end

# nfcc's "exit $rc" after a failed Path B compile with no gcc fallback.
# cuda_driver_wrap's exits (its messages and status).
class CudaExit < StandardError
  attr_reader :status
  def initialize(message, status)
    super(message)
    @status = status
  end
end

# bundle_wrap's own exits (its messages and status); the driver's real run is not part of the port.
class BundleExit < StandardError
  attr_reader :status
  def initialize(message, status)
    super(message)
    @status = status
  end
end

class PathbExit < StandardError
  attr_reader :status
  def initialize(status)
    super("path b failed")
    @status = status
  end
end

def die(message)
  raise LoopDie, message
end

# nfcc's gccplain: an option with no effect on QBE's output that gcc still gets, in the pathb backend or with passthrough.
def gccplain(state, arg)
  ok = state.backend == "pathb" || (state.backend == "gcc" && state.passthrough)
  state.gccf << arg if ok
  ok
end

# nfcc's gcconly: an option that changes meaning; pathb gives it to gcc (needgcc), gcc with passthrough gives it to gcc.
def gcconly(state, arg)
  if state.backend == "pathb"
    state.gccf << arg
    state.needgcc << arg
    return true
  end
  ok = state.backend == "gcc" && state.passthrough
  state.gccf << arg if ok
  ok
end

# nfcc's pathb_option (the pathb backend only): true when the option is handled here; the loop then skips its own case.
def pathb_option(state, arg)
  if arg == "-m16"
    state.pb_m16 = 1
  elsif arg == "-mregparm=3"
    state.pb_regparm = 1
  elsif PATHB_PBF_FLAGS.include?(arg) || PATHB_TRIVIAL.include?(arg)
    state.pbf << arg
  elsif arg == "-fshort-wchar"
    state.pbf << arg
    state.wchar16 = 1
  elsif PATHB_NOFP.include?(arg)
    state.pbf << "--no-fp"
    state.nofp = 1
  elsif arg == "-fno-asynchronous-unwind-tables"
    state.pbf << "--no-unwind"
    state.nounwind = 1
  elsif PATHB_NOPIE.include?(arg)
    state.pbf << "--no-pie"
  elsif matches_any?(arg, PATHB_NO_EFFECT)
    nil
  else
    return false
  end
  state.gccf << arg
  true
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

# -Wp,a,b,c: bash's wp_option, which the loop calls. Splits on commas the way `IFS=, read -ra` does (an empty middle field
# is kept, a comma at the end adds no empty field). The same parser is in scripts/driver-options.rb, the sealed build;
# tests/nfcc/loop-state.sh checks that the two agree on every -Wp option.
WP_TAKES_ARG = %w[-isystem -iquote -idirafter -include -imacros].freeze

def split_wp_fields(text)
  fields = []
  field = "".b
  text.b.each_byte do |byte|
    if byte == 44
      fields << field
      field = "".b
    else
      field << byte
    end
  end
  fields << field unless field.empty?
  fields
end

def apply_wp_option(option, state)
  words = split_wp_fields(option.byteslice(4, option.bytesize - 4))
  j = 0
  while j < words.length
    x = words[j]
    if x.bytesize > 2 && %w[-D -U -I].include?(x.byteslice(0, 2))
      state.pp << x
    elsif WP_TAKES_ARG.include?(x)
      die("#{option}: '#{x}' needs an argument") unless j + 1 < words.length

      j += 1
      state.pp << x << words[j]
    elsif x == "-MD" || x == "-MMD"
      die("#{option}: '#{x}' needs a file name") unless j + 1 < words.length

      j += 1
      state.depmode = x
      state.dfile = words[j]
    elsif x == "-MF"
      die("#{option}: '-MF' needs a file name") unless j + 1 < words.length

      j += 1
      state.dfile = words[j]
    elsif x == "-MT" || x == "-MQ"
      die("#{option}: '#{x}' needs a target") unless j + 1 < words.length

      j += 1
      state.dts << x << words[j]
    elsif x == "-MP"
      state.dp = 1
    else
      die("#{option}: the preprocessor option '#{x}' is not supported " \
          "(only -D -U -I -isystem -iquote -idirafter -include -imacros -MD -MMD -MF -MT -MQ -MP)")
    end
    j += 1
  end
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

# The option loop, in the order of nfcc's case statement. args are already expanded (no @file).
def run_loop(args, state)
  n = args.length
  i = 0
  while i < n
    a = args[i]
    if state.backend == "pathb" && pathb_option(state, a)
      i += 1
      next
    end

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
    elsif a.start_with?("-l") && a.length > 2 || a.start_with?("-L") && a.length > 2
      state.ld << a
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
    elsif a.start_with?("-Wp,")
      apply_wp_option(a, state)
    elsif a.start_with?("-Wa,")
      state.asf << a
    elsif a == "-w" || a.start_with?("-W")
      nil
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
    elsif a == "-fstack-protector" || STACK_PROTECTOR.include?(a)
      state.spon = 1
      gccplain(state, a)
    elsif a == "-fno-stack-protector"
      state.spon = 0
      gccplain(state, a)
    elsif a.start_with?("-mstack-protector-guard")
      state.spguard << a
    elsif INDIRECT_KEEP.include?(a)
      gccplain(state, a)
    elsif matches_any?(a, INDIRECT_REFUSED)
      die("#{a} is not supported") unless gcconly(state, a)
    elsif a == "-fPIC" || a == "-fpic"
      state.pathb_pic = 1
      state.ld << a
      state.picf << a unless gccplain(state, a)
    elsif a == "-fPIE" || a == "-fpie"
      state.pathb_pie = 1
      state.ld << a
      state.picf << a unless gccplain(state, a)
    elsif a == "-m32" || a == "-mx32" || a == "-m16" || a == "-miamcu"
      die("#{a} is not supported (x86-64 only)") unless gcconly(state, a)
    elsif matches_any?(a, ISA_OPTIONS)
      state.isa << a unless gccplain(state, a)
    elsif a.start_with?("--param=")
      state.isa << a
    elsif a == "-fno-jump-tables"
      state.isa << a
    elsif a == "-fno-crossjumping"
      state.isa << a if state.host_gnu_gcc
    elsif a == "--param"
      die("option '#{a}' requires an argument") unless i + 1 < n

      i += 1
      state.isa << a << args[i]
    elsif matches_any?(a, M_NO_EFFECT) || matches_any?(a, NO_EFFECT_F)
      gccplain(state, a)
    elsif a.start_with?("-m")
      die("#{a} is not supported") unless gcconly(state, a)
    elsif matches_any?(a, INSTRUMENTATION)
      die("#{a} is not supported (instrumentation would be dropped)")
    elsif matches_any?(a, FP_MATH)
      die("#{a} is not supported (changes floating-point semantics)") unless gcconly(state, a)
    elsif matches_any?(a, GCCONLY_PATTERNS)
      die("#{a} is not supported (it changes semantics or code generation that this pipeline cannot honour)") unless gcconly(state, a)
    elsif a.start_with?("-f")
      if matches_any?(a[2..], FOK_PATTERNS)
        gccplain(state, a)
      else
        die("#{a} is not supported (not in nfcc's list of harmless -f options)") unless gcconly(state, a)
      end
    elsif a == "-"
      state.inputs << "c:-"
    elsif a.start_with?("@")
      die("response files (#{a}) are not supported")
    elsif a.start_with?("-")
      die("unsupported option '#{a}'")
    else
      state.inputs << "#{input_kind(a, state)}:#{a}"
    end
    i += 1
  end

  # The post-loop checks (nfcc, after its loop).
  state.spguard.each do |a|
    if state.spon == 1
      die("#{a} is not supported") unless gcconly(state, a)
    else
      gccplain(state, a)
    end
  end
  die("no input files") if state.inputs.empty?
  state.mode = "compile" if state.asm == 1
  if state.mode == "compile"
    die("cannot specify -o with -c and multiple files") if state.sawout == 1 && state.inputs.length > 1
  end
  if !state.depmode.empty? && state.mode != "compile"
    die("#{state.depmode} needs -c (dependency files for a compile-and-link command are not supported)")
  end
  die("-MF needs -MD or -MMD with -c (or -M/-MM for -E)") if !state.dfile.empty? && state.depmode.empty?
  state
end

EXEC_PREFIXES = %w[-dumpmachine -dumpversion -dumpfullversion -dumpspecs -V -qversion --help --target-help].freeze
EXEC_TOOLS = %w[-E -M -MM -MG -fsyntax-only].freeze

# The decisions nfcc makes before its loop: a version query (not ported: raises Unported), a query or -E/-M/-fsyntax-only that
# runs the host compiler. Returns the command that exec runs, or nil to carry on.
def pre_loop_exec(args, host, banner_backend = nil, env = nil)
  args.each do |a|
    return [:banner, banner_backend, env] if a == "--version"
    return [host] + args if EXEC_PREFIXES.include?(a) || a.start_with?("-print-")
  end
  return [host, "-v"] if args == ["-v"]
  args.each { |a| return [host] + args if EXEC_TOOLS.include?(a) }
  nil
end

def emit(state)
  $stdout.write("mode=#{state.mode}\n")
  $stdout.write("asm=#{state.asm}\n")
  $stdout.write("out=#{state.out}\n")
  $stdout.write("sawout=#{state.sawout}\n")
  $stdout.write("lang=#{state.lang}\n")
  $stdout.write("backend=#{state.backend}\n")
  $stdout.write("optlvl=#{state.optlvl}\n")
  $stdout.write("depmode=#{state.depmode}\n")
  $stdout.write("dfile=#{state.dfile}\n")
  $stdout.write("dp=#{state.dp}\n")
  $stdout.write("spon=#{state.spon}\n")
  $stdout.write("pathb_pic=#{state.pathb_pic}\n")
  $stdout.write("pathb_pie=#{state.pathb_pie}\n")
  $stdout.write("pb_m16=#{state.pb_m16}\n")
  $stdout.write("pb_regparm=#{state.pb_regparm}\n")
  $stdout.write("nofp=#{state.nofp}\n")
  $stdout.write("nounwind=#{state.nounwind}\n")
  $stdout.write("wchar16=#{state.wchar16}\n")
  { "inputs" => state.inputs, "pp" => state.pp, "ld" => state.ld, "gccf" => state.gccf, "isa" => state.isa,
    "asf" => state.asf, "picf" => state.picf, "dbg" => state.dbg, "spguard" => state.spguard, "dts" => state.dts,
    "kqf" => state.kqf, "pbf" => state.pbf, "needgcc" => state.needgcc }.each do |name, items|
    items.each { |x| $stdout.write("#{name}+=#{x}\n") }
  end
end

# ---- the compile stage: nfcc's pathb_reason, pathb_compile, compile_one, the compile and link loops ----
# Each command the driver would run is printed as "RUN argv..." (copies as CP, CAT, LN), not run. The oracle prints the same
# for the same commands (tests/nfcc/option-state.sh stubs them), so the decisions can be compared.

PB_SIMPLE_ASM = %w[--fatal-warnings --noexecstack -W --no-warn -mrelax-relocations=yes -mrelax-relocations=no
                   -mx86-used-note=yes -mx86-used-note=no].freeze
PB_STD_DIRECT = %w[-std=c89 -std=c99 -std=c11 -std=c17 -std=c18 -std=c23].freeze
PB_STD_GNU = %w[-std=gnu89 -std=gnu99 -std=gnu11 -std=gnu17 -std=gnu18 -std=gnu23].freeze
PB_STD_C89 = %w[-ansi -std=c90 -std=iso9899:1990].freeze
PB_PP_FLAGS = %w[-D -U -I -include -isystem -idirafter].freeze
PB_PP_JOINED_PREFIXES = %w[-D -U -I -isystem -idirafter].freeze

def run_cmd(argv)
  $stdout.write("RUN #{argv.join(' ')}\n")
end

# nfcc's pathb_log: NFCXX_PATHB_LOG, when set, gets the line appended.
def pathb_log(env, message)
  return if env.pathb_log.nil? || env.pathb_log.empty?

  File.open(env.pathb_log, "ab") { |f| f.write("#{message}\n") }
end

# bash's ${x%.*}: the text before the last dot (the whole string when there is none).
def strip_ext(path)
  dot = path.rindex(".")
  dot.nil? ? path : path[0, dot]
end

# basename, then bash's ${base%.*}
def base_name_no_ext(path)
  strip_ext(File.basename(path))
end

# nfcc's pathb_reason: sets state.pb_opts and state.pb_std; returns the reason the unit cannot go to Path B, or "" when it can.
def pathb_reason(state, env, extra)
  state.pb_opts = []
  state.pb_std = "-std=c11"
  state.pb_gnu = 1
  return "#{state.needgcc.join(' ')}: not honoured by Path B" unless state.needgcc.empty?
  if state.pathb_pie == 1 && state.nofp == 1
    return "-fPIE with -mno-sse: Path B's data is absolute relocations a position-independent boot image cannot carry"
  end
  return "-mregparm=3 without -m16: not honoured by Path B" if state.pb_regparm == 1 && state.pb_m16 == 0
  if state.pb_m16 == 1
    state.pb_opts << "--i386" << "--m16" << "--ir-opt=none"
    state.pb_opts << "--regparm=3" unless state.pb_regparm == 0
  end
  state.asf.each do |o|
    split_wp_fields(o.byteslice(4, o.bytesize - 4)).each do |x|
      if PB_SIMPLE_ASM.include?(x)
        state.pb_opts << "--as-opt=#{x}"
      else
        return "#{o}: assembler option Path B does not pass on"
      end
    end
  end
  k2 = 0
  while k2 < state.pp.length
    o = state.pp[k2]
    if PB_PP_FLAGS.include?(o)
      state.pb_opts << o << state.pp[k2 + 1].to_s
      k2 += 1
    elsif PB_PP_JOINED_PREFIXES.any? { |f| o.start_with?(f) && o.length > f.length } || o == "-nostdinc"
      state.pb_opts << o
    elsif o.start_with?("-include") && o.length > 8
      state.pb_opts << "-include" << o[8..]
    elsif PB_STD_DIRECT.include?(o)
      state.pb_std = o
      state.pb_gnu = 0
    elsif PB_STD_GNU.include?(o)
      state.pb_std = "-std=c#{o[8..]}"
    elsif PB_STD_C89.include?(o)
      state.pb_std = "-std=c89"
      state.pb_gnu = 0
    elsif o == "-std=iso9899:2011"
      state.pb_std = "-std=c11"
      state.pb_gnu = 0
    else
      return "#{o}: not honoured by Path B"
    end
    k2 += 1
  end
  index = 0
  while index < extra.length
    state.pb_opts << "-I" << extra[index + 1]
    index += 2
  end
  state.pb_opts.unshift("-D_DEFAULT_SOURCE") if state.pb_gnu != 0
  state.pb_opts << "--pic" if state.pathb_pic != 0
  return "-fshort-wchar: a wide character or string literal" if state.wchar16 == 1 && env.wide_literal
  ""
end

# nfcc's pathb_compile: runs scripts/pathb-cc; with -S, the assembly is copied to obj (or written to stdout for -).
# Returns the status of scripts/pathb-cc (env.pathb_status, from the caller: the driver's real run has it from the tool).
def pathb_compile(state, env, what, csrc, obj)
  root_cc = "#{env.root}/scripts/pathb-cc"
  if what == "-S"
    keep = "#{env.tmp}/keep#{state.k}"
    run_cmd([root_cc, state.pb_std, *state.pbf, *state.pb_opts, csrc, "-o", "#{env.tmp}/pb#{state.k}.o"])
    if env.pathb_status == 0
      base = base_name_no_ext(csrc)
      if obj == "-"
        $stdout.write("CAT #{keep}/#{base}.s\n")
      else
        $stdout.write("CP #{keep}/#{base}.s #{obj}\n")
      end
    end
  else
    run_cmd([root_cc, state.pb_std, *state.pbf, *state.pb_opts, csrc, "-o", obj])
  end
  env.pathb_status
end

def gcc_argv(state, what, csrc, obj, extra)
  ["gcc", what, state.optlvl, *state.dbg, "-fwrapv", "-fno-strict-aliasing", *state.picf, *state.isa, *state.gccf,
   *state.pp, *state.asf, *extra, "-x", "c", csrc, "-o", obj]
end

# nfcc's compile_one KIND SOURCE OBJECT. Any kind other than "s" takes the C path (as the bash does for "o").
def compile_one(state, env, kind, src, obj)
  if kind == "s"
    xl = %w[assembler assembler-with-cpp].include?(state.lang) ? ["-x", state.lang] : []
    dep = []
    if !state.depmode.empty? && state.asm == 0
      df = state.dfile
      df = state.sawout == 1 ? "#{strip_ext(obj)}.d" : "#{base_name_no_ext(src)}.d" if df.empty?
      dep = [state.depmode, "-MF", df, *state.dts]
      dep << "-MP" unless state.dp == 0
    end
    if state.asm == 1
      die("-S: #{src} is assembly already") unless src.end_with?(".S") || state.lang == "assembler-with-cpp"

      run_cmd([env.host, "-S", *state.gccf, *state.pp, *xl, src, "-o", obj])
      return
    end
    run_cmd([env.host, "-c", *state.gccf, *dep, *state.pp, *state.asf, *xl, src, "-o", obj])
    return
  end

  csrc = src
  extra = []
  if src == "-"
    csrc = "#{env.tmp}/stdin#{state.k}.c"
  elsif !src.end_with?(".c")
    csrc = "#{env.tmp}/src#{state.k}.c"
    # realpath of an empty name fails with its own message (on stderr), and ln gets an empty target
    if src.empty?
      $stdout.flush
      $stderr.write("realpath: '': No such file or directory\n")
      real = ""
    else
      real = src.start_with?("/") ? src : "#{env.cwd}/#{src}"
    end
    run_cmd(["LN", "-s", real, csrc])
    extra = ["-iquote", File.dirname(src)]
  end
  state.k += 1
  unless state.depmode.empty?
    df = state.dfile
    tg = state.dts.dup
    opt = state.depmode == "-MMD" ? "-MM" : "-M"
    df = state.sawout == 1 ? "#{strip_ext(obj)}.d" : "#{base_name_no_ext(src)}.d" if df.empty?
    tg = ["-MT", obj] if tg.empty?
    unless src == "-"
      run_cmd([env.host, opt, "-MF", df, *tg, *(state.dp == 1 ? ["-MP"] : []), *state.gccf, *state.pp, *extra, "-x", "c", csrc])
    end
  end
  what = state.asm == 0 ? "-c" : "-S"
  if state.backend == "pathb"
    reason = pathb_reason(state, env, extra)
    if reason.empty?
      status = pathb_compile(state, env, what, csrc, obj)
      if status == 0
        pathb_log(env, "pathb #{src}")
        return
      end
      # a unit Path B refuses: gcc, when NFCXX_PATHB_FALLBACK=gcc; otherwise nfcc exits with that status
      raise PathbExit.new(status) unless env.pathb_fallback

      reason = "Path B refused it (status #{status})"
    end
    pathb_log(env, "gcc #{src}: #{reason}")
    run_cmd(gcc_argv(state, what, csrc, obj, extra))
  elsif state.backend == "cil"
    qcc = "#{env.root}/scripts/cil-cc"
    run_cmd([qcc, "--c-input", what, *state.kqf, *state.pp, *state.asf, *extra, csrc, "-o", obj])
  else
    run_cmd(gcc_argv(state, what, csrc, obj, extra))
  end
end

# The compile-only path: one object (or assembly) per input.
def compile_mode(state, env)
  suffix = state.asm == 0 ? ".o" : ".s"
  state.inputs.each do |entry|
    kind, src = entry.split(":", 2)
    obj = state.sawout == 1 ? state.out : "#{base_name_no_ext(src)}#{suffix}"
    compile_one(state, env, kind, src, obj)
  end
end

# The link path: compile the sources, keep the other inputs in command-line order, then link with the backend's link.
def link_mode(state, env)
  objs = []
  state.inputs.each do |entry|
    kind, src = entry.split(":", 2)
    if kind == "o"
      objs << src
    elsif kind == "c" || kind == "s"
      obj = "#{env.tmp}/obj#{state.k}.o"
      compile_one(state, env, kind, src, obj)
      objs << obj
    end
  end
  out = state.sawout == 1 ? state.out : "a.out"
  if state.backend == "pathb"
    if env.os == "Darwin"
      cxx_libs = ["-lc++"]
      atomic = []
    else
      cxx_libs = ["-lstdc++", "-lgcc_s"]
      atomic = ["-latomic"]
    end
    edg = env.edg_build || "#{env.root}/build/edg"
    run_cmd([env.host, *objs, *state.ld, "-o", out, env.ldrt, "-L#{edg}/lib", "-lC", *cxx_libs, "-lm", *atomic])
  elsif state.backend == "cil"
    qcc = "#{env.root}/scripts/cil-cc"
    run_cmd([qcc, *objs, *state.ld, "-o", out])
  else
    run_cmd(["gcc", *objs, *state.ld, "-o", out])
  end
end

# The leading --nfcc-* options carry what nfcc reads from its environment; nothing else starts with --nfcc-.
def take_config(argv)
  config = { backend: "gcc", passthrough: false, host_gnu_gcc: false, env: Env.new }
  env = config[:env]
  while argv.first && argv.first.start_with?("--nfcc-")
    option = argv.shift
    name, value = option.split("=", 2)
    value = "" if value.nil?
    flag = %w[--nfcc-passthrough --nfcc-host-gnu-gcc --nfcc-wide-literal --nfcc-pathb-fallback]
    die("#{name} takes 0 or 1") if flag.include?(name) && value != "0" && value != "1"
    case name
    when "--nfcc-backend" then config[:backend] = value
    when "--nfcc-passthrough" then config[:passthrough] = value == "1"
    when "--nfcc-host-gnu-gcc" then config[:host_gnu_gcc] = value == "1"
    when "--nfcc-root" then env.root = value
    when "--nfcc-tmp" then env.tmp = value
    when "--nfcc-cwd" then env.cwd = value
    when "--nfcc-os" then env.os = value
    when "--nfcc-ldrt" then env.ldrt = value
    when "--nfcc-edg-build" then env.edg_build = value
    when "--nfcc-wide-literal" then env.wide_literal = value == "1"
    when "--nfcc-pathb-status" then env.pathb_status = value.to_i
    when "--nfcc-host" then env.host = value
    when "--nfcc-pathb-log" then env.pathb_log = value
    when "--nfcc-dumpfullversion" then env.dumpfullversion = value
    when "--nfcc-bundle-tool" then env.bundle_tool = value
    when "--nfcc-cuda-home" then env.cuda_home = value
    when "--nfcc-cuda-driver-env" then env.cuda_driver_env = value
    when "--nfcc-cuda-h" then env.cuda_h = value == "1"
    when "--nfcc-cuda-header" then env.cuda_header = value == "1"
    when "--nfcc-cuda-typedefs" then env.cuda_typedefs = value == "1"
    when "--nfcc-cudart-version" then env.cudart_version = value.to_i
    when "--nfcc-lib64" then env.lib64 = value == "1"
    when "--nfcc-machine" then env.machine = value
    when "--nfcc-shim" then env.shim = value
    when "--nfcc-shim-error" then env.shim_error = value
    when "--nfcc-ninja-fails" then env.ninja_fails = value == "1"
    when "--nfcc-host-version-line" then env.host_version_line = value
    when "--nfcc-pathb-fallback" then env.pathb_fallback = value == "1"
    else die("unknown option #{name}")
    end
  end
  config
end

BUNDLE_LINK_OFF = %w[-c -E -S -M -MM -fsyntax-only --emit-c].freeze

# nfcc's bundle_wrap (scripts/bundle-wrap.sh): with no --bundle- option it changes nothing. Otherwise it runs the driver on the
# arguments without them, and for a link it runs the bundling tool (build/nfcbundle, built with ninja when it is missing or
# older than its source; the tool's state is an input here, see main). Returns nil when there is nothing to do.
def bundle_wrap(env, args)
  return nil unless (" " + args.join(" ") + " ").include?(" --bundle-")

  on = false
  link = true
  out = "a.out"
  prev = ""
  rest = []
  opts = []
  args.each do |a|
    out = a if prev == "-o"
    opts << "-L" << a if prev == "-L"
    if a == "--bundle-libs"
      on = true
    elsif a.start_with?("--bundle-exclude=") || a.start_with?("--bundle-only=") || a.start_with?("--bundle-add=")
      value = a[a.index("=") + 1..]
      split_wp_fields(value).each do |x|
        if a.start_with?("--bundle-exclude=") then opts << "--exclude" << x
        elsif a.start_with?("--bundle-add=") then opts << "--add" << x
        else opts << "--only" << x
        end
      end
    elsif a.start_with?("--bundle-stubs=")
      opts << "--stubs" << a[15..]
    elsif a.start_with?("--bundle-runpath=")
      opts << "--runpath" << a[17..]
    elsif a.start_with?("--bundle-rpath=")
      opts << "--rpath" << a[15..]
    elsif a.start_with?("--bundle-")
      raise BundleExit.new("nfcc: unknown option #{a} (--bundle-libs, --bundle-exclude=, --bundle-only=, --bundle-add=, --bundle-stubs=, --bundle-runpath=, --bundle-rpath=)", 2)
    else
      rest << a
      link = false if BUNDLE_LINK_OFF.include?(a)
      opts << "-L" << a[2..] if a.start_with?("-L") && a.length > 2
    end
    prev = a
  end
  raise BundleExit.new("nfcc: the --bundle-* options need --bundle-libs", 2) unless on

  run_cmd([env.root + "/nfcc", *rest])
  return 0 unless link

  tool = "#{env.root}/build/nfcbundle"
  if env.bundle_tool != "fresh"
    if env.ninja_fails
      raise BundleExit.new("nfcc: cannot build #{tool} (tools/bundle)", 1)
    end
  end
  # bash: exec "$tool" ... (the process is replaced: nothing after it runs)
  $stdout.write("EXEC #{[tool, *opts, out, "-o", out].join(' ')}\n")
  0
end

# nfcc's case on the library path: its lib64 (or targets/.../lib/stubs) directory's parent, or "" when neither pattern matches.
def cuda_home_from_library(found)
  if found.include?("/lib64/stubs/libcuda.so") || found.include?("/lib64/libcuda.so")
    return found[0, found.rindex("/lib64/")]
  end
  targets = found.index("/targets/")
  stubs = found.index("/lib/stubs/libcuda.so")
  if targets && stubs && targets < stubs
    return found[0, found.rindex("/lib/stubs/")]
  end
  ""
end

# The CUDART_VERSION of a header, as nfcc reads it: the first line "#define CUDART_VERSION <digits>" (sed -nE); 0 when none.
def cudart_version_of(path)
  return 0 unless File.file?(path)   # a missing header: the version is unknown (the bash's sed fails, and || rtv= takes it)
  text = File.open(path, "rb") { |io| io.read }
  text.split("\n").each do |line|
    next unless line.start_with?("#define")

    i = 7
    i += 1 while i < line.length && (line.getbyte(i) == 32 || line.getbyte(i) == 9)
    name = "CUDART_VERSION"
    next unless line[i, name.length] == name

    i += name.length
    j = i
    j += 1 while j < line.length && (line.getbyte(j) == 32 || line.getbyte(j) == 9)
    next if j == i

    k = j
    k += 1 while k < line.length && line.getbyte(k) >= 48 && line.getbyte(k) <= 57
    return line[j, k - j].to_i if k > j
  end
  0
end

def cuda_libcuda?(arg)
  %w[-lcuda -l:libcuda.so -l:libcuda.so.1].include?(arg) || arg.end_with?("/libcuda.so") || arg.end_with?("/libcuda.so.1")
end

# nfcc's cuda_driver_wrap (scripts/cuda-driver-wrap.sh). Returns [:args, list] when the driver goes on with list (its arguments
# without the --cuda-driver= options, which the wrapper drops from cuda_driver_args on every path), or [:exec, list], the
# arguments the driver is re-run with (the shim in place of libcuda). Raises CudaExit for a refusal.
def cuda_driver_wrap(env, args, driver_name)
  mode = env.cuda_driver_env
  found = ""
  static = ""
  args.each do |a|
    if a.start_with?("--cuda-driver=")
      mode = a[14..]
    elsif cuda_libcuda?(a)
      found = a
    elsif a == "-lcudart_static" || a.end_with?("/libcudart_static.a")
      static = a
    end
  end
  unless %w[auto cudart libcuda].include?(mode)
    raise CudaExit.new("#{driver_name}: --cuda-driver=#{mode}: auto, cudart or libcuda", 2)
  end
  kept = args.reject { |a| a.start_with?("--cuda-driver=") }
  return [:args, kept] if found.empty? || mode == "libcuda"

  home = env.cuda_home
  if home.empty?
    # nfcc: the home is the directory above the library's lib64 (or targets) directory, when it has include/cuda.h
    derived = cuda_home_from_library(found)
    home = !derived.empty? && File.file?("#{derived}/include/cuda.h") ? derived : "/usr/local/cuda"
  end
  # the version is read from cuda_runtime_api.h; a missing header leaves it unknown (the bash reads it with || rtv=)
  header = "#{home}/include/cuda_runtime_api.h"
  rtv = cudart_version_of(header)

  why = ""
  if env.machine != "x86_64"
    why = "the shim is x86-64 only"
  elsif !File.file?("#{home}/include/cuda.h") || !File.file?("#{home}/include/cudaTypedefs.h")
    why = "no cuda.h and cudaTypedefs.h in #{home}/include"
  elsif !File.file?(header)
    why = "no cuda_runtime_api.h in #{home}/include"
  elsif rtv == 0 || rtv < 12050
    rtv_text = rtv == 0 ? "of unknown version" : rtv.to_s
    why = "libcudart #{rtv_text} is older than 12.5"
  elsif env.shim_error
    why = "the shim did not build: #{env.shim_error}"
  end
  unless why.empty?
    raise CudaExit.new("#{driver_name}: --cuda-driver=cudart: #{why}", 1) if mode == "cudart"

    $stdout.flush
    $stderr.write("#{driver_name}: note: linking the CUDA driver library #{found} as named (#{why}; docs/notes/cuda-driver.md)\n")
    return [:args, kept]
  end

  shim = env.shim
  out = []
  done = false
  kept.each do |a|
    if cuda_libcuda?(a)
      next if done

      done = true
      out << shim
      if !static.empty?
        out << static
      else
        out << "-L#{home}/lib64" << "-Wl,-rpath,#{home}/lib64" if File.directory?("#{home}/lib64")
        out << "-lcudart"
      end
    else
      out << a
    end
  end
  [:exec, out]
end

def main(argv)
  config = take_config(argv)
  die("unknown NFCXX_BACKEND '#{config[:backend]}' (gcc, pathb or cil)") unless %w[cil gcc pathb].include?(config[:backend])
  args = expand_response_args(argv)
  # nfcc's bundle_wrap and cuda_driver_wrap: with no --bundle- option and no libcuda, they change nothing; the others run a
  # second driver or build a shim, which the port does not do.
  bundled = bundle_wrap(config[:env], args)
  return bundled unless bundled.nil?
  kind, list = cuda_driver_wrap(config[:env], args, "nfcc")
  if kind == :exec
    $stdout.write("EXEC #{(["#{config[:env].root}/nfcc"] + list).join(' ')}\n")
    return 0
  end
  args = list
  die("no input files") if args.empty?

  command = pre_loop_exec(args, config[:env].host, config[:backend], config[:env])
  if command && command[0] == :banner
    env = command[2]
    $stdout.write("nfcc (nfcxx C driver 0.1, backend #{command[1]}) #{env.dumpfullversion}\n")
    $stdout.write("gcc-compatible driver over Path B and gcc; the host compiler is #{env.host_version_line}\n")
    return 0
  end
  if command
    $stdout.write("EXEC #{command.join(' ')}\n")
    return 0
  end
  state = LoopState.new(config[:backend], config[:passthrough], config[:host_gnu_gcc])
  emit(run_loop(args, state))
  if state.mode == "compile"
    compile_mode(state, config[:env])
  else
    link_mode(state, config[:env])
  end
  0
rescue PathbExit => e
  $stdout.flush
  e.status
rescue CudaExit => e
  $stdout.flush
  $stderr.write("#{e.message}\n") unless e.message.empty?
  e.status
rescue BundleExit => e
  $stdout.flush
  $stderr.write("#{e.message}\n")
  e.status
rescue LoopDie => e
  $stdout.flush
  $stderr.write("nfcc: error: #{e.message}\n")
  1
rescue Unported => e
  $stdout.flush
  $stderr.write("unported: #{e.message}\n")
  3
end

rc = main(ARGV)
exit(rc) if rc != 0
