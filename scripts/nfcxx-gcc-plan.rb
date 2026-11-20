#!/usr/bin/env ruby
# nfcxx's gcc-backend compile and link dispatch, ported from the bash in nfcxx: the setup after the argument loop (the
# isa, asan and sanitize options, the host headers, the EH shim and VLA runtime of a link), the C inputs (gcc), the link
# of C-only programs, and the EDG driver call (eccp) that compiles and links C++ sources, plus the -E preprocess and the
# -MD dependency step that follows the eccp call. The argument loop is the one of scripts/nfcxx-loop.rb, copied here for the
# options in this slice (nfcxx-loop.rb is a script with a main, so it is not required).
#
#   ruby scripts/nfcxx-gcc-plan.rb --facts=FILE ARG...   the facts of a file (the tests)
#   ruby scripts/nfcxx-gcc-plan.rb --live=ROOT ARG...    the facts of this machine (tabs: --tabs first, for a plan file)
#   ruby scripts/nfcxx-gcc-plan.rb --shell --live=ROOT ARG...   the plan as shell statements a bash driver evals (below)
#
# The exit status is the bash's: 0 or the status the bash ends with (2 for a refusal), or 3 for UNPORTED: the plan does not
# cover these arguments or this environment, so the bash goes on by itself (the contract of this port: nothing is planned,
# nothing runs, and the reason is on stderr as "unported: ...").
#
# prints the commands the bash runs for ARG..., one per line, then "STATUS n" (the exit status the bash ends with):
#   RUN PROGRAM ARG...     a program the driver runs (gcc, g++, cp's CP below, the EDG driver as ROOT/build/edg/bin/eccp, the
#                          helpers ruby ROOT/scripts/nfcxx-link.rb ...)
#   EXEC PROGRAM ARG...    the program replaces nfcxx (-E: exec g++ -E)
#   CP SRC DST             a copy (the objects of a C-only -c)
#   ENV NAME=VALUE         a variable the bash exports, for the programs that follow (EDG_CPFE_DEFAULT_OPTIONS for the GNU or
#                          clang version, EDG_OBJ_TO_EXEC_DEFAULT_OPTIONS for -shared)
#   CD DIR                 the next RUN runs in DIR (the bash's eccp subshell, cd'ed to its temporary directory on a link)
#   NOTE TEXT              a line for standard error, in order (the --keep-intermediates note of the kept directory)
#   CHECK PROGRAM ARG...   the cache lookup (scripts/nfcxx-cache-check.rb check, with --statements=TMP/cc): status 10 is a hit
#                          that was copied back, and the driver ends with 0; status 0 sets the cache entry from the statements
#                          file; any other status leaves the cache off
#   STORE PROGRAM ARG...   the cache store (scripts/nfcxx-cache-check.rb store, --entry=ENTRY): run only when the lookup set an
#                          entry (the bash's cache_store)
#   EXIT PROGRAM ARG...    the command of a link's exit trap (scripts/nfcxx-link.rb cleanup): run when the driver exits, however
#                          it exits (the bash's eccp_cleanup); its words are the last line of the plan
#
# The substitution contract (--shell only; the default form prints the names in brackets): every word holds placeholders, each
# a whole token that the driver replaces, with bash parameter expansion, as nfcxx's fso_argv does for @@NFCXX_FSO_TMP@@:
#   @@NFCXX_ROOT@@    the repository (the driver's $root)                       ROOT
#   @@NFCXX_WORK@@    the working directory (the driver's $PWD)                 WORK
#   @@NFCXX_TMP@@     a temporary directory the driver makes with mktemp -d     TMP (C objects, the -fsyntax-only object, cc)
#   @@NFCXX_ECCP@@    the directory eccp runs in (a link), made the same way    TMP (kept on exit with --keep-intermediates)
#   @@NFCXX_RUBY@@    ${RUBY:-ruby}                                            ruby
#   @@NFCXX_ENTRY@@   the cache entry the lookup set (cache_entry)              ENTRY
# nfcxx_plan_uses=(TMP ECCP) names the temporary directories the plan uses (each made once, removed on exit: TMP always, ECCP
# unless nfcxx_plan_keep=1). The real paths of abs_path are in the words already (a link's include names are resolved here).
# An argument list outside the gcc backend (Path B by default, cosmo, the CUDA inputs, a cache lookup, modules, cppfront,
# freestanding, ...) exits 3 with "unported: ..." on stderr and prints nothing. A refusal the bash makes (status 2) prints
# the lines before it, then its status.
#
# Modelled here: -fsyntax-only (the re-run as -c -o TMP/x.o, as nfcxx-loop.rb's
# syntax_only_plan has it; -E execs g++ -E), --cuda-driver= and a link that names libcuda (the re-run of
# scripts/wrap.rb, or its note, or its error), and --cache=DIR for every compile and link of the gcc route: the lookup (CHECK)
# and the store (STORE) are commands of the plan, and the key is the lookup's own (scripts/nfcxx-cache-check.rb), so nothing
# of the key is planned here. --keep-intermediates: the note (NOTE) and the kept directory (nfcxx_plan_keep).
#
# --shell (the driver's form): the same plan as shell statements, every value escaped with Shellwords, for the driver to eval:
#   nfcxx_plan_state=PLAN           the plan follows (the state is UNPORTED alone when the plan is unported: exit 3)
#   nfcxx_plan_status=N             the exit status the bash ends with (0, or 2 for a refusal, with the lines before it)
#   nfcxx_plan_keep=0|1             --keep-intermediates: the ECCP directory is kept on exit
#   nfcxx_plan_uses=(NAME...)       the temporary directories the plan uses (TMP, ECCP: see the placeholders above)
#   nfcxx_plan_kinds=(KIND...)      one per command: RUN, EXEC, CP, ENV, CD, NOTE, CHECK, STORE or EXIT (the kinds as above)
#   nfcxx_plan_nwords=(N...)        the number of words of each command, the program and its arguments (ENV: one word)
#   nfcxx_plan_words=(WORD...)      the words of all the commands, in order (the command i takes nwords[i] of them)
# An UNPORTED plan prints only "nfcxx_plan_state=UNPORTED" on standard output (and exits 3), so an eval never reads an empty
# plan as "nothing to run". Joining a command's kind and words with spaces gives its line in the default form.
#
# FILE holds the facts the bash reads from the machine and from its helper scripts (tests/nfcxx-gcc/run.sh writes it):
#   host-sys DIR            a directory of the host C++ library, in host_sys_includes' order
#   isa FLAG NAME VALUE     a macro that the -m option FLAG adds (the difference of gcc -dM with and without FLAG)
#   ld NAME                 ld.NAME is on PATH (for -fuse-ld=NAME)
#   exists PATH             PATH (relative to WORK) is an existing file or directory (abs_path and -e tests)
#   module PATH             PATH declares or imports a C++ module (the module check reads the source; not ported)
#   cxx-clang 0|1           the host C++ compiler (g++) is clang
#   cc-clang 0|1            the C compiler (cc) is clang
#   ehshim PATH             scripts/ehshim.rb prints PATH (absent: it prints nothing)
#   asan-vla PATH           scripts/asan-vla.rb prints PATH (absent: it fails)
#   eh-tls 1                ${EDG}/../eh-tls exists
#   dir PATH                PATH (relative to WORK) is an existing directory (the exists lines cover files and directories)
#   machine M               uname -m
#   env NAME VALUE          the environment variable NAME is VALUE (only NFCXX_LD, NFCXX_DIALECT, NFCXX_BACKEND=gcc, as above)
#   cuda-home PATH          CUDA_HOME is PATH (no line: CUDA_HOME is unset)
#   cuda-cub PATH           scripts/cuda-cub.rb prints PATH (no line: it prints nothing and fails)
#   cuda-shim PATH          scripts/cuda-driver-shim.rb prints PATH (the shim's archive)
#   cuda-shim-error TEXT    scripts/cuda-driver-shim.rb fails with TEXT (takes precedence over cuda-shim)
#   cuda-rtv PATH N         the header PATH has "#define CUDART_VERSION N"
#   cuda-file, cuda-dir     run.sh makes these in the work directory; the port reads the exists and dir lines instead
#
# Read from the environment: NFCXX_LD, NFCXX_DIALECT (PLAN_ENV: the defaults the bash sets before its arguments) and
# NFCXX_BACKEND=gcc (the backend the bash takes as given, not as an explicit --backend=). An env line of the facts file
# gives the same variables to the port, and the harness gives them to the bash. Any other NFCXX_* variable is unported.
# Assumed, not read: the environment (other NFCXX_* variables: the harness runs the bash with none, and CUDA_HOME only as
# the cuda-home fact), the SYCL pre-pass (it needs a sycl include in the source), the existence of eccp and of the
# built repository tools (ensure_tool finds them fresh, so no ninja run), and the host GNU version (not used by this path).
# A CUDA toolkit that is /usr/local/cuda (CUDA_HOME unset, and the libcuda path does not name a toolkit with cuda.h) is
# not read: unported.

require "open3"
require "pathname"
require "shellwords"
require_relative "nfcxx-linkargs"
require_relative "nfcxx-depmode"

class NfcxxUnported < StandardError
end

# the bash ends here with status 0 (after a copy the -c of C sources makes, or the link of a C-only program)
class PlanDone < StandardError
end

class NfcxxExit < StandardError
  attr_reader :status

  def initialize(message, status)
    super(message)
    @status = status
  end
end

# The placeholders of a plan (the substitution contract, see the --shell form above). Each is a whole token, so the driver
# replaces it with a bash parameter expansion, as nfcxx's fso_argv does with @@NFCXX_FSO_TMP@@.
ROOT = "@@NFCXX_ROOT@@".freeze        # the repository: the driver's $root
CWD = "@@NFCXX_WORK@@".freeze        # the working directory: the driver's $PWD
TMP = "@@NFCXX_TMP@@".freeze         # a mktemp -d the driver makes for the plan (C objects, the -fsyntax-only object, the statements)
ECCP_DIR = "@@NFCXX_ECCP@@".freeze   # the mktemp -d eccp runs in (a link); kept with --keep-intermediates
RUBY_PROG = "@@NFCXX_RUBY@@".freeze  # ${RUBY:-ruby}
ENTRY = "@@NFCXX_ENTRY@@".freeze     # the cache entry a lookup set (cache_entry), for the store
# the words of the plan's default form show these names for the placeholders (the tests compare with them)
DISPLAY = { ROOT => "ROOT", CWD => "WORK", TMP => "TMP", ECCP_DIR => "TMP", RUBY_PROG => "ruby", ENTRY => "ENTRY" }.freeze
ECCP = "#{ROOT}/build/edg/bin/eccp".freeze
LIBC = "#{ROOT}/build/edg/lib/libC.a".freeze
EH_UNWIND_HEADER = "#{ROOT}/lib/ehshim/nfcxx_eh_unwind.h".freeze
NLINK = "#{ROOT}/scripts/nfcxx-link.rb".freeze
NCACHE = "#{ROOT}/scripts/nfcxx-cache-check.rb".freeze

# The facts the bash reads from the machine (see the header).
class Facts
  attr_reader :host_sys, :isa, :ld, :exists, :modules, :dirs

  def initialize
    @host_sys = []
    @isa = []
    @ld = []
    @exists = []
    @modules = []
    @dirs = []
    @rtv = {}
    @values = {}
    @env = {}
  end

  def self.load(path)
    facts = new
    File.foreach(path) do |line|
      line = line.chomp
      next if line.empty? || line.start_with?("#")

      key, rest = line.split(" ", 2)
      rest = rest.to_s
      case key
      when "host-sys" then facts.host_sys << rest
      when "isa"
        flag, name, value = rest.split(" ", 3)
        facts.isa << [flag, name, value.to_s]
      when "ld" then facts.ld << rest
      when "exists" then facts.exists << rest
      when "module" then facts.modules << rest
      when "dir" then facts.dirs << rest
      when "cuda-rtv"
        path, version = rest.split(" ", 2)
        facts.cuda_rtv_set(path, version)
      when "cuda-file", "cuda-dir" then nil
      when "env"
        name, value = rest.split(" ", 2)
        unported("environment #{name} (the facts' env line)") if env_refused?(name, value.to_s)
        facts.env_set(name, value.to_s)
      else facts.set(key, rest)
      end
    end
    facts
  end

  def env_set(name, value)
    @env[name] = value
  end

  def set(key, value)
    @values[key] = value
  end

  def value(key)
    @values[key]
  end

  # an environment variable the plan reads (PLAN_ENV, NFCXX_BACKEND): nil when unset, or when the facts have no env line for it
  def env_value(name)
    @env[name]
  end

  def host_sys
    @host_sys
  end

  def flag?(key)
    value(key) == "1"
  end

  # the working directory as the plan names it (the placeholder, for the words of the plan)
  def cwd_name
    CWD
  end

  # the working directory as the cache key reads it (the bash's $PWD): "WORK" for a facts file
  def real_cwd
    "WORK"
  end

  # the real directory of DIR (realpath in the bash's abs_path): the work directory's placeholder for a relative name
  def real_dir(dir)
    normalize(dir.start_with?("/") ? dir : File.join(CWD, dir))
  end

  # ld.NAME is on PATH (the -fuse-ld= names)
  def ld_available?(name)
    @ld.include?(name)
  end

  # the facts' sources that declare or import a module (the port does not plan those)
  def module_source?(path)
    @modules.include?(path)
  end

  # a source the plan may compile: a file (the facts of a file list the sources the tests use, so this is true there)
  def source_ok?(_path)
    true
  end

  # the isa macros of the -m options FLAGS (the facts list one entry per flag and macro)
  def isa_for(flags)
    @isa.select { |flag, _, _| flags.include?(flag) }
  end

  def exists?(path)
    @exists.include?(path)
  end

  # a regular file (the bash's -f): it exists and is not a directory
  def file?(path)
    exists?(path) && !@dirs.include?(path)
  end

  def dir?(path)
    @dirs.include?(path)
  end

  def cuda_rtv_set(path, version)
    @rtv[path] = version
  end

  # the CUDART_VERSION of the header at PATH (nil when the header has no such line)
  def cuda_rtv(path)
    @rtv[path]
  end
end

# The facts read from this machine, for the repository (--live=ROOT): each fact is probed when the port asks for it, with
# the commands the bash runs. A fact the live facts do not model is unported, never guessed: the CUDA toolkit and shim,
# more than one -m option, a macro with arguments, a module source (the bash's grammar is read, but a module is not
# planned), and NFCXX_* (but NFCXX_LD, NFCXX_DIALECT and NFCXX_BACKEND=gcc) or CUDA_HOME in the environment (the port does
# not read them; the bash does).
class LiveFacts < Facts
  def initialize(root, cwd)
    super()
    @root = root
    @cwd = cwd
    @probes = {}
    @host_sys = nil  # computed on first use (Facts sets an empty list)
    ENV.each do |name, value|
      unported("environment #{name} (the live facts do not read it)") if env_refused?(name, value)
    end
    # the bash builds these on first use (ensure_tool); the live facts do not build anything
    unported("the EDG front end is not built (build/edg/bin/eccp)") unless File.executable?(File.join(root, "build/edg/bin/eccp"))
    unported("the C++ runtime is not built (build/edg/lib/libC.a)") unless File.file?(File.join(root, "build/edg/lib/libC.a"))
  end

  def cwd_name
    CWD
  end

  # the bash's $PWD (a logical name, as the bash keeps it): the cache key takes it
  def real_cwd
    ENV.fetch("PWD", @cwd)
  end

  # realpath of DIR: the physical name the bash's abs_path gives (a relative name is in the working directory; a placeholder
  # names the repository)
  def real_dir(dir)
    File.realpath(real(dir))
  end

  # cuda-cub PATH: scripts/cuda-cub.rb's output (built when stale), as the bash's $(cuda-cub). A failure is no value, so the
  # link goes without the archive (the bash's behaviour). Read on demand: only a link that names -lcudart asks for it.
  def value(key)
    return super unless key == "cuda-cub"

    out, status = Open3.capture2(File.join(@root, "scripts", "cuda-cub.rb"))
    status.success? ? out.chomp : nil
  rescue SystemCallError
    nil
  end

  # the file a plan path names on this machine: ROOT is the repository, a relative path is in the working directory
  def real(path)
    return @root if path == ROOT
    return File.join(@root, path[(ROOT.size + 1)..]) if path.start_with?("#{ROOT}/")
    return path if path.start_with?("/")

    File.join(@cwd, path)
  end

  def exists?(path)
    File.exist?(real(path))
  end

  def file?(path)
    File.file?(real(path))
  end

  def dir?(path)
    File.directory?(real(path))
  end

  def source_ok?(path)
    File.file?(real(path))
  end

  def ld_available?(name)
    ENV.fetch("PATH", "").split(":").any? do |d|
      f = File.join(d, "ld.#{name}")
      File.file?(f) && File.executable?(f)
    end
  end

  def module_source?(path)
    f = real(path)
    return false unless File.file?(f)

    File.foreach(f, mode: "rb").any? { |l| l.match?(/\A[[:space:]]*(export[[:space:]]+)?(module|import)[[:space:]]+[A-Za-z_<"]/n) }
  end

  # the host C++ library directories of g++, as host_sys_includes (scripts/host-sys.rb) prints them
  def host_sys
    @host_sys ||= begin
      _out, err, _status = Open3.capture3("g++", "-E", "-x", "c++", "-v", "-", stdin_data: "")
      dirs = []
      on = false
      err.each_line do |l|
        if l.include?("search starts here:") then on = true
        elsif l.include?("End of search list") then on = false
        elsif on && !l.include?("framework directory")
          dirs << (l.start_with?(" ") ? l.sub(/\A +/, "").chomp : l.chomp)
        end
      end
      dirs
    end
  end

  def isa_for(flags)
    return [] if flags.empty?

    unported("more than one -m option (the live facts take one at a time)") if flags.size > 1
    new_macros = macro_lines(flags) - macro_lines([])
    new_macros.map do |line|
      unported("a macro with arguments (#{line})") if line.match?(/\A#define [^ ]*\(/)
      m = line.match(/\A#define (\S+) ?(.*)\z/) or unported("a macro line the live facts do not read (#{line})")
      [flags.first, m[1], m[2]]
    end
  end

  def value(key)
    @probes.fetch(key) { @probes[key] = probe(key) }
  end

  def env_value(name)
    ENV[name] if PLAN_ENV.include?(name)
  end

  def cuda_rtv(_path)
    unported("the CUDA toolkit is not in the live facts")
  end

  private

  def probe(key)
    case key
    when "cxx-clang" then clang?("g++") ? "1" : "0"
    when "cc-clang" then clang?("cc") ? "1" : "0"
    when "eh-tls" then File.file?(File.join(@root, "build", "edg", "eh-tls")) ? "1" : nil
    when "ehshim" then script_output("scripts/ehshim.rb", require_success: true)
    when "asan-vla" then script_output("scripts/asan-vla.rb", require_success: true)
    when "machine" then Open3.capture2("uname", "-m", err: File::NULL).first.chomp
    when "cuda-home" then nil
    when "gnu-version" then host_gnu_version
    when "clang-version" then host_clang_version
    else unported("#{key} is not in the live facts")
    end
  end

  # host_gnu_version (scripts/host-sys.rb): major*10000 + minor*100 + patch from g++ -dumpfullversion; Apple clang, which has
  # no -dumpfullversion, reports 150000
  def host_gnu_version
    ver, = Open3.capture2("g++", "-dumpfullversion", err: File::NULL)
    ver = ver.to_s.chomp
    return "150000" if ver.empty? && clang?("g++")
    return nil if ver.empty?

    maj, min, pat = ver.split(".")
    (maj.to_i * 10000 + min.to_i * 100 + pat.to_i).to_s
  rescue SystemCallError
    nil
  end

  # host_clang_version (scripts/host-sys.rb): the version of the host clang as major*10000 + minor*100 + patch, at most 200000
  def host_clang_version
    out, = Open3.capture2("g++", "--version", err: File::NULL)
    m = out.lines.first.to_s.match(/version ([0-9][0-9.]*)/)
    return nil unless m

    maj, min, pat = m[1].split(".")
    [maj.to_i * 10000 + min.to_i * 100 + pat.to_i, 200000].min.to_s
  rescue SystemCallError
    nil
  end

  def clang?(compiler)
    out, = Open3.capture2(compiler, "--version", err: File::NULL)
    out.lines.first.to_s.match?(/clang/i)
  rescue SystemCallError
    false
  end

  # a script of the repository, as the bash runs it in command substitution: its output (no trailing newline) when it
  # succeeds; with require_success false, its output whatever its status
  def script_output(script, require_success:)
    out, status = Open3.capture2(File.join(@root, script), err: File::NULL)
    return nil if require_success && !status.success?

    out.chomp
  rescue SystemCallError
    nil
  end

  # the -dM macro lines of gcc with the -m FLAGS, sorted
  def macro_lines(flags)
    out, status = Open3.capture2("gcc", *flags, "-dM", "-E", "-x", "c", "/dev/null", err: File::NULL)
    unported("gcc -dM failed") unless status.success?
    out.lines.map(&:chomp).sort
  end
end

def unported(what)
  raise NfcxxUnported, what
end

# onoff of the argument loop (nfcxx's onoff): on|1 and off|0 are accepted, anything else is the bash's error
def onoff_value(arg)
  flag, value = arg.split("=", 2)
  return if %w[on 1 off 0].include?(value)

  raise NfcxxExit.new("nfcxx: #{flag} takes on or off (got '#{value}')", 2)
end

def normalize(path)
  Pathname.new(path).cleanpath.to_s
end

# options of the argument loop that the gcc path does not port (the other tracks, or the tools they need)
UNPORTED_PREFIXES = ["--bundle-", "--time-log=", "--trace=", "--target=",
                     "--pathb-c=", "--ir-opt=", "--emit-"].freeze
UNPORTED_OPTIONS = ["--cosmo", "--freestanding", "--obfuscate-kernels", "-fsafe-pointers"].freeze
# the -fsanitize= checks the bash implements (its sanitize block; docs/notes/ubsan.md)
SANITIZE_CHECKS = %w[undefined signed-integer-overflow integer-divide-by-zero shift bounds null unreachable return
                     float-cast-overflow].freeze
# the environment variables the plan reads (the bash's defaults for the linker, the dialect and the backend): their values are
# the facts'. NFCXX_BACKEND is read only as gcc (env_refused?).
PLAN_ENV = %w[NFCXX_LD NFCXX_DIALECT NFCXX_BACKEND].freeze

# Whether the plan is unported for the environment variable NAME with VALUE (the live environment, or an env line of the
# facts): NFCXX_BACKEND only as gcc (Path B and any other name are unported, as before), the PLAN_ENV names otherwise, and
# NFCXX_DRIVER_TRACE (the CRuby driver's own switch, scripts/nfcxx.rb; the bash does not read it) are not refused. Nor is
# NFCXX_TRACE_UNIT, which the bash exports itself before the gcc route (the trace unit's name): the plan traces nothing unless
# NFCXX_TRACE is set, and that one is refused. Any other NFCXX_* variable, and CUDA_HOME and the EDG variables, are refused.
def env_refused?(name, value)
  return value != "gcc" if name == "NFCXX_BACKEND"
  return false if PLAN_ENV.include?(name) || %w[NFCXX_DRIVER_TRACE NFCXX_TRACE_UNIT].include?(name)

  name.start_with?("NFCXX_") || %w[CUDA_HOME EDG_BUILD EDG_CPFE_DEFAULT_OPTIONS EDG_OBJ_TO_EXEC_DEFAULT_OPTIONS].include?(name)
end

class Plan
  attr_reader :lines

  def keep?
    @keep
  end

  # lines: the output (a nested run, the -fsyntax-only or --cuda-driver= re-run, appends to it); env_mode: the mode of
  # NFCXX_CUDA_DRIVER for this run ("libcuda" for the run the wrap execs, which has the mode in its environment)
  def initialize(facts, lines = [], env_mode = "auto")
    @facts = facts
    @lines = lines
    @env_mode = env_mode
    @cache_dir = ""
    @cache_log = ""
    @keep = false
    @std = "--c++23"
    @out = "a.out"
    @argv = []
    @outset = false
    @dialect = facts.flag?("cxx-clang") ? "clang" : "g++"
    @backend = ""
    @backend_explicit = false
    @emit_c = 0
    @cosmo = 0
    @target = ""
    @instantiate = "used"
    @eh_unwind_on = false
    @eh_shim_on = true
    @asan = false
    @asanopts = []
    @sanitize = "" # the -fsanitize= checks, joined as the bash joins them (sanitize_checks)
    @pic = false
    @shared = false
    @rdynamic = false
    @pthread = false
    @compile_only = false
    @preprocess = false
    @xlang = ""
    @stdin_src = false
    @depmode = ""
    @dfile = ""
    @dtarget = ""
    @depphony = ""
    @ncpp = 0
    @nobj = 0
    @ld_name = ""
    @files = []
    @cflags = []
    @cfiles = []
    @srcs = []
    @ppflags = []
    @pie_opts = []
    @preinc = []
    @sysdirs = []
    @isa_opts = []
    @diag_opts = []
    @dialect_asked = false
    # the environment first, as the bash sets its defaults (the arguments after it override them): NFCXX_DIALECT (a
    # non-empty value is asked for) and NFCXX_LD
    env_dialect = facts.env_value("NFCXX_DIALECT")
    if env_dialect && !env_dialect.empty?
      @dialect = env_dialect
      @dialect_asked = true
    end
    @ld_name = facts.env_value("NFCXX_LD") || ""
    # NFCXX_BACKEND=gcc is the backend as the bash takes it (backend=${NFCXX_BACKEND:-}, backend_explicit stays 0), so the
    # default-backend rule of select_backend does not apply to it
    @backend = facts.env_value("NFCXX_BACKEND") || ""
  end

  # the -fsanitize= checks, after the argument loop, as the bash's sanitize block: an unknown name is the bash's refusal (exit 2);
  # the checks the bash implements take Path B, which the port does not plan here (@sanitize is "" after -fno-sanitize=all)
  def sanitize_checks
    return if @sanitize.empty?

    checks = @sanitize.split(",", -1)
    checks.pop if @sanitize.end_with?(",")
    bad = checks.find { |c| !SANITIZE_CHECKS.include?(c) }
    raise NfcxxExit.new("nfcxx: -fsanitize=#{bad} is not supported (implemented: #{SANITIZE_CHECKS.join(", ")})", 2) if bad

    unported("-fsanitize=#{@sanitize} (Path B: scripts/nfcxx-pathb.rb)")
  end

  # the argument loop (scripts/nfcxx-loop.rb's run_loop, for the options of this slice)
  def parse(args)
    i = 0
    while i < args.length
      a = args[i]
      nxt = args[i + 1].to_s
      if UNPORTED_OPTIONS.include?(a) || UNPORTED_PREFIXES.any? { |p| a.start_with?(p) }
        unported(a)
      elsif a == "--backend=pathb" then unported("--backend=pathb (Path B)")
      elsif a.start_with?("--backend=") then @backend = a[10..]; @backend_explicit = true
      elsif a == "--keep-intermediates" then @keep = true
      elsif a == "--no-eh-unwind" then nil
      elsif a == "--eh-unwind" then @eh_unwind_on = true
      elsif a == "--no-eh-shim" then @eh_shim_on = false
      elsif a.start_with?("--cache=") then @cache_dir = a[8..]
      elsif a.start_with?("--cache-log=") then @cache_log = a[12..]
      elsif a.start_with?("--instantiate=") then @instantiate = a[14..]
      # the CUDA device code's options (not in a hosted plan), and the module directory (read only for a module source,
      # which run refuses)
      elsif a.start_with?("--promote-slots=", "--unroll=", "--struct-slots=") then onoff_value(a)
      elsif a.start_with?("--module-dir=") then nil
      elsif a.start_with?("--dialect=") then @dialect = a[10..]; @dialect_asked = true
      elsif a.start_with?("--gnu-version=") then nil
      elsif a.start_with?("-fuse-ld=")
        name = a[9..]
        if @facts.ld_available?(name) then @ld_name = name else @files << a end
      elsif a == "-fsanitize=address" then @asan = true
      elsif a == "-fno-sanitize=address" then @asan = false
      elsif a == "-fno-sanitize=all" then @sanitize = ""
      # refusals the bash makes in its loop, whatever the backend (before any compile): the bash's messages
      elsif a.start_with?("-fsanitize-")
        raise NfcxxExit.new("nfcxx: #{a} is not supported (only -fsanitize=address; docs/notes/asan.md)", 2)
      elsif a.start_with?("-fno-sanitize=")
        raise NfcxxExit.new("nfcxx: #{a} is not supported (only -fsanitize=undefined and its checks, docs/notes/ubsan.md)", 2)
      elsif a.start_with?("-fsanitize=")
        # the checks are joined as the bash joins them and checked after the loop (sanitize_checks)
        value = a.delete_prefix("-fsanitize=")
        @sanitize = @sanitize.empty? ? value : "#{@sanitize},#{value}"
      elsif a.start_with?("-fno-sanitize-")
        unported(a)
      elsif a == "-fno-safe-pointers" then nil
      elsif a == "-fno-omit-frame-pointer" || a == "-fomit-frame-pointer" then @asanopts << a
      elsif a == "-shared" then @shared = true; @pic = true
      elsif a == "-fPIC" || a == "-fpic" then @pic = true
      elsif a == "-rdynamic" then @rdynamic = true
      elsif a == "-c" then @compile_only = true; @files << "-c"
      elsif a == "-o" then @out = nxt; @outset = true; i += 1
      elsif a.start_with?("-std=c++") then @std = "--c++#{a[8..]}"
      elsif a.start_with?("-std=gnu++") then @std = "--c++#{a[10..]}"
      elsif a == "-E" then @preprocess = true
      elsif a == "-P" then @ppflags << "-P"
      elsif a == "-x" then @xlang = nxt; i += 1
      elsif a == "-" then @stdin_src = true
      elsif a == "-pthread" then @pthread = true
      elsif a == "-fexceptions" || a == "-fwrapv" || a == "-fno-strict-aliasing" || a == "-pipe" then nil
      elsif a.start_with?("-fvisibility=") || a == "-fvisibility-inlines-hidden" then nil
      elsif a == "-fPIE" || a == "-fpie" then @pie_opts.push("--c_to_obj_option", "-fPIE")
      elsif a == "-pie" then @pie_opts.push("--c_to_obj_option", "-pie")
      elsif a.start_with?("-Wl,") then @files << a
      elsif a.start_with?("-l") && a.length > 2
        @files << a
      elsif a == "-Wno-narrowing" then @diag_opts << "--diag_warning=narrowing_conversion"
      elsif a.start_with?("-W") || a == "-w" then nil
      elsif a.start_with?("-m") then @isa_opts << a
      elsif a == "-MD" || a == "-MMD" then @depmode = a
      elsif a == "-MP" then @depphony = "-MP"
      elsif a == "-MF" then @dfile = nxt; i += 1
      elsif a == "-MT" || a == "-MQ" then @dtarget = nxt; i += 1
      elsif a == "-include"
        raise NfcxxExit.new("nfcxx: -include needs an argument", 2) unless i + 1 < args.length
        @preinc << nxt; i += 1
      elsif a == "-isystem"
        @sysdirs << nxt; i += 1
      elsif a.start_with?("-isystem") && a.length > 8 then @sysdirs << a[8..]
      elsif a.end_with?(".c") then @cfiles << a
      elsif (a.start_with?("-I", "-D", "-U")) && a.length > 2
        @cflags << a
        @files << a
      elsif a == "-I" || a == "-D" || a == "-U"
        raise NfcxxExit.new("nfcxx: #{a} needs an argument", 2) unless i + 1 < args.length
        @cflags << "#{a}#{nxt}"
        @files << "#{a}#{nxt}"
        i += 1
      elsif a.end_with?(".o")
        @files << a
        @nobj += 1
      elsif a.start_with?("-") || a.end_with?(".a") || a.end_with?(".so")
        @files << a
      elsif a.end_with?(".cu", ".cpp2") then unported("CUDA or cppfront input #{a}")
      else
        @files << a
        @ncpp += 1
        @srcs << a
      end
      i += 1
    end
  end

  def run(args)
    @argv = args
    return syntax_only(args) if args.include?("-fsyntax-only")

    kind, argv = cuda_driver_step(args)
    return nested(argv, "libcuda") if kind == :exec

    parse(argv)
    if @ncpp + @nobj + @cfiles.length + (@stdin_src ? 1 : 0) == 0
      raise NfcxxExit.new("nfcxx: no input files", 2)
    end
    @srcs.each { |s| unported("source #{s} is not a file (the bash reports it)") unless @facts.source_ok?(s) }
    @srcs.each { |s| unported("module source #{s}") if @facts.module_source?(s) }
    if @preprocess
      unported("-fsanitize with -E") unless @sanitize.empty?
      return preprocess
    end

    raise NfcxxExit.new("nfcxx: a source on stdin is supported only with -E", 2) if @stdin_src
    unless ["", "c++", "none"].include?(@xlang)
      raise NfcxxExit.new("nfcxx: -x #{@xlang}: only C++ sources (use nfcc for C)", 2)
    end
    if !@depmode.empty? && !@compile_only
      raise NfcxxExit.new("nfcxx: #{@depmode} needs -c (dependency files are written for a compile only)", 2)
    end
    raise NfcxxExit.new("nfcxx: unknown dialect '#{@dialect}'", 2) unless ["g++", "clang"].include?(@dialect)
    sanitize_checks

    select_backend
    @moves = !@compile_only
    asan_c = @asan ? ["-fsanitize=address", "-fno-omit-frame-pointer", *@asanopts] : []
    @asanopts = [] unless @asan
    inst_opts = instantiate_options
    sys_inc = []
    hosted_libs = []
    @facts.host_sys.each { |d| sys_inc << "--sys_include=#{d}" }
    hosted_libs = ["--c_to_obj_lib=m"]
    @sysdirs.each { |d| sys_inc << "--sys_include=#{ecp_arg(d)}" }
    pre_opts = []
    @preinc.each do |f|
      f = abs(f) if @moves && @facts.exists?(f)
      pre_opts.push("--preinclude", f)
    end
    shim, rtlib, vlart = link_helpers
    picopts, ldopts, cflags_pic = pic_and_link_options(asan_c)
    cobjs = c_inputs(asan_c, cflags_pic, ldopts)
    link_files = @files + isa_defines
    eflist, userinc = edg_link_options(link_files)
    keep_static = @facts.flag?("cc-clang") ? [] : ["--c_to_obj_option", "-fkeep-static-functions"]
    eh_unwind = []
    eh_unwind << "--nfcxx_eh_thread_local" if @facts.flag?("eh-tls")
    if @eh_unwind_on && @backend == "gcc"
      eh_unwind += ["--nfcxx_eh_unwind", "--c_to_obj_option", "-fexceptions", "--c_to_obj_option", "-include",
                    "--c_to_obj_option", EH_UNWIND_HEADER]
    end
    # the bash's order of the eccp route: the note of a kept directory (eccp_plan), the records of the sources (compile_clean),
    # the records of the link (link_records_rm), the cache lookup, then the eccp call in its directory with its exports, the
    # records again, the cache store and the dependency file (-MD)
    lk = nil
    if @shared
      lk = ["-shared"]
      prev = nil
      (picopts + eflist + inst_opts).each do |a|
        lk << a if prev == "--c_to_obj_option" && (a.start_with?("-Wl,", "-fuse-ld=") || a == "-pthread" || a == "-rdynamic")
        prev = a
      end
    end
    # -c without -o: the object is <stem>.o, as for C and .cu inputs; eccp makes one object per call
    out = @out
    if @compile_only && !@outset && @ncpp > 0
      raise NfcxxExit.new("nfcxx: -c with several sources needs -o (one object is made per call)", 2) if @srcs.length > 1
      out = "#{File.basename(@srcs[0], ".*")}.o"
    end
    @out = out
    # the bash exports EDG_CPFE_DEFAULT_OPTIONS (the GNU or clang version) before it runs the EDG driver
    cpfe = if @dialect == "clang" then @facts.value("clang-version") && ["--clang_version=#{@facts.value("clang-version")}"]
           else @facts.value("gnu-version") && ["--gnu_version=#{@facts.value("gnu-version")}"]
           end
    emit("NOTE", "nfcxx: intermediates kept in #{ECCP_DIR} (--keep-intermediates)") if @moves && @keep
    emit("RUN", RUBY_PROG, NLINK, "compile-clean", out, *@srcs) if @compile_only && @ncpp > 0
    emit("RUN", RUBY_PROG, NLINK, "records-rm", "--", *link_files)
    emit("CHECK", RUBY_PROG, NCACHE, "check", "--statements=#{TMP}/cc", *cache_opts(out)) unless @cache_dir.empty?
    emit("ENV", "EDG_OBJ_TO_EXEC_DEFAULT_OPTIONS=#{lk.join(" ")}") if lk
    emit("ENV", "EDG_CPFE_DEFAULT_OPTIONS=#{cpfe.join(" ")} ") if cpfe && !cpfe.empty?
    emit("CD", ECCP_DIR) if @moves
    emit("RUN", ECCP, @std, "--#{@dialect}", "--wdir", "/", *inst_opts, *@diag_opts, *userinc, *sys_inc, *hosted_libs,
         "--c_to_obj_option", "-O2", "--c_to_obj_option", "-fwrapv", "--c_to_obj_option", "-fno-strict-aliasing",
         *keep_static, *eh_unwind, "--c_to_obj_option", "-fgnu89-inline", *picopts, *cobjs, *pre_opts, *eflist,
         *shim, *vlart, *rtlib, "-o", ecp_arg(out))
    emit("RUN", RUBY_PROG, NLINK, "records-rm", "--", *link_files)
    emit("STORE", RUBY_PROG, NCACHE, "store", "--out=#{out}", "--entry=#{ENTRY}") unless @cache_dir.empty?
    depend_step unless @depmode.empty?
    # a link's exit trap (eccp_cleanup): the eccp directory (kept with --keep-intermediates) and the C objects' directory
    emit_exit
    nil
  end

  private

  def emit(kind, *words)
    @lines << [kind, *words]
  end

  # the backend: an explicit --backend=, else gcc unless the default would be Path B (which is not ported)
  def select_backend
    if @backend.empty?
      if !@backend_explicit && @cosmo == 0 && @emit_c == 0 && @target.empty? && !@preprocess && @depmode.empty? && !@shared
        unported("the default backend is Path B for this argument list (give --backend=gcc)")
      end
      @backend = "gcc"
    end
    raise NfcxxExit.new("nfcxx: unknown backend '#{@backend}'", 2) unless ["pathb", "gcc"].include?(@backend)
    unported("--backend=pathb") if @backend == "pathb"
  end

  def instantiate_options
    case @instantiate
    when "auto" then []
    when "used"
      opts = ["--no_auto_instantiation", "-tused"]
      opts += ["--c_to_obj_option", "-ffunction-sections", "--c_to_obj_option", "-fdata-sections",
               "--c_to_obj_option", "-Wl,--gc-sections"]
      opts
    else
      raise NfcxxExit.new("nfcxx: --instantiate (NFCXX_INSTANTIATE) is auto or used (got #{@instantiate})", 2)
    end
  end

  # ecp_arg: an argument as eccp receives it (paths absolute when eccp runs in a temporary directory: a link)
  def ecp_arg(arg)
    return arg unless @moves

    case arg
    when /\A-I./ then "-I#{abs(arg[2..])}"
    when /\A-L./ then "-L#{abs(arg[2..])}"
    when /\A-Wl,/ then wl_arg(arg)
    when /\A-/ then arg
    else abs(arg)
    end
  end

  # abs_path (scripts/host-sys.rb): the absolute name when the directory of the path exists (the path itself need not): the
  # directory's real path, then "/" and the base name, so a root-level name is "//NAME" as the bash makes it
  def abs(path)
    dir = File.dirname(path)
    return path unless dir_exists?(dir)

    "#{@facts.real_dir(dir)}/#{File.basename(path)}"
  end

  def dir_exists?(dir)
    dir == "." || @facts.dir?(dir)
  end

  def wl_arg(arg)
    parts = arg[4..].split(",", -1)
    res = "-Wl"
    prevp = nil
    parts.each do |p|
      if ["-soname", "--soname", "-h"].include?(prevp)
        res += ",#{p}"
        prevp = p
        next
      end
      prevp = p
      if p.match?(/\A(-soname=|--soname=)/) then nil
      elsif p.match?(/\A(--dependency-file=|-Map=|--Map=)/)
        name, value = p.split("=", 2)
        if @facts.exists?(value) || dir_exists?(File.dirname(value))
          p = "#{name}=#{abs(File.dirname(value))}/#{File.basename(value)}"
        end
      elsif p.include?("=")
        name, value = p.split("=", 2)
        p = "#{name}=#{abs(value)}" if @facts.exists?(value)
      elsif @facts.exists?(p)
        p = abs(p)
      end
      res += ",#{p}"
    end
    res
  end

  def isa_defines
    return [] if @isa_opts.empty?

    defs = @facts.isa_for(@isa_opts)
    defs.map { |_, name, value| [name, value] }.uniq.sort_by { |name, value| "#{name} #{value}" }
        .map { |name, value| "-D#{name}=#{value}" }
  end

  # the EH shim and the VLA runtime of a hosted link (the block before the C inputs)
  def link_helpers
    shim = []
    rtlib = []
    vlart = []
    return [shim, rtlib, vlart] unless !@compile_only && !@shared && (@ncpp + @nobj) > 0

    s = @eh_shim_on ? @facts.value("ehshim").to_s : ""
    shim << s unless s.empty?
    rtlib = [LIBC]
    if @asan
      v = @facts.value("asan-vla").to_s
      raise NfcxxExit.new("nfcxx: cannot build the C++ VLA runtime for -fsanitize=address (scripts/asan-vla.rb)", 2) if v.empty?

      vlart = [v]
    end
    [shim, rtlib, vlart]
  end

  # the picopts and ldopts of the bash (the -m options, the -fPIC reset, the link options)
  def pic_and_link_options(asan_c)
    picopts = []
    ldopts = []
    cflags_pic = []
    @isa_opts.each { |o| picopts.push("--c_to_obj_option", o) }
    if @pic
      picopts = ["--c_to_obj_option", "-fPIC"]
      cflags_pic = ["-fPIC"]
    end
    picopts.push("--c_to_obj_option", "-rdynamic") if @rdynamic
    picopts.push("--c_to_obj_option", "-pthread") if @pthread
    picopts += @pie_opts
    asan_c.each { |o| picopts.push("--c_to_obj_option", o) }
    ldopts = ["-shared"] if @shared
    ldopts << "-rdynamic" if @rdynamic
    unless @ld_name.empty?
      unless @facts.ld_available?(@ld_name)
        raise NfcxxExit.new("nfcxx: NFCXX_LD=#{@ld_name}: ld.#{@ld_name} is not on PATH", 2)
      end
      ldopts << "-fuse-ld=#{@ld_name}"
      picopts.push("--c_to_obj_option", "-fuse-ld=#{@ld_name}")
    end
    [picopts, ldopts, cflags_pic]
  end

  # the C inputs: one gcc object each (a -c of C alone copies them; a C-only program links with gcc and stops)
  def c_inputs(asan_c, cflags_pic, ldopts)
    cobjs = []
    return cobjs if @cfiles.empty?

    @cfiles.each_with_index do |c, n|
      o = "#{TMP}/#{n}.o"
      emit("RUN", "gcc", "-c", "-O2", "-fwrapv", "-fno-strict-aliasing", *asan_c, *cflags_pic, *@cflags, c, "-o", o)
      cobjs << o
    end
    if @compile_only && @ncpp == 0
      raise NfcxxExit.new("nfcxx: -c with -o needs exactly one source", 2) if @outset && cobjs.length != 1

      cobjs.each_with_index do |o, i|
        dst = @outset ? @out : "#{File.basename(@cfiles[i], ".c")}.o"
        emit("CP", o, dst)
      end
      raise PlanDone
    end
    if @ncpp == 0 && @nobj == 0
      emit("RUN", "gcc", *asan_c, *ldopts, *cobjs, *(@files + isa_defines), "-o", @out)
      raise PlanDone
    end
    cobjs
  end

  # the link options of the EDG call: -l, -L, -Wl, and the rest, in argument order (scripts/nfcxx-linkargs.rb's rules; the
  # facts give the CUDA home and the CUB archive)
  def edg_link_options(files)
    NfcxxLinkArgs.edg_options(files, compile_only: @compile_only, cuda_home: @facts.value("cuda-home").to_s,
                              dir: ->(d) { @facts.dir?(d) }, cub: -> { @facts.value("cuda-cub").to_s },
                              ecp_arg: ->(a) { ecp_arg(a) })
  rescue NfcxxLinkArgs::Refused => e
    # the bash sets its exit trap before it plans the link arguments, so a refusal there still runs the cleanup
    emit_exit
    raise NfcxxExit.new(e.message, 2)
  end

  # a link's exit trap (the bash's eccp_cleanup, set once the eccp directory is made): the eccp directory (kept with
  # --keep-intermediates) and the C objects' directory are removed when the driver exits. Emitted once.
  def emit_exit
    return unless @moves && !@exit_emitted

    @exit_emitted = true
    emit("EXIT", RUBY_PROG, NLINK, "cleanup", @keep ? "1" : "0", ECCP_DIR, "", @cfiles.empty? ? "" : TMP)
  end

  # the run of nfcxx on ARGV, in the same output (the bash runs it as a new process)
  def nested(argv, mode)
    Plan.new(@facts, @lines, mode).run(argv)
  end

  # -fsyntax-only (the first step of the bash): the compile without its object, run as -c -o TMP/x.o, its -o value
  # replaced (the same rule as scripts/nfcxx-loop.rb's syntax_only_plan). With -E the run goes on without the option, and
  # that run execs g++ -E.
  def syntax_only(args)
    rest = args.reject { |b| b == "-fsyntax-only" }
    return nested(rest, @env_mode) if rest.include?("-E")

    if rest.include?("-o")
      unported("-o with no value under -fsyntax-only") if rest.last == "-o"
      replaced = []
      skip = false
      rest.each do |b|
        if skip
          replaced << "#{TMP}/x.o"
          skip = false
          next
        end
        skip = true if b == "-o"
        replaced << b
      end
      return nested(["-c", *replaced], @env_mode)
    end
    nested(["-c", *rest, "-o", "#{TMP}/x.o"], @env_mode)
  end

  def libcuda?(arg)
    ["-lcuda", "-l:libcuda.so", "-l:libcuda.so.1"].include?(arg) || arg.end_with?("/libcuda.so", "/libcuda.so.1")
  end

  def cuda_static?(arg)
    arg == "-lcudart_static" || arg.end_with?("/libcudart_static.a")
  end

  # the toolkit a libcuda path implies (scripts/wrap.rb: the directory above lib64, or above lib/stubs for a
  # targets/ path); "" when it implies none
  def derived_home(found)
    if found.match?(%r{/lib64/(stubs/)?libcuda\.so}) then found[0...found.rindex("/lib64/")]
    elsif found.match?(%r{/targets/.*/lib/stubs/libcuda\.so}) then found[0...found.rindex("/lib/stubs/")]
    else ""
    end
  end

  # the toolkit: CUDA_HOME when it is set, else the derived one when it has include/cuda.h, else /usr/local/cuda (not read)
  def cuda_toolkit(found)
    env_home = @facts.value("cuda-home").to_s
    return env_home unless env_home.empty?

    home = derived_home(found)
    return home if !home.empty? && @facts.file?("#{home}/include/cuda.h")

    unported("the CUDA toolkit is /usr/local/cuda (CUDA_HOME unset, and #{found} names no toolkit with cuda.h): not read")
  end

  # the reason the wrap cannot replace libcuda with the shim, or nil (the bash's why)
  def cuda_why(home)
    # the version is read from cuda_runtime_api.h; a missing header leaves it unknown (the bash reads it with || rtv=)
    header = "#{home}/include/cuda_runtime_api.h"
    machine = @facts.value("machine") or unported("uname -m is not in the facts")
    return "the shim is x86-64 only" unless machine == "x86_64"
    return "no cuda.h and cudaTypedefs.h in #{home}/include" unless @facts.file?("#{home}/include/cuda.h") &&
                                                                    @facts.file?("#{home}/include/cudaTypedefs.h")

    return "no cuda_runtime_api.h in #{home}/include" unless @facts.file?(header)

    rtv = @facts.cuda_rtv(header)
    return "libcudart #{rtv || "of unknown version"} is older than 12.5" if rtv.nil? || rtv.to_i < 12050

    error = @facts.value("cuda-shim-error")
    return "the shim did not build: #{error}" unless error.nil?
    unported("the shim's result (cuda-shim or cuda-shim-error) is not in the facts") if @facts.value("cuda-shim").nil?

    nil
  end

  # scripts/wrap.rb, the first step after -fsyntax-only: --cuda-driver=MODE is taken out of the arguments; a
  # link that names libcuda is run again with the shim and -lcudart in its place ([:exec, ARGV]), or goes on as named
  # ([:go, ARGV]: no libcuda, mode libcuda, or a note: the shim cannot be made). --cuda-driver=cudart fails then (status 1).
  def cuda_driver_step(args)
    mode = @env_mode
    rest = []
    args.each do |a|
      if a.start_with?("--cuda-driver=") then mode = a.delete_prefix("--cuda-driver=")
      else rest << a
      end
    end
    unless ["auto", "cudart", "libcuda"].include?(mode)
      raise NfcxxExit.new("nfcxx: --cuda-driver=#{mode}: auto, cudart or libcuda", 2)
    end

    found = rest.select { |a| libcuda?(a) }.last
    return [:go, rest] if found.nil? || mode == "libcuda"

    static = rest.select { |a| cuda_static?(a) }.last
    home = cuda_toolkit(found)
    why = cuda_why(home)
    unless why.nil?
      raise NfcxxExit.new("nfcxx: --cuda-driver=cudart: #{why}", 1) if mode == "cudart"

      return [:go, rest]
    end

    lib64 = "#{home}/lib64"
    out = []
    done = false
    rest.each do |a|
      unless libcuda?(a)
        out << a
        next
      end
      next if done

      done = true
      out << @facts.value("cuda-shim")
      if static
        out << static
      else
        out.push("-L#{lib64}", "-Wl,-rpath,#{lib64}") if @facts.dir?(lib64)
        out << "-lcudart"
      end
    end
    [:exec, out]
  end

  # -E: exec g++ -E (before the backend is chosen)
  def preprocess
    args = ["-E", "-std=#{@std.delete_prefix("--")}"]
    args += ["-x", @xlang] unless @xlang.empty?
    args += @ppflags + @cflags + @sysdirs.map { |d| "-isystem#{d}" }
    @preinc.each { |f| args += ["-include", f] }
    args += @srcs
    args << "-" if @stdin_src
    args += ["-o", @out] if @outset
    emit("EXEC", "g++", *args)
    nil
  end

  # -MD/-MMD: the host preprocessor writes the dependency file (after the eccp call): the words are scripts/nfcxx-depmode.rb's
  # (the bash runs the command it plans)
  def depend_step
    scalars = { "depmode" => @depmode, "out" => @out, "std" => @std, "dfile" => @dfile, "dtarget" => @dtarget,
                "depphony" => @depphony }
    arrays = { "cflags" => @cflags, "sysdirs" => @sysdirs, "srcs" => @srcs }
    emit("RUN", *NfcxxDepmode.words(scalars, arrays))
  end

  # the cache lookup's options (scripts/nfcxx-setup.rb cache-opts, as the bash reads them back: NUL-terminated words)
  def cache_opts(out)
    fields = {
      "cache_dir" => @cache_dir, "cache_log" => @cache_log, "out" => out, "src" => @srcs[0].to_s, "cwd" => @facts.real_cwd,
      "backend" => @backend, "compile_only" => @compile_only ? "1" : "0", "ncpp" => @ncpp.to_s, "outset" => @outset ? "1" : "0",
      "nobj" => @nobj.to_s, "modules" => "0", "preprocess" => "0", "stdin_src" => "0", "depmode" => @depmode,
      "cfiles_n" => @cfiles.length.to_s, "cu_n" => "0", "cpp2_n" => "0", "std" => @std,
      "argv" => @argv.join("\x1f"), "cflags" => @cflags.join("\x1f"), "preinc" => @preinc.join("\x1f"),
      "sysdirs" => @sysdirs.join("\x1f")
    }
    out_text, status = Open3.capture2(ENV["RUBY"] || "ruby", File.join(__dir__, "nfcxx-setup.rb"), "cache-opts",
                                      *fields.map { |k, v| "#{k}=#{v}" })
    raise NfcxxUnported, "nfcxx-setup.rb cache-opts failed" unless status.success?

    out_text.split("\0")
  end
end

# the --shell output (see the header): the plan as statements a bash driver evals; every value is escaped with Shellwords. The
# placeholders stay in the words (the substitution contract): nfcxx_plan_uses names the temporary directories the plan
# needs (TMP, ECCP: the driver makes each with mktemp -d), and nfcxx_plan_keep is 1 when ECCP is kept on exit.
def emit_shell(lines, status, keep)
  words = lines.flat_map { |fields| fields.drop(1) }
  uses = []
  uses << "TMP" if words.any? { |w| w.include?(TMP) }
  uses << "ECCP" if words.any? { |w| w.include?(ECCP_DIR) }
  $stdout.write("nfcxx_plan_state=PLAN\n")
  $stdout.write("nfcxx_plan_status=#{status}\n")
  $stdout.write("nfcxx_plan_keep=#{keep ? 1 : 0}\n")
  $stdout.write("nfcxx_plan_uses=(#{uses.join(" ")})\n")
  $stdout.write("nfcxx_plan_kinds=(#{lines.map { |fields| Shellwords.escape(fields.first) }.join(" ")})\n")
  $stdout.write("nfcxx_plan_nwords=(#{lines.map { |fields| fields.size - 1 }.join(" ")})\n")
  $stdout.write("nfcxx_plan_words=(#{words.map { |w| Shellwords.escape(w) }.join(" ")})\n")
end

# the default form's text of a word: the placeholders as the names the tests use
def display(word)
  DISPLAY.reduce(word) { |w, (token, name)| w.gsub(token, name) }
end

def main(argv)
  format = %w[--tabs --shell].include?(argv.first) ? argv.shift : nil
  source = argv.shift.to_s
  facts =
    if source.start_with?("--facts=") then Facts.load(source.delete_prefix("--facts="))
    elsif source.start_with?("--live=") then LiveFacts.new(source.delete_prefix("--live="), Dir.pwd)
    else raise ArgumentError, "the first argument is --facts=FILE or --live=ROOT"
    end
  plan = Plan.new(facts)
  status = 0
  begin
    plan.run(argv)
  rescue PlanDone
    status = 0
  rescue NfcxxExit => e
    $stderr.write("#{e.message}\n")
    status = e.status
  end
  if format == "--shell"
    emit_shell(plan.lines, status, plan.keep?)
  else
    plan.lines.each { |fields| $stdout.write("#{fields.map { |w| display(w) }.join(format == "--tabs" ? "\t" : " ")}\n") }
    $stdout.write("STATUS #{status}\n") unless format == "--tabs"  # a plan file (--tabs) holds commands only; the status is the exit status
  end
  status
rescue NfcxxUnported => e
  $stderr.write("unported: #{e.message}\n")
  $stdout.write("nfcxx_plan_state=UNPORTED\n") if format == "--shell"
  3
end

exit(main(ARGV)) if $PROGRAM_NAME == __FILE__
