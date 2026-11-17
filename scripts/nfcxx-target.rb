#!/usr/bin/env ruby
# --target=NAME (restructure step 3 of docs/notes/driver-body-port.md), ported from the bash block in nfcxx: the EDG target of the
# generated C (with --freestanding --emit-c), its table (EDG_BASE, default build/edg-base, lib_NAME), the target's options to the
# front end (gnu_opts), and the export of EDG_CPFE_DEFAULT_OPTIONS that carries them. linux_k1om has its own block (nfcxx-k1om-env.rb).
# Checked against the bash by tests/driver-target/run.sh.
#
#   ruby scripts/nfcxx-target.rb plan target=NAME freestanding=0|1 emit_c=0|1 root=ROOT gnu_opts=WORD<US>WORD...
#       prints the statements for the driver to eval (gnu_opts+= for the target, and the export), or the refusal on standard error
#       with status 2. EDG_BASE is read from the environment. gnu_opts is the array as the driver has it, joined by ASCII 31.

require "shellwords"

module NfcxxTarget
  module_function

  class Refusal < StandardError; end

  def plan(opts, env)
    target = opts.fetch("target", "")
    export = 'export EDG_CPFE_DEFAULT_OPTIONS="${gnu_opts[*]} ${EDG_CPFE_DEFAULT_OPTIONS:-}"'
    # without a target (or for linux_k1om, which has its own block) only the export of a non-empty gnu_opts remains
    if target.empty? || target == "linux_k1om"
      return opts.fetch("gnu_opts", "").empty? ? "" : export
    end
    freestanding = opts.fetch("freestanding") == "1"
    emit_c = opts.fetch("emit_c") == "1"
    root = opts.fetch("root")
    raise Refusal, "nfcxx: --target needs --freestanding (the host's library headers are the host target's)" unless freestanding
    raise Refusal, "nfcxx: --target needs --emit-c (the generated C is for the target; compile it with a cross compiler)" unless emit_c
    tbase = env["EDG_BASE"].to_s.empty? ? File.join(root, "build/edg-base") : env["EDG_BASE"]
    unless File.directory?(File.join(tbase, "lib_#{target}"))
      tables = Dir.glob(File.join(tbase, "lib_*")).sort.map { |d| "#{File.basename(d).sub(/\Alib_/, "")} " }.join
      raise Refusal, "nfcxx: no EDG target '#{target}' in #{tbase} (lib_* tables: #{tables})"
    end
    added = ["--target", target]
    added << "--unsigned_chars" if %w[linux_aarch64 linux_armv7 linux_riscv32 linux_riscv64].include?(target)
    lines = ["gnu_opts+=(#{added.map { |w| Shellwords.escape(w) }.join(" ")})"]
    # the export: the array's words and the previous value, expanded by the shell when the driver evaluates it (as the bash line)
    lines << export
    lines.join("\n")
  end
end

if $PROGRAM_NAME == __FILE__
  cmd, *rest = ARGV
  abort "nfcxx-target: plan KEY=VALUE... (got #{cmd.inspect})" unless cmd == "plan"
  begin
    out = NfcxxTarget.plan(rest.to_h { |kv| kv.split("=", 2) }, ENV)
    puts out unless out.empty?
  rescue NfcxxTarget::Refusal => e
    warn e.message
    exit 2
  end
end
