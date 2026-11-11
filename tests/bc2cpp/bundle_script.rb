#!/usr/bin/env ruby
# Bundles a script and the scripts it loads with require_relative into one file for a bc2cpp script world, which takes a
# single script. usage: bundle_script.rb OUT MAIN REQUIRED... (REQUIRED in load order, dependencies first).
# Each required file loses its require_relative lines for bundled files and its command-line guard (the `exit(main(ARGV))
# if $PROGRAM_NAME == __FILE__` line or the `if $0 == __FILE__ ... end` block) and its top-level `def main` is renamed
# (the compiled world takes one definition of a method); the main script's guard becomes the world tail `rc = main(ARGV)` /
# `exit(rc) if rc != 0`.
out, main, *reqs = ARGV
abort "usage: bundle_script.rb OUT MAIN REQUIRED..." unless out && main
names = (reqs + [main]).map { |f| File.basename(f, ".rb") }
strip = lambda do |f|
  s = File.read(f)
  s = s.lines.reject { |l| l =~ /\Arequire_relative ['"]([^'"]+)['"]/ && names.include?($1.sub(/\.rb\z/, "")) }.join
  s = s.gsub(/^# [^\n]*\n(?=if \$0 == __FILE__)/, "").sub(/^if \$0 == __FILE__\n.*?^end\n/m, "")
  s = s.sub(/^exit\(main\(ARGV\)\) if \$PROGRAM_NAME == __FILE__\n/, "")
  f == main ? s : s.gsub(/^def main\(/, "def main_of_#{File.basename(f, '.rb').tr('-', '_')}(")
end
body = reqs.map { |f| strip.(f) }.join("\n") + "\n" + strip.(main)
File.write(out, body.rstrip + "\n\nrc = main(ARGV)\nexit(rc) if rc != 0\n")
