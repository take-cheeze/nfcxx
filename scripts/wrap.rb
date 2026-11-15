#!/usr/bin/env ruby
# nfcxx's --bundle-* and --cuda-driver= wrappers, run by the bash driver (nfcxx calls these through shims). The decisions are
# scripts/driver-loop.rb's bundle_wrap and cuda_driver_wrap, the ones nfcc runs; this file gives them the real environment
# (scripts/nfcc.rb's effects and probes), the way nfcc does. The bash original of each wrapper is tests/wrap/*.sh, and
# tests/wrap/run.sh is the differential test.
#
#   ruby scripts/wrap.rb bundle DRIVER ARGS...
#       the --bundle-* options: the driver runs again on ARGS without them, and a link is bundled with build/nfcbundle
#   ruby scripts/wrap.rb cuda-driver DRIVER ARGS...
#       --cuda-driver=: prints a decision line, CONTINUE (the driver goes on with the arguments that follow, without the
#       --cuda-driver= options) or EXEC (the driver is run again with them, the shim in place of libcuda), then the arguments,
#       one to a line. An argument with a newline is refused (the lines could not carry it).
#
# Exit status of bundle: 254 means nothing was done and the caller goes on. Any other status is the end of the run (a
# refusal, the driver's status, nfcbundle's), and a process that exec's the driver or nfcbundle is replaced, as in bash. A
# status of 254 from a run is reported as 255, since 254 means "go on".

require_relative "nfcc"

module WrapCli
  module_function

  GO_ON = 254

  # the environment the wrappers read, as nfcc's front sets it (only what the wrappers use; nfcc's front also reads the
  # backend and the Path B settings, which these do not)
  def environment(driver)
    env = Env.new
    env.root = ROOT
    env.driver = driver
    env.cuda_home = ENV["CUDA_HOME"].to_s
    env.cuda_driver_env = ENV["NFCXX_CUDA_DRIVER"].to_s.empty? ? "auto" : ENV["NFCXX_CUDA_DRIVER"]
    env.machine = Etc.uname[:machine]
    tool = File.join(ROOT, "build/nfcbundle")
    source = File.join(ROOT, "tools/bundle/nfcbundle.cpp")
    env.bundle_tool = if !File.executable?(tool) then "missing"
                      elsif File.exist?(source) && File.mtime(source) > File.mtime(tool) then "stale"
                      else "fresh"
                      end
    env.ninja_fails = lambda do
      !system("ninja", "-C", File.join(ROOT, "tools/bundle"), out: File::NULL)
    end
    env.shim = lambda do |include_dir|
      out, ok = capture_stdout([File.join(ROOT, "scripts/cuda-driver-shim.rb"), include_dir], err: [:child, :out])
      text = out.sub(/\n+\z/, "")
      ok ? [text, nil] : [nil, text]
    end
    env
  end

  # the status to end with (254 would read as "go on", so a run's 254 is 255)
  def finish(status)
    exit(status == GO_ON ? 255 : status)
  end

  def bundle(driver, args)
    $nfcc_effects = NfccEffects.new
    result = bundle_wrap(environment(driver), args, File.basename(driver))
    exit(GO_ON) if result.nil?

    finish(0)
  rescue BundleExit => e
    $stderr.write("#{e.message}\n") unless e.message.empty?
    finish(e.status)
  rescue PathbExit => e
    finish(e.status)
  end

  def cuda_driver(driver, args)
    if args.any? { |a| a.include?("\n") }
      $stderr.write("wrap: an argument with a newline cannot be passed to the CUDA driver wrapper\n")
      exit(2)
    end
    kind, list = cuda_driver_wrap(environment(driver), args, File.basename(driver))
    $stdout.write((kind == :exec ? "EXEC\n" : "CONTINUE\n") + list.map { |a| "#{a}\n" }.join)
    exit(0)
  rescue CudaExit => e
    $stderr.write("#{e.message}\n") unless e.message.empty?
    finish(e.status)
  end
end

if $PROGRAM_NAME == __FILE__
  mode = ARGV.shift
  case mode
  when "bundle" then WrapCli.bundle(ARGV[0], ARGV[1..])
  when "cuda-driver" then WrapCli.cuda_driver(ARGV[0], ARGV[1..])
  else abort "wrap: unknown mode #{mode.inspect} (bundle or cuda-driver)"
  end
end
