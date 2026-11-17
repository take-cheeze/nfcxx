#!/usr/bin/env ruby
# cu_prepare's apply (restructure step 2/B4 of docs/notes/driver-body-port.md), ported from the bash in nfcxx: the planner
# scripts/nfcxx-cuda-device.rb --cu-prepare answers with records (k GROUP, v VALUE, x MESSAGE, z end). This reads them from stdin
# and prints the driver's array state: each input's -I directory goes into cflags and files, each input's copy replaces the
# input in srcs and files, and the cuda and preinc groups become cuda_opts and preinc. A refusal ends with status 2; a reply
# without its end marker ends with status 1. Checked against the bash by tests/driver-cu-apply/run.sh.
#
#   ruby scripts/nfcxx-cu-apply.rb plan inputs=A<US>B srcs=... files=... cflags=... < REPLY
#       (every list is joined by ASCII 31, as the driver passes its arrays)

require "shellwords"

module NfcxxCuApply
  module_function

  def split(s) = s.to_s.split("\x1f", -1).reject(&:empty?)

  def plan(opts, reply)
    inputs = split(opts["inputs"])
    srcs = split(opts["srcs"])
    files = split(opts["files"])
    cflags = split(opts["cflags"])
    groups = Hash.new { |h, k| h[k] = [] }
    group = nil
    done = false
    reply.split("\0").each do |rec|
      # the bash: k*, v*, x* by their first letter; z only as the whole record
      if rec == "z"
        done = true
      elsif rec.start_with?("k")
        group = rec[1..]
      elsif rec.start_with?("v")
        groups[group] << rec[1..] if %w[sdirs copies cuda preinc].include?(group)
      elsif rec.start_with?("x")
        warn rec[1..]
        raise SystemExit.new(2)
      end
    end
    unless done
      warn "nfcxx: scripts/nfcxx-cuda-device.rb stopped before its end (the .cu inputs are incomplete)"
      raise SystemExit.new(1)
    end
    inputs.each_with_index do |src, idx|
      copy = groups["copies"][idx].to_s
      sdir = "-I#{groups["sdirs"][idx]}"
      cflags << sdir
      files << sdir
      srcs.map! { |x| x == src ? copy : x }
      files.map! { |x| x == src ? copy : x }
    end
    [
      "srcs=(#{srcs.map { |w| Shellwords.escape(w) }.join(" ")})",
      "files=(#{files.map { |w| Shellwords.escape(w) }.join(" ")})",
      "cflags=(#{cflags.map { |w| Shellwords.escape(w) }.join(" ")})",
      "cuda_opts=(#{groups["cuda"].map { |w| Shellwords.escape(w) }.join(" ")})",
      "preinc=(#{groups["preinc"].map { |w| Shellwords.escape(w) }.join(" ")})",
    ].join("\n")
  end
end

if $PROGRAM_NAME == __FILE__
  cmd, *rest = ARGV
  abort "nfcxx-cu-apply: plan KEY=VALUE... < REPLY (got #{cmd.inspect})" unless cmd == "plan"
  begin
    puts NfcxxCuApply.plan(rest.to_h { |kv| kv.split("=", 2) }, $stdin.read)
  rescue SystemExit => e
    exit e.status
  end
end
