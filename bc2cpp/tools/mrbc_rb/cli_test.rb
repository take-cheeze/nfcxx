# frozen_string_literal: true

# bin/mrbc_rb must write what the fork's mrbc writes, byte for byte, for every flag combination real builds use
# (mruby's own gem build runs `mrbc -B<sym> -o- -S [-s] files...`; bc2cpp runs `mrbc -g -o x.mrb files...`).
#   MRBC=<fork mrbc> bundle exec ruby bc2cpp/tools/mrbc_rb/cli_test.rb
# Needs MRBC (SKIP otherwise). Two parts: the dump functions on the corpus (every file of bc2cpp/ and every gem's mrblib set,
# in-process), and the command itself (subprocess) on a few inputs, including the fallback and failure behaviour.

require 'tmpdir'
require 'open3'
require 'rbconfig'
require_relative 'mrbc_rb'
require_relative 'rite_dump'

oracle = ENV.fetch('MRBC', nil)
unless oracle && File.executable?(oracle)
  puts 'SKIP: set MRBC to the fork mrbc to run the CLI check'
  exit 0
end

CLI = File.expand_path('bin/mrbc_rb', __dir__)
D = MrbcRb::RiteDump

# [flags the oracle gets, lambda image -> expected output of the dump functions] per combination.
COMBOS = [
  [%w[-o-], ->(img) { D.strip(img, debug: false, lvar: true) }],
  [%w[-g -o-], ->(img) { D.strip(img, debug: true, lvar: true) }],
  [%w[--remove-lv -o-], ->(img) { D.strip(img, debug: false, lvar: false) }],
  [%w[-g --remove-lv -o-], ->(img) { D.strip(img, debug: true, lvar: false) }],
  [%w[-Bsym -o-], ->(img) { D.cfunc(D.strip(img, debug: false, lvar: true), 'sym') }],
  [%w[-Bsym -s -o-], ->(img) { D.cfunc(D.strip(img, debug: false, lvar: true), 'sym', static: true) }],
  [%w[-g -Bsym -o-], ->(img) { D.cfunc(D.strip(img, debug: true, lvar: true), 'sym') }],
  [%w[-Bsym -S -o-], ->(img) { D.cstruct(D.strip(img, debug: false, lvar: true), 'sym') }],
  [%w[-Bsym -S -s -o-], ->(img) { D.cstruct(D.strip(img, debug: false, lvar: true), 'sym', static: true) }],
  [%w[-Bsym -S -s --remove-lv -o-], ->(img) { D.cstruct(D.strip(img, debug: false, lvar: true), 'sym', static: true) }],
  # -g -S: the file name symbol id is known for one input file only (the first symbol after the presyms)
  [%w[-g -Bsym -S -o-], ->(img) { D.cstruct(D.strip(img, debug: true, lvar: true), 'sym') }, :single],
  [%w[-g -Bsym -S -s -o-], ->(img) { D.cstruct(D.strip(img, debug: true, lvar: true), 'sym', static: true) }, :single]
].freeze

mruby_dir = File.expand_path('../..', oracle)
world_root = File.expand_path('../..', mruby_dir)
sets = { 'core mrblib' => Dir["#{mruby_dir}/mrblib/*.rb"].sort.reject { |p| p.end_with?('/10error.rb') } }
(Dir["#{mruby_dir}/mrbgems/*"] + Dir["#{world_root}/3rd/*"] + Dir["#{world_root}/mruby-*"]).sort.each do |gem_dir|
  sets[File.basename(gem_dir)] = Dir["#{gem_dir}/mrblib/**/*.rb"].sort
end
sets.reject! { |_, files| files.empty? }
inputs = sets.map { |name, files| [name, files] } + Dir.glob('bc2cpp/**/*.rb').sort.map { |f| [f, [f]] }

failures = 0
checked = Hash.new(0)
skipped = 0
inputs.each do |name, paths|
  img = begin
    paths.size == 1 ? MrbcRb.compile(File.binread(paths.first), paths.first) : MrbcRb.compile_files(paths.map { |p| [File.binread(p), p] })
  rescue MrbcRb::Error
    skipped += 1
    next
  end
  COMBOS.each do |flags, make, only|
    next if only == :single && paths.size > 1

    expected, err, st = Open3.capture3(oracle, *flags, *paths, binmode: true)
    unless st.success?
      puts "  oracle failed for #{flags.join(' ')} #{name}: #{err[0, 80]}"
      next
    end
    got = make.call(img)
    if got.b == expected.b
      checked[flags.join(' ')] += 1
    else
      failures += 1
      puts "FAIL #{flags.join(' ')} #{name}"
    end
  end
end
puts "dump functions: #{inputs.size - skipped} inputs (#{skipped} not covered by the emitter)"
checked.each { |flags, n| puts "  #{flags}: #{n} identical" }

# The command itself.
def run_cli(env, *args)
  Open3.capture3(env, RbConfig.ruby, CLI, *args, binmode: true)
end

Dir.mktmpdir('mrbc_rb_cli') do |dir|
  a = File.join(dir, 'a.rb')
  b = File.join(dir, 'b.rb')
  File.write(a, "x = 1\ndef foo?(v); @iv = v + x; :\"a b\"; 3000000000; 1.5; end\nputs x\n")
  File.write(b, "y = x\nclass A\n  def g; 1; end\nend\n")
  unsupported = File.join(dir, 'u.rb')
  File.write(unsupported, "begin\n  1\nrescue => e\n  2\nend\nnot_a_covered_thing = ObjectSpace.each_object { |o| o }\n")
  cases = [
    [%w[-o-], [a]], [%w[-g -o-], [a, b]], [%w[-Bsym -o- -S], [a, b]], [%w[-Bsym -o- -S -s], [a]], [%w[-g -Bsym -o- -S], [a]], [%w[-g -Bsym -o- -S -s], [a]], [%w[-Bsym -o- --remove-lv], [a]],
    [%w[-B sym -o -], [a]], [%w[-e -o-], [a]]
  ]
  cases.each do |flags, files|
    exp, _e, st = Open3.capture3(oracle, *flags, *files, binmode: true)
    got, err, gst = run_cli({ 'MRBC_FALLBACK' => nil }, *flags, *files)
    if st.success? && gst.success? && got == exp
      puts "ok   cli #{flags.join(' ')} #{files.size} file(s)"
    else
      failures += 1
      puts "FAIL cli #{flags.join(' ')}: #{err[0, 120]}"
    end
  end

  # -o FILE and the default output name
  Dir.chdir(dir) do
    system(oracle, '-g', '-o', 'ref.mrb', 'a.rb', 'b.rb', exception: true)
    _o, e, st = run_cli({}, '-g', '-o', 'out.mrb', 'a.rb', 'b.rb')
    same = st.success? && File.binread('out.mrb') == File.binread('ref.mrb')
    system(oracle, 'a.rb', exception: true)
    ref_default = File.binread('a.mrb')
    File.delete('a.mrb')
    _o, e2, st2 = run_cli({}, 'a.rb')
    same &&= st2.success? && File.binread('a.mrb') == ref_default
    system(oracle, '-Bfoo', 'a.rb', exception: true)
    ref_c = File.binread('a.c')
    File.delete('a.c')
    _o, e3, st3 = run_cli({}, '-Bfoo', 'a.rb')
    same &&= st3.success? && File.binread('a.c') == ref_c
    puts same ? 'ok   cli -o FILE and default output names' : "FAIL cli output file names: #{e}#{e2}#{e3}"
    failures += 1 unless same
  end

  # Not covered: fails without MRBC_FALLBACK, runs the real mrbc with it.
  _o, err, st = run_cli({ 'MRBC_FALLBACK' => nil }, '-Bsym', '-S', '-g', '-o-', a, b)
  ok = !st.success? && err.include?('MRBC_FALLBACK')
  puts ok ? 'ok   cli: an uncovered option set fails with a clear message without MRBC_FALLBACK' : "FAIL cli failure message: #{err}"
  failures += 1 unless ok
  exp, _e, = Open3.capture3(oracle, '-Bsym', '-S', '-g', '-o-', a, b, binmode: true)
  got, err, st = run_cli({ 'MRBC_FALLBACK' => oracle }, '-Bsym', '-S', '-g', '-o-', a, b)
  ok = st.success? && got == exp
  puts ok ? 'ok   cli: MRBC_FALLBACK runs the real mrbc for what is not covered' : "FAIL cli fallback: #{err}"
  failures += 1 unless ok
  exp, _e, ost = Open3.capture3(oracle, '-c', a)
  got, = run_cli({ 'MRBC_FALLBACK' => oracle }, '-c', a)
  ok = ost.success? && got == exp && got.include?('Syntax OK')
  puts ok ? 'ok   cli: -c goes to the real mrbc' : 'FAIL cli -c'
  failures += 1 unless ok
  # A syntax error: mrbc's own report and exit status, through the fallback.
  bad = File.join(dir, 'bad.rb')
  File.write(bad, "def (\n")
  _o, _e, bst = Open3.capture3(oracle, '-o-', bad)
  _o, _e, gst = run_cli({ 'MRBC_FALLBACK' => oracle }, '-o-', bad)
  ok = !bst.success? && !gst.success?
  puts ok ? 'ok   cli: a syntax error fails (through mrbc)' : 'FAIL cli syntax error'
  failures += 1 unless ok
end

puts failures.zero? ? 'all CLI checks pass' : "#{failures} CLI problem(s)"
exit(failures.zero? ? 0 : 1)
