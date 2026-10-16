#!/usr/bin/env ruby
# encoding: UTF-8
#
# bc2cpp coverage report: regenerates tools/bc2cpp/bc2cpp.rb's whole-program
# wio closed-world diagnostic (every owner across all three compiled gems --
# mruby-rpg2k-compiled/mruby-lcf-compiled/mruby-rgss-compiled -- combined,
# with the actual wio gem set and outside-source proof inputs) and prints a small,
# stats-only summary: compiled-entry-point and
# #error counts, a method-level coverage percentage (attempted vs. actually
# compiled clean), and both the resolved AND the poisoned-to-unknown side of
# every ivar/return/argument fact the diagnostic proves -- an "unknown"
# count that used to be silently dropped (ClassLayout's own analyze() only
# ever returned the resolved half; this script's own bc2cpp.rb change adds
# a `.known`/`.unknowns` split mirroring the one ArrayElementLayout already
# had, so the poisoned ivars are reportable too).
#
# Deliberately NOT the generated C++ itself: a single gem's own generated
# output runs past 250K lines, and even an unrelated bc2cpp.rb/mrblib edit
# can reshuffle register numbers and line order across the whole file --
# tracking that in git would make every commit's diff unreviewable and put
# any two concurrent bc2cpp-touching PRs into a guaranteed merge conflict in
# a file neither of them meaningfully changed. This report is the cheaper
# alternative: aggregate counts only, so the report can be published in the
# CI job summary and copied into a PR description without adding a generated
# file that conflicts whenever two concurrent bc2cpp changes land together.
# Contains no timestamp or other run-specific content.
#
# Usage: MRBC=path/to/host/mrbc ruby scripts/bc2cpp/coverage_report.rb
# Requires a host mrbc already built (3rd/mruby/build/host, the same
# prerequisite every real mruby-*-compiled/mrbgem.rake Rake task already
# has). Writes to stdout. Set BC2CPP_COVERAGE_REPORT_PATH to write a file
# instead (used by callers that need to capture the report). Set
# BC2CPP_COVERAGE_KEEP_DIR to also keep the shipped pass's generated C++.

require 'shellwords'
require 'open3'
require 'tmpdir'
require 'set'

ROOT = File.expand_path('../..', __dir__)
require_relative '../../tools/bc2cpp/compiled_gems'
require_relative '../../tools/bc2cpp/symbol_cache'
require_relative '../../tools/bc2cpp/nomethod_reviewed_probe'

BC2CPP = File.join(ROOT, 'tools/bc2cpp/bc2cpp.rb')
MRBC = ENV['MRBC'] || 'mrbc'
# Optional output path for callers that need to capture the report.
REPORT_PATH = ENV['BC2CPP_COVERAGE_REPORT_PATH']

srcs = closed_world_mrblib_srcs(ROOT)
native_srcs = bc2cpp_rgss_native_srcs(ROOT, 'wio') + core_native_srcs("#{ROOT}/3rd/mruby") +
              external_gem_native_srcs(ROOT)
# INTEGER_CONSTANT_PROOF's own out-of-closed-world poison source -- see
# foreign_mrblib_srcs (compiled_gems.rb) and bc2cpp.rb's own IntegerConstants
# header. Passed here for the same reason NATIVE_SRCS is: this report must
# measure what a real gem build actually produces, and bc2cpp skips the whole
# analysis unless BOTH inputs are present.
foreign_ruby_srcs = foreign_mrblib_srcs(ROOT)
all_owners = BC2CPP_COMPILED_GEMS.values.flat_map { |g| g[:owners] }
# owner name -> gem short name, for the per-gem breakdown below.
gem_of_owner = {}
BC2CPP_COMPILED_GEMS.each { |gem, g| g[:owners].each { |o| gem_of_owner[o] = gem } }
gem_of_owner_engine = {}
BC2CPP_COMPILED_GEMS.each { |gem, g| g[:owners].each { |o| gem_of_owner_engine[o] = gem } unless gem == 'mruby-core-compiled' }

env = {
  'MRBC' => MRBC,
  'OUT_SYMBOL' => 'coverage_report',
  'ONLY_OWNERS' => all_owners.join(','),
  'NATIVE_SRCS' => Shellwords.join(native_srcs),
  'FOREIGN_RUBY_SRCS' => Shellwords.join(foreign_ruby_srcs),
  # The whole-program dispatch count is meaningful only under the same closed
  # world that the wio compiled gems use. `allow` skips the reviewed-site audit
  # failure for this measurement run; it does not alter generated dispatch.
  'BC2CPP_CLOSED_WORLD' => '1',
  'BC2CPP_BUILD_NAME' => 'wio', 'BC2CPP_COLLECTION_EXPORTS' => '1',
  'BC2CPP_BUILD_GEMS' => Shellwords.join(NomethodReviewedProbe.wio_gems(ROOT).map { |n, d| "#{n}=#{d}" }),
  NomethodReviewed::ALLOW_ENV => 'allow',
}
env['BC2CPP_PROFILE_TIMINGS'] = '1' if ENV['BC2CPP_PROFILE_TIMINGS'] == '1'
cmd = [RbConfig.ruby, BC2CPP, '--annotated', *srcs].shelljoin
Dir.mktmpdir do |dir|
  env['OUT_DIR'] = dir
  @stdout, @stderr, status = Open3.capture3(env, cmd)
  raise "bc2cpp.rb failed (exit #{status.exitstatus}):\n#{@stderr[-4000..]}" unless status.success?
end

# DYNAMIC_DISPATCH_STATS_SUPPORT: a second, SEPARATE run with SKIP_
# UNSUPPORTED=1 -- the real flag every actual gem build sets, dropping
# every method that still has a `#error` anywhere in its own body (see
# compile_all's own SKIP_UNSUPPORTED comment). The FIRST run above
# deliberately doesn't set it (this report's own #error-by-reason
# breakdown needs the real #error TEXT, which SKIP_UNSUPPORTED=1 strips
# out entirely) -- so counting `mrb_funcall`/`mrb_funcall_with_block`
# call sites straight off that first run's own @stdout would overcount:
# it would include real dispatch lines sitting inside a method that
# never actually ships, alongside its own unrelated #error. A second,
# real "what does the shipped build actually contain" run is the only
# way to get a true whole-program dynamic-dispatch count.
Dir.mktmpdir do |dir|
  # BC2CPP_COVERAGE_ORIGIN_TABLE: the shipped pass also writes the exact receiver-origin table (SiteOriginTable);
  # its generated text carries the /*SO:*/ join tags, so it is measured apart from the untagged shipped.cxx.
  shipped_env = env.merge('OUT_SYMBOL' => 'coverage_report_shipped', 'SKIP_UNSUPPORTED' => '1', 'OUT_DIR' => dir,
                          'BC2CPP_SITE_ORIGIN_TABLE' => ENV['BC2CPP_COVERAGE_ORIGIN_TABLE'])
  @shipped_stdout, @shipped_stderr, shipped_status = Open3.capture3(shipped_env, cmd)
  raise "bc2cpp.rb (SKIP_UNSUPPORTED=1) failed (exit #{shipped_status.exitstatus}):\n#{@shipped_stderr[-4000..]}" unless shipped_status.success?
end
# BC2CPP_COVERAGE_KEEP_DIR: keep the shipped run's generated C++ (stdout, plus
# any OUT_DIR files) for a semantic diff of two compiler revisions.
if (keep = ENV['BC2CPP_COVERAGE_KEEP_DIR'])
  File.write(File.join(keep, 'shipped.cxx'), @shipped_stdout)
  File.write(File.join(keep, 'shipped.stderr'), @shipped_stderr)
end

# ---------------------------------------------------------------------------
# Section counts, straight off bc2cpp.rb's own `== header ==` diagnostic --
# see that file's own `warn '== ... =='` call sites for the exact section
# list this depends on.
# ---------------------------------------------------------------------------
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

# `== compiled entry points ==` is every method compile_all produced an
# entry for -- but WITHOUT `SKIP_UNSUPPORTED=1` (this run's own default,
# needed below to see the real #error text at all) that list is
# unfiltered: it still includes a method whose body is nothing but
# `#error` lines (compile_all's own SKIP_UNSUPPORTED partition is what
# normally drops those, done here only when a real gem build sets the
# env var -- see that code's own comment). So this raw line count is
# "entries registered", not "entries that actually compiled" -- the
# method-level scan below re-derives the real clean/errored split by
# reading each entry's own generated body.
compiled_lines = section_lines(err, 'compiled entry points')
compiled_names = compiled_lines.filter_map { |l| (m = l.match(/\((\S+)#(\S+),/)) && "#{m[1]}##{m[2]}" }.to_set

never_called_match = err.match(/== never called \((\d+) of (\d+) compiled entry points/)

# ---------------------------------------------------------------------------
# Method-level coverage: every real bytecode method compile_method ever
# attempts gets its own `// Owner#name (compiled from irep N, M insns)`
# comment right before its `_impl` signature (compile_method's own
# unconditional header, emitted whether or not the body that follows is
# real code or nothing but #error lines) -- splitting @stdout on that
# marker gives one chunk per attempted method. A synthesized accessor
# override (ATTR_STRUCT_DEVIRT's own emit_synthesized_accessors, added to
# `compiled` alongside compile_all's own output) never goes through
# compile_method at all, so it carries no such comment and never appears
# here -- `compiled_names - attempted_names` below is exactly that set.
#
# Also the only place the real #error TEXT is visible at all (the stderr
# diagnostic never prints it, only counts derived from stdout can), so the
# per-reason breakdown further down reads the same @stdout this scan does.
# ---------------------------------------------------------------------------
attempted_names = Set.new
errored_names = Set.new
error_reasons = Hash.new(0)
@stdout.split(/^(?=\/\/ (\S+#\S+) \(compiled from irep \d+, \d+ insns\)$)/).drop(1).each_slice(2) do |name, chunk|
  attempted_names << name
  chunk.each_line do |line|
    m = line.match(/#error (.+?) -- not in this prototype/)
    next unless m

    errored_names << name
    # Collapse the per-call-site variable part of a splat/keyword-argument
    # error (arg/kwarg counts differ site to site) so the report buckets by
    # shape, not by exact signature -- everything else here is already a
    # fixed opcode name.
    reason = m[1].sub(/^SEND\/SSEND :\S+ /, 'SEND/SSEND ').sub(/\(n=[^)]*\)/, '(n=...)')
    error_reasons[reason] += 1
  end
end
total_errors = error_reasons.values.sum
attempted = attempted_names.size
errored = errored_names.size

clean_names = compiled_names - errored_names
synthesized_count = (compiled_names - attempted_names).size
# CORE_DEFS (ADR 0264): the entries compiled from mruby's own Ruby. An owner both an engine gem and
# core sources define methods on (Array, StringIO) is attributed by where each method comes from.
core_section = err[/== core-source compiled entry points \(\d+\) ==\n(.*?)(?=\n==|\z)/m, 1].to_s
core_keys = core_section.lines.map(&:strip).reject(&:empty?).to_set
compiled_by_gem = Hash.new(0)
clean_names.each do |name|
  owner = name.split('#', 2).first
  gem = core_keys.include?(name) ? 'mruby-core-compiled' : gem_of_owner_engine[owner] || gem_of_owner[owner]
  compiled_by_gem[gem || 'unknown'] += 1
end

report = +''
report << "bc2cpp coverage report\n"
report << "(scripts/bc2cpp/coverage_report.rb; wio closed world, whole-program, all three\n"
report << " gems' owners combined -- see that script's own header)\n\n"

report << "compiled entry points (real build output -- clean, zero #error): #{clean_names.size}\n"
report << "  from bytecode: #{clean_names.size - synthesized_count}\n"
report << "  synthesized accessor overrides (ATTR_STRUCT_DEVIRT): #{synthesized_count}\n"
compiled_by_gem.sort.each { |gem, n| report << "  #{gem}: #{n}\n" }
core_summary = err.match(/== core methods: (\d+) core-source bytecode methods, (\d+) shadowed by a later definition, (\d+) kept interpreted \(([^)]*)\), (\d+) compiled without being registry definitions/)
if core_summary
  report << "mruby core mrblib (docs/adr/0264): #{core_summary[1]} bytecode methods in the world, " \
            "#{(core_keys & clean_names).size} compiled clean (#{core_summary[5]} of them not registry definitions), " \
            "#{core_summary[3]} kept interpreted (#{core_summary[4]}), #{core_summary[2]} shadowed by a later definition\n"
end
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
# ANY_OPAQUE_SUPPORT: the same poisoned-ivar-class count above, split by
# WHY -- :any (two real sites proven to genuinely disagree, unfixable) vs.
# :opaque (at least one site untraceable, a real candidate for a future
# annotation round). See ClassLayout.analyze's own `poison_reason` header.
report << "  split: ANY (proven heterogeneous, not fixable): #{count(err, 'ivar-class candidates split: ANY (proven heterogeneous, not fixable)', placeholder: '(none)')}\n"
report << "  split: OPAQUE (unresolved, may be fixable): #{count(err, 'ivar-class candidates split: OPAQUE (unresolved, may be fixable)', placeholder: '(none)')}\n"
report << "known-array-element-class hints (ELEM_HINT): #{count(err, 'known-array-element-class hints (guarded devirtualization only)', placeholder: '(none)')}\n"
# PRIMITIVE_ELEMENT_SUPPORT: element facts that resolved to a primitive
# scalar (Integer/Hash/String/Symbol) rather than a real registry class --
# never fed to CodeGen (see ArrayElementLayout.primitives' own comment),
# reported here purely so a resolved-but-inert primitive fact isn't
# invisible to the coverage trend.
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
# RECORD_HASH_PROOF: ivar names that are record-like Hashes, and the sends that now dispatch on a
# class a record key proves (a direct call instead of a guarded one).
record_lines = section_lines(err, 'record hash slots (RECORD_HASH_PROOF)')
report << "record-like Hash slots proven (RECORD_HASH_PROOF): #{record_lines.count { |l| l.start_with?('RECORD_HASH ') }} " \
          "accepted, #{record_lines.count { |l| l.start_with?('RECORD_HASH_REFUSED') }} refused\n"
report << "  exact-class direct calls through a record key: #{@shipped_stdout.scan('record key holds only fresh').size}\n"
# LCF_ROW_FLOW (ADR 0294): whether the LCF object-kind proof is on, the receivers it proved an exact class
# (a direct call, no guard), and the untyped GETIDX sites still behind the generic class gate.
lcf_state = err[/== LCF row flow \(LCF_ROW_FLOW\) ==\n  (.*)/, 1].to_s
lcf_calls = @shipped_stdout.scan(%r{^\s*// LCF_ROW_FLOW :(\S+) -> (\S+)}).map(&:last).tally
report << "LCF row flow (LCF_ROW_FLOW): #{lcf_state.empty? ? 'not reported' : lcf_state}\n"
report << "  exact-class direct calls: #{lcf_calls.values.sum}" \
          "#{lcf_calls.empty? ? '' : " (#{lcf_calls.sort_by { |k, v| [-v, k] }.map { |k, v| "#{k} #{v}" }.join(', ')})"}\n"
report << "  untyped GETIDX/GETIDX0 sites behind the generic class gate: #{@shipped_stdout.scan(/\bbc2cpp_getidx0?\(M,/).size}\n"
# INTEGER_CONSTANT_PROOF: bare constant names every definition in the whole
# program agrees is an integer literal -- FIXNUM_OPERAND_PROOF's own fifth
# proof source. Reported here for the same reason every other proven fact
# above is: it is a real, whole-program fact whose count moves when the Ruby
# sources change (a new `FOO = 3` adds one; reassigning an existing constant
# to a non-literal silently REMOVES one, along with every devirtualization it
# was feeding), so a drift in it is exactly the kind of thing this file's own
# git diff exists to make visible.
report << "integer-valued constants proven (INTEGER_CONSTANT_PROOF): #{count(err, 'integer-valued constants proven (INTEGER_CONSTANT_PROOF)', placeholder: '(none)')}\n"
# UNIQUE_CLASS_NAME: bare class names canonicalized to their one definition.
report << "bare class names with one definition (UNIQUE_CLASS_NAME): #{count(err, 'bare class names with one definition (UNIQUE_CLASS_NAME)')}\n"
# FIXNUM_RETURN_PROOF: bare method names whose one closed-world definition
# provably returns a Fixnum on every return path -- FIXNUM_OPERAND_PROOF's
# own sixth proof source. Tracked here for exactly the reason the constant
# count above is: it is a whole-program fact that moves silently when the
# Ruby sources change. Adding a `return nil` guard to one of these methods,
# or a second definition of its bare name anywhere (including in mruby's own
# mrblib), removes the name and with it every devirtualization it fed.
report << "methods proven Fixnum-returning (FIXNUM_RETURN_PROOF): #{count(err, 'methods proven Fixnum-returning (FIXNUM_RETURN_PROOF)', placeholder: '(none)')}\n"
# ARRAY_RETURN_PROOF: the Array analogue of the line just above -- bare
# method names whose one closed-world definition provably returns an Array
# on every return path, consumed by the block recognizers' own receiver gate
# (proven_array_source). Tracked here for the identical reason: it is a
# whole-program fact that moves silently when the Ruby sources change. An
# added `return nil` guard, a new conditional landing on a method's own
# RETURN, or a second definition of its bare name anywhere (including in
# mruby's own mrblib) removes the name and with it every loop it unblocked.
report << "methods proven Array-returning (ARRAY_RETURN_PROOF): #{count(err, 'methods proven Array-returning (ARRAY_RETURN_PROOF)', placeholder: '(none)')}\n"
# NUMERIC_OPERAND_PROOF (ADR 0276): whole-program class-set facts, by kind. Like
# the counts above they move silently with the Ruby sources: one write of a
# String to an ivar drops the ivar, and every arithmetic site it fed regains its
# dynamic-send else.
numeric_lines = section_lines(err, 'numeric operand facts (NUMERIC_OPERAND_PROOF)')
numeric_kinds = { 'NUMARG' => 'entry arguments', 'NUMIVAR' => 'instance variables',
                  'NUMRET' => 'method names returning', 'NUMCONST' => 'constants', 'NUMTUPLE' => 'tuple-returning names' }
report << "numeric operand facts (NUMERIC_OPERAND_PROOF): " \
          "#{numeric_kinds.map { |tag, what| "#{numeric_lines.count { |l| l.start_with?("#{tag} ") }} #{what}" }.join(', ')}\n"
# RETURN_CLASS_TABLE (ADR 0294): names every call of which returns one exact class.
report << "return-class table (RETURN_CLASS_TABLE): #{count(err, 'return class table (RETURN_CLASS_TABLE)')} names with one exact class\n"
# CLASS_POOLS (ADR 0296, ADR 0301): ivar, argument and constant class sets carried across methods.
pool_lines = section_lines(err, 'class pools (CLASS_POOLS)')
pool_lines = [] if pool_lines == ['(none)']
report << "class pools (CLASS_POOLS): #{pool_lines.count { |l| l.start_with?('CLASSIVAR ') }} ivar pools, " \
          "#{pool_lines.count { |l| l.start_with?('CLASSARG ') }} argument pools, " \
          "#{pool_lines.count { |l| l.start_with?('CLASSCONST ') }} constant pools\n"
# ADR 0279: typed (mrb_int, mrb_sym, mrb_bool) ivar slots given back to boxed slots because a writer
# the compiler cannot type (attr_writer, computed setter, reflection) can reach them.
boxed_lines = section_lines(err, 'typed slots demoted to boxed slots (foreign writers, ADR 0279)')
boxed_lines = [] if boxed_lines == ['(none)']
report << "typed ivar slots boxed for foreign writers (ADR 0279): #{boxed_lines.size}" \
          "#{boxed_lines.map { |l| l[/\(([^:)]*)/, 1] }.tally.sort.map { |why, n| " #{why} #{n}" }.join(',').then { |t| t.empty? ? '' : " (#{t.strip})" }}\n"
report << "\n"

report << "-- #error markers by reason (whole program) --\n"
error_reasons.sort_by { |reason, n| [-n, reason] }.each do |reason, n|
  report << format("  %5d  %s\n", n, reason)
end
report << format("  %5d  total\n", total_errors)
report << "\n"

# BLOCK_CFUNC_FALLBACK_SUPPORT: a previously-#error'd BLOCK/SENDB/SSENDB
# call site that now compiles clean via emit_block_fallback_glue's own
# `// BLOCK_FALLBACK :name -- ...` marker comment -- these already count
# toward "compiled clean" above, same as any other method, but are
# deliberately ALSO broken out here because the call carrying the block
# still dispatches dynamically (`mrb_funcall_with_block`). The standalone
# cfunc body can now specialize calls on proven Array/Hash iterator elements, so
# count those separately from the dynamic block-carrying call site.
block_fallback_count = @stdout.scan(/^\s*\/\/ BLOCK_FALLBACK :/).size
report << "block bodies compiled via cfunc/RProc fallback (BLOCK_FALLBACK): " \
          "#{block_fallback_count}\n"
fallback_element_sends = Hash.new(0)
current_fallback = nil
@stdout.each_line do |line|
  if (m = line.match(/^\s*(?:static )?mrb_value (\w*block_fallback\w*_impl)\(.*\) \{\s*$/))
    current_fallback = m[1]
    fallback_element_sends[current_fallback] ||= 0
  elsif line.match?(/^\s*(?:static )?mrb_value \w+\(.*\) \{\s*$/)
    current_fallback = nil
  elsif current_fallback && line.include?('// ELEMENT :')
    fallback_element_sends[current_fallback] += 1
  end
end
fallback_element_functions = fallback_element_sends.count { |_name, sends| sends.positive? }
fallback_element_send_count = fallback_element_sends.values.sum
report << "  fallback cfuncs with guarded Array/Hash iterator element sends: " \
          "#{fallback_element_functions} function(s), #{fallback_element_send_count} send(s)\n"

# LAMBDA_FALLBACK_SUPPORT: the LAMBDA-opcode sibling of BLOCK_CFUNC_
# FALLBACK_SUPPORT immediately above -- a previously-#error'd LAMBDA
# instruction that now compiles clean via emit_lambda_fallback_glue's own
# `// LAMBDA_FALLBACK -- ...` marker comment. Counted the same way, but
# deliberately NOT captioned "dynamic dispatch": a LAMBDA never calls
# anything itself (it only BUILDS a value), so there is no dispatch
# decision to make at the LAMBDA site at all -- whatever devirtualization
# coverage applies to a LATER `.call`/`.()` on the resulting value is
# already whatever compile_send's own MONO/POLY/TYPED logic decides for
# that separate call site (an opaque-Proc receiver, so POLY/dynamic in
# practice today, same as any other not-statically-known receiver).
lambda_fallback_count = @stdout.scan(/^\s*\/\/ LAMBDA_FALLBACK --/).size
report << "lambda bodies compiled via cfunc/RProc fallback (LAMBDA_FALLBACK): " \
          "#{lambda_fallback_count}\n"
sdef_fallback_count = @stdout.scan(/^\s*\/\/ SDEF_FALLBACK :/).size
tdef_fallback_count = @stdout.scan(/^\s*\/\/ TDEF_FALLBACK :/).size
sclass_fallback_count = @stdout.scan(/^\s*\/\/ SCLASS_FALLBACK \+/).size
report << "runtime definition fallbacks (SDEF/TDEF/SCLASS+EXEC): " \
          "#{sdef_fallback_count}/#{tdef_fallback_count}/#{sclass_fallback_count}\n"
report << "\n"

# DYNAMIC_DISPATCH_STATS_SUPPORT: every real dynamic-dispatch call site left in
# the actual SHIPPED build (@shipped_stdout, SKIP_UNSUPPORTED=1). SymbolCache rewrites
# the ordinary mrb_funcall form to `bc2cpp_send(M, recv, index, ...)`; resolve
# those indices through the generated symbol table instead of scanning only the
# pre-cache spelling. `mrb_funcall_with_block` is counted separately because it
# carries a block and is emitted by the block-fallback glue, not SymbolCache.
def unescape_cpp_string(s)
  s.gsub(/\\x(\h\h)/) { [Regexp.last_match(1).hex].pack('C') }
    .gsub(/\\([0-7]{1,3})/) { Regexp.last_match(1).to_i(8).chr }
    .gsub(/\\(.)/) { { 'n' => "\n", 't' => "\t", 'r' => "\r" }.fetch(Regexp.last_match(1), Regexp.last_match(1)) }
end

def cached_send_indices(code)
  indices = []
  pos = 0
  while (start = code.index(/\bbc2cpp_send\(M,\s*/, pos))
    head_end = Regexp.last_match.end(0)
    receiver_end = SymbolCache.expression_end(code, head_end)
    index = receiver_end && code[receiver_end..][/\A,\s*(\d+)\s*[,)]/, 1]
    indices << index.to_i if index
    pos = start + 1
  end
  indices
end

def cached_with_block_indices(code)
  indices = []
  pos = 0
  while (start = code.index(/\bmrb_funcall_with_block\(M,\s*/, pos))
    head_end = Regexp.last_match.end(0)
    receiver_end = SymbolCache.expression_end(code, head_end)
    index = receiver_end && code[receiver_end..][/\A,\s*bc2cpp_sym\(M,\s*(\d+)\)\s*[,)]/, 1]
    indices << index.to_i if index
    pos = start + 1
  end
  indices
end

# These include fallback arms attached to direct-call guards; POLY_DIAG below
# separately counts sites that had no complete direct set.
dispatch_counts = Hash.new(0)
symbol_names = @shipped_stdout[/static const char\* const bc2cpp_sym_names\[\d+\] = \{(.*?)\n\};/m, 1].to_s
                         .scan(/"((?:[^"\\\n]|\\.)*)"/).flatten.map { |literal| unescape_cpp_string(literal) }
(cached_send_indices(@shipped_stdout) + cached_with_block_indices(@shipped_stdout)).each do |index|
  name = symbol_names[index]
  dispatch_counts[name || "?symbol-#{index}"] += 1
end
@shipped_stdout.scan(/mrb_funcall_with_block\(M,\s*[^,]+,\s*mrb_intern_cstr\(M,\s*"((?:[^"\\]|\\.)*)"\)/) { |m| dispatch_counts[unescape_cpp_string(m[0])] += 1 }
total_dispatch = dispatch_counts.values.sum
shipped_poly = @shipped_stdout.scan(/^\s*\/\/ POLY :\S+ --/).size
raise "bc2cpp coverage report: POLY markers exceed dispatch sites" if shipped_poly > total_dispatch
hash_values_fast_paths = @shipped_stdout.scan(/^\s*\/\/ HASH_VALUES :values/).size

# POLY_DIAGNOSTICS: generated markers are attached to every selected class
# chain/table and every remaining POLY fallback. The exclusion counts are
# definition-level and repeat across call sites; path counts are call-site
# counts and are the useful denominator for unresolved dispatch.
poly_paths = Hash.new(0)
poly_receivers = Hash.new(0)
dynamic_receivers = Hash.new(0)
unresolved_origins = Hash.new(0)
unresolved_origin_names = Hash.new { |hash, origin| hash[origin] = Hash.new(0) }
poly_exclusions = Hash.new(0)
new_dispatch_paths = Hash.new(0)
new_dispatch_exclusions = Hash.new(0)
poly_diag_sites = 0
poly_dynamic_names = Hash.new(0)
# Which generated function a line belongs to: a core-source entry's `_impl` and the helper functions
# (block, rescue, inline-loop bodies) named after it. Everything else is the engine's.
shipped_core_keys = @shipped_stderr[/== core-source compiled entry points \(\d+\) ==\n(.*?)(?=\n==|\z)/m, 1].to_s.lines.map(&:strip).reject(&:empty?).to_set
core_entry_names = section_lines(@shipped_stderr, 'compiled entry points').filter_map do |l|
  (m = l.match(/\A(\S+) \/ \S+\s+\((\S+#[^,]+),/)) && shipped_core_keys.include?(m[2]) ? m[1] : nil
end
core_function = /\A(?:#{core_entry_names.map { |n| Regexp.escape(n) }.join('|')})(?:_impl|_(?:block_fallback|inline|rescue|exec|tdef|lambda)\w*)?\z/
core_dispatch_diag_sites = 0
core_dispatch_diag_dynamic = 0
current_function = nil
@shipped_stdout.each_line do |line|
  current_function = Regexp.last_match(1) if !core_entry_names.empty? && line =~ /\A(?:static )?mrb_value (\w+|[\w$]+)\(mrb_state\*/
  match = line.match(/^\s*\/\/ POLY_DIAG path=(\S+) receiver=(\S+) name="((?:\\.|[^"\\])*)" arity=\d+ candidates=(\d+) excluded=(\S+)(?: origin=(\S+))?/)
  next unless match

  poly_diag_sites += 1
  in_core = current_function && core_entry_names.any? && current_function.match?(core_function)
  core_dispatch_diag_sites += 1 if in_core
  core_dispatch_diag_dynamic += 1 if in_core && match[1].start_with?('dynamic_')
  poly_paths[match[1]] += 1
  poly_receivers[match[2]] += 1
  if match[3] == 'new' && match[1].start_with?('dynamic_')
    new_dispatch_paths[[match[1], match[2]]] += 1
    unless match[5] == 'none'
      match[5].split(',').each do |entry|
        reason, count = entry.split('=', 2)
        new_dispatch_exclusions[reason] += count.to_i
      end
    end
  end
  dynamic_receivers[[match[1], match[2]]] += 1 if match[1].start_with?('dynamic_')
  if match[2] == 'receiver_class_unresolved'
    origin = match[6] || 'not_recorded'
    unresolved_origins[origin] += 1
    method_name = match[3].gsub(/\\(.)/, '\\1')
    unresolved_origin_names[origin][method_name] += 1
  end
  next if match[5] == 'none'

  match[5].split(',').each do |entry|
    reason, count = entry.split('=', 2)
    poly_exclusions[reason] += count.to_i
  end
end
@shipped_stdout.scan(/^\s*\/\/ POLY :(\S+) --/).each { |match| poly_dynamic_names[match.first] += 1 }
poly_dynamic_sites = poly_paths.sum { |path, count| path.start_with?('dynamic_') ? count : 0 }
direct_new_sites = @shipped_stdout.scan(/^\s*\/\/ MONO :new -> /).size
# Literal-block sends: BLOCK_CORE_DIRECT (ADR 0270) keeps the POLY marker of its dynamic else, so
# those sites stay in the POLY counts below although the common receivers no longer dispatch.
block_direct_sites = @shipped_stdout.scan(/^\s*\/\/ BLOCK_FALLBACK :.*direct call with the block/).size
block_dynamic_sites = @shipped_stdout.scan(/^\s*\/\/ BLOCK_FALLBACK :.*dynamic dispatch/).size
block_core_arm_sites = @shipped_stdout.scan(/^\s*\/\/ BLOCK_CORE_DIRECT :/).size

report << "-- dynamic dispatch remaining (real shipped build, SKIP_UNSUPPORTED=1) --\n"
report << "cached bc2cpp_send/mrb_funcall_with_block sites, including guarded fallbacks: #{total_dispatch}\n"
report << "  POLY-marked (receiver's runtime class genuinely decides): #{shipped_poly}\n"
# Guarded arithmetic/compare arms: each carries a tag comment, and one that keeps
# its dynamic-send else has a send in the lines after it (NUMERIC_OPERAND_PROOF,
# ADR 0276, removes it where both operands are proven Integer/Float).
guarded_tags = %w[FIXNUM_ARITHMETIC FIXNUM_COMPARE FLOAT_DIV_RECEIVER INTEGER_LSHIFT FIXNUM_SHIFT FIXNUM_BINARY INTEGER_UNARY]
shipped_lines = @shipped_stdout.lines
guarded_sites = Hash.new(0)
guarded_kept = Hash.new(0)
shipped_lines.each_with_index do |line, i|
  tag = guarded_tags.find { |t| line.include?("// #{t} ") }
  next unless tag

  guarded_sites[tag] += 1
  # An arm keeps its own by-name call unless its else is a helper call, read up to the next arm's tag.
  arm = shipped_lines[(i + 1)..(i + 40)].take_while { |l| !l.match?(%r{^\s*// [A-Z_]+ :}) }
  guarded_kept[tag] += 1 unless arm.any? { |l| l.include?('bc2cpp_slow_') }
end
numeric_proven_sites = @shipped_stdout.scan(%r{^\s*// NUMERIC_OPERAND_PROOF :}).size
# NUMERIC_SLOW_PATH (ADR 0292): an arm's else is a typed helper call; the by-name call lives in the helper.
slow_calls = Hash.new(0)
@shipped_stdout.scan(/= bc2cpp_slow_([a-z]+)(?:_f)?\(M,/) { |(key)| slow_calls[key] += 1 }
slow_helper_sends = 0
@shipped_stdout.scan(/^static mrb_value bc2cpp_slow_\w+\(mrb_state\* M.*?^\}\n/m) { |body| slow_helper_sends += body.scan('bc2cpp_send(').size }
report << "  guarded numeric arms with a dynamic-send else of their own: #{guarded_kept.values.sum} " \
          "(" + guarded_tags.map { |t| "#{t} #{guarded_kept[t]}" }.join(', ') + ")\n"
report << "  guarded numeric arms whose else is a NUMERIC_SLOW_PATH helper call: #{slow_calls.values.sum} " \
          "(" + slow_calls.sort.map { |k, n| "#{k} #{n}" }.join(', ') + ")\n"
report << "    by-name calls held by those helpers (one per operand class they do not own): #{slow_helper_sends}\n"
report << "  arms whose send NUMERIC_OPERAND_PROOF removed (operands proven Integer/Float): #{numeric_proven_sites}\n"
report << "  direct :new constructor paths emitted (some retain guarded fallback): #{direct_new_sites}\n"
# ADR 0294: a TYPED call behind a class guard with a dynamic-send fallback, against the same call when
# the receiver is proven exactly that class.
typed_guarded_sites = @shipped_stdout.scan(%r{^\s*// TYPED :}).size
typed_exact_sites = @shipped_stdout.scan(%r{^\s*// EXACT_TYPED :}).size
report << "  TYPED calls: #{typed_guarded_sites} behind a class guard with a send fallback, " \
          "#{typed_exact_sites} guard-free (EXACT_TYPED)\n"
# ADR 0296: a receiver proven nil-or-one-class takes one nil test; its non-nil path is the exact call.
nilable_sites = @shipped_stdout.scan(%r{^\s*// NILABLE_RECEIVER :}).size
nil_arms = @shipped_stdout.scan(/\bbc2cpp_nil_receiver\(M,/).size
index_exact = @shipped_stdout.scan(%r{^\s*// INDEX_EXACT }).size
report << "  NILABLE_RECEIVER sites: #{nilable_sites} (#{nil_arms} with a bc2cpp_nil_receiver arm instead of a send), " \
          "INDEX_EXACT arms: #{index_exact}\n"
report << "  literal-block sends: #{block_direct_sites} direct call with the block " \
          "(#{block_core_arm_sites} through exact-class core arms that keep the dynamic send as their else), " \
          "#{block_dynamic_sites} dynamic dispatch only\n"
report << "  generic POLY sites by diagnostics: #{poly_dynamic_sites}\n"
report << "    in engine methods: #{poly_dynamic_sites - core_dispatch_diag_dynamic}\n"
report << "    in compiled mruby-core mrblib methods: #{core_dispatch_diag_dynamic}\n"
report << "  POLY_DIAG sites categorized: #{poly_diag_sites}\n"
report << "  dispatch path by call site:\n"
poly_paths.sort.each { |path, count| report << format("    %5d  %s\n", count, path) }
report << "  generic dynamic sites by path and receiver evidence:\n"
dynamic_receivers.sort.each do |(path, receiver), count|
  report << format("    %5d  %-38s %s\n", count, path, receiver)
end
report << "  unresolved :new sites by path and receiver evidence:\n"
new_dispatch_paths.sort.each do |(path, receiver), count|
  report << format("    %5d  %-38s %s\n", count, path, receiver)
end
report << "  excluded :new definitions across unresolved sites:\n"
new_dispatch_exclusions.sort_by { |reason, count| [-count, reason] }.each do |reason, count|
  report << format("    %5d  %s\n", count, reason)
end
report << "  unresolved receiver origins (nearest defining instruction):\n"
unresolved_origins.sort_by { |origin, count| [-count, origin] }.each do |origin, count|
  report << format("    %5d  %s\n", count, origin)
end
report << "  top dynamic method names within the largest unresolved origins:\n"
unresolved_origins.sort_by { |origin, count| [-count, origin] }.first(8).each do |origin, _count|
  names = unresolved_origin_names[origin].sort_by { |name, count| [-count, name] }.first(8)
  report << "    #{origin}: #{names.map { |name, count| ":#{name} #{count}" }.join(', ')}\n"
end
report << "  receiver-class evidence at those sites:\n"
poly_receivers.sort.each { |fact, count| report << format("    %5d  %s\n", count, fact) }
report << "  excluded definitions across sites (counts repeat per call site):\n"
poly_exclusions.sort_by { |reason, count| [-count, reason] }.each do |reason, count|
  report << format("    %5d  %s\n", count, reason)
end
report << "  guarded native Hash#values call sites: #{hash_values_fast_paths}\n"
report << "  everything else (not yet attempted or failed MONO/TYPED): #{[total_dispatch - shipped_poly, 0].max}\n"
report << "distinct unresolved generic-dispatch method names: #{poly_dynamic_names.size}\n"
report << "top 30 unresolved generic-dispatch method names:\n"
poly_dynamic_names.sort_by { |name, n| [-n, name] }.first(30).each_with_index do |(name, n), i|
  report << format("  %2d. %5d  :%s\n", i + 1, n, name)
end
report << "top 30 cached dispatch method names (generic sites and guarded fallbacks):\n"
dispatch_counts.sort_by { |name, n| [-n, name] }.first(30).each_with_index do |(name, n), i|
  generic = poly_dynamic_names[name]
  report << format("  %2d. %5d total  %4d generic  %5d other  :%s\n",
                   i + 1, n, generic, [n - generic, 0].max, name)
end

if ENV['BC2CPP_PROFILE_TIMINGS'] == '1'
  report << "\n-- bc2cpp generation phase timings (two complete passes) --\n"
  [['analysis pass', err], ['shipped pass', @shipped_stderr]].each do |label, stderr|
    report << "  #{label}:\n"
    stderr.each_line.grep(/^BC2CPP_TIME /).each { |line| report << "    #{line.sub(/^BC2CPP_TIME /, '')}" }
    stderr.each_line.grep(/^BC2CPP_DETAIL /).each { |line| report << "    #{line.sub(/^BC2CPP_DETAIL /, 'detail ')}" }
  end
end

if REPORT_PATH
  File.write(REPORT_PATH, report)
else
  puts report
end
