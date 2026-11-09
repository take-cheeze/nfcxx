#!/usr/bin/env ruby
# frozen_string_literal: true

# ROM_METHOD_TABLES (tools/bc2cpp/codegen_emit.rb): the closed build registers its compiled methods through const
# mrb_mt_entry tables chained into the classes, so a compiled entry takes no heap method-table entry.
#   static: no owner registration in the generated sources defines a presym-spellable name through mrb_define_*method,
#     each file installs the fiber runtime's tables, and every bc2cpp_mt_install names a table the file defines;
#   --host TRACE_HOST GAME_DIR: after boot no heap entry duplicates a ROM entry below it and none is a C function of the
#     generated code (nm), so what stays on the heap is the natives' and class bodies' attr_* procs.
#
#   ruby scripts/bc2cpp/rom_method_tables_check.rb <closed-build-dir> [--host TRACE_HOST GAME_DIR]
require 'open3'
require 'set'
require_relative '../../tools/bc2cpp/presym_spelling'

dir = ARGV.fetch(0) { abort 'usage: rom_method_tables_check.rb <closed-build-dir> [--host TRACE_HOST GAME_DIR]' }
failures = []
sources = Dir[File.join(dir, 'mrbgems/*-compiled/*_gen.cpp')].sort
abort "rom_method_tables: no generated sources under #{dir}/mrbgems" if sources.empty?

DEFINE = /\b(?:mrb_define_(?:private_|class_)?method|bc2cpp_define_private_class_method)\(M, bc2cpp_owner_reg_\w+, "((?:[^"\\]|\\.)*)"/
REGISTRATION = /^(?:\[\[maybe_unused\]\] )?(?:static|inline) void bc2cpp_register_(?:core|program)_owner_methods\(\[\[maybe_unused\]\] mrb_state\* M\) \{\n(.*?)^\}/m
tables = 0
sources.each do |path|
  src = File.read(path)
  name = File.basename(path)
  failures << "#{name}: no `#define BC2CPP_ROM_METHOD_TABLES 1`" unless src.include?("#define BC2CPP_ROM_METHOD_TABLES 1\n")
  defined = src.scan(/^(?:static|inline) const mrb_mt_entry (bc2cpp_mt_\w+)\[\] = \{$/).flatten.to_set
  tables += defined.size
  bodies = src.scan(REGISTRATION).flatten
  failures << "#{name}: no registration functions" if bodies.empty?
  bodies.each do |body|
    body.scan(DEFINE).flatten.each do |method|
      failures << "#{name}: #{method} is registered with mrb_define_*method" if PresymSpelling.key(method)
    end
    body.scan(/bc2cpp_mt_install\(M, \w+, (\w+),/).flatten.each do |table|
      failures << "#{name}: #{table} is installed but not defined" unless defined.include?(table)
    end
  end
end
failures << 'no ROM tables in any generated source' if tables.zero?

summary = nil
if (i = ARGV.index('--host'))
  host, game = ARGV[i + 1], ARGV[i + 2]
  abort "rom_method_tables: no host at #{host}" unless host && File.executable?(host)
  out, status = Open3.capture2({ 'BC2CPP_HOST_MT_HEAP' => '1' }, host, game, '1')
  failures << "#{host} exited #{status.exitstatus}" unless status.success?
  summary = out[/^TRACE_HOST heap_method_tables .*$/]
  failures << 'no heap_method_tables summary' unless summary
  failures << "a heap entry duplicates a ROM entry: #{summary}" unless summary.to_s.include?(' rom_duplicates=0')
  # The C functions of the generated code: every compiled gem's are in a bc2cpp_shard_ namespace.
  symbols = Open3.capture2('nm', '-C', '--defined-only', host).first.lines.filter_map do |line|
    addr, type, name = line.chomp.split(' ', 3)
    [addr.to_i(16), name] if name && %w[t T w W].include?(type)
  end.sort
  starts = symbols.map(&:first)
  procs = 0
  out.scan(/^TRACE_HOST_MT_HEAP (\S+) (\S+) (func|cfuncproc) (\h+)$/).each do |klass, method, kind, offset|
    k = starts.bsearch_index { |a| a > offset.to_i(16) }
    fn = symbols[(k || symbols.size) - 1]&.last.to_s
    next unless fn.start_with?('bc2cpp_shard_')

    # A class body's attr_* is a cfunc proc over the ivar name (bc2cpp_mod_attr), a run-time definition.
    next procs += 1 if kind == 'cfuncproc'

    failures << "#{klass}##{method} is a heap entry of the generated #{fn}"
  end
  summary = "#{summary} class_body_attr_procs=#{procs}" if summary
end

abort failures.map { |f| "rom_method_tables: #{f}" }.join("\n") unless failures.empty?
puts "rom_method_tables: #{tables} tables in #{sources.size} generated sources#{summary ? "; #{summary.sub('TRACE_HOST ', '')}" : ''}"
