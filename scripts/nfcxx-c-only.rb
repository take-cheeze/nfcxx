#!/usr/bin/env ruby
# The C-only -c exit of nfcxx (the block after the C objects are made, when every input is a C source and -c is given), ported
# from the bash in nfcxx: the refusal of -o with several sources, and the copy of each C object to its output name. The driver
# names the objects of a -c compile with -o (one object: OUT) or, without -o, <source>.o (scripts/nfcxx-objname.rb --suffix=.c).
# The bash then exits 0; that exit stays in nfcxx, which runs this planner first.
#
#   ruby scripts/nfcxx-c-only.rb copy outset=0|1 out=PATH cobjs=LIST cfiles=LIST
#       LIST is the elements joined by ASCII 31 (the driver's convention). With outset=1, the one object is copied to out, else
#       each object is copied to the object name of its source. A refusal (-o with more than one source) prints the bash's message
#       on standard error and exits 2. A failed cp ends the planner with cp's status (set -e in the bash: the same status, cp's
#       message). The driver's C-only -c block is removed from tests/driver-body/run.sh's comparison (the strip rule for it).

require_relative "nfcxx-objname"

module NfcxxCOnly
  module_function

  def words(list)
    list.to_s.split("\x1f", -1).reject(&:empty?)
  end

  # the copies: returns the status of the first failed cp (the bash stops there), else 0
  def copy(opts)
    outset = opts.fetch("outset", "0")
    out = opts.fetch("out", "")
    cobjs = words(opts["cobjs"])
    cfiles = words(opts["cfiles"])
    if outset != "0" && cobjs.size != 1
      $stderr.puts "nfcxx: -c with -o needs exactly one source"
      return 2
    end
    cobjs.each_with_index do |obj, i|
      dst = out
      if outset == "0"
        dst = NfcxxObjname.object_name(cfiles.fetch(i), suffix: ".c").sub(/\n+\z/n, "".b)
      end
      next if system("cp", obj, dst)

      return $?.exitstatus || 1
    end
    0
  end
end

if $PROGRAM_NAME == __FILE__
  cmd, *rest = ARGV
  if cmd == "copy"
    status = NfcxxCOnly.copy(rest.to_h { |kv| kv.split("=", 2) })
    exit status
  end
  abort "nfcxx-c-only: copy outset=0|1 out=PATH cobjs=LIST cfiles=LIST (got #{cmd.inspect})"
end
