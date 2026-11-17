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

root = File.expand_path("..", __dir__)
oracle = File.join(root, "tests", "driver-body", "nfcxx-bash")

# the oracle computes its root from its own location; here it is this repository's root (the same substitution the
# differential tests make), so its paths are the repository's
text = File.read(oracle).sub(/^root=\$\(cd "\$\(dirname "\$0"\)" && pwd\)$/) { "root=#{root}" }
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
  status = system({ "RUBY" => ENV["RUBY"] || RbConfig.ruby, "TMPDIR" => tmproot, "NFCXX_TMP_OWNED" => "1" }, "bash", program.path, *ARGV)
  status_code = status ? 0 : ($?.exitstatus || 1)
ensure
  program.unlink
  FileUtils.rm_rf(tmproot) unless keep
end
exit status_code
