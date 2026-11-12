#!/usr/bin/env ruby
# frozen_string_literal: true

require 'fileutils'
require 'open3'
require 'rbconfig'
require 'tmpdir'
require_relative '../../bc2cpp/tools/bc2cpp/world_root'

# Different tree/world roots and template text must not redirect or corrupt the compiler baked into the runner.
build = File.join(BC2CPP_TREE_ROOT, 'build')
FileUtils.mkdir_p(build)
Dir.mktmpdir('bake-check-', build) do |dir|
  world = File.join(dir, 'world')
  FileUtils.mkdir_p(File.join(world, 'scripts'))
  File.write(File.join(world, 'scripts/extra.rb'), "EXTRA = :world\n")
  File.write(File.join(dir, 'child.rb'), "CHILD = :tree\n")
  entry = File.join(dir, 'entry.rb')
  source = <<~'RUBY'
    # UTF-8 offset before the call: 日本語
    require_relative('child') if true
    TEMPLATE = <<~'RAKE'
      require_relative 'missing_template_dependency'
      __FILE__ __dir__
    RAKE
    PATTERN = /__FILE__|__dir__/
    LITERAL = '__FILE__ __dir__'
    FILE_NAME = __FILE__
    DIRECTORY = __dir__
  RUBY
  File.write(entry, source)
  baked = File.join(dir, 'baked')
  tool = File.join(BC2CPP_TREE_ROOT, 'tools/bc2cpp/bake_sources.rb')
  output, status = Open3.capture2e({ 'BC2CPP_WORLD_ROOT' => world }, RbConfig.ruby, tool,
                                 '--dir', baked, entry, File.join(dir, 'stamp'), 'scripts/extra.rb', chdir: '/')
  abort output unless status.success?
  names = File.readlines(File.join(baked, 'index'), chomp: true)
  name = entry.delete_prefix("#{BC2CPP_TREE_ROOT}/").delete_suffix('.rb')
  abort 'wrong tree/world source names' unless names.sort == [name, name.sub(/entry\z/, 'child'), 'scripts/extra'].sort
  body = File.read(File.join(baked, "#{name}.rb"))
  abort 'template text changed' unless body.include?("require_relative 'missing_template_dependency'\n  __FILE__ __dir__")
  abort 'literal or regexp changed' unless body.include?("PATTERN = /__FILE__|__dir__/\nLITERAL = '__FILE__ __dir__'")
  abort 'source identity was not baked' unless body.include?("FILE_NAME = #{name.dump}") && body.include?("DIRECTORY = #{dir.dump}")
  abort 'actual call was not rewritten' unless body.include?("require '#{name.sub(/entry\z/, 'child')}' if true")
  abort 'invalid generated Ruby' unless system(RbConfig.ruby, '-c', File.join(baked, "#{name}.rb"), out: File::NULL)
end
shim = File.join(BC2CPP_TREE_ROOT, 'host-libs/mruby-require/mrblib/require.rb')
probe = <<~'RUBY'
  load ARGV.fetch(0)
  BC2CPP_TREE_ROOT = '/compiler-tree'
  BC2CPP_WORLD_ROOT = '/program-world'
  module MRubyRequire
    def self.baked?(name) = name == 'tools/compiler'
    def self.load_baked(name)
      raise 'duplicate load' if @loaded
      @loaded = name
    end
  end
  object = Object.new
  raise 'world path did not load' unless object.require('/program-world/tools/compiler.rb')
  raise 'tree alias loaded twice' if object.require('/compiler-tree/tools/compiler')
  begin
    object.require('/program-world/not-baked.rb')
    raise 'unbaked source accepted'
  rescue LoadError
  end
RUBY
output, status = Open3.capture2e(RbConfig.ruby, '-e', probe, shim)
abort output unless status.success?
options_probe = <<~'RUBY'
  require ARGV.fetch(0)
  thread = Object.send(:remove_const, :Thread)
  begin
    raise 'initial options' unless MrbcRb.options.empty?
    MrbcRb.with_options(no_optimize: true) do
      begin
        MrbcRb.with_options(no_ext_ops: true) { raise 'expected' }
      rescue RuntimeError => error
        raise unless error.message == 'expected'
      end
      raise 'outer options lost' unless MrbcRb.options == { no_optimize: true }
    end
    raise 'options leaked' unless MrbcRb.options.empty?
  ensure
    Object.const_set(:Thread, thread)
  end
RUBY
output, status = Open3.capture2e(RbConfig.ruby, '-e', options_probe,
                               File.join(BC2CPP_TREE_ROOT, 'tools/mrbc_rb/mrbc_rb.rb'))
abort output unless status.success?
puts 'bc2cpp source baking tree/world and syntax checks: PASS'
