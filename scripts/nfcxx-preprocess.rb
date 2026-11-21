#!/usr/bin/env ruby
# nfcxx's -E route: the host C++ compiler's command line for the preprocessing run (the frozen body's "if [ $preprocess = 1 ]"
# block, which execs it). The state comes on stdin as NUL-terminated records:
#   s NAME=VALUE   a scalar: host (the compiler, NFCXX_CXX or g++), std (the --c++NN option), xlang, outset (1 when -o is given),
#                  out (the -o file), stdin_src (1 for a source on stdin)
#   e ARG          a preprocessor flag (ppflags)
#   c ARG          a compile flag (cflags)
#   d DIR          a system directory (sysdirs): -isystemDIR
#   i FILE         a forced include (preinc): -include FILE
#   r SRC          a source (srcs)
# The command is printed the same way, NUL-terminated, one argument per record, in the order the driver used:
#   HOST -E -std=STD [-x XLANG] ppflags cflags -isystemDIR... -include FILE... SRC... [-] [-o OUT]
# tests/driver-preprocess/run.sh checks its output against the driver's before this script existed.

scalars = {}
lists = Hash.new { |h, k| h[k] = [] }
records = $stdin.read.split("\0", -1)
records.pop if records.last == ""
records.each do |rec|
  kind = rec[0]
  value = rec[1..] || ""
  case kind
  when "s"
    name, val = value.split("=", 2)
    scalars[name] = val.to_s
  when "e", "c", "d", "i", "r" then lists[kind] << value
  else
    warn "nfcxx-preprocess: no record kind #{kind.inspect}"
    exit 2
  end
end

argv = [scalars.fetch("host", "g++"), "-E", "-std=#{scalars.fetch("std", "--c++23").delete_prefix("--")}"]
xlang = scalars.fetch("xlang", "")
argv += ["-x", xlang] unless xlang.empty?
argv += lists["e"]
argv += lists["c"]
argv += lists["d"].map { |dir| "-isystem#{dir}" }
lists["i"].each { |file| argv += ["-include", file] }
argv += lists["r"]
argv << "-" if scalars.fetch("stdin_src", "0") == "1"
argv += ["-o", scalars.fetch("out", "")] if scalars.fetch("outset", "0") == "1"

argv.each { |arg| $stdout.write(arg + "\0") }
