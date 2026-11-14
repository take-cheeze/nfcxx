#!/usr/bin/env ruby
# Build a SYCL program (lib/sycl, docs/notes/sycl-webgpu.md) for the host CPU or for WebGPU.
#
#   scripts/sycl-build.rb [--cpu] [--backend=webgpu|vulkan|opencl|level-zero] [--keep-ir] [--ndebug] [--no-div-trap] [-I dir] [-D mac] [--cxx=CMD]
#                         [-L dir] [-l lib] [-Wl,...] [-rpath dir] prog.cpp -o prog
#
# WebGPU (the default): a device pass compiles prog.cpp with -D__NFCXX_SYCL_DEVICE__ through the Path B front end
# (scripts/pathb-dump --ir), scripts/pathb-wgsl-emit.rb lowers every kernel to WGSL, and the host pass compiles the
# program with -DNFCXX_SYCL_WEBGPU. The WGSL and the kernel table are written next to the output as prog.wgsl and
# prog.man; at run time the program finds them through NFCXX_SYCL_IMAGE (default: the output path, baked in). The
# server that executes them is tests/sycl/server.cjs (Node + Playwright's Chromium; see rt_pipe.hpp).
# --cpu: the host path only, no WGSL (the kernels are C++ loops).
# Link flags (-L, -l, -Wl,..., -rpath dir; -rpath becomes -Wl,-rpath,dir) go to the host compile only, after the source and
# -o; the device pass never sees them.
# -c, -fPIC: a host object instead of a program (OpenCL and Level Zero). The TU's image is written next to the object
# (obj.o.cl.spv, obj.o.man) and the object registers it, so objects linked into one program or one -shared library each
# bring their kernels (lib/sycl/include/sycl/rt_image.hpp). Link the objects with the host compiler (nfcxx a.o b.o).
# -shared and -rdynamic go to the host link like the other link flags.
# --no-div-trap: the SPIR-V emitter divides by 1 where a division is undefined (a zero divisor, INT_MIN / -1) instead of
# trapping, as a GPU gives a meaningless value there (ggml-sycl divides by a dimension of an absent mask, ne33 = 0).
# --ndebug: -DNDEBUG on the device pass only (the host pass keeps its asserts). For a TU that reaches ggml.h's assert() from a
# device-side function: the device pass refuses the call to the host __assert_fail, and the device has no assert to lower it to.
# It also drops the SPIR-V emitter's null-pointer and bounds checks (--no-checks): a failed one no longer traps.
# --cxx=CMD: the host compiler (default: $CXX; else nfcxx for WebGPU when built, else g++). The closure types' mangling and
# layout must match the device pass's (this front end; g++ mostly agrees), because the host finds a kernel by
# typeid(F).name() and copies the closure bytes. The server refuses a closure whose size differs.
# Exit status 3 when the emitter refuses a kernel (the reason is on stderr).
require "fileutils"
$stdout.sync = true
$stderr.sync = true

ROOT = File.expand_path("..", File.dirname($PROGRAM_NAME))

# A variable that the shell's ${VAR:-default} takes: unset or empty means the default
def envd(name, default)
  v = ENV[name].to_s
  v.empty? ? default : v
end

# A variable that ${VAR-default} takes: unset means the default (an empty value is kept)
def envu(name, default)
  ENV.key?(name) ? ENV[name] : default
end

# . "$root/scripts/oneapi-env.sh": the oneAPI runtime libraries and OPENCL_INCLUDE (the same settings as the sourced file)
def oneapi_env
  oroot = envd("ONEAPI_ROOT", "/opt/intel/oneapi")
  ver = ENV["ONEAPI_COMPILER_VERSION"].to_s
  if ver.empty? && Dir.exist?("#{oroot}/compiler")
    cands = Dir.children("#{oroot}/compiler").select { |d| d.match?(/\A[0-9]+(\.[0-9]+)*\z/) }
    ver = cands.max_by { |d| d.split(".").map(&:to_i) }.to_s
  end
  return unless !ver.empty? && Dir.exist?("#{oroot}/compiler/#{ver}")

  ld = ENV["LD_LIBRARY_PATH"].to_s
  new_dirs = []
  ["#{oroot}/compiler/#{ver}/lib", "#{oroot}/mkl/latest/lib", "#{oroot}/tbb/latest/lib", "#{oroot}/umf/latest/lib"].each do |d|
    next unless Dir.exist?(d)
    next if (":#{ld}:").include?(":#{d}:")

    new_dirs << d
  end
  new = new_dirs.join(":")
  ENV["LD_LIBRARY_PATH"] = ld.empty? ? new : "#{new}:#{ld}" unless new.empty?
  if ENV["OPENCL_INCLUDE"].to_s.empty? && Dir.exist?("#{oroot}/compiler/#{ver}/include")
    ENV["OPENCL_INCLUDE"] = "#{oroot}/compiler/#{ver}/include"
  end
end

# Run a command (no shell) with the given environment; returns its status (127 when it cannot run)
def run_status(env, argv, out: nil, err_to_out: false)
  opts = {}
  opts[:out] = out if out
  opts[:err] = [:child, :out] if err_to_out
  ok = system(env, [argv[0], argv[0]], *argv[1..], **opts)
  return 127 if ok.nil?

  $?.exitstatus || (128 + $?.termsig)
end

# exec: replaces the process; a command that cannot run ends it with 127
def exec_argv(argv)
  $stdout.flush
  $stderr.flush
  Kernel.exec([argv[0], argv[0]], *argv[1..])
rescue SystemCallError => e
  warn "#{argv[0]}: #{e.message}"
  exit 127
end

# mv that ends the script on failure (set -e)
def mv_or_die(from, to)
  FileUtils.mv(from, to)
rescue SystemCallError => e
  warn "mv: #{e.message}"
  exit 1
end

def usage_exit(msg, status = 2)
  warn msg
  exit status
end

oneapi_env

cxx = ENV["CXX"].to_s
mode = "webgpu"
backend = "webgpu"
out = ""
src = ""
keep = 0
ndebug = nil
opts = []
link = []
hostopts = []
std = "c++17"
emitopts = []
diag = []

args = ARGV.dup
while (a = args.shift)
  case a
  when "--cpu" then mode = "cpu"
  when /\A--backend=/
    backend = a.delete_prefix("--backend=")
    unless %w[webgpu vulkan opencl level-zero].include?(backend)
      usage_exit "sycl-build: --backend must be webgpu, vulkan, opencl or level-zero"
    end
  when "--keep-ir" then keep = 1
  when "--ndebug"
    ndebug = "-DNDEBUG"
    emitopts << "--no-checks"
  when "--no-div-trap" then emitopts << "--no-div-trap"
  when /\A--cxx=/ then cxx = a.delete_prefix("--cxx=")
  when /\A-std=/ then std = a.delete_prefix("-std=")
  when "-o"
    out = args.shift
    exit 1 if out.nil?
  when "-I", "-D"
    v = args.shift
    exit 1 if v.nil?
    opts << "#{a}#{v}"
  when "-L", "-l"
    usage_exit "sycl-build: #{a} needs an argument" if args.empty?
    link << a << args.shift
  when "-rpath"
    usage_exit "sycl-build: -rpath needs an argument" if args.empty?
    link << "-Wl,-rpath,#{args.shift}"
  when /\A-[Ll]/, /\A-Wl,/, "-shared", "-rdynamic" then link << a
  when "-c", "-fPIC", "-fpic" then hostopts << a
  when /\A--diag_/ then diag << a
  when /\A-[IDUOW]/, "-g" then opts << a
  when /\A-/ then usage_exit "sycl-build: unknown option #{a}"
  else src = a
  end
end

usage_exit "usage: sycl-build.rb [--cpu] prog.cpp -o prog" if src.empty?
if !hostopts.empty? && (mode == "cpu" || (backend != "opencl" && backend != "level-zero"))
  usage_exit "sycl-build: -c and -fPIC need --backend=opencl or level-zero (the other runtimes load one image per program)"
end
out = src.delete_suffix(".cpp") if out.empty?

# the host compiler (see the header): nfcxx when its EDG build is found, else $CXX or g++
if cxx.empty?
  edg_build = envd("EDG_BUILD", File.join(ROOT, "build/edg"))
  if mode == "webgpu" && File.executable?(File.join(ROOT, "nfcxx")) && File.executable?(File.join(edg_build, "bin/eccp"))
    cxx = File.join(ROOT, "nfcxx")
    ENV["EDG_BUILD"] = edg_build
    ENV["EDG_BASE"] = envd("EDG_BASE", File.join(ROOT, "build/edg-base"))
    ENV["NFCXX_BACKEND"] = envd("NFCXX_BACKEND", "gcc") unless File.executable?(File.join(ROOT, "build/qbe/qbe"))
  else
    cxx = "g++"
    warn "sycl-build: the host is g++, which names file-local kernel closures differently from the device pass (no kernel for the closure type); build nfcxx's EDG (build/edg, or EDG_BUILD) or pass --cxx" unless mode == "cpu"
  end
end
inc = File.join(ROOT, "lib/sycl/include")
cxx_words = cxx.split
first_word = cxx[/\A[^ ]*/]
optflag = File.basename(first_word) == "nfcxx" ? [] : ["-O2"]   # nfcxx optimizes by itself; a plain compiler needs it for the host loops

if mode == "cpu"
  exec_argv(cxx_words + ["-std=#{std}"] + optflag + ["-I#{inc}"] + opts + [src, "-o", out] + link)
end

# absout=$(cd "$(dirname "$out")" && pwd)/$(basename "$out"): as in the sh original, a missing directory leaves the
# first part empty and the script goes on
dir_of_out = File.dirname(out)
absout = "#{Dir.exist?(dir_of_out) ? File.expand_path(dir_of_out) : ''}/#{File.basename(out)}"
dev_ir = "#{absout}.dev.ir"
pathb = ->(name) { File.join(ROOT, "scripts", name) }
rb = envd("RUBY", "ruby")

st = run_status({}, [pathb.call("pathb-dump")] + ["--ir", "-std=#{std}", "-D__NFCXX_SYCL_DEVICE__"] +
                    (ndebug ? [ndebug] : []) + ["-I#{inc}"] + opts + diag + [src], out: dev_ir)
exit st unless st.zero?

# NFCXX_IR_OPT (see docs/notes/pathb-ir-passes.md): the IR-to-IR passes before the device emitter.
ir_opt = if backend == "vulkan" && !ENV.key?("NFCXX_IR_OPT")
           "strip-eh,inline,sroa,unroll-cap-in=nfcxx_sycl_entry,unroll-limit=12"
         else
           envu("NFCXX_IR_OPT", "strip-eh,inline,sroa")
         end
if ir_opt != "off" && !ir_opt.empty?
  irpasses = ir_opt.tr(",", " ").split.map { |p| "--#{p}" }
  st = run_status({}, [rb, pathb.call("pathb-ir-opt.rb")] + irpasses + [dev_ir], out: "#{absout}.dev.opt.ir")
  exit st unless st.zero?
  mv_or_die("#{absout}.dev.opt.ir", dev_ir)
end

# The SSA round trip (default; NFCXX_CFG=off turns it off); see the comments in the sh original
if envd("NFCXX_CFG", "structurize") == "structurize"
  dev_ssa = "#{absout}.dev.ssa"
  st = run_status({}, [rb, pathb.call("pathb-ssa.rb"), dev_ir], out: dev_ssa)
  if st.zero?
    st = 0
    if envd("NFCXX_SSA_OPT", "egraph") == "egraph"
      st = run_status({}, [rb, pathb.call("pathb-egraph.rb"), dev_ssa], out: "#{dev_ssa}.opt")
      mv_or_die("#{dev_ssa}.opt", dev_ssa) if st.zero?
    end
    if st.zero?
      st = run_status({}, [rb, pathb.call("pathb-ssa-structurize.rb"), dev_ssa], out: "#{absout}.dev.opt.ir")
      exit st unless st.zero?
    end
  end
  mv_or_die("#{absout}.dev.opt.ir", dev_ir)
end

# store-to-load forwarding on the structured IR (NFCXX_FORWARD=off turns it off)
if envd("NFCXX_FORWARD", "on") == "on"
  st = run_status({}, [rb, pathb.call("pathb-ir-opt.rb"), "--forward", dev_ir], out: "#{absout}.dev.fwd.ir")
  mv_or_die("#{absout}.dev.fwd.ir", dev_ir) if st.zero?
end

rc = 0
if backend == "vulkan"
  st = run_status({}, [pathb.call("spirv-emit")] + emitopts + ["--manifest=#{absout}.man", dev_ir], out: "#{absout}.spv")
  rc = st unless st.zero?
elsif backend == "opencl" || backend == "level-zero"
  st = run_status({}, [pathb.call("spirv-emit"), "--kernel-cl"] + emitopts + ["--manifest=#{absout}.man", dev_ir],
                  out: "#{absout}.cl.spv")
  rc = st unless st.zero?
else
  st = run_status({}, [pathb.call("mrb"), pathb.call("pathb-wgsl-emit.rb"), "--manifest=#{absout}.man", dev_ir],
                  out: "#{absout}.wgsl")
  rc = st unless st.zero?
end
FileUtils.rm_f(dev_ir) unless keep == 1
if rc != 0
  %w[wgsl spv cl.spv man].each { |e| FileUtils.rm_f("#{absout}.#{e}") }
  warn "sycl-build: the device code of #{src} was refused (exit #{rc})"
  exit rc
end

def spirv_ok?(path, env, log)
  return true unless File.size?(path)

  run_status({}, ["spirv-val", "--target-env", env, path], out: log, err_to_out: true).zero?
end

def cat_to_stderr(path)
  $stderr.write(File.read(path))
end

if backend == "vulkan"
  unless spirv_ok?("#{absout}.spv", "vulkan1.2", "#{absout}.val.log")
    cat_to_stderr("#{absout}.val.log")
    usage_exit "sycl-build: the SPIR-V of #{src} does not validate", 1
  end
  exec_argv(cxx_words + ["-std=#{std}"] + optflag + ["-DNFCXX_SYCL_VULKAN", "-DNFCXX_SYCL_IMAGE_PREFIX=\"#{absout}\"",
                                                     "-I#{inc}"] + opts + [src, "-o", out, "-lvulkan"] + link)
end

if backend == "opencl" || backend == "level-zero"
  unless spirv_ok?("#{absout}.cl.spv", "opencl2.2", "#{absout}.val.log")
    cat_to_stderr("#{absout}.val.log")
    usage_exit "sycl-build: the OpenCL SPIR-V of #{src} does not validate", 1
  end
end

if backend == "level-zero"
  # the Level Zero headers (/usr/include/level_zero) and loader (libze_loader.so.1; no dev symlink, so it is named by its file)
  unless hostopts.empty?
    exec_argv(cxx_words + ["-std=#{std}"] + optflag + ["-DNFCXX_SYCL_LEVEL_ZERO", "-DNFCXX_SYCL_IMAGE_PREFIX=\"#{absout}\"",
                                                       "-I#{inc}"] + opts + hostopts + [src, "-o", out])
  end
  exec_argv(cxx_words + ["-std=#{std}"] + optflag + ["-DNFCXX_SYCL_LEVEL_ZERO", "-DNFCXX_SYCL_IMAGE_PREFIX=\"#{absout}\"",
                                                     "-I#{inc}"] + opts + [src, "-o", out, "-l:libze_loader.so.1"] + link)
end

if backend == "opencl" && !ENV["OPENCL_INCLUDE"].to_s.empty? && Dir.exist?("#{ENV['OPENCL_INCLUDE']}/sycl")
  # the oneAPI include directory: only its CL/ is wanted (see the sh original)
  clinc = File.join(ROOT, "build/opencl-include")
  FileUtils.mkdir_p(clinc)
  if run_status({}, ["ln", "-sfn", "#{ENV['OPENCL_INCLUDE']}/CL", "#{clinc}/CL"]).zero?
    ENV["OPENCL_INCLUDE"] = clinc
  end
end

if backend == "opencl"
  oinc = ENV["OPENCL_INCLUDE"].to_s.empty? ? [] : ["-I#{ENV['OPENCL_INCLUDE']}"]
  unless hostopts.empty?
    exec_argv(cxx_words + ["-std=#{std}"] + optflag + ["-DNFCXX_SYCL_OPENCL", "-DNFCXX_SYCL_IMAGE_PREFIX=\"#{absout}\""] +
              opts + ["-I#{inc}"] + oinc + hostopts + [src, "-o", out])
  end
  exec_argv(cxx_words + ["-std=#{std}"] + optflag + ["-DNFCXX_SYCL_OPENCL", "-DNFCXX_SYCL_IMAGE_PREFIX=\"#{absout}\""] +
            opts + ["-I#{inc}"] + oinc + [src, "-o", out, "-l:libOpenCL.so.1"] + link)
end

exec_argv(cxx_words + ["-std=#{std}"] + optflag + ["-DNFCXX_SYCL_WEBGPU",
                                                   "-DNFCXX_SYCL_SERVER_JS=\"#{ROOT}/tests/sycl/server.cjs\"",
                                                   "-DNFCXX_SYCL_IMAGE_PREFIX=\"#{absout}\"",
                                                   "-I#{inc}"] + opts + [src, "-o", out] + link)
