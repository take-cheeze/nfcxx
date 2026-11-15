#!/usr/bin/env ruby
# A stand-in for scripts/nfcxx-cache-gha.rb in tests/nfcxx-cache-io/run.sh: the same command line (get KEY DIR; put KEY DIR
# FILE...) and exit codes, with the answer chosen by FAKE_GHA (hit, miss, error, put-ok, put-fail). It writes its output to
# stdout and stderr as the real client does, and a put appends its arguments to FAKE_GHA_LOG (relative to the working
# directory), so the test can compare the calls the bash and the Ruby make.
mode = ENV.fetch("FAKE_GHA", "miss")
cmd, key, dir, *files = ARGV

case cmd
when "get"
  case mode
  when "hit"
    require "fileutils"
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "obj"), "FAKE OBJ #{key}\n")
    File.write(File.join(dir, "ti"), "FAKE TI\n")
    File.write(File.join(dir, "ii"), "FAKE II\n")
    puts "fake get #{key}"
    exit 0
  when "error"
    puts "fake get out"
    warn "fake get: boom"
    exit 2
  else
    exit 1
  end
when "put"
  File.open(ENV.fetch("FAKE_GHA_LOG"), "a") { |f| f.write("put #{key} #{dir} #{files.join(' ')}\n") }
  if mode == "put-fail"
    warn "fake put: refused"
    exit 2
  end
  puts "fake put out"
  exit 0
else
  warn "usage: fake-gha.rb get|put ..."
  exit 2
end
