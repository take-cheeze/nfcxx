#!/usr/bin/env ruby
# frozen_string_literal: true

require 'fileutils'
require 'tmpdir'
require_relative '../../tools/bc2cpp/compiled_gems'

root = File.expand_path('../..', __dir__)
Dir.mktmpdir('optcarrot-world-check-') do |dir|
  FileUtils.mkdir_p(["#{dir}/mrblib", "#{dir}/src"])
  bundle = "#{dir}/mrblib/benchmark.rb"
  host = "#{dir}/src/main.cxx"
  File.write(bundle, 'module OptcarrotBenchmark; def self.run; end; end')
  File.write(host, 'int main() { mrb_state *M = mrb_open(); mrb_funcall(M, benchmark, "run", 0); }')
  gems = { 'optcarrot-benchmark' => dir, 'optcarrot-compiled' => "#{dir}/compiled" }
  validate = ->(set = gems, inputs = [bundle]) do
    bc2cpp_closed_world_violations('optcarrot-probe', set, root, compiled_srcs: inputs)
  end
  raise 'fixed benchmark refused' unless validate.call.empty?
  BC2CPP_OPEN_WORLD_GEMS.each do |name|
    raise "open gem #{name} accepted" unless validate.call(gems.merge(name => dir)).any? { |e| e.include?(name) }
  end
  raise 'compiler accepted' if validate.call(gems.merge('mruby-compiler' => dir)).empty?
  raise 'missing compiled bundle accepted' if validate.call(gems, []).empty?
  raise 'missing benchmark accepted' if validate.call(gems.except('optcarrot-benchmark')).empty?
  File.write(host, 'int main() { mrb_load_file(M, input); }')
  raise 'runtime source loader accepted' if validate.call.empty?
  File.write(host, 'int main() { mrb_load_irep(M, bytes); }')
  raise 'runtime bytecode loader accepted' if validate.call.empty?
  File.write(host, 'int main() { mrb_funcall(M, benchmark, "run", 0); }')
  native, ruby = bc2cpp_closed_world_outside_srcs('optcarrot-probe', gems, root)
  raise 'host missing from native scan' unless native.include?(host)
  raise 'compiled benchmark counted as outside Ruby' if ruby.include?(bundle)
  puts 'Optcarrot closed-world source and host checks passed'
end
