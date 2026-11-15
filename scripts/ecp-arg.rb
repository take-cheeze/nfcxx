#!/usr/bin/env ruby
# nfcxx's ecp_arg, ported from the bash function (stage 4 of docs/notes/driver-port-plan.md): ARG as eccp receives it when eccp
# runs in a temporary directory, so the paths that name files here are made absolute first. The bash original is
# tests/nfcxx-ecp-arg/oracle.sh, and tests/nfcxx-ecp-arg/run.sh is the differential test. nfcxx's shim calls this only when
# eccp runs in a temporary directory (moves=1); with moves=0 the argument is passed as it is.
#
#   ruby scripts/ecp-arg.rb ARG     prints the argument for eccp (one line)
#
# abs_path is host-sys.rb's: the absolute path of a path that need not exist (its directory must exist, else it is unchanged).

require_relative "host-sys"

module EcpArg
  module_function

  # the bash `dirname`/`basename` of a value (bash's dirname "" is "."; Ruby's File.dirname "" is "." too)
  def abs(path)
    HostSys.abs_path(path)
  end

  # bash: IFS=, read -r -a parts <<< "$x": the fields, a final delimiter ending the last field (not an empty field)
  def split_fields(text)
    parts = text.split(",", -1)
    parts.pop if !parts.empty? && parts.last.empty?
    parts
  end

  # a file named in a -Wl, option is made absolute when it exists here (or, for a file the link writes, when its directory exists)
  def wl_option(arg)
    res = "-Wl"
    prevp = nil
    split_fields(arg[4..]).each do |p|
      # the operand of -soname (-h) is the name the library records, not a file
      if %w[-soname --soname -h].include?(prevp)
        res += ",#{p}"
        prevp = p
        next
      end
      prevp = p
      p = if p.start_with?("-soname=") || p.start_with?("--soname=")
            p
          elsif p.start_with?("--dependency-file=") || p.start_with?("-Map=") || p.start_with?("--Map=")
            # files the link writes (CMake 4 passes -Wl,--dependency-file=...): absolute when their directory exists here
            key, value = p.split("=", 2)
            if File.exist?(value) || File.directory?(File.dirname(value))
              "#{key}=#{abs(File.dirname(value))}/#{File.basename(value)}"
            else
              p
            end
          elsif p.include?("=")
            key, value = p.split("=", 2)
            File.exist?(value) ? "#{key}=#{abs(value)}" : p
          else
            File.exist?(p) ? abs(p) : p
          end
      res += ",#{p}"
    end
    res
  end

  # the argument as eccp receives it
  def ecp_arg(arg)
    if arg.start_with?("-I") && arg.length > 2
      "-I#{abs(arg[2..])}"
    elsif arg.start_with?("-L") && arg.length > 2
      "-L#{abs(arg[2..])}"
    elsif arg.start_with?("-Wl,")
      wl_option(arg)
    elsif arg.start_with?("-")
      arg
    else
      abs(arg)
    end
  end
end

if $PROGRAM_NAME == __FILE__
  abort "ecp-arg: one argument" unless ARGV.length == 1
  puts EcpArg.ecp_arg(ARGV[0])
end
