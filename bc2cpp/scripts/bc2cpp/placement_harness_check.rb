#!/usr/bin/env ruby
# frozen_string_literal: true

# The gate harness any stack or in-frame placement of objects must pass (docs/bc2cpp-placement-harness.md).
# Placement itself is NOT implemented: tools/bc2cpp/inframe_placement.rb is a stub that refuses the experimental
# flag. This check proves what can be proven now and reports the rest as an explicit SKIP:
#   A. the flag is off by default and off is identity: generation with the flag unset or '0' is byte-identical,
#      and the flag set to '1' is refused loudly (never a silent fallback to the heap);
#   B. the static gate: the escape verdict and the immediate-ivars fact accept the positive fixture's object
#      (confined and immediate) and refuse the deliberately leaking negative fixture (verdict "escapes");
#   C. the runtime gates on the heap build (the only build that exists): after each call a full GC at frame exit
#      leaves no live object the call made, and the frame-exit tripwire finds no ivar or array element that points
#      into the dead stack; compiled and interpreted runs agree (with sanitizers when the toolchain has them);
#   D. the tripwire detects a planted dangling stack reference (a self-test of gate 1, run in its own process,
#      because the planted reference is dead memory that no later GC may traverse);
#   E. the heap-vs-stack differential: SKIP (not run) while placement is a stub. With PLACEMENT_HARNESS_REQUIRE=1
#      that SKIP fails the check, so it cannot stay in place once placement lands.
#
# Usage: MRBC=path/to/host/mrbc BC2CPP_MRUBY_FULL=path/to/build ruby scripts/bc2cpp/placement_harness_check.rb

require 'fileutils'
require 'tmpdir'
require_relative 'fixture_runtime'
require_relative '../../tools/bc2cpp/inframe_placement'

ENV['BC2CPP_SIG_DIRS'] ||= ''
unless ENV['MRBC']
  puts '  SKIP: no host mrbc (set MRBC)'
  exit 0
end
unless system(ENV['MRBC'], '--version', out: File::NULL, err: File::NULL)
  warn "placement_harness_check: MRBC=#{ENV['MRBC']} does not run"
  exit 1
end

# The experimental flag must not leak in from the caller's environment into the "off" arm.
ENV.delete(InFramePlacement::ENV_KEY)

FIXTURE = <<~'RUBY'
  class PlCell
    def initialize; @n = 1; @done = false; end
    def settle; @n = 2; @done = true; nil; end
    def peek; @n; end
  end
  class PlUse
    def local_cell; c = PlCell.new; c.settle; 0; end
    def plain_pair; c = PlCell.new; c.peek; 1; end
  end
  # Results of sends on the object are not used: a send's result may alias the receiver, which makes it not immediate.
  # Negative fixture: each method keeps its object alive past the frame, so its site must read "escapes".
  class PlLeak
    def initialize; @n = 1; end
    def peek; @n; end
  end
  class PlLeakUse
    def leak_global; $pl_leak = PlLeak.new; 0; end
    def leak_array; $pl_keep = []; c = PlLeak.new; $pl_keep << c; 0; end
  end
RUBY

OWNERS = %w[PlCell PlUse PlLeak PlLeakUse].freeze
RUN_OWNERS = %w[PlCell PlUse].freeze
POSITIVE = 'PlUse#local_cell'
NEGATIVE = %w[PlLeakUse#leak_global PlLeakUse#leak_array].freeze

failures = []
skips = []
check = lambda do |label, condition|
  puts "#{condition ? 'ok  ' : 'FAIL'} #{label}"
  failures << label unless condition
end
skip = lambda do |label|
  puts "SKIP #{label}"
  skips << label
end

# Generates FIXTURE into dir with the experimental flag set to `flag` (nil = unset) and, when `escape` is a path,
# writes the escape report there. Returns [code, diagnostics] as Bc2cppFixtureRuntime.generate does.
def generate_with(dir, flag: nil, escape: nil)
  saved = ENV.fetch(InFramePlacement::ENV_KEY, nil)
  if flag
    ENV[InFramePlacement::ENV_KEY] = flag
  else
    ENV.delete(InFramePlacement::ENV_KEY)
  end
  ENV['BC2CPP_ESCAPE_REPORT'] = escape if escape
  Bc2cppFixtureRuntime.generate(FIXTURE, dir, only_owners: OWNERS)
ensure
  ENV.delete('BC2CPP_ESCAPE_REPORT')
  if saved
    ENV[InFramePlacement::ENV_KEY] = saved
  else
    ENV.delete(InFramePlacement::ENV_KEY)
  end
end

# The site rows (verdict per creation site) and the ivars rows (immediate-ivars fact) of an escape report.
def gate_rows(tsv)
  rows = File.readlines(tsv, chomp: true).map { |line| line.split("\t", -1) }
  sites = rows.select { |r| r[0] == 'site' && r[5] == 'object' }
  ivars = rows.select { |r| r[0] == 'ivars' }.to_h { |r| [r[2], r] }
  [sites, ivars]
end

# The static placement gate: a site is placeable only when it is confined and every ivar store is immediate.
def static_gate(owner, sites, ivars)
  site = sites.find { |r| r[2] == owner }
  return [false, 'no creation site'] unless site
  return [false, 'escapes'] unless site[6] == 'confined'

  ivar = ivars[owner]
  return [false, 'no immediate-ivars fact'] unless ivar && ivar[7] == 'immediate'

  [true, 'confined and immediate']
end

# Shared C++ for the tripwire: a heap object's ivar values and array elements are scanned for a pointer into the
# dead stack, that is below the scanner's own frame and within 8 MiB of the scenario frame.
TRIPWIRE_CPP = <<~CPP
  #include <cstdint>
  #include <cstdlib>
  static char* bc2cpp_stack_top = nullptr;
  static size_t tripwire_hits = 0;
  struct TripScan { const char* here; };
  static bool in_dead_stack(const void* q, const char* here) {
    uintptr_t p = (uintptr_t)q, h = (uintptr_t)here, top = (uintptr_t)bc2cpp_stack_top;
    return p < h && p + ((uintptr_t)8 << 20) >= top;
  }
  static void scan_value(mrb_value v, const TripScan* s) {
    if (!mrb_immediate_p(v) && in_dead_stack(mrb_ptr(v), s->here)) ++tripwire_hits;
  }
  static int scan_ivar(mrb_state*, mrb_sym, mrb_value v, void* p) {
    scan_value(v, (const TripScan*)p);
    return 0;
  }
  static int scan_object(mrb_state* M, struct RBasic* obj, void* p) {
    const TripScan* s = (const TripScan*)p;
    if (obj->tt == MRB_TT_OBJECT) {
      mrb_iv_foreach(M, mrb_obj_value(obj), scan_ivar, (void*)s);
    } else if (obj->tt == MRB_TT_ARRAY) {
      mrb_value av = mrb_obj_value(obj);
      for (mrb_int i = 0; i < RARRAY_LEN(av); ++i) scan_value(mrb_ary_ref(M, av, i), s);
    }
    return MRB_EACH_OBJ_OK;
  }
  // Walks the live heap (instances and arrays only; the VM register stacks and globals are not walked, see the doc).
  static __attribute__((noinline)) size_t tripwire_scan(mrb_state* M) {
    volatile char marker = 0;
    TripScan s{ const_cast<const char*>(&marker) };
    tripwire_hits = 0;
    mrb_objspace_each_objects(M, scan_object, &s);
    return tripwire_hits;
  }
CPP

GATE_BODY = <<~CPP
  #{TRIPWIRE_CPP}
  // One call as a placed frame would run it: live objects before and after, a full GC at frame exit.
  static __attribute__((noinline)) void gated(mrb_state* M, const char* label, mrb_value obj, const char* meth) {
    mrb_full_gc(M);
    size_t before = M->gc.live;
    // The call's own C-API temporaries sit in the GC arena until restored; the frame exit releases them.
    int arena = mrb_gc_arena_save(M);
    call(M, label, obj, meth);
    mrb_gc_arena_restore(M, arena);
    mrb_full_gc(M);
    long leaked = (long)M->gc.live - (long)before;
    size_t dangling = tripwire_scan(M);
    std::printf("gate %s leaked=%ld dangling=%zu\\n", label, leaked, dangling);
  }
  static int scenario(mrb_state* M) {
    volatile char top_marker = 0;
    bc2cpp_stack_top = const_cast<char*>(&top_marker);
    mrb_value cls = mrb_const_get(M, mrb_obj_value(M->object_class), mrb_intern_lit(M, "PlUse"));
    mrb_value use = mrb_obj_new(M, mrb_class_ptr(cls), 0, nullptr);
    // A C local is no GC root: keep the receiver alive across the full GCs the gates run.
    mrb_gc_protect(M, use);
    gated(M, "local_cell", use, "local_cell");
    gated(M, "plain_pair", use, "plain_pair");
    return 0;
  }
CPP

SELFTEST_BODY = <<~CPP
  #{TRIPWIRE_CPP}
  // The planted object lives in this frame, 8 KiB below the scenario, and is dead once this returns.
  static __attribute__((noinline)) void plant_dangling(mrb_state* M, mrb_value holder) {
    volatile char pad[8192];
    pad[0] = 0;
    struct RObject frame_object = {};
    frame_object.tt = MRB_TT_OBJECT;
    frame_object.c = M->object_class;
    mrb_iv_set(M, holder, mrb_intern_lit(M, "@leak"), mrb_obj_value(&frame_object));
  }
  static int scenario(mrb_state* M) {
    volatile char top_marker = 0;
    bc2cpp_stack_top = const_cast<char*>(&top_marker);
    mrb_value holder = mrb_obj_new(M, M->object_class, 0, nullptr);
    mrb_gc_protect(M, holder);
    plant_dangling(M, holder);
    size_t hits = tripwire_scan(M);
    std::printf("selftest tripwire planted=1 detected=%zu\\n", hits);
    std::fflush(stdout);
    // The planted reference is dead memory: no later GC (mrb_close included) may traverse it.
    std::_Exit(0);
  }
CPP

Dir.mktmpdir('placement-harness') do |root|
  # A. Flag identity and refusal.
  puts '-- A. flag off is identity; flag on is refused'
  unset_dir = File.join(root, 'unset')
  zero_dir = File.join(root, 'zero')
  on_dir = File.join(root, 'on')
  [unset_dir, zero_dir, on_dir].each { |d| FileUtils.mkdir_p(d) }
  unset_code, = generate_with(unset_dir)
  zero_code, = generate_with(zero_dir, flag: '0')
  check.call('the generated C++ is byte-identical with the flag unset and with it set to 0',
             unset_code.gsub(unset_dir, 'DIR') == zero_code.gsub(zero_dir, 'DIR'))
  refused = begin
    generate_with(on_dir, flag: '1')
    false
  rescue RuntimeError => e
    e.message.include?('not implemented') && e.message.include?(InFramePlacement::ENV_KEY)
  end
  check.call('the flag set to 1 is refused, not silently ignored (placement is a stub)', refused)

  # B. The static gate on the fixture, and the negative fixture's refusal.
  puts '-- B. static gate: confined and immediate, or refused'
  gate_dir = File.join(root, 'gate')
  FileUtils.mkdir_p(gate_dir)
  tsv = File.join(gate_dir, 'escape.tsv')
  generate_with(gate_dir, escape: tsv)
  check.call('the escape report is written', File.exist?(tsv))
  sites, ivars = gate_rows(tsv)
  ok, why = static_gate(POSITIVE, sites, ivars)
  check.call("#{POSITIVE} passes the static gate (#{why})", ok)
  NEGATIVE.each do |owner|
    ok, why = static_gate(owner, sites, ivars)
    # The negative fixture must fail the gate, for the escape reason; a pass here would mean the gate is blind.
    check.call("#{owner} fails the static gate as the leaking negative fixture (#{why})", !ok && why == 'escapes')
  end

  # C. Runtime gates on the heap build, and D. the tripwire self-test.
  puts '-- C/D. runtime gates on the heap build'
  build = Bc2cppFixtureRuntime.full_or_build
  if build.nil?
    skip.call('runtime gates: needs a full-core libmruby (BC2CPP_MRUBY_FULL, or rake, g++ and 3rd/mruby)')
  else
    sanitizer = %w[-fsanitize=address,undefined -fno-omit-frame-pointer -g]
    probe = File.join(root, 'probe.cc')
    File.write(probe, "int main() { return 0; }\n")
    sanitized = Bc2cppCxx.system(*sanitizer, probe, '-o', File.join(root, 'probe')) &&
                system(File.join(root, 'probe'), out: File::NULL, err: File::NULL)
    if sanitized
      ENV['BC2CPP_CXXFLAGS'] = sanitizer.join(' ')
      puts 'info  runtime gates built with -fsanitize=address,undefined'
    else
      skip.call('sanitizers: the toolchain cannot build and run -fsanitize=address,undefined; runtime gates run without them')
    end

    # The tripwire reads the native stack. detect_stack_use_after_return=1 moves address-taken frames to ASan's
    # fake stack, outside the window it scans, so the gate runs use =0; the =1 run is a smoke run of the same binary.
    native = { 'ASAN_OPTIONS' => 'detect_stack_use_after_return=0' }
    uar = { 'ASAN_OPTIONS' => 'detect_stack_use_after_return=1' }
    run_dir = File.join(root, 'run')
    FileUtils.mkdir_p(run_dir)
    _run_code, run_err = generate_with(run_dir)
    built, results = Bc2cppFixtureRuntime.run(run_dir, run_err, RUN_OWNERS, GATE_BODY,
                                              build: build, full: true, envs: [native, uar])
    check.call('the positive fixture builds and runs', built)
    output, native_ok = built ? results[0] : ['', false]
    uar_output, uar_ok = built ? results[1] : ['', false]
    check.call('the positive fixture exits cleanly on the native stack', native_ok)
    sections = Bc2cppFixtureRuntime.sections(output)
    compiled = sections['compiled']
    interpreted = sections['interpreted']
    gate_lines = ->(lines) { (lines || []).grep(/\Agate /) }
    both = gate_lines.call(compiled) + gate_lines.call(interpreted)
    both.each { |line| puts "     #{line}" }
    check.call('both runs report both gates', gate_lines.call(compiled).size == 2 && gate_lines.call(interpreted).size == 2)
    check.call('no gate leaves a live object behind past frame exit (compiled and interpreted)',
               !both.empty? && both.all? { |l| l.include?('leaked=0 ') })
    check.call('the tripwire finds no dangling stack reference in the heap (compiled and interpreted)',
               !both.empty? && both.all? { |l| l.end_with?('dangling=0') })
    strip = ->(lines) { lines.reject { |l| l.start_with?('  dispatches=') } }
    check.call('compiled and interpreted runs print the same values and gate lines',
               compiled && interpreted && strip.call(compiled) == strip.call(interpreted))
    puts output.lines.last(30).join unless native_ok && compiled && interpreted

    uar_gates = gate_lines.call(uar_output.lines.map(&:chomp))
    check.call('smoke: the heap build runs clean under detect_stack_use_after_return=1 (no sanitizer report, no leak)',
               uar_ok && !uar_output.include?('AddressSanitizer') && uar_gates.size == 4 &&
               uar_gates.all? { |l| l.include?('leaked=0 ') })

    # D. The planted dangling reference must be detected, in its own process (see SELFTEST_BODY).
    puts '-- D. tripwire self-test: a planted dangling stack reference'
    self_dir = File.join(root, 'self')
    FileUtils.mkdir_p(self_dir)
    _self_code, self_err = generate_with(self_dir)
    self_built, self_results = Bc2cppFixtureRuntime.run(self_dir, self_err, [], SELFTEST_BODY,
                                                        build: build, full: true, vms: [false], envs: [native])
    self_output, = self_built ? self_results[0] : ['', false]
    detected = self_output[/selftest tripwire planted=1 detected=(\d+)/, 1]&.to_i
    check.call('the self-test builds and runs', self_built)
    check.call('the tripwire detects the planted dangling stack reference (detected=1)', self_built && detected == 1)
    puts self_output.lines.last(5).join unless self_built && detected == 1
  end

  # E. The heap-vs-stack differential needs a placement that exists.
  puts '-- E. heap-vs-stack differential'
  if InFramePlacement::IMPLEMENTED
    check.call('the differential arm exists for the implemented placement (not written yet)', false)
  elsif ENV['PLACEMENT_HARNESS_REQUIRE'] == '1'
    check.call('in-frame placement is implemented and its differential passes (PLACEMENT_HARNESS_REQUIRE=1)', false)
  else
    skip.call('heap-vs-stack differential: in-frame placement is a stub (TODO in tools/bc2cpp/inframe_placement.rb); not run')
  end
end

puts "placement_harness_check: #{skips.size} explicit skip(s)" unless skips.empty?
if failures.empty?
  puts 'placement_harness_check: all checks passed'
else
  puts "placement_harness_check: #{failures.size} failure(s)"
  exit 1
end
