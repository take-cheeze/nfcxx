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
