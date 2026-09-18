#!/usr/bin/env ruby
# frozen_string_literal: true

# Assembles a single runnable mruby script from the 3rd/optcarrot submodule
# (patched -- see below) plus this directory's shims.rb and runner_tail.rb.
# See README.md for why this exists and what each piece does; not committed
# to the repo since it's fully mechanical to regenerate.
#
# mruby has no `require`/`load`, so optcarrot's own require_relative-based
# file layout can't be used as-is: this walks the exact same 9 files in the
# exact same order optcarrot.rb's own require_relative list loads them in
# (nes.rb first -- it defines constants cpu.rb's own class body reads at
# load time -- then opt.rb before cpu.rb/ppu.rb, which each require_relative
# it themselves), stripping every require_relative line since the
# concatenation IS the loading.
#
# Usage: build_bundle.rb OUT_FILE

require 'fileutils'
require 'open3'

ROOT = File.expand_path('../..', __dir__)
PROBE_DIR = __dir__
OPTCARROT_DIR = File.join(ROOT, '3rd/optcarrot')
PATCH = File.join(ROOT, 'patches/optcarrot-module-function-scope.patch')
APPLY_SCRIPT = File.join(ROOT, 'scripts/apply_mruby_patch.bash')

out_file = ARGV[0] or abort "usage: #{$PROGRAM_NAME} OUT_FILE"

unless Dir.exist?(File.join(OPTCARROT_DIR, 'lib'))
  abort "#{OPTCARROT_DIR} is empty -- run `git submodule update --init 3rd/optcarrot` first"
end

system(APPLY_SCRIPT, OPTCARROT_DIR, PATCH, exception: true)

# Real require_relative order from 3rd/optcarrot/lib/optcarrot.rb, with
# opt.rb spliced in where cpu.rb's and ppu.rb's own require_relative "opt"
# put it (both need CodeOptimizationHelper defined before their own class
# bodies reference it, even though only the --opt path actually calls it).
LIB = File.join(OPTCARROT_DIR, 'lib')
FILES = %w[
  optcarrot.rb
  optcarrot/nes.rb
  optcarrot/rom.rb
  optcarrot/pad.rb
  optcarrot/opt.rb
  optcarrot/cpu.rb
  optcarrot/apu.rb
  optcarrot/ppu.rb
  optcarrot/palette.rb
  optcarrot/driver.rb
  optcarrot/config.rb
].map { |f| File.join(LIB, f) }

File.open(out_file, 'w') do |out|
  out.write(File.read(File.join(PROBE_DIR, 'shims.rb')))
  FILES.each do |f|
    File.foreach(f) do |line|
      out.write(line) unless line =~ /^\s*require_relative\b/
    end
    out.write("\n")
  end
  out.write(File.read(File.join(PROBE_DIR, 'runner_tail.rb')))
end

warn "wrote #{out_file}"
