#!/usr/bin/env ruby
# macos-stub-tbd.rb INSTALL-NAME OUT.tbd NAMES.txt: writes a clean-room TBD v4 link stub that exports the names in
# NAMES.txt (one Mach-O name per line, with the leading underscore). The names come from the undefined references of
# nfcxx's own test objects (llvm-nm -u), so the stub's contents follow what the objects import and nothing else. It has
# no code and no behaviour: a program linked against it can be checked for its Mach-O shape and its imports, never run.
$stdout.sync = true
$stderr.sync = true

def errno_text(err)
  SystemCallError.new(nil, err.errno).message
end

# set -u: an argument that is not given is the shell's "unbound variable" error (the script's line 7)
%w[$1 $2 $3].each_with_index do |name, i|
  next if ARGV.size > i

  warn "#{$PROGRAM_NAME}: line 7: #{name}: unbound variable"
  exit 1
end
install = ARGV[0].b
out = ARGV[1]
names = ARGV[2]

# syms=$(LC_ALL=C sort -u "$names" | paste -sd, - | sed 's/,/, /g'): sort's failure ends the script with its status
data =
  begin
    names == "-" ? $stdin.binmode.read : File.binread(names)
  rescue SystemCallError => e
    if e.is_a?(Errno::EISDIR)
      warn "sort: read failed: #{names}: #{errno_text(e)}"
    else
      warn "sort: cannot read: #{names}: #{errno_text(e)}"
    end
    exit 2
  end
syms = data.lines.map { |l| l.chomp("\n") }.uniq.sort.join(",").gsub(",", ", ").b

text = [
  "--- !tapi-tbd\n",
  "# Clean-room link stub written by scripts/macos-stub-tbd.rb from the undefined references of nfcxx's C++ test\n",
  "# objects (llvm-nm -u), minus the libSystem stub. Names only: no code and no behaviour; not Apple's library.\n",
  "tbd-version:     4\n",
  "targets:         [ arm64-macos ]\n",
  "install-name:    #{install}\n",
  "current-version: 1\n",
  "compatibility-version: 1\n",
  "exports:\n",
  "  - targets:         [ arm64-macos ]\n",
  "    symbols:         [ #{syms} ]\n",
  "...\n"
].join.b

# } > "$out" (the script's line 22): the file is opened after the names are read
begin
  File.binwrite(out, text)
rescue SystemCallError => e
  warn "#{$PROGRAM_NAME}: line 22: #{out}: #{errno_text(e)}"
  exit 1
end
