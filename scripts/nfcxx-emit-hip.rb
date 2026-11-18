#!/usr/bin/env ruby
# nfcxx's --emit-hip option filter (docs/notes/driver-body-port.md). The driver passed the -I, -D and -U options of the
# cflags to the rewriter (tools/cuda-rewrite --hip) with a case in bash:
#   for f in ${cflags[@]+"${cflags[@]}"}; do case $f in -I*|-D*|-U*) hip_opts+=("$f");; esac; done
# This keeps the same words, in the same order, and prints them NUL-terminated (one NUL after each word), so a word
# with a newline or a space stays intact. The driver reads them back with while IFS= read -r -d ''.
# tests/driver-emithip/run.sh checks the port against the bash case verbatim.
#
#   ruby scripts/nfcxx-emit-hip.rb plan [CFLAG...]
#
# A word is kept when it starts with -I, -D or -U, so the bare -I, -D and -U are kept too (the bash pattern -I* matches
# "-I"). The empty word and every other word are dropped (the bash case does not match "").

module NfcxxEmitHip
  module_function

  PREFIXES = ["-I".b, "-D".b, "-U".b].freeze

  # the words of CFLAGS that the rewriter gets, in order (binary strings)
  def hip_options(cflags)
    cflags.map(&:b).select { |w| PREFIXES.any? { |p| w.start_with?(p) } }
  end
end

if $PROGRAM_NAME == __FILE__
  if ARGV.first != "plan"
    warn "usage: nfcxx-emit-hip.rb plan [CFLAG...]"
    exit 2
  end
  $stdout.binmode.write(*NfcxxEmitHip.hip_options(ARGV.drop(1)).map { |w| w + "\0".b })
end
