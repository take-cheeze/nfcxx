#!/usr/bin/env ruby
# The Ruby driver (stage B2 of docs/notes/driver-body-port.md): the skeleton that will run the driver's top-level flow in Ruby.
# Until the stages are ported, it runs the bash driver (the oracle, tests/driver-body/nfcxx-bash) with the same arguments,
# environment, standard streams and status, so NFCXX_RUBY_DRIVER=1 changes nothing yet. Each stage moves a part of the flow
# here; the bash driver is the reference the differential tests compare against.
#
#   NFCXX_RUBY_DRIVER=1 ./nfcxx ARGS...      (./nfcxx runs this script when the flag is set)

require "tempfile"
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

# the stages not yet ported run in bash: the same arguments and environment, the standard streams inherited. Its status is ours.
status = system({ "RUBY" => ENV["RUBY"] || RbConfig.ruby }, "bash", program.path, *ARGV)
program.unlink
exit 0 if status
exit($?.exitstatus || 1)
