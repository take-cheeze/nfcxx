#!/usr/bin/env ruby
# nfcxx's CUDA device build, ported from the CUDA helpers in nfcxx: cu_prepare (where the copy goes), cu_rewrite (the host
# copy, the device unit, the toolkit's version macros, the device image), cu_device_build (the device IR, the modules,
# ptxas), cu_amd_build (the amdgcn image) and ir_opt_device. Checked against the bash by tests/nfcxx-cuda-device/run.sh.
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
# Nothing here runs a tool. The facts of the tree are inputs, as the other ports take them:
#   --nfcxx-file=PATH, --nfcxx-dir=PATH   the paths that exist (a cache entry, a CUDA header); --live reads the file system
#   --kernel=NAME                         the kernels the rewriter listed, in order (none: no device image)
#   --group=NAME                          the group files the emitter wrote (gNNNN.ptx; the bash lists them in glob order)
#   --cache-key=KEY                       the device image cache key (cu_device_key, not ported)
# The environment is read from --nfcxx-env=NAME=VALUE (the variables the bash reads: NFCXX_SM, NFCXX_PTXAS, NFCXX_CUDA_*,
# NFCXX_OBFUSCATE_*, NFCXX_CU_CACHE, CUDA_HOME, HOME, XDG_CACHE_HOME, RUBY, ...). The options --obfuscate-kernels,
# --promote-slots=0|1, --unroll=0|1, --struct-slots=0|1 and --ir-opt=V are the driver's own arguments, as the bash reads them.
# The toolkit's version macros are read from the header files that exist (their text, not a tool's output).
# The temporary directory of the bash (cudatmp) is --tmp=DIR. The PID of a cache store (.tmp.$$) prints as PID.
#
#   ruby scripts/nfcxx-cuda-device.rb [OPTION]... SRC.cu
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
#   --promote-slots=0|1, --unroll=0|1, --struct-slots=0|1   the driver's options (the environment's values otherwise)
#   --cache-dir=DIR           the device image cache (--cache)
#   --cache-key=KEY           its key (cu_device_key)
#   --nfcxx-file=PATH, --nfcxx-dir=PATH, --kernel=NAME, --group=NAME
# Exit: 0; 2 with nfcxx's message; 3 with "unported: ..." for what is not ported (the AMD GPU's architecture and the
# amdgcn clang when NFCXX_AMDGPU_ARCH and NFCXX_AMDGPU_CLANG are not set, and a device image cache without --cache-key).

require "digest"
require "securerandom"

class CudaUnported < StandardError; end
class CudaRefused < StandardError; end

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
    @seed = nil
    @lines = []
  end

  # The lines of the plan for the phase: the copy and the device unit, then the device image.
  def run
    raise CudaRefused, "unknown phase #{@phase}" unless PHASES.include?(@phase)

    @base = File.basename(@src, ".cu")
    @dir = @tmp
    if @compile
      obj = @out || "#{@base}.o"
      key = Digest::SHA1.hexdigest("#{File.expand_path(obj)}\n")[0, 16]
      cache = env("NFCXX_CU_CACHE") || "#{env("XDG_CACHE_HOME") || "#{env("HOME") || "/tmp"}/.cache"}/nfcxx"
      @dir = "#{cache}/cu/#{key}"
    end
    @cu_keep = @compile ? @dir : ""
    @cflags << "-I#{File.realpath(File.dirname(@src))}"
    @copy = "#{@dir}/#{@base}.cpp"
    @dev = "#{@tmp}/#{@base}.dev"
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

    prep if %i[all prep].include?(@phase)
    return @lines if @phase == :prep || @kernels.empty?

    device_build if %i[all emit].include?(@phase)
    finish if %i[all finish].include?(@phase)
    @lines
  end

  private

  def env(name, default = nil)
    v = @env[name]
    (v.nil? || v.empty?) ? default : v
  end

  def amd? = env("NFCXX_CUDA_TARGET", "nvidia") == "amdgpu"

  def emit_line(kind, argv)
    @lines << [kind, *argv].join(@tabs ? "\t" : " ")
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

  # cu_rewrite up to the device image: the host copy, then the device unit (its kernel list is the next phase's fact).
  def prep
    run_cmd("mkdir", "-p", @dir) if @compile
    out_to(@copy)
    run_cmd(rewriter, *@incs, *@defs, *@obf, *@rw, @src)
    env1("NFCXX_SM", @sm)
    out_to("#{@dev}.cpp")
    run_cmd(rewriter, *@incs, *@defs, *@ver, *@obf, *@hs, "--device", "--kernels=#{@dev}.kernels", @src)
  end

  # The device image cache entry of this unit (--cache-dir with the key), or nil. A hit has the IR and the groups.
  def cache_entry
    @cache_entry ||= device_cache_entry
  end

  def cache_hit? = !cache_entry.nil? && exists?("#{cache_entry}/ir")

  # the device image: cu_device_build (or cu_amd_build), with the groups in @groups_dir. A cache hit copies them instead.
  def device_build
    return amd_build if amd?

    ensure_tool("#{@root}/tools/pathb-ptx-emit", ptx_emit)
    run_cmd("rm", "-rf", @groups_dir)
    if cache_hit?
      cp("#{cache_entry}/ir", "#{@dev}.ir")
      cp("-R", "#{cache_entry}/groups", @groups_dir)
      return
    end
    out_to("#{@dev}.ir")
    run_cmd(pathb_dump, "--cuda-device", *@defs, *@ver, "--ir", "--freestanding", "#{@dev}.cpp")
    ir_opt("#{@dev}.ir")
    kopts = @kernels.map { |k| "--kernel=#{k}" }
    inl = []
    inl << "--inline=off" if env("NFCXX_INLINE_DEVICE", "1") == "0"
    inl << "--promote=off" if promote_slots == "0"
    inl << "--unroll=off" if unroll == "0"
    inl << "--struct-slots=off" if struct_slots == "0"
    run_cmd(ptx_emit, "--emit", "--sm=#{@sm}", "--f2i=convert", "--int=gpu", *inl, "--groups-dir=#{@groups_dir}",
            "--max-const-bytes=#{env("NFCXX_CUDA_MAX_CONST_BYTES", "65536")}",
            "--max-ptx-lines=#{env("NFCXX_CUDA_MAX_PTX_LINES", "1000000")}", *kopts, "#{@dev}.ir")
  end

  # the groups' cubins (ptxas, NFCXX_CUDA_JIT=0), the store of a miss in the device image cache, then the embedding of the
  # images into the copy (cu_rewrite's last step, appended with >>)
  def finish
    return if amd?

    unless cache_hit?
      if @ext == "cubin"
        emit_line("JOBS", [env("NFCXX_PTXAS_JOBS", "4")])
        @groups.each do |g|
          run_cmd(@ptxas, "-arch=sm_#{@sm}", "#{@groups_dir}/#{g}", "-o", "#{@groups_dir}/#{g.sub(/\.ptx\z/, "")}.cubin")
        end
      end
      cache_store if cache_entry
    end
    app_to(@copy)
    run_cmd(ptx_emit, "--embed", "--groups=#{@groups_dir}", "--ext=#{@ext}", "#{@dev}.ir", "#{@dev}.kernels",
            "#{@dev}.kernels.addr")
  end

  def promote_slots = @promote || env("NFCXX_PROMOTE_SLOTS", "1")
  def unroll = @unroll || env("NFCXX_UNROLL", "1")
  def struct_slots = @struct_slots || env("NFCXX_STRUCT_SLOTS", "1")

  # ir_opt_device: the IR passes on the device IR in place; NFCXX_KEEP_DEVICE_IR keeps copies before (.pre) and after (.post).
  def ir_opt(ir)
    v = @ir_opt || "inline,sroa"
    return if v.empty? || v == "off"

    keep = env("NFCXX_KEEP_DEVICE_IR")
    cp(ir, "#{keep}.pre") if keep
    opts = v.split(",").reject(&:empty?).map { |p| "--#{p}" }
    out_to("#{ir}.opt")
    run_cmd(env("RUBY", "ruby"), "#{@root}/scripts/pathb-ir-opt.rb", *opts, ir)
    run_cmd("mv", "#{ir}.opt", ir)
    cp(ir, "#{keep}.post") if keep
  end

  # cu_amd_build: the same device IR, then pathb-amdgpu-emit, clang for the amdgcn target and the embed.
  def amd_build
    arch = env("NFCXX_AMDGPU_ARCH") or
      raise CudaUnported, "the AMD GPU's architecture (scripts/amdgpu-env.rb finds it in KFD; NFCXX_AMDGPU_ARCH overrides)"
    clang = env("NFCXX_AMDGPU_CLANG") or
      raise CudaUnported, "the amdgcn clang (scripts/amdgpu-env.rb searches for it; NFCXX_AMDGPU_CLANG overrides)"
    amd_emit = "#{@root}/build/pathb-amdgpu-emit"
    ensure_tool("#{@root}/tools/pathb-amdgpu-emit", amd_emit)
    out_to("#{@dev}.ir")
    run_cmd(pathb_dump, "--cuda-device", *@defs, *@ver, "--ir", "--freestanding", "#{@dev}.cpp")
    ir_opt("#{@dev}.ir")
    kopts = @kernels.map { |k| "--kernel=#{k}" }
    out_to("#{@dev}.ll")
    run_cmd(amd_emit, *kopts, "#{@dev}.ir")
    run_cmd(clang, "-target", "amdgcn-amd-amdhsa", "-mcpu=#{arch}", "-O2", "-nogpulib", "#{@dev}.ll", "-o", "#{@dev}.hsaco")
    app_to(@copy)
    run_cmd(ptx_emit, "--embed", "#{@dev}.hsaco", "#{@dev}.ir", "#{@dev}.kernels", "#{@dev}.kernels.addr")
  end

  def device_cache_entry
    return nil if @cache_dir.nil? || @cache_dir.empty?
    raise CudaUnported, "the device image cache key (cu_device_key; the port takes it as --cache-key=)" if @cache_key.nil?

    "#{@cache_dir}/cu-device/#{@cache_key}"
  end

  # The store of a miss: a whole entry appears at once (a rename), so a partial copy is never a hit.
  def cache_store
    ctmp = "#{cache_entry}.tmp.PID"
    run_cmd("mkdir", "-p", ctmp)
    cp("#{@dev}.ir", "#{ctmp}/ir")
    cp("-R", @groups_dir, "#{ctmp}/groups")
    run_cmd("mv", ctmp, cache_entry) unless exists?(cache_entry)
    run_cmd("rm", "-rf", ctmp)
  end

  # obfuscate_opts: the seed is one for both copies of the file (the host and the device unit must agree), so it is drawn once.
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
        out: nil, ir_opt: nil, cache_dir: nil, cache_key: nil, root: nil, tmp: nil, src: nil }
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
    when "--obfuscate-kernels" then o[:obfuscate] = true
    when /\A--phase=(.*)\z/ then o[:phase] = $1.to_sym
    when /\A--promote-slots=([01])\z/ then o[:promote] = $1
    when /\A--unroll=([01])\z/ then o[:unroll] = $1
    when /\A--struct-slots=([01])\z/ then o[:struct_slots] = $1
    when /\A--out=(.*)\z/m then o[:out] = $1
    when /\A--ir-opt=(.*)\z/m then o[:ir_opt] = $1
    when /\A--cache-dir=(.*)\z/m then o[:cache_dir] = $1
    when /\A--cache-key=(.*)\z/m then o[:cache_key] = $1
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
  env = o[:env]
  CudaDevicePlan.new(o.merge(env: env, live: o[:live]))
end

if $PROGRAM_NAME == __FILE__
  begin
    o = parse_options(ARGV)
    puts plan_for(o).run
  rescue CudaUnported => e
    $stderr.puts "unported: #{e.message}"
    exit 3
  rescue CudaRefused => e
    $stderr.puts "nfcxx: #{e.message}"
    exit 2
  end
end
