# frozen_string_literal: true

# MrbcRb::MrubyBuild's fallback provider (no oracle needed): the real mrbc is built only for a file the emitter does not
# cover, once, and an explicit MRBC_FALLBACK wins.
#   bundle exec ruby bc2cpp/tools/mrbc_rb/mruby_build_test.rb

require 'tmpdir'
require 'stringio'
# mruby_build.rb prepends to MRuby::Command::Mrbc only if mruby's build is loaded; not here.
require_relative 'mruby_build'

$fails = 0
def check(name, cond)
  puts "#{cond ? 'ok  ' : 'FAIL'} #{name}"
  $fails += 1 unless cond
end

def run_cli(file, env)
  out = StringIO.new.binmode
  err = StringIO.new
  st = MrbcRb::Cli.run(['-Bsym', '-o-', '-S', file], stdin: StringIO.new, stdout: out, stderr: err,
                       env: MrbcRb::MrubyBuild::Env.new(env), prog: 'mrbc_rb')
  [st, out.string, err.string]
end

Dir.mktmpdir do |dir|
  good = File.join(dir, 'good.rb')
  File.write(good, "puts 1\n")
  bad = File.join(dir, 'bad.rb') # Prism rejects it: handed to the real mrbc
  File.write(bad, "def (\n")
  stub = File.join(dir, 'stub_mrbc')
  File.write(stub, "#!/bin/sh\necho stub-mrbc-ran\n")
  File.chmod(0o755, stub)
  calls = 0
  MrbcRb::MrubyBuild.fallback_provider = -> { calls += 1; stub }

  st, out, = run_cli(good, {})
  check('a covered file does not ask for the real mrbc', st.zero? && calls.zero? && out.include?('sym'))

  st, out, = run_cli(bad, {})
  check('an uncovered file runs the provided mrbc', st.zero? && out == "stub-mrbc-ran\n" && calls == 1)

  run_cli(bad, {})
  check('the provider runs once', calls == 1)

  other = File.join(dir, 'other_mrbc')
  File.write(other, "#!/bin/sh\necho other\n")
  File.chmod(0o755, other)
  st, out, = run_cli(bad, { 'MRBC_FALLBACK' => other })
  check('MRBC_FALLBACK in the environment wins', st.zero? && out == "other\n")

  MrbcRb::MrubyBuild.fallback_provider = nil
  MrbcRb::MrubyBuild.instance_variable_set(:@fallback_path, nil)
  st, _, err = run_cli(bad, {})
  check('no provider and no MRBC_FALLBACK still fails and says so', st == 1 && err.include?('MRBC_FALLBACK'))
end

exit($fails.zero? ? 0 : 1)
