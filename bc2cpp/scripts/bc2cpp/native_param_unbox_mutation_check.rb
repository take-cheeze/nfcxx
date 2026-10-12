#!/usr/bin/env ruby
# frozen_string_literal: true

# Mutants for scripts/bc2cpp/native_param_unbox_check.rb (ADR 0372), generated-code half only
# (PU_GENERATED_ONLY=1). Each one weakens a condition the unboxing needs and must be caught;
# the control must pass.
require 'fileutils'
require 'rbconfig'
require 'tmpdir'
require_relative 'mutant_pool'
ROOT = File.expand_path('../..', __dir__)
abort 'SKIP: set MRBC' unless ENV['MRBC']
UNBOX = 'codegen_native_param_unbox.rb'
MUTANTS = [
  ['control', nil, nil, nil, {}],
  # Every name counts as proven: an alias, an installer or a singleton method loses the gate the world needs.
  ['name proof dropped', UNBOX,
   "!symbol_installed_names.include?(name) && !devirt_blocked_name?(name) &&\n      @closed_world.native_exact_direct_name_safe?(name, NativeExactDirect::RGSS_SRC)",
   'true', {}],
  # No name counts as proven: the Integer gate and its by-name else stay everywhere.
  ['gate never dropped', UNBOX, 'safe = native_param_unbox_name?(name)', 'safe = false', {}],
  # The conversions are operands of the call again, so their order is the compiler's.
  ['float conversion inline', UNBOX,
   "stmts << \"mrb_float \#{local} = mrb_as_float(M, \#{argv[i]});\"\n        local",
   "\"mrb_as_float(M, \#{argv[i]})\"", {}],
  ['int conversion inline', UNBOX,
   "stmts << \"mrb_int \#{local} = mrb_as_int(M, \#{argv[i]});\"\n        local",
   "\"mrb_as_int(M, \#{argv[i]})\"", {}],
  # The statements run last-argument-first.
  ['conversions reversed', UNBOX, '[stmts, args]', '[stmts.reverse, args]', {}],
  # An :int the proof does not cover is read with mrb_integer, which is undefined on a Float.
  ['unproven int read unconverted', UNBOX, 'unboxed: safe ? proven : ints', 'unboxed: ints', {}],
  # Bitmap.new loses the tag test that selects the size form over the String form.
  ['Bitmap first argument untested', 'codegen_send.rb',
   "arg_checks = native_int_arg_proven?(*int_site, argv, 0) ? '' : \"mrb_integer_p(\#{argv[0]})\"", "arg_checks = ''", {}],
  # Rect.new/Color.new unbox inside the call again.
  ['construct unboxed inline', 'codegen_send.rb',
   'if native_param_unbox_on? && %i[int float].include?(native[:arg_type])', 'if false', {}]
].freeze
work = lambda do |(_name, file, pattern, replacement, extra)|
  Dir.mktmpdir('native-param-mutant') do |dir|
    FileUtils.cp_r(File.join(ROOT, 'tools'), dir)
    if file
      path = File.join(dir, 'tools/bc2cpp', file)
      source = File.read(path)
      next nil unless source.include?(pattern)

      File.write(path, source.sub(pattern) { replacement })
    end
    env = { 'BC2CPP_TOOL' => File.join(dir, 'tools/bc2cpp/bc2cpp.rb'), 'PU_GENERATED_ONLY' => '1',
           # The copy of tools/ has no scripts/ next to it for the lint cross-check (ADR 0368) to find.
           'BC2CPP_LINT_CROSSCHECK' => '0' }.merge(extra)
    Bc2cppMutantPool.run(env, [RbConfig.ruby, File.join(ROOT, 'scripts/bc2cpp/native_param_unbox_check.rb')],
                        stop_on: /^\s+FAIL /)
  end
end
failures = []
Bc2cppMutantPool.each_ordered(MUTANTS, work: work) do |(name, file, _pattern, _replacement, _extra), run|
  ok = run && (file ? run.out.match?(/^\s+FAIL /) : run.success)
  puts "  #{ok ? 'ok  ' : 'FAIL'} #{name}"
  failures << name unless ok
  warn run&.out unless ok
end
abort "FAILED: #{failures.join(', ')}" unless failures.empty?
puts 'bc2cpp native param unbox mutation check: PASS'
