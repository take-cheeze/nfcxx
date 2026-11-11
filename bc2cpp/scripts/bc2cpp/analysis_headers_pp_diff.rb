#!/usr/bin/env ruby
# frozen_string_literal: true

# The analysis headers (scripts/bc2cpp/analysis_headers.rb) generated with each preprocessor: BC2CPP_PREPROCESSOR=clang and =nfcxx
# (scripts/nfcxx-cpp) over the same sources, AnalysisHeaders.native_sources (the closed world's natives, the compiler's C and
# the RGSS sources), through mruby's own presym scanner. The presym ID header must be byte-identical; exits 1 otherwise.
#
#   BC2CPP_WORLD_ROOT=/path/to/rpg-maker-clone ruby scripts/bc2cpp/analysis_headers_pp_diff.rb OUT_DIR
#
# Writes OUT_DIR/analysis/include/mruby/presym/id.h (the clang one, equal to the nfcxx one). A checkout without every submodule
# cannot preprocess some sources (stb, lvgl, uni-algo, the Onigmo tarball): a source that fails is dropped from the scan, and
# must fail in both preprocessors. The Onigmo header and the closed build's own presym list are not part of the comparison
# (they do not depend on the preprocessor).
require 'fileutils'
require_relative 'analysis_headers'

out = ARGV.shift or abort 'usage: analysis_headers_pp_diff.rb OUT_DIR'
out = File.expand_path(out)

failed = Hash.new { |h, k| h[k] = [] }
class << BaseRbsNative
  alias_method :preprocess_strict, :preprocess

  def preprocess(path, flags)
    preprocess_strict(path, flags)
  rescue RuntimeError
    (Thread.current[:analysis_headers_failed] ||= []) << path
    ''
  end
end

sources = AnalysisHeaders.native_sources
headers = %w[clang nfcxx].to_h do |pp|
  ENV['BC2CPP_PREPROCESSOR'] = pp
  Thread.current[:analysis_headers_failed] = []
  work = File.join(out, pp)
  FileUtils.rm_rf(work)
  FileUtils.mkdir_p(work)
  names = AnalysisHeaders.scan(sources, nil, work).uniq.sort_by { |s| [s.size, s] }
  failed[pp] = Thread.current[:analysis_headers_failed]
  presym = MRuby::Presym.new(Struct.new(:build_dir).new(work))
  FileUtils.mkdir_p(presym.header_dir)
  presym.write_id_header(names)
  FileUtils.rm_rf(File.join(work, 'scan'))
  [pp, [names, File.join(presym.header_dir, 'id.h')]]
end
unless failed['clang'] == failed['nfcxx']
  abort "FAIL analysis headers: sources only one preprocessor fails on: clang #{(failed['clang'] - failed['nfcxx']).inspect}, " \
        "nfcxx #{(failed['nfcxx'] - failed['clang']).inspect}"
end
names = headers.transform_values(&:first)
unless names['clang'] == names['nfcxx']
  abort "FAIL analysis headers: presym names differ: clang-only #{(names['clang'] - names['nfcxx']).first(5)}, " \
        "nfcxx-only #{(names['nfcxx'] - names['clang']).first(5)}"
end
abort 'FAIL analysis headers: no presym names found (vacuous)' if names['clang'].size < 100
unless File.binread(headers['clang'].last) == File.binread(headers['nfcxx'].last)
  abort 'FAIL analysis headers: the presym id.h differs between the preprocessors'
end
overlay = File.join(out, 'analysis')
FileUtils.rm_rf(overlay)
FileUtils.mkdir_p(File.join(overlay, 'include', 'mruby', 'presym'))
FileUtils.cp(headers['clang'].last, File.join(overlay, 'include', 'mruby', 'presym', 'id.h'))
FileUtils.rm_rf(File.join(out, 'clang'))
FileUtils.rm_rf(File.join(out, 'nfcxx'))
puts "analysis headers: #{names['clang'].size} presym IDs from #{sources.size - failed['clang'].size} of #{sources.size} sources " \
     "(#{failed['clang'].size} unreadable without their submodules in both), id.h byte-identical"
