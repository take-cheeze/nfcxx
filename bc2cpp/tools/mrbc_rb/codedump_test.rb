# frozen_string_literal: true

# codedump.rb (the instruction listing of `mrbc -v`) against the fork's mrbc: the text after the C parser's AST dump, from
# the first `irep` line on, with the irep addresses replaced. Every file of bc2cpp/ and every gem's mrblib set.
#   MRBC=<fork mrbc> bundle exec ruby bc2cpp/tools/mrbc_rb/codedump_test.rb
# Needs MRBC (SKIP otherwise). MRBC_RB_CLI_SAMPLE=n checks every n-th input only.

require 'open3'
require_relative 'mrbc_rb'
require_relative 'rite_dump'
require_relative 'codedump'

oracle = ENV.fetch('MRBC', nil)
unless oracle && File.executable?(oracle)
  puts 'SKIP: set MRBC to the fork mrbc to run the codedump check'
  exit 0
end

mruby_dir = File.expand_path('../..', oracle)
world_root = File.expand_path('../..', mruby_dir)
sets = { 'core mrblib' => Dir["#{mruby_dir}/mrblib/*.rb"].sort.reject { |p| p.end_with?('/10error.rb') } }
(Dir["#{mruby_dir}/mrbgems/*"] + Dir["#{world_root}/3rd/*"] + Dir["#{world_root}/mruby-*"]).sort.each do |gem_dir|
  sets[File.basename(gem_dir)] = Dir["#{gem_dir}/mrblib/**/*.rb"].sort
end
sets.reject! { |_, files| files.empty? }
inputs = sets.to_a + Dir.glob('bc2cpp/**/*.rb').sort.map { |f| [f, [f]] }
sample = Integer(ENV.fetch('MRBC_RB_CLI_SAMPLE', '1'))
inputs = inputs.each_with_index.select { |(_, files), i| files.size > 1 || (i % sample).zero? }.map(&:first)

# Constructs the corpus may lack: catch tables, many registers (OP_EXT), floats, odd symbols and strings.
require 'tmpdir'
snippets = {
  'rescue' => "begin\n  raise 'x'\nrescue ArgumentError, TypeError => e\n  p e\nensure\n  p 1\nend\n",
  'ext' => (1..300).map { |i| "v#{i} = #{i}\n" }.join + "p v1 + v300\n",
  'literals' => "p 1.5, -2.25e10, 4294967296, -70000, 'a\\0b', :\"a b\", :+, :[]=, :a?, :A=, \"caf\\u00e9\"\n",
  'kwargs' => "def f(a, b = 1, *r, c, k: 2, **o, &blk); end\nf(1, 2, k: 3)\n"
}
snip_dir = Dir.mktmpdir('codedump')
snippets.each do |name, src|
  File.write(File.join(snip_dir, "#{name}.rb"), src)
  inputs << [name, [File.join(snip_dir, "#{name}.rb")]]
end

norm = ->(t) { t.b.gsub(/^irep 0x[0-9a-f]+/, 'irep ADDR') }
failures = 0
checked = 0
inputs.each do |name, paths|
  img = begin
    paths.size == 1 ? MrbcRb.compile(File.binread(paths.first), paths.first) : MrbcRb.compile_files(paths.map { |p| [File.binread(p), p] })
  rescue MrbcRb::Error
    next
  end
  out, _err, st = Open3.capture3(oracle, '-v', '-o', '/dev/null', *paths, binmode: true)
  next unless st.success?

  expected = out.b[/^irep 0x.*/m]
  got = MrbcRb::Codedump.listing(MrbcRb::RiteDump.parse(img))
  checked += 1
  next if norm.call(got) == norm.call(expected)

  failures += 1
  e = norm.call(expected).lines
  g = norm.call(got).lines
  i = e.zip(g).index { |x, y| x != y } || [e.size, g.size].min
  puts "FAIL #{name}: line #{i}: oracle #{e[i].inspect} vs #{g[i].inspect}"
  break if failures >= 5
end
puts failures.zero? ? "codedump: #{checked} inputs identical to mrbc -v's listing" : "#{failures} codedump difference(s) in #{checked} inputs"
exit(failures.zero? ? 0 : 1)
