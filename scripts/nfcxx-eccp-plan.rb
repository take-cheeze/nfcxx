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
# hosted_libs, keep_static, eh_unwind, picopts, cobjs, pre_opts, cuda_opts, eflist, shim, vlart, rtlib. The scalars (eccp,
# std, dialect, out) have one value. An absent group is empty.
#
# Standard output: NUL-separated records, then the end marker "z":
#   "a ARG"   the next word of the command (the first is the driver's path, as the bash runs it)
#   "e NAME=VALUE"   a variable the bash exports for the command
#   "d DIR"   the directory the bash changes to first (only when DIR is not empty)
#   "z"       the end marker, written last (the bash stops with an error when it does not see one)
# A note for a kept temporary directory goes to standard error, as the bash printed it.
# Standard error for a bad record stream is a message and status 1 (no "z" is written).

require_relative "driver-state"

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
     *g.call("keep_static"), *g.call("eh_unwind"), "--c_to_obj_option", "-fgnu89-inline",
     *g.call("picopts"), *g.call("cobjs"), *g.call("pre_opts"), *g.call("cuda_opts"), *g.call("eflist"),
     *g.call("shim"), *g.call("vlart"), *g.call("rtlib"), "-o", scalar.call("out")]
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
