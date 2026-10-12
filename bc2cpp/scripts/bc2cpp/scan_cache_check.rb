#!/usr/bin/env ruby
# frozen_string_literal: true

# Check ScanCache (tools/bc2cpp/scan_cache.rb, ADR 0415): the disk memo of the scans that read only the
# outside-world sources. A stored result must be returned only for the exact inputs and scanner sources it was
# computed from, must never change what the scan returns, and must not be written at all unless
# BC2CPP_SCAN_CACHE_DIR is set. Run by the `ruby-checks` job; needs no mruby build.

require 'tmpdir'
require 'fileutils'
require 'stringio'
require_relative '../../tools/bc2cpp/bc2cpp'

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

# Calls made by the block of the scan over `inputs` under `env`; the scan's value.
def run_scan(inputs, name: 'scan', cache_absent: true, value: -> { { 'a' => [1, 2] } })
  calls = 0
  result = ScanCache.fetch(name, inputs, cache_absent: cache_absent) do
    calls += 1
    value.call
  end
  [calls, result]
end

def capture_stderr
  saved = $stderr
  $stderr = StringIO.new
  yield
  $stderr.string
ensure
  $stderr = saved
end

Dir.mktmpdir do |tmp|
  cache = File.join(tmp, 'cache')
  one = File.join(tmp, 'one.c')
  two = File.join(tmp, 'two.c')
  File.write(one, 'mrb_define_method(a);')
  File.write(two, 'mrb_define_method(b);')
  old_env = ENV.fetch(ScanCache::ENV_NAME, nil)

  puts '-- off by default'
  ENV.delete(ScanCache::ENV_NAME)
  check.call('without the variable the block runs every time', [run_scan([one]).first, run_scan([one]).first] == [1, 1])
  check.call('without the variable nothing is written', !File.exist?(cache))

  puts '-- on'
  ENV[ScanCache::ENV_NAME] = cache
  calls, first = run_scan([one, two])
  check.call('the first call computes and stores', calls == 1 && Dir.children(cache).size == 1)
  calls, again = run_scan([one, two])
  check.call('the second call is loaded, not computed', calls.zero?)
  check.call('a loaded value equals the computed one', again == first)
  check.call('a loaded value is a fresh object each time', !again.equal?(run_scan([one, two]).last))
  check.call('a different scan name is a different entry', run_scan([one, two], name: 'other').first == 1)
  check.call('the order of the inputs is part of the key', run_scan([two, one]).first == 1)

  puts '-- invalidation'
  File.write(one, 'mrb_define_method(c);')
  check.call('a changed input file is recomputed', run_scan([one, two]).first == 1)
  File.write(one, 'mrb_define_method(c);')
  check.call('a rewrite with the same bytes still hits', run_scan([one, two]).first.zero?)
  saved_tools = ScanCache.instance_variable_get(:@tools_digest)
  ScanCache.instance_variable_set(:@tools_digest, 'another scanner source')
  check.call('a changed scanner source is recomputed', run_scan([one, two]).first == 1)
  ScanCache.instance_variable_set(:@tools_digest, saved_tools)
  check.call('the tools digest covers every tools/bc2cpp source', saved_tools.is_a?(String) && saved_tools.size == 64)

  puts '-- inputs that are not files'
  missing = File.join(tmp, 'missing.c')
  check.call('an absent input is part of the key and the scan is stored', [run_scan([one, missing]).first, run_scan([one, missing]).first] == [1, 0])
  File.write(missing, 'now present')
  check.call('the input appearing is a new key', run_scan([one, missing]).first == 1)
  FileUtils.rm_f(missing)
  check.call('a scan that reports an absent input is never stored',
             [run_scan([one, missing], name: 'reports', cache_absent: false).first,
              run_scan([one, missing], name: 'reports', cache_absent: false).first] == [1, 1])
  check.call('a directory input is never stored', [run_scan([tmp], name: 'dir').first, run_scan([tmp], name: 'dir').first] == [1, 1])

  puts '-- failures are reported, never hidden'
  entry = File.join(cache, "scan-#{ScanCache.key_for('scan', [one, two], true)}.bin")
  File.binwrite(entry, 'not a marshal dump')
  warned = capture_stderr { @corrupt = run_scan([one, two]) }
  check.call('a corrupt entry is reported and recomputed', warned.include?('unreadable') && @corrupt.first == 1)
  check.call('the recomputed entry replaces the corrupt one', run_scan([one, two]).first.zero?)
  warned = capture_stderr { @unstorable = run_scan([one], name: 'proc', value: -> { Hash.new { |h, k| h[k] = 1 } }) }
  check.call('a value that cannot be dumped is returned and reported', warned.include?('was not stored') && @unstorable.first == 1)
  blocked = File.join(tmp, 'blocked')
  File.write(blocked, 'a file where the cache directory should be')
  ENV[ScanCache::ENV_NAME] = File.join(blocked, 'sub')
  warned = capture_stderr { @blocked = run_scan([one], name: 'blocked') }
  check.call('an unwritable cache directory is reported and the value still returned', warned.include?('was not stored') && @blocked.last == { 'a' => [1, 2] })
  ENV[ScanCache::ENV_NAME] = cache

  puts '-- concurrent writers'
  pids = Array.new(4) { fork { run_scan([one, two], name: 'race', value: -> { { 'b' => 3 } }); exit!(0) } }
  pids.each { |pid| Process.wait(pid) }
  check.call('four processes storing one key leave a single whole entry',
             Dir[File.join(cache, 'race-*')].size == 1 && run_scan([one, two], name: 'race').first.zero?)

  puts '-- the real scanners'
  root = File.expand_path('../..', __dir__)
  natives = Dir[File.join(root, '3rd/mruby/src/*.c')] + Dir[File.join(root, '3rd/mruby/mrbgems/*/src/*.c')]
  if natives.empty?
    puts '  SKIP 3rd/mruby is not checked out'
  else
    ENV.delete(ScanCache::ENV_NAME)
    plain = [NativeExpressionDevirt.analyze(natives), NativeExpressionDevirt.analyze_exact_class_expressions(natives),
             outside_world_tokens(natives)]
    ENV[ScanCache::ENV_NAME] = File.join(tmp, 'real')
    cold = [NativeExpressionDevirt.analyze(natives), NativeExpressionDevirt.analyze_exact_class_expressions(natives),
            outside_world_tokens(natives)]
    warm = [NativeExpressionDevirt.analyze(natives), NativeExpressionDevirt.analyze_exact_class_expressions(natives),
            outside_world_tokens(natives)]
    check.call('the scans return the same with the cache off, cold and warm', plain == cold && cold == warm)
    check.call('the three scans were stored', Dir.children(File.join(tmp, 'real')).size == 3)

    puts '-- the stateful scans (ADR 0415): a closed world, the class registrations and the file registrations'
    # What a closed world over `decls` ends up holding from the native sources (the state the scan fills).
    state_names = %i[@native_code_tokens @native_tokens @native_other_literals @outside_names @outside_name_paths
                     @global_refusal @touches @clone_sent @freeze_possible @singleton_makers @dynamic_constant_mutation
                     @outside_constant_writes @outside_constant_write_counts]
    world_state = lambda do |decls|
      world = ClosedWorld.new(ireps: {}, registry: {}, class_decls: decls.to_h { |name| [name, [{ super: 'Object' }]] },
                              walked: {}, native_paths: natives, ruby_paths: [])
      state_names.map { |name| world.instance_variable_get(name) }
    end
    # Each scan's in-process memo is emptied, so a phase computes or loads as a new process would.
    fresh_process = lambda do
      NativeExpressionDevirt::REGISTRATION_CACHE.clear
      NativeExpressionDevirt::CLASS_METHOD_CACHE.clear
      NativeDirect.instance_variable_get(:@registrations).clear
      NativeDirect.instance_variable_set(:@sibling_owners, nil)
    end
    # The result of the three stateful scans under `dir` (nil: cache off), the scan's calls and what it printed.
    phase = lambda do |dir, decls: %w[Array Hash RGSS::Bitmap]|
      fresh_process.call
      ENV[ScanCache::ENV_NAME] = dir
      calls = Hash.new(0)
      wrapped = lambda do |owner, name|
        original = owner.method(name)
        owner.define_singleton_method(name) do |*args|
          calls[name] += 1
          original.call(*args)
        end
        original
      end
      originals = [[ClosedWorld, :native_facts], [NativeExpressionDevirt, :scan_class_registrations],
                   [NativeDirect, :scan_file_registrations]].map { |owner, name| [owner, name, wrapped.call(owner, name)] }
      warned = capture_stderr do
        @phase_value = [world_state.call(decls), NativeExpressionDevirt.class_registrations(natives),
                        natives.map { |path| NativeDirect.file_registrations(path) }]
      end
      originals.each { |owner, name, original| owner.define_singleton_method(name, original) }
      [@phase_value, calls, warned]
    end
    stateful = File.join(tmp, 'stateful')
    off, off_calls, off_warned = phase.call(nil)
    cold, cold_calls, cold_warned = phase.call(stateful)
    warm, warm_calls, warm_warned = phase.call(stateful)
    check.call('the closed world, class and file registrations are the same with the cache off, cold and warm',
               off == cold && cold == warm)
    # One closed world, one class registration scan, and one file registration scan per native source.
    computed = 2 + natives.size
    check.call('the cache off and the cold run compute every scan, the warm run computes none',
               off_calls.values.sum == computed && cold_calls.values.sum == computed && warm_calls.empty?)
    check.call('the stateful scans print nothing on success, cache off, cold or warm',
               [off_warned, cold_warned, warm_warned].all?(&:empty?))
    stored = Dir.children(stateful)
    check.call('each stateful scan stores its entries under its name',
               %w[closed_world.native native_expression_devirt.class_registrations native_direct.file_registrations].all? do |name|
                 stored.any? { |file| file.start_with?("#{name}-") }
               end)
    other_decls = phase.call(stateful, decls: %w[Array Integer Rect])
    check.call('the closed world depends on the declared classes: a warm entry is not reused for another set',
               other_decls[0] == phase.call(nil, decls: %w[Array Integer Rect])[0] && other_decls[0] != warm[0])
  end

  old_env ? ENV[ScanCache::ENV_NAME] = old_env : ENV.delete(ScanCache::ENV_NAME)
end

if failures.empty?
  puts 'bc2cpp scan cache check: PASS'
else
  warn "bc2cpp scan cache check: #{failures.size} failure(s)"
  exit 1
end
