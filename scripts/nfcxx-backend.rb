#!/usr/bin/env ruby
# The backend decision of nfcxx's setup (stage B3 of docs/notes/driver-body-port.md): which compiler builds the program, and
# whether that was the default choice (a file Path B does not build is then built again with gcc). Ported from the bash in
# nfcxx (default_backend, pb_fs_host, the NFCXX_PATH=b override and the case on $backend). Checked against the bash by
# tests/driver-backend/run.sh (tests/driver-backend/oracle.sh holds the bash verbatim).
#
#   ruby scripts/nfcxx-backend.rb decide KEY=VALUE...
#   ruby scripts/nfcxx-backend.rb default KEY=VALUE...
#       the default only (the bash block that runs when no backend was named): backend is kept when given, else gcc or pathb;
#       no refusals and no NFCXX_PATH=b handling (nfcxx does those where they always were). nfcxx evals the output.
#
# Inputs (each optional; the bash defaults are used when absent):
#   backend=      the explicit --backend= value or NFCXX_BACKEND ("" when none)
#   backend_explicit=0|1, path_b=0|1 (NFCXX_PATH=b or --backend=pathb), freestanding=0|1, cosmo=0|1, emit_c=0|1,
#   target=       the --target= value ("" when none), preprocess=0|1, depmode=  ("" when none), shared=0|1,
#   host=         the output of `uname -s` and `uname -m` joined by a space, e.g. "Linux x86_64" (the host of the driver)
#
# Output on standard output, one line: "backend=NAME default_backend=0|1 pb_fs_host=0|1". Exit status 0.
# A request the bash refuses prints its message on standard error and exits 2 (the same messages as nfcxx).

module NfcxxBackend
  module_function

  # pb_fs_host: Path B compiles freestanding programs on x86-64 and aarch64 Linux and arm64 macOS
  def pb_fs_host?(system_name, machine)
    case system_name
    when "Linux" then %w[x86_64 aarch64 arm64].include?(machine)
    when "Darwin" then machine == "arm64"
    else false
    end
  end

  # the decision: returns [backend, default_backend, pb_fs_host], or raises Refusal with the message and status
  class Refusal < StandardError
    attr_reader :status
    def initialize(message, status = 2)
      super(message)
      @status = status
    end
  end

  # the default block alone: no refusals, no override (see the usage above)
  def default_choice(opts)
    flag = ->(k) { opts.fetch(k, "0") == "1" }
    system_name, machine = opts.fetch("host", "Linux x86_64").split(" ", 2)
    pb_fs = pb_fs_host?(system_name, machine) ? 1 : 0
    backend = opts.fetch("backend", "")
    default_backend = 0
    if backend.empty?
      backend = "gcc"
      fs_ok = !flag.("freestanding") || pb_fs == 1
      if !flag.("backend_explicit") && fs_ok && !flag.("cosmo") && !flag.("emit_c") &&
         opts.fetch("target", "").empty? && !flag.("preprocess") && opts.fetch("depmode", "").empty? && !flag.("shared")
        backend = "pathb"
        default_backend = 1
      end
    end
    [backend, default_backend, pb_fs]
  end

  def decide(opts)
    flag = ->(k) { opts.fetch(k, "0") == "1" }
    backend = opts.fetch("backend", "")
    backend_explicit = flag.("backend_explicit")
    path_b = flag.("path_b")
    freestanding = flag.("freestanding")
    cosmo = flag.("cosmo")
    emit_c = flag.("emit_c")
    target = opts.fetch("target", "")
    preprocess = flag.("preprocess")
    depmode = opts.fetch("depmode", "")
    shared = flag.("shared")
    system_name, machine = opts.fetch("host", "Linux x86_64").split(" ", 2)
    pb_fs = pb_fs_host?(system_name, machine) ? 1 : 0
    default_backend = 0

    # the default (bash: "if [ -z "$backend" ]"): gcc, or Path B for a request only Path B takes
    if backend.empty?
      backend = "gcc"
      fs_ok = !freestanding || pb_fs == 1
      if !backend_explicit && fs_ok && !cosmo && !emit_c && target.empty? && !preprocess && depmode.empty? && !shared
        backend = "pathb"
        default_backend = 1
      end
    end

    # --backend=pathb, or NFCXX_PATH=b: asked for by name, so no fallback (bash: "[ $path_b = 0 ] || {...}")
    if path_b
      backend = "pathb"
      default_backend = 0
    end

    # bash: "case $backend in pathb) ...; gcc) ...; *) unknown"
    case backend
    when "pathb"
      if freestanding && pb_fs != 1
        raise Refusal, "nfcxx: Path B (--backend=pathb) compiles freestanding programs on x86-64 and aarch64 Linux and arm64 macOS only"
      end
    when "gcc"
    else
      raise Refusal, "nfcxx: unknown backend '#{backend}'"
    end

    [backend, default_backend, pb_fs]
  end
end

if $PROGRAM_NAME == __FILE__
  cmd, *rest = ARGV
  opts = rest.to_h { |kv| kv.split("=", 2) }
  case cmd
  when "decide"
    begin
      backend, default_backend, pb_fs = NfcxxBackend.decide(opts)
      puts "backend=#{backend} default_backend=#{default_backend} pb_fs_host=#{pb_fs}"
    rescue NfcxxBackend::Refusal => e
      warn e.message
      exit e.status
    end
  when "default"
    backend, default_backend, pb_fs = NfcxxBackend.default_choice(opts)
    puts "backend=#{backend} default_backend=#{default_backend} pb_fs_host=#{pb_fs}"
  else
    abort "nfcxx-backend: decide or default KEY=VALUE... (got #{cmd.inspect})"
  end
end
