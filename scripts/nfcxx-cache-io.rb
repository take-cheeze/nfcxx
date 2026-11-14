#!/usr/bin/env ruby
# The cache's small helpers of the bash driver (nfcxx), ported: the SHA-256 of standard input (cache_sha), the diagnostic
# log line of --cache-log (cache_log), and the remote tier's get and put (cache_remote_get, cache_remote_put, which call the
# Python helper scripts/nfcxx-cache-gha.py). The bash driver's functions call this script with the same arguments.
#
#   ruby scripts/nfcxx-cache-io.rb sha                 the SHA-256 of standard input, as "HEX  -" (sha256sum's form)
#   ruby scripts/nfcxx-cache-io.rb log FILE TEXT...    appends TEXT (joined by spaces, as "$*") and a newline to FILE, under a
#                                                      lock (mkdir FILE.lock), as the bash does
#   ruby scripts/nfcxx-cache-io.rb remote-get KEY ENTRY   fills the directory ENTRY from the remote tier (status 1 on a miss)
#   ruby scripts/nfcxx-cache-io.rb remote-put KEY ENTRY   stores the files of the local entry ENTRY remotely (the build goes on
#                                                         when the store fails, with a note on stderr)
require "digest"
require "fileutils"
require "open3"

ROOT = File.expand_path("..", File.expand_path(File.dirname($0)))
GHA = File.join(ROOT, "scripts", "nfcxx-cache-gha.py")

def python_helper(*args)
  Open3.capture2e("python3", "-I", GHA, *args)
end

cmd, *rest = ARGV
case cmd
when "sha"
  $stdout.write("#{Digest::SHA256.hexdigest($stdin.binmode.read)}  -\n")
when "log"
  file, *text = rest
  exit 0 if file.nil? || file.empty?
  lock = "#{file}.lock"
  sleep 0.05 until (begin
                      Dir.mkdir(lock)
                      true
                    rescue Errno::EEXIST
                      false
                    end)
  begin
    File.open(file, "a") { |f| f.write("#{text.join(' ')}\n") }
  ensure
    Dir.rmdir(lock)
  end
when "remote-get"
  key, entry = rest
  tmp = "#{entry}.remote.#{Process.pid}"
  FileUtils.rm_rf(tmp)
  out, status = python_helper("get", key, tmp)
  $stderr.write(out)
  ok = status.success? && File.file?(File.join(tmp, "obj"))
  if ok
    FileUtils.mkdir_p(File.dirname(entry))
    File.exist?(entry) || (FileUtils.mv(tmp, entry) rescue nil)
  end
  FileUtils.rm_rf(tmp)
  exit(ok ? 0 : 1)
when "remote-put"
  key, entry = rest
  names = ["obj"]
  %w[ti ii].each { |x| names << x if File.file?(File.join(entry, x)) }
  out, status = python_helper("put", key, entry, *names)
  $stderr.write(out)
  unless status.success?
    warn "nfcxx: remote cache: could not store #{key} (the build continues)"
  end
else
  warn "usage: nfcxx-cache-io.rb sha | log FILE TEXT... | remote-get KEY ENTRY | remote-put KEY ENTRY"
  exit 2
end
