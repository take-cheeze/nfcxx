#!/usr/bin/env ruby
# nfcxx's C++ module options (docs/notes/modules.md), planned in Ruby: the options of a -c compile of a module source. The bash
# makes the module directory first (mkdir -p, then its physical path with cd and pwd -P: the directory must exist before pwd -P
# can give its path, and mkdir's own message and status on failure are the driver's, so both stay in the driver). This planner
# gets that physical directory and the source, and prints the shell statement of modopts (for eval): --modules, the directory
# of the interface files, and, when the source declares "export module NAME;", the interface file it writes. The interface name
# is the scan of scripts/nfcxx-modscan.rb (NfcxxModscan.decl_name, the same as its decl-name command).
# tests/driver-modopts/run.sh checks the planner against the bash lines verbatim, with the real scanner.
#
#   ruby scripts/nfcxx-modopts.rb plan mdir=DIR src=FILE
#       prints modopts=(...) for the driver to eval. DIR is the physical module directory ("" when there is none); every value is
#       quoted so that it survives eval.
#
# A source that cannot be read raises, as the bash's decl-name call did (the driver checks each source first, so this does not
# happen in a build).

require "shellwords"
require_relative "nfcxx-modscan"

module NfcxxModopts
  module_function

  # the modopts statement for the module directory DIR and the source SRC
  def plan(opts)
    dir = opts.fetch("mdir", "")
    src = opts.fetch("src", "")
    mopts = ["--modules", "--modules_directory", dir]
    name = NfcxxModscan.decl_name(src)
    mopts.push("--create_module_interface", "#{dir}/#{name}.eifc") if name
    "modopts=(#{mopts.map { |w| Shellwords.escape(w) }.join(" ")})"
  end
end

if $PROGRAM_NAME == __FILE__
  cmd, *rest = ARGV
  abort "nfcxx-modopts: plan mdir=DIR src=FILE (got #{cmd.inspect})" unless cmd == "plan"
  puts NfcxxModopts.plan(rest.to_h { |kv| kv.split("=", 2) })
end
