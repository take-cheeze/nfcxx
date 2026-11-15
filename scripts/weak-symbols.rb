#!/usr/bin/env ruby
# The .weak directives of EDG's generated C (tools/weak-symbols, the C++ port of the former scripts/weak-symbols.rb):
# scripts/weak-symbols.rb [--c-input] [--sym-prefix=P] [--marked=FILE] PREPROCESSED_C ASSEMBLY appends them to ASSEMBLY.
# Builds build/weak-symbols on first use (scripts/tool-ensure.rb). NFCXX_WEAK_SYMBOLS_RB=SCRIPT runs an mruby script
# with the same arguments instead (tests/mruby: the oracle tests/mruby/oracle/weak-symbols.rb).
# The Ruby port of the bash wrapper (its original is tests/helpers/oracle/weak-symbols.sh).
require_relative 'tool-ensure'

root = File.expand_path('..', __dir__)
rb = ENV['NFCXX_WEAK_SYMBOLS_RB'].to_s
ToolEnsure.exec_program(File.join(root, 'scripts/mrb.rb'), rb, *ARGV) unless rb.empty?
rc = ToolEnsure.ensure('weak-symbols', root)
exit rc unless rc.zero?
ToolEnsure.exec_program(File.join(root, 'build/weak-symbols'), *ARGV)
