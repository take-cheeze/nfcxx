#!/usr/bin/env ruby
# The C++ modules block of nfcxx (docs/notes/modules.md), planned in Ruby. The frozen body (tests/driver-body/nfcxx-oracle.sh) calls
# it once, at the block's place (after the -E route and the post early exits), in place of its own module block:
#
#   ruby scripts/nfcxx-modules-plan.rb STATE REPLY
#
# It does what that block did, in the same order, with the same messages and statuses:
#   1. the module scan of every source (scripts/nfcxx-modscan.rb is-module; a source it cannot read is its message, and the
#      scan goes on with the next one);
#   2. when a source declares or imports a module: the refusals (the standard before C++20, --emit-c, C sources, each
#      source's check (scripts/nfcxx-modscan.rb check: partitions, header units, std imports), and -c with more than one
#      source); the checks run in the order of the sources, and the first failure ends the driver with its status;
#   3. a link (no -c): the module build, scripts/nfcxx-modules.rb build, which compiles each source and links them; the driver
#      ends with the build's status;
#   4. a -c compile: the module directory (mkdir -p, then its physical path), and the module options of the compile: --modules,
#      --modules_directory DIR, and --create_module_interface DIR/NAME.eifc for an interface unit (scripts/nfcxx-modscan.rb
#      decl-name).
#
# The scans and the build run as the same commands the bash ran (the child processes print their own messages on the
# driver's streams), so their output and statuses are theirs. The state comes from the body as NUL-terminated records
# (scripts/driver-state.rb, the bash's state_put); the groups are:
#   root         the repository (nfcxx and its scripts are under it)
#   out          the -o output
#   moddir       the --module-dir value ("" when unset)
#   std          the -std option (--c++NN)
#   emit_c       1 with --emit-c, else 0
#   compile_only 1 with -c, else 0
#   cfiles       the C sources
#   srcs         the source arguments (after the .cu and .cpp2 preparation)
#   argv         the command as given (the link's build repeats it)
# The reply (REPLY, written only when this returns 0) has the groups:
#   modules      1 when a source declares or imports a module, else 0
#   modopts      the module options of a compile (empty for a link or a plain compile)
#   built        the module build's status, when the build ran (the body then ends with it)
# and the end marker. A refusal or a failed step writes no reply: the message is on stderr and the exit status is the driver's.
#
# The body's modules variable and modopts array come from the reply; the body removes the reply's directory and ends with
# the status of the build when there is one.
require "open3"
require "rbconfig"
require_relative "driver-state"

OLD_STANDARDS = %w[--c++98 --c++03 --c++11 --c++14 --c++17].freeze

# the child's exit status (a signal is 128 plus its number, as the shell reports it)
def status_of(st)
  st.exitstatus || 128 + st.termsig.to_i
end

# runs CMD with the driver's standard streams; returns its status
def run_status(*cmd)
  pid = spawn(*cmd)
  _, st = Process.wait2(pid)
  status_of(st)
end

# the first value of a group; a group with no value (an empty argument of the state) is ""
def first(groups, name)
  (groups[name] || []).first.to_s
end

# a refusal: the message on stderr, the driver's status 2 (the bash's echo and exit 2)
def refuse(message)
  warn message
  exit 2
end

def write_reply(path, groups)
  File.open(path, "wb") do |io|
    DriverState.write_groups(io, groups)
    DriverState.write_end(io)
  end
end

def main(state_path, reply_path)
  groups = DriverState.read_groups(File.binread(state_path))
  root = first(groups, "root")
  out = first(groups, "out")
  moddir = first(groups, "moddir")
  std = first(groups, "std")
  emit_c = first(groups, "emit_c")
  compile_only = first(groups, "compile_only")
  cfiles = groups["cfiles"] || []
  srcs = groups["srcs"] || []
  argv = groups["argv"] || []
  ruby = ENV.fetch("RUBY", "").empty? ? "ruby" : ENV["RUBY"]
  scan = File.join(root, "scripts", "nfcxx-modscan.rb")
  build = File.join(root, "scripts", "nfcxx-modules.rb")

  # 1. the scan of every source (the bash read them all: is-module's status is the test, and a failure is its message)
  flags = srcs.map { |s| run_status(ruby, scan, "is-module", s) == 0 }
  modules = flags.any?
  unless modules
    write_reply(reply_path, [["modules", ["0"]], ["modopts", []]])
    return 0
  end

  # 2. the refusals of a module program
  refuse("nfcxx: C++ modules need -std=c++20 or later") if OLD_STANDARDS.include?(std)
  refuse("nfcxx: --emit-c does not support C++ modules yet (docs/notes/modules.md)") unless emit_c == "0"
  refuse("nfcxx: C sources cannot be built with C++ modules yet (docs/notes/modules.md)") unless cfiles.empty?
  srcs.each do |s|
    st = run_status(ruby, scan, "check", s)
    exit(st) unless st.zero?
  end

  # 3. a link: the module build (it compiles each source with this driver, then links them); the driver ends with its status
  if compile_only == "0"
    st = run_status(ruby, build, "build", root, out, moddir, srcs.size.to_s, *srcs, *argv)
    write_reply(reply_path, [["modules", ["1"]], ["modopts", []], ["built", [st.to_s]]])
    return 0
  end

  # 4. a -c compile: one source, its module directory, and its module options
  refuse("nfcxx: -c with C++ modules takes one source") unless srcs.size == 1
  dir = moddir.empty? ? File.dirname(out) : moddir
  st = run_status("mkdir", "-p", dir)
  exit(st) unless st.zero?
  dir = File.realpath(dir)
  name, decl_st = Open3.capture2(ruby, scan, "decl-name", srcs[0])
  exit(status_of(decl_st)) unless decl_st.success?
  name = name.sub(/\n+\z/, "")
  opts = ["--modules", "--modules_directory", dir]
  opts += ["--create_module_interface", "#{dir}/#{name}.eifc"] unless name.empty?
  write_reply(reply_path, [["modules", ["1"]], ["modopts", opts]])
  0
end

if $PROGRAM_NAME == __FILE__
  abort "usage: nfcxx-modules-plan.rb STATE REPLY" unless ARGV.size == 2
  exit(main(ARGV[0], ARGV[1]))
end
