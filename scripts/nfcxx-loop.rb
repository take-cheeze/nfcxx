#!/usr/bin/env ruby
# nfcxx's argument loop, ported from the bash in nfcxx (the "while [ $# -gt 0 ]" loop after its setup). The first slice
# covers the loop itself with the default environment (no NFCXX_* variables): the options set the state below, and an
# error exits 2 with nfcxx's message. Checked against the bash by tests/nfcxx/loop-state.sh, which runs nfcxx's own setup
# and loop with the build step (ensure_tool) stubbed out (tests/nfcxx/option-state.sh).
#
# -fsyntax-only (the re-run before the setup) prints the command the bash would run instead of the state (syntax_only_plan).
# --bundle-* (the re-run before the setup) prints the commands it runs (bundle_plan). --cuda-driver= and a link that names
# libcuda (the wrap of scripts/cuda-driver-wrap.sh, after the bundle re-run) prints the driver's re-run, or a note or an
# error, or goes on without --cuda-driver= (cuda_driver_step). Not covered in this slice (refused as "unported", exit 3):
# -fuse-ld= (which asks the shell whether ld.NAME exists; the port takes that as --ld-available=), and the NFCXX_*
# variables that are not in the apply_environment list.
#
#   ruby scripts/nfcxx-loop.rb ARG...   prints the state the loop leaves, one line per variable
#   --ld-available=NAME,...             the ld.NAME programs that exist (for -fuse-ld=NAME)
#   --nfcxx-env=NAME=VALUE              the environment (NFCXX_CUDA_DRIVER, CUDA_HOME, and the NFCXX_* state variables)
#   --nfcxx-machine=M                   uname -m (default x86_64)
#   --nfcxx-cuda-file=PATH              PATH is an existing file (repeated; the headers the wrap tests)
#   --nfcxx-cuda-dir=PATH               PATH is an existing directory (repeated; $home/lib64)
#   --nfcxx-cuda-rtv=PATH=N             CUDART_VERSION of the header at PATH (absent when the file has no such line)
#   --nfcxx-shim=ok|error:TEXT          the shim's result: ok (the archive path is ROOT/build/cuda-driver/SHIM/libnfcxx_cudrv.a,
#                                       a stand-in for the hashed path), or it did not build, with the text it printed
#   The facts are the files the bash tests: tests/nfcxx/loop-state.sh gives the port the real ones for the toolkits it uses.

class NfcxxUnported < StandardError
end

class NfcxxExit < StandardError
  attr_reader :status
  def initialize(message, status)
    super(message)
    @status = status
  end
end

# The state of the loop (the bash globals of the same names).
class LoopState
  attr_accessor :std, :out, :outset, :emit_c, :emit_hip, :backend, :backend_explicit, :path_b, :ir_opt, :ir_opt_set
  attr_accessor :eh_unwind_on, :eh_shim_on, :cache_dir, :cache_log_file, :keep_intermediates, :time_log, :instantiate
  attr_accessor :promote_slots, :unroll, :struct_slots, :pathb_c, :ld_name, :obfuscate, :dialect, :dialect_asked
  attr_accessor :gnu, :gnu_user, :freestanding, :cosmo, :target, :trace, :moddir, :asan, :safeptr, :sanitize
  attr_accessor :shared, :pic, :rdynamic, :compile_only, :pthread, :preprocess, :xlang, :stdin_src
  attr_accessor :depmode, :dfile, :dtarget, :depphony, :ncpp, :nobj, :system_paths
  attr_reader :files, :cflags, :cfiles, :cu_inputs, :cpp2_inputs, :srcs, :ppflags, :pie_opts, :preinc, :sysdirs
  attr_reader :isa, :diag_opts, :asanopts

  def initialize
    @std = "--c++23"
    @out = "a.out"
    @outset = 0
    @emit_c = 0
    @emit_hip = ""
    @backend = ""
    @backend_explicit = 0
    @path_b = 0
    @ir_opt = ""
    @ir_opt_set = 0
    @eh_unwind_on = 0
    @eh_shim_on = 1
    @cache_dir = ""
    @cache_log_file = ""
    @keep_intermediates = 0
    @time_log = ""
    @instantiate = "used"
    @promote_slots = 1
    @unroll = 1
    @struct_slots = 1
    @pathb_c = ""
    @ld_name = ""
    @obfuscate = 0
    @dialect = "g++"
    @dialect_asked = ""
    @gnu = ""
    @gnu_user = ""
    @freestanding = 0
    @cosmo = 0
    @target = ""
    @trace = ""
    @moddir = ""
    @asan = 0
    @safeptr = 0
    @sanitize = ""
    @shared = 0
    @pic = 0
    @rdynamic = 0
    @compile_only = 0
    @pthread = 0
    @preprocess = 0
    @xlang = ""
    @stdin_src = 0
    @depmode = ""
    @dfile = ""
    @dtarget = ""
    @depphony = ""
    @ncpp = 0
    @nobj = 0
    @system_paths = ""
    @files = []
    @cflags = []
    @cfiles = []
    @cu_inputs = []
    @cpp2_inputs = []
    @srcs = []
    @ppflags = []
    @pie_opts = []
    @preinc = []
    @sysdirs = []
    @isa = []
    @diag_opts = []
    @asanopts = []
  end
end

# The NFCXX_* variables that set the loop's state during nfcxx's setup, as the setup reads them: the port takes them as
# explicit inputs (--nfcxx-env=NAME=VALUE, one per variable that is set, empty values included) instead of reading the
# environment. A variable that is not in the list is not read here (the tools it names run after the loop).
ENV_STATE_VARIABLES = %w[NFCXX_BACKEND NFCXX_PATH NFCXX_IR_OPT NFCXX_EH_UNWIND NFCXX_EHSHIM NFCXX_CACHE NFCXX_CACHE_LOG
                         NFCXX_CACHE_REMOTE NFCXX_KEEP_INTERMEDIATES NFCXX_TIME_LOG NFCXX_INSTANTIATE NFCXX_PROMOTE_SLOTS
                         NFCXX_UNROLL NFCXX_STRUCT_SLOTS NFCXX_LD NFCXX_PATHB_C NFCXX_OBFUSCATE_KERNELS NFCXX_DIALECT
                         NFCXX_TRACE].freeze

# nfcxx's setup, for the variables above: each sets the loop's state the way the bash does (${VAR:-default}, and the
# tests of the value). env maps a variable name to its value (only the variables that are set); uid is id -u, and it is
# used only for the default remote-cache directory.
def apply_environment(state, env, uid, tmpdir)
  state.backend = env["NFCXX_BACKEND"] if env.key?("NFCXX_BACKEND")
  state.path_b = 1 if env["NFCXX_PATH"] == "b"
  if env.key?("NFCXX_IR_OPT")
    state.ir_opt = env["NFCXX_IR_OPT"]
    state.ir_opt_set = 1
  end
  state.eh_unwind_on = 1 if env["NFCXX_EH_UNWIND"] == "1"
  state.eh_shim_on = 0 if env["NFCXX_EHSHIM"] == "0"
  state.cache_dir = env["NFCXX_CACHE"] if env.key?("NFCXX_CACHE")
  state.cache_log_file = env["NFCXX_CACHE_LOG"] if env.key?("NFCXX_CACHE_LOG")
  remote = env.fetch("NFCXX_CACHE_REMOTE", "")
  unless remote.empty? || remote == "gha"
    raise NfcxxExit.new("nfcxx: NFCXX_CACHE_REMOTE takes gha (got '#{remote}')", 2)
  end
  if state.cache_dir.empty? && !remote.empty?
    base = tmpdir.empty? ? "/tmp" : tmpdir
    state.cache_dir = "#{base}/nfcxx-cache-#{uid}"
  end
  state.keep_intermediates = 1 if env["NFCXX_KEEP_INTERMEDIATES"] == "1"
  state.time_log = env["NFCXX_TIME_LOG"] if env.key?("NFCXX_TIME_LOG")
  state.instantiate = env.fetch("NFCXX_INSTANTIATE", "") == "" ? "used" : env["NFCXX_INSTANTIATE"]
  state.promote_slots = env.fetch("NFCXX_PROMOTE_SLOTS", "") == "" ? "1" : env["NFCXX_PROMOTE_SLOTS"]
  state.unroll = env.fetch("NFCXX_UNROLL", "") == "" ? "1" : env["NFCXX_UNROLL"]
  state.struct_slots = env.fetch("NFCXX_STRUCT_SLOTS", "") == "" ? "1" : env["NFCXX_STRUCT_SLOTS"]
  state.ld_name = env["NFCXX_LD"] if env.key?("NFCXX_LD")
  state.pathb_c = env["NFCXX_PATHB_C"] if env.key?("NFCXX_PATHB_C")
  obf = env.fetch("NFCXX_OBFUSCATE_KERNELS", "0")
  state.obfuscate = obf == "0" || obf == "" ? 0 : 1
  if env.key?("NFCXX_DIALECT")
    unless env["NFCXX_DIALECT"].empty?
      state.dialect = env["NFCXX_DIALECT"]
      state.dialect_asked = "1"
    end
  end
  state.trace = env["NFCXX_TRACE"] if env.key?("NFCXX_TRACE")
  apply_system_paths(state, env)
end

# nfcxx's setup exports NFCXX_SYSTEM_PATHS (the directories the rewriter treats as system directories): CUDA_HOME is put
# first when set, and with NFCXX_CUDA_TARGET=amdgpu lib/hip and ROCm's include directory go before it. ROOT stands for the
# repository. The result is the variable the tools after the loop read.
def apply_system_paths(state, env)
  sys = env.fetch("NFCXX_SYSTEM_PATHS", "")
  cuda = env.fetch("CUDA_HOME", "")
  sys = cuda + (sys.empty? ? "" : ":#{sys}") unless cuda.empty?
  target = env.fetch("NFCXX_CUDA_TARGET", "")
  target = "nvidia" if target.empty?
  if target == "amdgpu"
    rocm = env.fetch("ROCM", "")
    rocm = "/opt/rocm" if rocm.empty?
    sys = "ROOT/lib/hip:#{rocm}/include" + (sys.empty? ? "" : ":#{sys}")
  end
  state.system_paths = sys
end

def onoff(flag, value)
  return 1 if value == "on" || value == "1"
  return 0 if value == "off" || value == "0"

  raise NfcxxExit.new("nfcxx: #{flag} takes on or off (got '#{value}')", 2)
end

def starts_with?(text, prefix)
  text.start_with?(prefix)
end

# The loop. args are the arguments after the setup's own set -- (no wrapper has changed them).
def run_loop(args, state, ld_available)
  i = 0
  n = args.length
  while i < n
    a = args[i]
    if a == "--emit-c" then state.emit_c = 1
    elsif a == "--emit-hip" then state.emit_hip = 1
    elsif starts_with?(a, "--backend=")
      state.backend = a[10..]
      state.backend_explicit = 1
      state.path_b = 1 if state.backend == "pathb"
    elsif starts_with?(a, "--ir-opt=")
      state.ir_opt = a[9..]
      state.ir_opt_set = 1
    elsif a == "--eh-unwind" then state.eh_unwind_on = 1
    elsif a == "--no-eh-unwind" then state.eh_unwind_on = 0
    elsif a == "--no-eh-shim" then state.eh_shim_on = 0
    elsif starts_with?(a, "--cache-log=") then state.cache_log_file = a[12..]
    elsif starts_with?(a, "--cache=") then state.cache_dir = a[8..]
    elsif a == "--keep-intermediates" then state.keep_intermediates = 1
    elsif starts_with?(a, "--time-log=") then state.time_log = a[11..]
    elsif starts_with?(a, "--instantiate=") then state.instantiate = a[14..]
    elsif starts_with?(a, "--promote-slots=") then state.promote_slots = onoff("--promote-slots", a[16..])
    elsif starts_with?(a, "--unroll=") then state.unroll = onoff("--unroll", a[9..])
    elsif starts_with?(a, "--struct-slots=") then state.struct_slots = onoff("--struct-slots", a[15..])
    elsif starts_with?(a, "--pathb-c=") then state.pathb_c = a[10..]
    elsif starts_with?(a, "-fuse-ld=")
      name = a[9..]
      if ld_available.include?(name)
        state.ld_name = name
      else
        state.files << a
      end
    elsif a == "--obfuscate-kernels" then state.obfuscate = 1
    elsif a == "-fsanitize=address" then state.asan = 1
    elsif a == "-fsafe-pointers" then state.safeptr = 1
    elsif a == "-fno-safe-pointers" then state.safeptr = 0
    elsif a == "-fno-sanitize=address" then state.asan = 0
    elsif starts_with?(a, "-fsanitize=") || starts_with?(a, "-fsanitize-")
      raise NfcxxExit.new("nfcxx: #{a} is not supported (only -fsanitize=address; docs/notes/asan.md)", 2)
    elsif a == "-fno-omit-frame-pointer" || a == "-fomit-frame-pointer" then state.asanopts << a
    elsif starts_with?(a, "--dialect=")
      state.dialect = a[10..]
      state.dialect_asked = 1
    elsif starts_with?(a, "--gnu-version=")
      state.gnu = a[14..]
      state.gnu_user = state.gnu
    elsif a == "--freestanding" then state.freestanding = 1
    elsif a == "--cosmo" then state.cosmo = 1
    elsif starts_with?(a, "--target=") then state.target = a[9..]
    elsif starts_with?(a, "--trace=") then state.trace = a[8..]
    elsif starts_with?(a, "--module-dir=") then state.moddir = a[13..]
    elsif a == "-shared"
      state.shared = 1
      state.pic = 1
    elsif a == "-fPIC" || a == "-fpic" then state.pic = 1
    elsif a == "-rdynamic" then state.rdynamic = 1
    elsif a == "-c"
      state.compile_only = 1
      state.files << "-c"
    elsif a == "-o"
      state.out = args[i + 1].to_s
      state.outset = 1
      i += 1
    elsif starts_with?(a, "-std=c++") then state.std = "--c++#{a[8..]}"
    elsif starts_with?(a, "-std=gnu++") then state.std = "--c++#{a[10..]}"
    elsif a == "-E" then state.preprocess = 1
    elsif a == "-P" then state.ppflags << "-P"
    elsif a == "-x"
      state.xlang = args[i + 1].to_s
      i += 1
    elsif a == "-" then state.stdin_src = 1
    elsif a == "-pthread" then state.pthread = 1
    elsif a == "-fexceptions" || a == "-fwrapv" || a == "-fno-strict-aliasing" then nil
    elsif a == "-fno-sanitize=all" then state.sanitize = ""
    elsif starts_with?(a, "-fno-sanitize=") || starts_with?(a, "-fsanitize-")
      raise NfcxxExit.new("nfcxx: #{a} is not supported (only -fsanitize=undefined and its checks, docs/notes/ubsan.md)", 2)
    elsif a == "-pipe" then nil
    elsif a == "-fvisibility-inlines-hidden" || starts_with?(a, "-fvisibility=") then nil
    elsif a == "-fPIE" || a == "-fpie"
      state.pie_opts << "--c_to_obj_option" << "-fPIE"
    elsif a == "-pie"
      state.pie_opts << "--c_to_obj_option" << "-pie"
    elsif starts_with?(a, "-Wl,") then state.files << a
    elsif starts_with?(a, "-l") && a.length > 2 then state.files << a
    elsif a == "-Wno-narrowing" then state.diag_opts << "--diag_warning=narrowing_conversion"
    elsif starts_with?(a, "-W") || a == "-w" then nil
    elsif starts_with?(a, "-m") then state.isa << a
    elsif a == "-MD" || a == "-MMD" then state.depmode = a
    elsif a == "-MP" then state.depphony = "-MP"
    elsif a == "-MF"
      state.dfile = args[i + 1].to_s
      i += 1
    elsif a == "-MT" || a == "-MQ"
      state.dtarget = args[i + 1].to_s
      i += 1
    elsif a == "-include"
      state.preinc << args[i + 1].to_s
      i += 1
    elsif a == "-isystem"
      state.sysdirs << args[i + 1].to_s
      i += 1
    elsif starts_with?(a, "-isystem") && a.length > 8 then state.sysdirs << a[8..]
    elsif a.end_with?(".c") then state.cfiles << a
    elsif (starts_with?(a, "-I") || starts_with?(a, "-D") || starts_with?(a, "-U")) && a.length > 2
      state.cflags << a
      state.files << a
    elsif a == "-I" || a == "-D" || a == "-U"
      raise NfcxxExit.new("nfcxx: #{a} needs an argument", 2) unless i + 1 < n

      state.cflags << "#{a}#{args[i + 1]}"
      state.files << "#{a}#{args[i + 1]}"
      i += 1
    elsif a.end_with?(".o")
      state.files << a
      state.nobj += 1
    elsif starts_with?(a, "-") || a.end_with?(".a") || a.end_with?(".so")
      state.files << a
    elsif a.end_with?(".cu")
      state.cu_inputs << a
      state.files << a
      state.ncpp += 1
      state.srcs << a
    elsif a.end_with?(".cpp2")
      state.cpp2_inputs << a
      state.files << a
      state.ncpp += 1
      state.srcs << a
    else
      state.files << a
      state.ncpp += 1
      state.srcs << a
    end
    i += 1
  end
  state
end

def emit(state)
  scalars = %w[std out outset emit_c emit_hip backend backend_explicit path_b ir_opt ir_opt_set eh_unwind_on eh_shim_on
               cache_dir cache_log_file keep_intermediates time_log instantiate promote_slots unroll struct_slots pathb_c
               ld_name obfuscate dialect dialect_asked gnu gnu_user freestanding cosmo target trace moddir asan safeptr
               sanitize shared pic rdynamic compile_only pthread preprocess xlang stdin_src depmode dfile dtarget depphony
               ncpp nobj system_paths]
  scalars.each { |name| $stdout.write("#{name}=#{state.public_send(name)}\n") }
  %w[files cflags cfiles cu_inputs cpp2_inputs srcs ppflags pie_opts preinc sysdirs isa diag_opts asanopts].each do |name|
    state.public_send(name).each { |x| $stdout.write("#{name}+=#{x}\n") }
  end
end

# nfcxx's -fsyntax-only block, which runs before its setup: the compile again, without its object (a type check). Returns the
# command the bash runs as [kind, argv], kind RUN (the driver) or EXEC (nfcxx replaces itself), or nil when there is no
# -fsyntax-only. TMP stands for the temporary directory the bash makes for the object.
def syntax_only_plan(argv)
  return nil unless argv.include?("-fsyntax-only")
  args = argv.reject { |b| b == "-fsyntax-only" }
  return ["EXEC", ["nfcxx", *args]] if args.include?("-E")
  if args.include?("-o")
    # an explicit -o is honoured by the real compile: the object goes to the temporary directory instead
    rewritten = []
    skip = false
    args.each do |b|
      if skip
        skip = false
        rewritten << "TMP/x.o"
        next
      end
      skip = true if b == "-o"
      rewritten << b
    end
    return ["RUN", ["nfcxx", "-c", *rewritten]]
  end
  ["RUN", ["nfcxx", "-c", *args, "-o", "TMP/x.o"]]
end

# nfcxx's --bundle-* options (scripts/bundle-wrap.sh, before its setup): the driver runs again on the arguments without them,
# and a link then goes through the bundler. Returns the commands the bash runs as [kind, argv] (RUN, EXEC), or nil when
# no --bundle- option is given. ROOT stands for the repository. The bundler's build (ninja) is taken to succeed.
BUNDLE_NO_LINK = %w[-c -E -S -M -MM -fsyntax-only --emit-c].freeze

# the list of a --bundle-*=a,b option: read splits on the commas, and the empty field after a last comma is dropped
def bundle_list(value)
  parts = value.split(",", -1)
  parts.pop if parts.last == ""
  parts
end

def bundle_plan(argv)
  return nil unless (" " + argv.join(" ") + " ").include?(" --bundle-")
  driver = "ROOT/nfcxx"
  on = false
  link = true
  out = "a.out"
  prev = nil
  opts = []
  args = []
  argv.each do |a|
    out = a if prev == "-o"
    opts.push("-L", a) if prev == "-L"
    if a == "--bundle-libs"
      on = true
    elsif a.start_with?("--bundle-exclude=", "--bundle-only=", "--bundle-add=")
      flag = if a.start_with?("--bundle-exclude=") then "--exclude"
             elsif a.start_with?("--bundle-add=") then "--add"
             else "--only"
             end
      bundle_list(a.split("=", 2)[1]).each { |x| opts.push(flag, x) }
    elsif a.start_with?("--bundle-stubs=") then opts.push("--stubs", a[15..])
    elsif a.start_with?("--bundle-runpath=") then opts.push("--runpath", a[17..])
    elsif a.start_with?("--bundle-rpath=") then opts.push("--rpath", a[15..])
    elsif a.start_with?("--bundle-")
      raise NfcxxExit.new("nfcxx: unknown option #{a} (--bundle-libs, --bundle-exclude=, --bundle-only=, --bundle-add=, --bundle-stubs=, --bundle-runpath=, --bundle-rpath=)", 2)
    else
      args << a
      link = false if BUNDLE_NO_LINK.include?(a)
      opts.push("-L", a[2..]) if a.start_with?("-L") && a.length > 2
    end
    prev = a
  end
  raise NfcxxExit.new("nfcxx: the --bundle-* options need --bundle-libs", 2) unless on
  plan = [["RUN", [driver, *args]]]
  return plan unless link
  plan << ["EXEC", ["ROOT/build/nfcbundle", *opts, out, "-o", out]]
  plan
end

# ============================================================================================================================
# --cuda-driver= (scripts/cuda-driver-wrap.sh, cuda_driver_wrap; docs/notes/cuda-driver.md). The bash is sourced after the
# bundle re-run and before the setup, and it sees every argument: a link that names libcuda (-lcuda, -l:libcuda.so[.1], a
# path ending in libcuda.so[.1]) is run again through the shim and libcudart (EXEC), and otherwise the arguments go on
# without --cuda-driver=*. The toolkit's files and the machine are the facts the bash reads (CudaFacts, the options above).
# ============================================================================================================================

CUDA_LIBCUDA_PATTERNS = ["-lcuda", "-l:libcuda.so", "-l:libcuda.so.1", "*/libcuda.so", "*/libcuda.so.1"].freeze
CUDA_STATIC_PATTERNS = ["-lcudart_static", "*/libcudart_static.a"].freeze
CUDA_SHIM_ARCHIVE = "ROOT/build/cuda-driver/SHIM/libnfcxx_cudrv.a".freeze

# a bash case pattern: * matches a slash and a leading dot
def cuda_glob?(text, patterns)
  patterns.any? { |pattern| File.fnmatch(pattern, text, File::FNM_DOTMATCH) }
end

# The facts the bash reads from the machine and the filesystem. take(option) records one --nfcxx-* option of this section.
class CudaFacts
  attr_accessor :machine, :shim

  def initialize
    @machine = "x86_64"
    @shim = "ok"
    @files = []
    @dirs = []
    @rtv = {}
  end

  def file?(path)
    @files.include?(path)
  end

  def dir?(path)
    @dirs.include?(path)
  end

  def rtv(path)
    @rtv[path]
  end

  def take(option)
    if option.start_with?("--nfcxx-machine=") then @machine = option.delete_prefix("--nfcxx-machine=")
    elsif option.start_with?("--nfcxx-shim=") then @shim = option.delete_prefix("--nfcxx-shim=")
    elsif option.start_with?("--nfcxx-cuda-file=") then @files << option.delete_prefix("--nfcxx-cuda-file=")
    elsif option.start_with?("--nfcxx-cuda-dir=") then @dirs << option.delete_prefix("--nfcxx-cuda-dir=")
    elsif option.start_with?("--nfcxx-cuda-rtv=")
      path, version = option.delete_prefix("--nfcxx-cuda-rtv=").split("=", 2)
      @rtv[path] = version.to_s
    else
      return false
    end
    true
  end
end

# cuda_driver_wrap on argv (the arguments after the bundle re-run). Returns [plan, args]: plan is the commands the bash runs
# (the driver again, as EXEC), or nil when the link goes on with args (argv minus --cuda-driver=*). An error raises NfcxxExit
# with the bash's message and status; a note goes to stderr.
def cuda_driver_step(argv, env, facts)
  mode = env["NFCXX_CUDA_DRIVER"].to_s
  mode = "auto" if mode.empty?
  found = nil
  static = nil
  args = []
  argv.each do |a|
    if a.start_with?("--cuda-driver=")
      mode = a.delete_prefix("--cuda-driver=")
    elsif cuda_glob?(a, CUDA_LIBCUDA_PATTERNS)
      found = a
      args << a
    else
      static = a if cuda_glob?(a, CUDA_STATIC_PATTERNS)
      args << a
    end
  end
  unless %w[auto cudart libcuda].include?(mode)
    raise NfcxxExit.new("nfcxx: --cuda-driver=#{mode}: auto, cudart or libcuda", 2)
  end
  return [nil, args] if found.nil? || mode == "libcuda"

  # the toolkit: $CUDA_HOME, else the one the libcuda path is in, else /usr/local/cuda
  home = env["CUDA_HOME"].to_s
  if home.empty?
    if cuda_glob?(found, ["*/lib64/stubs/libcuda.so*", "*/lib64/libcuda.so*"])
      home = found[0...found.rindex("/lib64/")]
    elsif cuda_glob?(found, ["*/targets/*/lib/stubs/libcuda.so*"])
      home = found[0...found.rindex("/lib/stubs/")]
    end
    home = "/usr/local/cuda" unless !home.empty? && facts.file?("#{home}/include/cuda.h")
  end

  # the version is read from cuda_runtime_api.h; a missing header leaves it unknown (the bash reads it with || rtv=)
  header = "#{home}/include/cuda_runtime_api.h"
  rtv = facts.rtv(header)
  why = if facts.machine != "x86_64"
          "the shim is x86-64 only"
        elsif !facts.file?("#{home}/include/cuda.h") || !facts.file?("#{home}/include/cudaTypedefs.h")
          "no cuda.h and cudaTypedefs.h in #{home}/include"
        elsif !facts.file?(header)
          "no cuda_runtime_api.h in #{home}/include"
        elsif rtv.nil? || rtv.empty? || rtv.to_i < 12050
          "libcudart #{rtv.to_s.empty? ? "of unknown version" : rtv} is older than 12.5"
        elsif facts.shim.start_with?("error:")
          "the shim did not build: #{facts.shim.delete_prefix("error:")}"
        end
  if why
    raise NfcxxExit.new("nfcxx: --cuda-driver=cudart: #{why}", 1) if mode == "cudart"
    $stdout.flush
    $stderr.write("nfcxx: note: linking the CUDA driver library #{found} as named (#{why}; docs/notes/cuda-driver.md)\n")
    return [nil, args]
  end

  # every mention of libcuda goes; the first becomes the shim (and the static runtime, if the link has it, else -lcudart
  # with the toolkit's lib64 as a run path, when that directory exists)
  lib64 = "#{home}/lib64"
  replaced = []
  shimmed = false
  args.each do |a|
    unless cuda_glob?(a, CUDA_LIBCUDA_PATTERNS)
      replaced << a
      next
    end
    next if shimmed

    shimmed = true
    replaced << CUDA_SHIM_ARCHIVE
    if static
      replaced << static
    else
      replaced.push("-L#{lib64}", "-Wl,-rpath,#{lib64}") if facts.dir?(lib64)
      replaced << "-lcudart"
    end
  end
  [[["EXEC", ["ROOT/nfcxx", *replaced]]], args]
end

def main(argv)
  ld_available = []
  env = {}
  uid = "0"
  tmpdir = ""
  cuda_facts = CudaFacts.new
  # the configuration first: --ld-available=, --nfcxx-env=NAME=VALUE (repeated), --nfcxx-uid=, --nfcxx-tmpdir=
  while argv.first && argv.first.start_with?("--ld-available=", "--nfcxx-")
    option = argv.shift
    if option.start_with?("--ld-available=")
      ld_available = option[15..].split(",")
    elsif option.start_with?("--nfcxx-env=")
      name, value = option[12..].split("=", 2)
      env[name] = value.to_s
    elsif option.start_with?("--nfcxx-uid=")
      uid = option[12..]
    elsif option.start_with?("--nfcxx-tmpdir=")
      tmpdir = option[15..]
    elsif cuda_facts.take(option) then nil
    else
      raise NfcxxUnported, option
    end
  end
  plan = syntax_only_plan(argv)
  plan = [plan] if plan
  plan ||= bundle_plan(argv)
  plan, argv = cuda_driver_step(argv, env, cuda_facts) unless plan
  if plan
    plan.each { |kind, cmd| $stdout.write("#{kind} #{cmd.join(" ")}\n") }
    return 0
  end
  state = LoopState.new
  apply_environment(state, env, uid, tmpdir)
  state = run_loop(argv, state, ld_available)
  emit(state)
  0
rescue NfcxxExit => e
  $stdout.flush
  $stderr.write("#{e.message}\n") unless e.message.empty?
  e.status
rescue NfcxxUnported => e
  $stdout.flush
  $stderr.write("unported: #{e.message}\n")
  3
end

rc = main(ARGV)
exit(rc) if rc != 0
