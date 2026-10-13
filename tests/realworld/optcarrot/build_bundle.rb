# Concatenates upstream optcarrot (mame/optcarrot, unmodified) with shims.rb and runner_tail.rb into one script, because
# mruby has no require_relative. Files go in the order optcarrot.rb loads them (nes.rb before cpu.rb, opt.rb before
# cpu.rb and ppu.rb); require_relative lines are dropped since the concatenation is the loading.
# Usage: ruby build_bundle.rb OPTCARROT_DIR OUT_FILE
dir, out_file = ARGV
abort "usage: #{$PROGRAM_NAME} OPTCARROT_DIR OUT_FILE" unless dir && out_file
here = __dir__
files = %w[optcarrot.rb nes.rb rom.rb pad.rb opt.rb cpu.rb apu.rb ppu.rb palette.rb driver.rb config.rb]
File.open(out_file, 'w') do |out|
  out.write(File.read(File.join(here, 'shims.rb')))
  files.each do |f|
    path = f == 'optcarrot.rb' ? File.join(dir, 'lib', f) : File.join(dir, 'lib/optcarrot', f)
    File.foreach(path) { |line| out.write(line) unless line =~ /^\s*require_relative\b/ }
    out.write("\n")
  end
  out.write(File.read(File.join(here, 'runner_tail.rb')))
end
