#!/usr/bin/env ruby
# cache_check (restructure step 2 / B5 of docs/notes/driver-body-port.md), ported from the bash in nfcxx: the lookup of the compile
# cache, its cache-log line, the remote tier's fetch on a local miss, and the hit (the object copied back). The driver passes the
# lookup's arguments unchanged (the same --cache-dir, --out, --var and --arg options scripts/nfcxx-cache.rb lookup takes).
#
#   ruby scripts/nfcxx-cache-check.rb check --statements=FILE [--remote=KIND] LOOKUP-ARGS...
#       writes cache_entry, cc_state (hit, miss or none) and cc_key to FILE for the driver to source, and logs the decision
#       (--cache-log). On a local miss with --remote, the remote tier is fetched (scripts/nfcxx-cache-io.rb remote-get); an object
#       then present is a hit, copied back to the output (scripts/nfcxx-cache.rb hit). Exit status 10: the hit was copied, and the
#       driver exits 0; 0: go on. NFCXX_CACHE_IO replaces the remote helper's script (tests/nfcxx-cache/run.sh's stub).
#   ruby scripts/nfcxx-cache-check.rb store --out=OUT --entry=DIR [--remote=KIND]
#       stores the object just built (scripts/nfcxx-cache.rb store); a new entry goes to the remote tier (remote-put, through
#       NFCXX_CACHE_IO as the check's remote-get). Checked by tests/nfcxx-cache/run.sh.

require "shellwords"
require "stringio"
require_relative "nfcxx-cache"

module NfcxxCacheCheck
  module_function

  def ruby = ENV["RUBY"] || RbConfig.ruby

  def helper(*args)
    system(ruby, File.join(__dir__, "nfcxx-cache-io.rb"), *args)
  end

  # the store of the object just built (nfcxx-cache.rb store). A new entry goes to the remote tier (remote-put; a failure is a
  # note on stderr, and the build goes on). Status 0 always, as the driver's cache_store.
  def store(args)
    out = entry = nil
    remote = ""
    args.each do |a|
      if a.start_with?("--out=") then out = a.delete_prefix("--out=")
      elsif a.start_with?("--entry=") then entry = a.delete_prefix("--entry=")
      elsif a.start_with?("--remote=") then remote = a.delete_prefix("--remote=")
      end
    end
    return 0 if entry.nil? || entry.empty?
    made = system(ruby, File.join(__dir__, "nfcxx-cache.rb"), "store", "--out=#{out}", "--entry=#{entry}")
    if made && !remote.empty?
      system(ruby, ENV["NFCXX_CACHE_IO"] || File.join(__dir__, "nfcxx-cache-io.rb"), "remote-put", File.basename(entry), entry)
    end
    0
  end

  # the hit: the object and its records copied back to the output (nfcxx-cache.rb hit); true when it was copied
  def hit(opt, entry)
    system(ruby, File.join(__dir__, "nfcxx-cache.rb"), "hit", "--out=#{opt[:out]}", "--entry=#{entry}")
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
  # the remote tier's fetch and the hit: the GHA helper's stand-in in tests (NFCXX_CACHE_IO), and nfcxx-cache.rb hit
  def check(args)
    statements = nil
    lookup_args = []
    remote = ""
    args.each do |a|
      if a.start_with?("--statements=") then statements = a.delete_prefix("--statements=")
      elsif a.start_with?("--remote=") then remote = a.delete_prefix("--remote=")
      else lookup_args << a
      end
    end
    state = "none"
    key = ""
    cache_entry = ""
    opt = nil
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
    hit_now = state == "hit"
    if state == "miss" && !cache_entry.empty?
      # a local miss is looked up in the remote tier (a failure is a miss); an object there is a hit
      system(ruby, ENV["NFCXX_CACHE_IO"] || File.join(__dir__, "nfcxx-cache-io.rb"), "remote-get", key, cache_entry) if !remote.empty?
      hit_now = File.file?(File.join(cache_entry, "obj"))
    end
    if statements
      File.write(statements, [
        "cache_entry=#{Shellwords.escape(cache_entry)}",
        "cc_state=#{Shellwords.escape(state)}",
        "cc_key=#{Shellwords.escape(key)}",
      ].join("\n") + "\n")
    end
    return 0 unless hit_now && opt
    hit(opt, cache_entry) ? 10 : 0
  end
end

if $PROGRAM_NAME == __FILE__
  cmd, *rest = ARGV
  case cmd
  when "check" then exit NfcxxCacheCheck.check(rest)
  when "store" then exit NfcxxCacheCheck.store(rest)
  else abort "nfcxx-cache-check: check --statements=FILE [--remote=KIND] LOOKUP-ARGS... | store --out=OUT --entry=DIR [--remote=KIND] (got #{cmd.inspect})"
  end
end
