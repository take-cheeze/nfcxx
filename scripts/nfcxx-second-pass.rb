#!/usr/bin/env ruby
# The second pass's decision (restructure step 2 / B7 of docs/notes/driver-body-port.md), ported from the bash loop in nfcxx: the
# second pass runs when a kernel the device side left unresolved appears in the host symbols as NAME< (after the
# _INTERNAL_..:: scopes are removed). The driver keeps nm and the re-run; this decides.
#
#   ruby scripts/nfcxx-second-pass.rb host-symbols OBJ DEST
#       writes the host symbols of OBJ to DEST: nm -C, with the _INTERNAL_..:: scopes removed (the bash's nm | sed).
#   ruby scripts/nfcxx-second-pass.rb found HOSTSYMS UNRESOLVED
#       prints 1 when some non-empty line of UNRESOLVED is NAME with a line of HOSTSYMS matching (^|[ :])NAME<, else 0.
#       Missing files count as empty. Checked against the bash loop by tests/driver-second-pass/run.sh. As the bash
#       "while read" loop, a last line without its newline is not a name.
#   ruby scripts/nfcxx-second-pass.rb rerun ROOT HOSTSYMS PID ARGS...
#       runs the driver again (see rerun) and records its span when it succeeds (the bash's trace_end, with the driver's PID).
#   ruby scripts/nfcxx-second-pass.rb plan OUT CUDATMP NCU CU0 PREPROCESS HOSTSYMS_ENV ARGS...
#       prints the shell statements for eval: the bash gate (one .cu input, no NFCXX_CUDA_HOST_SYMBOLS, no preprocessing,
#       OUT made, a non-empty CUDATMP/<CU0 base>.dev.kernels.unresolved), the host symbols written to CUDATMP/host.syms, and
#       the found check. Then sp_run=1 with hsyms and args2 (ARGS without --cache=), or sp_run=0.
#       Checked by tests/driver-secondpass-plan/run.sh.

require_relative "trace"

module NfcxxSecondPass
  module_function

  # the shell statements of the second pass's decision (see the usage above)
  def plan(out, cudatmp, ncu, cu0, preprocess, hostsyms_env, args)
    unresolved = "#{cudatmp}/#{File.basename(cu0, ".cu")}.dev.kernels.unresolved"
    return ["sp_run=0"] unless ncu == "1" && hostsyms_env.empty? && preprocess == "0" && File.file?(out) && nonempty?(unresolved)
    hsyms = "#{cudatmp}/host.syms"
    begin
      File.write(hsyms, host_symbols(out))
    rescue SystemCallError => e
      warn e.message   # the bash's "|| true": a host symbols file that is not written leaves none
    end
    return ["sp_run=0"] unless found?(hsyms, unresolved)
    kept = args.reject { |a| a.start_with?("--cache=") }
    ["sp_run=1", "hsyms=#{shq(hsyms)}", "args2=(#{kept.map { |a| shq(a) }.join(" ")})"]
  end

  # a word for eval: single quotes, with a quote written as '\''
  def shq(s)
    "'" + s.gsub("'") { "'\\''" } + "'"
  end

  def nonempty?(path)
    File.size(path) > 0
  rescue SystemCallError
    false
  end

  # the second pass's run: the driver again, with the host symbols, the cache left out (NFCXX_CACHE and NFCXX_CACHE_REMOTE
  # emptied), and the arguments of the compile without --cache. Its status is returned (the driver ends with it). The span
  # of the run is the bash's trace_start / trace_end around it: recorded only when the run succeeded (a failing run ends the
  # driver before its trace_end), with the driver's PID, as scripts/trace.sh's trace_end writes it.
  def rerun(root, hostsyms, pid, args)
    t0 = NfccxxTrace.start
    env = { "NFCXX_CUDA_HOST_SYMBOLS" => hostsyms, "NFCXX_CACHE" => "", "NFCXX_CACHE_REMOTE" => "" }
    system(env, File.join(root, "nfcxx"), *args)
    status = $?.exitstatus || 1
    trace_span(t0, "second pass (kernel instances from the host compile)", "eccp", pid) if status == 0
    status
  end

  # the span a bash trace_end writes (trace.sh): into the pending file when the driver batches its spans, else directly
  # (the same record as scripts/nfcxx-setup.rb's trace_span)
  def trace_span(start, name, category, pid, env: ENV)
    return unless NfccxxTrace.enabled?(env)

    pending = env["NFCXX_TRACE_PENDING"].to_s
    if pending.empty?
      NfccxxTrace.span(start, name, category, pid: pid, env: env)
    else
      fields = [start, NfccxxTrace.now_us, name, category, pid, env["NFCXX_TRACE_UNIT"].to_s]
      File.open(pending, "ab") { |f| f.write(fields.map { |v| "#{v}\0" }.join) }
    end
  end

  # the host symbols of OBJ: nm -C with the _INTERNAL_..:: scopes removed (the bash nm | sed); a failing nm gives nothing
  def host_symbols(obj)
    out = IO.popen(["nm", "-C", obj], err: File::NULL, &:read).to_s
    out.gsub(/_INTERNAL_[A-Za-z0-9_]*::/, "")
  rescue SystemCallError
    ""
  end

  def found?(hostsyms, unresolved)
    syms = File.file?(hostsyms) ? File.read(hostsyms) : ""
    names = File.file?(unresolved) ? File.read(unresolved).each_line.select { |l| l.end_with?("\n") }.map(&:chomp) : []
    names.any? do |k|
      !k.empty? && syms.each_line.any? { |line| line.match?(/(^|[ :])#{Regexp.escape(k)}</) }
    end
  end
end

if $PROGRAM_NAME == __FILE__
  cmd, *rest = ARGV
  case cmd
  when "found"
    hostsyms, unresolved = rest
    abort "nfcxx-second-pass: found HOSTSYMS UNRESOLVED" unless unresolved
    puts(NfcxxSecondPass.found?(hostsyms, unresolved) ? 1 : 0)
  when "rerun"
    root, hostsyms, pid, *args = rest
    abort "nfcxx-second-pass: rerun ROOT HOSTSYMS PID ARGS..." unless pid
    exit NfcxxSecondPass.rerun(root, hostsyms, pid.to_i, args)
  when "host-symbols"
    obj, dest = rest
    abort "nfcxx-second-pass: host-symbols OBJ DEST" unless dest
    File.write(dest, NfcxxSecondPass.host_symbols(obj))
  when "plan"
    out, cudatmp, ncu, cu0, preprocess, hostsyms_env, *args = rest
    abort "nfcxx-second-pass: plan OUT CUDATMP NCU CU0 PREPROCESS HOSTSYMS_ENV ARGS..." unless hostsyms_env
    puts NfcxxSecondPass.plan(out, cudatmp, ncu, cu0, preprocess, hostsyms_env, args)
  else
    abort "nfcxx-second-pass: found HOSTSYMS UNRESOLVED, host-symbols OBJ DEST, rerun ROOT HOSTSYMS PID ARGS... or plan (got #{cmd.inspect})"
  end
end
