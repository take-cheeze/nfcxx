#!/usr/bin/env ruby
# frozen_string_literal: true

require 'open3'
require 'rbconfig'
require 'tmpdir'

root = File.expand_path('../..', __dir__)
Dir.mktmpdir('upstream-optcarrot-bundle') do |dir|
  bundle = File.join(dir, 'bundle.rb')
  output, status = Open3.capture2e(RbConfig.ruby, File.join(root, 'tools/optcarrot_probe/build_bundle.rb'), bundle)
  raise "bundle failed: #{output}" unless status.success?

  refused, refused_status = Open3.capture2e({ 'OPTCARROT_STATIC_DISPATCH' => '1' },
                                          RbConfig.ruby, File.join(root, 'tools/optcarrot_probe/build_bundle.rb'), bundle)
  raise 'removed source optimization was accepted' if refused_status.success?
  raise 'removed option failure was unexplained' unless refused.include?('Removed workload-specific optimization')

  source = File.read(bundle)
  %w[cpu ppu].each do |name|
    upstream = File.read(File.join(root, "3rd/optcarrot/lib/optcarrot/#{name}.rb"))
    stripped = upstream.lines.reject { |line| line.match?(/^\s*require_relative\b/) }.join
    raise "upstream #{name} source was changed" unless source.include?(stripped)
  end
end
puts 'upstream Optcarrot bundle check: PASS'
