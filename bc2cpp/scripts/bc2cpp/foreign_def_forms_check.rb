#!/usr/bin/env ruby
# frozen_string_literal: true

# Check that every syntactic form of an outside-Ruby `def` counts as a definer
# (docs/adr/0278): `private def x`, `def` after `;`, a one-line `class << self`,
# `def self.x`, `def obj.x`, `module_function def x`, ... Missing one made a name
# look undefined outside the closed world, so a guard chain over its in-world
# definers ended in bc2cpp_nomethod for a receiver that the outside definer answers.
#
#   MRBC=path/to/host/mrbc ruby scripts/bc2cpp/foreign_def_forms_check.rb

require 'fileutils'
require 'open3'
require 'rbconfig'
require 'shellwords'
require 'tmpdir'
require_relative '../../tools/bc2cpp/compiled_gems'
require_relative '../../tools/bc2cpp/nomethod_reviewed'
require_relative '../../tools/bc2cpp/bc2cpp'

root = File.expand_path('../..', __dir__)
failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

# name => outside-Ruby source that defines it in a form a line-start scan misses
# (or, for the first one, the form it always saw).
FORMS = {
  'cw_plain' => "class CwOut\n  def cw_plain; end\nend\n",
  'cw_private' => "class CwOut\n  private def cw_private; end\nend\n",
  'cw_protected' => "class CwOut\n  protected def cw_protected; end\nend\n",
  'cw_public' => "class CwOut\n  public def cw_public; end\nend\n",
  'cw_modfun' => "module CwOut\n  module_function def cw_modfun; end\nend\n",
  'cw_pcm' => "class CwOut\n  private_class_method def self.cw_pcm; end\nend\n",
  'cw_semi' => "class CwOut; def cw_semi; end; end\n",
  'cw_oneline' => "class CwOut; class << self; def cw_oneline; end; end; end\n",
  'cw_paren' => "class CwOut\n  x = (def cw_paren; end)\nend\n",
  'cw_ternary' => "class CwOut\n  1.zero? ? nil : (def cw_ternary; end)\nend\n",
  'cw_recv' => "class CwOut\n  def CwOut.cw_recv; end\nend\n",
  'cw_selfdef' => "class CwOut\n  def self.cw_selfdef; end\nend\n",
  'cw_objdef' => "o = Object.new\ndef o.cw_objdef; end\n",
  'cw_attr' => "class CwOut\n  private attr_reader :cw_attr\nend\n",
  'cw_attrsemi' => "class CwOut; attr_accessor :cw_attrsemi; end\n",
  'cw_alias' => "class CwOut; alias cw_alias to_s; end\n",
  'cw_aliasm' => "class CwOut\n  private alias_method :cw_aliasm, :to_s\nend\n",
  'cw_defm' => "class CwOut\n  private define_method(:cw_defm) { }\nend\n",
  'cw_endless' => "class CwOut\n  private def cw_endless = 1\nend\n",
  '<=>' => "class CwOut\n  private def <=>(o) = 0\nend\n",
  'cw_heredoc' => "class CwOut\n  X = <<~T; def cw_heredoc; end\n  t\n  T\nend\n"
}.freeze
# Words a comment or string mentions are not definitions; only over-collection may differ.
NOT_DEFS = { 'cw_comment' => "# def cw_comment\nclass CwOut; end\n" }.freeze

world = <<~'RUBY'
  class CwA
    def PROBE; 1; end
  end
  class CwB
    def PROBE; 2; end
  end
  class CwCaller
    def call_it(x); x.PROBE; end
  end
RUBY

# The wio build's gem list (same as bc2cpp_closed_world_check.rb).
core_gems = %w[mruby-array-ext mruby-hash-ext mruby-enum-ext mruby-io mruby-numeric-ext mruby-range-ext mruby-fiber
               mruby-exit mruby-sprintf mruby-time mruby-bigint mruby-pack mruby-string-ext mruby-struct
               mruby-metaprog mruby-enumerator]
wio_gems = core_gems.to_h { |g| [g, "#{root}/3rd/mruby/mrbgems/#{g}"] }
wio_gems.merge!('hal-wio-io' => "#{root}/app/wio/hal-wio-io", 'mruby-math-wio' => "#{root}/app/wio/mruby-math-wio",
                'mruby-stringio' => "#{root}/3rd/mruby-stringio", 'mruby-marshal' => "#{root}/3rd/mruby-marshal")
%w[mruby-lcf mruby-lcf-compiled mruby-rgss mruby-rgss-compiled mruby-rpg2k mruby-rpg2k-compiled
   mruby-core-compiled].each { |g| wio_gems[g] = "#{root}/#{g}" }

mrbc = ENV['MRBC'] || 'mrbc'
generate = lambda do |source, name, ruby_srcs|
  Dir.mktmpdir do |dir|
    path = File.join(dir, "#{name}.rb")
    File.write(path, source)
    # The outside Ruby comes from the build's other gems' mrblib, so it rides in a fixture gem.
    gem_dir = File.join(dir, 'cw-outside')
    FileUtils.mkdir_p(File.join(gem_dir, 'mrblib'))
    ruby_srcs.each_with_index { |text, i| File.write(File.join(gem_dir, 'mrblib', "outside#{i}.rb"), text) }
    gems = wio_gems.merge('cw-outside' => gem_dir)
    env = { 'MRBC' => mrbc, 'OUT_SYMBOL' => name, 'OUT_DIR' => dir, 'SKIP_UNSUPPORTED' => '1',
                        'BC2CPP_CLOSED_WORLD' => '1', 'BC2CPP_BUILD_NAME' => 'wio',
            'BC2CPP_BUILD_GEMS' => Shellwords.join(gems.map { |n, d| "#{n}=#{d}" }),
            NomethodReviewed::ALLOW_ENV => 'allow' }
    out, err, status = Open3.capture3(env, RbConfig.ruby, File.join(root, 'tools/bc2cpp/bc2cpp.rb'), '--annotated', path)
    abort "bc2cpp.rb failed for #{name}:\n#{err[-3000..] || err}" unless status.success?
    [out, err]
  end
end
body_of = lambda do |code, fn|
  code[/^mrb_value #{fn}_impl\(mrb_state\* M.*?(?=^(?:static )?mrb_value \w+\(mrb_state\* M|\z)/m].to_s
end

# -- foreign_method_names sees every form ------------------------------------------
FORMS.each do |name, src|
  Dir.mktmpdir do |dir|
    path = File.join(dir, 'f.rb')
    File.write(path, src)
    check.call("foreign_method_names: #{name}", foreign_method_names([path]).include?(name))
  end
end

# -- and so a guard chain is not completed over a name an outside definer answers ------
FORMS.each_key do |name|
  next if name == '<=>' # the fixture world calls PROBE, an identifier
  code, = generate.call(world.gsub('PROBE', name), "cw_#{name}", [FORMS.fetch(name)])
  call = body_of.call(code, 'CwCaller_call_it')
  check.call("closed world keeps the dispatch for #{name}",
             call.include?('CLOSED_WORLD kept:') && !call.include?('bc2cpp_nomethod('))
end
code, = generate.call(world.gsub('PROBE', 'cw_none'), 'cw_none', [NOT_DEFS.fetch('cw_comment')])
check.call('control: with no outside definer the chain still ends in bc2cpp_nomethod',
           body_of.call(code, 'CwCaller_call_it').include?('bc2cpp_nomethod('))

if failures.empty?
  puts 'bc2cpp foreign def forms check: PASS'
else
  puts "bc2cpp foreign def forms check: FAIL (#{failures.size})"
  exit 1
end
