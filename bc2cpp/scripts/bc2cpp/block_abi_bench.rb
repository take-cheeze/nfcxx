#!/usr/bin/env ruby
# encoding: UTF-8
# frozen_string_literal: true

# Block-heavy hot loops through compiled callees, for comparing block ABIs (docs/bc2cpp-stack-blocks.md).
# Builds the fixture once (-O2) and prints user CPU seconds per shape, best of 3.
#
#   `yield`: 100M yields through one compiled plain yielder (the cost of the yield itself);
#   `sites`: 5M calls of a compiled yielder with a fresh literal block (the cost of making the block);
#   `fwd`  : 20M yields through a yielder that forwards its block to another compiled yielder;
#   `fsites`: 3M calls of `def eachn(a); a.each { |x| yield x }; end` (a nested block that yields to the frame block);
#   `each` : 100M elements through the compiled Array#each.
#
# Usage: MRBC=... BC2CPP_MRUBY_FULL=dir [BENCH_SCALE=1] ruby scripts/bc2cpp/block_abi_bench.rb [tools-root]

require 'tmpdir'
require_relative 'fixture_runtime'

ENV['BC2CPP_SIG_DIRS'] = ''
ENV['BC2CPP_CXXFLAGS'] = "-O2 #{ENV.fetch('BC2CPP_CXXFLAGS', '')}"
scale = Float(ENV.fetch('BENCH_SCALE', '1'))

SRC = <<~'RUBY'
  class BbFx
    def gen(n); i = 0; while i < n; yield i; i += 1; end; self; end
    def pass(n, &b); gen(n, &b); end
    def run_yield(n); s = 0; gen(n) { |x| s += x }; s; end
    def run_sites(n); s = 0; i = 0; while i < n; gen(2) { |x| s += x }; i += 1; end; s; end
    def run_fwd(n); s = 0; pass(n) { |x| s += x }; s; end
    def eachn(a); a.each { |x| yield x }; end
    def run_fsites(n); s = 0; a = [1, 2]; i = 0; while i < n; eachn(a) { |x| s += x }; i += 1; end; s; end
    def run_each(a, k); s = 0; i = 0; while i < k; a.each { |x| s += x }; i += 1; end; s; end
  end
RUBY

DRIVER = <<~RUBY
  fx = BbFx.new
  case ENV_SHAPE
  when 'yield' then p fx.run_yield(#{(100_000_000 * scale).to_i})
  when 'sites' then p fx.run_sites(#{(5_000_000 * scale).to_i})
  when 'fsites' then p fx.run_fsites(#{(3_000_000 * scale).to_i})
  when 'fwd' then p fx.run_fwd(#{(20_000_000 * scale).to_i})
  when 'each' then p fx.run_each((1..1000).to_a, #{(100_000 * scale).to_i})
  end
RUBY

shapes = %w[yield sites fwd fsites each]
unless Bc2cppFixtureRuntime.mrbc
  puts 'SKIP: no host mrbc'
  exit 0
end
build = Bc2cppFixtureRuntime.full_or_build or abort 'needs a full libmruby'
Dir.mktmpdir('bc2cpp-bench') do |dir|
  code, err = Bc2cppFixtureRuntime.generate(SRC, dir, core: true, only_owners: %w[BbFx])
  body = <<~CPP
    static int scenario(mrb_state* M) {
      const char* shape = std::getenv("BENCH_SHAPE");
      std::string src = std::string("ENV_SHAPE = '") + shape + "'\\n" + R"BBD(#{DRIVER.sub("ENV_SHAPE", 'ENV_SHAPE')})BBD";
      mrb_load_string(M, src.c_str());
      if (M->exc) { mrb_print_error(M); return 1; }
      return 0;
    }
  CPP
  built, = Bc2cppFixtureRuntime.run(dir, err, %w[BbFx], "#include <cstdlib>\n#include <string>\n#{body}", build: build,
                                    full: true, vms: [true], envs: [{ 'BENCH_SHAPE' => 'each' }])
  abort 'fixture build failed' unless built
  binary = File.join(dir, 'fixture')
  shapes.each do |shape|
    times = 3.times.map do
      t0 = Process.times
      pid = Process.spawn({ 'BENCH_SHAPE' => shape }, binary, File.join(dir, 'fixture.mrb'), out: File::NULL)
      Process.wait(pid)
      t1 = Process.times
      t1.cutime - t0.cutime
    end
    puts format('%-6s %.3f s user (best of 3)', shape, times.min)
  end
end
