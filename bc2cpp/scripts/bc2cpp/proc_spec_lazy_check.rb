#!/usr/bin/env ruby
# frozen_string_literal: true

# PROC_SPEC_LAZY (codegen_block_fallback.rb): a core body whose every registration the closed build leaves out registers
# its blocks' Proc#arity / Proc#parameters specs where the proc is made, not at static init, so a body nothing reaches
# keeps no spec row and the linker drops its blocks with it.
#
#   - such a body's spec has a note function and no static registration; the code that makes its proc calls the note;
#   - a body that keeps a registration keeps the static one, and BC2CPP_PROC_SPEC_LAZY=0 keeps it for every body;
#   - an alias the build still registers keeps the body's spec static;
#   - behaviour: a block of the left-out body reached through a direct call answers Proc#arity and Proc#parameters as the
#     interpreter does (skipped without a full-core libmruby).
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir | BC2CPP_FULL_BUILD_DIR=dir] ruby scripts/bc2cpp/proc_spec_lazy_check.rb

require 'json'
require 'tmpdir'
require_relative 'fixture_runtime'
require_relative '../../tools/bc2cpp/static_dispatch_lists'

suite = Bc2cppStepCheck.new('proc_spec_lazy_check')

SRC = <<~RUBY
  class LzFix
    def lz_gone
      proc { |a, b| a }
    end

    def lz_aliased
      proc { |a, b, c| a }
    end
    alias lz_alias lz_aliased

    def lz_kept
      pr = lz_gone
      [pr.arity, pr.parameters, lz_aliased.arity, proc { |x| x }.arity]
    end
  end
RUBY
OWNERS = %w[LzFix].freeze
DRIVER = Bc2cppStepCheck::SHOW + <<~'RUBY'
  show('kept') { LzFix.new.lz_kept }
  puts 'end'
RUBY

lists_dir = Dir.mktmpdir('proc-spec-lazy-lists')
at_exit { FileUtils.remove_entry(lists_dir) }
lists = StaticDispatchLists::KEYS.to_h { |key| [key, []] }
lists['core_left_out'] = %w[LzFix#lz_gone LzFix#lz_aliased]
lists_path = File.join(lists_dir, 'static_dispatch_lists.json')
File.write(lists_path, JSON.generate(lists.merge('digest' => 'proc-spec-lazy-check')))

saved = %w[BC2CPP_STATIC_DISPATCH_LISTS BC2CPP_BUILD_NAME BC2CPP_PROC_SPEC_LAZY].to_h { |k| [k, ENV[k]] }
generate = lambda do |lazy|
  ENV['BC2CPP_STATIC_DISPATCH_LISTS'] = lists_path
  ENV['BC2CPP_BUILD_NAME'] = 'closed'
  lazy ? ENV.delete('BC2CPP_PROC_SPEC_LAZY') : ENV['BC2CPP_PROC_SPEC_LAZY'] = '0'
  # Under 3rd/mruby/mrblib/ the fixture is core Ruby (CoreDefs.core_source?), whose left-out bodies the rule covers.
  suite.generate(SRC, OWNERS, path: '3rd/mruby/mrblib/lz_fix.rb')
ensure
  saved.each { |k, v| v ? ENV[k] = v : ENV.delete(k) }
end

off = generate.call(false)
suite.check('BC2CPP_PROC_SPEC_LAZY=0: every spec of the fixture is registered at static init',
            !off.match?(/static void bc2cpp_proc_spec_\d+_note\(/))
code = generate.call(true)
spec_of = lambda do |fn|
  code[/static const Bc2cppProcSpec (bc2cpp_proc_spec_\d+)_row0 = \{ \(const void\*\)&#{fn}\w*,/, 1]
end
gone = spec_of.call('LzFix_lz_gone_block_fallback_')
aliased = spec_of.call('LzFix_lz_aliased_block_fallback_')
kept = spec_of.call('LzFix_lz_kept_block_fallback_')
suite.check('the three bodies compile with a spec each', gone && aliased && kept)
if gone && aliased && kept
  suite.check('the left-out body\'s spec has a note and no static registration',
              code.include?("static void #{gone}_note(mrb_state* M) {") && !code.include?("static const int #{gone} ="))
  suite.check('the note registers the row once and installs the Proc methods',
              code[/static void #{gone}_note\(mrb_state\* M\) \{.*?^\}/m].to_s
                .match?(/if \(!done\) \{ done = true; bc2cpp_proc_spec_register\(&#{gone}_row0\); bc2cpp_proc_specs_install\(M\); \}/))
  suite.check('the code that makes the left-out body\'s proc calls its note first',
              code.match?(/^\s*#{gone}_note\(M\);\n\s*mrb_value bc2cpp_blk_env_\d+\[\] = /))
  suite.check('a body that keeps a registration keeps its spec static',
              code.include?("static const int #{kept} = bc2cpp_proc_spec_register(&#{kept}_row0);"))
  suite.check('a body registered under an alias keeps its spec static',
              code.include?("static const int #{aliased} = bc2cpp_proc_spec_register(&#{aliased}_row0);"))
end
suite.check('lz_kept reaches lz_gone without a lookup', code.include?('LzFix_lz_gone_impl('))

suite.behaviour(DRIVER, same: false) do |interpreted, compiled|
  suite.check('Proc#arity and #parameters of the lazily registered block answer as interpreted',
              interpreted == compiled && compiled.first.to_s.include?('[2, [[:opt, :a], [:opt, :b]], 3, 1]'))
  suite.report_diff(interpreted, compiled) unless interpreted == compiled
end
suite.finish
