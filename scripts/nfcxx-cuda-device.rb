#!/usr/bin/env ruby
# nfcxx's CUDA device build, ported from the CUDA helpers in nfcxx: cu_prepare (where the copy goes), cu_rewrite (the host
# copy, the device unit, the toolkit's version macros, the device image), cu_device_build (the device IR, the modules,
# ptxas), cu_amd_build (the amdgcn image) and ir_opt_device. Checked against the bash by tests/nfcxx-cuda-device/run.sh.
#
# The port prints the commands the bash would run, one line each:
#   RUN ARGV...   a command: the rewriter, pathb-dump, pathb-ir-opt (through ruby), pathb-ptx-emit, pathb-amdgpu-emit,
#                 ptxas, clang, the tool build (ensure_tool), mkdir, mv and rm
#   CP ARGV...    a cp: the device image cache entry and NFCXX_KEEP_DEVICE_IR
#   JOBS N        the ptxas jobs (NFCXX_PTXAS_JOBS, default 4): the bash assembles the groups through xargs -P N
# Not in the lines: the redirections (> FILE, >> FILE) and the environment prefix of a command (NFCXX_SM=...).
#
# Nothing here runs a tool. The facts of the tree are inputs, as the other ports take them:
#   --nfcxx-file=PATH, --nfcxx-dir=PATH   the paths that exist (a tool's build, a cache entry, a CUDA header)
#   --kernel=NAME                         the kernels the rewriter listed, in order (none: no device image)
#   --group=NAME                          the group files the emitter wrote (gNNNN.ptx; the bash lists them in glob order)
#   --cache-key=KEY                       the device image cache key (cu_device_key, not ported)
# The toolkit's version macros are read from the header files that exist (their text, not a tool's output).
# The temporary directory of the bash (cudatmp) is --tmp=DIR. The PID of a cache store (.tmp.$$) prints as PID.
#
#   ruby scripts/nfcxx-cuda-device.rb [OPTION]... SRC.cu
#   --root=DIR                nfcxx's root
#   --tmp=DIR                 the temporary directory
#   --nfcxx-env=NAME=VALUE    the environment (repeated): NFCXX_SM, NFCXX_PTXAS, NFCXX_CUDA_*, CUDA_HOME, HOME, ...
#   --cflag=ARG               a cflags word, in order (-I, -D and -U are used; repeated)
#   --compile --out=PATH      -c and its -o: the copy and the groups go to the cache (NFCXX_CU_CACHE)
#   --ir-opt=V                --ir-opt (default inline,sroa; off turns the IR passes off)
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
  def initialize(opts)
    @root = opts.fetch(:root)
    @tmp = opts.fetch(:tmp)
    @env = opts.fetch(:env)
    @files = opts.fetch(:files)
    @dirs = opts.fetch(:dirs)
    @cflags = opts.fetch(:cflags).dup
    @kernels = opts.fetch(:kernels)
    @groups = opts.fetch(:groups).sort
    @compile = opts.fetch(:compile)
    @out = opts[:out]
    @ir_opt = opts[:ir_opt]
    @cache_dir = opts[:cache_dir]
    @cache_key = opts[:cache_key]
    @src = opts.fetch(:src)
    @cu_keep = ""
    @lines = []
  end

  # The lines of the plan (cu_prepare, then cu_rewrite for the one input).
  def run
    base = File.basename(@src, ".cu")
    dir = @tmp
    if @compile
      obj = @out || "#{base}.o"
      key = Digest::SHA1.hexdigest("#{File.expand_path(obj)}\n")[0, 16]
      cache = env("NFCXX_CU_CACHE") || "#{env("XDG_CACHE_HOME") || "#{env("HOME") || "/tmp"}/.cache"}/nfcxx"
      dir = "#{cache}/cu/#{key}"
      run_cmd("mkdir", "-p", dir)
      @cu_keep = dir
    end
    @cflags << "-I#{File.realpath(File.dirname(@src))}"
    cu_rewrite
    @lines
  end

  private

  def env(name, default = nil)
    v = @env[name]
    (v.nil? || v.empty?) ? default : v
  end

  def run_cmd(*argv)
    @lines << ["RUN", *argv].join(" ")
  end

  def cp(*argv)
    @lines << ["CP", *argv].join(" ")
  end

  def exists?(path)
    @files.include?(path) || @dirs.include?(path)
  end

  def rewriter = "#{@root}/build/cuda-rewrite"
  def pathb_dump = "#{@root}/scripts/pathb-dump"
  def ptx_emit = "#{@root}/build/pathb-ptx-emit"

  def ensure_tool(dir, out)
    run_cmd("ensure_tool", dir, out) unless exists?(out)
  end

  # cu_rewrite: the host copy, then the device unit; a unit with no kernel has no device image.
  def cu_rewrite
    base = File.basename(@src, ".cu")
    incs = @cflags.select { |f| f.start_with?("-I") }
    defs = @cflags.select { |f| f.start_with?("-D", "-U") }
    obf = obfuscate_opts
    rw = env("NFCXX_CUDA_EDG_LAUNCH", "1") == "1" ? ["--edg-launches"] : []
    run_cmd(rewriter, *incs, *defs, *obf, *rw, @src)

    dev = "#{@tmp}/#{base}.dev"
    sm = env("NFCXX_SM", "75")
    ptxas = env("NFCXX_PTXAS") || "#{env("CUDA_HOME") || "/usr/local/cuda"}/bin/ptxas"
    ver = version_opts(incs, defs)
    hs = env("NFCXX_CUDA_HOST_SYMBOLS") ? ["--host-symbols=#{env("NFCXX_CUDA_HOST_SYMBOLS")}"] : []
    run_cmd(rewriter, *incs, *defs, *ver, *obf, *hs, "--device", "--kernels=#{dev}.kernels", @src)
    return if @kernels.empty?

    return amd_build(dev, defs, ver) if env("NFCXX_CUDA_TARGET", "nvidia") == "amdgpu"

    ensure_tool("#{@root}/tools/pathb-ptx-emit", ptx_emit)
    groups = "#{@cu_keep.empty? ? @tmp : @cu_keep}/#{base}.groups"
    ext = env("NFCXX_CUDA_JIT", "0") == "1" ? "ptx" : "cubin"
    run_cmd("rm", "-rf", groups)
    dent = device_cache_entry
    if dent && exists?("#{dent}/ir")
      cp("#{dent}/ir", "#{dev}.ir")
      cp("-R", "#{dent}/groups", groups)
    else
      device_build(base, dev, groups, sm, ptxas, ext, defs, ver)
      cache_store(dev, groups, dent) if dent
    end
    run_cmd(ptx_emit, "--embed", "--groups=#{groups}", "--ext=#{ext}", "#{dev}.ir", "#{dev}.kernels", "#{dev}.kernels.addr")
  end

  # cu_device_build: the device IR, the module images (pathb-ptx-emit --emit), then one cubin per group (ptxas).
  def device_build(base, dev, groups, sm, ptxas, ext, defs, ver)
    run_cmd(pathb_dump, "--cuda-device", *defs, *ver, "--ir", "--freestanding", "#{dev}.cpp")
    ir_opt("#{dev}.ir")
    kopts = @kernels.map { |k| "--kernel=#{k}" }
    inl = []
    inl << "--inline=off" if env("NFCXX_INLINE_DEVICE", "1") == "0"
    inl << "--promote=off" if env("NFCXX_PROMOTE_SLOTS", "1") == "0"
    inl << "--unroll=off" if env("NFCXX_UNROLL", "1") == "0"
    inl << "--struct-slots=off" if env("NFCXX_STRUCT_SLOTS", "1") == "0"
    run_cmd(ptx_emit, "--emit", "--sm=#{sm}", "--f2i=convert", "--int=gpu", *inl, "--groups-dir=#{groups}",
            "--max-const-bytes=#{env("NFCXX_CUDA_MAX_CONST_BYTES", "65536")}",
            "--max-ptx-lines=#{env("NFCXX_CUDA_MAX_PTX_LINES", "1000000")}", *kopts, "#{dev}.ir")
    return unless ext == "cubin"

    @lines << "JOBS #{env("NFCXX_PTXAS_JOBS", "4")}"
    @groups.each do |g|
      run_cmd(ptxas, "-arch=sm_#{sm}", "#{groups}/#{g}", "-o", "#{groups}/#{g.sub(/\.ptx\z/, "")}.cubin")
    end
  end

  # ir_opt_device: the IR passes on the device IR in place; NFCXX_KEEP_DEVICE_IR keeps copies before (.pre) and after (.post).
  def ir_opt(ir)
    v = @ir_opt || "inline,sroa"
    return if v.empty? || v == "off"

    keep = env("NFCXX_KEEP_DEVICE_IR")
    cp(ir, "#{keep}.pre") if keep
    opts = v.split(",").reject(&:empty?).map { |p| "--#{p}" }
    run_cmd(env("RUBY", "ruby"), "#{@root}/scripts/pathb-ir-opt.rb", *opts, ir)
    run_cmd("mv", "#{ir}.opt", ir)
    cp(ir, "#{keep}.post") if keep
  end

  # cu_amd_build: the same device IR, then pathb-amdgpu-emit, clang for the amdgcn target and the embed.
  def amd_build(dev, defs, ver)
    arch = env("NFCXX_AMDGPU_ARCH") or
      raise CudaUnported, "the AMD GPU's architecture (scripts/amdgpu-env.sh finds it in KFD; NFCXX_AMDGPU_ARCH overrides)"
    clang = env("NFCXX_AMDGPU_CLANG") or
      raise CudaUnported, "the amdgcn clang (scripts/amdgpu-env.sh searches for it; NFCXX_AMDGPU_CLANG overrides)"
    amd_emit = "#{@root}/build/pathb-amdgpu-emit"
    ensure_tool("#{@root}/tools/pathb-amdgpu-emit", amd_emit)
    run_cmd(pathb_dump, "--cuda-device", *defs, *ver, "--ir", "--freestanding", "#{dev}.cpp")
    ir_opt("#{dev}.ir")
    kopts = @kernels.map { |k| "--kernel=#{k}" }
    run_cmd(amd_emit, *kopts, "#{dev}.ir")
    run_cmd(clang, "-target", "amdgcn-amd-amdhsa", "-mcpu=#{arch}", "-O2", "-nogpulib", "#{dev}.ll", "-o", "#{dev}.hsaco")
    run_cmd(ptx_emit, "--embed", "#{dev}.hsaco", "#{dev}.ir", "#{dev}.kernels", "#{dev}.kernels.addr")
  end

  def device_cache_entry
    return nil if @cache_dir.nil? || @cache_dir.empty?
    raise CudaUnported, "the device image cache key (cu_device_key; the port takes it as --cache-key=)" if @cache_key.nil?

    "#{@cache_dir}/cu-device/#{@cache_key}"
  end

  # The store of a miss: a whole entry appears at once (a rename), so a partial copy is never a hit.
  def cache_store(dev, groups, dent)
    ctmp = "#{dent}.tmp.PID"
    run_cmd("mkdir", "-p", ctmp)
    cp("#{dev}.ir", "#{ctmp}/ir")
    cp("-R", groups, "#{ctmp}/groups")
    run_cmd("mv", ctmp, dent) unless exists?(dent)
    run_cmd("rm", "-rf", ctmp)
  end

  # obfuscate_opts: the seed is one for both copies of the file (the host and the device unit must agree).
  def obfuscate_opts
    return [] if env("NFCXX_OBFUSCATE_KERNELS", "0") == "0"

    ["--obfuscate=#{env("NFCXX_OBFUSCATE_SEED") || SecureRandom.hex(16)}"]
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
  o = { env: {}, files: [], dirs: [], cflags: [], kernels: [], groups: [], compile: false,
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

if $PROGRAM_NAME == __FILE__
  begin
    o = parse_options(ARGV)
    puts CudaDevicePlan.new(o).run
  rescue CudaUnported => e
    $stderr.puts "unported: #{e.message}"
    exit 3
  rescue CudaRefused => e
    $stderr.puts "nfcxx: #{e.message}"
    exit 2
  end
end
