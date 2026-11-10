# frozen_string_literal: true

# bc2cpp's own loader, fed by the Ruby emitter (BC2CPP_MRBC_RB=1) and by the fork's mrbc, must load the same ireps:
# this is the seam bc2cpp uses (run_mrbc in bc2cpp/tools/bc2cpp/irep.rb). Needs MRBC=<fork mrbc>; SKIP otherwise.
#   MRBC=<mrbc> bundle exec ruby bc2cpp/tools/mrbc_rb/integration_test.rb

require 'tmpdir'
require_relative '../bc2cpp/irep'

oracle = ENV.fetch('MRBC', nil)
unless oracle && File.executable?(oracle)
  puts 'SKIP: set MRBC to the fork mrbc to run the integration check'
  exit 0
end

# Each case is its files in command-line order (several files are one program to mrbc).
SOURCES = {
  'simple.rb' => { 'simple.rb' => "x = 1\nif x\n  p x\nelse\n  p 2\nend\n" },
  'strings.rb' => { 'strings.rb' => "x = \"ab\"\ny = [x, 2]\np y\n" },
  'unless.rb' => { 'unless.rb' => "x = nil\nunless x\n  p 1\nend\n" },
  'multi' => { 'm1.rb' => "x = 1\ndef f(a); a + x; end\n", 'm2.rb' => "y = x\np y, __FILE__\n", 'm3.rb' => "# c\nclass A\n  def g; 1; end\nend\nz = y\n" }
}.freeze

failures = 0
SOURCES.each do |name, files|
  Dir.mktmpdir('mrbc_rb_int') do |dir|
    files.each { |file, src| File.binwrite(File.join(dir, file), src) }
    names = files.keys
    Dir.chdir(dir) do
      ENV.delete('BC2CPP_MRBC_RB')
      ENV['MRBC'] = oracle
      mrbc_ireps, mrbc_root = compile_ireps(names, 'int', dir, mrbc: oracle)
      ENV['BC2CPP_MRBC_RB'] = '1'
      emitter_ireps, emitter_root = compile_ireps(names, 'int', dir)
      ENV.delete('BC2CPP_MRBC_RB')
      # The emitter must take the file itself, or the comparison would only be mrbc against mrbc.
      covered = !mrbc_rb_image(names).nil?
      failures += 1 unless covered
      same = covered && mrbc_root == emitter_root && mrbc_ireps.keys.sort == emitter_ireps.keys.sort &&
             mrbc_ireps.keys.all? { |k| mrbc_ireps[k].instructions == emitter_ireps[k].instructions && mrbc_ireps[k].pool == emitter_ireps[k].pool && mrbc_ireps[k].syms == emitter_ireps[k].syms }
      if same
        puts "ok   #{name}: #{mrbc_ireps.size} irep(s) load the same, from the emitter"
      else
        failures += 1
        puts "FAIL #{name}"
      end
    end
  end
end
puts failures.zero? ? "all #{SOURCES.size} integration cases match" : "#{failures} integration case(s) differ"
exit(failures.zero? ? 0 : 1)
