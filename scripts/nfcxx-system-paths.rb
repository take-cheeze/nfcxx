#!/usr/bin/env ruby
# NFCXX_SYSTEM_PATHS, the directories the rewriter treats as system directories (stage B3/restructure step 3 of
# docs/notes/driver-body-port.md), computed from the environment the way the driver's two lines did: CUDA_HOME is put first
# (when set and not empty); with NFCXX_CUDA_TARGET=amdgpu, lib/hip and ROCm's include directory go in front of that. Checked
# against the bash by tests/driver-system-paths/run.sh.
#
#   ruby scripts/nfcxx-system-paths.rb plan root=ROOT
#       reads CUDA_HOME, NFCXX_SYSTEM_PATHS, NFCXX_CUDA_TARGET and ROCM from the environment; prints the export statement for
#       the driver to eval, or nothing when neither applies (the variable is then left as it was).

require "shellwords"

module NfcxxSystemPaths
  module_function

  def plan(env, root)
    value = env["NFCXX_SYSTEM_PATHS"]
    applies = false
    cuda = env["CUDA_HOME"].to_s
    unless cuda.empty?
      value = value.to_s.empty? ? cuda : "#{cuda}:#{value}"
      applies = true
    end
    if env.fetch("NFCXX_CUDA_TARGET", "nvidia") == "amdgpu"
      rocm = env["ROCM"].to_s.empty? ? "/opt/rocm" : env["ROCM"]
      front = "#{root}/lib/hip:#{rocm}/include"
      value = value.to_s.empty? ? front : "#{front}:#{value}"
      applies = true
    end
    applies ? "export NFCXX_SYSTEM_PATHS=#{Shellwords.escape(value)}" : ""
  end
end

if $PROGRAM_NAME == __FILE__
  cmd, *rest = ARGV
  abort "nfcxx-system-paths: plan root=ROOT (got #{cmd.inspect})" unless cmd == "plan"
  root = rest.find { |a| a.start_with?("root=") }&.sub("root=", "") || abort("nfcxx-system-paths: plan needs root=ROOT")
  out = NfcxxSystemPaths.plan(ENV, root)
  puts out unless out.empty?
end
