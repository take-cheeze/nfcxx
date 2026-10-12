#!/usr/bin/env ruby
# encoding: UTF-8
# IO_PUTS_MODEL (docs/adr/0284): every explicit-receiver `puts` is one call to the shared
# bc2cpp_io_puts, which runs mruby-io's IO#puts body while the receiver still resolves to
# it and dispatches by name otherwise.
#
# 1. Generated code (MRBC): the shape of a site, and the single fallback in the preamble.
# 2. Behaviour (MRBC, BC2CPP_MRUBY_FULL with mruby-io/-stringio/-eval, g++): compiled runs
#    print and return what the interpreter does, through a normal $stdout, a redirect made
#    by the program, by an interpreted script and by eval, an IO#puts override, a
#    user-defined puts and a literal block.
#
# Usage: [MRBC=path/to/mrbc BC2CPP_MRUBY_FULL=dir|BC2CPP_FULL_BUILD_DIR=dir] ruby scripts/bc2cpp/io_puts_model_check.rb

require 'tmpdir'
require_relative '../../tools/bc2cpp/bc2cpp'
require_relative 'fixture_runtime'

runtime = Bc2cppFixtureRuntime

failures = []
check = lambda do |what, condition|
  if condition
    puts "  ok  #{what}"
  else
    warn "  FAIL #{what}"
    failures << what
  end
end

source_text = <<~'RUBY'
  class PutsCaller
    def one(value); $stdout.puts(value); end
    def none; $stdout.puts; end
    def many(a, b, c); $stderr.puts(a, b, c); end
  end
RUBY

puts '-- generated code'
Dir.mktmpdir do |dir|
  source = File.join(dir, 'puts.rb')
  File.write(source, source_text)
  ireps, root_label = compile_ireps(source, 'bc2cpp_puts_model', dir)
  registry = build_registry(ireps, root_label)[0]
  owners = Set.new(registry.values.flatten.map(&:owner))
  annotations = ElementAnnotations.extract(ireps, registry, owners)
  class_annotations = ClassAnnotations.extract(ireps, registry, owners)
  gen = CodeGen.new(ireps, registry, {}, {}, class_annotations, {}, {}, {}, annotations, {}, {}, Set.new)

  { 'one' => 1, 'none' => 0, 'many' => 3 }.each do |method_name, argc|
    method = registry.fetch(method_name).find { |md| md.owner == 'PutsCaller' }
    irep = ireps.fetch(method.irep)
    send_insn = irep.instructions.find { |insn| insn.op.start_with?('SEND') && insn.args.include?(':puts') }
    raise "#{method_name}: no puts SEND" unless send_insn

    code = gen.compile_insn(send_insn, irep, method, irep.instructions.index(send_insn))
    check.call("#{method_name} is one bc2cpp_io_puts call with #{argc} argument(s)",
               code.scan(/bc2cpp_io_puts\(M, r\d+, mrb_intern_lit\(M, "puts"\), #{argc}, /).one?)
    check.call("#{method_name} carries no dispatch or gem #ifdef of its own",
               !code.include?('mrb_funcall') && !code.include?('#ifdef') && !code.include?('mrb_io_puts_direct'))
  end
end

Dir.mktmpdir do |dir|
  code, = runtime.generate(source_text, dir)
  helper = code[/static inline mrb_value bc2cpp_io_puts\(.*?^\}\n/m].to_s
  check.call('the preamble defines the helper once', code.scan('static inline mrb_value bc2cpp_io_puts(').one?)
  check.call('the helper tries the exact IO#puts body first, then dispatches by name',
             helper.include?('#ifdef HAVE_MRUBY_IO_GEM') && helper.index('mrb_io_puts_direct(') &&
               helper.index('bc2cpp_funcall_argv(') && helper.index('mrb_io_puts_direct(') < helper.index('bc2cpp_funcall_argv('))
  check.call('every site names puts through the symbol cache, not through a send of its own',
             code.scan(/bc2cpp_io_puts\(M, r\d+, bc2cpp_sym\(M, \d+\), /).size == 3 &&
               code.scan(/bc2cpp_send\(M, [^;]*\bmrb_intern_lit\(M, "puts"\)/).empty?)
end

full = runtime.full_or_build
if !ENV['MRBC'] || full.nil? || !runtime.compiler?
  puts '  SKIP behavioural comparison: needs MRBC, BC2CPP_MRUBY_FULL (mruby-io, mruby-stringio, mruby-eval) and g++'
else
  puts '-- behaviour against the interpreter'
  fixture = <<~'RUBY'
    class Named
      def to_s; 'named-obj'; end
    end

    class Sink
      def initialize; @last = nil; end
      def last; @last; end
      def puts(*args); @last = args; :sink; end
    end

    class PutsProbe
      def none(io); io.puts; end
      def one(io, v); io.puts(v); end
      def two(io, a, b); io.puts(a, b); end
      def three(io, a, b, c); io.puts(a, b, c); end
      def blocked(io, v); io.puts(v) { :block }; end
      def out0; $stdout.puts; end
      def out1(v); $stdout.puts(v); end
      def out_frozen; $stdout.puts('frozen text'.freeze); end
      def err1(v); $stderr.puts(v); end

      def swap_stdout(v)
        saved = $stdout
        $stdout = StringIO.new
        $stdout.puts(v)
        text = $stdout.string
        $stdout = saved
        text
      end

      def swap_stderr(v)
        saved = $stderr
        $stderr = StringIO.new
        $stderr.puts(v, v)
        text = $stderr.string
        $stderr = saved
        text
      end

      def eval_swap(v)
        saved = $stdout
        $eval_target = StringIO.new
        eval('$stdout = $eval_target')
        $stdout.puts(v)
        text = $stdout.string
        $stdout = saved
        text
      end

      def override_io_puts
        IO.class_eval do
          def puts(*args)
            $stderr.write("io-override #{args.inspect}\n")
            :overridden
          end
        end
      end
    end
  RUBY

  Dir.mktmpdir do |dir|
    # eval is only in an open world; a closed one proves it undefined (ADR 0210).
    code, err = runtime.generate(fixture, dir, closed: false)
    File.write(File.join(dir, 'fixture_gen.cpp'), "#define HAVE_MRUBY_IO_GEM 1\n#{code}")
    body = <<~'CPP'
      static mrb_value str(mrb_state* M, const char* s) { return mrb_str_new_cstr(M, s); }
      static mrb_value eval_rb(mrb_state* M, const char* src) {
        mrb_value r = mrb_load_string(M, src);
        if (M->exc) { show_exc(M, "script"); return mrb_nil_value(); }
        return r;
      }
      static int scenario(mrb_state* M) {
        setvbuf(stdout, nullptr, _IONBF, 0);
        mrb_value p = mrb_obj_new(M, mrb_class_get(M, "PutsProbe"), 0, nullptr);
        mrb_value out = mrb_gv_get(M, mrb_intern_lit(M, "$stdout"));
        mrb_value err = mrb_gv_get(M, mrb_intern_lit(M, "$stderr"));
        mrb_value a1[1];
        a1[0] = str(M, "plain"); call(M, "out plain", p, "out1", 1, a1);
        a1[0] = str(M, "has newline\n"); call(M, "out newline", p, "out1", 1, a1);
        a1[0] = mrb_nil_value(); call(M, "out nil", p, "out1", 1, a1);
        a1[0] = mrb_symbol_value(mrb_intern_lit(M, "sym")); call(M, "out symbol", p, "out1", 1, a1);
        a1[0] = mrb_fixnum_value(42); call(M, "out integer", p, "out1", 1, a1);
        a1[0] = eval_rb(M, "[1, [2, [nil, 'x']], :y]"); call(M, "out nested array", p, "out1", 1, a1);
        a1[0] = eval_rb(M, "[]"); call(M, "out empty array", p, "out1", 1, a1);
        a1[0] = eval_rb(M, "Named.new"); call(M, "out to_s object", p, "out1", 1, a1);
        a1[0] = eval_rb(M, "'literal'.freeze"); call(M, "out frozen", p, "out1", 1, a1);
        call(M, "out frozen literal", p, "out_frozen");
        call(M, "out none", p, "out0");
        a1[0] = str(M, "to stderr"); call(M, "err one", p, "err1", 1, a1);
        mrb_value two_out[3] = { out, str(M, "first"), str(M, "second") };
        call(M, "two on stdout", p, "two", 3, two_out);
        mrb_value three_err[4] = { err, str(M, "x"), str(M, "y"), mrb_nil_value() };
        call(M, "three on stderr", p, "three", 4, three_err);
        call(M, "none on stdout", p, "none", 1, &out);

        // A user-defined puts and a literal block.
        mrb_value sink = eval_rb(M, "Sink.new");
        mrb_value one_sink[2] = { sink, str(M, "to sink") };
        call(M, "one on sink", p, "one", 2, one_sink);
        mrb_value two_sink[3] = { sink, mrb_fixnum_value(1), eval_rb(M, "[2, 3]") };
        call(M, "two on sink", p, "two", 3, two_sink);
        call(M, "none on sink", p, "none", 1, &sink);
        mrb_value blocked_sink[2] = { sink, str(M, "blocked") };
        call(M, "blocked on sink", p, "blocked", 2, blocked_sink);
        mrb_value blocked_out[2] = { out, str(M, "blocked out") };
        call(M, "blocked on stdout", p, "blocked", 2, blocked_out);
        call(M, "sink last", sink, "last");

        // The program reassigns $stdout/$stderr itself, and eval does.
        a1[0] = str(M, "redirected"); call(M, "swap stdout", p, "swap_stdout", 1, a1);
        a1[0] = str(M, "twice"); call(M, "swap stderr", p, "swap_stderr", 1, a1);
        a1[0] = str(M, "from eval"); call(M, "eval swap", p, "eval_swap", 1, a1);
        a1[0] = str(M, "back on stdout"); call(M, "stdout restored", p, "out1", 1, a1);

        // An interpreted script reassigns $stdout between compiled calls.
        eval_rb(M, "$stdout = StringIO.new");
        a1[0] = str(M, "captured by script"); call(M, "out after script swap", p, "out1", 1, a1);
        call(M, "out none after script swap", p, "out0");
        show(M, "captured", eval_rb(M, "s = $stdout.string; $stdout = STDOUT; s"));
        a1[0] = str(M, "stdout again"); call(M, "out after script restore", p, "out1", 1, a1);

        // A Ruby IO#puts takes over from the C body.
        call(M, "override", p, "override_io_puts");
        a1[0] = str(M, "after override"); call(M, "out after override", p, "out1", 1, a1);
        call(M, "err after override", p, "err1", 1, a1);
        call(M, "none after override", p, "out0");
        call(M, "two after override", p, "two", 3, two_out);
        return 0;
      }
    CPP
    built, output = runtime.run(dir, err, %w[PutsProbe Sink Named], body, build: full, full: true)
    check.call('the fixture compiles and runs against the patched mruby-io', built)
    puts output unless built
    if built
      puts output if ENV['BC2CPP_CHECK_VERBOSE']
      sections = runtime.sections(output)
      interpreted = sections.fetch('interpreted', [])
      compiled = sections.fetch('compiled', [])
      plain = ->(lines) { lines.reject { |l| l.start_with?('  dispatches=') } }
      check.call('the interpreter printed something to compare', interpreted.size > 30)
      check.call('compiled output and results equal the interpreter, line for line',
                 plain.call(interpreted) == plain.call(compiled))
      check.call('output reaches the real $stdout', compiled.include?('named-obj') && compiled.include?('has newline'))
      check.call('a redirect made by the program is honoured', compiled.include?('swap stdout => "redirected\n"'))
      check.call('a redirect made by eval is honoured', compiled.include?('eval swap => "from eval\n"'))
      check.call('a redirect made by an interpreted script is honoured',
                 compiled.include?('captured => "captured by script\n\n"') && !compiled.include?('captured by script'))
      check.call('the IO#puts override wins over the C body',
                 compiled.include?('io-override ["after override"]') && compiled.include?('out after override => :overridden'))
      dispatches = lambda do |label|
        i = compiled.index { |l| l.start_with?("#{label} =>") }
        i && compiled[i + 1].to_s[/dispatches=(\d+)/, 1]&.to_i
      end
      check.call('a plain $stdout.puts makes no dispatch', dispatches.call('out plain') == 0)
      check.call('a plain $stderr.puts makes no dispatch', dispatches.call('err one') == 0)
      check.call('a user-defined puts is reached by exactly one shared dispatch', dispatches.call('one on sink') == 1 && dispatches.call('none on sink') == 1)
      check.call('a call after the override falls back to dispatch', dispatches.call('out after override').to_i >= 1)
    end
  end
end

if failures.empty?
  puts 'bc2cpp IO#puts model check: PASS'
else
  warn "bc2cpp IO#puts model check: #{failures.size} failure(s)"
  exit 1
end
