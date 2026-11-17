#!/usr/bin/env ruby
# The include directories of nfcxx's --emit-c front end run (the block that prints the generated C): the host's system
# directories (or the freestanding library), then EDG's own include, and the user's -I directories in front of them, each made
# absolute (abs_path: its directory's physical path, then its basename, as the bash had it). The bash built this array with
# abs_path per -I; tests/driver-emit-c/run.sh checks the port against that bash verbatim.
#
#   ruby scripts/nfcxx-emit-c.rb inc BASE ROOT FREESTANDING -- SYS_INC... -- FILES...
#       prints the array's elements, each followed by a NUL byte; FREESTANDING is 1 or 0.

module NfcxxEmitC
  module_function

  # abs_path (nfcxx): the directory's physical path, then the basename; a directory that does not exist gives the argument as is
  def abs_path(path)
    dir = File.dirname(path)
    base = File.basename(path)
    return path unless File.directory?(dir)

    "#{File.realpath(dir)}/#{base}"
  rescue SystemCallError
    path
  end

  def inc(base:, root:, freestanding:, sys_inc:, files:)
    inc = freestanding == "1" ? ["-I#{root}/lib"] : sys_inc + ["--sys_include=#{base}/include"]
    files.each do |x|
      next unless x.start_with?("-I") && x.length >= 3   # bash: case $x in -I?*)

      inc.unshift("-I#{abs_path(x.delete_prefix("-I"))}")
    end
    inc
  end
end

if $PROGRAM_NAME == __FILE__
  cmd, *rest = ARGV
  abort "nfcxx-emit-c: inc BASE ROOT FREESTANDING -- SYS_INC... -- FILES... (got #{cmd.inspect})" unless cmd == "inc"
  base, root, freestanding, *tail = rest
  first = tail.index("--")
  second = first && (rel = tail[(first + 1)..].index("--")) && first + 1 + rel
  abort "nfcxx-emit-c: inc needs two -- separators" unless first && second
  sys_inc = tail[(first + 1)...second]
  files = tail[(second + 1)..] || []
  NfcxxEmitC.inc(base: base, root: root, freestanding: freestanding, sys_inc: sys_inc, files: files)
    .each { |x| $stdout.write(x, "\0") }
end
