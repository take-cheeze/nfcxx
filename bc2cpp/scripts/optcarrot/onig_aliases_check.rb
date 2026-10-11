#!/usr/bin/env ruby
# frozen_string_literal: true

require 'tmpdir'
require_relative '../../tools/optcarrot_probe/onig_aliases'
require_relative '../../tools/bc2cpp/closed_world'

root = File.expand_path('../..', __dir__)
source = File.read(File.join(root, '3rd/mruby-onig-regexp/mrblib/onig_regexp.rb'))
transformed = OptcarrotOnigAliases.transform(source)

loop_source = OptcarrotOnigAliases::LOOP.lines.map { |line| "  #{line}" }.join
literal_source = OptcarrotOnigAliases.transform(loop_source)
[[], %w[sub gsub], OptcarrotOnigAliases::NAMES].each do |existing|
  snapshots = [loop_source, literal_source].map do |body|
    klass = Class.new do
      OptcarrotOnigAliases::NAMES.each do |name|
        define_method("onig_regexp_#{name}") { "onig-#{name}" }
        define_method(name) { "original-#{name}" } if existing.include?(name)
      end
    end
    klass.class_eval(body)
    obj = klass.new
    OptcarrotOnigAliases::NAMES.map do |name|
      [obj.public_send(name), obj.respond_to?("string_#{name}"),
       (obj.public_send("string_#{name}") if obj.respond_to?("string_#{name}"))]
    end
  end
  raise "alias behavior differs with #{existing.inspect}" unless snapshots[0] == snapshots[1]
end
begin
  OptcarrotOnigAliases.transform(source.sub('%i[sub gsub split scan]', '%i[sub gsub split scan extra]'))
  raise 'upstream alias loop drift accepted'
rescue RuntimeError => e
  raise unless e.message == 'OnigRegexp alias loop changed'
end
Dir.mktmpdir do |temp|
  gem_dir = OptcarrotOnigAliases.prepare(root, temp)
  path = File.join(gem_dir, 'mrblib/onig_regexp.rb')
  raise 'upstream source modified' unless File.read(File.join(root, '3rd/mruby-onig-regexp/mrblib/onig_regexp.rb')) == source
  raise 'runtime source differs from analyzed source' unless File.read(path) == transformed
  world = ClosedWorld.new(ireps: {}, registry: {}, class_decls: {}, walked: [],
                          native_paths: [], ruby_paths: [path])
  raise "unrolled outside Ruby refused: #{world.global_refusal}" if world.global_refusal
end
puts 'Optcarrot OnigRegexp literal aliases preserve runtime behavior and pass outside scanning'
