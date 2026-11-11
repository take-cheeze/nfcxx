# frozen_string_literal: true

# The library entry points: the irep tree MrbcRb.compile_result builds from the emitter's data must equal what RiteDump.parse
# reads back from the image (so the C dumps and the listing can use the tree), CDump.dump of it must equal the bytes-based
# path, and MrbcRb::Cli.run must work in-process (StringIO streams, an env hash, no spawn for covered inputs).
#   bundle exec ruby -w bc2cpp/tools/mrbc_rb/lib_test.rb      (no oracle needed)

require 'stringio'
require 'tmpdir'
require_relative 'cli'
require_relative 'file_syms'

D = MrbcRb::RiteDump
failures = 0
check = lambda do |ok, what|
  next if ok

  failures += 1
  puts "FAIL #{what}"
end

root = File.expand_path('../..', __dir__)
sets = Dir.glob('**/*.rb', base: root).reject { |f| f.end_with?('_test.rb') }.sort.map { |f| [File.join(root, f)] }
n = 0
sets.each do |paths|
  srcs = paths.map { |p| [File.binread(p), p] }
  res = begin
    MrbcRb.compile_files_result(srcs)
  rescue MrbcRb::Error
    next
  end
  n += 1
  parsed = D.parse(res.image)
  check.call(res.tree == parsed, "tree != parse(image) #{paths.first}")
  check.call(D.parse(MrbcRb.compile_files(srcs)) == parsed, "compile_files #{paths.first}")
  fs = MrbcRb::FileSyms.ids(srcs)
  [[true, true], [false, true], [true, false]].each do |debug, lvar|
    from_tree = MrbcRb::CDump.dump(MrbcRb::CDump.strip(res.tree, debug: debug, lvar: lvar), 'sym', file_syms: fs)
    from_bytes = D.cstruct(D.strip(res.image, debug: debug, lvar: lvar), 'sym', file_syms: fs)
    check.call(from_tree == from_bytes, "CDump.dump != cstruct(image) #{paths.first} debug=#{debug} lvar=#{lvar}")
  end
end
puts "tree == parse(image) and CDump.dump == cstruct(image): #{n} inputs"

Dir.mktmpdir('mrbc_rb_lib') do |dir|
  a = File.join(dir, 'a.rb')
  File.write(a, "x = 1\ndef f(v); v + x; end\n")
  run = lambda do |env, *args|
    out = StringIO.new
    err = StringIO.new
    st = MrbcRb::Cli.run(args, stdin: StringIO.new, stdout: out, stderr: err, env: env, prog: 'PROG')
    [st, out.string, err.string]
  end
  st, out, = run.call({}, '-Bsym', '-S', '-s', '-o-', a)
  check.call(st.zero? && out.include?('static') && out.include?('sym_irep_0'), 'Cli.run -B -S')
  st, out, = run.call({}, '-g', '-o-', a)
  check.call(st.zero? && out == MrbcRb.compile(File.binread(a), a), 'Cli.run -g -o-')
  st, out, = run.call({ 'MRBC_RB_VERSION' => 'v9' }, '--version')
  check.call(st.zero? && out == "v9\n", 'Cli.run --version uses env')
  st, _, err = run.call({}, '--no-optimize', '-o-', a)
  check.call(st == 1 && err.include?('MRBC_FALLBACK'), 'Cli.run without fallback fails')
  fake = File.join(dir, 'fake_mrbc')
  File.write(fake, "#!/bin/sh\necho out-from-fake\necho err-from-fake >&2\nexit 3\n")
  File.chmod(0o755, fake)
  st, out, err = run.call({ 'MRBC_FALLBACK' => fake }, '--no-optimize', '-o-', a)
  check.call(st == 3 && out == "out-from-fake\n" && err == "err-from-fake\n", 'Cli.run fallback passes output and status on')
  st, = run.call({}, '-o-', File.join(dir, 'missing.rb'))
  check.call(st == 1, 'Cli.run missing input')
end

puts failures.zero? ? 'all library checks pass' : "#{failures} library problem(s)"
exit(failures.zero? ? 0 : 1)
