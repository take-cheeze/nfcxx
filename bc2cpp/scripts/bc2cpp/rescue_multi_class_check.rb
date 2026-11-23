#!/usr/bin/env ruby
# frozen_string_literal: true

# RESCUE_MULTI_CLASS (recognize_rescue_class_handler): a clause naming several classes (`rescue A, B => e`) tests each
# class in turn and jumps to its one handler; the clause's `JMP next` follows only its last class. A whole-method
# rescue, a `begin ... end` value and a chain mixing single- and multi-class clauses compile, and each matches, misses
# (re-raises) and binds the exception as the interpreter does. The behaviour part needs BC2CPP_MRUBY_FULL, or rake and a
# C++ compiler.
# RESCUE_CTX_PRUNE (prune_rescue_ctx): RcShapes' try bodies leave arguments, saved registers and aliased locals unread,
# so their Ctx loses those fields; every shape (nested regions, a local written before the raise, `$!` in and after a
# handler, a block's rescue over upvars, retry, ensure on return/break) still behaves as interpreted.
ENV['BC2CPP_SIG_DIRS'] = ''

require 'tmpdir'
require_relative 'check_support'
require_relative 'fixture_runtime'

suite = FixtureCheck.new('rescue_multi_class_check')
suite.require_mrbc!

SOURCE = <<~RUBY
  class RmParse
    # Raises by kind, so every exception class is the program's own choice.
    def conv(x)
      case x
      when Integer then x
      when nil then raise TypeError, 'nil'
      when :index then raise IndexError, 'index'
      when :key then raise KeyError, 'key'
      else raise ArgumentError, 'bad'
      end
    end

    def parse(x)
      conv(x)
    rescue ArgumentError, TypeError => e
      [:bad, e.class]
    end

    def parse_value(x)
      n = begin
        conv(x)
      rescue TypeError, ArgumentError
        nil
      end
      [n]
    end

    def parse_chain(x)
      conv(x)
    rescue KeyError
      :key
    rescue TypeError, IndexError => e
      [:type_or_index, e.class]
    end

    def missed(x)
      conv(x)
    rescue TypeError, IndexError
      :never
    end

    def run
      [parse(12), parse('zz'), parse(nil), parse_value(7), parse_value('q'), parse_value(nil),
       parse_chain(:key), parse_chain(:index), parse_chain(nil), parse_chain(2),
       begin
         missed('zz')
       rescue ArgumentError => e
         [:reraised, e.class]
       end]
    end
  end

  class RcShapes
    def boom(x)
      raise ArgumentError, "boom \#{x}" if x.nil? || x == :boom
      x
    end

    # The try body reads only self and `a`: `b` and `c` stay out of its Ctx.
    def unused_args(a, b, c)
      boom(a)
    rescue ArgumentError
      [:fallback, b, c]
    end

    # Entered after other code, so every register is a saved field; the body reads one of them.
    def saved_regs(a, b)
      t = a.to_s * 2
      u = [b, t]
      v = begin
        boom(b)
      rescue ArgumentError => e
        e.message
      end
      [t, u, v]
    end

    # `w` is written inside the range before the raise, and read after it on both paths.
    def partial_write(x)
      w = nil
      begin
        w = "pre \#{x}"
        boom(x)
        w = "post \#{x}"
      rescue ArgumentError
        GC.start
        w = "\#{w} rescued"
      end
      GC.start
      w
    end

    # A written local nothing reads afterwards.
    def dead_write(x)
      begin
        d = boom(x)
        d.to_s
      rescue ArgumentError
        :dead
      end
    end

    def nested(x, y)
      outer = begin
        inner = begin
          boom(x)
        rescue ArgumentError
          :inner_fallback
        end
        [inner, boom(y)]
      rescue ArgumentError => e
        [:outer, e.message]
      end
      [outer, x]
    end

    # `$!` inside the handler, after the begin/end, and in the caller once the method returned.
    def errinfo_in
      begin
        boom(:boom)
      rescue ArgumentError
        m = $!.message
      end
      [m, $!]
    end

    def errinfo_after
      r = errinfo_in
      [r, $!]
    end

    def mismatch(x)
      boom(x)
    rescue TypeError
      :never
    end

    def block_rescue(xs, bias)
      acc = []
      xs.each do |x|
        acc << begin
          boom(x)
        rescue ArgumentError
          bias
        end
      end
      acc
    end

    def retried(limit)
      tries = 0
      begin
        tries += 1
        boom(tries < limit ? :boom : tries)
      rescue ArgumentError
        retry
      end
    end

    def ensure_return(xs)
      log = []
      xs.each do |x|
        begin
          return [x, log] if x == 2
        ensure
          log << x
        end
      end
      [:none, log]
    end

    def ensure_break(xs)
      log = []
      r = xs.each do |x|
        begin
          break x * 10 if x == 2
        ensure
          log << x
        end
      end
      [r, log]
    end

    def run
      [unused_args(1, 2, 3), unused_args(nil, 2, 3), saved_regs(4, 5), saved_regs(4, nil),
       partial_write(1), partial_write(:boom), dead_write(3), dead_write(nil),
       nested(1, 2), nested(nil, 2), nested(1, nil), nested(nil, nil),
       errinfo_after, $!, block_rescue([1, nil, 3], :b), retried(3),
       ensure_return([1, 2, 3]), ensure_return([5]), ensure_break([1, 2, 3]),
       begin
         mismatch(nil)
       rescue ArgumentError => e
         [:reraised, e.message, $!.equal?(e)]
       end, $!]
    end
  end
RUBY

OWNERS = %w[RmParse RcShapes].freeze

def with_env(vars)
  saved = vars.to_h { |key, _| [key, ENV.fetch(key, nil)] }
  vars.each { |key, value| ENV[key] = value }
  yield
ensure
  saved.each { |key, value| ENV[key] = value }
end

def compiled?(code, name)
  code.match?(/^mrb_value RmParse_#{name}_impl\(mrb_state\* M/)
end

Dir.mktmpdir('bc2cpp-rescue-multi-class') do |dir|
  code, err = Bc2cppFixtureRuntime.generate(SOURCE, dir, core: true, only_owners: OWNERS)
  missing = %w[parse parse_value parse_chain missed].reject { |name| compiled?(code, name) }
  suite.check("multi-class rescue clauses compile (missing: #{missing.join(', ')})", missing.empty?)
  shapes = %w[unused_args saved_regs partial_write dead_write nested errinfo_in mismatch]
  missing = shapes.reject { |name| code.match?(/^mrb_value RcShapes_#{name}_impl\(/) }
  suite.check("the RcShapes rescue shapes compile (missing: #{missing.join(', ')})", missing.empty?)
  ctx_fields = lambda do |text|
    text.scan(/^struct (RcShapes_\w+_rescue_try\w*)_Ctx \{ (.*?)\};$/).to_h { |name, body| [name, body.scan(';').size] }
  end
  pruned = ctx_fields.call(code)
  unpruned_code, = with_env('BC2CPP_RESCUE_CTX_PRUNE' => '0') do
    Bc2cppFixtureRuntime.generate(SOURCE, File.join(dir, 'unpruned'), core: true, only_owners: OWNERS)
  end
  unpruned = ctx_fields.call(unpruned_code)
  suite.check('RESCUE_CTX_PRUNE keeps every try body and drops fields',
              pruned.keys.sort == unpruned.keys.sort && pruned.all? { |name, n| n <= unpruned[name] } &&
              pruned.values.sum < unpruned.values.sum)
  suite.check('unused_args passes only self and `a` to its try body',
              code.include?('struct RcShapes_unused_args_impl_rescue_try_Ctx { mrb_value self; mrb_value a; };'))

  build = ENV['CC_GENERATED_ONLY'] == '1' ? nil : Bc2cppFixtureRuntime.full_or_build
  if build.nil?
    puts '  SKIP multi-class rescue behaviour: needs a full-core libmruby (BC2CPP_MRUBY_FULL, or rake and g++)'
  else
    scenario = <<~CPP
      static int scenario(mrb_state* M) {
        mrb_value o = mrb_funcall_argv(M, mrb_obj_value(mrb_class_get(M, "RmParse")), mrb_intern_lit(M, "new"), 0, nullptr);
        call(M, "run", o, "run");
        mrb_value bad = mrb_str_new_lit(M, "zz");
        mrb_value key = mrb_symbol_value(mrb_intern_lit(M, "key"));
        call(M, "missed_key", o, "missed", 1, &key);
        call(M, "missed", o, "missed", 1, &bad);
        mrb_value shapes = mrb_funcall_argv(M, mrb_obj_value(mrb_class_get(M, "RcShapes")), mrb_intern_lit(M, "new"), 0,
                                            nullptr);
        call(M, "shapes", shapes, "run");
        mrb_value boom = mrb_symbol_value(mrb_intern_lit(M, "boom"));
        call(M, "shapes_mismatch", shapes, "mismatch", 1, &boom);
        return 0;
      }
    CPP
    built, output = Bc2cppFixtureRuntime.run(dir, err, OWNERS, scenario, build: build, full: true)
    suite.check('fixture builds and runs', built)
    sections = Bc2cppFixtureRuntime.sections(output)
    plain = ->(lines) { lines.to_a.reject { |l| l.start_with?('  dispatches=') } }
    interpreted = plain.call(sections['interpreted'])
    compiled = plain.call(sections['compiled'])
    suite.check('the interpreter matches each class of a clause',
                interpreted.include?('run => [12, [:bad, ArgumentError], [:bad, TypeError], [7], [nil], [nil], :key, ' \
                                     '[:type_or_index, IndexError], [:type_or_index, TypeError], 2, ' \
                                     '[:reraised, ArgumentError]]') &&
                interpreted.include?('missed => raised ArgumentError'))
    suite.check('the interpreter runs every RcShapes shape',
                interpreted.any? { |l| l.start_with?('shapes => [1, [:fallback, 2, 3], ["44", [5, "44"], 5], ') } &&
                interpreted.include?('shapes_mismatch => raised ArgumentError'))
    suite.check('compiled matches interpreted', compiled == interpreted)
  end
end

suite.finish!
