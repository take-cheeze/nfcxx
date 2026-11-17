#!/usr/bin/env ruby
# The second pass's decision (restructure step 2 / B7 of docs/notes/driver-body-port.md), ported from the bash loop in nfcxx: the
# second pass runs when a kernel the device side left unresolved appears in the host symbols as NAME< (after the
# _INTERNAL_..:: scopes are removed). The driver keeps nm and the re-run; this decides.
#
#   ruby scripts/nfcxx-second-pass.rb host-symbols OBJ DEST
#       writes the host symbols of OBJ to DEST: nm -C, with the _INTERNAL_..:: scopes removed (the bash's nm | sed).
#   ruby scripts/nfcxx-second-pass.rb found HOSTSYMS UNRESOLVED
#       prints 1 when some non-empty line of UNRESOLVED is NAME with a line of HOSTSYMS matching (^|[ :])NAME<, else 0.
#       Missing files count as empty. Checked against the bash loop by tests/driver-second-pass/run.sh.

module NfcxxSecondPass
  module_function

  # the second pass's run: the driver again, with the host symbols, the cache left out (NFCXX_CACHE and NFCXX_CACHE_REMOTE
  # emptied), and the arguments of the compile without --cache. Its status is returned (the driver ends with it).
  def rerun(root, hostsyms, args)
    env = { "NFCXX_CUDA_HOST_SYMBOLS" => hostsyms, "NFCXX_CACHE" => "", "NFCXX_CACHE_REMOTE" => "" }
    system(env, File.join(root, "nfcxx"), *args)
    $?.exitstatus || 1
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
    names = File.file?(unresolved) ? File.read(unresolved).each_line.map(&:chomp) : []
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
    root, hostsyms, *args = rest
    abort "nfcxx-second-pass: rerun ROOT HOSTSYMS ARGS..." unless hostsyms
    exit NfcxxSecondPass.rerun(root, hostsyms, args)
  when "host-symbols"
    obj, dest = rest
    abort "nfcxx-second-pass: host-symbols OBJ DEST" unless dest
    File.write(dest, NfcxxSecondPass.host_symbols(obj))
  else
    abort "nfcxx-second-pass: found HOSTSYMS UNRESOLVED or host-symbols OBJ DEST (got #{cmd.inspect})"
  end
end
