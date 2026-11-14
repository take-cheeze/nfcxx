#!/usr/bin/env ruby
# Build the baked bc2cpp command with nfcxx's C++ runtime. Its Ruby sources run as mruby bytecode;
# this is the runner, not the experimental bc2cpp-self AOT build.
# BC2CPP_RPG_DIR / BC2CPP_WORLD_ROOT: an existing world; otherwise fetch the test world's pin.
# BC2CPP_RUNNER_CXX: C++ compiler (default nfcxx); NFCXX_BACKEND: nfcxx backend (default gcc).
# BC2CPP_RUNNER_BUILD_DIR: override the build directory; BC2CPP_BUILD_JOBS: rake jobs (default 8).
require_relative "setup-common"
include SetupCommon

# The world's fetch is tests/bc2cpp/fetch.sh, which the bash sourced. Its pin and submodules are repeated here;
# tests/rb-migration/bc2cpp runs the bash fetch against the same cases, so a change to one that is not made to the other fails.
RPG_PIN = "f2cc1cad69a4058951e9669e90a2b7e0650a334e"
RPG_URL = "https://github.com/take-cheeze/rpg-maker-clone"
SUBMODULES = %w[3rd/mruby 3rd/mruby-onig-regexp 3rd/mruby-stringio 3rd/mruby-marshal 3rd/optcarrot].freeze
SKIP_FULL = "3rd/effekseer 3rd/gflags 3rd/ng-log 3rd/inicpp 3rd/nfcxx"
# The fetch ran with its output on stderr (bc2cpp_fetch >&2)
TO_STDERR = { out: :err }.freeze

# bc2cpp_fetch: [the world's root, the status the script exits with]
def bc2cpp_fetch(root)
  rpg = ENV["BC2CPP_RPG_DIR"].to_s
  unless rpg.empty?
    return [nil, 1] unless File.directory?(rpg)

    return [File.expand_path(rpg), 0]
  end

  bc2cpp_root = "#{root}/build/bc2cpp/rpg-maker-clone"
  unless File.directory?("#{bc2cpp_root}/.git")
    ok = run("mkdir", "-p", bc2cpp_root, **TO_STDERR).success? &&
         run("git", "-C", bc2cpp_root, "init", "-q", **TO_STDERR).success? &&
         run("git", "-C", bc2cpp_root, "remote", "add", "origin", RPG_URL, **TO_STDERR).success?
    return [nil, 1] unless ok
  end
  head, = capture("git", "-C", bc2cpp_root, "rev-parse", "-q", "--verify", "HEAD", err: File::NULL)
  if chomp_all(head) != RPG_PIN
    run("rm", "-f", "#{bc2cpp_root}/3rd/nfcxx", **TO_STDERR)
    unless run("git", "-C", bc2cpp_root, "fetch", "-q", "--depth", "1", "origin", RPG_PIN, **TO_STDERR).success?
      $stderr.puts "bc2cpp: fetching #{RPG_URL} #{RPG_PIN} failed"
      return [nil, 2]
    end
    return [nil, 1] unless run("git", "-C", bc2cpp_root, "checkout", "-q", "-f", RPG_PIN, **TO_STDERR).success?
  end

  if ENV["BC2CPP_WORLD_FULL"] == "1"
    unless run({ "SKIP_SUBMODULES" => SKIP_FULL }, "#{bc2cpp_root}/scripts/checkout-submodules.bash",
               chdir: bc2cpp_root, out: File::NULL).success?
      $stderr.puts "bc2cpp: fetching the submodules failed"
      return [nil, 2]
    end
  else
    unless run("git", "-C", bc2cpp_root, "submodule", "update", "-q", "--init", "--depth", "1", "--force",
               *SUBMODULES, **TO_STDERR).success?
      $stderr.puts "bc2cpp: fetching the submodules failed"
      return [nil, 2]
    end
  end

  nfcxx = "#{bc2cpp_root}/3rd/nfcxx"
  unless File.symlink?(nfcxx)
    return [nil, 1] unless run("rm", "-rf", nfcxx, **TO_STDERR).success? &&
                           run("ln", "-s", root, nfcxx, **TO_STDERR).success?
  end
  [bc2cpp_root, 0]
end

root = root_of(__FILE__)
if ENV["BC2CPP_WORLD_ROOT"].to_s.empty?
  world, status = bc2cpp_fetch(root)
  exit status unless status.zero?
else
  world = File.expand_path(ENV["BC2CPP_WORLD_ROOT"])
  die("setup-bc2cpp: no directory #{ENV['BC2CPP_WORLD_ROOT']}") unless File.directory?(world)
end

must("git", "-C", root, "submodule", "update", "--init", "--depth", "1", "bc2cpp/3rd/prism", "bc2cpp/3rd/rbs", **TO_STDERR)
ENV["NFCXX_BACKEND"] = env_or("NFCXX_BACKEND", "gcc")
out = env_or("BC2CPP_RUNNER_BUILD_DIR", "#{root}/build/bc2cpp-runner-#{ENV['NFCXX_BACKEND']}")
must("mkdir", "-p", out)
out = File.expand_path(out)
lock = nil
if command?("flock")
  lock = File.open("#{out}/.lock", "w")
  lock.flock(File::LOCK_EX)
end

build_log = "#{out}/build.log"
built = begin
  run({ "LD" => nil, "BC2CPP_WORLD_ROOT" => world,
        "BC2CPP_RUNNER_CXX" => env_or("BC2CPP_RUNNER_CXX", "#{root}/nfcxx"), "BC2CPP_RUNNER_OPT" => "1",
        "MRUBY_CONFIG" => "#{root}/bc2cpp/host-libs/mruby-bc2cpp-runner/build_config.rb",
        "MRUBY_BUILD_DIR" => out },
      "rake", "-j#{env_or('BC2CPP_BUILD_JOBS', '8')}", "all", "#{out}/bc2cpp-runner/lib/libmruby.flags.mak",
      chdir: "#{world}/3rd/mruby", out: build_log, err: [:child, :out])
rescue SystemCallError
  nil
end
unless built&.success?
  File.readlines(build_log).last(30).each { |line| $stderr.print line } if File.exist?(build_log)
  die("setup-bc2cpp: build failed; log: #{build_log}")
end
puts "#{out}/bc2cpp-runner/bin/mruby"
