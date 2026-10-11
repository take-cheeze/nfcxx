#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative 'fixture_runtime'
require ENV.fetch('BC2CPP_TOOL') { File.expand_path('../../tools/bc2cpp/bc2cpp.rb', __dir__) }

SOURCE = <<~'SOURCE'
  class EwCallback
    def size; Fiber.yield(:size_callback); 7; end
    def inspect; Fiber.yield(:inspect_callback); 'callback'; end
    def rewind; Fiber.yield(:rewind_callback); self; end
    def each; yield 1; end
  end
  class EwSubclass < Enumerator
    def next; :overridden; end
  end
  class EwFixture
    def root
      e = [1, 2].each
      [e.size, e.inspect, e.peek, e.peek_values, e.next, e.next,
       e.rewind.equal?(e), e.next]
    end
    def feed
      e = Enumerator.new { |y| value = y.yield(:first); y << value }
      first = e.next
      e.feed(17)
      [first, e.peek, e.peek_values, e.next]
    end
    def stop
      e = [1].each
      e.next
      begin
        e.next
      rescue StopIteration => error
        [error.class.to_s, error.result]
      end
    end
    def fiber
      f = Fiber.new { Fiber.yield(root); feed }
      [f.resume, f.resume, f.alive?]
    end
    def callbacks
      e = Enumerator.new(EwCallback.new)
      f = Fiber.new { [e.size, e.inspect, e.rewind.equal?(e)] }
      [f.resume, f.resume, f.resume, f.resume, f.alive?]
    end
    def subclass; EwSubclass.new([1], :each).next; end
    def gc
      total = 0
      100.times do |index|
        e = [index].each
        e.peek
        GC.start
        total += Fiber.new { e.next }.resume
      end
      total
    end
    def errors
      e = [1].each
      out = []
      begin; e.next(1); rescue ArgumentError; out << :next_arity; end
      begin; e.feed; rescue ArgumentError; out << :feed_arity; end
      begin; e.feed(1); e.feed(2); rescue TypeError; out << :duplicate_feed; end
      out
    end
  end
SOURCE
WRAPPERS = %w[inspect size rewind feed next peek peek_values].freeze
failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end
runtime = Bc2cppFixtureRuntime
if ENV['MRBC']
  gate_cases = [
    ['plain wrapper', 'def inspect; :ok; end', true],
    ['wrapper with block', 'def inspect; [1].each { |x| x }; end', false],
    ['wrapper with lambda', 'def inspect; -> { 1 }; end', false],
    ['wrapper naming Fiber', 'def inspect; Fiber.current; end', false],
    ['unlisted wrapper', 'def other_wrapper; :ok; end', false],
    ['wrong source', 'def inspect; :ok; end', false]
  ]
  gate_cases.each do |name, definition, admitted|
    Dir.mktmpdir('enumerator-gate') do |dir|
      relative = name == 'wrong source' ? '3rd/mruby/mrblib/other.rb' : '3rd/mruby/mrbgems/mruby-enumerator/mrblib/enumerator.rb'
      path = File.join(dir, relative)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "class Enumerator; #{definition}; end")
      ireps, label = compile_ireps([path], 'gate', dir)
      registry, = build_registry(ireps, label)
      method = registry.values.flatten.find(&:irep)
      expected = admitted && ENV['BC2CPP_ENUMERATOR_WRAPPERS'] != '0'
      check.call("#{name}: eligibility gate", CoreMethods.enumerator_wrapper?(method, ireps) == expected)
    end
  end
  Dir.mktmpdir('enumerator-wrappers') do |dir|
    code, err = runtime.generate(SOURCE, dir, core: true, only_owners: ['Enumerator'])
    FileUtils.cp_r(dir, ENV['BC2CPP_KEEP_DIR'], remove_destination: true) if ENV['BC2CPP_KEEP_DIR']
    entries = err.split('== compiled entry points ==', 2)[1].to_s.split("\n== ", 2)[0]
    enabled = ENV['BC2CPP_ENUMERATOR_WRAPPERS'] != '0'
    WRAPPERS.each do |name|
      emitted = entries.include?("(Enumerator##{name},")
      check.call("#{name}: wrapper eligibility", emitted == enabled)
      next unless enabled

      check.call("#{name}: unconditional root guard",
                 code.match?(/static mrb_value Enumerator_#{name}\(mrb_state\* M, mrb_value self\) \{\n  if \(mrb_unlikely\(M->c != M->root_c\)\) return bc2cpp_core_interpreted/))
      literal = Regexp.escape('"' + name.bytes.map { |byte| format('\\x%02x', byte) }.join + '"')
      check.call("#{name}: saved bytecode", code.match?(/bc2cpp_core_save_interpreted\(M, \w+, false, #{literal}, \d+\)/))
      check.call("#{name}: hidden definition", err.include?("  HIDDEN Enumerator##{name}\n"))
      check.call("#{name}: guarded body has no direct callers", code.scan(/(?<![\w$])Enumerator_#{name}_impl\(/).size == 3)
    end
    %w[each initialize initialize_copy with_index with_object next_values __enumerator_block_call].each do |name|
      check.call("#{name}: complex Enumerator body stays interpreted", !entries.include?("(Enumerator##{name},"))
    end
    unless ENV['EW_GENERATED_ONLY'] == '1'
      build = runtime.full_or_build
      if build
        harness = <<~CPP
          static int scenario(mrb_state* M) {
            if (compiled) bc2cpp_register_owner_methods(M);
            if (compiled) {
              for (const char* name : {"inspect", "size", "rewind", "feed", "next", "peek", "peek_values"}) {
                mrb_method_t method = mrb_method_search(M, mrb_class_get(M, "Enumerator"), mrb_intern_cstr(M, name));
                if (MRB_METHOD_CFUNC_P(method) != #{enabled ? 'true' : 'false'}) {
                  std::fprintf(stderr, "wrong wrapper registration: %s\\n", name);
                  return 3;
                }
              }
            }
            mrb_value fixture = mrb_obj_new(M, mrb_class_get(M, "EwFixture"), 0, nullptr);
            for (const char* name : {"root", "feed", "stop", "fiber", "callbacks", "subclass", "gc", "errors"}) {
              call(M, name, fixture, name);
            }
            return 0;
          }
        CPP
        built, output = runtime.run(dir, err, [], harness, build: build, full: true)
        sections = runtime.sections(output).transform_values { |lines| lines.reject { |line| line.start_with?('  dispatches=') } }
        check.call('wrappers match the interpreter including yielding callbacks and GC',
                   built && sections['compiled'] == sections['interpreted'] &&
                   sections['compiled'].any? { |line| line == 'gc => 4950' } &&
                   sections['compiled'].any? { |line| line.include?('callbacks => [:size_callback, :inspect_callback, :rewind_callback') })
        warn output unless built && sections['compiled'] == sections['interpreted']
      else
        puts '-- SKIP runtime parity: no full-core build'
      end
    end
  end
else
  puts '-- SKIP generated code: set MRBC'
end
abort "FAILED: #{failures.join(', ')}" unless failures.empty?
puts 'bc2cpp Enumerator wrappers check: PASS'
