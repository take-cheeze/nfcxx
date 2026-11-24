#!/usr/bin/env ruby
# frozen_string_literal: true

# ROM_METHOD_TABLES (tools/bc2cpp/codegen_emit.rb): the closed build registers its compiled methods through const
# mrb_mt_entry tables chained into the classes, so a compiled entry takes no heap method-table entry.
#   static: no owner registration in the generated sources defines a presym-spellable name through mrb_define_*method,
#     or leaves one out through a bc2cpp_left_out call instead of a walked LEFT_OUT_TABLE stream,
#     each file installs the fiber runtime's tables, and every bc2cpp_mt_install names a table the file defines;
#     ROM_CLASS_BODY_DEFS: no class unit registers through mrb_define_*method an entry a ROM table holds;
#     CONST_PATH_WALK: no registration or direct-construct capture chains mrb_const_get, and each path it walks is a
#     row its own function defines;
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
LEFT_OUT = /\bbc2cpp_left_out\(M, \w+, "((?:[^"\\]|\\.)*)"/
# A class unit's registration (codegen_class_body.rb): the class is the unit's self or a register.
UNIT_DEFINE = /\bmrb_define_(?:private_|class_)?method\(M, mrb_class_ptr\((?:self|r\d+)\), "(?:[^"\\]|\\.)*", (\w+), /
ROW_ENTRY = /\bMRB_MT_ENTRY(?:_CTOR_)?\((\w+), /
# BC2CPP_SHARED_FN: a sharded gem's stateless prelude helper (shard_output.rb, SHARED_HELPERS).
REGISTRATION = /^(?:\[\[maybe_unused\]\] )?(?:static|inline|BC2CPP_SHARED_FN) void bc2cpp_register_(?:core|program)_owner_methods\(\[\[maybe_unused\]\] mrb_state\* M\) \{\n(.*?)^\}/m
# DIRECT_CONSTRUCT_ACCESSORS' capture function, which resolves its classes the way the registrations do.
CAPTURE = /^(?:\[\[maybe_unused\]\] )?(?:static|inline|BC2CPP_SHARED_FN) void bc2cpp_capture_direct_construct_classes\(\[\[maybe_unused\]\] mrb_state\* M\) \{\n(.*?)^\}/m
tables = 0
walked = 0
paths = 0
sources.each do |path|
  src = File.read(path)
  # RUNTIME_HEADER (tools/bc2cpp/runtime_header.rb) and CROSS_GEM_SHARE (cross_gem_share.rb): part of the prelude is
  # in the headers the file includes.
  src.scan(/^#include "([^"]*bc2cpp_(?:runtime|cs)_\h+\.hxx)"$/).flatten.uniq.each { |header| src += File.read(header) }
  name = File.basename(path)
  failures << "#{name}: no `#define BC2CPP_ROM_METHOD_TABLES 1`" unless src.include?("#define BC2CPP_ROM_METHOD_TABLES 1\n")
  defined = src.scan(/^(?:static|inline) const mrb_mt_entry (bc2cpp_mt_\w+)\[\] = \{$/).flatten.to_set
  streams = src.scan(/^(?:static|inline) constexpr uint16_t (bc2cpp_left_out_\w+)\[\] = \{$/).flatten.to_set
  walked += streams.size
  tables += defined.size
  if ENV['BC2CPP_ROM_CLASS_BODY_DEFS'] != '0'
    rows = src.scan(ROW_ENTRY).flatten.to_set
    src.scan(UNIT_DEFINE).flatten.uniq.each do |entry|
      failures << "#{name}: a class unit registers #{entry}, a ROM table row" if rows.include?(entry)
    end
  end
  bodies = src.scan(REGISTRATION).flatten
  failures << "#{name}: no registration functions" if bodies.empty?
  if ENV['BC2CPP_CONST_PATH_WALK'] != '0'
    (bodies + src.scan(CAPTURE).flatten).each do |body|
      failures << "#{name}: an init function chains mrb_const_get" if body.include?('mrb_const_get(M, mrb_const_get(')
      rows = body.scan(/static constexpr uint16_t (bc2cpp_cpath_\d+)\[\] = \{/).flatten.to_set
      body.scan(/bc2cpp_const_path_class\(M, (\w+)\)/).flatten.each do |row|
        paths += 1
        failures << "#{name}: #{row} is walked but not defined in its function" unless rows.include?(row)
      end
    end
  end
  bodies.each do |body|
    body.scan(DEFINE).flatten.each do |method|
      failures << "#{name}: #{method} is registered with mrb_define_*method" if PresymSpelling.key(method)
    end
    # LEFT_OUT_TABLE: outside a verify-only block, a left-out name presym spells is a row of a walked stream.
    body.gsub(/^#ifdef BC2CPP_UNREGISTERED_VERIFY\n.*?^#endif\n/m, '').scan(LEFT_OUT).flatten.each do |lit|
      method = lit.gsub(/\\x(\h\h)/) { Regexp.last_match(1).hex.chr }
      failures << "#{name}: #{method} is left out by a bc2cpp_left_out call" if PresymSpelling.key(method)
    end
    body.scan(/bc2cpp_left_out_walk\(M, (\w+)\);/).flatten.each do |stream|
      failures << "#{name}: #{stream} is walked but not defined" unless streams.include?(stream)
    end
    body.scan(/bc2cpp_mt_install\(M, \w+, (\w+),/).flatten.each do |table|
      failures << "#{name}: #{table} is installed but not defined" unless defined.include?(table)
    end
  end
end
failures << 'no ROM tables in any generated source' if tables.zero?
failures << 'no CONST_PATH_WALK row in any generated source' if paths.zero? && ENV['BC2CPP_CONST_PATH_WALK'] != '0'
failures << 'no LEFT_OUT_TABLE stream in any generated source' if walked.zero? && ENV['BC2CPP_LEFT_OUT_TABLE'] != '0'

summary = nil
if (i = ARGV.index('--host'))
  host, game = ARGV[i + 1], ARGV[i + 2]
  abort "rom_method_tables: no host at #{host}" unless host && File.executable?(host)
  out, status = Open3.capture2({ 'BC2CPP_HOST_MT_HEAP' => '1' }, host, game, '1')
  failures << "#{host} exited #{status.exitstatus}" unless status.success?
  summary = out[/^TRACE_HOST heap_method_tables .*$/]
  failures << 'no heap_method_tables summary' unless summary
  failures << "a heap entry duplicates a ROM entry: #{summary}" unless summary.to_s.include?(' rom_duplicates=0')
  # The C functions of the generated code: every compiled gem's are in a bc2cpp_shard_ namespace, the shared
  # runtime's in bc2cpp_rt_ (RUNTIME_HEADER).
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
puts "rom_method_tables: #{tables} tables, #{paths} const path rows in #{sources.size} generated sources#{summary ? "; #{summary.sub('TRACE_HOST ', '')}" : ''}"
