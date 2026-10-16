# frozen_string_literal: true
require 'open3'
require 'rbconfig'
require 'shellwords'
require 'tmpdir'
require_relative '../../tools/bc2cpp/bc2cpp'

ROOT = File.expand_path('../..', __dir__)
BC2CPP = File.join(ROOT, 'tools/bc2cpp/bc2cpp.rb')
MRBC_ENV = ENV['MRBC'] || 'mrbc'
failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end
SOURCE = <<~'RUBY'
  class RangeZeroOwner
    def run
      total = 0
      (1..3).each { total += 1 }
      total
    end
  end

  class RangeOneOwner
    def run
      total = 0
      (1..3).each { |i| total += i }
      total
    end
  end

  class UnknownRangeOwner
    def run(value)
      value.each { 1 }
    end
  end
RUBY

def body_of(code, function)
  code[/^mrb_value #{function}_impl\(mrb_state\* M.*?(?=^(?:static )?mrb_value \w+\(mrb_state\* M|\z)/m].to_s
end

Dir.mktmpdir do |dir|
  source = File.join(dir, 'range_each_arity.rb')
  File.write(source, SOURCE)
  env = { 'MRBC' => MRBC_ENV, 'OUT_SYMBOL' => 'range_each_arity', 'OUT_DIR' => dir,
          'SKIP_UNSUPPORTED' => '1', 'BC2CPP_SELF_REGISTERING' => '1' }
  out, err, status = Open3.capture3(env, RbConfig.ruby, BC2CPP, '--annotated', source, chdir: ROOT)
  abort "bc2cpp.rb failed:\n#{err[-3000..] || err}" unless status.success?

  zero = body_of(out, 'RangeZeroOwner_run')
  one = body_of(out, 'RangeOneOwner_run')
  unknown = body_of(out, 'UnknownRangeOwner_run')
  check.call('a zero-argument Range block is inlined', zero.include?('Lbc2cpp_range_iter_'))
  check.call('a one-argument Range block stays inlined', one.include?('Lbc2cpp_range_iter_'))
  check.call('an unknown receiver keeps the block fallback', unknown.include?('BLOCK_FALLBACK :each'))
  check.call('the inline Range loop retains its guard and exclusion handling',
             one.include?('mrb_range_p(') && one.include?('mrb_range_excl_p(M, '))
end

if failures.empty?
  puts 'bc2cpp Range#each arity check: PASS'
else
  warn "bc2cpp Range#each arity check: #{failures.size} failure(s)"
  exit 1
end
