#!/usr/bin/env ruby
# frozen_string_literal: true

# EMBED_INIT_GUARD (tools/bc2cpp/embed_init_guard.rb): an owner whose ivars are embedded must be emitted with the
# compiled #initialize that allocates its storage, or the build fails. The unit part feeds the guard each way a run
# can lack that #initialize; the fixture part generates a class that embeds and checks the guard stays quiet and the
# storage line it looks for is the one the generator emits. The fixture part needs a host mrbc (MRBC).
ENV['BC2CPP_SIG_DIRS'] = ''

require 'tmpdir'
require_relative 'check_support'
require_relative 'fixture_runtime'
require_relative '../../tools/bc2cpp/embed_init_guard'

suite = FixtureCheck.new('embed_init_guard_check')

line = 'mrb_data_init(self, embedded, &Eg_type);'
init = ['Eg', 'L1', line]
ok = { label: 'L1', owner: 'Eg', name: 'initialize', code: "  {\n    #{line}\n  }\n" }
suite.check('a compiled #initialize that builds the storage passes', EmbedInitGuard.failures([init], [ok], nil).empty?)
suite.check('a missing #initialize fails', EmbedInitGuard.failures([init], [], nil).size == 1)
suite.check('an owner without a Ruby #initialize fails', EmbedInitGuard.failures([['Eg', nil, line]], [ok], nil).size == 1)
suite.check('an #initialize kept with #error fails',
            EmbedInitGuard.failures([init], [ok.merge(code: "#{ok[:code]}#error x\n")], nil).size == 1)
suite.check('an #initialize without the storage line fails',
            EmbedInitGuard.failures([init], [ok.merge(code: "  return self;\n")], nil).size == 1)
suite.check('an owner another unit emits is not this run\'s', EmbedInitGuard.failures([init], [], %w[Other]).empty?)

suite.require_mrbc!
SOURCE = <<~RUBY
  class Eg
    def initialize(a)
      @a = a
      @b = a + 1
    end

    def sum = @a + @b
  end
RUBY

Dir.mktmpdir('bc2cpp-embed-init-guard') do |dir|
  code, err = Bc2cppFixtureRuntime.generate(SOURCE, dir, core: true, only_owners: %w[Eg])
  suite.check('the fixture class embeds its ivars', err.include?('EMBED  Eg#@a'))
  suite.check('its #initialize builds the storage with the line the guard looks for',
              code.match?(/mrb_data_init\(self, embedded, &\w+\);/))
  suite.check('the guard stays quiet', !err.include?(EmbedInitGuard::CODE))
end

suite.finish!
