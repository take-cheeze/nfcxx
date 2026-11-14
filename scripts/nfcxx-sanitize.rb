#!/usr/bin/env ruby
# nfcxx's post-loop check of -fsanitize=CHECKS (the block after the argument loop that validates the UBSan check names,
# refuses a freestanding build, and sends the build to Path B). Ported from the bash block that starts with
#   if [ -n "$sanitize" ]; then
# and ends with its "fi" (tests/nfcxx-sanitize/run.sh checks the two against each other, with the bash block taken from nfcxx).
#
#   ruby scripts/nfcxx-sanitize.rb SANITIZE FREESTANDING BACKEND
#   prints the error message nfcxx prints (if any), then, on success, "backend=B pb_flags=F", then "status=N"
#
# The check names are the ones the bash lists. The command line's -fsanitize=address is not this block's (it has its own case).

IMPLEMENTED = %w[undefined signed-integer-overflow integer-divide-by-zero shift bounds null unreachable return float-cast-overflow].freeze

# bash's IFS=, read -ra: a trailing empty field after the last comma is dropped; empty fields between commas are kept
def split_checks(text)
  parts = text.split(",", -1)
  parts.pop if parts.last == ""
  parts
end

# returns [status, message, backend, pb_flags]
def sanitize_block(sanitize, freestanding, backend)
  return [0, nil, backend, []] if sanitize.empty?
  split_checks(sanitize).each do |c|
    next if IMPLEMENTED.include?(c)
    return [2, "nfcxx: -fsanitize=#{c} is not supported (implemented: #{IMPLEMENTED.join(", ")})", backend, []]
  end
  return [2, "nfcxx: -fsanitize needs Path B, which compiles hosted programs only", backend, []] unless freestanding == "0"
  [0, nil, "pathb", ["--sanitize=#{sanitize}"]]
end

if $PROGRAM_NAME == __FILE__
  sanitize, freestanding, backend = ARGV
  status, message, backend, pb_flags = sanitize_block(sanitize.to_s, freestanding.to_s, backend.to_s)
  $stdout.write("#{message}\n") if message
  $stdout.write("backend=#{backend} pb_flags=#{pb_flags.join(" ")}\n") if status == 0
  $stdout.write("status=#{status}\n")
  exit(0)
end
