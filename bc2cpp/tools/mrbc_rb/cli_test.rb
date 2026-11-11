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
require_relative 'file_syms'
require_relative 'golden_data'

oracle = ENV.fetch('MRBC', nil)
unless oracle && File.executable?(oracle)
  # No oracle: the command's `-g -o-` output (the RITE image every other format is cut from) against the snapshot, for the
  # single files of bc2cpp/ and the gem sets of a world checkout, through bin/mrbc_rb itself. The other output formats need MRBC.
  require 'open3'
  require_relative 'snapshot'
  cli = File.expand_path('bin/mrbc_rb', __dir__)
  note = MrbcRb::Snapshot.world_pin_note
  puts "cli_test: #{note}" if note
  bad = ok = missing = 0
  missing_labels = []
  MrbcRb::Snapshot.each_input.each do |label, sources|
    next if sources.any? { |_, p| !File.file?(p) } # snippets and groups are golden_test.rb's

    # as the oracle is run: from the world root with the world-relative names (see Snapshot.relative)
    rel, world = MrbcRb::Snapshot.relative(sources)
    opts = world ? { chdir: world } : {}
    out, _e, st = Open3.capture3(RbConfig.ruby, cli, '-g', '-o-', *rel.map(&:last), binmode: true, **opts)
    next unless st.success?

    begin
      MrbcRb::Snapshot.check(sources, out) == :ok ? ok += 1 : (bad += 1; puts "DIFFERS #{label}")
    rescue MrbcRb::Snapshot::NotInSnapshot
      missing += 1
      missing_labels << "MISSING #{label}"
    end
  end
  puts MrbcRb::Snapshot.summarize_missing(missing_labels)
  puts "cli_test (snapshot, no MRBC): #{ok} match, #{bad} differ, #{missing} missing"
  puts 'cli_test: nothing was checked (set BC2CPP_RPG_DIR to a world checkout, or MRBC to the oracle)' if ok.zero?
  exit(bad.zero? && missing.zero? && !ok.zero? ? 0 : 1)
end

CLI = File.expand_path('bin/mrbc_rb', __dir__)
D = MrbcRb::RiteDump
FS = MrbcRb::FileSyms

# [flags the oracle gets, lambda image -> expected output of the dump functions] per combination.
COMBOS = [
  [%w[-o-], ->(img, _f) { D.strip(img, debug: false, lvar: true) }],
  [%w[-g -o-], ->(img, _f) { D.strip(img, debug: true, lvar: true) }],
  [%w[--remove-lv -o-], ->(img, _f) { D.strip(img, debug: false, lvar: false) }],
  [%w[-g --remove-lv -o-], ->(img, _f) { D.strip(img, debug: true, lvar: false) }],
  [%w[-Bsym -o-], ->(img, _f) { D.cfunc(D.strip(img, debug: false, lvar: true), 'sym') }],
  [%w[-Bsym -s -o-], ->(img, _f) { D.cfunc(D.strip(img, debug: false, lvar: true), 'sym', static: true) }],
  [%w[-g -Bsym -o-], ->(img, _f) { D.cfunc(D.strip(img, debug: true, lvar: true), 'sym') }],
  [%w[-Bsym -S -o-], ->(img, _f) { D.cstruct(D.strip(img, debug: false, lvar: true), 'sym') }],
  [%w[-Bsym -S -s -o-], ->(img, _f) { D.cstruct(D.strip(img, debug: false, lvar: true), 'sym', static: true) }],
  [%w[-Bsym -S -s --remove-lv -o-], ->(img, _f) { D.cstruct(D.strip(img, debug: false, lvar: true), 'sym', static: true) }],
  # -g -S: the file name symbol ids come from the sources (file_syms.rb)
  [%w[-g -Bsym -S -o-], ->(img, f) { D.cstruct(D.strip(img, debug: true, lvar: true), 'sym', file_syms: FS.ids(f)) }],
  [%w[-g -Bsym -S -s -o-], ->(img, f) { D.cstruct(D.strip(img, debug: true, lvar: true), 'sym', static: true, file_syms: FS.ids(f)) }]
].freeze

mruby_dir = File.expand_path('../..', oracle)
world_root = File.expand_path('../..', mruby_dir)
sets = { 'core mrblib' => Dir["#{mruby_dir}/mrblib/*.rb"].sort.reject { |p| p.end_with?('/10error.rb') } }
(Dir["#{mruby_dir}/mrbgems/*"] + Dir["#{world_root}/3rd/*"] + Dir["#{world_root}/mruby-*"]).sort.each do |gem_dir|
  sets[File.basename(gem_dir)] = Dir["#{gem_dir}/mrblib/**/*.rb"].sort
end
sets.reject! { |_, files| files.empty? }
inputs = sets.map { |name, files| [name, files] } + Dir.glob('bc2cpp/**/*.rb').sort.map { |f| [f, [f]] }
# MRBC_RB_CLI_SAMPLE=n: check every n-th single file of bc2cpp/ (the gem sets, which hold the multi-file cases, are always all
# checked). CI uses it to keep the job short; unset = everything.
sample = Integer(ENV.fetch('MRBC_RB_CLI_SAMPLE', '1'))
inputs = inputs.each_with_index.select { |(_, files), i| files.size > 1 || (i % sample).zero? }.map(&:first)

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
  sources = paths.map { |p| [File.binread(p), p] }
  COMBOS.each do |flags, make|
    expected, err, st = Open3.capture3(oracle, *flags, *paths, binmode: true)
    unless st.success?
      puts "  oracle failed for #{flags.join(' ')} #{name}: #{err[0, 80]}"
      next
    end
    got = make.call(img, sources)
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
def run_cli(env, *args, stdin: '')
  Open3.capture3(env, RbConfig.ruby, CLI, *args, binmode: true, stdin_data: stdin)
end

Dir.mktmpdir('mrbc_rb_cli') do |dir|
  a = File.join(dir, 'a.rb')
  b = File.join(dir, 'b.rb')
  File.write(a, "x = 1\ndef foo?(v); @iv = v + x; :\"a b\"; 3000000000; 1.5; end\nputs x\n")
  File.write(b, "y = x\nclass A\n  def g; 1; end\nend\n")
  unsupported = File.join(dir, 'u.rb')
  File.write(unsupported, "begin\n  1\nrescue => e\n  2\nend\nnot_a_covered_thing = ObjectSpace.each_object { |o| o }\n")
  cases = [
    [%w[-o-], [a]], [%w[-g -o-], [a, b]], [%w[-Bsym -o- -S], [a, b]], [%w[-Bsym -o- -S -s], [a]], [%w[-g -Bsym -o- -S], [a]], [%w[-g -Bsym -o- -S], [a, b]], [%w[-g -Bsym -o- -S -s], [b, a]], [%w[-g -Bsym -o- -S -s], [a]], [%w[-Bsym -o- --remove-lv], [a]],
    [%w[-B sym -o -], [a]], [%w[-e -o-], [a]],
    # -S and -s without -B are ignored by mrbc (the binary is written); -e -E; attached and detached -o
    [%w[-S -o-], [a]], [%w[-S -s -g -o-], [a, b]], [%w[-s -o-], [a]], [%w[-e -E -g -o-], [a, b]],
    [%w[-Bsym -S --remove-lv -g -o-], [a]]
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

  # --no-optimize, --no-ext-ops and standard input ("-"): the same bytes as mrbc, with no fallback.
  ops = File.join(dir, 'ops.rb')
  File.write(ops, "x = 1\na = [1, 2]\na[0] = x + 2\na[1] += 3\nfoo(-x, a[0], x == 1, !x)\ny = x\nputs \"\#{y}\" if y\nz = [:a, :b]\n")
  wide = File.join(dir, 'wide.rb')
  File.write(wide, (0...300).map { |i| "m#{i}\n" }.join) # 300 symbols: an operand past 255 takes an OP_EXT prefix
  [[%w[--no-optimize -o-], [a]], [%w[-g --no-optimize -o-], [ops, b]], [%w[--no-optimize -Bsym -S -o-], [ops]], [%w[--no-ext-ops -o-], [a]],
   [%w[--no-ext-ops --no-optimize -g -o-], [ops]]].each do |flags, files|
    exp, _e, st = Open3.capture3(oracle, *flags, *files, binmode: true)
    got, err, gst = run_cli({ 'MRBC_FALLBACK' => nil }, *flags, *files)
    ok = st.success? && gst.success? && got == exp
    puts ok ? "ok   cli #{flags.join(' ')} #{files.size} file(s)" : "FAIL cli #{flags.join(' ')}: #{err[0, 120]}"
    failures += 1 unless ok
  end
  # --no-ext-ops with an operand that needs OP_EXT: mrbc fails; the emitter refuses and the fallback reports it
  exp, eerr, est = Open3.capture3(oracle, '--no-ext-ops', '-o-', wide, binmode: true)
  _o, err, gst = run_cli({ 'MRBC_FALLBACK' => nil }, '--no-ext-ops', '-o-', wide)
  got, gerr, gst2 = run_cli({ 'MRBC_FALLBACK' => oracle }, '--no-ext-ops', '-o-', wide)
  ok = !est.success? && !gst.success? && err.include?('MRBC_FALLBACK') && gst2.exitstatus == est.exitstatus && got == exp && gerr == eerr
  puts ok ? 'ok   cli --no-ext-ops with a wide operand: the real mrbc reports the error' : "FAIL cli --no-ext-ops wide: #{err[0, 100]} #{gerr[0, 100]}"
  failures += 1 unless ok
  exp, _e, = Open3.capture3(oracle, '-o-', wide, binmode: true)
  got, err, gst = run_cli({ 'MRBC_FALLBACK' => nil }, '-o-', wide)
  ok = gst.success? && got == exp
  puts ok ? 'ok   cli: wide operands without --no-ext-ops' : "FAIL cli wide: #{err[0, 100]}"
  failures += 1 unless ok
  # standard input: `mrbc -` writes to standard output by default; `- other.rb` reads stdin first
  [[%w[-], [], ops], [%w[-g -o-], ['-'], ops], [%w[-g -o-], ['-', a], ops], [%w[-c], ['-'], ops], [%w[-Bsym -o-], ['-'], ops]].each do |flags, files, prog|
    exp, _e, st = Open3.capture3(oracle, *flags, *files, binmode: true, stdin_data: File.binread(prog))
    got, err, gst = run_cli({ 'MRBC_FALLBACK' => nil }, *flags, *files, stdin: File.binread(prog))
    got = got.gsub(CLI, 'PROG').gsub(oracle, 'PROG') if flags.include?('-c') # the program name is printed
    exp = exp.gsub(CLI, 'PROG').gsub(oracle, 'PROG') if flags.include?('-c')
    ok = st.success? && gst.success? && got == exp
    puts ok ? "ok   cli stdin: #{(flags + files).join(' ')}" : "FAIL cli stdin #{(flags + files).join(' ')}: #{err[0, 120]}"
    failures += 1 unless ok
  end
  # a syntax error on stdin and `-` after the first input go through the real mrbc, which reads the same bytes
  [[['-o-'], ['-'], "def (\n"], [['-o-'], [a, '-'], "x = 1\n"]].each do |flags, files, prog|
    exp, eerr, est = Open3.capture3(oracle, *flags, *files, binmode: true, stdin_data: prog)
    got, gerr, gst = run_cli({ 'MRBC_FALLBACK' => oracle }, *flags, *files, stdin: prog)
    ok = est.exitstatus == gst.exitstatus && got == exp && gerr.gsub(CLI, 'P').gsub(oracle, 'P') == eerr.gsub(oracle, 'P')
    puts ok ? "ok   cli stdin through the fallback: #{files.map { |f| File.basename(f) }.join(' ')}" : "FAIL cli stdin fallback #{files.inspect}: #{gerr[0, 100]}"
    failures += 1 unless ok
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

  # Not covered: fails without MRBC_FALLBACK, runs the real mrbc with it (-v: the AST dump and the irep addresses of the C
  # compiler).
  _o, err, st = run_cli({ 'MRBC_FALLBACK' => nil }, '--verbose', '-o-', a)
  ok = !st.success? && err.include?('MRBC_FALLBACK')
  puts ok ? 'ok   cli: an uncovered option set fails with a clear message without MRBC_FALLBACK' : "FAIL cli failure message: #{err}"
  failures += 1 unless ok
  exp, _e, = Open3.capture3(oracle, '--verbose', '-o-', a, binmode: true)
  got, err, st = run_cli({ 'MRBC_FALLBACK' => oracle }, '--verbose', '-o-', a)
  norm_addr = ->(t) { t.b.gsub(/irep 0x[0-9a-f]+/, 'irep ADDR') }
  exp = norm_addr.call(exp)
  got = norm_addr.call(got)
  ok = st.success? && got == exp
  puts ok ? 'ok   cli: MRBC_FALLBACK runs the real mrbc for what is not covered' : "FAIL cli fallback: #{err}"
  failures += 1 unless ok
  # -c, --version, --copyright, -h and the usage errors, without the fallback: the oracle's text with its program name
  # replaced (mrbc prints argv[0]).
  [[%w[-c], [a]], [%w[-c], [a, b]], [%w[--version], []], [%w[--copyright], []], [%w[-h], []], [%w[--bogus], []], [[], []],
   [%w[-o], [a]], [%w[-o- -Bsym -S -g], [File.join(dir, 'missing.rb')]], [%w[-g], [a, b]],
   # -v prints the version when it is parsed: the exits that need no compile show it first (a compile goes to the fallback)
   [%w[-v], []], [%w[-v], [File.join(dir, 'missing.rb')]], [%w[-v --bogus], []], [%w[-v -v --version], []], [%w[-v --copyright], []],
   [%w[--verbose -v -h], []], [%w[-c -o], [a]], [%w[-S -o- -B], [a]]].each do |flags, files|
    exp, eerr, est = Open3.capture3(oracle, *flags, *files, binmode: true)
    got, gerr, gst = run_cli({ 'MRBC_FALLBACK' => nil }, *flags, *files)
    norm = ->(t) { t.gsub(oracle, 'PROG').gsub(CLI, 'PROG').gsub(dir, 'DIR') }
    ok = est.exitstatus == gst.exitstatus && norm.call(exp) == norm.call(got) && norm.call(eerr) == norm.call(gerr)
    puts ok ? "ok   cli #{flags.join(' ')} #{files.size} file(s): same text and status" : "FAIL cli #{flags.join(' ')}: #{norm.call(got)[0, 100].inspect} #{norm.call(gerr)[0, 100].inspect}"
    failures += 1 unless ok
  end
  # -v, -vv, -v -c, --verbose -c through the fallback: the real mrbc's AST dump and listing (irep addresses aside)
  [%w[-v -o-], %w[-vv -c], %w[--verbose -c], %w[-v -g -o-]].each do |flags|
    exp, eerr, est = Open3.capture3(oracle, *flags, a, binmode: true)
    got, gerr, gst = run_cli({ 'MRBC_FALLBACK' => oracle }, *flags, a)
    norm = ->(t) { t.b.gsub(/irep 0x[0-9a-f]+/, 'irep ADDR').gsub(oracle, 'P').gsub(CLI, 'P') }
    ok = est.exitstatus == gst.exitstatus && norm.call(exp) == norm.call(got) && norm.call(eerr) == norm.call(gerr)
    puts ok ? "ok   cli #{flags.join(' ')}: the fallback's output is mrbc's" : "FAIL cli #{flags.join(' ')} through the fallback"
    failures += 1 unless ok
  end
  # --help documents the supported switches and the fallback, and exits 0 (an addition: mrbc prints its usage and exits 1)
  help, _e, hst = run_cli({ 'MRBC_FALLBACK' => nil }, '--help')
  ok = hst.success? && help.start_with?('Usage: ') && %w[-o -g -B -S -s --remove-lv -c -e --no-optimize --no-ext-ops -v --verbose --disasm
                                                         MRBC_FALLBACK --version --copyright].all? { |w| help.include?(w) }
  puts ok ? 'ok   cli --help lists the switches and the fallback' : 'FAIL cli --help'
  failures += 1 unless ok
  # --disasm: the listing of mrbc -v (from its first irep line), irep addresses aside.
  exp, = Open3.capture3(oracle, '-v', '-o', '/dev/null', a, b, binmode: true)
  got, = run_cli({ 'MRBC_FALLBACK' => nil }, '--disasm', a, b)
  addr = ->(t) { t.b.gsub(/^irep 0x[0-9a-f]+/, 'irep ADDR') }
  ok = addr.call(exp[/^irep 0x.*/m]) == addr.call(got)
  puts ok ? 'ok   cli: --disasm is the listing of mrbc -v' : 'FAIL cli --disasm'
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
