#!/usr/bin/env ruby
# The frozen oracle of the driver body, tests/driver-body/nfcxx-oracle.sh (the bash driver as it was when the port began).
# This script runs it on its own, prepared the way scripts/nfcxx.rb prepares it (the root line, the "$0" re-run and the
# second-run line), so the oracle can be compared with the Ruby driver on the same command.
#
#   ruby scripts/nfcxx-oracle.rb -- ARGS...          run the oracle with ARGS (stdio inherited); its status is ours
#   ruby scripts/nfcxx-oracle.rb --diff -- ARGS...   run ./nfcxx (the Ruby driver) and the oracle in the current directory
#                                                    on the same ARGS, and compare stdout, stderr and status. Exit 0 when
#                                                    all three agree, 1 when they differ (the differences are printed).
#
# Run alone the oracle makes its own temporary directories and runs its own argument loop (the state the Ruby driver would
# pass in its environment is not set), so a comparison is of the behaviour, not of the environment the driver gives.
# tests/driver-oracle/run.sh checks the cases this script is for.

require "open3"
require "rbconfig"
require "tempfile"
require "tmpdir"
require "fileutils"
require_relative "nfcxx-second-pass"

ROOT = File.expand_path("..", __dir__)
ORACLE = File.join(ROOT, "tests", "driver-body", "nfcxx-oracle.sh")
DRIVER = File.join(ROOT, "nfcxx")

# the oracle's text, prepared as scripts/nfcxx.rb prepares it; returns [path to a runnable copy, the Tempfile holding it]
def prepared_oracle
  text = File.read(ORACLE).sub(/^root=\$\(cd "\$\(dirname "\$0"\)" && pwd\)$/) { "root=#{ROOT}" }
  abort "nfcxx-oracle: the oracle's root line is not as expected" unless text.include?("root=#{ROOT}")
  text = text.gsub('"$0"', "\"#{DRIVER}\"")
  text = NfcxxSecondPass.oracle_text(text) or abort "nfcxx-oracle: the oracle's second-pass run is not as expected"
  file = Tempfile.new(["nfcxx-oracle", ".sh"])
  file.write(text)
  file.close
  file
end

# the environment the Ruby driver gives the body that the body cannot make itself: the modules block's directory
# (NFCXX_OWNED_MODPLAN, scripts/nfcxx.rb). The others are left to the body, which makes its own when run alone.
def oracle_env
  { "NFCXX_OWNED_MODPLAN" => Dir.mktmpdir("nfcxx-oracle-modplan.") }
end

# runs COMMAND (an array) in the current directory, capturing stdout and stderr; returns [stdout, stderr, status]
def capture(command)
  out, err, status = Open3.capture3(*command)
  [out, err, status.exitstatus || 128 + status.termsig.to_i]
end

def run_oracle_alone(args)
  program = prepared_oracle
  env = oracle_env
  pid = Process.spawn(env, "bash", program.path, *args)
  Process.wait(pid)
  $?.exitstatus || 128 + $?.termsig
ensure
  program&.unlink
  FileUtils.rm_rf(env["NFCXX_OWNED_MODPLAN"]) if env
end

def diff(args)
  program = prepared_oracle
  ruby_side = capture([DRIVER, *args])
  env = oracle_env
  oracle_side = capture([env, "bash", program.path, *args])
  names = %w[stdout stderr status]
  differences = names.each_index.reject { |i| ruby_side[i] == oracle_side[i] }
  if differences.empty?
    puts "same: stdout, stderr and status agree (status #{ruby_side[2]})"
    return 0
  end
  differences.each do |i|
    puts "differs: #{names[i]}"
    puts "  driver: #{ruby_side[i].to_s.inspect[0, 400]}"
    puts "  oracle: #{oracle_side[i].to_s.inspect[0, 400]}"
  end
  1
ensure
  program&.unlink
  FileUtils.rm_rf(env["NFCXX_OWNED_MODPLAN"]) if env
end

if __FILE__ == $PROGRAM_NAME
  mode = ARGV.shift
  args = ARGV.first == "--" ? ARGV.drop(1) : ARGV
  case mode
  when "--diff" then exit(diff(args))
  when "--" , nil then exit(run_oracle_alone(args))
  else
    warn "usage: ruby scripts/nfcxx-oracle.rb [--diff] -- ARGS..."
    exit 2
  end
end
