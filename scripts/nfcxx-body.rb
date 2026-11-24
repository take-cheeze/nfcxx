#!/usr/bin/env ruby
# The driver body of nfcxx in Ruby: the port of tests/driver-body/nfcxx-oracle.sh (the bash body), in the body's order, with the
# same messages, statuses, outputs and temporary directories. scripts/nfcxx.rb runs it in this process in place of the bash body.
#
# The state the body kept in shell variables is in @v (scalars, Strings) and @a (arrays, Arrays of Strings). The planners that
# print shell statements (setup, cu/cpp2 preparation, the cache lookup, the second pass) are read back with
# NfcxxSetupState.apply_text, which takes exactly the statements they print.
#
#   NfcxxBody.run(argv, env) -> status         (raises NfcxxBody::Fallback when the gcc backend must build the program)

require "fileutils"
require "open3"
require "rbconfig"
require "shellwords"
require "tmpdir"
require "tempfile"
require_relative "nfcxx-loop"
require_relative "nfcxx-setup-args"
require_relative "nfcxx-setup-state"
require_relative "trace"
require_relative "nfcxx-emit-c"

module NfcxxBody
  ROOT = File.expand_path("..", __dir__)
  EDG_DEFAULT = File.join(ROOT, "build", "edg")
  SCALARS = %w[std out outset emit_c emit_hip backend backend_explicit path_b ir_opt ir_opt_set eh_unwind_on eh_shim_on
               cache_dir cache_log_file keep_intermediates time_log instantiate promote_slots unroll struct_slots pathb_c
               ld_name obfuscate dialect dialect_asked gnu gnu_user freestanding cosmo target trace moddir asan safeptr
               sanitize shared pic rdynamic compile_only pthread preprocess xlang stdin_src depmode dfile dtarget depphony
               ncpp nobj system_paths vec_assoc].freeze
  ARRAYS = %w[files cflags cfiles cu_inputs cpp2_inputs srcs ppflags pie_opts preinc sysdirs isa diag_opts asanopts].freeze

  # a refusal or a route's exit: the status the driver ends with, its message (on standard error) first
  class Exit < StandardError
    attr_reader :status
    def initialize(status, message = "")
      super(message)
      @status = status
    end
  end

  # the gcc backend builds the program after this one failed (the bash's fallback_gcc): the driver prints the message and runs again
  class Fallback < StandardError
  end

  module_function

  # ---------------------------------------------------------------------------------------------------------------------
  # the run

  def run(argv, env = ENV)
    @env = env
    @argv = argv.dup
    NfcxxSetupArgs.forget
    @planned = nil
    @state_values = {}
    @v = {}
    @a = {}
    @trace_t0 = nil
    @temps = []
    # the directories of the run are made under TMPDIR (the driver's temporary root), as the body's mktemp -d made them
    @owned_root = env["TMPDIR"].to_s.empty? ? Dir.tmpdir : env["TMPDIR"]
    # --keep-intermediates: the directories of the eccp call are kept, and the children see the setting (as the bash exported it)
    env["NFCXX_KEEP_INTERMEDIATES"] = "1" if env["NFCXX_KEEP_INTERMEDIATES"] == "1" || argv.include?("--keep-intermediates")
    @keep = env["NFCXX_KEEP_INTERMEDIATES"] == "1"
    begin
      body
    rescue Exit => e
      $stderr.write(e.message) unless e.message.empty?
      e.status
    rescue Fallback
      # the body's fallback_gcc ends this run without its span: the file gets this run's end marker, and the gcc run writes its span
      # (the directories this run made are removed, as the bash's fallback_gcc removed them, whether or not they are kept)
      close_trace_marker
      cleanup_temps(force: true)
      raise
    ensure
      cleanup_temps
    end
  end

  # a refusal the driver prints before the body runs (the setup's and the input's, scripts/nfcxx.rb): the trace is opened first, as
  # the bash did, so the file and its end are written; the message goes to standard error and the status is the refusal's
  def refuse(argv, env, message, status)
    @env = env
    @argv = argv.dup
    file = argv.reverse.find { |a| a.start_with?("--trace=") }&.delete_prefix("--trace=") || env["NFCXX_TRACE"].to_s
    @trace_t0 = NfccxxTrace.begin_trace(file, env: env) unless file.empty?
    $stderr.write(message)
    status
  ensure
    close_trace_marker
  end

  # the end marker of a trace this process owns, without a span (the bash's exits that end before the driver's span)
  def close_trace_marker
    return unless @trace_t0

    @trace_t0 = nil
    flush_pending
    return unless @env["NFCXX_TRACE_OWNER"].to_s == Process.pid.to_s

    File.open(@env["NFCXX_TRACE"], "a") do |f|
      f.write(format(%({"name":"trace_end","ph":"i","s":"g","ts":%d,"pid":%d,"tid":1}\n]\n), NfccxxTrace.now_us, Process.pid))
    end
  end

  # the run's directories are removed when it ends, unless the intermediates are kept (the eccp directory then stays, as the bash kept it)
  def cleanup_temps(force: false)
    @temps.each { |d| FileUtils.rm_rf(d) } if force || !@keep
    @temps = []
    finish_trace
  end

  def fail!(message, status = 2)
    text = message.to_s.empty? || message.end_with?("\n") ? message.to_s : "#{message}\n"
    raise Exit.new(status, text)
  end

  # ---------------------------------------------------------------------------------------------------------------------
  # state helpers

  def v(name)
    @v.fetch(name, "").to_s
  end

  def flag?(name)
    v(name) == "1"
  end

  def a(name)
    @a.fetch(name, [])
  end

  def set(name, value)
    @v[name] = value.to_s
  end

  def apply(text)
    NfcxxSetupState.apply_text(text.to_s, @state_values, @env)
  end

  # the state as the shell records the driver writes (scripts/driver-state.rb): k NAME, then v VALUE for each value
  def state_put(out, name, *values)
    out << "k#{name}\0"
    values.flatten.each { |x| out << "v#{x}\0" }
  end

  # a command that cannot be started is status 127, as the shell reports it (its message goes to standard error)
  def run_cmd(*cmd, env: {}, out: nil, chdir: nil)
    options = out ? { out: out } : {}
    options[:chdir] = chdir if chdir
    pid = Process.spawn(env, *cmd, **options)
    Process.wait(pid)
    $?.exitstatus || 128 + $?.termsig
  rescue Errno::ENOENT, Errno::EACCES => e
    $stderr.puts(e.message)   # the shell's message, not the driver's
    127
  end

  def capture(*cmd, env: {}, stdin: nil)
    opts = stdin ? { stdin_data: stdin, binmode: true } : { binmode: true }
    out, err, status = Open3.capture3(env, *cmd, **opts)
    [out, err, status.exitstatus || 128 + status.termsig.to_i]
  rescue Errno::ENOENT, Errno::EACCES => e
    ["", "#{e.message}\n", 127]
  end

  def ruby_cmd
    @env["RUBY"].to_s.empty? ? RbConfig.ruby : @env["RUBY"]
  end

  def script(name, *args)
    File.join(ROOT, "scripts", name)
  end

  def flags_from(names)
    names.select { |n| flag?(n) }
  end

  def host_dialect
    out, _, _ = capture(ruby_cmd, script("host-sys.rb"), "host_dialect")
    out.chomp
  end

  def abs_path(path)
    out, _, _ = capture(ruby_cmd, script("host-sys.rb"), "abs_path", path)
    out.chomp
  end

  def temp_dir(kind)
    d = Dir.mktmpdir("tmp.", @owned_root)
    @temps << d
    d
  end

  def edg_base
    @env["EDG_BUILD"].to_s.empty? ? EDG_DEFAULT : @env["EDG_BUILD"]
  end

  def edg
    File.join(edg_base, "bin")
  end

  def libc_a
    File.join(edg_base, "lib", "libC.a")
  end

  def trace_start
    NfccxxTrace.enabled?(@env) ? NfccxxTrace.now_us : 0
  end

  def trace_end(start, name, category)
    NfccxxTrace.span(start, name, category, env: @env) if NfccxxTrace.enabled?(@env)
  end

  def finish_trace
    return if @trace_t0.nil?

    t0 = @trace_t0
    @trace_t0 = nil
    flush_pending
    NfccxxTrace.finish_trace(t0, env: @env)
  end

  # the spans the children of this run recorded in the pending file (the eccp call's, scripts/nfcxx-eccp-run.rb) go to the trace
  def flush_pending
    pending = @env["NFCXX_TRACE_PENDING"].to_s
    return if pending.empty? || !File.size?(pending)

    NfccxxTrace.flush(pending, env: @env)
  end

  # ---------------------------------------------------------------------------------------------------------------------
  # the body, in its order

  def body
    read_loop
    early_pre
    setup_default
    setup_asan
    trace_unit
    trace_begin
    cu_prepare
    syntax_and_tool
    preprocess_route if flag?("preprocess")
    post_early
    modules_block
    setup_rest
    ecp_answers
    pre_options
    return emit_c_route if flag?("emit_c")
    setup_stage
    setup_flags
    setup_backend_env
    shim_and_link_options
    c_inputs
    cache_and_routes
    nil
  end

  # the argument loop: the state the loop leaves (scripts/nfcxx-loop.rb), as the body's variables
  def read_loop
    config = @env.select { |k, _| k.start_with?("NFCXX_") || k == "CUDA_HOME" || k == "ROCM" }.to_h
    uid = Process.uid.to_s
    tmpdir = @env["TMPDIR"].to_s
    ld = ld_on_path(@argv)
    ls = begin
      loop_state(@argv, config, uid, tmpdir, ld)
    rescue NfcxxExit => e
      raise Exit.new(e.status, e.message.end_with?("\n") ? e.message : "#{e.message}\n")
    rescue NfcxxMissing => e
      raise Exit.new(1, "nfcxx: #{e.message} needs a value\n")
    rescue NfcxxUnported => e
      # the loop does not port this option: its message and status (scripts/nfcxx-loop.rb main)
      raise Exit.new(3, "unported: #{e.message}\n")
    end
    @v = {}
    @a = {}
    SCALARS.each { |n| @v[n] = ls.public_send(n).to_s }
    ARRAYS.each { |n| @a[n] = ls.public_send(n).map(&:to_s) }
    @v["vec_assoc"] = ls.vec_assoc.to_s
    @state_values = {}
    @v["dialect"] = flag?("dialect_asked") ? v("dialect") : host_dialect
    @v["std"] = "--c++23" if v("std").empty?
    @v["out"] = "a.out" if v("out").empty?
    @v["instantiate"] = "used" if v("instantiate").empty?
    @v["promote_slots"] = "1" if v("promote_slots").empty?
    @v["unroll"] = "1" if v("unroll").empty?
    @v["struct_slots"] = "1" if v("struct_slots").empty?
    @v["eh_shim_on"] = "1" if v("eh_shim_on").empty?
    @v["compile_only"] = "0" if v("compile_only").empty?
    @v["ncpp"] = "0" if v("ncpp").empty?
    @v["nobj"] = "0" if v("nobj").empty?
    @v["sysdirs_n"] = a("sysdirs").size.to_s
    @v["moves"] = flag?("compile_only") ? "0" : "1"
    @v["keep_intermediates"] = "1" if flag?("keep_intermediates") || @argv.include?("--keep-intermediates")
    @v["moves"] = "1" unless flag?("compile_only")
    @v["out_base"] = v("out")
    @v["ecp_list"] = ""
    @v["hosted_libs"] = ""
    @v["fallback_ok"] = "1"
    @v["default_backend"] = "0"
    @v["pb_fs_host"] = "0"
    @v["pathb_c"] = v("pathb_c")
    @v["cache_remote"] = @env["NFCXX_CACHE_REMOTE"].to_s
    @v["cache_dir"] = v("cache_dir")
    if v("cache_dir").empty? && !v("cache_remote").empty? && v("cache_remote") != ""
      @v["cache_dir"] = File.join(@env["TMPDIR"].to_s.empty? ? "/tmp" : @env["TMPDIR"], "nfcxx-cache-#{Process.uid}")
    end
    unless %w[gha].include?(v("cache_remote")) || v("cache_remote").empty?
      fail!("nfcxx: NFCXX_CACHE_REMOTE takes gha (got '#{v("cache_remote")}')")
    end
    @v["trace"] = v("trace")
    @v["trace"] = @env["NFCXX_TRACE"].to_s if v("trace").empty?
    @v["time_log"] = v("time_log")
    @env["NFCXX_TIME_LOG"] = abs_path(v("time_log")) unless v("time_log").empty?
  end

  # the default backend and the sanitizer's options, from the setup planners (their statements, read back here)
  def planned
    @planned ||= NfcxxSetupArgs.planned_state(@argv, @env) or fail!("nfcxx: the setup could not be planned for these arguments")
  end

  def setup_default
    default = planned[:default]
    apply(default)
    @v["backend"] = @state_values["backend"].to_s
    @v["default_backend"] = @state_values["default_backend"].to_s
    @v["pb_fs_host"] = @state_values["pb_fs_host"].to_s
  end

  def setup_asan
    status, text = planned[:asan]
    if status.to_i != 0
      fail!(text, status.to_i)
    end
    apply(text)
    @a["asan_c"] = @state_values.fetch("asan_c", []) if @state_values.key?("asan_c")
    @a["asanopts"] = @state_values.fetch("asanopts", []) if @state_values.key?("asanopts")
  end

  # the trace unit (the first source, else the output), set before tracing starts
  def trace_unit
    apply(planned[:trace_unit])
    exports_to_env
  end

  def trace_begin
    file = v("trace")
    return if file.empty?

    @trace_t0 = NfccxxTrace.begin_trace(file, env: @env)
    # the spans of this run are written as they end; the pending file the children see stays empty (the bash batched them there)
    @env["NFCXX_TRACE_PENDING"] = File.join(@owned_root, "nfcxx-trace-pending.#{Process.pid}")
    File.write(@env["NFCXX_TRACE_PENDING"], "")
  end

  # --- the .cu and .cpp2 inputs ------------------------------------------------------------------------------------

  def cu_prepare
    return if a("cu_inputs").empty? && a("cpp2_inputs").empty?

    cudatmp = temp_dir("cudatmp")
    @v["cudatmp"] = cudatmp
    recs, _err, st = capture(ruby_cmd, script("nfcxx-cu-records.rb"), ROOT, cudatmp, Process.pid.to_s, "--", *@argv,
                             env: @env)
    fail!("nfcxx: nfcxx-cu-records failed", st) unless st == 0
    out, err, st = capture(ruby_cmd, script("nfcxx-cu-cpp2-prepare.rb"), "both", stdin: recs, env: @env)
    $stderr.write(err)
    fail!("", st) unless st == 0
    apply(out)
    @a["srcs"] = @state_values.fetch("srcs", a("srcs"))
    @a["files"] = @state_values.fetch("files", a("files"))
    @a["cflags"] = @state_values.fetch("cflags", a("cflags"))
    @a["cuda_opts"] = @state_values.fetch("cuda_opts", [])
    @a["preinc"] = @state_values.fetch("preinc", a("preinc"))
  end

  # --- the tool check and the syntax route -------------------------------------------------------------------------

  def syntax_and_tool
    @env["NFCXX_SYSTEM_PATHS"] = "#{@env["CUDA_HOME"]}#{@env["NFCXX_SYSTEM_PATHS"] ? ":" + @env["NFCXX_SYSTEM_PATHS"] : ""}" if @env["CUDA_HOME"].to_s != ""
    if v("cuda_target") == "amdgpu"
      @env["NFCXX_SYSTEM_PATHS"] = "#{ROOT}/lib/hip:#{@env["ROCM"] || "/opt/rocm"}/include"
    end
    st = run_cmd(ruby_cmd, script("nfcxx-ensure-tool.rb"), File.join(ROOT, "tools", "cuda-rewrite"), File.join(ROOT, "build", "cuda-rewrite"))
    fail!("", st) unless st == 0
  end

  # the early exits before the setup (scripts/nfcxx-early-exit.rb pre), and the --emit-hip route (status 3)
  def early_pre
    recs = early_records
    _out, err, st = capture(ruby_cmd, script("nfcxx-early-exit.rb"), "pre", stdin: recs, env: @env)
    $stderr.write(err)
    case st
    when 0 then nil
    when 3
      hip = a("cflags").select { |f| f =~ /\A-[IDU]/ }
      cu = a("cu_inputs")[0]
      exec_status = run_cmd(File.join(ROOT, "build", "cuda-rewrite"), "--hip", *hip, cu)
      raise Exit.new(exec_status)
    else
      raise Exit.new(st)
    end
  end

  def early_records
    kv = ["ncpp=#{v("ncpp")}", "nobj=#{v("nobj")}", "cfiles_n=#{a("cfiles").size}", "cu_n=#{a("cu_inputs").size}",
          "stdin_src=#{v("stdin_src")}", "emit_hip=#{v("emit_hip").empty? ? "0" : v("emit_hip")}",
          "compile_only=#{v("compile_only")}", "emit_c=#{v("emit_c")}", "xlang=#{v("xlang")}", "depmode=#{v("depmode")}",
          "dialect=#{v("dialect")}", "edg=#{edg}"]
    kv.map { |x| "s#{x}\0" }.join
  end

  def post_early
    _out, err, st = capture(ruby_cmd, script("nfcxx-early-exit.rb"), "post", stdin: early_records, env: @env)
    $stderr.write(err)
    raise Exit.new(st) unless st == 0
  end

  # --- the -E route ---------------------------------------------------------------------------------------------------

  def preprocess_records
    out = +""
    scalar = ->(k, x) { out << "s#{k}=#{x}\0" }
    scalar.("host", @env["NFCXX_CXX"] || "g++")
    scalar.("std", v("std"))
    scalar.("xlang", v("xlang"))
    scalar.("outset", v("outset"))
    scalar.("out", v("out"))
    scalar.("stdin_src", v("stdin_src"))
    a("ppflags").each { |x| out << "e#{x}\0" }
    a("cflags").each { |x| out << "c#{x}\0" }
    a("sysdirs").each { |x| out << "d#{x}\0" }
    a("preinc").each { |x| out << "i#{x}\0" }
    a("srcs").each { |x| out << "r#{x}\0" }
    out
  end

  # the -E route: the host C++ compiler preprocesses (scripts/nfcxx-preprocess.rb plans the command); the body execs it
  def preprocess_route
    recs, err, st = capture(ruby_cmd, script("nfcxx-preprocess.rb"), stdin: preprocess_records, env: @env)
    $stderr.write(err)
    raise Exit.new(st) unless st == 0
    argv = recs.split("\0", -1).reject(&:empty?)
    fail!("nfcxx: scripts/nfcxx-preprocess.rb planned no command", 2) if argv.empty?
    raise Exit.new(run_cmd(*argv, env: @env))
  end

  # --- the modules block -------------------------------------------------------------------------------------------

  def modules_plan_input
    out = +""
    state_put(out, "root", ROOT)
    state_put(out, "out", v("out"))
    state_put(out, "moddir", v("moddir"))
    state_put(out, "std", v("std"))
    state_put(out, "emit_c", v("emit_c"))
    state_put(out, "compile_only", v("compile_only"))
    state_put(out, "cfiles", a("cfiles"))
    state_put(out, "srcs", a("srcs"))
    state_put(out, "argv", @argv)
    out
  end

  def modules_block
    # the modules block's records: made by the driver for this block only, removed when the block ends (never kept)
    dir = Dir.mktmpdir("modplan.", @owned_root)
    begin
      modules_block_records(dir)
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  def modules_block_records(dir)
    File.binwrite(File.join(dir, "state"), modules_plan_input)
    st = run_cmd(ruby_cmd, script("nfcxx-modules-plan.rb"), File.join(dir, "state"), File.join(dir, "reply"))
    fail!("", st) unless st == 0
    group = nil
    modules = "0"
    modopts = []
    built = ""
    done = false
    File.binread(File.join(dir, "reply")).split("\0", -1).each do |rec|
      next if rec.empty?
      case rec[0]
      when "k" then group = rec[1..]
      when "v"
        case group
        when "modules" then modules = rec[1..]
        when "modopts" then modopts << rec[1..]
        when "built" then built = rec[1..]
        end
      when "z" then done = true
      end
    end
    fail!("nfcxx: scripts/nfcxx-modules-plan.rb stopped before its end (the module block is incomplete)", 1) unless done
    @v["modules"] = modules
    @a["modopts"] = modopts
    raise Exit.new(built.to_i) unless built.empty?
  end

  # --- setup: the rest, the stage, the flags and the backend environment ----------------------------------------------

  def setup_rest
    status, text, message = planned[:rest] || [0, "", ""]
    apply(text) if text
    @v["rest_status"] = status.to_s
    @rest_error = [status.to_i, message.to_s] if status.to_i != 0
    @a["inst_opts"] = @state_values.fetch("inst_opts", [])
    @a["extra"] = @state_values.fetch("extra", [])
    @a["sys_inc"] = @state_values.fetch("sys_inc", [])
    @a["hosted_libs"] = @state_values.fetch("hosted_libs", [])
    @a["gnu_opts"] = @state_values.fetch("gnu_opts", [])
    @v["gnu"] = @state_values.fetch("gnu", v("gnu")).to_s
    @v["target"] = v("target")
    @v["cosmo_root"] = @state_values.fetch("cosmo_root", "").to_s
    span = @state_values.fetch("setup_span_start", nil)
    if span && @state_values["setup_span_stop"]
      NfccxxTrace.span(span.to_i, "host C++ headers", "driver", env: @env, stop: @state_values["setup_span_stop"].to_i) if NfccxxTrace.enabled?(@env)
    end
    if @rest_error
      fail!(@rest_error[1], @rest_error[0])
    end
    @env["EDG_CPFE_DEFAULT_OPTIONS"] = @state_values["EDG_CPFE_DEFAULT_OPTIONS"].to_s if @state_values.key?("EDG_CPFE_DEFAULT_OPTIONS")
    exports_to_env
  end

  def exports_to_env
    (@state_values[:exports] || {}).each { |k, val| @env[k] = val }
  end

  # the -isystem directories of the command line (scripts/ecp-arg.rb --batch), then the forced includes
  def ecp_answers
    dirs = a("sysdirs")
    if dirs.any?
      out, err, st = capture(ruby_cmd, script("ecp-arg.rb"), "--batch", v("moves"), *dirs, env: @env)
      $stderr.write(err)
      group = nil
      done = false
      answers = []
      out.split("\0", -1).each do |rec|
        next if rec.empty?
        case rec[0]
        when "k" then group = rec[1..]
        when "v" then answers << rec[1..] if group == "ecp"
        when "z" then done = true
        end
      end
      fail!("nfcxx: scripts/ecp-arg.rb stopped before its end (the argument answers are incomplete)", 1) unless done
      @a["sys_inc"] = a("sys_inc") + answers.map { |d| "--sys_include=#{d}" }
    end
  end

  def pre_options
    @a["pre_opts"] = a("preinc").flat_map do |f|
      f = abs_path(f) if v("moves") == "1" && File.exist?(f)
      ["--preinclude", f]
    end
  end

  # --- -fsanitize, -fsafe-pointers and the Path B override ----------------------------------------------------------

  def setup_stage
    if planned[:stage]
      status, text = planned[:stage]
      fail!(text, status.to_i) if status.to_i != 0
      apply(text)
    end
    @v["backend"] = @state_values.fetch("backend", v("backend")).to_s
    @a["pb_flags"] = @state_values.fetch("pb_flags", []).dup
  end

  def setup_flags
    apply(planned[:flags]) if planned[:flags]
    @a["pb_flags"] = @state_values.fetch("pb_flags", a("pb_flags")).dup
  end

  def setup_backend_env
    status, text = planned[:backend_env] || [0, ""]
    fail!(text, status.to_i) if status.to_i != 0
    apply(text)
    exports_to_env
    case v("backend")
    when "pathb"
      if flag?("freestanding") && !flag?("pb_fs_host")
        fail!("nfcxx: Path B (--backend=pathb) compiles freestanding programs on x86-64 and aarch64 Linux and arm64 macOS only", 2)
      end
      fail!("nfcxx: QBE not built; run scripts/setup-qbe.sh", 2) unless File.executable?(File.join(ROOT, "build", "qbe", "qbe"))
      @env["NFCXX_CC"] = File.join(ROOT, "scripts", "gcc-cc.rb")
    when "gcc"
      @env["NFCXX_CC"] = File.join(ROOT, "scripts", "gcc-cc.rb")
    else
      fail!("nfcxx: unknown backend '#{v("backend")}'", 2)
    end
  end

  # --- emit-C -----------------------------------------------------------------------------------------------------------

  def emit_c_route
    raise Exit.new(2, "nfcxx: --emit-c does not apply to .c inputs (they skip the front end)\n") unless a("cfiles").empty?
    base = @env["EDG_BASE"].to_s.empty? ? File.join(ROOT, "build", "edg-base") : @env["EDG_BASE"]
    # the front end runs in its base directory (the body's cd "$base"): a missing one is status 1 with a message
    fail!("nfcxx: cd: #{base}: No such file or directory", 1) unless File.directory?(base)
    cpfe = File.join(edg, "cpfe")
    # the front end is started by the shell in the base directory: a missing binary is its error, status 127
    raise Exit.new(127, "No such file or directory - #{cpfe}\n") unless File.executable?(cpfe)
    tmp = temp_dir("tmp")
    posix = `uname -s`.chomp == "Darwin" ? %w[-D_DARWIN_C_SOURCE -U__BLOCKS__] : %w[-D_POSIX_SOURCE]
    eh_tls = File.file?(File.join(edg_base, "eh-tls")) ? ["--nfcxx_eh_thread_local"] : []
    opts = {
      "edg" => edg, "base" => base, "root" => ROOT, "freestanding" => v("freestanding"), "std" => v("std"),
      "dialect" => v("dialect"), "tmp" => tmp, "file" => File.realpath(a("srcs")[0]), "unit" => @env["NFCXX_TRACE_UNIT"].to_s,
      "bash_pid" => Process.pid.to_s,
      "posix_def" => posix.join("\x1f"), "eh_tls" => eh_tls.join("\x1f"), "gnu_opts" => a("gnu_opts").join("\x1f"),
      "diag_opts" => a("diag_opts").join("\x1f"), "sys_inc" => a("sys_inc").join("\x1f"),
      "files" => a("files").join("\x1f")
    }
    begin
      NfcxxEmitC.run(opts, @env)
    rescue NfcxxEmitC::Failed => e
      raise Exit.new(e.status)
    end
    $stdout.write(File.binread(File.join(tmp, "out.c")))
    raise Exit.new(0)
  end

  # --- hosted link: the EH shim, libC, the VLA runtime, the C compiler's options ----------------------------------------

  def shim_and_link_options
    @a["shim"] = []
    @a["rtlib"] = []
    @a["vlart"] = []
    @a["picopts"] = []
    @a["ldopts"] = []
    @v["ncpp_nobj"] = (v("ncpp").to_i + v("nobj").to_i).to_s
    if !flag?("freestanding") && !flag?("compile_only") && !flag?("shared") && v("ncpp_nobj").to_i > 0
      t = trace_start
      s = ""
      pb_tables = v("backend") == "pathb" && File.file?(File.join(File.dirname(@env["PATHB_CPFE"] || File.join(ROOT, "build", "pathb", "cmake", "bin", "cpfe")), "eh-tables"))
      unless !flag?("eh_shim_on") || pb_tables
        s, shim_err, _st = capture(File.join(ROOT, "scripts", "ehshim.rb"))
        $stderr.write(shim_err)
        s = s.chomp
      end
      trace_end(t, "EH shim", "driver")
      @a["shim"] = [s] if !flag?("cosmo") && !s.empty?
      @a["rtlib"] = [libc_a]
      if flag?("asan")
        t = trace_start
        v_out, _e, vst = capture(File.join(ROOT, "scripts", "asan-vla.rb"))
        fail!("nfcxx: cannot build the C++ VLA runtime for -fsanitize=address (scripts/asan-vla.rb)", 2) unless vst == 0
        trace_end(t, "VLA runtime (asan)", "driver")
        @a["vlart"] = [v_out.chomp]
      end
    end
    @a["picopts"] = []
    @a["picopts"] += ["--c_to_obj_option", "-fPIC"] if flag?("pic")
    @a["picopts"] += ["--c_to_obj_option", "-rdynamic"] if flag?("rdynamic")
    @a["picopts"] += ["--c_to_obj_option", "-pthread"] if flag?("pthread")
    @a["picopts"] += a("pie_opts")
    a("asan_c").each { |o| @a["picopts"] += ["--c_to_obj_option", o] }
    if flag?("shared")
      @env["EDG_OBJ_TO_EXEC_DEFAULT_OPTIONS"] = "-shared"
      @a["ldopts"] = ["-shared"]
    end
    @a["ldopts"] << "-rdynamic" if flag?("rdynamic")
    unless v("ld_name").empty?
      unless File.executable?(File.join(ENV.fetch("PATH", "").split(":").map { |d| File.join(d, "ld.#{v("ld_name")}") }.find { |p| File.executable?(p) }.to_s)) &&
             ENV.fetch("PATH", "").split(":").any? { |d| File.executable?(File.join(d, "ld.#{v("ld_name")}")) }
        fail!("nfcxx: NFCXX_LD=#{v("ld_name")}: ld.#{v("ld_name")} is not on PATH", 2)
      end
      @a["ldopts"] << "-fuse-ld=#{v("ld_name")}"
      @a["picopts"] += ["--c_to_obj_option", "-fuse-ld=#{v("ld_name")}"]
    end
  end

  # --- C inputs ----------------------------------------------------------------------------------------------------------

  def gcc_cc
    @env["NFCXX_GCC"].to_s.empty? ? "gcc" : @env["NFCXX_GCC"]
  end

  def cc
    @env["NFCXX_CC"].to_s.empty? ? "cc" : @env["NFCXX_CC"]
  end

  def pathb_cc(args)
    run_cmd(File.join(ROOT, "scripts", "pathb-cc.rb"), *args, env: @env)
  end

  def c_inputs
    @a["cobjs"] = []
    return if a("cfiles").empty?

    ctmp = temp_dir("ctmp")
    @v["ctmp"] = ctmp
    a("cfiles").each_with_index do |c, n|
      o = File.join(ctmp, "#{n}.o")
      t = trace_start
      if v("backend") == "pathb"
        prc = pathb_cc(pb_flags + ["-std=c11", *a("cflags"), c, "-o", o])
        if prc != 0
          fail_fallback(c, prc)
        end
      else
        cmd = [gcc_cc, "-c", "-O2", "-fwrapv", "-fno-strict-aliasing", *a("asan_c"), *flags_pic, *a("cflags"), c, "-o", o]
        st = run_cmd(*cmd, env: @env)
        raise Exit.new(st) unless st == 0
      end
      trace_end(t, "C input: #{c}", "cinput")
      @a["cobjs"] << o
    end
    if flag?("compile_only") && v("ncpp").to_i == 0
      fail!("nfcxx: -c with -o needs exactly one source", 2) unless flag?("outset") == false || a("cobjs").size == 1 || v("outset") != "1"
      a("cobjs").each_with_index do |o, i|
        dst = v("outset") == "1" ? v("out") : File.basename(a("cfiles")[i], ".c") + ".o"
        FileUtils.cp(o, dst)
      end
      raise Exit.new(0)
    end
    if v("ncpp").to_i == 0 && (v("nobj").to_i == 0 || !File.executable?(File.join(edg, "eccp")))
      t = trace_start
      if v("backend") == "pathb"
        cvla = flag?("asan") ? [capture(File.join(ROOT, "scripts", "asan-vla.rb"))[0].chomp] : []
        linkf = []
        a("files").each do |f|
          if f == "-lcudart"
            cub, _e, cst = capture(File.join(ROOT, "scripts", "cuda-cub.rb"))
            linkf << cub.chomp if cst == 0 && !cub.chomp.empty?
          end
          linkf << f
        end
        ldrt, = capture(File.join(ROOT, "scripts", "pathb-ldrt.rb"))
        cxx = RbConfig::CONFIG["host_os"] =~ /darwin/ ? ["-lc++"] : ["-lstdc++"]
        atomic = RbConfig::CONFIG["host_os"] =~ /darwin/ ? [] : ["-latomic"]
        st = run_cmd(cc, *a("asan_c"), *@a["ldopts"], *a("cobjs"), *linkf, *cvla, "-o", v("out"), ldrt.chomp,
                     libc_a, *cxx, "-lm", *atomic, env: @env)
      else
        st = run_cmd(gcc_cc, *a("asan_c"), *@a["ldopts"], *a("cobjs"), *a("files"), "-o", v("out"), env: @env)
      end
      trace_end(t, "link (C only)", "cinput")
      raise Exit.new(st)
    end
  end

  def flags_pic
    flag?("pic") ? ["-fPIC"] : []
  end

  def pb_flags
    flags = a("pb_flags").dup
    flags.unshift("--ir-opt=#{v("ir_opt")}") if flag?("ir_opt_set")
    flags
  end

  # the default backend failed on one source: the program is built again with gcc (the body's fallback_gcc)
  def fail_fallback(source, status)
    raise Exit.new(status) unless flag?("default_backend")
    raise Fallback, "nfcxx: Path B did not build #{source} (status #{status}); building the program with the gcc backend, which compiles with C semantics (-fwrapv -fno-strict-aliasing)"
  end

  # --- the compile cache ---------------------------------------------------------------------------------------------------

  def cache_plan_records
    out = +""
    o = ->(k, x) { out << "o#{k}=#{x}\0" }
    o.("cache-dir", v("cache_dir"))
    o.("cache-log", v("cache_log_file"))
    o.("out", v("out"))
    o.("src", a("srcs")[0].to_s)
    o.("cwd", Dir.pwd)
    vv = ->(k, x) { out << "v#{k}=#{x}\0" }
    vv.("backend", v("backend"))
    vv.("compile_only", v("compile_only"))
    vv.("ncpp", v("ncpp"))
    vv.("outset", v("outset"))
    vv.("nobj", v("nobj"))
    vv.("modules", v("modules"))
    vv.("preprocess", v("preprocess"))
    vv.("stdin_src", v("stdin_src"))
    vv.("depmode", v("depmode"))
    vv.("cfiles_n", a("cfiles").size)
    vv.("cu_n", a("cu_inputs").size)
    vv.("cpp2_n", a("cpp2_inputs").size)
    @argv.each { |x| out << "a#{x}\0" }
    out << "s#{v("std")}\0"
    a("cflags").each { |x| out << "f#{x}\0" }
    a("preinc").each { |x| out << "p#{x}\0" }
    a("sysdirs").each { |x| out << "d#{x}\0" }
    out
  end

  def cache_check
    @cache_entry = nil
    return if v("cache_dir").empty?

    records = Tempfile.new("nfcxx-cache-records")
    records.binmode
    records.write(cache_plan_records)
    records.close
    # the statements go to a file, so the children of the lookup (the remote tier's client) write to the driver's own standard output
    statements = Tempfile.new("nfcxx-cache-statements")
    statements.close
    pid = Process.spawn(@env, ruby_cmd, script("nfcxx-cache-check.rb"), "check", "--remote=#{v("cache_remote")}",
                        "--records=#{records.path}", "--statements=#{statements.path}")
    Process.wait(pid)
    code = $?.exitstatus || 1
    stmts = File.read(statements.path)
    records.unlink
    statements.unlink
    raise Exit.new(0) if code == 10
    fail!("", code) unless code == 0
    apply(stmts) unless stmts.empty?
    @cache_entry = @state_values["cache_entry"]
  end

  def cache_store(out)
    return if @cache_entry.to_s.empty?

    run_cmd(ruby_cmd, script("nfcxx-cache-check.rb"), "store", "--out=#{out}", "--entry=#{@cache_entry}", "--remote=#{v("cache_remote")}")
  end

  # --- the routes ----------------------------------------------------------------------------------------------------------

  def cache_and_routes
    if v("backend") == "pathb" && flag?("compile_only") && v("ncpp").to_i > 0
      cache_route_pathb
    elsif v("backend") == "pathb"
      pathb_link_route
    else
      gcc_route
    end
  end

  # Path B: one object per source, then the stop (the cache lookup first)
  def cache_route_pathb
    if !a("cu_inputs").empty? && @v["cudatmp"] && File.size?(File.join(@v["cudatmp"], "#{File.basename(a("cu_inputs")[0], ".cu")}.dev.kernels.unresolved"))
      fail_fallback(a("cu_inputs")[0], 3)
    end
    cache_check
    a("files").each do |f|
      next if f.start_with?("-I", "-D", "-U", "-") || f.end_with?(".o", ".a", ".so")
      b = File.basename(f)
      dst = b.sub(/\.[^.]*\z/, ".o")
      dst = v("out") if v("outset") == "1"
      prc = pathb_cc(pb_flags + ["-std=c++#{v("std").delete_prefix("--c++")}", *a("cflags"), *pb_pre, *a("cuda_opts"), *a("modopts"), f, "-o", dst])
      fail_fallback(f, prc) unless prc == 0
    end
    cache_store(v("out")) if @cache_entry && a("srcs").size == 1
    raise Exit.new(0)
  end

  def pb_pre
    a("preinc").flat_map { |f| ["-include", f] }
  end

  # Path B links the objects with EDG's runtime (one link line, or the -c objects)
  def pathb_link_route
    ptmp = temp_dir("ptmp")
    pobjs = []
    plink = []
    n = 0
    a("files").each do |f|
      case f
      when /\A-[IDU]/ then nil
      when "-lcudart"
        if flag?("shared") == false
          cub, _e, cst = capture(File.join(ROOT, "scripts", "cuda-cub.rb"))
          plink << cub.chomp if cst == 0 && !cub.chomp.empty?
        end
        plink << f
      when /\A-/, /\.(o|a|so)\z/ then plink << f
      else
        o = File.join(ptmp, "p#{n}.o")
        n += 1
        t = trace_start
        prc = pathb_cc(pb_flags + ["-std=c++#{v("std").delete_prefix("--c++")}", *a("cflags"), *pb_pre, *a("cuda_opts"), f, "-o", o])
        trace_end(t, "Path B: #{f}", "pathb")
        fail_fallback(f, prc) unless prc == 0
        pobjs << o
      end
    end
    t = trace_start
    ldrt, = capture(File.join(ROOT, "scripts", "pathb-ldrt.rb"))
    darwin = RbConfig::CONFIG["host_os"] =~ /darwin/
    cxx = darwin ? "-lc++" : "-lstdc++ -lgcc_s"
    atomic = darwin ? "" : "-latomic"
    cxx = "" if flag?("freestanding") && !darwin
    sprt = []
    if flag?("safeptr") && !flag?("compile_only")
      sprt = [capture(File.join(ROOT, "scripts", "safeptr-rt.rb"))[0].chomp, "-pthread"]
    end
    if flag?("cosmo")
      st = cosmo_link(pobjs, plink, ldrt.chomp, sprt, t)
      raise Exit.new(st)
    end
    st = run_cmd(cc, *a("asan_c"), *@a["ldopts"], *sprt, *@a["cobjs"], *pobjs, *plink, ldrt.chomp, *@a["shim"], *@a["vlart"],
                 libc_a, *cxx.split, "-lpthread", "-lm", *atomic.split, "-o", v("out"), env: @env)
    trace_end(t, "link", "pathb")
    raise Exit.new(st)
  end

  # --cosmo with Path B: cosmocc's x86_64 link (ape.o, crt.o, its linker script and libraries), the ELF fixed up and packaged as APE
  # (bash: the cosmo branch of the Path B link; docs/notes/cosmo.md)
  def cosmo_link(pobjs, plink, ldrt, sprt, t)
    root = @v["cosmo_root"].to_s
    lib = File.join(root, "x86_64-linux-cosmo", "lib")
    libc, = capture(File.join(ROOT, "scripts", "cosmo-libc.rb"))
    dir = temp_dir("ptmp")
    elf = File.join(dir, "cosmo.elf")
    st = run_cmd(File.join(root, "bin", "x86_64-linux-cosmo-g++"), "-nostartfiles", "-nodefaultlibs", "-static",
                 "-Wl,-T,#{lib}/ape.lds", "-L#{lib}", "-o", elf, *sprt, "#{lib}/ape.o", "#{lib}/crt.o", *@a["cobjs"], *pobjs,
                 *plink, ldrt, *@a["shim"], "-L#{libc.chomp}", "-lC", "-lcxx", "-lc", "-lcosmo", "-lm", env: @env)
    return st unless st == 0

    st = run_cmd(File.join(root, "bin", "fixupobj"), elf, env: @env)
    return st unless st == 0

    st = run_cmd(File.join(root, "bin", "apelink"), "-V", "-1", "-l", File.join(root, "bin", "ape-x86_64.elf"), "-o", v("out"), elf,
                 env: @env)
    trace_end(t, "link", "pathb")
    st
  end

  # the gcc backend: the one-step eccp build (compile and link), with its compile cache, the second pass and the depmode
  def gcc_route
    keep_static = ["--c_to_obj_option", "-fkeep-static-functions"]
    keep_static = [] if clang_cc?
    eh_unwind = []
    eh_unwind << "--nfcxx_eh_thread_local" if File.exist?(File.join(edg_base, "eh-tls"))
    if flag?("eh_unwind_on") && v("backend") == "gcc"
      eh_unwind += ["--nfcxx_eh_unwind", "--c_to_obj_option", "-fexceptions", "--c_to_obj_option", "-include",
                    "--c_to_obj_option", File.join(ROOT, "lib", "ehshim", "nfcxx_eh_unwind.h")]
    end
    if flag?("compile_only") && v("outset") == "0" && v("ncpp").to_i > 0
      fail!("nfcxx: -c with several sources needs -o (one object is made per call)", 2) unless a("srcs").size == 1
      v_out = File.basename(a("srcs")[0]).sub(/\.[^.]*\z/, ".o")
      set("out", v_out)
    end
    moves = flag?("compile_only") ? "0" : "1"
    set("moves", moves)
    eccp_dir = nil
    eccp_owned = false
    if moves == "1"
      eccp_dir = temp_dir("eccp")
    end
    eccp_bin = File.join(edg, "eccp")
    @a["keep_static"] = keep_static
    @a["eh_unwind"] = eh_unwind
    @a["cobjs"] = a("cobjs")
    @a["eflist"] = []
    @a["userinc"] = []
    @a["modopts"] = a("modopts")
    @a["diag_opts"] = a("diag_opts")
    @a["inst_opts"] = a("inst_opts")
    link_args
    eccp_out = v("out")
    eccp_plan_run(eccp_bin, eccp_out, eccp_dir, moves)
    FileUtils.rm_rf(eccp_dir) if eccp_dir && !flag?("keep_intermediates")
    raise Exit.new(0)
  end

  def clang_cc?
    out, _e, _s = capture(gcc_cc, "--version")
    out.lines.first.to_s.downcase.include?("clang")
  end

  # the link arguments: the files of the link are planned by scripts/nfcxx-link-args (through the eccp planner's records)
  def link_args
    @a["eflist"] = @a["eflist"]
  end

  # the records of the eccp command line (scripts/nfcxx-eccp-plan.rb reads them: the groups of the body's eccp_plan_input)
  def eccp_plan_input(eccp_bin, eccp_out, moves)
    out = +""
    state_put(out, "eccp", eccp_bin)
    state_put(out, "std", v("std"))
    state_put(out, "dialect", v("dialect"))
    state_put(out, "out", eccp_out)
    %w[extra inst_opts modopts diag_opts].each { |n| state_put(out, n, a(n)) }
    state_put(out, "root", ROOT)
    state_put(out, "files", a("files"))
    state_put(out, "compile_only", v("compile_only"))
    %w[sys_inc hosted_libs keep_static eh_unwind picopts cobjs pre_opts cuda_opts shim vlart rtlib].each { |n| state_put(out, n, a(n)) }
    state_put(out, "moves", moves)
    out
  end

  def eccp_plan_run(eccp_bin, eccp_out, eccp_dir, moves)
    recs = eccp_plan_input(eccp_bin, eccp_out, moves)
    out, err, st = capture(ruby_cmd, script("nfcxx-eccp-plan.rb"), eccp_dir.to_s, flag?("keep_intermediates") ? "1" : "0",
                           flag?("shared") ? "1" : "0", stdin: recs, env: @env)
    $stderr.write(err)
    raise Exit.new(st) unless st == 0
    argv = []
    envs = []
    cd = nil
    out.split("\0", -1).each do |rec|
      case rec[0]
      when "a" then argv << rec[1..]
      when "e" then envs << rec[1..]
      when "d" then cd = rec[1..]
      end
    end
    compile_clean(eccp_out) if flag?("compile_only") && v("ncpp").to_i > 0
    run_cmd(ruby_cmd, script("nfcxx-link.rb"), "records-rm", "--", *a("files"), env: @env)
    cache_check
    envs_hash = envs.to_h { |e| e.split("=", 2) }
    st = run_cmd(ruby_cmd, script("nfcxx-eccp-run.rb"), *(cd ? ["--cd=#{cd}"] : []), *envs.map { |e| "--env=#{e}" }, "--", *argv,
                 env: @env)
    raise Exit.new(st) unless st == 0
    run_cmd(ruby_cmd, script("nfcxx-link.rb"), "records-rm", "--", *a("files"), env: @env)
    second_pass(eccp_out)
    cache_store(eccp_out)
    depmode(eccp_out)
  end

  def compile_clean(out)
    run_cmd(ruby_cmd, script("nfcxx-link.rb"), "compile-clean", out, *a("srcs"), env: @env)
  end

  def second_pass(out)
    return unless a("cu_inputs").size == 1

    stmts, _e, st = capture(ruby_cmd, script("nfcxx-second-pass.rb"), "plan", out, @v["cudatmp"].to_s, a("cu_inputs").size.to_s,
                            a("cu_inputs")[0].to_s, v("preprocess"), @env["NFCXX_CUDA_HOST_SYMBOLS"].to_s, *@argv, env: @env)
    return unless st == 0
    apply(stmts)
    return unless @state_values["sp_run"].to_s == "1"

    hsyms = @state_values["hsyms"].to_s
    args2 = @state_values.fetch("args2", [])
    env2 = @env.merge("NFCXX_CUDA_HOST_SYMBOLS" => hsyms, "NFCXX_CACHE" => "", "NFCXX_CACHE_REMOTE" => "")
    st2 = run_cmd(RbConfig.ruby, File.join(ROOT, "scripts", "nfcxx.rb"), *args2, env: env2)
    raise Exit.new(st2) unless st2 == 0
  end

  def depmode(out)
    return if v("depmode").empty?

    words = []
    recs, _e, st = capture(ruby_cmd, script("nfcxx-depmode.rb"), "plan", "depmode=#{v("depmode")}", "out=#{out}",
                           "std=#{v("std")}", "cxx=#{@env["NFCXX_CXX"]}", "dfile=#{v("dfile")}", "dtarget=#{v("dtarget")}",
                           "depphony=#{v("depphony")}", *a("cflags").map { |x| "cflags=#{x}" },
                           *a("sysdirs").map { |x| "sysdirs=#{x}" }, *a("srcs").map { |x| "srcs=#{x}" }, env: @env)
    recs.split("\0", -1).each { |w| words << w unless w.empty? }
    raise Exit.new(1) if words.empty?
    st = run_cmd(*words, env: @env)
    raise Exit.new(st) unless st == 0
  end
end
