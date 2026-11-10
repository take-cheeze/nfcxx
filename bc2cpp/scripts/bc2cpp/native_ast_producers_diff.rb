#!/usr/bin/env ruby
# frozen_string_literal: true

# Compares the two AST producers (tools/bc2cpp/native_ast_source.rb: clang and nfcxx) on real sources: the return kind
# NativeAstReturns gives each function (single-kind and optional modes), and the frame-free verdict and
# candidate rows (defined, external, frame_free) of NativeCoreCandidates, and the ROM tables of NativeRomExtract (each entry's function, symbol and defined flag). Prints every function whose result differs, and a summary. Exits 1 on any difference or when
# a producer fails on a file the other parses.
#
#   BC2CPP_WORLD_ROOT=/path/to/rpg-maker-clone ruby scripts/bc2cpp/native_ast_producers_diff.rb [--flags="-DX -Iy"] SRC.c...
#   (--closed=DIR as above)  ... with no SRC: every 3rd/mruby/src/*.c of the world; --world: every source the closed world
#   reads (NativeFnKinds.sources), each with its own gem's flags.
#
# The flags default to BaseRbsAll.source_flags: with --closed=DIR (a closed build, or just DIR/analysis/include/mruby/presym/id.h
# from scripts/bc2cpp/analysis_headers.rb) the real ones; without it the scanning mode, which only parses sources that do
# not name a presym.
require 'json'
require 'shellwords'
require 'time'
require_relative 'base_rbs_all'
require_relative '../../tools/bc2cpp/native_ast_returns'
require_relative '../../tools/bc2cpp/native_ast_source'
require_relative '../../tools/bc2cpp/native_core_candidates'
require_relative '../../tools/bc2cpp/native_rom_extract'

extra = nil
closed = nil
world = false
paths = []
ARGV.each do |arg|
  if arg.start_with?('--flags=') then extra = Shellwords.split(arg.delete_prefix('--flags='))
  elsif arg.start_with?('--closed=') then closed = arg.delete_prefix('--closed=')
  elsif arg == '--world' then world = true
  else paths << arg
  end
end
if world
  require_relative 'native_fn_kinds'
  paths = NativeFnKinds.sources(closed).map(&:first)
elsif paths.empty?
  paths = Dir[File.join(BaseRbsAll::MRUBY_ROOT, 'src', '*.c')].sort
end

differences = 0
totals = Hash.new(0)
paths.each do |path|
  flags = extra || BaseRbsAll.source_flags(path, closed) + (closed ? [] : ['-DMRB_PRESYM_SCANNING'])
  lang = path.end_with?('.c') ? :c : :cxx
  asts = {}
  seconds = {}
  NativeAstSource::PRODUCERS.each do |name|
    started = Time.now
    out, err, status = NativeAstSource.dump(path, flags, lang: lang, name: name)
    seconds[name] = Time.now - started
    asts[name] = status.success? ? JSON.parse(out) : (warn("  #{name} failed on #{File.basename(path)}: #{(err.lines.find { |l| l =~ /error/ } || err.lines.first)&.strip}") && nil)
  end
  if asts.values.any?(&:nil?)
    differences += 1 if asts.values.any? { |ast| !ast.nil? } && ENV['BC2CPP_DIFF_STRICT']
    puts "SKIP #{File.basename(path)} (#{asts.map { |n, a| "#{n}:#{a ? 'ok' : 'failed'}" }.join(' ')})"
    next
  end

  results = asts.transform_values do |ast|
    { kinds: NativeAstReturns.analyze(ast, path), optional: NativeAstReturns.analyze(ast, path, optional: true),
      free: NativeCoreCandidates.frame_free(ast),
      # The `*_rom_entries` tables (file-scope initializers: InitListExpr of InitListExpr, function and symbol per entry).
      rom: NativeRomExtract.extract(ast).to_h { |table| [table['table'], table['entries']] },
      candidates: NativeCoreCandidates.candidates(path, ast).to_h { |c| [c['function'], c] } }
  end
  clang, nfcxx = results.values_at('clang', 'nfcxx')
  totals[:proven] += clang[:kinds].values.count { |kind| !kind.nil? }
  bad = 0
  %i[kinds optional free candidates rom].each do |facet|
    # The frame-free verdict is read for the source's own functions (a header's unused static inline function has no
    # body in the nfcxx IL, and no consumer asks about it).
    names = clang[facet].keys | nfcxx[facet].keys
    names &= clang[:kinds].keys if facet == :free || facet == :candidates
    totals[:rom_entries] += clang[:rom].values.sum(&:size) if facet == :rom
    names.sort.each do |fn|
      totals[facet] += 1
      next if clang[facet][fn] == nfcxx[facet][fn] && clang[facet].key?(fn) == nfcxx[facet].key?(fn)

      bad += 1
      puts "  #{File.basename(path)} #{facet} #{fn}: clang=#{clang[facet][fn].inspect} nfcxx=#{nfcxx[facet][fn].inspect}"
    end
  end
  differences += bad
  puts format('%-28s %4d functions, %3d differences (clang %.1fs, nfcxx %.1fs)', File.basename(path), clang[:kinds].size, bad,
              seconds['clang'], seconds['nfcxx'])
end
puts "#{paths.size} files, #{totals[:kinds]} function kinds (#{totals[:proven]} with a kind), #{totals[:candidates]} candidate rows, #{totals[:rom]} ROM tables (#{totals[:rom_entries]} entries), #{differences} differences"
exit(differences.zero? ? 0 : 1)
