#!/usr/bin/env ruby
# frozen_string_literal: true

# Builds the full-core host libmruby the width-sensitive bc2cpp checks run against (ADR 0300):
#   int32     -DMRB_32BIT -DMRB_INT32: the Emscripten/Wio/PSP arithmetic (31-bit Fixnums, 32-bit
#             mrb_int) on the 64-bit host; its bin/mrbc is the BC2CPP_MRBC32 the checks need.
#   nobigint  every full-core gem except mruby-bigint: mruby's default width then is a 32-bit mrb_int
#             where every Integer is a Fixnum and an overflow raises RangeError.
# The mruby tree must already be patched (cmake --build <dir> --target mruby_host_mrbc does it).
#
# Usage: ruby scripts/bc2cpp/width_build.rb int32|nobigint OUT_DIR   (libmruby.a lands in OUT_DIR/host/lib)

require 'etc'
require 'fileutils'
require_relative 'cxx'

ROOT = File.expand_path('../..', __dir__)

CONFIG = <<~RUBY
  MRuby::Build.new('host') do |conf|
    toolchain :gcc
    %<gems>s
    conf.gem '%<root>s/3rd/mruby-stringio'
    %<defines>s
    conf.cxx.flags << '-std=gnu++17'
    enable_cxx_exception
    enable_debug
    [conf.cc, conf.cxx].each { |t| t.flags = t.flags.flatten.delete_if { |v| v == '-O0' } << '-O1' }
  end
RUBY

# mrbgems/full-core.gembox's own exclusions, plus mruby-bigint and mruby-rational (its Rational#== helper does not compile without bigint).
NO_BIGINT_GEMS = <<~'RUBY'.strip
  Dir.glob("#{root}/mrbgems/mruby-*/mrbgem.rake") do |x|
      g = File.basename(File.dirname(x))
      conf.gem :core => g unless g =~ /^mruby-(?:bin-debugger|test|sleep|bigint|rational)$/
    end
RUBY

VARIANTS = {
  'int32' => { gems: "conf.gembox 'full-core'",
               defines: "[conf.cc, conf.cxx].each { |t| t.defines << 'MRB_32BIT' << 'MRB_INT32' }" },
  'nobigint' => { gems: NO_BIGINT_GEMS, defines: '' }
}.freeze

variant, work = ARGV
abort "usage: #{$PROGRAM_NAME} #{VARIANTS.keys.join('|')} OUT_DIR" unless VARIANTS.key?(variant) && work

work = File.expand_path(work)
FileUtils.mkdir_p(File.join(work, 'repos/host'))
FileUtils.ln_sf(File.join(ROOT, '3rd/mgem-list'), File.join(work, 'repos/host/mgem-list'))
File.write(File.join(work, 'config.rb'), format(CONFIG, root: ROOT, **VARIANTS.fetch(variant)))
env = { 'MRUBY_CONFIG' => File.join(work, 'config.rb'), 'MRUBY_BUILD_DIR' => work }.merge(Bc2cppCxx.rake_env)
abort "#{variant} mruby build failed" unless system(env, 'rake', "-j#{Etc.nprocessors}", 'all',
                                                     chdir: File.join(ROOT, '3rd/mruby'))
%w[lib/libmruby.a bin/mrbc].each do |rel|
  abort "#{variant} build produced no #{rel} under #{work}/host" unless File.exist?(File.join(work, 'host', rel))
end
puts "#{variant}: #{work}/host"
