#!/usr/bin/env ruby
# nfcxx's CUDA compile, planned in Ruby: a -c compile of one .cu input (the device image of nfcxx's bash cu_prepare and
# cu_rewrite, then the host copy compiled by the Path B port). scripts/nfcxx.rb runs this for the .cu arguments it can plan
# and falls back to the bash driver otherwise.
#
# The bash's order, with each stage planned from the facts the stage before it made:
#   1. the rewriter's host copy and device unit (scripts/nfcxx-cuda-device.rb --phase=prep), which writes the kernel list;
#   2. the device IR and the module images (--phase=emit, with the kernels as facts);
#   3. the ptxas run of each group and the embedding of the images into the copy (--phase=finish, with the group files as
#      facts); the device image cache is not used (a --cache or NFCXX_CACHE is refused, below);
#   4. the host copy compiled as a C++ source (scripts/nfcxx-pathb.rb, with the copy in place of the .cu, the copy's
#      directory as -I, nfcxx_cuda.h as -include, and --nfcxx-cuda-unit for the --cuda the bash passes).
# Each plan runs through scripts/nfcxx-run.rb. Exit 3 means "not planned here, run the bash driver with the same arguments";
# nothing has been observable before that in the stages that ran, except the temporary files and the copy, which the bash
# rewrites. A failure of the host compile under the default backend also exits 3 (the bash builds the program with gcc).
# Other statuses are the driver's, as the bash's are.
#
# Refused (exit 3): a link (no -c), a source or object other than the one .cu, -E, -fsyntax-only, the depfile options, the
# cache (NFCXX_CACHE, --cache=, the device image cache), the trace and time-log, --keep-intermediates, a backend other than
# default or pathb, the AMD GPU target, NFCXX_CUDA_HOST_SYMBOLS, and the environment variables of the bash that this port
# does not model (NFCXX_BACKEND, NFCXX_IR_OPT, NFCXX_EH_UNWIND, NFCXX_EHSHIM, NFCXX_INSTANTIATE, NFCXX_PATHB_C, NFCXX_SYCL_PASS).
# The Path B port refuses what it does not model (exit 3 from it), which falls back the same way.
#
# What this planned driver does on a toolkit whose headers the Path B port refuses: the host copy's plan is made, its run
# fails (the default backend), and the bash runs the arguments (the gcc route). The device stages before it are the Ruby's,
# and NFCXX_CUDA_LIVE_STOP=prep|emit|finish (a test hook) stops after a stage, with status 0, so the device products can be
# compared with the bash's (tests/nfcxx-cuda-live/run.sh). The CUDA 13.5 headers declare 32-byte aligned vector types
# (long4_32a), which the Path B SSA route refuses (QbeUnsupported), so every .cu compile on that toolkit takes the bash route.
#
#   ruby scripts/nfcxx-cuda-live.rb -- ARG...     plans and runs the compile; exit status as above
require "fileutils"
require "open3"
require "rbconfig"
require "tmpdir"
require_relative "nfcxx-cuda-device"

ROOT = File.expand_path("..", __dir__)
RUNNER = File.join(ROOT, "scripts", "nfcxx-run.rb")
PATHB_PLAN = File.join(ROOT, "scripts", "nfcxx-pathb.rb")
NFCXX_CUDA_HEADER = File.join(ROOT, "lib", "cuda", "nfcxx_cuda.h")

# the bash's refusal, for the arguments this port does not plan (the driver runs the bash with the same arguments)
class Fallback < StandardError; end

# the variables of the bash that set a behaviour this port does not model (refused when non-empty; NFCXX_BACKEND when set)
REFUSED_ENV = %w[NFCXX_CACHE NFCXX_CACHE_REMOTE NFCXX_CACHE_LOG NFCXX_CUDA_HOST_SYMBOLS NFCXX_TIME_LOG NFCXX_TRACE
                 NFCXX_PATHB_C NFCXX_SYCL_PASS NFCXX_IR_OPT NFCXX_EH_UNWIND NFCXX_EHSHIM NFCXX_INSTANTIATE].freeze
# the options this port does not model: these words exactly, and these prefixes
REFUSED_WORDS = %w[-E -fsyntax-only -x -shared --emit-c --emit-hip --freestanding --cosmo --cuda -].freeze
REFUSED_PREFIXES = %w[--target= --cache --time-log= --trace= --keep-intermediates --pathb-c= -fsanitize -fno-sanitize
                      --module-dir= --cuda-driver= --bundle --eh --no-eh -l -L -fuse-ld= -M].freeze
# options that take the next argument (joined here as one word, as the bash joins the separate forms)
TAKES_VALUE = %w[-o -I -D -U -include -isystem].freeze

def fallback!(why)
  raise Fallback, why
end

# The arguments, read as the bash reads them for a -c compile of one .cu input.
class Args
  attr_reader :cu, :out, :cflags, :obfuscate, :ir_opt, :promote, :unroll, :struct_slots, :backend, :pathb_args

  def initialize(argv, env)
    @cu = []
    @out = nil
    @compile = false
    @cflags = []
    @obfuscate = false
    @ir_opt = nil
    @promote = @unroll = @struct_slots = nil
    @backend = "default"
    @backend_seen = false
    @pathb_args = []
    @env = env
    parse(argv)
  end

  def compile? = @compile

  private

  def parse(argv)
    i = 0
    while i < argv.size
      a = argv[i]
      nxt = argv[i + 1]
      if TAKES_VALUE.include?(a)
        fallback!("#{a} needs an argument") if nxt.nil?
        @out = nxt if a == "-o"
        @cflags << "#{a}#{nxt}" if %w[-I -D -U].include?(a)
        @pathb_args.push(a, nxt)
        i += 2
        next
      end
      if a.end_with?(".cu") && !a.start_with?("-")
        @cu << a
        @pathb_args << a
      elsif a.start_with?("-I", "-D", "-U") && a.size > 2
        @cflags << a
        @pathb_args << a
      elsif a == "-c"
        @compile = true
        @pathb_args << a
      elsif a == "--obfuscate-kernels"
        @obfuscate = true
        @pathb_args << a
      elsif a.start_with?("--ir-opt=")
        @ir_opt = a.delete_prefix("--ir-opt=")
        @pathb_args << a
      elsif %w[--promote-slots= --unroll= --struct-slots=].any? { |p| a.start_with?(p) }
        name, value = a.split("=", 2)
        v = { "on" => "1", "1" => "1", "off" => "0", "0" => "0" }[value]
        fallback!("#{name} takes on or off") if v.nil?
        case name
        when "--promote-slots" then @promote = v
        when "--unroll" then @unroll = v
        when "--struct-slots" then @struct_slots = v
        end
        @pathb_args << a
      elsif a.start_with?("--backend=")
        # the planner takes the backend choice as its own argument (the option is not in pathb_args)
        value = a.delete_prefix("--backend=")
        fallback!("--backend=#{value}") unless value == "pathb"
        fallback!("two --backend options") if @backend_seen
        @backend = value
        @backend_seen = true
      elsif REFUSED_WORDS.include?(a) || REFUSED_PREFIXES.any? { |p| a.start_with?(p) }
        fallback!("option #{a}")
      elsif !a.start_with?("-")
        fallback!("input #{a}: only the one .cu input is planned")
      else
        @pathb_args << a
      end
      i += 1
    end
    fallback!("a link (no -c)") unless @compile
    fallback!("#{@cu.size} .cu inputs (one is planned)") unless @cu.size == 1
    fallback!("#{@cu[0]}: no such file") unless File.file?(@cu[0])
    fallback!("NFCXX_BACKEND is set") if @env.key?("NFCXX_BACKEND")
    REFUSED_ENV.each { |name| fallback!("#{name} is set") unless @env[name].to_s.empty? }
    fallback!("NFCXX_CUDA_TARGET=#{@env["NFCXX_CUDA_TARGET"]}") if @env["NFCXX_CUDA_TARGET"] == "amdgpu"
  end
end

# the environment of the bash's exports (NFCXX_SYSTEM_PATHS: CUDA_HOME first, then what the caller set)
def system_paths(env)
  home = env["CUDA_HOME"].to_s
  return nil if home.empty?

  rest = env["NFCXX_SYSTEM_PATHS"].to_s
  rest.empty? ? home : "#{home}:#{rest}"
end

# The output of the stages, kept until the outcome is known: it is printed when the planned driver answers the arguments, and
# dropped when the bash runs them instead (so the bash's own messages are printed once, not twice).
class Output
  def initialize
    @out = +""
    @err = +""
  end

  def add(out, err)
    @out << out
    @err << err
  end

  def flush
    $stdout.write(@out)
    $stderr.write(@err)
  end
end

# NFCXX_CUDA_LIVE_STOP=prep|emit|finish (a test's hook): the compile stops after that stage, with status 0, so the device
# products (the copy with its images, the groups) can be compared with the bash's. NFCXX_DRIVER_TRACE=1 prints each stage.
def stage_done(name, env, detail = "")
  $stderr.write("nfcxx-cuda-live: stage #{name} done#{detail}\n") if env["NFCXX_DRIVER_TRACE"] == "1"
end

# runs a plan file with the runner (the same temporary directory, the bash's exports as --env); its output is kept in output
def run_plan(text, tmp, exports, name, output)
  file = File.join(tmp, "#{name}.plan")
  File.write(file, text)
  opts = exports.flat_map { |k, v| ["--env", "#{k}=#{v}"] }
  out, err, st = Open3.capture3(RbConfig.ruby, RUNNER, "--root=#{ROOT}", "--tmp=#{tmp}", *opts, "--plan=#{file}")
  output.add(out, err)
  st.exitstatus || 128 + st.termsig
end

# the plan of the device stages (CudaDevicePlan.run), with the facts of the stages before it
def device_lines(env, args, tmp, phase, kernels: [], groups: [])
  plan = CudaDevicePlan.new(
    root: ROOT, tmp: tmp, env: env, files: [], dirs: [], live: true, tabs: true, phase: phase,
    cflags: args.cflags, kernels: kernels, groups: groups, compile: args.compile?, out: args.out,
    ir_opt: args.ir_opt, obfuscate: args.obfuscate, promote: args.promote, unroll: args.unroll,
    struct_slots: args.struct_slots, cache_dir: nil, cache_key: nil, src: args.cu[0]
  )
  [plan, plan.run]
end

def kernels_of(path)
  return [] unless File.file?(path)

  File.readlines(path, chomp: true).reject(&:empty?)
end

def groups_of(dir)
  return [] unless Dir.exist?(dir)

  Dir.children(dir).select { |f| f.start_with?("g") && f.end_with?(".ptx") }.sort
end

# The environment the Path B planner sees. Its live facts refuse any NFCXX_* variable and CUDA_HOME, since they can change a
# driver's lines; the ones here cannot: the device stages (planned above, and their variables are the device planner's), and
# the variables pathb-cc reads while it runs (it runs with the full environment, from the runner). The variables that change
# the driver's own lines are refused in Args (REFUSED_ENV), so the planner's assumption holds: NFCXX_LD and NFCXX_DIALECT stay.
def pathb_planner_env(env)
  keep = %w[NFCXX_LD NFCXX_DIALECT NFCXX_DRIVER_TRACE]
  env.keys.select { |k| (k.start_with?("NFCXX_") && !keep.include?(k)) || k == "CUDA_HOME" }.to_h { |k| [k, nil] }
end

# the host copy's Path B plan: the arguments with the copy for the .cu, its directory as -I, and nfcxx_cuda.h as -include
def host_args(args, copy, src_dir, env)
  words = args.pathb_args.map { |a| a == args.cu[0] ? copy : a }
  words += ["-I#{src_dir}"]
  preinc = words.each_cons(2).select { |a, _| a == "-include" }.map(&:last)
  words += ["-include", NFCXX_CUDA_HEADER] unless preinc.include?(NFCXX_CUDA_HEADER)
  edg = env["NFCXX_CUDA_EDG_LAUNCH"].to_s
  words += ["--nfcxx-cuda-unit"] if edg.empty? || edg == "1"   # the bash's cuda_opts: --cuda, with the EDG launches
  words
end

# The compile of the arguments: the status of the planned driver. It returns with the output of its stages to be printed
# (output), or raises Fallback before anything is printed.
def run_compile(argv, env, output)
  args = Args.new(argv, env)
  src = args.cu[0]
  src_dir = File.realpath(File.dirname(src))
  exports = {}
  sp = system_paths(env)
  exports["NFCXX_SYSTEM_PATHS"] = sp if sp
  Dir.mktmpdir("nfcxx-cu") do |tmp|
    startup = "RUN\tensure_tool\t#{ROOT}/tools/cuda-rewrite\t#{ROOT}/build/cuda-rewrite\n"
    plan, prep = device_lines(env, args, tmp, :prep)
    status = run_plan(startup + prep.join("\n") + "\n", tmp, exports, "prep", output)
    return status unless status.zero?

    kernels = kernels_of(File.join(tmp, "#{File.basename(src, ".cu")}.dev.kernels"))
    stage_done("prep", env, " (#{kernels.size} kernels)")
    return 0 if env["NFCXX_CUDA_LIVE_STOP"] == "prep"
    # the bash's second pass (scripts/nfcxx-second-pass.rb): kernel instances the device unit leaves unresolved are the host
    # compile's, and this route does not build them; the bash does
    unresolved = File.join(tmp, "#{File.basename(src, ".cu")}.dev.kernels.unresolved")
    fallback!("the unit has kernel instances only the host compile makes (the bash's second pass)") if File.size?(unresolved)
    unless kernels.empty?
      _, emit = device_lines(env, args, tmp, :emit, kernels: kernels)
      status = run_plan(emit.join("\n") + "\n", tmp, exports, "emit", output)
      return status unless status.zero?

      stage_done("emit", env)
      return 0 if env["NFCXX_CUDA_LIVE_STOP"] == "emit"
      groups = groups_of(plan.groups_dir)
      _, finish = device_lines(env, args, tmp, :finish, kernels: kernels, groups: groups)
      status = run_plan(finish.join("\n") + "\n", tmp, exports, "finish", output)
      return status unless status.zero?

      stage_done("finish", env, " (#{groups.size} groups)")
      return 0 if env["NFCXX_CUDA_LIVE_STOP"] == "finish"
    end

    words = host_args(args, plan.copy, src_dir, env)
    choice = args.backend
    out, err, st = Open3.capture3(pathb_planner_env(env), RbConfig.ruby, PATHB_PLAN, "--tabs", "--live=#{ROOT}",
                                  "--backend=#{choice}", "--", *words)
    fallback!("the Path B port does not plan the host copy: #{err.strip}") unless st.success? && !out.empty?
    fallback!("the host copy's plan has an exec (the gcc fallback or -E)") if out.lines.any? { |l| l.start_with?("EXEC\t") }
    host = run_plan(out, tmp, exports, "host", output)
    stage_done("host", env, " (status #{host})")
    # the default backend's failure is the bash's to report and to rebuild with gcc: it runs the arguments again
    fallback!("the Path B host compile failed (status #{host}); the bash builds it with gcc") if host != 0 && choice == "default"
    host
  end
end

if $PROGRAM_NAME == __FILE__
  argv = ARGV.first == "--" ? ARGV.drop(1) : ARGV
  begin
    output = Output.new
    status = run_compile(argv, ENV.to_h, output)
    output.flush
    exit(status)
  rescue Fallback => e
    $stderr.write("nfcxx-cuda-live: #{e.message}\n") if ENV["NFCXX_DRIVER_TRACE"] == "1"
    exit 3
  rescue CudaUnported => e
    $stderr.write("nfcxx-cuda-live: #{e.message}\n") if ENV["NFCXX_DRIVER_TRACE"] == "1"
    exit 3
  rescue CudaRefused => e
    $stderr.write("nfcxx: #{e.message}\n")
    exit 2
  rescue SystemCallError, IOError, KeyError, ArgumentError => e
    # a failure the port does not expect (a file it cannot read): the bash decides, with the same arguments
    $stderr.write("nfcxx-cuda-live: #{e.class}: #{e.message}\n") if ENV["NFCXX_DRIVER_TRACE"] == "1"
    exit 3
  end
end
