#!/usr/bin/env ruby
# The remote helper's stand-in for tests/nfcxx-cache/run.sh (the check's NFCXX_CACHE_IO): answers the remote-get of
# scripts/nfcxx-cache-io.rb as the bash harness's stub did. CACHE_TEST_REMOTE=hit fills the entry with an object; the default is a
# miss (status 1). It prints the same RUN line the harness printed for the bash call, so the decisions match.
require "fileutils"

io = File.expand_path("../../scripts/nfcxx-cache-io.rb", __dir__)
cmd, key, entry = ARGV
case cmd
when "remote-put"
  puts "RUN ruby #{io} remote-put #{key} #{entry}"
  exit 0
when "remote-get"
  puts "RUN ruby #{io} remote-get #{key} #{entry}"
else
  exit 2
end
exit 1 unless ENV.fetch("CACHE_TEST_REMOTE", "miss") == "hit"
unless File.exist?(entry)
  FileUtils.mkdir_p(entry)
  File.write(File.join(entry, "obj"), "OBJECT remote\n")
end
exit 0
