#!/usr/bin/env ruby
# Compares scripts/nfcxx-backend.rb with the bash backend decision (oracle.sh) over every combination of the inputs.
#   ruby tests/driver-backend/run.rb
require "open3"
require_relative "../../scripts/nfcxx-backend"

hosts = [["Linux", "x86_64"], ["Linux", "aarch64"], ["Linux", "riscv64"], ["Darwin", "arm64"], ["Darwin", "x86_64"]]
backends = ["", "gcc", "pathb", "bogus"]
flags = %w[backend_explicit path_b freestanding cosmo emit_c preprocess shared]
targets = ["", "linux_k1om"]
depmodes = ["", "-M"]
cases = []
backends.each do |b|
  (0...(2**flags.size)).each do |bits|
    targets.each do |t|
      depmodes.each do |d|
        hosts.each do |sys, mach|
          opts = { "backend" => b, "target" => t, "depmode" => d, "host" => "#{sys} #{mach}" }
          flags.each_with_index { |f, i| opts[f] = ((bits >> i) & 1).to_s }
          cases << opts
        end
      end
    end
  end
end

input = cases.map { |o| o.map { |k, v| "#{k}=#{v}" }.join(" ") }.join("\n") + "\n"
# the bash reads the same KEY=VALUE words; its uname is stubbed by SYS and MACH
lines = cases.map { |o| sys, mach = o["host"].split(" "); "SYS=#{sys} MACH=#{mach} " + o.reject { |k, _| k == "host" }.map { |k, v| "#{k}=#{v}" }.join(" ") }
out, status = Open3.capture2("bash", File.join(__dir__, "oracle.sh"), stdin_data: lines.join("\n") + "\n")
abort "oracle failed: #{status}" unless status.success?
bash_results = out.lines.map(&:chomp)
abort "oracle lines #{bash_results.size} != cases #{cases.size}" unless bash_results.size == cases.size

pass = fail = 0
cases.zip(bash_results).each do |opts, want|
  got =
    begin
      b, d, p = NfcxxBackend.decide(opts)
      "#{b} #{d} #{p}"
    rescue NfcxxBackend::Refusal => e
      "REFUSED #{e.message}"
    end
  if got == want
    pass += 1
  else
    fail += 1
    puts "FAIL #{opts.inspect}\n  bash: #{want}\n  ruby: #{got}" if fail <= 10
  end
end
puts "driver-backend: #{pass} passed, #{fail} failed (#{cases.size} cases)"
exit(fail.zero? ? 0 : 1)
