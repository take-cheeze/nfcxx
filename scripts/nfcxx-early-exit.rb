#!/usr/bin/env ruby
# nfcxx's early exits: the refusals, and the emit-hip route, that the driver takes right after the argument loop and before the
# setup (the frozen body's block between "END the argument loop" and the C++ modules). The driver calls it twice:
#   ruby scripts/nfcxx-early-exit.rb pre   before the SYCL check: no input files, and --emit-hip (its route is status 3)
#   ruby scripts/nfcxx-early-exit.rb post  after the -E route: stdin without -E, -x, dependency files without -c, the EDG build
#                                          and the dialect
# The state comes on stdin as NUL-terminated records "s NAME=VALUE" (the body's variable names, see early_records there).
# Exit status: 0 continue; 2 refuse, with the driver's message on stderr (the driver exits with that status); 3 route to the
# emit-hip run (the driver runs it itself: the route is not planned here).
# tests/driver-early-exit/run.sh checks the refusals against the driver's output before this script existed.

state = {}
$stdin.read.split("\0").each do |rec|
  next unless rec.start_with?("s")
  name, value = rec[1..].split("=", 2)
  state[name] = value.to_s
end

def refuse(message)
  warn message
  exit 2
end

def count(state, name)
  Integer(state.fetch(name, "0"), 10)
end

case ARGV[0]
when "pre"
  if count(state, "ncpp") + count(state, "nobj") + count(state, "cfiles_n") + count(state, "stdin_src") <= 0
    refuse "nfcxx: no input files"
  end
  if state.fetch("emit_hip", "0") == "1"
    refuse "nfcxx: --emit-hip takes one .cu file" unless count(state, "cu_n") == 1
    exit 3
  end
when "post"
  refuse "nfcxx: a source on stdin is supported only with -E" if count(state, "stdin_src") == 1
  xlang = state.fetch("xlang", "")
  refuse "nfcxx: -x #{xlang}: only C++ sources (use nfcc for C)" unless ["", "c++", "none"].include?(xlang)
  depmode = state.fetch("depmode", "")
  refuse "nfcxx: #{depmode} needs -c (dependency files are written for a compile only)" if !depmode.empty? && count(state, "compile_only") == 0
  needs_edg = count(state, "ncpp") > 0 || count(state, "emit_c") == 1 ||
              (count(state, "nobj") > 0 && count(state, "cfiles_n") == 0)
  if needs_edg && !File.executable?(File.join(state.fetch("edg", ""), "eccp"))
    refuse "nfcxx: EDG not built; run scripts/setup-edg.sh"
  end
  dialect = state.fetch("dialect", "")
  refuse "nfcxx: unknown dialect '#{dialect}'" unless ["g++", "clang"].include?(dialect)
else
  warn "nfcxx-early-exit: usage: pre|post (records on stdin)"
  exit 1
end
exit 0
