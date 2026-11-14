#!/usr/bin/env ruby
# Build SQLite (the amalgamation, sqlite3.c) with the project's C compiler into build/sqlite/<backend>/libsqlite3.a,
# with sqlite3.h beside it. nfcc compiles it: qbe (cproc -> QBE, the default), pathb (NFCXX_BACKEND=pathb) or gcc (NFCXX_BACKEND=gcc).
#
# The amalgamation is SQLite 3.54.1, the release zip from sqlite.org. Its published SHA3-256 is
# 92281c86e2957f9b9305890f9ac04204caa7b677cc868dc326d942689df28e30; the SHA-256 pins below are checked before use, and
# a mismatch stops the build. Move the pins together when the version changes.
require "digest"
require "fileutils"
require "tmpdir"

$stdout.sync = true
ZIP_URL = "https://sqlite.org/2026/sqlite-amalgamation-3540100.zip"
ZIP_SHA256 = "0a9c8e34352dad46006aa82836d5383bff9dc6bc9ce5a60553c05aa30e6ad1f9"
C_SHA256 = "0c657666d819f261cc4007526ad57e1669de9949df7a8ea847aa284a2bf0ee52"

# Runs a command as the script's `set -e` does: when it fails, the script ends with its status.
def run!(*cmd)
  system(*cmd)
  status = $?
  exit(status.exitstatus || 1) unless status.success?
end

# stops the script unless the file has the SHA-256 want
def check!(file, want)
  got = Digest::SHA256.file(file).hexdigest
  return if got == want

  warn "setup-sqlite: #{file} has sha256 #{got}, expected #{want}"
  exit 1
end

root = File.expand_path("..", File.dirname(__FILE__))
backend = ENV["NFCXX_BACKEND"]
backend = "pathb" if backend.nil? || backend.empty?
dest = "#{root}/build/sqlite/#{backend}"
src = "#{root}/build/sqlite/src"

FileUtils.mkdir_p(src)
unless File.file?("#{src}/sqlite3.c") && Digest::SHA256.file("#{src}/sqlite3.c").hexdigest == C_SHA256
  Dir.mktmpdir do |tmp|
    run!("curl", "-fsSL", ZIP_URL, "-o", "#{tmp}/amalgamation.zip")
    check!("#{tmp}/amalgamation.zip", ZIP_SHA256)
    run!("unzip", "-q", "#{tmp}/amalgamation.zip", "-d", tmp)
    check!("#{tmp}/sqlite-amalgamation-3540100/sqlite3.c", C_SHA256)
    FileUtils.mv(["#{tmp}/sqlite-amalgamation-3540100/sqlite3.c", "#{tmp}/sqlite-amalgamation-3540100/sqlite3.h"], "#{src}/")
  end
end

# SQLITE_THREADSAFE=1: the serialized mode, safe to share one connection set across threads. SQLITE_DQS=0: a double-quoted
# word is an identifier, never a string literal (the SQL standard's reading).
FileUtils.rm_rf(dest)
FileUtils.mkdir_p(dest)
FileUtils.cp("#{src}/sqlite3.h", "#{dest}/")
run!({ "NFCXX_BACKEND" => backend }, "#{root}/nfcc", "-c", "#{src}/sqlite3.c", "-o", "#{dest}/sqlite3.o",
     "-DSQLITE_THREADSAFE=1", "-DSQLITE_DQS=0")
run!("ar", "rcs", "#{dest}/libsqlite3.a", "#{dest}/sqlite3.o")
# The bundle: the archive, its header and a manifest, so a program links it with -L$dest -lsqlite3. SQLite is in the
# public domain (https://sqlite.org/copyright.html); the manifest says where it came from.
File.write("#{dest}/MANIFEST", <<~MANIFEST)
  name: sqlite
  version: 3.54.1
  backend: #{backend}
  source: #{ZIP_URL}
  source-sha256: #{ZIP_SHA256}
  sqlite3.c-sha256: #{C_SHA256}
  license: public domain (https://sqlite.org/copyright.html)
  files: libsqlite3.a sqlite3.h MANIFEST
MANIFEST
version = File.readlines("#{dest}/sqlite3.h").filter_map { |l| l[/\A#define SQLITE_VERSION *"(.*)"/, 1] }.join("\n")
puts "built #{dest}/libsqlite3.a (SQLite #{version})"
