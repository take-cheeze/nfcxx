#!/usr/bin/env ruby
# The Ruby driver (docs/notes/driver-body-port.md). ./nfcxx is a shim that runs this script (stage B8, the switch).
# The stages not yet ported run in the bash body, tests/driver-body/nfcxx-oracle.sh (the frozen oracle), with the same arguments,
# environment, standard streams and status. Each stage moves a part of the flow here; the bash body is the reference the
# differential tests compare against.
#
#   ./nfcxx ARGS...      (runs: ruby scripts/nfcxx.rb ARGS...)

# Usage (moved here from the bash driver at the B8 switch):
# nfcxx: experimental C++ compiler driver.
#   Path A: C++ --(EDG front end)--> C --(host C compiler)--> executable
# Usage: nfcxx [--emit-c] [--backend=gcc|pathb] [--dialect=g++|clang] [--gnu-version=N] [--freestanding]
# Options are flags; most also have an NFCXX_* environment variable (listed with each), the fallback for build systems and
# scripts that cannot change a command line. When both are given the flag wins. Tool and host locations stay environment
# variables, as CC= does: NFCXX_GCC, NFCXX_CC, NFCXX_CXX, NFCXX_COSMOCC, NFCXX_SYSTEM_PATHS, NFCXX_SYS_INCLUDES,
# NFCXX_K1OM_ROOT, NFCXX_MACOS_SYSROOT, and the CUDA tuning variables (NFCXX_SM, NFCXX_CUDA_*, docs/notes/gpu.md).
#   Hosted (default): host C++ headers and GNU version from g++ (see scripts/host-sys.rb host_sys_includes below).
#              [-o out] [-std=c++NN] file.cpp...
#   pathb (default on x86-64 Linux, unless cosmo, --emit-c, --target, -E, -M or -shared is
#                  asked for; --backend=pathb, or NFCXX_PATH=b): EDG lowered IL -> typed IR -> QBE, no generated C. Hosted programs, and freestanding ones on x86-64 and aarch64 Linux and arm64 macOS.
#                  A program it does not build is built with the gcc backend instead (docs/notes/pathb-default.md).
#   gcc (default elsewhere, and for the options above): EDG's generated C through the host compiler (scripts/gcc-cc.rb)
#   gcc:           generated C -> gcc -O2 -fwrapv -fno-strict-aliasing
#                  Needs the Path B harness (scripts/setup-pathb.sh, PATHB_CPFE/PATHB_BASE); docs/notes/pathb-hosted.md.
#   --dialect:     EDG front-end mode (default g++; NFCXX_DIALECT overrides the default)
#   --ir-opt=LIST (NFCXX_IR_OPT): the Path B IR passes (docs/notes/pathb-ir-passes.md), a comma-separated list or none. Off by
#                  default for host code; a .cu file's device code runs inline,sroa unless it is set (--ir-opt=off turns them off).
#   --eh-unwind (NFCXX_EH_UNWIND=1): a throw runs the cleanups of the frames it unwinds in the system unwinder (gcc and Path B
#                  backends; docs/notes/eh-shim.md). --no-eh-unwind undoes it. --no-eh-shim (NFCXX_EHSHIM=0) links without the EH shim.
#   --instantiate=used|auto (NFCXX_INSTANTIATE): templates are instantiated in each unit that uses them (default) or by EDG's
#                  prelinker at link time (docs/notes/cxx-driver.md).
#   --promote-slots=on|off, --unroll=on|off, --struct-slots=on|off (NFCXX_PROMOTE_SLOTS, NFCXX_UNROLL, NFCXX_STRUCT_SLOTS = 0|1):
#                  the optimizations of a .cu file's device code (docs/notes/gpu.md); on by default.
#   --pathb-c=gcc (NFCXX_PATHB_C=gcc): with Path B, the .c inputs go through gcc-cc instead of Path B's C front end.
#   --gnu-version: GCC version the g++ front end emulates, e.g. 130000 (EDG default when unset)
#   -fsanitize=undefined|CHECK[,CHECK...]: the undefined behavior sanitizer (docs/notes/ubsan.md). Implies Path B, whose IR has the
#                  checks; a failing check prints "file:line: runtime error: ..." and aborts. -fno-sanitize=all turns it off.
#   file.cpp2:     Cpp2 source, experimental: cppfront (build/cppfront, scripts/setup-cppfront.sh) translates it to C++ first.
#                  docs/notes/cpp2.md.
#   --trace=FILE: write a Chrome trace-event JSON file (open in ui.perfetto.dev); NFCXX_TRACE=FILE too.
#   --time-log=FILE (NFCXX_TIME_LOG=FILE): appends one line per stage, "SECONDS<Tab>CATEGORY<Tab>STAGE<Tab>SOURCE", to FILE; the compiles
#                  of a parallel build can share it (sort -rn FILE ranks them). A .cu file's stages are the rewriter's two
#                  passes, the device front end, the PTX emitter, ptxas, the embed step and the host compile (eccp).
#   --module-dir=DIR: where C++ module interface files (NAME.eifc) are written and read; the default is the directory of -o.
#                  A program with `export module` or `import` is built one source at a time (docs/notes/modules.md).
#   NFCXX_CUDA_HOST_SYMBOLS=FILE: internal (the second pass of a .cu compile, see "Kernel instances from the host
#                  compile" below): the demangled symbols of the first pass's output, for the device rewrite.
#   --keep-intermediates (NFCXX_KEEP_INTERMEDIATES=1): a compile and link keeps its intermediates (the .o files, <stem>.ii, <stem>.ti) in the
#                  temporary directory the driver names on stderr, instead of removing it on exit. A -c compile keeps
#                  <stem>.ii and <stem>.ti beside its object in any case: the link that follows reads them there.
#   -shared [-fPIC] [-rdynamic]: build a shared object (-shared implies -fPIC); -rdynamic exports an
#                  executable's symbols so a dlopen'd object can bind to them. See docs/notes/eval.md.
#   --bundle-libs [--bundle-exclude=NAME,...] [--bundle-only=NAME,...]: after the link, the shared libraries the output
#                  needs (libstdc++, libgcc_s, the program's own; never glibc) are copied into it, so it runs without them
#                  (tools/bundle, docs/notes/bundle.md). Executables and -shared objects.
#   --cuda-driver=auto|cudart|libcuda: a link that names libcuda (-lcuda, CMake's CUDA::cuda_driver path) reaches the
#                  CUDA driver API through libcudart instead (default auto; scripts/wrap.rb,
#                  docs/notes/cuda-driver.md); NFCXX_CUDA_DRIVER= for every command.
#   -c / *.o:      separate compilation: `nfcxx -c a.cpp -o a.o`, then `nfcxx a.o b.o -o x` links objects (docs/notes/multi-tu.md).
#   -fuse-ld=NAME (NFCXX_LD=NAME): link with that linker (mold, lld, gold, bfd; needs ld.NAME on PATH). Default: the system linker.
#   --cache=DIR (NFCXX_CACHE=DIR): keeps each -c compile in DIR and takes it back when nothing it depends on changed (docs/notes/cxx-driver.md).
#                  For a .cu file it keeps the device images (DIR/cu-device): an unchanged device unit skips the device
#                  front end, the PTX emitter and ptxas; the rewriter and the host compile still run.
#   --cache-log=FILE (NFCXX_CACHE_LOG=FILE): with --cache, appends each lookup's key inputs, its key, and hit or miss to FILE, to diff a miss against a hit.
#   NFCXX_CACHE_REMOTE=gha: with the cache, objects are also kept in the GitHub Actions cache (scripts/nfcxx-cache-gha.rb), like sccache's GHA backend.
#   -fsanitize=address: AddressSanitizer (heap/stack/global overflow, use-after-free, double free, leaks). Path B (the default
#                  backend) calls libasan's checks before each access through a computed address (docs/notes/asan-plan.md), and
#                  a program Path B does not build falls back to gcc, which instruments the code; --backend=gcc is used.
#                  docs/notes/asan.md. -fno-sanitize=address undoes it; other -fsanitize= values are
#                  refused (-fsanitize=undefined and its checks are the UBSan option above).
#   -fsafe-pointers: Fil-C-style memory safety checks (docs/notes/safe-pointers.md). Implies Path B: pointer arithmetic must
#                  stay in its object, loads and stores must be in a live object (heap, global, escaping local), and a
#                  freed or returned-from object cannot be used; a failure prints "file:line: safety error: ..." and
#                  aborts. -fno-safe-pointers turns it off.
#   --freestanding: headers come only from lib/ (no EDG std headers, no hosted libc++/libstdc++),
#                  and --gnu-version defaults to 130000. Opt-in; see docs/notes/freestanding.md.
#   --target=NAME: with --freestanding and --emit-c only. The front end lays out the program for an EDG target (sizes,
#                  predefined macros) instead of the build host: linux_aarch64, linux_armv7, linux_riscv64, linux_riscv32,
#                  linux_i686, linux_k1om (Intel Knights Corner: freestanding, the k1om GCC; docs/notes/k1om.md), win64 (MinGW's macros when MinGW is installed at setup; docs/notes/freestanding.md, "Windows"), win32. The generated C is for that target, so the
#                  host cc must not compile it: give it to a cross compiler. docs/notes/freestanding.md, "Targets".
#   --cosmo: build with cosmocc (Cosmopolitan libc, APE output) as the C compiler. Implies --backend=gcc. cosmocc is
#                  read from NFCXX_COSMOCC, else build/cosmocc/bin/cosmocc (scripts/setup-cosmo.sh). docs/notes/cosmo.md.

# The driver starts about 30 Ruby helpers per compile, and each one loads RubyGems first: about 30 ms of its 40 ms startup.
# The helpers use the standard library only, so the driver's children run with --disable=gems (the same outputs; a hello-world
# compile drops from about 2.1 s to 1.0 s). Set before the first child starts; the driver itself is already running.
ENV["RUBYOPT"] = [ENV["RUBYOPT"], "--disable=gems"].compact.reject(&:empty?).join(" ")

require "tempfile"
require "tmpdir"
require "fileutils"
require "open3"
require "rbconfig"
require_relative "nfcxx-setup-args"
require_relative "nfcxx-second-pass"
require_relative "nfcxx-cache-config"
require_relative "nfcxx-sycl"
require_relative "nfcxx-syntax-only"

root = File.expand_path("..", __dir__)
ROOT = root
oracle = File.join(root, "tests", "driver-body", "nfcxx-oracle.sh")
SYCL_SCRIPT = File.join(root, "scripts", "nfcxx-sycl.rb")

# -fsyntax-only (the type check) comes first, as it came first in the body: the command is rewritten (scripts/nfcxx-syntax-only.rb),
# and this driver runs again on the rewritten command in a temporary directory, with its status.
if (syntax = NfcxxSyntaxOnly.plan(ARGV))
  $stderr.write("nfcxx: driver: plan\n") if ENV["NFCXX_DRIVER_TRACE"] == "1"   # the route the pre-loop plan took
  status = nil
  Dir.mktmpdir("nfcxx-fso.") do |dir|
    system(RbConfig.ruby, __FILE__, *NfcxxSyntaxOnly.args_in(syntax, dir))
    status = $?.exitstatus || 128 + $?.termsig
  end
  exit status
end

# --bundle-libs and --cuda-driver= (docs/notes/bundle.md, docs/notes/cuda-driver.md): the wrappers (scripts/wrap.rb) come after the
# -fsyntax-only step and before anything else, as they came first in the body. Status 254 from the bundle wrapper means nothing
# was done and the run goes on; any other status ends the run. A --cuda-driver= run goes on with the arguments the wrapper gives
# (the --cuda-driver= options left out), or is run again with the shim in place of libcuda (EXEC) and ends with that status.
WRAP_RB = File.join(root, "scripts", "wrap.rb")
DRIVER_SHIM = File.join(root, "nfcxx")
WRAP_GO_ON = 254
$stderr.write("nfcxx: driver: plan\n") if ENV["NFCXX_DRIVER_TRACE"] == "1" && ARGV.any? { |a| a.start_with?("--bundle-") }
system(RbConfig.ruby, WRAP_RB, "bundle", DRIVER_SHIM, *ARGV)
bundle_status = $?.exitstatus || 128 + $?.termsig
exit bundle_status unless bundle_status == WRAP_GO_ON
cuda_out = IO.popen([RbConfig.ruby, WRAP_RB, "cuda-driver", DRIVER_SHIM, *ARGV], &:read)
cuda_status = $?.exitstatus || 128 + $?.termsig
exit cuda_status unless cuda_status == 0
cuda_lines = cuda_out.lines.map(&:chomp)
cuda_kind = cuda_lines.shift
if cuda_kind == "EXEC"
  system({ "NFCXX_CUDA_DRIVER" => "libcuda" }, DRIVER_SHIM, *cuda_lines)
  exit($?.exitstatus || 128 + $?.termsig)
end
ARGV.replace(cuda_lines)

# The route dispatch: the pre-loop plan (scripts/nfcxx-loop.rb) runs in scripts/nfcxx-run.rb, and a gcc-route refusal
# (scripts/nfcxx-gcc-plan.rb --live, status 2) is printed here, as the bash prints it. Every other argument list goes to the
# oracle below, which runs the gcc and Path B plans itself (its routes call nfcxx_plan_run and the --records planner).
LOOP = File.join(ROOT, "scripts", "nfcxx-loop.rb")
EARLY = File.join(ROOT, "scripts", "nfcxx-early-exit.rb")
GCC_PLAN = File.join(ROOT, "scripts", "nfcxx-gcc-plan.rb")
PATHB_PLAN = File.join(ROOT, "scripts", "nfcxx-pathb.rb")
CUDA_LIVE = File.join(ROOT, "scripts", "nfcxx-cuda-live.rb")
RUNNER = File.join(ROOT, "scripts", "nfcxx-run.rb")
PLAN_KINDS = %w[RUN EXEC CP CAT LN ENV].freeze
# the kinds of a Path B plan (scripts/nfcxx-pathb.rb --tabs --checks --live): its compiles and links, the CHECK after each
# pathb-cc, and the trace and time log lines
PATHB_KINDS = %w[RUN EXEC CP TRACE TIMELOG START SPAN SPANF CHECK].freeze

def plan_text?(out)
  first = out.lines.first
  !first.nil? && PLAN_KINDS.include?(first.split(/[ \t]/, 2).first)
end

def pathb_text?(out)
  first = out.lines.first
  !first.nil? && PATHB_KINDS.include?(first.split(/[ \t]/, 2).first)
end

# a refusal the bash makes before it runs anything (the Path B port's sanitizer refusals): the message, printed by the driver
Refusal = Struct.new(:message)

def planned_loop?(args)
  out, _err, status = Open3.capture3(RbConfig.ruby, LOOP, *args)
  status.success? && plan_text?(out)
end

# the refusals before the oracle, [input, setup] (scripts/nfcxx-setup-args.rb refusals), computed when one is needed: the
# input's (CUDA, .cpp2 and module) come after the gcc planner in the bash, the setup's after them
def driver_refusals
  @driver_refusals ||= NfcxxSetupArgs.refusals(ARGV, ENV)
end

def gcc_plan(args)
  out, err, status = Open3.capture3(RbConfig.ruby, GCC_PLAN, "--tabs", "--live=#{ROOT}", *args)
  # a refusal (status 2): the port's message is the bash's, so the driver prints it and stops here, as the bash would
  # the setup's refusals come first, as the bash checks them before the backend's name (the setup check below prints them)
  if status.exitstatus == 2 && !plan_text?(out) && driver_refusals[1].nil?
    trace_route("gcc-plan")
    $stderr.write(err)
    exit(2)
  end
  nil
end

# The Path B plan of these arguments (scripts/nfcxx-pathb.rb --live --checks): the default backend, or --backend=pathb (the
# bash's two choices for a hosted compile or link; a gcc choice is the gcc plan's). Returns the plan text, a Refusal (the
# port's refusal, which the bash makes before it runs anything), or nil when the port does not plan these arguments. The
# compile cache (--cache, --cache-log) is the bash's own lookup and store, which the port does not plan: those go to the bash.
# the CUDA compile of these arguments (a .cu input): its status, or nil when the port does not plan them (exit 3 from it).
# It runs the compile itself, in stages, so this is not a probe. Its exit 3 means the bash runs the arguments: when that
# comes after its stages ran, the stages' output is dropped and the bash's own output is the one printed (the bash rewrites
# the same files).
def cuda_run(args)
  return nil unless args.any? { |a| a.end_with?(".cu") }

  pid = Process.spawn(RbConfig.ruby, CUDA_LIVE, "--", *args)
  Process.wait(pid)
  status = $?.exitstatus || 128 + $?.termsig
  status == 3 ? nil : status
end

def pathb_plan(args)
  return nil if ENV.key?("NFCXX_BACKEND") || args.any? { |a| a.start_with?("--cache") }

  backends = args.select { |a| a.start_with?("--backend=") }
  choice, rest =
    if backends.empty? then ["default", args]
    elsif backends == ["--backend=pathb"] then ["pathb", args - backends]
    else return nil
    end
  out, err, status = Open3.capture3(RbConfig.ruby, PATHB_PLAN, "--tabs", "--checks", "--live=#{ROOT}", "--backend=#{choice}", "--", *rest)
  return Refusal.new(err) if status.exitstatus == 2 && out.strip.empty? && !err.strip.empty?
  return nil unless status.success? && pathb_text?(out)

  out
end

def trace_route(kind)
  $stderr.write("nfcxx: driver: #{kind}\n") if ENV["NFCXX_DRIVER_TRACE"] == "1"
end

# runs a plan text with the runner (scripts/nfcxx-run.rb --plan); returns its status
def run_plan_text(text)
  Dir.mktmpdir("nfcxx-plan") do |dir|
    file = File.join(dir, "plan.txt")
    File.write(file, text)
    pid = Process.spawn(RbConfig.ruby, RUNNER, "--root=#{ROOT}", "--plan=#{file}")
    Process.wait(pid)
    $?.exitstatus || 128 + $?.termsig
  end
end

# The SYCL kernel integration (docs/notes/sycl-kernel-builtins.md): a -c compile of one C++ source that includes the oneAPI SYCL
# headers (a -I directory holding sycl/detail/kernel_desc.hpp) runs in two passes, as the real toolchain's integration headers
# do. The decision and the two passes are scripts/nfcxx-sycl.rb's (tests/nfcxx-sycl/run.sh checks them against the bash block).
# The bash body ran this check after its early exits and before its setup, and the early exits never refuse these arguments
# (they have one source, a compile, and no -E, -x or EDG-less path), so the check runs here, before the body, with the body's
# environment (the temporary root and the trace are set up below, and the passes inherit them as before).
def sycl_applies?
  NfcxxSycl.applies?(ARGV)
rescue StandardError
  false
end

# B5: the cache configuration's refusal (NFCXX_CACHE_REMOTE, scripts/nfcxx-cache-config.rb plan). The bash checks it first (its
# line 115, before the argument loop, the routes and the setup, and before its trace begins), so it is checked before anything
# else here. The bash's -fsyntax-only pre-loop plan runs before it, so that command is the oracle's.
unless ARGV.include?("-fsyntax-only")
  _cache_config, cache_refusal = NfcxxCacheConfig.plan(ENV, Process.euid)
  if cache_refusal
    $stderr.puts(cache_refusal)
    exit(2)
  end
end

# The argument loop (scripts/nfcxx-loop.rb --bash-state) runs here, before the routes, on the arguments the body's loop sees. Its
# result is handed to the body in the environment (NFCXX_LOOP_STATUS: 0 and NFCXX_LOOP_STATE the statements to eval, or the
# status and message of a refusal), and the body evals it at the place of its loop: a refusal is printed there, after the
# body's steps before its loop, as before. The body's wrappers (--bundle-*, --cuda-driver=, a link that names libcuda) rewrite
# the arguments before its loop, so for those the loop is left to the body (NFCXX_LOOP_STATUS unset).
LOOP_WRAPPED = /--bundle-|\A--cuda-driver=|libcuda/

def loop_result(args)
  return nil if args.any? { |a| LOOP_WRAPPED.match?(a) }

  out, err, status = Open3.capture3(RbConfig.ruby, LOOP, "--bash-state", "--", *args)
  status.success? ? [0, out] : [status.exitstatus || 1, err]
end

LOOP_RESULT = loop_result(ARGV)

# the body's early exits before its setup (scripts/nfcxx-early-exit.rb pre), run here on the argument loop's state
# (nfcxx-loop.rb --pre-records): [status, records] when the loop finished, status 0 to go on (the body then skips its own
# check: NFCXX_EARLY_PRE_DONE), 2 for a refusal (printed here), 3 for --emit-hip (run here). nil when the loop is left to the body.
def early_pre(args)
  return nil unless LOOP_RESULT && LOOP_RESULT.first == 0
  records, _err, status = Open3.capture3(RbConfig.ruby, LOOP, "--pre-records", "--", *args, binmode: true)
  return nil unless status.success?
  _out, err, check = Open3.capture3(RbConfig.ruby, EARLY, "pre", stdin_data: records, binmode: true)
  $stderr.write(err)
  [check.exitstatus || 1, records]
end

if planned_loop?(ARGV)
  trace_route("plan")
  pid = Process.spawn(RbConfig.ruby, RUNNER, "--root=#{ROOT}", "--", *ARGV)
  Process.wait(pid)
  exit($?.exitstatus || 128 + $?.termsig)
end

# the gcc plan's kinds (CD, NOTE, CHECK, STORE, the placeholders) are the bash's nfcxx_plan_run's: a gcc plan is left to the oracle
# below (only its refusal is printed here). The Path B plan is run below, with the runner, which takes its kinds.
gcc_plan(ARGV) # a refusal exits here; a plan is left to the oracle

# the Path B plan (the default backend, or --backend=pathb), run by the runner: the CHECK lines of the plan are the bash's rule for
# a pathb-cc status (the gcc form re-executes the driver with NFCXX_BACKEND=gcc, as the bash does), so a failed compile is not
# run a second time here. The setup's and the input's refusals come first, as the bash prints them (the oracle prints them).
unless driver_refusals.any?
  cu = cuda_run(ARGV)
  if cu
    trace_route("cuda-plan")
    exit(cu)
  end
  pb = pathb_plan(ARGV)
  if pb.is_a?(Refusal)
    trace_route("pathb-plan")
    $stderr.write(pb.message)
    exit(2)
  end
  if pb
    trace_route("pathb-plan")
    exit(run_plan_text(pb))
  end
end
trace_route("bash")

# The driver body (scripts/nfcxx-body.rb) runs in this process: the same arguments and environment, the trace, the temporary
# directories (a root this process owns, removed when the run ends unless the intermediates are kept), and the SYCL build and the
# refusals before it, as the driver has them above. A fallback to the gcc backend runs the body again with NFCXX_BACKEND=gcc.
require_relative "nfcxx-body"

keep = ENV["NFCXX_KEEP_INTERMEDIATES"] == "1" || ARGV.include?("--keep-intermediates")
tmproot = Dir.mktmpdir("nfcxx-tmp.")
status_code = 1
begin
  ENV["NFCXX_TMP_OWNED"] = "1"
  ENV["TMPDIR"] = tmproot
  input, setup = driver_refusals
  sycl = sycl_applies?
  refusal = sycl ? nil : (input || setup)
  if sycl
    system(ENV.to_h, ENV["RUBY"] || RbConfig.ruby, SYCL_SCRIPT, "run", "--root=#{ROOT}", *ARGV)
    status_code = $?.exitstatus || 128 + $?.termsig
  elsif refusal
    status_code = NfcxxBody.refuse(ARGV, ENV, refusal.message.end_with?("\n") ? refusal.message : "#{refusal.message}\n", refusal.status)
  else
    begin
      status_code = NfcxxBody.run(ARGV, ENV)
    rescue NfcxxBody::Fallback => e
      $stderr.puts(e.message)
      trace_route("gcc-fallback")
      ENV["NFCXX_BACKEND"] = "gcc"
      status_code = NfcxxBody.run(ARGV, ENV)
    end
  end
ensure
  FileUtils.rm_rf(tmproot) unless keep
end
exit status_code
