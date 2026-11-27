#!/usr/bin/env ruby
# nfcxx's Path B compile and link of hosted C and C++ sources, ported from the bash in nfcxx: the backend choice, the argument
# loop for the options of this slice, the -fsyntax-only rewrite, the -E exec, the scripts/pathb-cc.rb calls of a compile (C
# sources, then C++ files), the cp of a C-only -c, the link (one per source, then the cc link with EDG's runtime, the EH shim,
# the ASan VLA runtime and the safe-pointer runtime), and the fallback to the gcc backend that a default-selected Path B build
# takes when pathb-cc fails on a file. The argument loop is the one of nfcxx, for these options only (scripts/nfcxx-gcc-plan.rb
# has the same design for the gcc backend).
#
#   ruby scripts/nfcxx-pathb.rb --facts=FILE --backend=default|pathb -- ARG...
#   ruby scripts/nfcxx-pathb.rb --live=ROOT --tabs --checks --backend=default|pathb -- ARG...
#                                    --checks: the status rule of each pathb-cc is a CHECK line (the bash's own CHECK, which
#                                    scripts/nfcxx-run.rb applies), not an EXEC or an exit. Used by scripts/nfcxx.rb.
#   ruby scripts/nfcxx-pathb.rb --records [--shell] < STATE     the Path B -c route, planned from the driver's state (below)
#
# --records (the -c route, CompilePlan): the driver's own values, not the argv. STATE is the record stream of
# scripts/driver-state.rb (NUL-terminated: "k NAME" starts a group, each "v VALUE" adds one value; state_put writes it). Every
# group is sent, in any order; a scalar group has exactly one value (an empty one is ""), a list has any number. The groups:
#   root            ROOT: the repository (scripts/pathb-cc.rb and nfcxx are under it)
#   backend         the driver's backend: pathb (the route is Path B only; anything else is refused, exit 2)
#   default_backend 1 when the backend is the default (a failed compile is built again with gcc), 0 for --backend=pathb
#   compile_only    1 (-c); ncpp  the number of C++ sources (positive: the route is taken only with C++ sources)
#   outset          1 with -o; out  the -o value, or the one object's name (the driver sets it to <stem>.o without -o)
#   std             the driver's standard, as it is set (--c++23): pathb-cc gets -std=c++23
#   srcs            the C++ sources (the .cu inputs are their host copies), one per source
#   files           the driver's files list after the .cu copies replaced their inputs: the options (-I, -D, -U, -W, ...), the
#                   inputs and the link files; the planner compiles each input (not an option, .o, .a or .so)
#   cflags          -I, -D and -U options (as pathb-cc gets them)
#   pb_flags        the options scripts/pathb-cc.rb gets (--sanitize=, --safe-pointers, --ir-opt=, --asan, --pic, diagnostics)
#   pb_pre          -include FILE pairs, as the driver builds them from preinc
#   cuda_opts       the options of a .cu input's host copy (--cuda, ...), from the CUDA device state
#   modules         1 when a source declares or imports a module (the driver's module scan), else 0
#   modopts         the module options the driver's plan gives (nfcxx-modopts.rb: --modules and the directory); they go on
#                   each compile when modules is 1, and must be empty otherwise
#   nfcxx_argv      the command as the driver got it: the gcc fallback re-runs the driver with it
#   cache_entry     the compile cache's entry name, "" when the cache does not apply (the driver's cache_check sets it)
# Output: the RUN and CHECK lines of the compiles, then a STORE line when the cache stores the object (cache_entry, one source).
# A CHECK line is the rule for the status of the compile before it (the driver evaluates it after each RUN):
#   CHECK exit                          a nonzero status ends the driver with that status
#   CHECK gcc BEFORE AFTER ARG...       a nonzero status: the driver prints BEFORE, the status, AFTER (on standard error), then
#                                       runs ARG... (exec env NFCXX_BACKEND=gcc ROOT/nfcxx ARGS: the program built again with gcc)
# The default backend takes the gcc form and an explicit --backend=pathb the exit form (the bash's rule, in the planner). The
# text output is one line per record, its words tab-separated, with the kind first; --shell prints the plan as the statements
# nfcxx_plan_state=PLAN, nfcxx_plan_kinds=(KIND...), nfcxx_plan_nwords=(N...) and nfcxx_plan_words=(WORD...), every value escaped
# with Shellwords (the driver evals it: nfcxx_plan_nwords counts the words of each line after its kind).
# A state the bash never has (a missing group, a value count that is not one for a scalar, backend not pathb) exits 2.
#
# --backend is the backend the driver is asked for: default (no --backend and no NFCXX_BACKEND: the driver picks Path B, and
# a file Path B fails on makes the driver build the program again with gcc), or pathb (--backend=pathb: the status of
# pathb-cc is the driver's status). gcc is scripts/nfcxx-gcc-plan.rb's, and is refused here. ARG... is the command line
# the bash gets, without --backend (an --backend in ARG... is refused).
#
# prints the commands the bash runs for ARG..., one per line, then "STATUS n" (the status the bash ends with):
#   RUN PROGRAM ARG...     a program the driver runs: ROOT/scripts/pathb-cc.rb (one source to an object), cp (a C-only -c) or
#                          cc (the link)
#   EXEC PROGRAM ARG...    the driver is replaced: the gcc fallback (exec env NFCXX_BACKEND=gcc ROOT/nfcxx ARG...), or the
#                          -E preprocess (exec g++ -E ...). The bash does not return from it, so no STATUS line follows; the
#                          status is the program's, not compared.
# ROOT stands for the repository and WORK for the working directory. The temporary directory of a compile or link is TMP
# (mktemp -d): the C objects TMP/N.o, the C++ objects of a link TMP/pN.o, and the -fsyntax-only object TMP/x.o. A refusal the
# bash makes (status 2, a pathb-cc status under --backend=pathb) prints the lines before it, then its status. A construct the
# port does not cover exits 3 with "unported: ..." on stderr and prints nothing (nothing is guessed).
#
# -fsyntax-only is the bash's own rewrite, not a plan of its own: its arguments are the compile of "-c ARGS -o TMP/x.o" (the
# -o value is replaced by TMP/x.o), or the -E path when -E is given. The port plans that command line.
#
# Modelled, with the bash's order of the lines: C sources (-c, and a link with C++ or alone), -E (exec g++ -E), -fsyntax-only,
# -fsanitize=address (--asan on the compile, the ASan link options, the VLA runtime), -fsanitize=CHECKS (--sanitize=CHECKS
# on each compile; the names the bash implements), -fsafe-pointers (--safe-pointers, the runtime ahead of the objects),
# -shared (--pic and -shared on the link; the default backend takes gcc for it), the depfile options -MP, -MF, -MT, -MQ
# with -c, and -MD and -MMD with -c and an explicit --backend=pathb (the bash writes no depfile on
# the Path B compile: its -c path returns before the depfile). --cache and --cache-log have no plan line of their own (the
# cache and the Path B paths return before the cache). --keep-intermediates, --pathb-c and --obfuscate-kernels have none
# either: the bash reads them on the EDG and CUDA paths only.
#
# Not covered (exit 3): the gcc backend (the default with -shared, or with -MD or -MMD and no -fsafe-pointers, and the
# --backend=gcc choice); .cu and .cpp2 inputs (CUDA and cppfront: the rewriter, the device units and the prelinker) and the
# CUDA options; C++ modules; SYCL (a -I directory with the oneAPI kernel header); --freestanding, --cosmo, --target, --emit-c,
# --emit-hip, --bundle-libs, --cuda-driver, --keep-intermediates, and any other --option (--instantiate=auto|used,
# --promote-slots, --unroll, --struct-slots and --module-dir are read and planned as no line: see parse); -M and
# -MM and the other -M options that are not the depfile family (the bash passes -M and -MM on to cc or drops them, while its
# header comment says -M takes the gcc backend: the two disagree, so the port does not choose); -MD with -c of a file -fsafe-
# and -MMD with the default backend and no -fsafe-pointers (the default takes gcc for them); -c with no C++ or C source; -x
# with a language other than c++; --trace and --time-log with C sources, a link of object files only, or -E with --trace (the
# bash's spans for those are not modelled here). --trace and --time-log on C++ compiles and links are modelled: the plan has
# TRACE and TIMELOG lines, and START and SPAN (SPANF for a pathb-cc span) around the driver's steps, in the bash's order (the
# host C++ headers, the EH shim and the ASan VLA runtime of a link, then each Path B compile and the link), which
# scripts/nfcxx-run.rb records. A -c compile records only the host C++ headers span: the bash's compiles have no span of their own.
# A -fsanitize= name the bash does not implement, and -fsanitize-* and -fno-sanitize=NAME, exit 2 (the bash's refusal).
#
# FILE holds the facts the bash reads from the machine and from its helper scripts (tests/nfcxx-pathb/run.sh writes it):
#   host linux-x86_64          the host is x86-64 Linux (the link libraries and the QBE target are that host's)
#   eccp 1|0                   ROOT/build/edg/bin/eccp is executable (the bash checks it for a C++ input or an object link)
#   qbe 1|0                    ROOT/build/qbe/qbe is executable (the bash checks it for the Path B backend)
#   libc-a 1|0                 ROOT/build/edg/lib/libC.a exists (the link names it; the port refuses a link without it)
#   pathb-ldrt PATH            scripts/pathb-ldrt.rb prints PATH (the long double helper archive)
#   ehshim PATH                scripts/ehshim.rb prints PATH (absent or empty: it prints nothing, so the link has no EH shim)
#   asan-vla PATH              scripts/asan-vla.rb prints PATH (the C++ VLA runtime of an ASan link; absent: the port refuses)
#   safeptr-rt PATH            scripts/safeptr-rt.rb prints PATH (the safe-pointer runtime of a link; absent: the port refuses)
#   ld NAME                    ld.NAME is on PATH (for -fuse-ld=NAME; the other names pass to cc as they are)
#   module PATH                PATH declares or imports a C++ module (the bash reads the source; not ported)
#   exists PATH                PATH (relative to WORK) exists (the SYCL pre-pass test reads an -I directory's header)
#   pathb-status PATH CODE     scripts/pathb-cc.rb exits with CODE on the source PATH (absent: 0)
#
# Read from the environment: NFCXX_LD and NFCXX_DIALECT (PLAN_ENV: the defaults the bash sets before its arguments).
# Assumed, not read: the environment (other NFCXX_* variables are not read: the harness runs the bash with none), the
# repository tools (ensure_tool finds them fresh), the build of pathb-cc itself (its harness is inside pathb-cc: its status
# is the pathb-status fact), and the host GNU version and dialect (only an explicit --dialect reaches the command line).

require "open3"
require "pathname"
require "shellwords"
require_relative "driver-state"
require_relative "nfcxx-objname"

# A construct the port does not cover (exit 3): the bash may do anything with it, so nothing is guessed.
class NfcxxUnported < StandardError
end

# The bash ends with this status: a refusal it makes, or a pathb-cc status it passes on. The lines before it are printed.
class NfcxxExit < StandardError
  attr_reader :status

  def initialize(message, status)
    super(message)
    @status = status
  end
end

# A refusal the bash makes before it runs anything (the sanitizer options): with --tabs it is printed by the caller, which
# exits 2 without the bash (scripts/nfcxx.rb), so it prints no plan line.
class NfcxxRefusal < NfcxxExit
end

# The bash replaces itself (the gcc fallback, or the -E preprocess): the EXEC line is the last line of the plan.
class PlanExec < StandardError
end

DRIVER = "ROOT/nfcxx".freeze
PATHB_CC = "ROOT/scripts/pathb-cc.rb".freeze
LIBC = "ROOT/build/edg/lib/libC.a".freeze
# --profile (docs/notes/profiler.md, "Path B"): the program's functions call the hooks (pathb-cc.rb --profile). The profiler
# runtime (lib/prof) is compiled as C without the hooks, so its own functions are not instrumented, and linked with the program;
# the program's global functions go into the dynamic symbol table (-rdynamic), and malloc, calloc, realloc and free are wrapped.
PROF_RT = %w[nfcxx_prof.c nfcxx_prof_cyg.c nfcxx_machine.c nfcxx_alloc.c].freeze
PROF_WRAP = "-Wl,--wrap=malloc,--wrap=calloc,--wrap=realloc,--wrap=free".freeze
CHOICES = %w[default pathb gcc].freeze
# the environment variables the plan reads (the bash's defaults for the linker and the dialect): their values are the facts'
PLAN_ENV = %w[NFCXX_LD NFCXX_DIALECT].freeze
# the -fsanitize= checks the bash implements (its sanitize block; docs/notes/ubsan.md)
SANITIZE_CHECKS = %w[undefined signed-integer-overflow integer-divide-by-zero shift bounds null unreachable return
                     float-cast-overflow].freeze
FSO_OBJECT = "TMP/x.o".freeze # the object of -fsyntax-only (its temporary directory's x.o)

def unported(what)
  raise NfcxxUnported, what
end

def exit_with(message, status)
  raise NfcxxExit.new(message, status)
end

def refuse(message)
  raise NfcxxRefusal.new(message, 2)
end

# The -fsyntax-only rewrite of nfcxx (the first loop of the script): with -E, the arguments without -fsyntax-only; otherwise
# "-c" then the arguments without -fsyntax-only, with the -o value (or a -o FILE added) pointing at the temporary object.
def fsyntax_only_args(args)
  return args unless args.include?("-fsyntax-only")

  base = args.reject { |a| a == "-fsyntax-only" }
  return base if base.include?("-E")

  return ["-c", *base, "-o", FSO_OBJECT] unless base.include?("-o")

  new_args = []
  skip = false
  base.each do |b|
    if skip
      new_args << FSO_OBJECT
      skip = false
      next
    end
    skip = true if b == "-o"
    new_args << b
  end
  unported("-fsyntax-only with a -o and no file") if skip
  ["-c", *new_args]
end

# The facts the bash reads from the machine (see the header).
class Facts
  attr_reader :lds, :modules, :exists, :statuses

  def initialize
    @values = {}
    @lds = []
    @modules = []
    @exists = []
    @statuses = {}
  end

  def self.load(path)
    facts = new
    File.foreach(path) do |line|
      line = line.chomp
      next if line.empty? || line.start_with?("#")

      key, rest = line.split(" ", 2)
      rest = rest.to_s
      case key
      when "ld" then facts.lds << rest
      when "module" then facts.modules << rest
      when "exists" then facts.exists << rest
      when "pathb-status"
        name, code = rest.split(" ", 2)
        facts.statuses[name] = code.to_i
      else facts.set(key, rest)
      end
    end
    facts
  end

  def set(key, value)
    @values[key] = value
  end

  def value(key)
    @values[key]
  end

  # an environment variable the plan reads (NFCXX_LD, NFCXX_DIALECT): nil when unset, or when the facts have none
  def env_value(_name)
    nil
  end

  def flag?(key)
    @values[key] == "1"
  end

  def ld?(name)
    @lds.include?(name)
  end

  def module?(path)
    @modules.include?(path)
  end

  def exists?(path)
    @exists.include?(path)
  end

  # a source the plan may compile (the test facts list the sources they use: true there)
  def source_ok?(_path)
    true
  end

  def status(name)
    @statuses.fetch(name, 0)
  end
end

class Plan
  attr_reader :lines

  def initialize(facts, choice, args, checks: false)
    @facts = facts
    @choice = choice
    @args = args
    @checks = checks  # --checks: each pathb-cc status is a CHECK line for the runner (see check_status)
    @lines = []
    @files = []    # the bash's files: link options, objects, C++ sources, and -c (in order); not C sources
    @cflags = []   # -I, -D, -U (joined), for pathb-cc and the -E preprocess
    @preinc = []   # -include FILE
    @srcs = []     # C++ sources (in order)
    @cfiles = []   # C sources (in order)
    @c_objs = []   # the C objects of this plan (TMP/N.o)
    @sysdirs = []  # -isystem DIR (for the -E preprocess only)
    @ppflags = []  # -P (for the -E preprocess only)
    @diag = []     # EDG diagnostic options (-Wno-narrowing)
    @ncpp = 0
    @nobj = 0
    @stdin_src = false
    @compile_only = false
    @outset = false
    @out = "a.out"
    @std = "23"
    @xlang = ""
    @pic = false
    @shared = false
    @rdynamic = false
    @preprocess = false
    @asan = false
    @asanopts = []
    @safeptr = false
    @sanitize = nil # the -fsanitize= checks (a comma list), "" after -fno-sanitize=all
    @depmode = nil
    @ir_opt = nil
    @vec_pb = nil # -ftree-vectorize / -fno-tree-vectorize (the last): pathb-cc.rb --vectorize / --no-vectorize
    @vec_assoc = false # -fassociative-math (the last): pathb-cc.rb --vectorize-assoc
    @dialect = "g++"
    @dialect_asked = false
    @gnu_user = nil
    @ld_name = nil
    @eh_shim = true
    @default_backend = false
    @profile = false  # --profile: the Path B hooks, the runtime and the wrapped allocation functions
    @trace = nil      # --trace=FILE (the last one; "" is off, as the bash's trace= is)
    @time_log = nil   # --time-log=FILE (the last one; "" is off)
    # the environment first (the arguments after it override it, as in the bash): NFCXX_DIALECT (non-empty: asked for), NFCXX_LD
    env_dialect = facts.env_value("NFCXX_DIALECT")
    if env_dialect && !env_dialect.empty?
      @dialect = env_dialect
      @dialect_asked = true
    end
    env_ld = facts.env_value("NFCXX_LD")
    @ld_name = env_ld unless env_ld.nil? || env_ld.empty?
  end

  def run
    parse
    exit_with("nfcxx: no input files", 2) if @ncpp + @nobj + @cfiles.size + (@stdin_src ? 1 : 0) == 0
    (@srcs + @cfiles).each { |s| unported("source #{s} is not a file (the bash reports it)") unless @facts.source_ok?(s) }
    unported("-E with --trace (the bash writes the trace file before its exec)") if @preprocess && trace_file
    preprocess_exec if @preprocess
    checks
    @pb_pre = @preinc.flat_map { |h| ["-include", h] }
    @pb_flags = pb_flags
    trace_setup
    compile_c_files
    if @compile_only
      if @ncpp.zero?
        cp_c_objects
      else
        compile_path
      end
    else
      link_path
    end
  end

  private

  def parse
    i = 0
    while i < @args.size
      x = @args[i]
      nxt = @args[i + 1]
      if x.start_with?("--backend=")
        unported("--backend in the arguments: the backend is the port's --backend")
      elsif x.start_with?("--ir-opt=")
        @ir_opt = x.delete_prefix("--ir-opt=")
      elsif x == "--eh-unwind" || x == "--no-eh-unwind"
        nil # with the gcc backend only (the EDG C side); Path B does not read it
      elsif x == "--no-eh-shim"
        @eh_shim = false
      elsif x == "--nfcxx-cuda-unit"
        @cuda_unit = true # the source is the host copy of a .cu input (scripts/nfcxx-cuda-live.rb): the bash passes --cuda
      elsif x == "--keep-intermediates" || x == "--obfuscate-kernels" || x.start_with?("--pathb-c=")
        nil # the bash reads these on the EDG and CUDA paths only (the Path B routes here never read them)
      elsif x.start_with?("--time-log=")
        @time_log = x.delete_prefix("--time-log=")
      elsif x.start_with?("--trace=")
        @trace = x.delete_prefix("--trace=")
      elsif x.start_with?("--cache=", "--cache-log=")
        nil # no plan line: the cache is not reached by the Path B paths
      elsif x.start_with?("--dialect=")
        @dialect = x.delete_prefix("--dialect=")
        @dialect_asked = true
      elsif x.start_with?("--gnu-version=")
        @gnu_user = x.delete_prefix("--gnu-version=")
      elsif x.start_with?("--instantiate=")
        # EDG's instantiation (the eccp calls of the gcc backend): Path B makes no such call
        value = x.delete_prefix("--instantiate=")
        exit_with("nfcxx: --instantiate (NFCXX_INSTANTIATE) is auto or used (got #{value})", 2) unless %w[auto used].include?(value)
      elsif x.start_with?("--promote-slots=", "--unroll=", "--struct-slots=")
        # CUDA device code only (not in a hosted plan): the value is checked as the argument loop checks it
        flag, value = x.split("=", 2)
        exit_with("nfcxx: #{flag} takes on or off (got '#{value}')", 2) unless %w[on 1 off 0].include?(value)
      elsif x.start_with?("--module-dir=")
        nil # the directory of module files: a module source is refused by checks
      elsif x == "--profile"
        @profile = true # the Path B hooks, the profiler runtime and the allocation wraps (profile_runtime_objects)
      elsif x.start_with?("--")
        unported(x)
      elsif x.start_with?("-fuse-ld=")
        name = x.delete_prefix("-fuse-ld=")
        if @facts.ld?(name)
          @ld_name = name
        else
          @files << x
        end
      elsif x == "-fsanitize=address"
        @asan = true
      elsif x == "-fno-sanitize=address"
        @asan = false
      elsif x == "-fsafe-pointers"
        @safeptr = true
      elsif x == "-fno-safe-pointers"
        @safeptr = false
      elsif x == "-fno-sanitize=all"
        @sanitize = ""
      elsif x.start_with?("-fsanitize=")
        # the bash joins the values in order (sanitize=${sanitize:+$sanitize,}VALUE) and checks each name after the loop
        value = x.delete_prefix("-fsanitize=")
        @sanitize = @sanitize.to_s.empty? ? value : "#{@sanitize},#{value}"
      elsif x.start_with?("-fsanitize-")
        refuse("nfcxx: #{x} is not supported (only -fsanitize=address; docs/notes/asan.md)")
      elsif x.start_with?("-fno-sanitize=")
        refuse("nfcxx: #{x} is not supported (only -fsanitize=undefined and its checks, docs/notes/ubsan.md)")
      elsif x == "-fno-omit-frame-pointer" || x == "-fomit-frame-pointer"
        @asanopts << x
      elsif x == "-fPIC" || x == "-fpic"
        @pic = true
      elsif x == "-rdynamic"
        @rdynamic = true
      elsif x == "-shared"
        @shared = true
        @pic = true
      elsif x == "-c"
        @compile_only = true
        @files << x
      elsif x == "-o"
        unported("-o with no file") if nxt.nil?
        @out = nxt
        @outset = true
        i += 1
      elsif x.start_with?("-std=c++")
        @std = x.delete_prefix("-std=c++")
      elsif x.start_with?("-std=gnu++")
        @std = x.delete_prefix("-std=gnu++")
      elsif x == "-E"
        @preprocess = true
      elsif x == "-P"
        @ppflags << x
      elsif x == "-x"
        unported("-x with no language") if nxt.nil?
        @xlang = nxt
        i += 1
      elsif x == "-"
        @stdin_src = true
      elsif %w[-pthread -fexceptions -fwrapv -fno-strict-aliasing -pipe -fvisibility-inlines-hidden
               -fPIE -fpie -pie].include?(x) || x.start_with?("-fvisibility=")
        nil # EDG always lowers exceptions; the others reach only the gcc or EDG link, not pathb-cc
      elsif x.start_with?("-Wl,")
        @files << x
      elsif x.start_with?("-l") && x.size > 2
        @files << x
      elsif x == "-Wno-narrowing"
        @diag << "--diag_warning=narrowing_conversion"
      elsif x.match?(/\A-g(gdb)?[0-3]?\z/)
        @files << x
        @dbg_g = x # also pathb-cc.rb -g: the object's line table (pb_flags)
      elsif x.start_with?("-W") || x == "-w"
        nil # warnings do not change the object code
      elsif x == "-ftree-vectorize" || x == "-fno-tree-vectorize"
        @vec_pb = x == "-ftree-vectorize" ? "--vectorize" : "--no-vectorize"
      elsif x == "-fassociative-math" || x == "-fno-associative-math"
        # the vectorizer may reassociate float sums (pathb-cc.rb --vectorize-assoc, qbe -F); off by default
        @vec_assoc = x == "-fassociative-math"
      elsif x.start_with?("-m")
        nil # ISA options: their macros go to the bash's files list and are skipped there, and -fPIC-style picopts are gcc-only
      elsif x == "-MD" || x == "-MMD"
        @depmode = x
      elsif x == "-MP"
        nil # the phony targets of the depfile the bash writes for -MD or -MMD only
      elsif x == "-MF" || x == "-MT" || x == "-MQ"
        unported("#{x} with no file") if nxt.nil?
        i += 1
      elsif x.start_with?("-M")
        unported("#{x} (dependency options the port does not model)")
      elsif x == "-include"
        unported("-include with no file") if nxt.nil?
        @preinc << nxt
        i += 1
      elsif x == "-isystem"
        unported("-isystem with no directory") if nxt.nil?
        @sysdirs << nxt
        i += 1
      elsif x.start_with?("-isystem")
        @sysdirs << x.delete_prefix("-isystem")
      elsif x.end_with?(".c")
        @cfiles << x
      elsif (x.start_with?("-I") || x.start_with?("-D") || x.start_with?("-U")) && x.size > 2
        @cflags << x
        @files << x
      elsif x == "-I" || x == "-D" || x == "-U"
        exit_with("nfcxx: #{x} needs an argument", 2) if nxt.nil?
        @cflags << (x + nxt)
        @files << (x + nxt)
        i += 1
      elsif x.end_with?(".o")
        @files << x
        @nobj += 1
      elsif x.start_with?("-") || x.end_with?(".a") || x.end_with?(".so")
        @files << x
      elsif x.end_with?(".cu") || x.end_with?(".cpp2")
        unported("#{x} (CUDA or cppfront input)")
      else
        @files << x
        @ncpp += 1
        @srcs << x
      end
      i += 1
    end
  end

  # The backend choice of the bash: default (Path B unless -shared or a depfile is asked for), or pathb. -fsafe-pointers takes
  # Path B whatever the choice. A default-selected build may fall back to gcc on a failure; the other Path B builds may not.
  def default_selected?
    @choice == "default" && !@shared && @depmode.nil?
  end

  # The checks the bash makes before the Path B section, in its order (only those that can print or end the plan).
  def checks
    exit_with("nfcxx: a source on stdin is supported only with -E", 2) if @stdin_src
    exit_with("nfcxx: -x #{@xlang}: only C++ sources (use nfcc for C)", 2) unless ["", "c++", "none"].include?(@xlang)
    exit_with("nfcxx: #{@depmode} needs -c (dependency files are written for a compile only)", 2) if @depmode && !@compile_only
    if (@ncpp.positive? || (@nobj.positive? && @cfiles.empty?)) && !@facts.flag?("eccp")
      exit_with("nfcxx: EDG not built; run scripts/setup-edg.sh", 2)
    end
    exit_with("nfcxx: unknown dialect '#{@dialect}'", 2) if @dialect_asked && !%w[g++ clang].include?(@dialect)
    # NFCXX_LD (the arguments' -fuse-ld= is checked when it is read): the linker must be on PATH
    exit_with("nfcxx: NFCXX_LD=#{@ld_name}: ld.#{@ld_name} is not on PATH", 2) if @ld_name && !@facts.ld?(@ld_name)
    @srcs.each { |s| unported("C++ module source #{s}") if @facts.module?(s) }
    if @compile_only && @ncpp == 1 && @nobj.zero? && @cfiles.empty? && sycl_kernel_headers?
      unported("SYCL pre-pass (an -I directory has sycl/detail/kernel_desc.hpp)")
    end
    unported("-c with no C++ or C source (the bash links the objects with -c ignored)") if @compile_only && @ncpp.zero? && @cfiles.empty?
    unported("the gcc backend (scripts/nfcxx-gcc-plan.rb)") if @choice == "gcc"
    unported("the gcc backend: the default is gcc for -shared and for -MD or -MMD (scripts/nfcxx-gcc-plan.rb)") unless
      @choice == "pathb" || @safeptr || default_selected?
    @default_backend = @choice == "default" && default_selected?
    # each check is named as the bash names it (sanitize=, split on commas; a trailing comma is no check)
    unless @sanitize.to_s.empty?
      checks = @sanitize.split(",", -1)
      checks.pop if @sanitize.end_with?(",")
      bad = checks.find { |c| !SANITIZE_CHECKS.include?(c) }
      refuse("nfcxx: -fsanitize=#{bad} is not supported (implemented: #{SANITIZE_CHECKS.join(", ")})") if bad
    end
    refuse("nfcxx: -fsafe-pointers and -fsanitize=address both replace malloc; use one") if @asan && @safeptr
    unported("host is not x86-64 Linux") unless @facts.value("host") == "linux-x86_64"
    exit_with("nfcxx: QBE not built; run scripts/setup-qbe.sh", 2) unless @facts.flag?("qbe")
  end

  # The SYCL test of the bash: an -I directory of the arguments holds sycl/detail/kernel_desc.hpp.
  def sycl_kernel_headers?
    prev = nil
    @args.each do |a|
      d = nil
      d = a.delete_prefix("-I") if a.start_with?("-I") && a.size > 2
      d = a if prev == "-I"
      prev = a
      next if d.nil? || d.empty?
      return true if @facts.exists?(Pathname.new(d).join("sycl/detail/kernel_desc.hpp").cleanpath.to_s)
    end
    false
  end

  # The -E exec of the bash: g++ preprocesses with the options in its order (-std, -x, -P, the -I/-D/-U, -isystem, -include,
  # the sources, - for stdin, -o). The C sources are not in it (the bash keeps them out of its source list).
  def preprocess_exec
    argv = ["-E", "-std=c++#{@std}"]
    argv += ["-x", @xlang] unless @xlang.empty?
    argv += @ppflags
    argv += @cflags
    argv += @sysdirs.map { |d| "-isystem#{d}" }
    argv += @preinc.flat_map { |h| ["-include", h] }
    argv += @srcs
    argv << "-" if @stdin_src
    argv += ["-o", @out] if @outset
    @lines << ["EXEC", "g++", *argv]
    raise PlanExec
  end

  # The options scripts/pathb-cc.rb gets, in the order the bash appends them (pb_flags): --sanitize, --safe-pointers, --ir-opt,
  # --asan (Path B only), --pic, -g, --vectorize / --no-vectorize, the EDG diagnostic options, --dialect=clang (only when asked), --gnu-version.
  def pb_flags
    f = []
    f << "--sanitize=#{@sanitize}" unless @sanitize.to_s.empty?
    f << "--safe-pointers" if @safeptr
    f << "--ir-opt=#{@ir_opt}" unless @ir_opt.nil?
    f << "--asan" if @asan
    f << "--profile" if @profile
    f << "--pic" if @pic
    f << "-g" if @dbg_g && !%w[-g0 -ggdb0].include?(@dbg_g) # -g (the last, unless -g0): the line table
    f << @vec_pb if @vec_pb
    f << "--vectorize-assoc" if @vec_assoc
    f.concat(@diag)
    f << "--dialect=clang" if @dialect == "clang" && @dialect_asked
    f << "--gnu-version=#{@gnu_user}" if @gnu_user && !@gnu_user.empty?
    f
  end

  # One pathb-cc call on a C++ source; returns its status (the pathb-status fact).
  def pathb_cc(source, dst)
    cuda = @cuda_unit ? ["--cuda"] : []   # cuda_opts of the bash: the host copy of a .cu input is compiled with --cuda
    argv = [PATHB_CC, *@pb_flags, "-std=c++#{@std}", *@cflags, *@pb_pre, *cuda, source, "-o", dst]
    @lines << ["RUN", *argv]
    @facts.status(source)
  end

  # A non-zero pathb-cc status: under the default backend the driver builds the program again with gcc (the EXEC line);
  # an explicit --backend=pathb ends with that status. With --checks the rule is a CHECK line instead, which the runner
  # applies to the status it gets (scripts/nfcxx-run.rb): the bash's own rule, the same words as its CHECK.
  def check_status(source, status)
    if @checks
      @lines << check_line(source)
      return
    end
    return if status.zero?
    exit_with("nfcxx: pathb-cc status #{status} on #{source}", status) unless @default_backend
    warn "nfcxx: Path B did not build #{source} (status #{status}); building the program with the gcc backend, which " \
         "compiles with C semantics (-fwrapv -fno-strict-aliasing)"
    @lines << ["EXEC", "env", "NFCXX_BACKEND=gcc", DRIVER, *@args]
    raise PlanExec
  end

  # The CHECK line of a compile (--checks): the default backend builds the program again with gcc, the explicit one exits with
  # the compile's status. The message and the command are the bash's (its C and C++ branches print the same words).
  def check_line(source)
    if @default_backend
      ["CHECK", "gcc", "nfcxx: Path B did not build #{source} (status ",
       "); building the program with the gcc backend, which compiles with C semantics (-fwrapv -fno-strict-aliasing)",
       "env", "NFCXX_BACKEND=gcc", DRIVER, *@args]
    else
      ["CHECK", "exit"]
    end
  end

  # The C sources, each to an object TMP/N.o (N counts the C sources), with the C options of the bash: no -fwrapv, no -include.
  # Before the C++ files, as the bash does.
  def compile_c_files
    @cfiles.each_with_index do |c, n|
      dst = "TMP/#{n}.o"
      argv = [PATHB_CC, *@pb_flags, "-std=c11", *@cflags, c, "-o", dst]
      @lines << ["RUN", *argv]
      check_status(c, @facts.status(c))
      @c_objs << dst
    end
  end

  # A C-only -c: the objects are the output, each copied to -o FILE (one source only) or to basename.o.
  def cp_c_objects
    exit_with("nfcxx: -c with -o needs exactly one source", 2) if @outset && @c_objs.size != 1
    @cfiles.each_with_index do |c, i|
      dst = @outset ? @out : "#{File.basename(c).sub(/\.c\z/, '')}.o"
      @lines << ["RUN", "cp", @c_objs[i], dst]
    end
  end

  # -c: one object per C++ file, named as the bash names it (basename without its last suffix, .o; -o names the one object).
  def compile_path
    @files.each do |x|
      next if x.start_with?("-") || x.end_with?(".o", ".a", ".so")

      dst = @outset ? @out : "#{File.basename(x).sub(/\.[^.]*\z/, '')}.o"
      check_status(x, pathb_cc(x, dst))
    end
  end

  # --trace and --time-log: the bash's values ("" is off)
  def trace_file
    @trace.to_s.empty? ? nil : @trace
  end

  def time_log_file
    @time_log.to_s.empty? ? nil : @time_log
  end

  def tracing?
    !trace_file.nil? || !time_log_file.nil?
  end

  # the unit of the time log's lines (the bash's trace_unit): the first C++ source, else the output
  def trace_unit
    @srcs.first || @out
  end

  # A span of the driver's steps: START, the lines of the block, then SPAN (SPANF: recorded also when the block's command
  # failed, as the bash's trace_end after a pathb-cc status it passes on). The block runs as it does without a trace.
  def traced(name, category, kind: "SPAN")
    return yield unless tracing?

    @lines << ["START", "t"]
    result = yield
    @lines << [kind, "t", name, category, trace_unit]
    result
  end

  # The trace file and the time log are set first, then the host C++ headers span (the first step of a hosted route). The
  # shapes are the ones whose spans are modelled: C++ compiles and links, with no C source and no link of objects only.
  def trace_setup
    return unless tracing?

    unported("C sources with --trace or --time-log (the bash's spans for them are not modelled)") unless @cfiles.empty?
    unported("a link of object files only with --trace or --time-log") unless @compile_only || @ncpp.positive?
    if trace_file && !File.directory?(File.dirname(File.expand_path(trace_file)))
      unported("#{trace_file}: its directory does not exist (the bash reports it)")
    end
    @lines << ["TIMELOG", time_log_file] if time_log_file
    @lines << ["TRACE", trace_file, trace_unit] if trace_file
    traced("host C++ headers", "driver") { nil }
  end

  # The options of the link's cc: -shared (a shared object), -rdynamic, -fuse-ld=NAME, in the bash's order.
  def ldopts
    o = []
    o << "-shared" if @shared
    o << "-rdynamic" if @rdynamic || @profile
    o << "-fuse-ld=#{@ld_name}" if @ld_name
    o
  end

  # The options of every C compile and link of an ASan program (the bash's asan_c), for the link's cc.
  def asan_c
    return [] unless @asan

    ["-fsanitize=address", "-fno-omit-frame-pointer", *@asanopts]
  end

  def fact_path(key)
    v = @facts.value(key)
    unported("scripts/#{key} printed no path") if v.nil? || v.empty?
    v
  end

  # The link's cc (the bash's hosted block): the EH shim and the sret objects, and with -fsanitize=address the C++ VLA runtime.
  # Neither is added to a -shared link or a link with no C++ or object input (the block is not entered).
  def hosted_extras
    return [[], []] if @shared

    shim = []
    eh = @facts.value("ehshim")
    shim << eh if @eh_shim && eh && !eh.empty?
    vla = @asan ? [fact_path("asan-vla")] : []
    [shim, vla]
  end

  # A link: each C++ file to a temporary object (TMP/pN.o), then cc with the objects and the link options, EDG's runtime
  # (libC.a) ahead of the host C++ library, as the bash links them. Before the compiles, the facts the link names are read: a
  # missing one is unported here (the bash would fail the link after the compiles, or before them).
  def link_path
    if @ncpp.zero? && (@nobj.zero? || !@facts.flag?("eccp"))
      return c_only_link
    end

    unported("#{LIBC} does not exist") unless @facts.flag?("libc-a")
    ldrt = fact_path("pathb-ldrt")
    shim, vla = hosted_extras
    rt = profile_runtime_objects
    # the driver's EH shim step, and its ASan VLA step, come before the compiles (not in a -shared link)
    unless @shared
      traced("EH shim", "driver") { nil }
      traced("VLA runtime (asan)", "driver") { nil } if @asan
    end
    sprt = @safeptr ? [fact_path("safeptr-rt"), "-pthread"] : []
    pobjs = []
    plink = []
    n = 0
    @files.each do |x|
      next if x.start_with?("-I", "-D", "-U")

      if x.start_with?("-") || x.end_with?(".o", ".a", ".so")
        plink.concat(link_option(x))
      else
        o = "TMP/p#{n}.o"
        n += 1
        status = traced("Path B: #{x}", "pathb", kind: "SPANF") { pathb_cc(x, o) }
        check_status(x, status)
        pobjs << o
      end
    end
    argv = ["cc", *asan_c, *ldopts, "-o", @out, *sprt, *@c_objs, *rt, *pobjs, *plink, ldrt, *shim, *vla,
            LIBC, "-lstdc++", "-lgcc_s", "-lpthread", "-lm", "-latomic"]
    traced("link", "pathb") { @lines << ["RUN", *argv] }
  end

  # --profile: the profiler runtime, each source compiled as C with the pb_flags but without --profile (its own functions are not
  # instrumented), to TMP/rN.o. The wrapped allocation functions are a link option (PROF_WRAP, added to the files here).
  def profile_runtime_objects
    return [] unless @profile

    @files << PROF_WRAP unless @files.include?(PROF_WRAP)
    PROF_RT.each_with_index.map do |c, n|
      dst = "TMP/r#{n}.o"
      # NFCXX_PROF_NO_TSC: the clock is CLOCK_MONOTONIC (the SSA route has no rdtsc; see nfcxx_prof.c)
      argv = [PATHB_CC, *@pb_flags.reject { |f| f == "--profile" }, "-std=c11", "-DNFCXX_PROF_NO_TSC=1", "-I", "ROOT/lib/prof",
              "ROOT/lib/prof/#{c}", "-o", dst]
      @lines << ["RUN", *argv]
      check_status(c, @facts.status(c))
      dst
    end
  end

  # A link argument as it goes to cc: the CUB archive (scripts/cuda-cub.rb's path, when it has one) goes before the -lcudart it
  # needs, as the other link routes place it. A shared link has no CUB archive.
  def link_option(x)
    return [x] unless x == "-lcudart" && !@shared

    cub = @facts.value("cuda-cub").to_s
    cub.empty? ? [x] : [cub, x]
  end

  # The link of C sources alone (or with object files when eccp is not built): cc with the C objects, every link option of the
  # command line (the -I, -D and -U options too), the VLA runtime of an ASan link, EDG's runtime and the host C++ library.
  def c_only_link
    unported("#{LIBC} does not exist") unless @facts.flag?("libc-a")
    ldrt = fact_path("pathb-ldrt")
    cvla = @asan ? [fact_path("asan-vla")] : []
    rt = profile_runtime_objects
    files = @files.flat_map { |x| link_option(x) }
    argv = ["cc", *asan_c, *ldopts, *@c_objs, *rt, *files, *cvla, "-o", @out, ldrt, LIBC, "-lstdc++", "-lm", "-latomic"]
    @lines << ["RUN", *argv]
  end
end

# A --records state the driver never sends (a missing group, a scalar without one value, the backend not pathb): exit 2.
class StateRefusal < StandardError
end

# The -c route's plan (the header's --records): one pathb-cc call per C++ input of the files list, each followed by its CHECK,
# then the cache's STORE. The values are the driver's own (its state_put groups): no argument is parsed here.
class CompilePlan
  attr_reader :lines

  def initialize(groups)
    @groups = groups
    @lines = []
  end

  def run
    refuse("backend #{scalar("backend")}: the -c plan is for the Path B route") unless scalar("backend") == "pathb"
    refuse("the -c plan is for -c with a C++ source") unless scalar("compile_only") == "1" && scalar("ncpp").to_i.positive?
    modules = scalar("modules")
    refuse("modules is #{modules}: 0 or 1") unless %w[0 1].include?(modules)
    refuse("modopts without modules") if modules == "0" && !list("modopts").empty?
    list("files").each do |f|
      next if f.start_with?("-") || f.end_with?(".o", ".a", ".so")

      dst = scalar("outset") == "1" ? scalar("out") : NfcxxObjname.object_name(f).to_s
      @lines << ["RUN", "#{root}/scripts/pathb-cc.rb", *list("pb_flags"), "-std=c++#{scalar("std").delete_prefix("--c++")}",
                 *list("cflags"), *list("pb_pre"), *list("cuda_opts"), *module_opts, f, "-o", dst]
      check(f)
    end
    @lines << ["STORE", scalar("out")] if !scalar("cache_entry").empty? && list("srcs").size == 1
  end

  private

  def root
    scalar("root")
  end

  # the module options of the compile: the driver's modopts when the module scan found a module (else none)
  def module_opts
    scalar("modules") == "1" ? list("modopts") : []
  end

  # the rule for the status of the compile before it (see the header): the default backend builds the program again with gcc,
  # an explicit --backend=pathb ends with the status
  def check(file)
    if scalar("default_backend") == "1"
      @lines << ["CHECK", "gcc", "nfcxx: Path B did not build #{file} (status ",
                 "); building the program with the gcc backend, which compiles with C semantics (-fwrapv -fno-strict-aliasing)",
                 "env", "NFCXX_BACKEND=gcc", "#{root}/nfcxx", *list("nfcxx_argv")]
    else
      @lines << ["CHECK", "exit"]
    end
  end

  # the one value of a scalar group (a state the driver never sends is refused)
  def scalar(name)
    values = list(name)
    refuse("group #{name} needs one value") unless values.size == 1
    values[0]
  end

  # the values of a group (a missing group is refused)
  def list(name)
    @groups.fetch(name) { refuse("group #{name} is missing") }
  end

  def refuse(message)
    raise StateRefusal, message
  end
end

# The --records mode: the state on standard input, the plan on standard output (tab-separated, or with --shell as statements).
def records_main(argv)
  shell = argv == ["--shell"]
  unless argv.empty? || shell
    warn "usage: nfcxx-pathb.rb --records [--shell] < STATE"
    return 2
  end
  plan = CompilePlan.new(DriverState.read_groups($stdin.binmode.read))
  plan.run
  if shell
    emit_compile_shell(plan.lines)
  else
    plan.lines.each { |l| puts l.join("\t") }
  end
  0
rescue StateRefusal, ArgumentError => e
  warn "nfcxx-pathb: #{e.message}"
  2
end

# the --shell output of the records plan (the gcc plan's form): the kinds, the word counts and the words, Shellwords-escaped
def emit_compile_shell(lines)
  words = lines.flat_map { |fields| fields.drop(1) }
  puts "nfcxx_plan_state=PLAN"
  puts "nfcxx_plan_kinds=(#{lines.map { |fields| Shellwords.escape(fields.first) }.join(" ")})"
  puts "nfcxx_plan_nwords=(#{lines.map { |fields| fields.size - 1 }.join(" ")})"
  puts "nfcxx_plan_words=(#{words.map { |w| Shellwords.escape(w) }.join(" ")})"
end

# The facts of this machine (--live=ROOT): each one is probed when the port asks for it, with the commands the bash runs.
# Path B's status is not a fact here: every pathb-cc call is planned as succeeding, and the driver (scripts/nfcxx.rb) builds the
# program again with the bash when one fails. Anything the live facts do not model is unported.
class LiveFacts < Facts
  def initialize(root, cwd)
    super()
    @root = root
    @cwd = cwd
    @probes = {}
    ENV.each_key do |name|
      next if PLAN_ENV.include?(name)
      next unless (name.start_with?("NFCXX_") && name != "NFCXX_DRIVER_TRACE") ||
                  %w[CUDA_HOME EDG_BUILD EDG_CPFE_DEFAULT_OPTIONS EDG_OBJ_TO_EXEC_DEFAULT_OPTIONS].include?(name)

      unported("environment #{name} (the live facts do not read it)")
    end
  end

  def env_value(name)
    ENV[name] if PLAN_ENV.include?(name)
  end

  def real(path)
    return @root if path == "ROOT"
    return File.join(@root, path[5..]) if path.start_with?("ROOT/")
    return path if path.start_with?("/")

    File.join(@cwd, path)
  end

  def value(key)
    @probes.fetch(key) { @probes[key] = probe(key) }
  end

  def flag?(key)
    value(key) == "1"
  end

  def ld?(name)
    ENV.fetch("PATH", "").split(":").any? do |d|
      f = File.join(d, "ld.#{name}")
      File.file?(f) && File.executable?(f)
    end
  end

  def module?(path)
    f = real(path)
    return false unless File.file?(f)

    File.foreach(f, mode: "rb").any? { |l| l.match?(/\A[[:space:]]*(export[[:space:]]+)?(module|import)[[:space:]]+[A-Za-z_<"]/n) }
  end

  def exists?(path)
    File.exist?(real(path))
  end

  def source_ok?(path)
    File.file?(real(path))
  end

  def status(_name)
    0
  end

  private

  def probe(key)
    case key
    when "host" then `uname -s`.chomp == "Linux" && `uname -m`.chomp == "x86_64" ? "linux-x86_64" : "other"
    when "eccp" then File.executable?(File.join(@root, "build/edg/bin/eccp")) ? "1" : "0"
    when "qbe" then File.executable?(File.join(@root, "build/qbe/qbe")) ? "1" : "0"
    when "libc-a" then File.file?(File.join(@root, "build/edg/lib/libC.a")) ? "1" : "0"
    when "pathb-ldrt" then script_output("scripts/pathb-ldrt.rb", require_success: true)
    # a harness with exception tables (eh-tables beside its cpfe, scripts/setup-pathb.sh) links libstdc++'s EH runtime: no shim
    when "ehshim" then pathb_eh_tables? ? "" : script_output("scripts/ehshim.rb", require_success: true)
    when "asan-vla" then script_output("scripts/asan-vla.rb", require_success: true)
    when "safeptr-rt" then script_output("scripts/safeptr-rt.rb", require_success: false)
    when "cuda-cub" then script_output("scripts/cuda-cub.rb", require_success: true)   # the CUB archive, or no path (no line)
    else unported("#{key} is not in the live facts")
    end
  end

  def pathb_eh_tables?
    cpfe = ENV["PATHB_CPFE"].to_s.empty? ? File.join(@root, "build/pathb/cmake/bin/cpfe") : ENV["PATHB_CPFE"]
    File.file?(File.join(File.dirname(cpfe), "eh-tables"))
  end

  def script_output(script, require_success:)
    out, status = Open3.capture2(File.join(@root, script), err: File::NULL)
    return nil if require_success && !status.success?

    out.chomp
  rescue SystemCallError
    nil
  end
end

def main(argv)
  return records_main(argv.drop(1)) if argv.first == "--records"

  facts_path = nil
  choice = "default"
  tabs = false
  checks = false
  live = nil
  i = 0
  while i < argv.size && argv[i] != "--"
    a = argv[i]
    if a.start_with?("--facts=")
      facts_path = a.delete_prefix("--facts=")
    elsif a.start_with?("--live=")
      live = a.delete_prefix("--live=")
    elsif a == "--tabs"
      tabs = true
    elsif a == "--checks"
      checks = true
    elsif a.start_with?("--backend=")
      choice = a.delete_prefix("--backend=")
    else
      warn "usage: nfcxx-pathb.rb --facts=FILE --backend=default|pathb -- ARG..."
      return 2
    end
    i += 1
  end
  args = argv[(i + 1)..] || []
  unless (facts_path || live) && CHOICES.include?(choice)
    warn "usage: nfcxx-pathb.rb --facts=FILE --backend=default|pathb -- ARG..."
    return 2
  end

  begin
    facts = live ? LiveFacts.new(live, Dir.pwd) : Facts.load(facts_path)
    plan = Plan.new(facts, choice, fsyntax_only_args(args), checks: checks)
    plan.run
    plan.lines.each { |l| puts(tabs ? l.join("\t") : l.join(" ")) }
    puts "STATUS 0" unless tabs
  rescue PlanExec
    plan.lines.each { |l| puts(tabs ? l.join("\t") : l.join(" ")) }
  rescue NfcxxExit => e
    # a refusal before any plan line: the caller prints the message and exits with its status (no bash)
    if tabs && e.is_a?(NfcxxRefusal)
      warn e.message
      return e.status
    end
    plan.lines.each { |l| puts(tabs ? l.join("\t") : l.join(" ")) }
    warn e.message unless e.message.empty?
    puts "STATUS #{e.status}" unless tabs
  rescue NfcxxUnported => e
    warn "unported: #{e.message}"
    return 3
  end
  0
end

exit main(ARGV) if $PROGRAM_NAME == __FILE__
