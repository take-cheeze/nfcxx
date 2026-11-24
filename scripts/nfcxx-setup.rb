#!/usr/bin/env ruby
# The setup stage in-process (stage B3 of docs/notes/driver-body-port.md, docs/notes/driver-setup-stage.md). Each step calls the
# planner's own function, the one its command line calls, with the same options, and returns the text that command prints. So
# a step's output is the planner's, byte for byte, and tests/driver-setup-b3/run.sh checks that against the command line.
# Refusals raise Refusal with the planner's message and status (the bash prints the message and exits with the status).
#
# The bash variables keep their names (docs/notes/driver-setup-stage.md, question 2): the options are a hash keyed by them.
# Sequencing (which step's answer feeds which) is not done here yet; that is the next slice. This file is the calls.
#
#   ruby scripts/nfcxx-setup.rb STEP KEY=VALUE...    (the steps: see STEPS)

require "shellwords"
require "stringio"

root = File.expand_path("..", __dir__)
%w[nfcxx-backend nfcxx-asan-c nfcxx-instantiate nfcxx-cosmo-setup nfcxx-freestanding-setup
   nfcxx-host-cflags nfcxx-gnu-opts nfcxx-k1om-env nfcxx-target nfcxx-backend-env nfcxx-sanitize trace ecp-arg].each do |f|
  require File.join(root, "scripts", f)
end

module NfcxxSetup
  module_function

  # a refusal of one step: the message (for stderr) and the status the driver exits with
  class Refusal < StandardError
    attr_reader :status
    def initialize(message, status = 2)
      super(message)
      @status = status
    end
  end

  STEPS = %w[default asan instantiate cosmo freestanding host_cflags gnu_opts k1om target backend_env].freeze

  # the options of a command line: KEY=VALUE words, as the planners' own command lines read them
  def options(words)
    words.to_h { |kv| kv.split("=", 2) }
  end

  # the text Kernel#puts would write for OBJ (a string, or an array of lines, one per element)
  def text_of(obj)
    io = StringIO.new
    io.puts(obj)
    io.string
  end

  # the values of the default step's statements (backend, default_backend, pb_fs_host), unquoted as the shell reads them
  def default_values(text)
    words = Shellwords.split(text).to_h { |kv| kv.split("=", 2) }
    words.values_at("backend", "default_backend", "pb_fs_host")
  end

  # the words of a bash array the planners print, as "NAME=(...)" (mode "=") or "NAME+=(...)" (mode "+="); [mode, words]
  def array_words(text, name)
    text.each_line do |line|
      m = line.match(/\A#{Regexp.escape(name)}(\+?)=\((.*)\)\s*\z/)
      return [m[1] == "+" ? "+=" : "=", Shellwords.split(m[2])] if m
    end
    ["=", []]
  end

  # run STEP with the options (a hash) and the environment; returns the text the step's command line prints
  def run(step, opts, env = ENV)
    case step
    when "default"
      backend, default_backend, pb_fs = NfcxxBackend.default_choice(opts)
      "backend=#{Shellwords.escape(backend)} default_backend=#{default_backend} pb_fs_host=#{pb_fs}\n"
    when "asan"
      asan = opts.fetch("asan", "")
      backend = opts.fetch("backend", "")
      asanopts = opts.fetch("asanopts", "").split("\x1f", -1).reject(&:empty?)
      begin
        asan_c, asanopts_out = NfcxxAsanC.plan(asan: asan, backend: backend, asanopts: asanopts)
      rescue NfcxxAsanC::Refusal => e
        raise Refusal.new(e.message, e.status)
      end
      if asan == "1"
        "asan_c=(#{asan_c.map { |w| Shellwords.escape(w) }.join(" ")})\n"
      else
        "asanopts=(#{asanopts_out.map { |w| Shellwords.escape(w) }.join(" ")})\n"
      end
    when "instantiate"
      begin
        text_of(NfcxxInstantiate.plan(opts.fetch("instantiate", ""), opts.fetch("sys", "")))
      rescue ArgumentError => e
        raise Refusal.new(e.message, 2)
      end
    when "cosmo"
      text_of(NfcxxCosmo.setup(opts, env))
    when "freestanding"
      text_of(NfcxxFreestanding.plan(opts))
    when "host_cflags"
      text_of(NfcxxHostCflags.plan(opts))
    when "gnu_opts"
      text_of(NfcxxGnuOpts.plan(opts))
    when "k1om"
      out = NfcxxK1om.plan(opts, env)
      out.empty? ? "" : out + "\n"
    when "target"
      out = NfcxxTarget.plan(opts, env)
      out.empty? ? "" : out + "\n"
    when "backend_env"
      text_of(NfcxxBackendEnv.plan(opts))
    else
      raise ArgumentError, "nfcxx-setup: unknown step #{step.inspect} (steps: #{STEPS.join(" ")})"
    end
  rescue NfcxxBackend::Refusal, NfcxxCosmo::Refusal, NfcxxK1om::Refusal, NfcxxTarget::Refusal, NfcxxBackendEnv::Refusal => e
    raise Refusal.new(e.message, e.respond_to?(:status) ? e.status : 2)
  end
end

module NfcxxSetup
  module_function

  # The steps in the order ./nfcxx runs them (line numbers on main): default 427, asan 435, instantiate 460, cosmo 465 (only
  # with cosmo=1), freestanding 472, host cflags 484, gnu opts 485, k1om 494, target 498, the Path B override 539, backend env
  # 553. The override runs after the planners above it, so they see the backend the default chose (docs/notes/driver-setup-stage.md).
  # Not sequenced yet: the system include list (ecp_args, sys_inc). Returns { steps: [[name, text, backend_seen]], state: {...} }.
  def sequence(opts, env = ENV)
    state = opts.dup
    flag = ->(k) { state.fetch(k, "0") == "1" }
    steps = []
    record = lambda do |name, text|
      steps << [name, text, state["backend"].to_s]
    end

    # 1. the default backend: sets backend, default_backend and pb_fs_host
    text = run("default", state, env)
    record.("default", text)
    state["backend"], state["default_backend"], state["pb_fs_host"] = default_values(text)

    # 2. the sanitizer, which reads the backend the default chose
    record.("asan", run("asan", state, env))

    # 3. instantiation
    record.("instantiate", run("instantiate", state, env))

    # 4. cosmo, only with cosmo=1; it reads the command line's gnu, which the freestanding step sets after it
    record.("cosmo", run("cosmo", state, env)) if flag.("cosmo")

    # 5. the freestanding or hosted headers; sets gnu
    text = run("freestanding", state, env)
    record.("freestanding", text)
    if (m = text.match(/^gnu=(\S+)/))
      state["gnu"] = m[1]
    end

    # 6. host cflags, which read the backend the default chose
    record.("host_cflags", run("host_cflags", state, env))

    # 7. the GNU version option, which reads the gnu the freestanding step set; its gnu_opts array is the state's
    text = run("gnu_opts", state, env)
    record.("gnu_opts", text)
    state["gnu_opts"] = array_words(text, "gnu_opts")[1].join("\x1f")

    # 8. k1om, which reads the backend the default chose
    record.("k1om", run("k1om", state, env))

    # 9. target: reads the gnu_opts array (joined by ASCII 31, as the bash passes it) and appends its own words to it
    text = run("target", state, env)
    record.("target", text)
    mode, words = array_words(text, "gnu_opts")
    state["gnu_opts"] = [state.fetch("gnu_opts", ""), *words].reject(&:empty?).join("\x1f") if mode == "+="

    # 10. the Path B override (bash line 539): after the planners above, before the backend environment
    if flag.("path_b")
      state["backend"] = "pathb"
      state["default_backend"] = "0"
    end

    # 11. the backend environment, which reads the overridden backend
    record.("backend_env", run("backend_env", state, env))

    { steps: steps, state: state }
  end
end

module NfcxxSetup
  module_function

  # the span a bash trace_end writes (trace.sh): into the pending file when the driver batches its spans, else directly
  def trace_span(start, name, category, env, pid)
    return unless NfccxxTrace.enabled?(env)

    pending = env["NFCXX_TRACE_PENDING"].to_s
    if pending.empty?
      NfccxxTrace.span(start, name, category, pid: pid, env: env)
    else
      # trace.sh's record: start, stop, name, category, pid, unit, each followed by NUL
      fields = [start, NfccxxTrace.now_us, name, category, pid, env["NFCXX_TRACE_UNIT"].to_s]
      File.open(pending, "ab") { |f| f.write(fields.map { |v| "#{v}\0" }.join) }
    end
  end

  # the host C++ headers step, with the span the bash wraps around it when the build is hosted (bash: trace_start, the
  # freestanding eval, trace_end "host C++ headers" driver). freestanding=1 has no span.
  def host_headers(opts, env, bash_pid)
    if opts.fetch("freestanding", "0") == "1"
      return text_of(NfcxxFreestanding.plan(opts))
    end

    start = NfccxxTrace.enabled?(env) ? NfccxxTrace.now_us : 0
    text = text_of(NfcxxFreestanding.plan(opts))
    trace_span(start, "host C++ headers", "driver", env, bash_pid) if NfccxxTrace.enabled?(env)
    text
  end

  # the -isystem directories as the bash's ecp_args builds sys_inc: each answer (the eccp form when moves is 1) as
  # --sys_include=DIR, in order; no directories, no words
  def sys_include(moves, dirs)
    answers = dirs.map { |arg| EcpArg.substitution(moves == "1" ? EcpArg.ecp_arg(arg) : arg) }
    answers.map { |d| "--sys_include=#{d}" }
  end
end

module NfcxxSetup
  module_function

  # The planners that the bash ran before the sanitizer, in the order it ran them: the default backend (which sets backend,
  # default_backend and pb_fs_host), the sanitizer's options, instantiation, cosmo (only with cosmo=1), the freestanding or
  # hosted headers (with the host C++ headers span), the host cflags, the GNU options, k1om and the target. Their statements
  # are returned as one text for the driver to eval. The sanitizer, -fsafe-pointers, the Path B override and the backend
  # environment stay in the driver, after this text, because they set backend (docs/notes/driver-setup-stage.md).
  def planners_text(opts, env, bash_pid)
    state = opts.dup
    flag = ->(k) { state.fetch(k, "0") == "1" }
    out = +""
    out << run("default", state, env)
    state["backend"], state["default_backend"], state["pb_fs_host"] = default_values(out)
    out << run("asan", state, env)
    out << run("instantiate", state, env)
    out << run("cosmo", state, env) if flag.("cosmo")
    text = host_headers(state, env, bash_pid)
    out << text
    if (m = text.match(/^gnu=(\S+)/))
      state["gnu"] = m[1]
    end
    out << run("host_cflags", state, env)
    gnu_text = run("gnu_opts", state, env)
    out << gnu_text
    state["gnu_opts"] = array_words(gnu_text, "gnu_opts")[1].join("\x1f")
    out << run("k1om", state, env)
    target_text = run("target", state, env)
    out << target_text
    out
  end
end

module NfcxxSetup
  module_function

  # The backend stage after the planners and the emit-C path (bash: the sanitizer, -fsafe-pointers and the Path B override):
  # the refusals first, in the bash's order, then the statements that set pb_flags and backend. The sanitizer's check is the
  # one scripts/nfcxx-sanitize.rb makes (its message and status 2). The body evals the text, where the bash ran them.
  def stage_text(opts)
    out = +""
    sanitize = opts.fetch("sanitize", "")
    freestanding = opts.fetch("freestanding", "0")
    unless sanitize.empty?
      msg = send(:check, sanitize, freestanding)
      raise Refusal.new(msg, 2) if msg
      out << "pb_flags+=(#{Shellwords.escape("--sanitize=#{sanitize}")})\n"
      out << "backend=pathb\n"
    end
    if opts.fetch("safeptr", "0") == "1"
      raise Refusal.new("nfcxx: -fsafe-pointers needs Path B, which compiles hosted programs only", 2) if freestanding != "0"
      raise Refusal.new("nfcxx: -fsafe-pointers and -fsanitize=address both replace malloc; use one", 2) if opts.fetch("asan", "0") != "0"
      out << "pb_flags+=(--safe-pointers)\n"
      out << "backend=pathb\n"
    end
    out << "backend=pathb default_backend=0\n" if opts.fetch("path_b", "0") == "1"
    out
  end
end

module NfcxxSetup
  module_function

  # The arrays the bash passes, joined by ASCII 31 (an empty array is the empty string).
  def split_list(text)
    text.to_s.empty? ? [] : text.split("\x1f", -1)
  end

  # The compile cache's options (bash: cache_check's key arguments): the cache and its log, the output, the source, the
  # working directory, the variables the key depends on, the command line without the cache's own options (--arg=), and the
  # host preprocessor's command line (--cpp=): -std, the cflags, the forced includes and the system directories. Printed
  # NUL-terminated, one option a word, so the driver reads them back with read -d ''.
  def cache_opts(h)
    argv = split_list(h["argv"]).reject { |a| a.start_with?("--cache=", "--cache-log=", "--time-log=", "--trace=") }
    pre = split_list(h["preinc"]).flat_map { |f| ["-include", f] }
    cpp = ["-std=#{h.fetch("std", "").delete_prefix("--")}", *split_list(h["cflags"]), *pre,
           *split_list(h["sysdirs"]).map { |d| "-isystem#{d}" }]
    opts = [
      "--cache-dir=#{h.fetch("cache_dir", "")}", "--cache-log=#{h.fetch("cache_log", "")}",
      "--out=#{h.fetch("out", "")}", "--src=#{h.fetch("src", "")}", "--cwd=#{h.fetch("cwd", "")}",
      "--var=backend=#{h.fetch("backend", "")}", "--var=compile_only=#{h.fetch("compile_only", "")}",
      "--var=ncpp=#{h.fetch("ncpp", "")}", "--var=outset=#{h.fetch("outset", "")}",
      "--var=nobj=#{h.fetch("nobj", "")}", "--var=modules=#{h.fetch("modules", "")}",
      "--var=preprocess=#{h.fetch("preprocess", "")}", "--var=stdin_src=#{h.fetch("stdin_src", "")}",
      "--var=depmode=#{h.fetch("depmode", "")}", "--var=cfiles_n=#{h.fetch("cfiles_n", "")}",
      "--var=cu_n=#{h.fetch("cu_n", "")}", "--var=cpp2_n=#{h.fetch("cpp2_n", "")}",
      *argv.map { |a| "--arg=#{a}" }, *cpp.map { |c| "--cpp=#{c}" }
    ]
    opts.map { |w| w + "\0" }.join
  end

  # The Path B option statements after the override (bash: the pb_flags lines, from the --ir-opt line to the --freestanding line).
  # Every condition is the bash's. The backend environment is a step of its own (run "backend_env"), which the body evals after
  # these. No statement here refuses.
  def flags_text(opts, env = ENV)
    out = +""
    flag = ->(k) { opts.fetch(k, "0") == "1" }
    backend = opts.fetch("backend", "")
    freestanding = opts.fetch("freestanding", "0")
    pb = ->(*words) { out << "pb_flags+=(#{words.map { |w| Shellwords.escape(w) }.join(" ")})\n" }
    pb.("--ir-opt=#{opts["ir_opt"]}") if flag.("ir_opt_set")
    pb.("--asan") if flag.("asan") && backend == "pathb"
    pb.("--pic") if flag.("pic")
    pb.("--vectorize-assoc") if flag.("vec_assoc") && backend == "pathb"
    diag = opts.fetch("diag_opts", "").split("\x1f", -1).reject(&:empty?)
    pb.(*diag) unless diag.empty?
    pb.("--dialect=clang") if backend == "pathb" && opts.fetch("dialect", "") == "clang" && !opts.fetch("dialect_asked", "").empty?
    gnu_user = opts.fetch("gnu_user", "")
    pb.("--gnu-version=#{gnu_user}") if backend == "pathb" && freestanding == "0" && !gnu_user.empty?
    if backend == "pathb" && freestanding != "0"
      pb.("--freestanding", "--eh-runtime", "--gnu-version=#{opts["gnu"]}", "-I#{opts["root"]}/lib")
    end
    out
  end

  # The trace unit's statements (bash: trace_unit=${srcs[0]-$out}; export NFCXX_TRACE_UNIT=$trace_unit): the first source, else the
  # output. The body evals them where the bash assigned it, before trace_begin.
  def trace_unit_text(srcs, out)
    unit = srcs.empty? ? out : srcs.first
    word = Shellwords.escape(unit)
    "trace_unit=#{word}; export NFCXX_TRACE_UNIT=#{word}\n"
  end
end

module NfcxxSetup
  module_function

  # the NAME=VALUE statements of a planner's text, as the value the shell reads (the last one of each NAME in NAMES)
  def assigned(text, names)
    values = {}
    text.each_line do |raw|
      line = raw.chomp # a line keeps its newline, which the anchored match below must not see
      m = line.match(/\A(#{names.map { |n| Regexp.escape(n) }.join("|")})=(.*)\z/) or next
      values[m[1]] = Shellwords.split(m[2]).first.to_s
    end
    values
  end

  # the NAME=VALUE words of a planner's export lines, as the value the shell exports (a value with a shell expansion is not one:
  # the target's EDG_CPFE_DEFAULT_OPTIONS line is left to the body)
  def exports_of(text)
    vars = {}
    text.each_line do |line|
      next unless line.start_with?("export ")

      Shellwords.split(line.delete_prefix("export ")).each do |w|
        name, value = w.split("=", 2)
        vars[name] = value if value && !value.include?("$") && name.match?(/\A\w+\z/)
      end
    end
    vars
  end

  # The setup's rest, in the bash's order (the body's block from the template instantiation to the target, and the export
  # of EDG_CPFE_DEFAULT_OPTIONS): instantiation, --cosmo, the freestanding or hosted headers, the host cflags, the GNU options,
  # --target=linux_k1om, --target. The hosted headers' probe is timed here and its span is left to the body (setup_span_start
  # and setup_span_stop are its statements), so a span is recorded only by a body that reaches the setup.
  # Returns [text, status, message, state]: text holds the statements up to the first refusal, which the body evals before it prints
  # the message and exits with the status (status 0 and "" when nothing is refused); state is the options after those statements
  # (backend, gnu and the gnu_opts array). The bash variables are the names.
  def rest(opts, env = ENV)
    state = opts.dup
    flag = ->(k) { state.fetch(k, "0") == "1" }
    out = +""
    # the environment the later steps see: the variables a step exports (the bash exports them when it runs), e.g. the
    # --cosmo's NFCXX_SYS_INCLUDES, which the host's include probe reads
    penv = env.to_h
    # the statements of a planner step: its text is kept, and the variables the next steps read are taken from it
    step = lambda do |name, text|
      out << text
      state.merge!(assigned(text, %w[backend gnu])) if %w[cosmo freestanding k1om].include?(name)
      penv = penv.merge(exports_of(text)) if %w[cosmo k1om].include?(name)
    end
    begin
      step.("instantiate", run("instantiate", state, penv))
      step.("cosmo", run("cosmo", state, penv)) if flag.("cosmo")

      if state.fetch("freestanding", "0") == "1"
        step.("freestanding", NfcxxFreestanding.plan(state, penv).map { |l| "#{l}\n" }.join)
      else
        start = NfccxxTrace.now_us
        includes = NfcxxFreestanding.includes(state, penv).map { |l| "#{l}\n" }.join
        stop = NfccxxTrace.now_us
        out << "setup_span_start=#{start} setup_span_stop=#{stop}\n"
        out << includes
        step.("freestanding", NfcxxFreestanding.gnu_line(state, penv).map { |l| "#{l}\n" }.join)
      end

      step.("host_cflags", run("host_cflags", state, penv))

      gnu_text = run("gnu_opts", state, penv)
      out << gnu_text
      state["gnu_opts"] = array_words(gnu_text, "gnu_opts")[1].join("\x1f")

      step.("k1om", run("k1om", state, penv))

      target_text = run("target", state, penv)
      out << target_text
      mode, words = array_words(target_text, "gnu_opts")
      state["gnu_opts"] = [state.fetch("gnu_opts", ""), *words].reject(&:empty?).join("\x1f") if mode == "+="
    rescue Refusal => e
      return [out, e.status, "#{e.message}\n", state]
    end
    [out, 0, "", state]
  end
end

if $PROGRAM_NAME == __FILE__
  if ARGV.first == "host-headers"
    opts = NfcxxSetup.options(ARGV.drop(1))
    $stdout.write(NfcxxSetup.host_headers(opts, ENV, opts.fetch("bash_pid", "0")))
    exit 0
  end
  if ARGV.first == "setup"
    opts = NfcxxSetup.options(ARGV.drop(1))
    begin
      $stdout.write(NfcxxSetup.planners_text(opts, ENV, opts.fetch("bash_pid", "0")))
    rescue NfcxxSetup::Refusal => e
      warn e.message
      exit e.status
    end
    exit 0
  end
  if ARGV.first == "stage"
    opts = NfcxxSetup.options(ARGV.drop(1))
    begin
      $stdout.write(NfcxxSetup.stage_text(opts))
    rescue NfcxxSetup::Refusal => e
      warn e.message
      exit e.status
    end
    exit 0
  end
  if ARGV.first == "rest"
    opts = NfcxxSetup.options(ARGV.drop(1))
    text, status, message = NfcxxSetup.rest(opts, ENV)
    $stdout.write(text)
    $stderr.write(message)
    exit status
  end
  if ARGV.first == "cache-opts"
    $stdout.binmode.write(NfcxxSetup.cache_opts(NfcxxSetup.options(ARGV.drop(1))))
    exit 0
  end
  if ARGV.first == "flags"
    opts = NfcxxSetup.options(ARGV.drop(1))
    begin
      $stdout.write(NfcxxSetup.flags_text(opts, ENV))
    rescue NfcxxSetup::Refusal, NfcxxBackendEnv::Refusal => e
      warn e.message
      exit(e.respond_to?(:status) ? e.status : 2)
    end
    exit 0
  end
  if ARGV.first == "sys-include"
    _, moves, *dirs = ARGV
    dirs = dirs.drop(1) if dirs.first == "--"
    $stdout.binmode.write(*NfcxxSetup.sys_include(moves, dirs).map { |w| w + "\0" })
    exit 0
  end
  step, *rest = ARGV
  abort "nfcxx-setup: STEP KEY=VALUE... (steps: #{NfcxxSetup::STEPS.join(" ")})" unless step
  begin
    print NfcxxSetup.run(step, NfcxxSetup.options(rest), ENV)
  rescue NfcxxSetup::Refusal => e
    warn e.message
    exit e.status
  end
end
