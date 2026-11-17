#!/usr/bin/env ruby
# cache_check (restructure step 2 / B5 of docs/notes/driver-body-port.md), ported from the bash in nfcxx: the lookup of the compile
# cache, its cache-log line, the remote tier's fetch on a local miss, and the hit (the object copied back). The driver passes the
# lookup's arguments unchanged (the same --cache-dir, --out, --var and --arg options scripts/nfcxx-cache.rb lookup takes).
#
#   ruby scripts/nfcxx-cache-check.rb check --statements=FILE LOOKUP-ARGS...
#       writes cache_entry, cc_state (hit, miss or none) and cc_key to FILE for the driver to source, and logs the decision
#       (--cache-log). The driver makes the remote fetch and the hit itself. Checked by tests/nfcxx-cache/run.sh.

require "shellwords"
require "stringio"
require_relative "nfcxx-cache"

module NfcxxCacheCheck
  module_function

  def ruby = ENV["RUBY"] || RbConfig.ruby

  def helper(*args)
    system(ruby, File.join(__dir__, "nfcxx-cache-io.rb"), *args)
  end

  def capture_lookup(opt)
    buf = StringIO.new
    old = $stdout
    $stdout = buf
    begin
      lookup(opt)
    ensure
      $stdout = old
    end
    buf.string
  end

  # the lookup and its log line: the decision (state hit or miss, and the key) for the driver, which makes the remote fetch and
  # the hit itself (the driver's cache_remote_get and nfcxx-cache.rb hit, so the functions the tests set around them still run)
  def check(args)
    statements = nil
    lookup_args = []
    args.each do |a|
      if a.start_with?("--statements=") then statements = a.delete_prefix("--statements=")
      else lookup_args << a
      end
    end
    state = "none"
    key = ""
    cache_entry = ""
    begin
      opt = parse(["lookup", *lookup_args])[1]
      look = capture_lookup(opt)
      unless look.empty?
        lines = look.chomp.split("\n")
        decision = lines.last
        if lines.size > 1 && !opt[:cache_log].to_s.empty?
          helper("log", opt[:cache_log], lines[0...-1].join("\n"))
        end
        state, key = decision.split(" ", 2)
        key = key.to_s
        cache_entry = File.join(opt[:cache_dir], "objects", key)
      end
    rescue Fatal => e
      warn e.message
      state = "none"
    end
    if statements
      File.write(statements, [
        "cache_entry=#{Shellwords.escape(cache_entry)}",
        "cc_state=#{Shellwords.escape(state)}",
        "cc_key=#{Shellwords.escape(key)}",
      ].join("\n") + "\n")
    end
    0
  end
end

if $PROGRAM_NAME == __FILE__
  cmd, *rest = ARGV
  abort "nfcxx-cache-check: check --statements=FILE [--remote] LOOKUP-ARGS... (got #{cmd.inspect})" unless cmd == "check"
  exit NfcxxCacheCheck.check(rest)
end
