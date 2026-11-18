#!/usr/bin/env ruby
# nfcxx's dependency file command (the -MD/-MMD block of the driver body, docs/notes/driver-body-port.md): the C++ compiler
# (NFCXX_CXX, default g++) writes the dependency file of a compile with -M or -MM, as the bash did. The defaults, the -M/-MM
# choice, the -std form, the -isystem prefix of each system directory and the order of the words are planned here; the bash
# runs the command. tests/driver-depmode/run.sh checks the driver's lines against the bash block verbatim, with stub compilers.
#
#   ruby scripts/nfcxx-depmode.rb plan depmode=-MD|-MMD out=OUT std=--c++NN cxx=NAME dfile=FILE dtarget=TARGET
#       depphony=-MP|"" cflags=ARG... sysdirs=DIR... srcs=FILE...
#
# Every input is a key=value argument (the key is the part before the first "="); cflags, sysdirs and srcs are arrays, one
# argument per element, in order. A missing scalar is "". Standard output: the command, one word per NUL-terminated record:
# the compiler, -M or -MM, depphony (split at white space, as the unquoted bash word was), -MT TARGET, -MF FILE, -std=FORM,
# the cflags, -isystem DIR for each system directory (joined without a space), then the sources. The compiler is NFCXX_CXX
# (the default g++ when it is empty); the dependency file is dfile, or out with its last ".suffix" replaced by ".d" (out
# without a dot gets ".d" appended); the target is dtarget, or out.
#
# Standard error for a bad argument is a message and status 1; nothing is written to standard output then.

module NfcxxDepmode
  module_function

  # the inputs: a hash of the scalar names to their values, and the arrays (name => elements) of cflags, sysdirs and srcs
  def parse(args)
    scalars = {}
    arrays = Hash.new { |h, k| h[k] = [] }
    args.each do |raw|
      arg = raw.b   # a path need not be UTF-8
      key, value = arg.split("=".b, 2)
      raise ArgumentError, "not a key=value argument: #{arg.inspect}" if value.nil?

      if %w[cflags sysdirs srcs].include?(key)
        arrays[key] << value
      else
        scalars[key] = value
      end
    end
    [scalars, arrays]
  end

  # the words of the command, in the bash's order
  def words(scalars, arrays)
    out = scalars.fetch("out", "")
    dfile = scalars.fetch("dfile", "")
    dtarget = scalars.fetch("dtarget", "")
    cxx = scalars.fetch("cxx", "")
    cxx = "g++" if cxx.empty?
    depmode = scalars.fetch("depmode", "")
    std = scalars.fetch("std", "")

    df = dfile.empty? ? default_dfile(out) : dfile                 # ${dfile:-${out%.*}.d}
    tgt = dtarget.empty? ? out : dtarget                            # ${dtarget:-$out}
    mflag = depmode == "-MMD" ? "-MM" : "-M"
    [cxx, mflag, *scalars.fetch("depphony", "").split, "-MT", tgt, "-MF", df, "-std=#{std.delete_prefix("--")}",
     *arrays["cflags"], *arrays["sysdirs"].map { |d| "-isystem#{d}" }, *arrays["srcs"]]
  end

  # ${out%.*}.d: the text before the last dot of OUT (the whole name when it has no dot), then ".d"
  def default_dfile(out)
    dot = out.rindex(".")
    stem = dot ? out[0...dot] : out
    "#{stem}.d"
  end

  # the plan: the words, as NUL-terminated records (binary)
  def plan(args)
    scalars, arrays = parse(args)
    words(scalars, arrays).map { |w| w.b + "\0".b }.join
  end
end

if $PROGRAM_NAME == __FILE__
  abort "nfcxx-depmode: plan key=value... (got #{ARGV.first.inspect})" unless ARGV.first == "plan"
  begin
    data = NfcxxDepmode.plan(ARGV.drop(1))
  rescue ArgumentError => e
    abort "nfcxx-depmode: #{e.message}"
  end
  STDOUT.binmode
  STDOUT.write(data)
end
