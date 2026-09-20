#!/usr/bin/env ruby
# frozen_string_literal: true

# Assembles a single runnable mruby script from the 3rd/optcarrot submodule
# (real, unpatched upstream source -- see README.md) plus this directory's
# shims.rb and runner_tail.rb. Not committed to the repo since it's fully
# mechanical to regenerate.
#
# mruby has no `require`/`load`, so optcarrot's own require_relative-based
# file layout can't be used as-is: this walks the exact same 9 files in the
# exact same order optcarrot.rb's own require_relative list loads them in
# (nes.rb first -- it defines constants cpu.rb's own class body reads at
# load time -- then opt.rb before cpu.rb/ppu.rb, which each require_relative
# it themselves), stripping every require_relative line since the
# concatenation IS the loading.
#
# Running the bundle also needs 3rd/mruby patched with
# patches/mruby-module-function-scope.patch (applied here, idempotent) --
# without it, optcarrot's own driver.rb/palette.rb/driver/misc.rb (bare
# `module_function`) fail to load with a NoMethodError vendored mruby never
# implemented that scope form for. See that patch's own preamble, and
# ../../cmake/build-mruby.cmake, which applies it to the project's real
# mruby build the same way.
#
# Set OPTCARROT_NO_SHIMS=1 to make a CRuby bundle using upstream APIs directly.
# Usage: build_bundle.rb OUT_FILE

require 'fileutils'
require 'open3'

ROOT = File.expand_path('../..', __dir__)
PROBE_DIR = __dir__
OPTCARROT_DIR = File.join(ROOT, '3rd/optcarrot')
MRUBY_DIR = File.join(ROOT, '3rd/mruby')
MODFUNC_PATCH = File.join(ROOT, 'patches/mruby-module-function-scope.patch')
APPLY_SCRIPT = File.join(ROOT, 'scripts/apply_mruby_patch.bash')

out_file = ARGV[0] or abort "usage: #{$PROGRAM_NAME} OUT_FILE"

unless Dir.exist?(File.join(OPTCARROT_DIR, 'lib'))
  abort "#{OPTCARROT_DIR} is empty -- run `git submodule update --init 3rd/optcarrot` first"
end

unless Dir.exist?(File.join(MRUBY_DIR, 'include'))
  abort "#{MRUBY_DIR} is empty -- run `git submodule update --init 3rd/mruby` first"
end

system(APPLY_SCRIPT, MRUBY_DIR, MODFUNC_PATCH, exception: true)

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

# The CPU dispatch table contains arrays describing each
# opcode's method and arguments. `send(*table_entry)` makes mruby duplicate
# that array on every instruction (OP_SEND's splat semantics). Emit the same
# call with fixed positional arguments instead, avoiding one temporary Array
# per opcode while keeping the table and dynamic method lookup intact.
CPU_DISPATCH_SPLAT = "send(*DISPATCH[@opcode])"
CPU_DISPATCH_DIRECT = <<~RUBY.chomp
  dispatch = DISPATCH[@opcode]
  case dispatch.length
  when 1 then send(dispatch[0])
  when 2 then send(dispatch[0], dispatch[1])
  when 3 then send(dispatch[0], dispatch[1], dispatch[2])
  when 4 then send(dispatch[0], dispatch[1], dispatch[2], dispatch[3])
  else raise "invalid opcode dispatch"
  end
RUBY

File.open(out_file, 'w') do |out|
  unless ENV['OPTCARROT_NO_SHIMS'] == '1'
    out.write(File.read(File.join(PROBE_DIR, 'shims.rb')))
  end
  cpu_dispatch_rewritten = false
  FILES.each do |f|
    File.foreach(f) do |line|
      next if line =~ /^\s*require_relative\b/

      if f.end_with?('/optcarrot/cpu.rb') && line.include?(CPU_DISPATCH_SPLAT)
        raise 'CPU dispatch splat occurs more than once' if cpu_dispatch_rewritten

        cpu_dispatch_rewritten = true
        line = line.sub(CPU_DISPATCH_SPLAT, CPU_DISPATCH_DIRECT.lines.map { |part| "          #{part}" }.join)
      end
      out.write(line)
    end
    out.write("\n")
  end
  raise 'optcarrot CPU dispatch splat not found' unless cpu_dispatch_rewritten

  out.write(File.read(File.join(PROBE_DIR, 'runner_tail.rb')))
end

warn "wrote #{out_file}"
