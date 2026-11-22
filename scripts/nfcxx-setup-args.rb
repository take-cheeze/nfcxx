#!/usr/bin/env ruby
# The setup stage's inputs and refusals for the Ruby driver (stage B3 of docs/notes/driver-body-port.md). scripts/nfcxx.rb calls
# refusal(ARGV, ENV) before it runs the bash oracle, and prints and exits with the refusal it returns.
#
# The setup options are the keys scripts/nfcxx-setup.rb reads, named as the bash variables are. They come from the argument
# loop's full state: scripts/nfcxx-loop.rb with no mode flag prints every variable (its records mode prints only the ones the
# loop assigned, so the defaults the setup reads would be missing). sys, mach and host are uname -s and uname -m; dialect is
# NFCXX_DIALECT when it is set, else host-sys.rb's host_dialect, as the bash sets it.
#
# The bash ends some commands before its setup (the -fsyntax-only and --bundle- re-runs, --emit-hip, the SYCL check, -E, the
# input checks, the EDG check, the dialect check, --emit-c, the sanitizer and safe-pointer checks, which come after a step
# this check does not model). A command that meets one of them is not checked here: refusals returns nil and the oracle runs
# it, so its messages and their order stay the bash's. Any other failure in this check also returns nil (the oracle runs the
# command as before). The .cu and .cpp2 preparation and the module block come before the setup in the bash: their refusals
# are scripts/nfcxx-cu-cpp2-args.rb's, checked here first (see refusals).
#
#   ruby scripts/nfcxx-setup-args.rb ARG...   prints the setup options (KEY=VALUE, the array as KEY=VALUE joined by ASCII 31)
#                                             or the deferral, for the tests

require "etc"
require "open3"
require "rbconfig"
require_relative "nfcxx-setup"
require_relative "nfcxx-cu-cpp2-args"

module NfcxxSetupArgs
  module_function

  ROOT = File.expand_path("..", __dir__)

  # the loop's state: [scalars, arrays] (name => value, name => [elements]), or nil when the loop refuses, is unported, or
  # prints a plan instead (the -fsyntax-only, --bundle- and --cuda-driver= re-runs)
  def loop_state(argv, env)
    # memoized per process (the driver asks for the same arguments' state more than once)
    @loop_states ||= {}
    return @loop_states[argv] if @loop_states.key?(argv)

    @loop_states[argv] = loop_state_uncached(argv, env)
  end

  def loop_state_uncached(argv, env)
    ruby = env["RUBY"] || RbConfig.ruby
    config = env.select { |k, _| k.start_with?("NFCXX_") || k == "CUDA_HOME" || k == "ROCM" }
                .map { |k, v| "--nfcxx-env=#{k}=#{v}" }
    out, status = Open3.capture2(ruby, File.join(ROOT, "scripts", "nfcxx-loop.rb"), *config,
                                 "--nfcxx-uid=#{Process.uid}", "--nfcxx-tmpdir=#{env["TMPDIR"]}", *argv, err: File::NULL)
    return nil unless status.success? && out.start_with?("std=")

    scalars = {}
    arrays = Hash.new { |h, k| h[k] = [] }
    out.each_line(chomp: true) do |line|
      if (m = line.match(/\A(\w+)\+=(.*)\z/m))
        arrays[m[1]] << m[2]
      elsif (m = line.match(/\A(\w+)=(.*)\z/))
        scalars[m[1]] = m[2]
      end
    end
    [scalars, arrays]
  end

  # the options the default and stage planners read, from the loop's full state: the flags (a key the loop does not print is off),
  # the values (a key it does not print is ""), and the host as uname -s and uname -m (Etc.uname: no process)
  PLANNER_FLAGS = %w[backend_explicit path_b freestanding cosmo emit_c preprocess shared asan safeptr].freeze
  PLANNER_VALUES = %w[backend target depmode sanitize].freeze

  def planner_opts(s)
    u = Etc.uname
    opts = PLANNER_FLAGS.to_h { |k| [k, s[k].to_s.empty? ? "0" : s[k].to_s] }
    PLANNER_VALUES.each { |k| opts[k] = s[k].to_s }
    opts["host"] = "#{u[:sysname]} #{u[:machine]}"
    opts
  end

  # The setup state the body evals, from the argument loop's full state: default is the default backend's statements
  # (NfcxxSetup.run "default", which sets backend, default_backend and pb_fs_host), and stage is [status, text] for the stage
  # after the emit-C route (NfcxxSetup.stage_text: the statements on success, the refusal's message and status 2 otherwise).
  # nil when the loop gives no state (the body's wrappers rewrite the arguments, so the body plans them itself).
  def planned_state(argv, env = ENV)
    scalars, _arrays = loop_state(argv, env)
    return nil unless scalars

    opts = planner_opts(scalars)
    default = NfcxxSetup.run("default", opts, env)
    stage = begin
      [0, NfcxxSetup.stage_text(opts)]
    rescue NfcxxSetup::Refusal => e
      [e.status, "#{e.message}\n"]
    end
    { default: default, stage: stage }
  rescue StandardError
    nil
  end

  # the host probes the setup reads: uname, and host-sys.rb's answers
  def uname(flag)
    Open3.capture2("uname", flag, err: File::NULL).first.to_s.chomp
  end

  def host_sys(ruby, command)
    Open3.capture2(ruby, File.join(ROOT, "scripts", "host-sys.rb"), command, err: File::NULL).first.to_s.chomp
  end

  # the setup options for the loop's state (the keys scripts/nfcxx-setup.rb reads)
  def setup_opts(s, arrays, env)
    ruby = env["RUBY"] || RbConfig.ruby
    sys = uname("-s")
    mach = uname("-m")
    # bash: dialect=${NFCXX_DIALECT:-host_dialect}; the loop's default is only its own, used when NFCXX_DIALECT is not set
    dialect = s["dialect_asked"] == "1" ? s["dialect"] : host_sys(ruby, "host_dialect")
    {
      "root" => ROOT, "host" => "#{sys} #{mach}", "sys" => sys, "mach" => mach,
      "backend" => s["backend"], "backend_explicit" => s["backend_explicit"], "path_b" => s["path_b"],
      "freestanding" => s["freestanding"], "cosmo" => s["cosmo"], "emit_c" => s["emit_c"], "target" => s["target"],
      "preprocess" => s["preprocess"], "depmode" => s["depmode"], "shared" => s["shared"],
      "gnu" => s["gnu"], "dialect" => dialect, "dialect_asked" => s["dialect_asked"],
      "instantiate" => s["instantiate"], "asan" => s["asan"], "safeptr" => s["safeptr"], "sanitize" => s["sanitize"],
      "asanopts" => arrays.fetch("asanopts", []).join("\x1f")
    }
  end

  # true when the bash would end before its setup, or after a step this check does not model (see the header)
  def deferred?(s, arrays, argv, env, opts)
    return true if argv.include?("-fsyntax-only")
    return true if argv.any? { |w| w.include?("--bundle-") || w.include?("--cuda-driver") || w.include?("libcuda") }
    return true unless s["emit_hip"].to_s.empty?
    return true if s["emit_c"] == "1" || s["preprocess"] == "1" || s["stdin_src"] == "1"
    return true unless s["sanitize"].to_s.empty?
    return true if s["safeptr"] == "1"
    return true unless ["", "c++", "none"].include?(s["xlang"])
    return true if !s["depmode"].to_s.empty? && s["compile_only"] != "1"

    ncpp = s["ncpp"].to_i
    nobj = s["nobj"].to_i
    cfiles = arrays.fetch("cfiles", [])
    cu = arrays.fetch("cu_inputs", [])
    cpp2 = arrays.fetch("cpp2_inputs", [])
    return true if ncpp + nobj + cfiles.size + cu.size + cpp2.size + (s["stdin_src"] == "1" ? 1 : 0) == 0
    return true if s["target"] == "linux_k1om"
    return true unless %w[g++ clang].include?(opts["dialect"])

    # bash: edg=${EDG_BUILD:-$root/build/edg}/bin; the EDG check runs before the setup when the build needs eccp
    edg = File.join(env["EDG_BUILD"].to_s.empty? ? File.join(ROOT, "build", "edg") : env["EDG_BUILD"], "bin")
    return true if (ncpp > 0 || s["emit_c"] == "1" || (nobj > 0 && cfiles.empty?)) && !File.executable?(File.join(edg, "eccp"))

    ruby = env["RUBY"] || RbConfig.ruby
    # the SYCL check (scripts/nfcxx-sycl.rb check, exit 0: the bash runs the two passes instead). Anything a check writes to
    # stderr (a missing source, for the module scan) is the bash's to print, before its setup: such a command is deferred.
    sycl_out, sycl_err, sycl_st = Open3.capture3(ruby, File.join(ROOT, "scripts", "nfcxx-sycl.rb"), "check", *argv)
    return true if sycl_st.success? || !sycl_err.empty?

    false
  end

  # the refusals before the oracle, as [input, setup]: input is the CUDA, .cpp2 and module refusals (scripts/nfcxx-cu-cpp2-args.rb,
  # which the bash prints before its setup), setup is the setup's. At most one is set; both nil when nothing is refused or the
  # command is deferred to the oracle. The setup check does not run for a command the input check decides (the bash rewrites,
  # translates or compiles before its setup), nor for a module link (the module build runs first).
  def refusals(argv, env = ENV)
    scalars, arrays = loop_state(argv, env)
    return [nil, nil] unless scalars

    opts = setup_opts(scalars, arrays, env)
    return [nil, nil] if deferred?(scalars, arrays, argv, env, opts)

    input = NfcxxCuCpp2Args.check(scalars, arrays, env)
    return [input, nil] if input.is_a?(NfcxxSetup::Refusal)
    return [nil, nil] unless input == :setup

    NfcxxSetup.sequence(opts, env)
    [nil, nil]
  rescue NfcxxSetup::Refusal => e
    [nil, e]
  rescue StandardError
    [nil, nil]
  end
end

if $PROGRAM_NAME == __FILE__
  argv = ARGV.dup
  scalars, arrays = NfcxxSetupArgs.loop_state(argv, ENV)
  if scalars.nil?
    puts "deferred: the loop does not give the state"
  else
    opts = NfcxxSetupArgs.setup_opts(scalars, arrays, ENV)
    if NfcxxSetupArgs.deferred?(scalars, arrays, argv, ENV, opts)
      puts "deferred"
    else
      opts.sort.each { |k, v| puts "#{k}=#{v}" }
    end
  end
end
