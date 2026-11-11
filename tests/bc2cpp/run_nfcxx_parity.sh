#!/usr/bin/env bash
# nfcxx against clang inside bc2cpp, on the pinned world's mruby (tests/bc2cpp/fetch.sh). Fails on any difference:
#   1. AST producers: native_ast_returns_check.rb (the fixture) runs every available producer (clang, nfcxx) and fails if
#      either misses an expectation; native_ast_producers_diff.rb compares clang's and nfcxx's return kinds, frame-free
#      verdicts and candidate rows over mruby's src/*.c (docs/notes/nfcxx-ast.md).
#   2. Preprocessor: BaseRbsNative.preprocess + scan with BC2CPP_PREPROCESSOR=clang against =nfcxx (scripts/nfcxx-cpp),
#      over a fixed list of mruby sources; the registrations found must be identical.
#   3. cxx_fiber_check.rb with CXX=nfcxx (NFCXX_PARITY_FIBER=1; builds a full-core libmruby, minutes).
# Needs clang, the EDG front end (scripts/setup-edg.sh), the AST front end (scripts/setup-libclang-edg.sh) and, for step 3,
# QBE (scripts/setup-qbe.sh). Ruby 4.0 and the root Gemfile's gems.
#   BC2CPP_RPG_DIR=dir      an existing rpg-maker-clone checkout (tests/bc2cpp/fetch.sh)
#   NFCXX_PARITY_FIBER=1    also step 3 (default: off)
set -eu
cd "$(dirname "$0")/../.."
root=$PWD
. tests/bc2cpp/fetch.sh
bc2cpp_fetch || exit 1
export BC2CPP_WORLD_ROOT=$bc2cpp_root LANG=C.UTF-8
run_ruby() { if command -v bundle >/dev/null 2>&1 && [ -f Gemfile.lock ]; then bundle exec ruby "$@"; else ruby "$@"; fi; }

for need in build/edg/bin/cpfe build/libclang-edg/cmake/bin/cpfe; do
  [ -x "$need" ] || { echo "FAIL nfcxx_parity: $need is missing (scripts/setup-edg.sh, scripts/setup-libclang-edg.sh)"; exit 1; }
done
command -v clang >/dev/null || { echo "FAIL nfcxx_parity: clang is not installed"; exit 1; }

echo "== 1a. native_ast_returns_check (clang and nfcxx)"
out=$(run_ruby bc2cpp/scripts/bc2cpp/native_ast_returns_check.rb) || { echo "$out"; echo "FAIL nfcxx_parity: native_ast_returns_check"; exit 1; }
echo "$out" | tail -5
for p in clang nfcxx; do
  echo "$out" | grep -q "$p" || { echo "$out"; echo "FAIL nfcxx_parity: native_ast_returns_check did not exercise $p"; exit 1; }
done

echo "== 1b. native_ast_producers_diff over mruby src/*.c"
# The presym ids the sources name (the analysis overlay of scripts/bc2cpp/analysis_headers.rb, from mruby's own scanner),
# without a closed build: a directory holding only analysis/include/mruby/presym/id.h.
closed=$root/build/nfcxx-parity/closed
rm -rf "$closed"; mkdir -p "$closed"
run_ruby -e '
  require "fileutils"
  require File.expand_path("bc2cpp/scripts/bc2cpp/analysis_headers", Dir.pwd)
  work = File.join(File.expand_path(ARGV[0]), "analysis")
  FileUtils.mkdir_p(work)
  sources = Dir[File.join(BaseRbsAll::MRUBY_ROOT, "src", "*.c")].sort
  # mruby'"'"'s presym scanner reads the preprocessed text, so the two preprocessors must name the same symbols.
  by_pp = %w[clang nfcxx].to_h do |pp|
    ENV["BC2CPP_PREPROCESSOR"] = pp
    [pp, AnalysisHeaders.scan(sources, nil, work).uniq.sort_by { |s| [s.size, s] }]
  end
  abort "FAIL nfcxx_parity: presym scan differs: clang-only #{(by_pp["clang"] - by_pp["nfcxx"]).first(5)}, nfcxx-only #{(by_pp["nfcxx"] - by_pp["clang"]).first(5)}" unless by_pp["clang"] == by_pp["nfcxx"]
  names = by_pp["clang"]
  abort "FAIL nfcxx_parity: the presym scan found no names" if names.empty?
  presym = MRuby::Presym.new(Struct.new(:build_dir).new(work))
  FileUtils.mkdir_p(presym.header_dir)
  presym.write_id_header(names)
  FileUtils.rm_rf(File.join(work, "scan"))
  warn "presym ids: #{names.size} names from #{sources.size} sources"
' "$closed"
# presym.header_dir is analysis/include/mruby/presym (analysis_headers.rb writes the same layout).
test -f "$closed/analysis/include/mruby/presym/id.h" || { echo "FAIL nfcxx_parity: no presym id.h generated"; exit 1; }
rc=0
diff_out=$(run_ruby bc2cpp/scripts/bc2cpp/native_ast_producers_diff.rb --closed="$closed") || rc=$?
echo "$diff_out" | tail -15
[ "$rc" = 0 ] || { echo "FAIL nfcxx_parity: the AST producers differ (exit $rc)"; exit 1; }
parsed=$(echo "$diff_out" | grep -c ' functions, ' || true)
[ "$parsed" -ge 20 ] || { echo "FAIL nfcxx_parity: only $parsed sources parsed by both producers (vacuous)"; exit 1; }

echo "== 2. preprocessor: clang vs nfcxx"
run_ruby -e '
  require File.expand_path("bc2cpp/scripts/bc2cpp/base_rbs_all", Dir.pwd)
  world = BaseRbsAll::MRUBY_ROOT
  # The core classes, and gems with registrations and ROM tables.
  list = %w[src/class.c src/kernel.c src/object.c src/string.c src/array.c src/hash.c src/numeric.c src/range.c
            src/error.c src/proc.c src/variable.c src/enum.c
            mrbgems/mruby-fiber/src/fiber.c mrbgems/mruby-time/src/time.c mrbgems/mruby-struct/src/struct.c
            mrbgems/mruby-math/src/math.c mrbgems/mruby-io/src/io.c mrbgems/mruby-pack/src/pack.c
            mrbgems/mruby-sprintf/src/sprintf.c mrbgems/mruby-compiler/core/codegen.c].map { |r| File.join(world, r) }
  list.reject { |p| File.file?(p) }.each { |p| warn "missing #{p}" }
  list.select! { |p| File.file?(p) }
  abort "FAIL nfcxx_parity: too few sources (#{list.size})" if list.size < 12
  bad = 0
  members = 0
  list.each do |path|
    flags = BaseRbsAll.source_flags(path, ARGV[0])
    scans = %w[clang nfcxx].to_h do |pp|
      ENV["BC2CPP_PREPROCESSOR"] = pp
      [pp, BaseRbsNative.scan(BaseRbsNative.preprocess(path, flags))]
    rescue StandardError => e
      [pp, "ERROR #{e.message.lines.first}"]
    end
    if scans["clang"] == scans["nfcxx"]
      n = scans["clang"].is_a?(Array) ? scans["clang"][2].size : 0
      members += n
      puts format("%-24s %4d registrations, identical", File.basename(path), n)
    else
      bad += 1
      puts "DIFF #{path.delete_prefix(world)}"
      a, b = scans.values_at("clang", "nfcxx").map { |s| s.is_a?(Array) ? s[2] : [s] }
      puts "  only clang: #{(a - b).first(5).inspect}", "  only nfcxx: #{(b - a).first(5).inspect}"
    end
  end
  abort "FAIL nfcxx_parity: #{bad} source(s) scan differently" if bad.positive?
  abort "FAIL nfcxx_parity: no registrations found (vacuous)" if members.zero?
  puts "preprocessors: #{list.size} sources, #{members} registrations, identical"
' "$closed"

if [ "${NFCXX_PARITY_FIBER:-}" = 1 ]; then
  echo "== 3. cxx_fiber_check with CXX=nfcxx"
  for need in build/qbe/qbe build/edg/bin/eccp; do
    [ -x "$need" ] || { echo "FAIL nfcxx_parity: $need is missing (scripts/setup-qbe.sh, scripts/setup-edg.sh)"; exit 1; }
  done
  # The driver's C++ tools (build.ninja: ${CXX:-g++}) are built on first use; with CXX=nfcxx in the environment they would
  # build themselves with the driver that needs them (the build waits on its own lock), so they are built with g++ first.
  for tool in qbe-prep weak-symbols; do env -u CXX -u CXXFLAGS ninja -C "tools/$tool" >/dev/null; done
  export BC2CPP_FULL_BUILD_DIR=${BC2CPP_FULL_BUILD_DIR:-$root/build/nfcxx-parity/full}
  host=$(run_ruby -e 'require "./bc2cpp/scripts/bc2cpp/fixture_runtime"; puts(Bc2cppFixtureRuntime.full_or_build || abort("full-core mruby unavailable"))')
  rc=0
  fiber_out=$(CXX="$root/nfcxx" BC2CPP_MRUBY_FULL=$host run_ruby bc2cpp/scripts/bc2cpp/cxx_fiber_check.rb) || rc=$?
  echo "$fiber_out" | tail -8
  [ "$rc" = 0 ] || { echo "FAIL nfcxx_parity: cxx_fiber_check (exit $rc)"; exit 1; }
  if echo "$fiber_out" | grep -q '^SKIP'; then echo "FAIL nfcxx_parity: cxx_fiber_check skipped"; exit 1; fi
fi
echo "nfcxx_parity: ok"
