#!/usr/bin/env ruby
# encoding: UTF-8
#
# optcarrot bc2cpp coverage report: the same measurement
# scripts/bc2cpp_coverage_report.rb makes for the real project's own 3
# compiled gems (mruby-lcf-compiled/mruby-rgss-compiled/mruby-rpg2k-compiled),
# run instead against optcarrot's own real source (3rd/optcarrot/lib) as its
# own standalone closed world -- see tools/optcarrot_probe/README.md for what
# this is and isn't (a scoping probe, not part of the real project's
# mruby-lcf/rgss/rpg2k registry or build). Reuses that script's exact
# section-parsing/report-formatting logic; the two scripts should be kept in
# sync by hand if bc2cpp.rb's own `== ... ==` diagnostic section list changes.
#
# Usage: MRBC=path/to/host/mrbc ruby tools/optcarrot_probe/optcarrot_bc2cpp_coverage_report.rb
# MRBC must be built from a 3rd/mruby checkout with
# patches/mruby-parser-dump-back-nth-ref.patch applied -- see
# tools/optcarrot_probe/bc2cpp_probe.rb's own header for why.
# Writes the report to stdout. Set BC2CPP_COVERAGE_REPORT_PATH to capture it
# in a file; CI publishes it in the build job summary.

require 'shellwords'
require 'open3'
require 'tmpdir'
require 'set'

ROOT = File.expand_path('../..', __dir__)
require_relative '../bc2cpp/compiled_gems'

BC2CPP = File.join(ROOT, 'tools/bc2cpp/bc2cpp.rb')
MRBC = ENV['MRBC'] || 'mrbc'
REPORT_PATH = ENV['BC2CPP_COVERAGE_REPORT_PATH']
OPTCARROT_LIB = File.join(ROOT, '3rd/optcarrot/lib')
MRUBY_DIR = File.join(ROOT, '3rd/mruby')
PARSER_DUMP_PATCH = File.join(ROOT, 'patches/mruby-parser-dump-back-nth-ref.patch')
APPLY_SCRIPT = File.join(ROOT, 'scripts/apply_mruby_patch.bash')

unless Dir.exist?(OPTCARROT_LIB)
  abort "#{OPTCARROT_LIB} is empty -- run `git submodule update --init 3rd/optcarrot` first"
end

system(APPLY_SCRIPT, MRUBY_DIR, PARSER_DUMP_PATCH, exception: true) if Dir.exist?(MRUBY_DIR)

# Same require_relative order build_bundle.rb/bc2cpp_probe.rb use.
srcs = %w[
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
].map { |f| File.join(OPTCARROT_LIB, f) }

native_srcs = core_native_srcs(MRUBY_DIR) + Dir[File.join(ROOT, '3rd/mruby-onig-regexp/src/*.c')]
foreign_ruby_srcs = Dir[File.join(ROOT, '3rd/mruby/mrblib/**/*.rb')] +
                    Dir[File.join(ROOT, '3rd/mruby/mrbgems/*/mrblib/**/*.rb')] +
                    Dir[File.join(ROOT, '3rd/mruby-onig-regexp/mrblib/**/*.rb')]

env = {
  'MRBC' => MRBC,
  'OUT_SYMBOL' => 'optcarrot_coverage_report',
  'NATIVE_SRCS' => Shellwords.join(native_srcs),
  'FOREIGN_RUBY_SRCS' => Shellwords.join(foreign_ruby_srcs),
}
cmd = [RbConfig.ruby, BC2CPP, *srcs].shelljoin
Dir.mktmpdir do |dir|
  env['OUT_DIR'] = dir
  @stdout, @stderr, status = Open3.capture3(env, cmd)
  raise "bc2cpp.rb failed (exit #{status.exitstatus}):\n#{@stderr[-4000..]}" unless status.success?
end

# See scripts/bc2cpp_coverage_report.rb's own DYNAMIC_DISPATCH_STATS_SUPPORT
# comment for why this needs a second, SKIP_UNSUPPORTED=1 run.
Dir.mktmpdir do |dir|
  shipped_env = env.merge('OUT_SYMBOL' => 'optcarrot_coverage_report_shipped', 'SKIP_UNSUPPORTED' => '1', 'OUT_DIR' => dir)
  @shipped_stdout, shipped_stderr, shipped_status = Open3.capture3(shipped_env, cmd)
  raise "bc2cpp.rb (SKIP_UNSUPPORTED=1) failed (exit #{shipped_status.exitstatus}):\n#{shipped_stderr[-4000..]}" unless shipped_status.success?
end

def section_lines(text, header)
  start = text.index("== #{header} ==")
  raise "section #{header.inspect} not found in bc2cpp.rb's own diagnostic" unless start

  rest = text[start..]
  stop = rest.index("\n==", 1)
  body = stop ? rest[0...stop] : rest
  body.lines.drop(1).map(&:strip).reject(&:empty?)
end

def count(text, header, placeholder: nil)
  lines = section_lines(text, header)
  return 0 if placeholder && lines == [placeholder]

  lines.size
end

err = @stderr

compiled_lines = section_lines(err, 'compiled entry points')
compiled_names = compiled_lines.filter_map { |l| (m = l.match(/\((\S+)#(\S+),/)) && "#{m[1]}##{m[2]}" }.to_set

never_called_match = err.match(/== never called \((\d+) of (\d+) compiled entry points/)

attempted_names = Set.new
errored_names = Set.new
error_reasons = Hash.new(0)
@stdout.split(/^(?=\/\/ (\S+#\S+) \(compiled from irep \d+, \d+ insns\)$)/).drop(1).each_slice(2) do |name, chunk|
  attempted_names << name
  chunk.each_line do |line|
    m = line.match(/#error (.+?) -- not in this prototype/)
    next unless m

    errored_names << name
    reason = m[1].sub(/^SEND\/SSEND :\S+ /, 'SEND/SSEND ').sub(/\(n=[^)]*\)/, '(n=...)')
    error_reasons[reason] += 1
  end
end
total_errors = error_reasons.values.sum
attempted = attempted_names.size
errored = errored_names.size

clean_names = compiled_names - errored_names
synthesized_count = (compiled_names - attempted_names).size

report = +''
report << "optcarrot bc2cpp coverage report\n"
report << "(tools/optcarrot_probe/optcarrot_bc2cpp_coverage_report.rb; optcarrot's\n"
report << " own real source as its own standalone closed world -- a scoping probe,\n"
report << " entirely separate from the real project's mruby-lcf/rgss/rpg2k registry\n"
report << " the CI job summary reports for the real project. See tools/optcarrot_probe/README.md.)\n\n"

report << "compiled entry points (clean, zero #error): #{clean_names.size}\n"
report << "  from bytecode: #{clean_names.size - synthesized_count}\n"
report << "  synthesized accessor overrides (ATTR_STRUCT_DEVIRT): #{synthesized_count}\n"
if never_called_match
  report << "never called (zero evidence in bytecode or NATIVE_SRCS): #{never_called_match[1]}\n"
end
report << "classes needing MRB_SET_INSTANCE_TT: #{count(err, 'classes needing MRB_SET_INSTANCE_TT(..., MRB_TT_DATA)')}\n"
report << "\n"

report << "-- method-level coverage (every bytecode method compile_method attempted) --\n"
report << "methods attempted: #{attempted}\n"
report << "  compiled clean: #{attempted - errored}\n"
report << "  left on the interpreter (>=1 #error): #{errored}\n"
report << format("  coverage: %.1f%%\n", attempted.zero? ? 0.0 : 100.0 * (attempted - errored) / attempted)
report << "\n"

report << "-- ivar/return/argument facts proven --\n"
report << "known-ivar-class hints (CLASS_HINT): #{count(err, 'known-ivar-class hints (devirtualization only, never embedded)', placeholder: '(none)')}\n"
report << "  poisoned to unknown (real evidence, but disagreeing/untraceable): #{count(err, 'ivar-class candidates (real SETIV evidence found, but poisoned to unknown)', placeholder: '(none)')}\n"
report << "  split: ANY (proven heterogeneous, not fixable): #{count(err, 'ivar-class candidates split: ANY (proven heterogeneous, not fixable)', placeholder: '(none)')}\n"
report << "  split: OPAQUE (unresolved, may be fixable): #{count(err, 'ivar-class candidates split: OPAQUE (unresolved, may be fixable)', placeholder: '(none)')}\n"
report << "known-array-element-class hints (ELEM_HINT): #{count(err, 'known-array-element-class hints (guarded devirtualization only)', placeholder: '(none)')}\n"
report << "  primitive-only hints (never embedded): #{count(err, 'known-array-element PRIMITIVE hints (informational only, never embedded)', placeholder: '(none)')}\n"
report << "  poisoned to unknown (proven Array, element class unresolved): #{count(err, 'array-element candidates (proven-Array ivar, element class poisoned to unknown)', placeholder: '(none)')}\n"
report << "    split: ANY (proven heterogeneous, not fixable): #{count(err, 'array-element candidates split: ANY (proven heterogeneous, not fixable)', placeholder: '(none)')}\n"
report << "    split: OPAQUE (unresolved, may be fixable): #{count(err, 'array-element candidates split: OPAQUE (unresolved, may be fixable)', placeholder: '(none)')}\n"
report << "known-hash-element-class hints (HASH_ELEM_HINT): #{count(err, 'known-hash-element-class hints (guarded devirtualization only)', placeholder: '(none)')}\n"
report << "  primitive-only hints (never embedded): #{count(err, 'known-hash-element PRIMITIVE hints (informational only, never embedded)', placeholder: '(none)')}\n"
report << "  poisoned to unknown (proven Hash, value class unresolved): #{count(err, 'hash-element candidates (proven-Hash ivar, value class poisoned to unknown)', placeholder: '(none)')}\n"
report << "    split: ANY (proven heterogeneous, not fixable): #{count(err, 'hash-element candidates split: ANY (proven heterogeneous, not fixable)', placeholder: '(none)')}\n"
report << "    split: OPAQUE (unresolved, may be fixable): #{count(err, 'hash-element candidates split: OPAQUE (unresolved, may be fixable)', placeholder: '(none)')}\n"
report << "ivar embedding (EMBED): #{count(err, 'ivar embedding', placeholder: '(none embeddable)')}\n"
report << "magic-comment return annotations (ANNOTATED): #{count(err, 'magic-comment annotations (# bc2cpp: (T, ...) -> T)', placeholder: '(none found)')}\n"
report << "magic-comment class-argument annotations (CLASS_ANNOTATED): #{count(err, 'magic-comment class annotations (# bc2cpp: (ClassName, ...))', placeholder: '(none found)')}\n"
report << "magic-comment element annotations (ELEM_ANNOTATED): #{count(err, 'magic-comment element annotations (# bc2cpp: ... -> Array<Klass> / -> Klass)', placeholder: '(none found)')}\n"
report << "annotation candidates (opaque argument, unresolved): #{count(err, 'annotation candidates (opaque incoming argument, unresolved)', placeholder: '(none)')}\n"
report << "integer-valued constants proven (INTEGER_CONSTANT_PROOF): #{count(err, 'integer-valued constants proven (INTEGER_CONSTANT_PROOF)', placeholder: '(none)')}\n"
report << "methods proven Fixnum-returning (FIXNUM_RETURN_PROOF): #{count(err, 'methods proven Fixnum-returning (FIXNUM_RETURN_PROOF)', placeholder: '(none)')}\n"
report << "\n"

report << "-- #error markers by reason (whole program) --\n"
error_reasons.sort_by { |reason, n| [-n, reason] }.each do |reason, n|
  report << format("  %5d  %s\n", n, reason)
end
report << format("  %5d  total\n", total_errors)
report << "\n"

block_fallback_count = @stdout.scan(/^\s*\/\/ BLOCK_FALLBACK :/).size
report << "block bodies compiled via cfunc/RProc fallback (BLOCK_FALLBACK): " \
          "#{block_fallback_count}\n"
report << "  still dynamic dispatch only -- MONO/POLY/TYPED devirtualization " \
          "not yet attempted for these\n"

lambda_fallback_count = @stdout.scan(/^\s*\/\/ LAMBDA_FALLBACK --/).size
report << "lambda bodies compiled via cfunc/RProc fallback (LAMBDA_FALLBACK): " \
          "#{lambda_fallback_count}\n"
report << "\n"

dispatch_counts = Hash.new(0)
@shipped_stdout.scan(/mrb_funcall\(M,\s*[^,]+,\s*"((?:[^"\\]|\\.)*)"/) { |m| dispatch_counts[m[0]] += 1 }
@shipped_stdout.scan(/mrb_funcall_with_block\(M,\s*[^,]+,\s*mrb_intern_cstr\(M,\s*"((?:[^"\\]|\\.)*)"\)/) { |m| dispatch_counts[m[0]] += 1 }
total_dispatch = dispatch_counts.values.sum
shipped_poly = @shipped_stdout.scan(/^\s*\/\/ POLY :\S+ --/).size
array_slice_write_fast_paths = @shipped_stdout.scan(/^\s*\/\/ ARRAY_SLICE_WRITE :\[\]=/).size
array_prefix_slice_fast_paths = @shipped_stdout.scan(/^\s*\/\/ ARRAY_PREFIX_SLICE_WRITE :slice!/).size
array_push_fast_paths = @shipped_stdout.scan(/^\s*\/\/ ARRAY_PUSH :<</).size
array_clear_fast_paths = @shipped_stdout.scan(/^\s*\/\/ ARRAY_CLEAR :clear/).size
array_clear_reuse_fast_paths = @shipped_stdout.scan(/^\s*\/\/ ARRAY_CLEAR_RETAIN :clear/).size
array_concat_copy_fast_paths = @shipped_stdout.scan(/^\s*\/\/ ARRAY_CONCAT_COPY :concat/).size
fixnum_binary_fast_paths = @shipped_stdout.scan(/^\s*\/\/ FIXNUM_BINARY :(?:%|&|\||\^)/).size
fixnum_shift_fast_paths = @shipped_stdout.scan(/^\s*\/\/ FIXNUM_SHIFT :>>/).size
fixnum_compare_fast_paths = @shipped_stdout.scan(/^\s*\/\/ FIXNUM_COMPARE :(?:<|<=|>|>=)/).size
fixnum_arithmetic_fast_paths = @shipped_stdout.scan(/^\s*\/\/ FIXNUM_ARITHMETIC :(?:\+|-|\*)/).size

report << "-- dynamic dispatch remaining (real shipped build, SKIP_UNSUPPORTED=1) --\n"
report << "total mrb_funcall/mrb_funcall_with_block call sites: #{total_dispatch}\n"
report << "  POLY-marked (receiver's runtime class genuinely decides): #{shipped_poly}\n"
report << "  everything else (not yet attempted or failed MONO/TYPED): #{total_dispatch - shipped_poly}\n"
report << "  guarded exact-Array slice writes lowered to mrb_ary_splice: #{array_slice_write_fast_paths}\n"
report << "  guarded exact-Array prefix slice! calls lowered to array APIs: #{array_prefix_slice_fast_paths}\n"
report << "  guarded exact-Array pushes lowered to mrb_ary_push: #{array_push_fast_paths}\n"
report << "  guarded exact-Array clear calls lowered to mrb_ary_clear: #{array_clear_fast_paths}\n"
report << "  PPU frame-buffer clears retaining backing storage: #{array_clear_reuse_fast_paths}\n"
report << "  exact-Array APU audio-buffer concatenations retaining capacity: #{array_concat_copy_fast_paths}\n"
report << "  guarded Fixnum modulo/bitwise sends lowered to C arithmetic: #{fixnum_binary_fast_paths}\n"
report << "  guarded Fixnum right shifts lowered to C arithmetic: #{fixnum_shift_fast_paths}\n"
report << "  guarded Fixnum comparisons lowered to C comparisons: #{fixnum_compare_fast_paths}\n"
report << "  guarded Fixnum +, -, * sends lowered to mruby numeric helpers: #{fixnum_arithmetic_fast_paths}\n"
report << "distinct dynamically-dispatched method names: #{dispatch_counts.size}\n"
report << "top 30 dynamically-dispatched method names:\n"
dispatch_counts.sort_by { |name, n| [-n, name] }.first(30).each_with_index do |(name, n), i|
  report << format("  %2d. %5d  :%s\n", i + 1, n, name)
end

if REPORT_PATH
  File.write(REPORT_PATH, report)
  puts "wrote #{REPORT_PATH}"
else
  print report
end
