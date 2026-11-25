#!/usr/bin/env ruby
# nfcxx's CUDA device build, ported from the CUDA helpers in nfcxx: cu_prepare (where the copy goes), cu_rewrite (the host
# copy, the device unit, the toolkit's version macros, the device image), cu_device_build (the device IR, the modules,
# ptxas), cu_amd_build (the amdgcn image), ir_opt_device and cu_device_key (the device image cache key). The bash driver
# calls --execute for each .cu input (cu_rewrite) and --cu-dir for the copy's directory (cu_prepare). The bash originals are
# kept as tests/nfcxx-cuda-device/nfcxx-bash (the oracle of tests/nfcxx-cuda-device/run.sh and key.sh).
#
# The port prints the commands the bash would run, one per line (tab-separated with --tabs, for scripts/nfcxx-run.rb; with
# spaces otherwise, as the test's oracle prints them):
#   RUN ARGV...   a command: the rewriter, pathb-dump, pathb-ir-opt (through ruby), pathb-ptx-emit, pathb-amdgpu-emit,
#                 ptxas, clang, mkdir, mv and rm; RUN ensure_tool DIR OUT is the bash's ensure_tool (runner: builds when stale)
#   CP ARGV...    a cp (CP -R for a directory): the device IR kept by NFCXX_KEEP_DEVICE_IR, the device image cache entry
#   JOBS N        the ptxas jobs (NFCXX_PTXAS_JOBS, default 4): the bash assembles the groups through xargs -P N
#   OUT FILE      the next RUN's standard output goes to FILE (the bash's > FILE); APP FILE: >> FILE
#   ENV1 NAME=V   the next RUN's environment has NAME=V (the bash's NAME=V cmd), e.g. NFCXX_SM for the device rewrite
# A plan is run in phases, because the kernel and group names are made by the commands themselves:
#   --phase=prep   the host copy and the device unit (the rewriter); the kernel list is then read from the device unit
#   --phase=emit   the device IR and the module images (needs --kernel facts, from that list)
#   --phase=finish the ptxas run of each group, the device image cache store and the embedding into the copy (needs --group
#                  facts, the group files)
#   --phase=all    the three together (the tests' default; needs both kind of facts)
# Nothing here runs a tool in text mode. The facts of the tree are inputs, as the other ports take them:
#   --nfcxx-file=PATH, --nfcxx-dir=PATH   the paths that exist (a cache entry, a CUDA header); --live reads the file system
#   --kernel=NAME                         the kernels the rewriter listed, in order (none: no device image)
#   --group=NAME                          the group files the emitter wrote (gNNNN.ptx; the bash lists them in glob order)
#   --cache-key=KEY                       the device image cache key (text mode; --execute computes it, as cu_device_key)
# The environment is read from --nfcxx-env=NAME=VALUE (the variables the bash reads: NFCXX_SM, NFCXX_PTXAS, NFCXX_CUDA_*,
# NFCXX_OBFUSCATE_*, NFCXX_CU_CACHE, CUDA_HOME, HOME, XDG_CACHE_HOME, RUBY, ...). The options --obfuscate-kernels,
# --promote-slots=V, --unroll=V, --struct-slots=V and --ir-opt=V are the driver's own arguments, as the bash reads them.
# The toolkit's version macros are read from the header files that exist (their text, not a tool's output).
# The temporary directory of the bash (cudatmp) is --tmp=DIR. The PID of a cache store (.tmp.$$) prints as PID.
#
# --execute (what nfcxx's cu_rewrite does): the plan is run, group by group, with scripts/nfcxx-run.rb. A group is one
# command, or the commands the bash runs between two of its checks; a failed group stops with the bash's status (and the
# bash's message, when it has one), and ptxas runs every group before it stops, as xargs does (status 123). Each stage the
# bash traces (trace_start / trace_end) is a span of scripts/trace.rb, recorded in the bash's order with the bash's name.
# The copy, the temporary directory, the groups directory (--keep-dir, the copy's directory with -c), the trace unit and
# the driver's PID are the bash's (--copy, --tmp, --keep-dir, --trace-unit, --bash-pid); the cache log is --cache-log=FILE.
#
#   ruby scripts/nfcxx-cuda-device.rb [OPTION]... SRC.cu
#   ruby scripts/nfcxx-cuda-device.rb --cu-dir=OBJ    prints the directory of the copy of a -c compile of OBJ (cu_prepare)
#   --root=DIR                nfcxx's root
#   --tmp=DIR                 the temporary directory
#   --tabs                    tab-separated lines
#   --phase=prep|emit|finish|all
#   --live                    the facts are the file system's (exists? is File.exist?)
#   --nfcxx-env=NAME=VALUE    the environment (repeated)
#   --cflag=ARG               a cflags word, in order (-I, -D and -U are used; repeated)
#   --compile --out=PATH      -c and its -o: the copy and the groups go to the cache (NFCXX_CU_CACHE)
#   --ir-opt=V                --ir-opt (default inline,sroa; off turns the IR passes off)
#   --obfuscate-kernels       the driver's option (NFCXX_OBFUSCATE_KERNELS=1 is the environment's)
#   --promote-slots=V, --unroll=V, --struct-slots=V   the driver's options (the environment's values otherwise)
#   --cache-dir=DIR           the device image cache (--cache)
#   --cache-key=KEY           its key (text mode; cu_device_key)
#   --nfcxx-file=PATH, --nfcxx-dir=PATH, --kernel=NAME, --group=NAME
#   --execute                 runs the plan (the bash's cu_rewrite); --copy=PATH, --keep-dir=DIR, --trace-unit=U,
#                             --bash-pid=N, --cache-log=FILE: the driver's values for --execute
# Exit: 0; 2 with nfcxx's message; 3 with "unported: ..." for what is not ported (text mode: the AMD GPU's architecture and
# the amdgcn clang when NFCXX_AMDGPU_ARCH and NFCXX_AMDGPU_CLANG are not set, and a device image cache without --cache-key).

require "digest"
require "open3"
require "rbconfig"
require "securerandom"
require_relative "trace"
require_relative "amdgpu-env"
require_relative "driver-state"
require "stringio"
require_relative "nfcxx-cu-apply"
require_relative "nfcxx-state"

RUNNER_PATH = File.expand_path("nfcxx-run.rb", __dir__)

class CudaUnported < StandardError; end
class CudaRefused < StandardError; end

# A stop of --execute: the driver's status. Its message (the bash's) is printed already.
class CudaStop < StandardError
  attr_reader :status

  def initialize(status)
    super("stop #{status}")
    @status = status
  end
end

# bash's printf %q for one argument (bash 5.2 in the C locale): empty is '', the shell's specials and a leading # or ~ are
# backslashed, and a control or non-ASCII byte is $'...' with octal escapes.
def bash_quote(s)
  return "''" if s.empty?

  if s.b.match?(/[^\x20-\x7e]/n)
    body = s.bytes.map do |b|
      case b
      when 0x5c then "\\\\"
      when 0x27 then "\\'"
      when 0x0a then "\\n"
      when 0x09 then "\\t"
      when 0x0d then "\\r"
      when 0x20..0x7e then b.chr
      else format("\\%03o", b)
      end
    end
    return "$'#{body.join}'"
  end
  # always: the shell's specials (a comma too); at the start: # and ~; after = or :, ~ (a tilde expansion of an assignment)
  s.gsub(/[ !"$&'()*,;<>?\[\\\]^`{|}]|\A[#~]|(?<=[=:])~/) { "\\#{$&}" }
end

# realpath -m (DriverState.realpath_m)
def realpath_m(path) = DriverState.realpath_m(path)

# cu_prepare's directory of the copy of a -c compile of OBJ (the per-user cache, keyed by the absolute object path)
def cu_dir(obj, env = ENV)
  key = Digest::SHA1.hexdigest("#{realpath_m(obj)}\n")[0, 16]
  cache = nonempty(env["NFCXX_CU_CACHE"]) ||
          "#{nonempty(env["XDG_CACHE_HOME"]) || "#{nonempty(env["HOME"]) || "/tmp"}/.cache"}/nfcxx"
  "#{cache}/cu/#{key}"
end

def nonempty(v) = (v.nil? || v.empty?) ? nil : v

# cu_prepare's per-input data: for each .cu input, the directory of its source (realpath of its dirname: the -I that quoted
# includes need) and its copy, DIR/<name without .cu>.cpp. Driver-state groups: "sdirs" and "copies", one value per input.
# A source directory that does not exist ends the step with realpath's message and status 1 (nfcxx runs under set -e).
def cu_copies(dir, srcs)
  sdirs = srcs.map do |s|
    DriverState.gnu_realpath(File.dirname(s))
  rescue SystemCallError
    raise CuCopiesFailed, "realpath: #{File.dirname(s)}: No such file or directory"
  end
  copies = srcs.map { |s| "#{dir}/#{File.basename(s, ".cu")}.cpp" }
  [sdirs, copies]
end

class CuCopiesFailed < StandardError; end

# cu_prepare's loop (slice 5): for each .cu input, in order, the -I of its source directory is added to the flags, and the
# rewrite runs with the options of rewrite_argv (in this process: plan_for(o).execute). The state comes in as records (the
# inputs, the directory, the flags, the rewrite's settings, the preinclude list, cuda_opts and whether the EDG launch is
# on) and goes back as the groups sdirs, copies, cuda and preinc. A failing rewrite stops with its status.
def cu_prepare_run(g)
  inputs = g["inputs"] || []
  dir = (g["dir"] || [])[0]
  sdirs, copies = cu_copies(dir, inputs)
  cflags = (g["cflags"] || []).dup
  root = (g["root"] || [])[0]
  hdr = "#{root}/lib/cuda/nfcxx_cuda.h"
  preinc = (g["preinc"] || []).dup
  cuda = (g["cuda"] || []).dup
  inputs.each_with_index do |src, i|
    cflags << "-I#{sdirs[i]}"
    rg = g.merge("cflags" => cflags, "copy" => [copies[i]])
    o = parse_options(rewrite_argv(rg) + [src])
    status = plan_for(o).execute
    return [nil, status] unless status == 0
    cuda = ["--cuda"] if (g["edg_launch"] || []).first == "1"
    preinc << hdr unless preinc.include?(hdr)
  end
  [[["sdirs", sdirs], ["copies", copies], ["cuda", cuda], ["preinc", preinc]], 0]
end

# cu_prepare's state (the driver's values, as key=value arguments; a list is its values joined by ASCII 31, an empty list is
# empty): the state records the driver's state_put wrote, read back as the groups cu_prepare_run takes. ir_opt is a group
# with its value only when ir_opt_set is 1 (the driver's --ir-opt, even when empty).
def cu_state_groups(a)
  s = ->(k) { a[k].to_s }
  list = ->(k) { s[k].empty? ? [] : s[k].split("\x1f", -1) }
  st = NfcxxState.new
  st.add("root", s["root"]).add("tmp", s["tmp"]).add("keep", s["keep"]).add("bash_pid", s["bash_pid"])
  st.add("trace_unit", s["trace_unit"]).add("dir", s["dir"])
  st.add("inputs", *list["inputs"]).add("cflags", *list["cflags"])
  st.add("obfuscate", s["obfuscate"])
  st.add("ir_opt", *(s["ir_opt_set"] == "1" ? [s["ir_opt"]] : []))
  st.add("promote_slots", s["promote_slots"]).add("unroll", s["unroll"]).add("struct_slots", s["struct_slots"])
  st.add("cache_dir", s["cache_dir"]).add("cache_log", s["cache_log"])
  st.add("preinc", *list["preinc"]).add("cuda", *list["cuda"])
  st.add("edg_launch", s["edg_launch"])
  DriverState.read_groups(st.records)
end

# cu_rewrite's --execute options (the bash built them from the driver's state; the bash now writes that state as records,
# with state_put, and runs this): the root, the temporary and copy directories, the keep directory, the bash's pid, the trace
# unit, one --cflag per word, --obfuscate-kernels when the flag is set, --ir-opt when it is set (even empty), the promotion,
# unrolling and struct-slot settings, and the cache options when they are not empty. The source is appended by the bash.
def rewrite_argv(g)
  s = ->(n) { (g[n] || [])[0] }
  argv = ["--execute", "--root=#{s["root"]}", "--tmp=#{s["tmp"]}", "--copy=#{s["copy"]}", "--keep-dir=#{s["keep"]}",
          "--bash-pid=#{s["bash_pid"]}", "--trace-unit=#{s["trace_unit"]}"]
  (g["cflags"] || []).each { |f| argv << "--cflag=#{f}" }
  argv << "--obfuscate-kernels" if s["obfuscate"] == "1"
  argv << "--ir-opt=#{s["ir_opt"]}" if (g["ir_opt"] || []).any?
  argv += ["--promote-slots=#{s["promote_slots"]}", "--unroll=#{s["unroll"]}", "--struct-slots=#{s["struct_slots"]}"]
  argv << "--cache-dir=#{s["cache_dir"]}" unless s["cache_dir"].to_s.empty?
  argv << "--cache-log=#{s["cache_log"]}" unless s["cache_log"].to_s.empty?
  argv
end


class CudaDevicePlan
  PHASES = %i[all prep emit finish].freeze
  attr_reader :copy, :dev, :groups_dir   # the paths the plan writes (set by run)

  def initialize(opts)
    @root = opts.fetch(:root)
    @tmp = opts.fetch(:tmp)
    @env = opts.fetch(:env)
    @files = opts.fetch(:files)
    @dirs = opts.fetch(:dirs)
    @live = opts.fetch(:live, false)
    @tabs = opts.fetch(:tabs, false)
    @phase = opts.fetch(:phase, :all)
    @cflags = opts.fetch(:cflags).dup
    @kernels = opts.fetch(:kernels)
    @groups = opts.fetch(:groups).sort
    @compile = opts.fetch(:compile)
    @out = opts[:out]
    @ir_opt = opts[:ir_opt]
    @obfuscate = opts.fetch(:obfuscate, false)
    @promote = opts[:promote]
    @unroll = opts[:unroll]
    @struct_slots = opts[:struct_slots]
    @cache_dir = opts[:cache_dir]
    @cache_key = opts[:cache_key]
    @src = opts.fetch(:src)
    # --execute: the bash's own facts (the copy, the groups directory, the trace, the cache log) and the live file system
    @exec = opts.fetch(:exec, false)
    @copy_opt = opts[:copy]
    @keep_dir = opts[:keep_dir]
    @trace_unit = opts[:trace_unit] || ""
    @bash_pid = opts[:bash_pid] || Process.pid
    @cache_log = opts[:cache_log]
    @append_src_dir = opts.fetch(:append_src_dir, true)
    @seed = nil
    @lines = []
    @pending = nil     # execute: the commands of the group being built
    @plan_n = 0
    @live = true if @exec
    @tabs = true if @exec
  end

  # The lines of the plan for the phase: the copy and the device unit, then the device image. With --execute the plan runs
  # instead, and the lines are not kept (execute returns the status).
  def run
    raise CudaRefused, "unknown phase #{@phase}" unless PHASES.include?(@phase)

    setup
    return execute_plan if @exec

    prep if %i[all prep].include?(@phase)
    return @lines if @phase == :prep || @kernels.empty?

    device_build if %i[all emit].include?(@phase)
    finish if %i[all finish].include?(@phase)
    @lines
  end

  # --key: the device image cache key of this unit (cu_device_key), with the options and the environment the driver has
  def key_only
    setup
    device_key
  end

  # The names and the tool paths of the unit, from the options and the environment (run, key_only).
  def setup
    @base = File.basename(@src, ".cu")
    @dir = @tmp
    if @exec
      @cu_keep = @keep_dir || ""
      @dir = @cu_keep.empty? ? @tmp : @cu_keep
      @copy = @copy_opt
      @dev = "#{@tmp}/#{@base}.dev"
    elsif @compile
      obj = @out || "#{@base}.o"
      @dir = cu_dir(obj, @env)
    end
    @cu_keep ||= @compile ? @dir : ""
    @cflags << "-I#{File.realpath(File.dirname(@src))}" if @append_src_dir
    @copy ||= "#{@dir}/#{@base}.cpp"
    @dev ||= "#{@tmp}/#{@base}.dev"
    @sm = env("NFCXX_SM", "75")
    @ptxas = env("NFCXX_PTXAS") || "#{env("CUDA_HOME") || "/usr/local/cuda"}/bin/ptxas"
    @ext = env("NFCXX_CUDA_JIT", "0") == "1" ? "ptx" : "cubin"
    @groups_dir = "#{@cu_keep.empty? ? @tmp : @cu_keep}/#{@base}.groups"
    @incs = @cflags.select { |f| f.start_with?("-I") }
    @defs = @cflags.select { |f| f.start_with?("-D", "-U") }
    @ver = version_opts(@incs, @defs)
    @obf = obfuscate_opts
    @rw = env("NFCXX_CUDA_EDG_LAUNCH", "1") == "1" ? ["--edg-launches"] : []
    @hs = env("NFCXX_CUDA_HOST_SYMBOLS") ? ["--host-symbols=#{env("NFCXX_CUDA_HOST_SYMBOLS")}"] : []
  end

  # --execute: the bash's cu_rewrite, run (see the header). Returns the driver's status.
  def execute
    run
    0
  rescue CudaStop => e
    e.status
  end

  private

  def env(name, default = nil)
    v = @env[name]
    (v.nil? || v.empty?) ? default : v
  end

  def amd? = env("NFCXX_CUDA_TARGET", "nvidia") == "amdgpu"

  def emit_line(kind, argv)
    line = [kind, *argv].join(@tabs ? "\t" : " ")
    if @exec
      raise "internal: a command outside a group (--execute)" if @pending.nil?

      @pending << line
    else
      @lines << line
    end
  end

  def run_cmd(*argv)
    emit_line("RUN", argv)
  end

  def cp(*argv)
    emit_line("CP", argv)
  end

  # OUT, APP and ENV1 are the prefixes of the next RUN (the bash's redirection and environment prefix)
  def out_to(file) = emit_line("OUT", [file])
  def app_to(file) = emit_line("APP", [file])
  def env1(name, value) = emit_line("ENV1", ["#{name}=#{value}"])

  def exists?(path)
    return File.exist?(path) if @live

    @files.include?(path) || @dirs.include?(path)
  end

  def rewriter = "#{@root}/build/cuda-rewrite"
  def pathb_dump = "#{@root}/scripts/pathb-dump.rb"
  def ptx_emit = "#{@root}/build/pathb-ptx-emit"

  # the bash's ensure_tool: always called; the runner decides whether the tool is stale
  def ensure_tool(dir, out)
    run_cmd("ensure_tool", dir, out)
  end

  # ---- execute: groups, spans and the bash's messages

  # A group of commands, in the bash's order. In text mode its commands are the plan's lines and the block only builds them.
  # In execute mode they run now, as one plan: a failure stops with fail_status (default: the command's status) and fail,
  # the bash's message on stderr. soft: the failure is returned and the bash goes on (cache store, ptxas).
  def group(fail: nil, fail_status: nil, soft: false)
    unless @exec && @pending.nil?
      yield
      return 0
    end

    @pending = []
    begin
      yield
      lines = @pending
    ensure
      @pending = nil
    end
    st = run_group(lines)
    return 0 if st.zero?
    return st if soft

    $stderr.puts(fail) if fail
    raise CudaStop.new(fail_status || st)
  end

  def run_group(lines)
    return 0 if lines.empty?

    file = File.join(@tmp, "plan-#{@plan_n += 1}.plan")
    File.write(file, lines.join("\n") + "\n")
    system(RbConfig.ruby, RUNNER_PATH, "--root=#{@root}", "--tmp=#{@tmp}", "--plan=#{file}")
    $?.exitstatus || 128 + ($?.termsig || 0)
  end

  # the bash's trace_start / trace_end around a stage: a span of scripts/trace.rb (its unit and the driver's pid, as the bash's).
  # name may be a proc, evaluated after the stage (the emitter's group count).
  def with_span(name)
    return yield unless @exec

    t0 = NfccxxTrace.start(@env)
    yield
    label = name.respond_to?(:call) ? name.call : name
    NfccxxTrace.span(t0, label, "cuda", unit: @trace_unit, pid: @bash_pid, env: @env)
  end

  # the bash's cache_log: one line appended under a lock directory (parallel compiles share the file)
  def cache_log(text)
    return unless @exec && @cache_log && !@cache_log.empty?

    lock = "#{@cache_log}.lock"
    sleep 0.05 until (Dir.mkdir(lock) rescue nil)
    begin
      File.open(@cache_log, "a") { |f| f.write(text + "\n") }
    ensure
      Dir.rmdir(lock) rescue nil
    end
  end

  def exec_fail(status, message)
    $stderr.puts message
    raise CudaStop.new(status)
  end

  # the stages of --execute: the host copy, the device unit, then the device image (the bash's cu_rewrite). The copy is
  # written in place (prep truncates it, finish appends the images), so two compiles of one object, which share the copy's
  # path, would interleave and append the images twice (a parallel build that repeats a unit). A lock beside the copy
  # serializes the stages; the host compile that reads the copy afterwards is not under it.
  def execute_plan
    File.open("#{@copy}.lock", File::RDWR | File::CREAT, 0o644) do |lock|
      lock.flock(File::LOCK_EX)
      execute_device_stages
    end
  end

  def execute_device_stages
    prep
    kfile = "#{@dev}.kernels"
    return [] unless File.size?(kfile)   # the bash's [ -s "$dev.kernels" ] || return 0

    @kernels = File.readlines(kfile, chomp: true).reject(&:empty?)
    return [] if @kernels.empty?

    if amd?
      amd_build
    else
      device_build
      finish
    end
    []
  end

  # ---- the stages (text and execute)

  # cu_rewrite up to the device image: the host copy, then the device unit (its kernel list is the next phase's fact).
  def prep
    with_span("cuda-rewrite (host copy): #{@base}.cu") do
      group do
        run_cmd("mkdir", "-p", @dir) if @compile && !@exec
        out_to(@copy)
        run_cmd(rewriter, *@incs, *@defs, *@obf, *@rw, @src)
      end
    end
    with_span("cuda-rewrite (device unit): #{@base}.cu") do
      group do
        env1("NFCXX_SM", @sm)
        out_to("#{@dev}.cpp")
        run_cmd(rewriter, *@incs, *@defs, *@ver, *@obf, *@hs, "--device", "--kernels=#{@dev}.kernels", @src)
      end
    end
  end

  # The device image cache entry of this unit (--cache-dir with the key), or nil. A hit has the IR and the groups.
  def cache_entry
    @cache_entry ||= device_cache_entry
  end

  def cache_hit? = !cache_entry.nil? && exists?("#{cache_entry}/ir")

  # the device image: cu_device_build (or cu_amd_build), with the groups in @groups_dir. A cache hit copies them instead.
  def device_build
    return amd_build if amd?

    group(fail_status: 1) do
      ensure_tool("#{@root}/tools/pathb-ptx-emit", ptx_emit)
      run_cmd("rm", "-rf", @groups_dir)
    end
    @cache_key = device_key if @exec && cache_dir_set? && @cache_key.nil?
    if cache_hit?
      group do
        cp("#{cache_entry}/ir", "#{@dev}.ir")
        cp("-R", "#{cache_entry}/groups", @groups_dir)
      end
      cache_log("== #{@base}.cu device unit\nkey #{@cache_key}\nhit")
      return
    end
    cache_log("== #{@base}.cu device unit\nkey #{@cache_key}\nmiss") if cache_entry

    with_span("pathb-dump --ir (device front end): #{File.basename(@src)}") do
      group(fail: front_end_message, fail_status: 2) do
        out_to("#{@dev}.ir")
        run_cmd(pathb_dump, "--cuda-device", *@defs, *@ver, "--ir", "--freestanding", "#{@dev}.cpp")
      end
      ir_opt("#{@dev}.ir")
    end
    kopts = @kernels.map { |k| "--kernel=#{k}" }
    inl = []
    inl << "--inline=off" if env("NFCXX_INLINE_DEVICE", "1") == "0"
    inl << "--promote=off" if promote_slots == "0"
    inl << "--unroll=off" if unroll == "0"
    inl << "--struct-slots=off" if struct_slots == "0"
    with_span(-> { "pathb-ptx-emit --emit: #{File.basename(@src)} (#{groups_on_disk.size} groups)" }) do
      group do
        run_cmd(ptx_emit, "--emit", "--sm=#{@sm}", "--f2i=convert", "--int=gpu", *inl, "--groups-dir=#{@groups_dir}",
                "--max-const-bytes=#{env("NFCXX_CUDA_MAX_CONST_BYTES", "65536")}",
                "--max-ptx-lines=#{env("NFCXX_CUDA_MAX_PTX_LINES", "1000000")}", *kopts, "#{@dev}.ir")
      end
    end
  end

  def front_end_message
    "nfcxx: #{@src}: device code: the front end refused it (see above; needs scripts/setup-pathb.sh)"
  end

  # the groups' cubins (ptxas, NFCXX_CUDA_JIT=0), the store of a miss in the device image cache, then the embedding of the
  # images into the copy (cu_rewrite's last step, appended with >>)
  def finish
    return if amd?

    unless cache_hit?
      if @ext == "cubin"
        names = @exec ? groups_on_disk : @groups
        with_span("ptxas: #{File.basename(@src)}") do
          group { emit_line("JOBS", [env("NFCXX_PTXAS_JOBS", "4")]) }
          status = 0
          names.each do |g|
            # xargs -P runs every group, then reports a failure (123) for any of them
            st = group(soft: true) do
              run_cmd(@ptxas, "-arch=sm_#{@sm}", "#{@groups_dir}/#{g}", "-o", "#{@groups_dir}/#{g.sub(/\.ptx\z/, "")}.cubin")
            end
            status = 123 unless st.zero?
          end
          raise CudaStop.new(status) unless status.zero?
        end
      end
      cache_store if cache_entry
    end
    with_span("pathb-ptx-emit --embed: #{File.basename(@src)}") do
      group do
        app_to(@copy)
        run_cmd(ptx_emit, "--embed", "--groups=#{@groups_dir}", "--ext=#{@ext}", "#{@dev}.ir", "#{@dev}.kernels",
                "#{@dev}.kernels.addr")
      end
    end
  end

  def promote_slots = @promote || env("NFCXX_PROMOTE_SLOTS", "1")
  def unroll = @unroll || env("NFCXX_UNROLL", "1")
  def struct_slots = @struct_slots || env("NFCXX_STRUCT_SLOTS", "1")

  # ir_opt_device: the IR passes on the device IR in place; NFCXX_KEEP_DEVICE_IR keeps copies before (.pre) and after (.post).
  def ir_opt(ir)
    v = @ir_opt || "inline,sroa"
    return if v.empty? || v == "off"

    keep = env("NFCXX_KEEP_DEVICE_IR")
    group { cp(ir, "#{keep}.pre") } if keep
    opts = v.split(",").reject(&:empty?).map { |p| "--#{p}" }
    group(fail: "nfcxx: the IR passes failed on #{ir} (--ir-opt=off turns them off)", fail_status: 2) do
      out_to("#{ir}.opt")
      run_cmd(env("RUBY", "ruby"), "#{@root}/scripts/pathb-ir-opt.rb", *opts, ir)
      run_cmd("mv", "#{ir}.opt", ir)
    end
    group { cp(ir, "#{keep}.post") } if keep
  end

  # cu_amd_build: the same device IR, then pathb-amdgpu-emit, clang for the amdgcn target and the embed.
  def amd_build
    arch, clang = amd_tools
    amd_emit = "#{@root}/build/pathb-amdgpu-emit"
    group(fail_status: 1) { ensure_tool("#{@root}/tools/pathb-amdgpu-emit", amd_emit) }
    group(fail: front_end_message, fail_status: 2) do
      out_to("#{@dev}.ir")
      run_cmd(pathb_dump, "--cuda-device", *@defs, *@ver, "--ir", "--freestanding", "#{@dev}.cpp")
    end
    ir_opt("#{@dev}.ir")
    kopts = @kernels.map { |k| "--kernel=#{k}" }
    group do
      out_to("#{@dev}.ll")
      run_cmd(amd_emit, *kopts, "#{@dev}.ir")
    end
    group do
      run_cmd(clang, "-target", "amdgcn-amd-amdhsa", "-mcpu=#{arch}", "-O2", "-nogpulib", "#{@dev}.ll", "-o", "#{@dev}.hsaco")
    end
    group do
      app_to(@copy)
      run_cmd(ptx_emit, "--embed", "#{@dev}.hsaco", "#{@dev}.ir", "#{@dev}.kernels", "#{@dev}.kernels.addr")
    end
  end

  # the architecture and the clang of cu_amd_build (scripts/amdgpu-env.rb finds them; NFCXX_AMDGPU_ARCH and NFCXX_AMDGPU_CLANG
  # override). Text mode cannot plan without them (unported); execute stops with the bash's message.
  def amd_tools
    if @exec
      arch = AmdgpuEnv.arch(@env) or exec_fail(2, "nfcxx: #{@src}: NFCXX_CUDA_TARGET=amdgpu: no AMD GPU found (set NFCXX_AMDGPU_ARCH, e.g. gfx1151)")
      clang = AmdgpuEnv.clang(@env) or exec_fail(2, "nfcxx: #{@src}: NFCXX_CUDA_TARGET=amdgpu: no clang with the amdgcn target (set NFCXX_AMDGPU_CLANG)")
      return [arch, clang]
    end
    arch = env("NFCXX_AMDGPU_ARCH") or
      raise CudaUnported, "the AMD GPU's architecture (scripts/amdgpu-env.rb finds it in KFD; NFCXX_AMDGPU_ARCH overrides)"
    clang = env("NFCXX_AMDGPU_CLANG") or
      raise CudaUnported, "the amdgcn clang (scripts/amdgpu-env.rb searches for it; NFCXX_AMDGPU_CLANG overrides)"
    [arch, clang]
  end

  def cache_dir_set? = !(@cache_dir.nil? || @cache_dir.empty?)

  def device_cache_entry
    return nil unless cache_dir_set?
    raise CudaUnported, "the device image cache key (cu_device_key; the port takes it as --cache-key=)" if @cache_key.nil?

    "#{@cache_dir}/cu-device/#{@cache_key}"
  end

  # The store of a miss: a whole entry appears at once (a rename), so a partial copy is never a hit. A failure is a miss
  # next time, not a failed build (the bash's `|| true` and its chain).
  def cache_store
    ctmp = "#{cache_entry}.tmp.#{@exec ? @bash_pid : "PID"}"
    group(soft: true) do
      run_cmd("mkdir", "-p", ctmp)
      cp("#{@dev}.ir", "#{ctmp}/ir")
      cp("-R", @groups_dir, "#{ctmp}/groups")
      run_cmd("mv", ctmp, cache_entry) unless exists?(cache_entry)
    end
    group(soft: true) { run_cmd("rm", "-rf", ctmp) }
  end

  # cu_device_key: the device image cache key of this unit (the bash's text, hashed the same way)
  def device_key
    text = +"nfcxx-cu-device-1\nsm #{@sm} ext #{@ext}\nopts:"
    # printf ' %q' "$@": with no argument the format is printed once with an empty one (" ''")
    args = @defs + @ver
    (args.empty? ? [""] : args).each { |a| text << " " << bash_quote(a) }
    text << "\nconst #{env("NFCXX_CUDA_MAX_CONST_BYTES", "65536")} lines #{env("NFCXX_CUDA_MAX_PTX_LINES", "1000000")}\n"
    text << "inline #{env("NFCXX_INLINE_DEVICE", "1")}\n"
    text << "promote #{promote_slots}\n" << "unroll #{unroll}\n" << "struct-slots #{struct_slots}\n"
    text << (@ir_opt.nil? ? "ir-opt inline,sroa\n" : "ir-opt #{@ir_opt}\n")
    text << sha_line(File.join(@root, "scripts", "pathb-ir-opt.rb"))
    text << sha_line("#{@dev}.cpp") << sha_line("#{@dev}.kernels")
    text << sha_line(pathb_dump) << sha_line(File.join(@root, "scripts", "host-sys.rb"))
    [env("PATHB_CPFE") || "#{@root}/build/pathb/cmake/bin/cpfe", ptx_emit].each do |f|
      text << (File.file?(f) ? sha_line(f) : "missing #{f}\n")
    end
    text << digest_line(pathb_base_files.map { |f| File.binread(f) }.join)
    text << ptxas_version_line if @ext == "cubin"
    Digest::SHA256.hexdigest(text)[0, 40]
  end

  # cache_sha < FILE: the hash line of sha256sum (empty when FILE does not exist, as the bash's redirection fails)
  def sha_line(path)
    return "" unless File.file?(path)

    digest_line(File.binread(path))
  end

  def digest_line(data) = "#{Digest::SHA256.hexdigest(data)}  -\n"

  # the regular files of PATHB_BASE (find -maxdepth 1 -type f, sorted), which the key hashes together
  def pathb_base_files
    base = env("PATHB_BASE") || "#{@root}/build/pathb/edg-base"
    return [] unless Dir.exist?(base)

    Dir.children(base).map { |n| File.join(base, n) }
       .select { |p| File.file?(p) && !File.symlink?(p) }.sort
  end

  # the last line of the ptxas version (2>&1 | tail -1); nothing when ptxas prints nothing
  def ptxas_version_line
    out = begin
      Open3.capture2e(@ptxas, "--version")[0]
    rescue SystemCallError
      ""
    end
    out.lines.last.to_s
  end

  def groups_on_disk
    return [] unless Dir.exist?(@groups_dir)

    Dir.children(@groups_dir).select { |f| f.start_with?("g") && f.end_with?(".ptx") }.sort
  end

  def obfuscate_opts
    return [] unless @obfuscate || env("NFCXX_OBFUSCATE_KERNELS", "0") != "0"

    @seed ||= env("NFCXX_OBFUSCATE_SEED") || SecureRandom.hex(16)
    ["--obfuscate=#{@seed}"]
  end

  # The version macros of the device pass, from the first include directory (the -I ones, then CUDA_HOME's) that has a
  # cuda_runtime_api.h. A -D or -U of the same name on the command line wins.
  def version_opts(incs, defs)
    out = []
    dirs = incs.map { |f| f[2..] } + ["#{env("CUDA_HOME") || "/usr/local/cuda"}/include"]
    dirs.each do |d|
      next unless exists?("#{d}/cuda_runtime_api.h")

      [["CUDART_VERSION", "cuda_runtime_api.h"], ["CUDA_VERSION", "cuda.h"]].each do |name, file|
        next if defs.any? { |f| f == "-D#{name}" || f.start_with?("-D#{name}=") || f == "-U#{name}" }

        v = version_of("#{d}/#{file}", name)
        out << "-D#{name}=#{v}" if v
      end
      break
    end
    out
  end

  def version_of(path, name)
    return nil unless exists?(path)

    File.foreach(path) do |line|
      m = line.match(/\A#define #{name} +([0-9]+)/)
      return m[1] if m
    end
    nil
  end
end

def parse_options(argv)
  o = { env: {}, files: [], dirs: [], cflags: [], kernels: [], groups: [], compile: false, live: false, tabs: false,
        phase: :all, obfuscate: false, promote: nil, unroll: nil, struct_slots: nil,
        out: nil, ir_opt: nil, cache_dir: nil, cache_key: nil, root: nil, tmp: nil, src: nil,
        execute: false, copy: nil, keep_dir: nil, trace_unit: nil, bash_pid: nil, cache_log: nil }
  argv.each do |a|
    case a
    when /\A--root=(.*)\z/m then o[:root] = $1
    when /\A--tmp=(.*)\z/m then o[:tmp] = $1
    when /\A--nfcxx-env=([^=]*)=(.*)\z/m then o[:env][$1] = $2
    when /\A--nfcxx-file=(.*)\z/m then o[:files] << $1
    when /\A--nfcxx-dir=(.*)\z/m then o[:dirs] << $1
    when /\A--cflag=(.*)\z/m then o[:cflags] << $1
    when /\A--kernel=(.*)\z/m then o[:kernels] << $1
    when /\A--group=(.*)\z/m then o[:groups] << $1
    when "--compile" then o[:compile] = true
    when "--live" then o[:live] = true
    when "--tabs" then o[:tabs] = true
    when "--execute" then o[:execute] = true
    when "--key" then o[:key] = true
    when "--obfuscate-kernels" then o[:obfuscate] = true
    when /\A--phase=(.*)\z/ then o[:phase] = $1.to_sym
    when /\A--promote-slots=(.*)\z/m then o[:promote] = $1
    when /\A--unroll=(.*)\z/m then o[:unroll] = $1
    when /\A--struct-slots=(.*)\z/m then o[:struct_slots] = $1
    when /\A--out=(.*)\z/m then o[:out] = $1
    when /\A--ir-opt=(.*)\z/m then o[:ir_opt] = $1
    when /\A--cache-dir=(.*)\z/m then o[:cache_dir] = $1
    when /\A--cache-key=(.*)\z/m then o[:cache_key] = $1
    when /\A--copy=(.*)\z/m then o[:copy] = $1
    when /\A--keep-dir=(.*)\z/m then o[:keep_dir] = $1
    when /\A--trace-unit=(.*)\z/m then o[:trace_unit] = $1
    when /\A--bash-pid=(.*)\z/m then o[:bash_pid] = $1.to_i
    when /\A--cache-log=(.*)\z/m then o[:cache_log] = $1
    when /\A--/ then raise CudaRefused, "unknown option #{a}"
    else
      raise CudaRefused, "one .cu input" if o[:src]

      o[:src] = a
    end
  end
  raise CudaRefused, "no .cu input" unless o[:src]
  raise CudaRefused, "--root and --tmp are required" unless o[:root] && o[:tmp]

  o
end

def plan_for(o)
  if o[:execute]
    # the driver's environment is the bash's (its exports); --nfcxx-env adds to it
    env = ENV.to_h.merge(o[:env])
    return CudaDevicePlan.new(o.merge(env: env, live: true, tabs: true, exec: true, append_src_dir: false))
  end
  if o[:key]
    # the key of the flags as given (no -I of the source's directory: the test passes the flags of cu_device_key)
    return CudaDevicePlan.new(o.merge(env: o[:env], live: true, append_src_dir: false))
  end
  CudaDevicePlan.new(o.merge(env: o[:env], live: o[:live]))
end

if $PROGRAM_NAME == __FILE__
  begin
    # --cu-run KEY=VALUE...: cu_prepare's state (cu_state_groups), its loop (--cu-prepare) and its apply (nfcxx-cu-apply.rb plan
    # kind=cu) in one process; the statements the driver evals are printed
    if ARGV[0] == "--cu-run"
      opts = ARGV.drop(1).to_h { |kv| kv.split("=", 2) }
      begin
        groups = cu_state_groups(opts)
        result, status = cu_prepare_run(groups)
      rescue ArgumentError, CuCopiesFailed => e
        $stderr.puts(e.message.start_with?("realpath") ? e.message : "nfcxx-cuda-device: #{e.message}")
        exit 2
      end
      exit status unless status == 0
      reply = StringIO.new
      DriverState.write_groups(reply, result)
      DriverState.write_end(reply)
      puts NfcxxCuApply.plan(opts.merge("kind" => "cu"), reply.string)
      exit 0
    end
    if ARGV[0] == "--cu-prepare"
      begin
        groups = DriverState.read_groups($stdin.binmode.read)
        result, status = cu_prepare_run(groups)
      rescue ArgumentError, CuCopiesFailed => e
        $stderr.puts(e.message.start_with?("realpath") ? e.message : "nfcxx-cuda-device: #{e.message}")
        exit 2
      end
      exit status unless status == 0
      DriverState.write_groups($stdout, result)
      DriverState.write_end($stdout)
      exit 0
    end
    if ARGV[0] == "--rewrite-argv"
      begin
        groups = DriverState.read_groups($stdin.binmode.read)
      rescue ArgumentError => e
        $stderr.puts "nfcxx-cuda-device: #{e.message}"
        exit 2
      end
      DriverState.write_groups($stdout, [["argv", rewrite_argv(groups)]])
      DriverState.write_end($stdout)
      exit 0
    end
    if ARGV[0] == "--cu-copies"
      begin
        sdirs, copies = cu_copies(ARGV[1], ARGV[2..])
      rescue CuCopiesFailed => e
        warn e.message
        exit 1
      end
      DriverState.write_groups($stdout, [["sdirs", sdirs], ["copies", copies]])
      DriverState.write_end($stdout)
      exit 0
    end
    if ARGV.size == 1 && ARGV[0].start_with?("--cu-dir=")
      puts cu_dir(ARGV[0].delete_prefix("--cu-dir="))
      exit 0
    end
    o = parse_options(ARGV)
    if o[:execute]
      exit plan_for(o).execute
    end
    if o[:key]
      puts plan_for(o).key_only
      exit 0
    end
    puts plan_for(o).run
  rescue CudaUnported => e
    $stderr.puts "unported: #{e.message}"
    exit 3
  rescue CudaRefused => e
    $stderr.puts "nfcxx: #{e.message}"
    exit 2
  end
end
