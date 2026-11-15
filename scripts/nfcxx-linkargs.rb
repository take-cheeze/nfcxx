#!/usr/bin/env ruby
# nfcxx's link arguments for the EDG call, ported from the bash loop over the link's files (stage 4 of
# docs/notes/driver-port-plan.md): the -I, -l, -lcudart, -Wl and object arguments become the EDG options (eflist) and the
# user include directories (userinc), in argument order. The gcc plan (scripts/nfcxx-gcc-plan.rb) uses the same
# NfcxxLinkArgs.edg_options with its facts. tests/nfcxx-linkargs/run.sh checks the CLI against the bash loop
# (tests/nfcxx-linkargs/oracle.sh holds it verbatim).
#
#   ruby scripts/nfcxx-linkargs.rb edg COMPILE_ONLY MOVES FILE...
#       COMPILE_ONLY and MOVES are 0 or 1 (nfcxx's compile_only and moves). Standard output is one record per value,
#       each ending in a NUL byte: "e" VALUE (an eflist element), "u" VALUE (a userinc element), or "x" MESSAGE for an
#       option the link refuses (the bash prints MESSAGE on standard error and exits 2; no records follow it).
#       The CUDA home is CUDA_HOME (the environment); the CUB archive is scripts/cuda-cub.rb's output.
#
# Standard error is the command's own (the cuda-cub script's messages pass through).

require "open3"
require_relative "ecp-arg"

module NfcxxLinkArgs
  module_function

  # an option the link refuses (the bash's exit 2, with the message)
  class Refused < StandardError
  end

  # the EDG options (eflist) and the user include directories (userinc) of FILES, in argument order.
  #   compile_only: a -c (the CUB archive is not added)
  #   cuda_home:    CUDA_HOME ("" when unset)
  #   dir:          ->(path) { the path is an existing directory }
  #   cub:          ->() { the CUB archive's path ("" when none); called for each -lcudart of a link }
  #   ecp_arg:      ->(arg) { the argument as eccp receives it }
  def edg_options(files, compile_only:, cuda_home:, dir:, cub:, ecp_arg:)
    eflist = []
    userinc = []
    no_as_needed = false
    as_needed = false
    files.each do |f|
      case f
      when /\A-I./ then userinc << ecp_arg.call(f)
      when "-lcudart"
        # the run path of a CUDA_HOME's lib64; the CUB archive (links only); libcudart
        eflist.push("--c_to_obj_option", "-Wl,-rpath,#{cuda_home}/lib64") if !cuda_home.empty? && dir.call("#{cuda_home}/lib64")
        unless compile_only
          cub_lib = cub.call
          eflist << cub_lib unless cub_lib.empty?
        end
        eflist << "--c_to_obj_lib=cudart"
      when /\A-l./ then eflist << "--c_to_obj_lib=#{f[2..]}"
      # --no-as-needed: one for the whole link (see the bash loop's comment in nfcxx)
      when "-Wl,--no-as-needed"
        no_as_needed = true
      when /\A-Wl,--no-as-needed,/
        no_as_needed = true
        EcpArg.split_fields(f.delete_prefix("-Wl,--no-as-needed,")).each do |item|
          if item.start_with?("-l") && item.length > 2 then eflist << "--c_to_obj_lib=#{item[2..]}"
          elsif item.start_with?("-") then eflist.push("--c_to_obj_option", ecp_arg.call("-Wl,#{item}"))
          else eflist << ecp_arg.call(item)
          end
        end
      when "-Wl,--as-needed" then as_needed = true
      when /\A-Wl,(--whole-archive|--no-whole-archive|--start-group|--end-group|--as-needed|-Bstatic|-Bdynamic)(,|\z)/
        raise Refused, "nfcxx: #{f}: an order-dependent link option cannot be kept with C++ inputs (docs/notes/cxx-driver.md)"
      when /\A-Wl,/ then eflist.push("--c_to_obj_option", ecp_arg.call(f))
      else eflist << ecp_arg.call(f)
      end
    end
    if no_as_needed
      eflist.push("--c_to_obj_option", "-Wl,--no-as-needed")
    elsif as_needed
      eflist.push("--c_to_obj_option", "-Wl,--as-needed")
    end
    [eflist, userinc]
  end

  # scripts/cuda-cub.rb's output (its trailing newlines removed, as the bash's $(...) does); "" when it fails
  def cub_archive(root)
    out, status = Open3.capture2(File.join(root, "scripts", "cuda-cub.rb"))
    status.success? ? EcpArg.substitution(out) : ""
  rescue SystemCallError
    ""
  end
end

if $PROGRAM_NAME == __FILE__
  cmd, compile_only, moves, *files = ARGV
  abort "nfcxx-linkargs: edg COMPILE_ONLY MOVES FILE... (got #{cmd.inspect})" unless cmd == "edg" && %w[0 1].include?(compile_only) && %w[0 1].include?(moves)
  root = File.expand_path("..", __dir__)
  ecp = lambda do |arg|
    EcpArg.substitution(moves == "1" ? EcpArg.ecp_arg(arg) : arg)
  end
  $stdout.binmode
  begin
    eflist, userinc = NfcxxLinkArgs.edg_options(files, compile_only: compile_only == "1", cuda_home: ENV["CUDA_HOME"].to_s,
                                                dir: ->(d) { File.directory?(d) }, cub: -> { NfcxxLinkArgs.cub_archive(root) },
                                                ecp_arg: ecp)
    eflist.each { |v| $stdout.write("e#{v}\0") }
    userinc.each { |v| $stdout.write("u#{v}\0") }
  rescue NfcxxLinkArgs::Refused => e
    $stdout.write("x#{e.message}\0")
  end
end
