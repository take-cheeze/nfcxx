#!/usr/bin/env ruby
# nfcxx's link steps, ported from the bash in nfcxx (stage 4 of docs/notes/driver-port-plan.md): link_records_rm and
# eccp_cleanup. The bash functions stay, as one-line calls of this script. Checked against the bash originals by
# tests/nfcxx-link/run.sh (tests/nfcxx-link/oracle.sh holds them verbatim).
#
#   ruby scripts/nfcxx-link.rb records-rm -- FILE...
#       link_records_rm: for each FILE that ends in .o, removes the <stem>.ii beside it (rm -f "${f%.o}.ii"). The status is the
#       status of the last FILE (a file that does not end in .o counts as 0, as the bash's case does); a <stem>.ii that is a
#       directory, or that cannot be removed, is rm's message and status 1.
#
#   ruby scripts/nfcxx-link.rb cleanup KEEP ECCP_DIR CUDATMP CTMP
#       eccp_cleanup's removals (rm -rf), for the EXIT trap: ECCP_DIR is removed unless KEEP is 1 (keep_intermediates); CUDATMP
#       and CTMP are always removed. An empty argument is an unset variable. The trace is finished by the bash (trace.sh).
#
# Both print rm's messages on standard error ("rm: ..."), as the bash's rm does. Exit status: as the bash's (see each step).

require "fileutils"

module NfcxxLink
  module_function

  # rm -f PATH: nothing to do when PATH does not exist (a dangling symbolic link is removed); a directory is not removed.
  # A name that starts with - is an option to rm (the bash passes the name without --): GNU getopt's message for it.
  def rm_f(path)
    if path.start_with?("--")
      $stderr.puts "rm: unrecognized option '#{path.split("=", 2)[0]}'"
      $stderr.puts "Try 'rm --help' for more information."
      return 1
    end
    if path.start_with?("-")
      bad = path[1..].each_char.find { |ch| !"fiIrRdv".include?(ch) }
      $stderr.puts "rm: invalid option -- '#{bad}'"
      $stderr.puts "Try 'rm --help' for more information."
      return 1
    end
    return 0 unless File.exist?(path) || File.symlink?(path)
    if File.directory?(path) && !File.symlink?(path)
      $stderr.puts "rm: cannot remove '#{path}': Is a directory"
      return 1
    end
    File.unlink(path)
    0
  rescue SystemCallError => e
    $stderr.puts "rm: cannot remove '#{path}': #{SystemCallError.new(nil, e.errno).message}"
    1
  end

  # the bash for loop of link_records_rm under nfcxx's set -e: a failing rm ends the loop and the step with its status
  def records_rm(files)
    files.each do |f|
      next unless f.end_with?(".o")
      status = rm_f("#{f.delete_suffix(".o")}.ii")
      return status unless status == 0
    end
    0
  end

  # rm -rf PATH (the removal of eccp_cleanup); the root directory is refused, as rm refuses it
  def rm_rf(path)
    if path == "/"
      $stderr.puts "rm: it is dangerous to operate recursively on '/'"
      return 1
    end
    FileUtils.rm_rf(path)
    0
  end

  # eccp_cleanup's removals: the status is the last rm's (the bash's trap returns its own status, not this one)
  def cleanup(keep, eccp_dir, cudatmp, ctmp)
    status = 0
    status = rm_rf(eccp_dir) if !eccp_dir.empty? && keep == "0"
    status = rm_rf(cudatmp) unless cudatmp.empty?
    status = rm_rf(ctmp) unless ctmp.empty?
    status
  end
end

if $PROGRAM_NAME == __FILE__
  cmd, *rest = ARGV
  case cmd
  when "records-rm"
    rest.shift if rest.first == "--"
    exit NfcxxLink.records_rm(rest)
  when "cleanup"
    abort "nfcxx-link: cleanup takes KEEP ECCP_DIR CUDATMP CTMP" unless rest.length == 4
    exit NfcxxLink.cleanup(*rest)
  else
    abort "nfcxx-link: records-rm or cleanup (got #{cmd.inspect})"
  end
end
