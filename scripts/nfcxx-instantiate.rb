#!/usr/bin/env ruby
# nfcxx's --instantiate choice (stage B3 of docs/notes/driver-body-port.md), ported from the bash in nfcxx: auto leaves the
# template instantiation to the front end; used asks for the used instantiations only, with the sections the linker can
# collect (not on Mach-O, which coalesces weak definitions itself). Checked against the bash by tests/driver-instantiate/run.sh.
#
#   ruby scripts/nfcxx-instantiate.rb plan instantiate=auto|used|OTHER sys=UNAME_S
#       prints the shell statement inst_opts=(...), or the refusal on standard error with status 2.

require "shellwords"

module NfcxxInstantiate
  module_function

  def plan(instantiate, sys)
    case instantiate
    when "auto" then "inst_opts=()"
    when "used"
      words = ["--no_auto_instantiation", "-tused"]
      unless sys == "Darwin"
        words += ["--c_to_obj_option", "-ffunction-sections", "--c_to_obj_option", "-fdata-sections",
                  "--c_to_obj_option", "-Wl,--gc-sections"]
      end
      "inst_opts=(#{words.map { |w| Shellwords.escape(w) }.join(" ")})"
    else
      raise ArgumentError, "nfcxx: --instantiate (NFCXX_INSTANTIATE) is auto or used (got #{instantiate})"
    end
  end
end

if $PROGRAM_NAME == __FILE__
  cmd, *rest = ARGV
  abort "nfcxx-instantiate: plan KEY=VALUE... (got #{cmd.inspect})" unless cmd == "plan"
  opts = rest.to_h { |kv| kv.split("=", 2) }
  begin
    puts NfcxxInstantiate.plan(opts.fetch("instantiate", ""), opts.fetch("sys", ""))
  rescue ArgumentError => e
    warn e.message
    exit 2
  end
end
