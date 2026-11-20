#!/usr/bin/env ruby
# The Ruby driver (stage B2 of docs/notes/driver-body-port.md): the skeleton that will run the driver's top-level flow in Ruby.
# Until the stages are ported, it runs the bash driver (the oracle, tests/driver-body/nfcxx-bash) with the same arguments,
# environment, standard streams and status, so NFCXX_RUBY_DRIVER=1 changes nothing yet. Each stage moves a part of the flow
# here; the bash driver is the reference the differential tests compare against.
#
#   NFCXX_RUBY_DRIVER=1 ./nfcxx ARGS...      (./nfcxx runs this script when the flag is set)

require "tempfile"
require "tmpdir"
require "fileutils"
require "rbconfig"
require_relative "nfcxx-setup-args"

root = File.expand_path("..", __dir__)
oracle = File.join(root, "tests", "driver-body", "nfcxx-bash")

# the oracle computes its root from its own location; here it is this repository's root (the same substitution the
# differential tests make), so its paths are the repository's
text = File.read(oracle).sub(/^root=\$\(cd "\$\(dirname "\$0"\)" && pwd\)$/) { "root=#{root}" }
# the oracle re-runs the driver as "$0" (the -fsyntax-only route): run from a temporary program, $0 is that file, so the
# driver's own path is put there (the program is an executable file of its own, not a driver)
text = text.gsub('"$0"', "\"#{File.join(root, "nfcxx")}\"")
abort "nfcxx: the oracle's root line is not as expected" unless text.include?("root=#{root}")
program = Tempfile.new(["nfcxx-oracle", ".sh"])
program.write(text)
program.close

# B6 (docs/notes/driver-body-restructure.md): the temporary directories of the driver are made under a root that this process
# owns. TMPDIR points at it, so every mktemp -d the bash makes lands there; the bash removes its own directories in its EXIT
# traps, and this removes whatever is left (a failing or interrupted driver) when the run ends, normally or not.
status = nil
# --keep-intermediates (NFCXX_KEEP_INTERMEDIATES=1): the bash keeps its eccp directory, which is made under this root; the root is then
# kept too, so the directory the user asked for survives the run (the bash's eccp_cleanup removes it only when the flag is off)
keep = ENV["NFCXX_KEEP_INTERMEDIATES"] == "1"
tmproot = Dir.mktmpdir("nfcxx-tmp.")
status_code = 1
begin
  # the stages not yet ported run in bash: the same arguments and environment, the standard streams inherited. Its status is ours.
  # NFCXX_TMP_OWNED: the temporary directories are this process's, removed when it ends (unless intermediates are kept), so the
  # driver's eccp trap keeps only its trace finish (nfcxx: eccp_cleanup is for the plain driver)
  # the trace (--trace=FILE, the last one, or NFCXX_TRACE): this process opens it and closes it, as the bash's trace_begin and
  # trace_finish did; the bash only flushes its spans (its trace_finish keeps its span flush, and does not close the trace)
  trace_file = ARGV.reverse.find { |a| a.start_with?("--trace=") }&.delete_prefix("--trace=") || ENV["NFCXX_TRACE"].to_s
  env = { "RUBY" => ENV["RUBY"] || RbConfig.ruby, "TMPDIR" => tmproot, "NFCXX_TMP_OWNED" => "1" }
  trace_rb = File.join(__dir__, "trace.rb")
  unless trace_file.empty?
    trace_abs = File.join(File.realpath(File.dirname(trace_file)), File.basename(trace_file))
    env["NFCXX_TRACE"] = trace_abs
    env["NFCXX_TRACE_OWNER"] = Process.pid.to_s
    env["NFCXX_TRACE_PENDING"] = File.join(tmproot, "nfcxx-trace-pending.#{Process.pid}")
    File.write(env["NFCXX_TRACE_PENDING"], "")
    system(env["RUBY"], trace_rb, "open", trace_abs)
  end
  # B3: the setup stage's refusals (scripts/nfcxx-setup-args.rb): the bash prints the message and exits with the status, after the
  # trace is opened and before anything else of the setup runs. Any other command goes on to the oracle unchanged.
  refusal = NfcxxSetupArgs.refusal(ARGV, ENV)
  if refusal
    $stderr.puts(refusal.message)
  else
    status = system(env, "bash", program.path, *ARGV)
  end
  unless trace_file.empty?
    system(env, env["RUBY"], trace_rb, "flush", env["NFCXX_TRACE_PENDING"]) if File.size?(env["NFCXX_TRACE_PENDING"])
    system(env["RUBY"], trace_rb, "close", trace_abs, Process.pid.to_s)
  end
  status_code = if refusal then refusal.status
                else status ? 0 : ($?.exitstatus || 1)
                end
ensure
  program.unlink
  FileUtils.rm_rf(tmproot) unless keep
end
exit status_code
