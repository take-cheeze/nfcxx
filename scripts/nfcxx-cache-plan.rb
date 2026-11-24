#!/usr/bin/env ruby
# nfcxx's compile-cache lookup arguments: the options that nfcxx's cache_check passes to scripts/nfcxx-cache.rb lookup, planned
# from records on stdin (the bash driver writes them; see cache_plan in tests/driver-body/nfcxx-oracle.sh). Each record is one kind
# letter and its payload, NUL-terminated; the options are printed the same way, in the records' order:
#   o NAME=VALUE   --NAME=VALUE                 (cache-dir, cache-log, out, src, cwd)
#   v NAME=VALUE   --var=NAME=VALUE             (the loop state the key and the lookup read)
#   a ARG          --arg=ARG, unless ARG is a cache option (--cache=, --cache-log=, --time-log=, --trace=: nfcxx leaves them out of the key)
#   s STD          --cpp=-std=STD without its leading "--" (the host preprocessor's -std)
#   f FLAG         --cpp=FLAG                   (the cflags)
#   p FILE         --cpp=-include --cpp=FILE    (a forced include)
#   d DIR          --cpp=-isystemDIR            (a system directory)
#
#   ruby scripts/nfcxx-cache-plan.rb < records
# NfcxxCachePlan.plan(records) is the same planner for scripts/nfcxx-cache-check.rb (--records).
#
# A record of another kind is a usage error: nothing is printed and the status is 2.

CACHE_OPTIONS = %w[--cache= --cache-log= --time-log= --trace=].freeze

module NfcxxCachePlan
  module_function

  # The options of the records (in their order), or nil, with a note on stderr, for a record of an unknown kind.
  def plan(records)
    out = []
    records.each do |rec|
      kind = rec[0]
      value = rec[1..] || ""
      case kind
      when "o" then out << "--#{value}"
      when "v" then out << "--var=#{value}"
      when "a"
        next if CACHE_OPTIONS.any? { |opt| value.start_with?(opt) }
        out << "--arg=#{value}"
      when "s" then out << "--cpp=-std=#{value.delete_prefix("--")}"
      when "f" then out << "--cpp=#{value}"
      when "p" then out << "--cpp=-include" << "--cpp=#{value}"
      when "d" then out << "--cpp=-isystem#{value}"
      else
        warn "nfcxx-cache-plan: no record kind #{kind.inspect}"
        return nil
      end
    end
    out
  end

  # The records of NUL-separated text (the last record is NUL-terminated: nothing follows it).
  def records_of(text)
    records = text.split("\0", -1)
    records.pop if records.last == ""
    records
  end
end

if $PROGRAM_NAME == __FILE__
  options = NfcxxCachePlan.plan(NfcxxCachePlan.records_of($stdin.read))
  exit 2 if options.nil?

  options.each { |opt| $stdout.write(opt + "\0") }
end
