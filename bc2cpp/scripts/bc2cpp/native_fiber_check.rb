#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative 'fixture_runtime'
require_relative '../../tools/bc2cpp/native_vm'

reference = Bc2cppFixtureRuntime.full_or_build
abort 'native Fiber check requires a full-core mruby build' unless reference

root = Bc2cppFixtureRuntime::ROOT
work = ENV.fetch('BC2CPP_NATIVE_BUILD_DIR', File.join(root, 'build-native-fiber'))
FileUtils.mkdir_p(work)
probe = File.join(work, 'probe')
FileUtils.mkdir_p(File.join(probe, 'mrblib'))
FileUtils.mkdir_p(File.join(probe, 'src'))
fixture = File.read(File.join(__dir__, 'resumable_variants_check.rb'))
scenarios = eval(fixture[/^SCENARIOS = (\[.*?^\])\.freeze/m, 1], binding, 'resumable_variants scenarios')
source = +<<~'RUBY_SOURCE'
  def show(label)
    puts "#{label}: #{yield.inspect}"
  rescue StandardError => e
    puts "#{label}: raised #{e.class}: #{e.message}"
  end
  def drain(f)
    out = []
    while f.alive?
      out << f.resume
      GC.start
    end
    out
  end
RUBY_SOURCE
scenarios.each do |label, fiber, plain|
  source << "show('fiber #{label}') { drain(Fiber.new { #{fiber} }) }\nshow('plain #{label}') { #{plain} }\n"
end
source << <<~'RUBY_SOURCE'
  class NativeFiberSource
    include Enumerable
    def each(start = 1, *rest, stop: 3, &block)
      while start <= stop
        block.call(start)
        start += 1
      end
      self
    end
  end
  def native_nonlocal_result
    [1, 2].each do |value|
      Fiber.yield value
      return :returned if value == 2
    end
  end
  show('nonlocal return') { drain(Fiber.new { native_nonlocal_result }) }
  show('C boundary stays an error') { drain(Fiber.new { [2, 1].sort! { |a, b| Fiber.yield a; a <=> b } }) }
  show('fiber transfer') do
    main = Fiber.current
    f = Fiber.new { resumed = main.transfer(:yielded); [:done, resumed] }
    [f.transfer, f.transfer(:resumed)]
  end
  show('custom nested each') { drain(Fiber.new { NativeFiberSource.new.map { |x| Fiber.yield x; x * 3 } }) }
  show('nested ensure') do
    events = []
    result = drain(Fiber.new do
      begin
        NativeFiberSource.new.each do |x|
          begin
            Fiber.yield x
            raise ArgumentError, 'after resume' if x == 2
          ensure
            events << x
          end
        end
      rescue ArgumentError => e
        events << e.message
      ensure
        events << :outer
      end
      :done
    end)
    [result, events]
  end
  show('catch throw after yield') { drain(Fiber.new { catch(:tag) { |tag| Fiber.yield tag; throw tag, :caught } }) }
  show('nested fibers and resume values') do
    outer = Fiber.new do |a|
      inner = Fiber.new { |b| Fiber.yield [a, b]; :inner_done }
      first = inner.resume(2)
      resumed = Fiber.yield(first)
      [resumed, inner.resume]
    end
    [outer.resume(1), outer.resume(3, 4)]
  end
  show('escaping closure') do
    f = Fiber.new do
      x = 1
      capture = proc { x += 1 }
      Fiber.yield capture
      capture.call
    end
    capture = f.resume
    GC.start
    [capture.call, f.resume, capture.call]
  end
  show('enumerator lazy nested') do
    e = NativeFiberSource.new.lazy.map { |x| x * 2 }.select { |x| x > 2 }.to_enum
    [e.next, e.next]
  end
  show('instruction-looking string data') do
    ['static const mrb_code pretend_iseq_0[2] = {0x00,0x00};',
     'MRB_IREP_STATIC,pretend_iseq_0,']
  end
  show('arity and parameters') do
    f = proc { |a, b = 1, *rest, key: 2, &block| }
    [f.arity, f.parameters]
  end
  if respond_to?(:native_only_reject_bytecode, true)
    show('NATIVE_ONLY root') { native_only_reject_bytecode }
    show('NATIVE_ONLY fiber') { Fiber.new { native_only_reject_bytecode }.resume }
  end
  puts 'end'
  puts "REGISTRATION #{native_fiber_compiled?}" if respond_to?(:native_fiber_compiled?, true)
  puts "AUDIT #{native_fiber_counts.inspect}" if respond_to?(:native_fiber_counts, true)
RUBY_SOURCE
wide = "def native_wide_registers\n" + (0...250).map { |i| "  local#{i} = #{i}\n" }.join +
       "  Fiber.yield [#{(0...250).map { |i| "local#{i}" }.join(", ")}]\n  [local0, local249]\nend\n" +
       "show('wide registers') { drain(Fiber.new { native_wide_registers }) }\n"
source = source.sub("puts 'end'", wide + "puts 'end'")
puts '-- generate optimized core methods with native support programs'
generated = File.join(work, 'generated')
FileUtils.mkdir_p(generated)
keys = %w[MRBC BC2CPP_NATIVE_VM_DIR BC2CPP_GUARD_FIBER_FREE BC2CPP_SIG_DIRS BC2CPP_SHARDS BC2CPP_SHARD_MIN_BYTES]
saved_env = ENV.to_h.slice(*keys)
begin
  ENV['MRBC'] = File.join(reference, 'bin/mrbc')
  ENV['BC2CPP_NATIVE_VM_DIR'] = File.join(work, 'host/native-vm')
  ENV['BC2CPP_GUARD_FIBER_FREE'] = '0'
  ENV['BC2CPP_SIG_DIRS'] = ''
  ENV['BC2CPP_SHARDS'] = '2'
  ENV['BC2CPP_SHARD_MIN_BYTES'] = '1'
  code, = Bc2cppFixtureRuntime.generate(source, generated, core: true,
                                      only_owners: %w[Array Enumerable Hash Integer Float Range String StringIO])
  abort 'generated Fiber support still loads bytecode or Ruby source' if code.match?(/mrb_load_(?:irep|string)\(/)
ensure
  keys.each { |key| saved_env.key?(key) ? ENV[key] = saved_env[key] : ENV.delete(key) }
end
Dir[File.join(generated, 'fixture_gen_shard*.cpp')].each_with_index do |shard, index|
  File.write(File.join(probe, "src/compiled_shard#{index}.cxx"), "#include #{shard.dump}\n")
end
program = File.join(probe, 'mrblib/probe.rb')
File.write(program, source)
File.write(File.join(probe, 'mrbgem.rake'), <<~RUBY_CONFIG)
  MRuby::Gem::Specification.new('native-fiber-probe') do |spec|
    spec.license = 'MIT'
    spec.author = 'bc2cpp checks'
  end
RUBY_CONFIG
FileUtils.rm_f(File.join(probe, 'src/probe.c'))
File.write(File.join(probe, 'src/probe.cxx'), "#include #{File.join(generated, 'fixture_gen.cpp').dump}\n" + <<~'C')
  #include <mruby.h>
  #include <mruby/array.h>
  #include <mruby/irep.h>
  #include <mruby/opcode.h>
  #include <cstdlib>
  static mrb_int native_steps, bytecode_steps;
  static void audit(mrb_state* mrb, const mrb_irep* irep, const mrb_code* pc, mrb_value* regs) {
    if (irep->native) native_steps++;
    else bytecode_steps++;
  }
  static mrb_value counts(mrb_state* mrb, mrb_value self) {
    mrb_value values[] = {mrb_int_value(mrb, native_steps), mrb_int_value(mrb, bytecode_steps)};
    return mrb_ary_new_from_values(mrb, 2, values);
  }
  static mrb_value reject_bytecode(mrb_state* mrb, mrb_value) {
    static const mrb_code rejected_program[] = {OP_STOP};
    mrb_irep* irep = mrb_add_irep(mrb);
    irep->iseq = rejected_program;
    irep->ilen = sizeof(rejected_program);
    irep->nlocals = 1;
    irep->nregs = 4;
    irep->flags |= MRB_ISEQ_NO_FREE;
    RProc* proc = mrb_proc_new(mrb, irep);
    mrb_irep_decref(mrb, irep);
    return mrb_top_run(mrb, proc, mrb_top_self(mrb), 0);
  }
  static mrb_value compiled_method(mrb_state* mrb, mrb_value self) {
    struct RClass* found = mrb->array_class;
    mrb_method_t method = mrb_method_search_vm(mrb, &found, mrb_intern_lit(mrb, "each"));
    return mrb_bool_value(!MRB_METHOD_UNDEF_P(method) &&
                         (!MRB_METHOD_PROC_P(method) || MRB_PROC_CFUNC_P(MRB_METHOD_PROC(method))));
  }
  extern "C" void mrb_native_fiber_probe_gem_init(mrb_state* mrb) {
    if (std::getenv("NATIVE_PROBE_COMPILED")) {
      bc2cpp_gem_init(mrb);
      bc2cpp_register_owner_methods(mrb);
    }
    mrb->code_fetch_hook = audit;
    mrb_define_method(mrb, mrb->object_class, "native_only_reject_bytecode", reject_bytecode, MRB_ARGS_NONE());
    mrb_define_method(mrb, mrb->object_class, "native_fiber_compiled?", compiled_method, MRB_ARGS_NONE());
    mrb_define_method(mrb, mrb->object_class, "native_fiber_counts", counts, MRB_ARGS_NONE());
  }
  extern "C" void mrb_native_fiber_probe_gem_final(mrb_state* mrb) {}
C
config = File.join(work, 'config.rb')
File.write(config, <<~RUBY_CONFIG)
  require #{File.join(root, 'tools/bc2cpp/native_vm_build.rb').dump}
  MRuby::Build.new('host') do |conf|
    toolchain :gcc
    %w[stdlib stdlib-ext stdlib-io math].each { |box| conf.gembox box }
    conf.gem core: 'mruby-metaprog'
    conf.gem core: 'mruby-method'
    conf.gem #{File.join(root, '3rd/mruby-stringio').dump}
    conf.gem #{probe.dump}
    conf.cxx.flags << '-std=gnu++17'
    conf.cxx.include_paths << #{File.join(root, 'include').dump}
    conf.cxx.include_paths << #{File.join(root, 'mruby-rgss/src').dump}
    enable_cxx_exception
    enable_debug
    [conf.cc, conf.cxx].each { |tool| tool.defines << 'MRB_USE_DEBUG_HOOK' }
    NativeVM.configure(conf, native_only: true)
  end
RUBY_CONFIG
# The probe includes freshly generated compiler output on every run.
FileUtils.rm_f(Dir[File.join(work, 'host/mrbgems/native-fiber-probe/src/probe.{o,d}')])
build_env = { 'MRUBY_CONFIG' => config, 'MRUBY_BUILD_DIR' => work }.merge(Bc2cppCxx.rake_env)
puts '-- build native continuations and a native-only Fiber runtime'
# Without binary gems, `all` does not request the flags used to link an external main.
flags_target = File.join(work, 'host/lib/libmruby.flags.mak')
output, status = Open3.capture2e(build_env, 'rake', '-m', '-j8', 'all', flags_target, chdir: File.join(root, '3rd/mruby'))
File.write(File.join(work, 'build.log'), output)
abort output.lines.last(35).join unless status.success?
expected, expected_status = Open3.capture2e(File.join(reference, 'bin/mruby'), program)
File.write(File.join(work, 'interpreted.log'), expected)
abort "interpreted fixture failed:\n#{expected}" unless expected_status.success?
main = File.join(work, 'native_main.cxx')
File.write(main, <<~'CPP')
  #include <mruby.h>
  int main() {
    mrb_state* mrb = mrb_open();
    if (!mrb) return 1;
    if (mrb->exc) { mrb_print_error(mrb); mrb_close(mrb); return 1; }
    mrb_close(mrb);
    return 0;
  }
CPP
host = File.join(work, 'host')
binary = File.join(work, 'native-main')
flags = %w[-std=c++17 -fexceptions] + Bc2cppFixtureRuntime.library_defines(host)
abort 'native-only test host failed to link' unless Bc2cppCxx.system(*flags, "-I#{host}/include", "-I#{root}/3rd/mruby/include",
                                                                  main, "#{host}/lib/libmruby.a", '-lm', '-o', binary)
symbols, symbol_status = Open3.capture2e('nm', '-g', '--defined-only', "#{host}/lib/libmruby.a")
abort symbols unless symbol_status.success?
forbidden = symbols.lines.grep(/\b(?:mrb_(?:parse_\w+|generate_code|load_(?:n?string\w*|file\w*|irep\w*|exec)|read_irep\w*|dump_irep\w*|codedump\w*))$/)
abort "native-only archive retains compiler/bytecode APIs:\n#{forbidden.join}" unless forbidden.empty?
preprocessed = File.read(File.join(host, 'src/vm-cxx.pi'))
abort 'native-only VM retains bytecode decoding' if preprocessed.match?(/\boptable\b|L_OP_EXT[123]_BODY|pc\s*=\s*ci->pc\s*\+\s*1/)
puts '  native-only archive omits source compilation, binary loaders/dumpers and instruction decoding'
[false, true].each do |optimized|
  env = { 'NATIVE_PROBE_COMPILED' => optimized ? '1' : nil }
  actual, status = Open3.capture2e(env, binary)
  File.write(File.join(work, optimized ? 'optimized.log' : 'native.log'), actual)
  abort "native fixture failed:\n#{actual}" unless status.success?
  audit = actual[/^AUDIT \[(\d+), (\d+)\]$/, 0]
  abort 'native execution audit is missing' unless audit
  abort "unexpected audit: #{audit}" unless audit.match?(/\[[1-9]\d*, 0\]/)
  abort 'compiled wrapper registration was not exercised' unless actual.include?("REGISTRATION #{optimized}\n")
  %w[root fiber].each do |context|
    required = "NATIVE_ONLY #{context}: raised RuntimeError: bytecode execution in a native-only runtime\n"
    abort "bytecode was not rejected in #{context}: #{actual}" unless actual.include?(required)
  end
  actual = actual.lines.reject { |line| line.start_with?('AUDIT ', 'REGISTRATION ', 'NATIVE_ONLY ') }.join
  unless actual == expected
    expected.lines.zip(actual.lines).reject { |a, b| a == b }.first(12).each { |a, b| warn "interpreted: #{a}native: #{b}" }
    abort "native Fiber behavior differs from interpreted mruby (optimized=#{optimized})"
  end
  abort 'native fixture did not finish' unless actual.lines.last == "end\n"

  puts "  optimized=#{optimized}: #{audit}; all results match interpreted mruby"
end
files = Dir[File.join(work, 'host/{mrblib,mrbgems}/**/*.c')]
abort 'no generated programs to audit' if files.empty?
retained = files.select { |file| File.read(file).match?(/^static const mrb_code \w+_iseq_/) }
abort "retained instruction arrays: #{retained.join(', ')}" unless retained.empty?
puts "  #{scenarios.size * 2} iterator scenarios plus nested calls, ensure, closures, catch/throw and Enumerator match"
puts '  no bytecode instruction executed in root or Fiber contexts; injected bytecode rejected in both'
strict_config = File.read(config)
[false, true].each do |native_only|
  File.write(config, strict_config.sub('native_only: true', "native_only: #{native_only}"))
  output, status = Open3.capture2e(build_env, 'rake', '-m', '-j8', 'all', chdir: File.join(root, '3rd/mruby'))
  File.write(File.join(work, "mode-#{native_only}.log"), output)
  abort "runtime mode rebuild failed:\n#{output.lines.last(35).join}" unless status.success?
  symbols, status = Open3.capture2e('nm', '-g', '--defined-only', "#{host}/lib/libmruby.a")
  abort symbols unless status.success?
  loaders = symbols.match?(/\bT mrb_load_irep$/)
  abort "stale binary loader objects after native_only=#{native_only}" unless loaders == !native_only
  decoded = File.read(File.join(host, 'src/vm-cxx.pi')).include?('L_OP_EXT1_BODY:')
  abort "stale instruction decoder after native_only=#{native_only}" unless decoded == !native_only
end
puts '  switching mixed/native-only modes rebuilds loaders and decoding without stale archive members'
begin
  File.write(config, strict_config.sub("conf.gem core: 'mruby-method'", "conf.gem core: 'mruby-method'\n  conf.gem core: 'mruby-compiler'"))
  output, status = Open3.capture2e(build_env, 'rake', '-P', chdir: File.join(root, '3rd/mruby'))
  abort 'a native-only runtime accepted the source compiler' if status.success? || !output.include?('native-only runtime cannot include mruby-compiler')
ensure
  File.write(config, strict_config)
end
puts '  native-only configuration rejects a source compiler gem'
puts 'bc2cpp native Fiber check: PASS'
