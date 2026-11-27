#!/usr/bin/env ruby
# nfcxx's eccp command line, planned in Ruby (stage 4 of docs/notes/driver-port-plan.md): the EDG driver call that
# compiles and links C++ sources. The bash arrays of the call (the options the argument loop and the link set) go in as
# records; this script computes the argument vector in the bash's order, the variable the bash exports for a shared
# link, and the working directory the call runs in. The bash runs the command (the trap, the temporary directory and
# the trace stay there). tests/nfcxx-eccp-plan/run.sh checks it against the bash's own command construction.
#
#   ruby scripts/nfcxx-eccp-plan.rb DIR KEEP SHARED < RECORDS
#
#   DIR     the temporary directory the call runs in ("" when the call stays in the user's directory)
#   KEEP    nfcxx's keep_intermediates ("0": the directory is removed on exit; anything else prints a note)
#   SHARED  nfcxx's shared (1: a shared link, which sets EDG_OBJ_TO_EXEC_DEFAULT_OPTIONS)
#
# RECORDS: NUL-separated. "k NAME" starts a group; "v VALUE" adds a value to the group (an empty value is "v").
# The groups: eccp (the EDG driver), std, dialect, out (the -o name), extra, inst_opts, modopts, diag_opts, userinc, sys_inc,
# hosted_libs, keep_static, profile_opts, eh_unwind, picopts, cobjs, preinc (the forced includes: their pre_opts are planned from them),
# cuda_opts, eflist, shim, vlart, rtlib. The scalars (eccp, std, dialect, out) have one value. An absent group is empty.
#
# Standard output: NUL-separated records, then the end marker "z":
#   "a ARG"   the next word of the command (the first is the driver's path, as the bash runs it)
#   "e NAME=VALUE"   a variable the bash exports for the command
#   "d DIR"   the directory the bash changes to first (only when DIR is not empty)
#   "z"       the end marker, written last (the bash stops with an error when it does not see one)
# A note for a kept temporary directory goes to standard error, as the bash printed it.
# Standard error for a bad record stream is a message and status 1 (no "z" is written).

require_relative "driver-state"
require_relative "ecp-arg"
require_relative "nfcxx-linkargs"

module NfcxxEccpPlan
  module_function

  # the command line: the driver, the standard, the dialect, the working-directory options, the options (the bash's order)
  def argv(groups)
    g = ->(name) { groups.fetch(name, []) }
    scalar = lambda do |name|
      values = g.call(name)
      raise ArgumentError, "group #{name} needs one value" unless values.length == 1
      values[0]
    end
    [scalar.call("eccp"), scalar.call("std"), "--#{scalar.call("dialect")}", "--wdir", "/",
     *g.call("extra"), *g.call("inst_opts"), *g.call("modopts"), *g.call("diag_opts"), *g.call("userinc"),
     *g.call("sys_inc"), *g.call("hosted_libs"),
     "--c_to_obj_option", "-O2", "--c_to_obj_option", "-fwrapv", "--c_to_obj_option", "-fno-strict-aliasing",
     *g.call("keep_static"), *g.call("profile_opts"), *g.call("eh_unwind"), "--c_to_obj_option", "-fgnu89-inline",
     *g.call("picopts"), *g.call("cobjs"), *g.call("pre_opts"), *g.call("cuda_opts"), *g.call("eflist"),
     *g.call("shim"), *g.call("vlart"), *g.call("rtlib"), "-o", scalar.call("out")]
  end

  # the --preinclude options of the forced includes (the bash's pre_opts, with the same values). With moves (the call runs in a
  # temporary directory) a file that exists here is made absolute, as the bash's abs_path made it: EcpArg.abs gives the path
  # (its directory must exist; the bash's $(...) removes trailing newlines). -include FILE is found through the include
  # directories as well as here, so the file is made absolute only when it exists here.
  def preinclude_options(files, moves)
    files.flat_map do |f|
      value = moves == "1" && File.exist?(f) ? EcpArg.substitution(EcpArg.abs(f)) : f
      ["--preinclude", value]
    end
  end

  # EDG_OBJ_TO_EXEC_DEFAULT_OPTIONS of a shared link: the link options among picopts, eflist and inst_opts (in that order),
  # which EDG takes in place of its own link options (-shared first). The option that follows --c_to_obj_option is kept
  # when it is a -Wl, option, -fuse-ld=, -pthread or -rdynamic: a shared library keeps its SONAME and RUNPATH this way.
  def shared_link_options(groups)
    lk = ["-shared"]
    prev = nil
    (groups.fetch("picopts", []) + groups.fetch("eflist", []) + groups.fetch("inst_opts", [])).each do |a|
      if prev == "--c_to_obj_option" && (a.start_with?("-Wl,", "-fuse-ld=") || a == "-pthread" || a == "-rdynamic")
        lk << a
      end
      prev = a
    end
    lk
  end

  # the plan: [argv, env, cd, note]; note is the message for standard error ("" for none)
  def plan(groups, dir, keep, shared)
    words = argv(groups)
    env = []
    if shared == "1"
      env << "EDG_OBJ_TO_EXEC_DEFAULT_OPTIONS=#{shared_link_options(groups).join(" ")}"
    end
    note = ""
    unless dir.empty? || keep == "0"
      note = "nfcxx: intermediates kept in #{dir} (--keep-intermediates)"
    end
    [words, env, dir.empty? ? nil : dir, note]
  end
end

if $PROGRAM_NAME == __FILE__
  abort "nfcxx-eccp-plan: DIR KEEP SHARED (records on standard input)" unless ARGV.length == 3
  dir, keep, shared = ARGV
  $stdin.binmode
  begin
    groups = DriverState.read_groups($stdin.read)
    # the eccp path and the -o name are given as nfcxx has them; with moves (the call runs in a temporary directory) they are
    # made absolute, as ecp-arg.rb does for the argument answers (the bash used to ask for them in a call of its own)
    moves = (groups["moves"] || ["0"])[0]
    ecp = ->(arg) { EcpArg.substitution(moves == "1" ? EcpArg.ecp_arg(arg) : arg) }
    groups["eccp"] = [ecp.(DriverState.scalar(groups, "eccp"))]   # a scalar group (one value) is checked as the plan checks it
    groups["out"] = [ecp.(DriverState.scalar(groups, "out"))]
    # the forced includes (preinc, the bash's -include FILE): their --preinclude options are planned here, with the call
    groups["pre_opts"] = NfcxxEccpPlan.preinclude_options(groups["preinc"] || [], moves) if groups.key?("preinc")
    # the link arguments (slice 8): the files of the link are planned here, with the call, so a refused option stops the driver
    # before the compile cache (the bash used to read them in a call of its own)
    if groups.key?("files")
      root = (groups["root"] || [])[0] || File.expand_path("..", __dir__)
      begin
        groups["eflist"], groups["userinc"] = NfcxxLinkArgs.edg_options(groups["files"], compile_only: (groups["compile_only"] || ["0"])[0] == "1",
          cuda_home: ENV["CUDA_HOME"].to_s, dir: ->(d) { File.directory?(d) }, cub: -> { NfcxxLinkArgs.cub_archive(root) }, ecp_arg: ecp)
      rescue NfcxxLinkArgs::Refused => e
        warn e.message
        exit 2
      end
    end
    words, env, cd, note = NfcxxEccpPlan.plan(groups, dir, keep, shared)
  rescue ArgumentError => e
    $stderr.puts "nfcxx-eccp-plan: #{e.message}"
    exit 1
  end
  $stderr.puts note unless note.empty?
  $stdout.binmode
  words.each { |w| $stdout.write("a#{w}\0") }
  env.each { |e| $stdout.write("e#{e}\0") }
  $stdout.write("d#{cd}\0") if cd
  $stdout.write("z\0")
end
