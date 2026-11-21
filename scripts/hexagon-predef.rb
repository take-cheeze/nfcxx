#!/usr/bin/env ruby
# Write EDG's linux_hexagon predefined-macro table from clang's Hexagon target:
# scripts/hexagon-predef.rb OUT [CLANG]
# The table is the output of `clang --target=hexagon -dM -E`, in the format of the
# other lib_* tables (tag gnu, flag no). Dropped: function-like macros, and the names
# EDG defines itself or that GCC-only headers need no table for (__cplusplus, __cpp_*,
# __STDC_*, __CHAR16_TYPE__, __WCHAR_TYPE__, __GNUC__ and the gcc version macros):
# EDG rejects some of them redefined. See scripts/win-predef.rb.

require "open3"

FUNCTION_LIKE = /\A#define [A-Za-z_][A-Za-z0-9_]*\(/
DROP = /\A(__cplusplus|__cpp_|__STDC|__CHAR16_TYPE__|__WCHAR_TYPE__|__GNUC|__GNUG|__GXX|__VERSION__|__OPTIMIZE|__CET__|__SEH__|__GCC)/

def run_cc(cc)
  out, err, status = Open3.capture3(cc, "--target=hexagon-unknown-linux-musl",
                                    "-mhvx", "-mhvx-length=128b",
                                    "-dM", "-E", "-x", "c++", "-std=c++23", "/dev/null")
  $stderr.binmode.write(err)
  [out, status.exitstatus || 128 + status.termsig]
rescue Errno::ENOENT
  $stderr.puts "hexagon-predef: #{cc}: command not found"
  ["", 127]
end

out_path = ARGV[0]
if out_path.nil?
  warn "usage: scripts/hexagon-predef.rb OUT [CLANG]"
  exit 1
end
cc = ARGV[1]
cc = "clang-19" if cc.nil? || cc.empty?

cc_out, cc_status = run_cc(cc)

entries = []
cc_out.each_line do |raw|
  line = raw.delete_suffix("\n")
  next if FUNCTION_LIKE.match?(line)
  next unless line.start_with?("#define ")
  name = line.sub(/\A[ \t\n]+/, "").split(/[ \t\n]+/)[1].to_s
  value = line.sub(/\A#define [^ ]+ ?/, "")
  value = "1" if value.empty?
  entry = "#{name}\t#{value}"
  next if DROP.match?(entry)
  parts = entry.split("\t", -1)
  entries << "gnu no  #{parts[0]} #{parts[1]}"
end

header = "# Hexagon: #{cc} --target=hexagon-unknown-linux-musl -dM -E (scripts/hexagon-predef.rb)"
File.binwrite(out_path, ([header] + entries).map { |l| "#{l}\n" }.join)

exit 1 if entries.empty?
exit cc_status
