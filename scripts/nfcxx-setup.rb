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
   nfcxx-host-cflags nfcxx-gnu-opts nfcxx-k1om-env nfcxx-target nfcxx-backend-env].each do |f|
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
      "backend=#{backend} default_backend=#{default_backend} pb_fs_host=#{pb_fs}\n"
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
    state["backend"], state["default_backend"], state["pb_fs_host"] = text.scan(/(\S+)=(\S+)/).map(&:last)

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

if $PROGRAM_NAME == __FILE__
  step, *rest = ARGV
  abort "nfcxx-setup: STEP KEY=VALUE... (steps: #{NfcxxSetup::STEPS.join(" ")})" unless step
  begin
    print NfcxxSetup.run(step, NfcxxSetup.options(rest), ENV)
  rescue NfcxxSetup::Refusal => e
    warn e.message
    exit e.status
  end
end
