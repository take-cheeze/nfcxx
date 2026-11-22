#!/usr/bin/env ruby
# cache_check (restructure step 2 / B5 of docs/notes/driver-body-port.md), ported from the bash in nfcxx: the lookup of the compile
# cache, its cache-log line, the remote tier's fetch on a local miss, and the hit (the object copied back). The driver passes the
# lookup's arguments unchanged (the same --cache-dir, --out, --var and --arg options scripts/nfcxx-cache.rb lookup takes).
#
#   ruby scripts/nfcxx-cache-check.rb check [--statements=FILE] [--remote=KIND] (--records=FILE | LOOKUP-ARGS...)
#       --records=FILE: the lookup's options are planned from FILE, the records of the driver's cache_plan (NUL-separated; the
#       planner is scripts/nfcxx-cache-plan.rb; FILE may be /dev/fd/N), so the driver makes this one call and writes no arguments.
#       writes cache_entry, cc_state (hit, miss or none) and cc_key to FILE for the driver to source, or to stdout when there is
#       no --statements (the driver captures them; the children's output then goes to stderr), and logs the decision
#       (--cache-log). On a local miss with --remote, the remote tier is fetched (scripts/nfcxx-cache-io.rb remote-get); an object
#       then present is a hit, copied back to the output (scripts/nfcxx-cache.rb hit). Exit status 10: the hit was copied, and the
#       driver exits 0; 0: go on. NFCXX_CACHE_IO replaces the remote helper's script (tests/nfcxx-cache/run.sh's stub).
#   ruby scripts/nfcxx-cache-check.rb store --out=OUT --entry=DIR [--remote=KIND]
#       stores the object just built (scripts/nfcxx-cache.rb store); a new entry goes to the remote tier (remote-put, through
#       NFCXX_CACHE_IO as the check's remote-get). Checked by tests/nfcxx-cache/run.sh.

require "shellwords"
require "stringio"
require_relative "nfcxx-cache"
require_relative "nfcxx-cache-plan"

module NfcxxCacheCheck
  module_function

  def ruby = ENV["RUBY"] || RbConfig.ruby

  def helper(*args)
    system(ruby, File.join(__dir__, "nfcxx-cache-io.rb"), *args)
  end

  # the GHA helper of the remote tier: scripts/nfcxx-cache-io.rb, or the NFCXX_CACHE_IO script in its place (the tests' stand-in)
  def remote_helper(*args)
    system(ruby, ENV["NFCXX_CACHE_IO"] || File.join(__dir__, "nfcxx-cache-io.rb"), *args)
  end

  # the --cache-log line: TEXT appended to FILE as one write (scripts/nfcxx-cache-io.rb log); nothing when FILE is empty
  def cache_log(file, text)
    return true if file.nil? || file.empty?
    helper("log", file, text)
  end

  # the remote tier's fetch of KEY into the directory ENTRY (remote-get); true when it filled the entry. A failure is a miss.
  def remote_get(key, entry)
    remote_helper("remote-get", key, entry)
  end

  # the remote tier's store of the entry ENTRY under KEY (remote-put). A failure is a note on stderr (the helper's): the build
  # goes on, so this is always true.
  def remote_put(key, entry)
    remote_helper("remote-put", key, entry)
    true
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
    remote_put(File.basename(entry), entry) if made && !remote.empty?
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
    records = nil
    lookup_args = nil
    remote = ""
    rest = []
    args.each do |a|
      if a.start_with?("--statements=") then statements = a.delete_prefix("--statements=")
      elsif a.start_with?("--remote=") then remote = a.delete_prefix("--remote=")
      elsif a.start_with?("--records=") then records = a.delete_prefix("--records=")
      else rest << a
      end
    end
    lookup_args = rest unless records
    # no --statements: the statements are the stdout (the driver captures them); the children of this check write to stderr, so
    # their output is not mixed into the statements
    stmt_out = nil
    unless statements
      stmt_out = STDOUT.dup
      STDOUT.reopen(STDERR)
    end
    state = "none"
    key = ""
    cache_entry = ""
    opt = nil
    begin
      # the records (cache_plan's, from the driver's file) are planned into the lookup's options; an unknown kind is a note and no cache
      lookup_args = NfcxxCachePlan.plan(NfcxxCachePlan.records_of(File.binread(records))) if records
      opt = parse(["lookup", *lookup_args])[1] unless lookup_args.nil?
      look = opt ? capture_lookup(opt) : ""
      unless look.empty?
        lines = look.chomp.split("\n")
        decision = lines.last
        if lines.size > 1 && !opt[:cache_log].to_s.empty?
          cache_log(opt[:cache_log], lines[0...-1].join("\n"))
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
      remote_get(key, cache_entry) if !remote.empty?
      hit_now = File.file?(File.join(cache_entry, "obj"))
    end
    text = [
      "cache_entry=#{Shellwords.escape(cache_entry)}",
      "cc_state=#{Shellwords.escape(state)}",
      "cc_key=#{Shellwords.escape(key)}",
    ].join("\n") + "\n"
    if statements
      File.write(statements, text)
    else
      stmt_out.write(text)
      stmt_out.flush
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
