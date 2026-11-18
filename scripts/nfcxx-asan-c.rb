#!/usr/bin/env ruby
# nfcxx's ASan options for the C compiles and links of a program (the block after the -fsanitize=address check in the driver,
# docs/notes/driver-body-port.md). With ASAN=1 the backend must be gcc or pathb; the options are the ASan flags followed by
# ASANOPTS. Otherwise ASANOPTS is empty and no option is added. The bash was
#   if [ $asan = 1 ]; then case $backend in gcc) ;; pathb) ;; *) echo "nfcxx: -fsanitize=address: unknown backend $backend" >&2; exit 2 ;; esac
#     asan_c=(-fsanitize=address -fno-omit-frame-pointer ${asanopts[@]+...}); else asanopts=(); fi
# tests/driver-asanc/run.sh checks the port against that bash verbatim.
#
#   ruby scripts/nfcxx-asan-c.rb plan asan=0|1 backend=NAME asanopts=OPT...   (one asanopts= per option)
require "shellwords"

module NfcxxAsanC
  module_function

  # [asan_c, asanopts] as shell words (values quoted by the caller); raises Refusal for an unknown backend
  class Refusal < StandardError
    attr_reader :status
    def initialize(message, status = 2)
      super(message)
      @status = status
    end
  end

  def plan(asan:, backend:, asanopts:)
    return [[], []] unless asan == "1"

    raise Refusal, "nfcxx: -fsanitize=address: unknown backend #{backend}" unless %w[gcc pathb].include?(backend)

    [["-fsanitize=address", "-fno-omit-frame-pointer", *asanopts], asanopts]
  end
end

if $PROGRAM_NAME == __FILE__
  abort "usage: nfcxx-asan-c.rb plan asan=0|1 backend=NAME asanopts=OPT..." unless ARGV.first == "plan"
  kv = ARGV.drop(1).map { |a| a.split("=", 2) }
  asan = kv.find { |k, _| k == "asan" }&.last.to_s
  backend = kv.find { |k, _| k == "backend" }&.last.to_s
  asanopts = kv.select { |k, _| k == "asanopts" }.map(&:last)
  begin
    asan_c, opts = NfcxxAsanC.plan(asan: asan, backend: backend, asanopts: asanopts)
  rescue NfcxxAsanC::Refusal => e
    warn e.message
    exit e.status
  end
  puts "asan_c=(#{asan_c.map { |w| Shellwords.escape(w) }.join(" ")})" if asan == "1"
  puts "asanopts=(#{opts.map { |w| Shellwords.escape(w) }.join(" ")})" if asan != "1"
end
