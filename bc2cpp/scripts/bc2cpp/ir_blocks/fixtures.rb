# frozen_string_literal: true

require 'tmpdir'
require_relative '../../../tools/bc2cpp/irep'

module Bc2cppIrBlockFixtures
  def self.compile(source, name)
    Dir.mktmpdir("ir-block-#{name}") do |directory|
      path = File.join(directory, 'fixture.rb')
      File.write(path, source)
      ireps, root = compile_ireps([path], name, directory)
      yield ireps, root
    end
  end
end
