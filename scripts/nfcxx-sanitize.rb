#!/usr/bin/env ruby
# nfcxx's -fsanitize= validation (stage B3 of docs/notes/driver-body-port.md), ported from the bash in nfcxx: every check name
# must be one Path B implements, and the checks need a hosted program (Path B compiles hosted programs only). Checked against
# the bash by tests/driver-body/run.sh's sanitize cases.
#
#   ruby scripts/nfcxx-sanitize.rb check SANITIZE FREESTANDING
#       SANITIZE: the -fsanitize= value ("" when none); FREESTANDING: 0 or 1. Exit 0 when the request is accepted, else the
#       message on standard error and exit 2 (the messages nfcxx gave before).

IMPLEMENTED = %w[undefined signed-integer-overflow integer-divide-by-zero shift bounds null unreachable return float-cast-overflow].freeze

def check(sanitize, freestanding)
  return nil if sanitize.empty?
  sanitize.split(",").each do |c|
    next if IMPLEMENTED.include?(c)
    return "nfcxx: -fsanitize=#{c} is not supported (implemented: #{IMPLEMENTED.join(', ')})"
  end
  return "nfcxx: -fsanitize needs Path B, which compiles hosted programs only" if freestanding != "0"
  nil
end

if $PROGRAM_NAME == __FILE__
  cmd, sanitize, freestanding = ARGV
  abort "nfcxx-sanitize: check SANITIZE FREESTANDING" unless cmd == "check" && freestanding
  msg = check(sanitize, freestanding)
  if msg
    warn msg
    exit 2
  end
end
