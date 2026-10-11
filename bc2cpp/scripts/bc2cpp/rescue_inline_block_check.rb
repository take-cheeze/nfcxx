#!/usr/bin/env ruby
# encoding: UTF-8
# frozen_string_literal: true

# RESCUE_TRY_INLINE and EACH_SPREAD (docs/adr/0376, continuing RESCUE_INLINE_BLOCK_FIX of #1909).
#
# A block loop whose BLOCK/SENDB sits inside a `rescue`-protected range is compiled into the extracted try
# body (emit_rescue_try_body), never into the method's own function: registered there it would be emitted
# after the rescue glue, on the path only an exception reaches, and run the block a second time with a
# receiver register that holds the exception (kk1.12's New Game died with `TypeError: bc2cpp: expected
# Array receiver for inlined #each` that way). Since ADR 0376 the try body runs the same inliner passes
# over the range, with the receiver proof and the arity gate taken from the whole method. This check holds
# the conditions that makes sound:
#
#   generated code (needs only a host mrbc)
#     - the loop is inlined in the try function and absent from the method function, its labels and block
#       registers with it; an unprotected loop is unchanged;
#     - a block that returns from the method (RETURN_BLK, at any depth) is not inlined into a try function,
#       where a C++ `return` would hand the range its value; a `next`, a `break` and a raise are;
#     - writes to a captured local go through the `bc2cpp_ref_r` alias of the outer register;
#     - a 2..8 parameter `each` block spreads one Array element over its parameters, with the element
#       hint off; BC2CPP_EACH_SPREAD=0 and BC2CPP_RESCUE_INLINE_BLOCKS=0 each restore the call;
#   behaviour (needs a full-core libmruby, see Bc2cppFixtureRuntime.full_or_build)
#     - the compiled methods answer what the interpreted ones do: a raise inside the block reaching the
#       same handler, a handler that continues, an unmatched raise unwinding through a caller's ensure,
#       next/break/return, captured locals written, short, long, non-Array and #to_ary rows, hashes, nesting.
#
# scripts/bc2cpp/rescue_inline_block_mutation_check.rb weakens each of those conditions in turn.
#
# Usage: [MRBC=path/to/mrbc BC2CPP_MRUBY_FULL=dir] ruby scripts/bc2cpp/rescue_inline_block_check.rb

require 'tmpdir'
require_relative 'fixture_runtime'
require ENV.fetch('BC2CPP_TOOL') { File.expand_path('../../tools/bc2cpp/bc2cpp.rb', __dir__) }

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

# A row mix for the spread: exact, short, empty, long, non-Array, nil, nested and a #to_ary object.
ROWS = '[[1, 2, 3, 4, 5], [6, 7], [8], [], 9, nil, [[10, 11], 12, 13, 14, 15, 16], "s", RiPair.new]'

SRC = <<~RUBY
  class RiPair
    def to_ary; [1, 2]; end
  end

  class RiFx
    # A raise inside the block reaches the method's own handler, which sees the locals written in the range.
    def whole_each(n)
      log = []
      [1, 2, 3].each { |x| log << x; raise ArgumentError, "at \#{x}" if x == n }
      log << :done
      log
    rescue ArgumentError => e
      [log, e.message]
    end

    # The rescue continues and the method goes on.
    def continue_after(n)
      acc = []
      begin
        [1, 2, 3].each { |x| raise "boom \#{x}" if x == n; acc << x }
      rescue RuntimeError => e
        acc << e.message
      end
      acc << :after
      acc
    end

    def next_in_block
      acc = []
      begin
        [1, 2, 3, 4].each { |x| next if x.even?; acc << x }
        raise "tail"
      rescue RuntimeError
        acc << :r
      end
      acc
    end

    def break_in_block
      r = begin
        [1, 2, 3].each { |x| break x * 7 if x == 2 }
      rescue RuntimeError
        :bad
      end
      r
    end

    # Locals written by the loop body and read by the handler and after the range.
    def captured_write
      sum = 0
      last = nil
      begin
        [3, 4, 5].each { |x| sum += x; last = x }
        raise "after"
      rescue RuntimeError
        sum += 1000
      end
      [sum, last]
    end

    def captured_write_raise(n)
      sum = 0
      last = nil
      begin
        [3, 4, 5].each { |x| sum += x; last = x; raise "stop" if x == n }
      rescue RuntimeError
        sum += 1000
      end
      [sum, last]
    end

    # Arity 4 and 5 over rows of every shape.
    def spread4
      out = []
      begin
        #{ROWS}.each { |a, b, c, d| out << [a.is_a?(RiPair) ? :pair : a, b, c, d] }
        raise "end"
      rescue RuntimeError
        out << :rescued
      end
      out
    end

    def spread5
      out = []
      begin
        #{ROWS}.each { |a, b, c, d, e| out << [a.is_a?(RiPair) ? :pair : a, b, c, d, e] }
        raise "end"
      rescue RuntimeError
        out << :rescued
      end
      out
    end

    def spread2_whole
      out = []
      #{ROWS}.each { |a, b| out << [a.is_a?(RiPair) ? :pair : a, b] }
      out << :done
      out
    rescue RuntimeError
      out
    end

    def spread_raise(n)
      out = []
      begin
        [[1, 2, 3, 4], [5, 6, 7, 8], [9, 10, 11, 12]].each { |a, b, c, d| raise "row \#{a}" if a == n; out << a + d }
      rescue RuntimeError => e
        out << e.message
      end
      out
    end

    # Writing a parameter writes the copy, not the row.
    def spread_param_write
      rows = [[1, 2, 3, 4], [5, 6, 7, 8]]
      begin
        rows.each { |a, b, c, d| a = 99; d = a + b }
        raise "end"
      rescue RuntimeError
        nil
      end
      rows
    end

    # Past EACH_SPREAD_MAX the call stays.
    def spread_wide
      out = []
      begin
        [[1, 2, 3, 4, 5, 6, 7, 8, 9]].each { |a, b, c, d, e, f, g, h, i| out << i }
      rescue RuntimeError
        out << :r
      end
      out
    end

    def spread_nested
      acc = []
      begin
        [[1, 2, 3, 4], [5, 6]].each { |a, b, c, d| [a, b].each { |v| acc << v } }
        raise "end"
      rescue RuntimeError
        acc << :r
      end
      acc
    end

    def hash_each
      acc = []
      begin
        { 1 => :a, 2 => :b, 3 => :c }.each { |k, v| acc << [k, v]; raise "h" if k == 2 }
      rescue RuntimeError
        acc << :r
      end
      acc
    end

    def times_in_rescue
      acc = []
      begin
        3.times { |i| acc << i; raise "t" if i == 1 }
      rescue RuntimeError
        acc << :r
      end
      acc
    end

    # A block that returns from the method must keep returning from the method.
    def return_in_block
      begin
        [1, 2, 3].each { |x| return x * 10 if x == 2 }
        :none
      rescue RuntimeError
        :rescued
      end
    end

    def return_in_block_whole
      [1, 2, 3].each { |x| return x * 10 if x == 2 }
      :none
    rescue RuntimeError
      :rescued
    end

    def return_in_nested_block
      begin
        [[1, 2], [3, 4]].each { |a, b| [a, b].each { |v| return v if v == 3 } }
        :none
      rescue RuntimeError
        :rescued
      end
    end

    # The handler re-raises: the caller's ensure runs after the handler, as interpreted.
    def reraise(log)
      [1, 2].each { |x| log << x; raise ArgumentError, "bad \#{x}" if x == 2 }
      log << :unreached
    rescue ArgumentError => e
      log << :handler
      raise e
    end

    def caller_ensure(log)
      reraise(log)
    ensure
      log << :ensure
    end

    def unmatched
      [1, 2].each { |x| raise ArgumentError, "bad" if x == 2 }
    rescue TypeError
      :wrong
    end

    def nested_rescue
      begin
        begin
          [1, 2].each { |x| raise TypeError, "t\#{x}" if x == 2 }
        rescue ArgumentError
          :inner
        end
      rescue TypeError => e
        e.message
      end
    end

    def errinfo_after
      begin
        [1].each { |x| raise "x" }
      rescue RuntimeError
        nil
      end
      $!.inspect
    end

    # A loop with a block of its own after the range: the try function must not claim it too.
    def loop_after_rescue
      acc = []
      begin
        [1].each { |x| acc << x }
      rescue RuntimeError
        acc << :r
      end
      [2, 3].each { |y| 2.times { |i| acc << y * i } }
      acc
    end

    # A rescue inside a block body is the block function's own try body: the method's inliners do not run there.
    def rescue_in_block
      [1, 2].map do |s|
        begin
          [s].each { |y| raise "a" }
        rescue RuntimeError
          :r
        end
      end
    end

    def plain
      xs = [1, 2]
      xs.each { |x| x.succ }
      xs
    end

    def plain_spread
      out = []
      [[1, 2, 3, 4], [5]].each { |a, b, c, d| out << [a, b, c, d] }
      out
    end
  end
RUBY

DRIVER = <<~'RUBY'
  fx = RiFx.new
  show = lambda do |name, &blk|
    out = begin
      blk.call.inspect
    rescue Exception => e
      "#{e.class}: #{e.message}"
    end
    puts "#{name}: #{out}"
  end
  [1, 2, 3, 9].each do |n|
    show.call("whole_each(#{n})") { fx.whole_each(n) }
    show.call("continue_after(#{n})") { fx.continue_after(n) }
    show.call("captured_write_raise(#{n})") { fx.captured_write_raise(n) }
  end
  [1, 5, 9, 13].each do |n|
    show.call("spread_raise(#{n})") { fx.spread_raise(n) }
  end
  %i[next_in_block break_in_block captured_write spread4 spread5 spread2_whole spread_param_write spread_nested spread_wide
     hash_each times_in_rescue return_in_block return_in_block_whole return_in_nested_block unmatched nested_rescue
     errinfo_after rescue_in_block loop_after_rescue plain plain_spread].each do |name|
    show.call(name.to_s) { fx.send(name) }
  end
  log = []
  show.call('caller_ensure') { fx.caller_ensure(log) }
  puts "log: #{log.inspect}"
  puts 'end'
RUBY

# A generated function ends with its fell-off-the-end raise (ADR 0262); a bare `}` at column 0 also closes
# an arithmetic fast path inside the body, so the closing brace alone cannot delimit it.
FELL_OFF = /fell off the end of its body"\);\n\}/

def impl_of(code, name)
  code[/^mrb_value RiFx_#{name}_impl\(.*?#{FELL_OFF.source}/m].to_s
end

# Every try function of the method (a method may have several ranges, and a range nested ones), one string.
def tries_of(code, name)
  code.scan(/^static mrb_value RiFx_#{name}_impl_rescue_try(?:_\d+)?(?:_nested(?:_\d+)?)?\(.*?#{FELL_OFF.source}/m).join("\n")
end

unless Bc2cppFixtureRuntime.mrbc && system(Bc2cppFixtureRuntime.mrbc, '--version', out: File::NULL, err: File::NULL)
  puts '  SKIP: no host mrbc (set MRBC); the generated-code and behavioural checks need it'
  exit 0
end

# The generated code of the fixture's methods, in-process (the open world: the proofs the check needs are
# all local to a method), with the given environment switches set around the generation.
def generate_fixture(env = {})
  saved = env.keys.to_h { |k| [k, ENV.fetch(k, nil)] }
  env.each { |k, v| ENV[k] = v }
  Dir.mktmpdir do |dir|
    path = File.join(dir, 'rescue_inline_block.rb')
    File.write(path, SRC)
    ireps, root_label = compile_ireps(path, 'bc2cpp_rescue_inline_block', dir)
    registry = build_registry(ireps, root_label)[0]
    gen = CodeGen.new(ireps, registry, {}, {}, {}, {}, {}, {}, {}, {}, {}, Set.new)
    registry.values.flatten.select { |d| d.owner == 'RiFx' && d.irep }.to_h do |d|
      [d.name, gen.compile_method(d.irep).fetch(:code)]
    end
  end
ensure
  saved&.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
end

codes = generate_fixture

inlined = lambda do |name, marker = 'bc2cpp_each_i_'|
  code = codes.fetch(name)
  try = tries_of(code, name)
  !try.empty? && try.include?(marker) && !try.include?('#error') && !impl_of(code, name).include?(marker)
end

puts '-- loops inside a rescue range are inlined into the try function'
%w[whole_each continue_after next_in_block break_in_block captured_write captured_write_raise].each do |name|
  check.call("#{name}: the #each loop is inlined in the try function and not in the method function", inlined.call(name))
end
check.call('times_in_rescue: the #times loop is inlined in the try function', inlined.call('times_in_rescue', 'bc2cpp_times_i_'))
check.call('hash_each: the Hash#each loop is inlined in the try function', inlined.call('hash_each', 'bc2cpp_heach_i_'))
check.call('an unprotected #each is still inlined in the method function',
           impl_of(codes.fetch('plain'), 'plain').include?('bc2cpp_each_i_'))

puts '-- the loop stays inside the try function'
%w[whole_each continue_after].each do |name|
  code = codes.fetch(name)
  impl = impl_of(code, name)
  try = tries_of(code, name)
  check.call("#{name}: no loop label or block register of the loop in the method function",
             !impl.empty? && !impl.match?(/Lbc2cpp_each|LBLK\d+_|bc2cpp_each_i_/))
  check.call("#{name}: the loop's end label is defined where its goto is", try.scan(/goto (Lbc2cpp_each_\w+);/).flatten.uniq.all? { |l| try.include?("#{l}:;") })
  check.call("#{name}: nothing in the loop leaves the try function through a method-level label",
             try.scan(/goto L(\d+);/).flatten.map(&:to_i).all? { |addr| try.include?("L#{addr}:;") })
end

puts '-- a return from the method is not inlined into a try function'
%w[return_in_block return_in_block_whole return_in_nested_block].each do |name|
  code = codes.fetch(name)
  try = tries_of(code, name)
  check.call("#{name}: no inlined loop in the try function, the call is kept",
             !try.empty? && !try.include?('bc2cpp_each_i_') && !code.include?('#error'))
  check.call("#{name}: the try function returns only at the range's exit",
             try.scan(/^\s*return\b/).size == 1)
end

puts '-- only the range\'s own loops are claimed by the try function'
loop_after = codes.fetch('loop_after_rescue')
check.call('loop_after_rescue: the loop inside the range is inlined in the try function, the one after it in the method function',
           tries_of(loop_after, 'loop_after_rescue').scan('for (mrb_int bc2cpp_each_i_').size == 1 &&
           impl_of(loop_after, 'loop_after_rescue').scan('for (mrb_int bc2cpp_each_i_').size == 1)
defined = loop_after.scan(/^static mrb_value (\w+)\(/).flatten
check.call('loop_after_rescue: no function is defined twice (the loop after the range has one set of nested block functions)',
           !defined.empty? && defined.uniq.size == defined.size && !loop_after.include?('#error'))

puts '-- the passes stay out of a block body\'s own rescue'
check.call('rescue_in_block: the loop inside the block-body rescue stays a call',
           !codes.fetch('rescue_in_block').include?('bc2cpp_each_i_') && !codes.fetch('rescue_in_block').include?('#error'))

puts '-- writes to captured locals go through the outer register'
%w[captured_write captured_write_raise].each do |name|
  try = tries_of(codes.fetch(name), name)
  aliases = try.scan(/mrb_value& (r\d+) = \*ctx->bc2cpp_ref_r\d+;/).flatten
  loop_text = try[/for \(mrb_int bc2cpp_each_i_.*?bc2cpp_each_end_\d+:;/m].to_s
  body_regs = loop_text.scan(/^\s*(r\d+) = /).flatten.uniq
  # The block's own registers sit past the method's; a write below that is a captured local's.
  method_regs = try.scan(/^  mrb_value&? (r\d+)\b/).flatten
  written_outer = body_regs & method_regs
  check.call("#{name}: the loop writes captured locals", !written_outer.empty?)
  check.call("#{name}: every captured local the loop writes is an alias of the outer register",
             written_outer.all? { |r| aliases.include?(r) || !try.match?(/^  mrb_value #{r} = /) })
  check.call("#{name}: the aliases are passed by address from the method function",
             impl_of(codes.fetch(name), name).scan(/ctx\{[^}]*&r\d+/).any? || codes.fetch(name).match?(/ctx\{[^}]*&r\d+/))
end

puts '-- multi-parameter spread'
%w[spread4 spread5 spread_raise spread_param_write spread_nested].each do |name|
  check.call("#{name}: the multi-parameter #each is inlined in the try function with the spread", inlined.call(name) &&
             tries_of(codes.fetch(name), name).include?('bc2cpp_row_'))
end
check.call('spread2_whole: a method-level rescue spreads too', inlined.call('spread2_whole') && tries_of(codes.fetch('spread2_whole'), 'spread2_whole').include?('bc2cpp_row_'))
check.call('spread_wide: nine parameters are past the spread bound, the call is kept',
           !codes.fetch('spread_wide').include?('bc2cpp_row_') && !codes.fetch('spread_wide').include?('bc2cpp_each_i_') &&
           !codes.fetch('spread_wide').include?('#error'))
check.call('plain_spread: an unprotected multi-parameter #each spreads in the method function',
           impl_of(codes.fetch('plain_spread'), 'plain_spread').include?('bc2cpp_row_'))
spread4 = tries_of(codes.fetch('spread4'), 'spread4')
binds = spread4.scan(/RARRAY_LEN\(bc2cpp_row_\d+\) > (\d)\) \{ r(\d+) = RARRAY_PTR\(bc2cpp_row_\d+\)\[(\d)\]/)
check.call('spread4 binds the four row elements, in order, to four consecutive parameters, each behind a length test',
           binds.map(&:first) == %w[0 1 2 3] && binds.map(&:last) == %w[0 1 2 3] &&
           binds.map { |_, reg, _| reg.to_i }.each_cons(2).all? { |a, b| b == a + 1 })
check.call('spread4 takes the row by type only (no #to_ary dispatch)', spread4.include?('mrb_array_p(bc2cpp_row_') && !spread4.include?('to_ary'))
spread5 = tries_of(codes.fetch('spread5'), 'spread5')
check.call('spread5 binds five parameters', spread5.scan(/RARRAY_LEN\(bc2cpp_row_\d+\) > \d\) \{ r\d+ = RARRAY_PTR/).size == 5)
check.call('a non-Array element is the first parameter alone', spread4.match?(/\} else \{\n\s+r\d+ = bc2cpp_row_\d+;\n\s+\}/))

puts '-- the switches'
off = generate_fixture('BC2CPP_RESCUE_INLINE_BLOCKS' => '0')
check.call('BC2CPP_RESCUE_INLINE_BLOCKS=0: no loop is inlined in a try function',
           %w[whole_each continue_after spread4 hash_each times_in_rescue].none? { |n| tries_of(off.fetch(n), n).match?(/bc2cpp_(each|times|hash)/) } &&
           off.values.none? { |c| c.include?('#error') })
check.call('BC2CPP_RESCUE_INLINE_BLOCKS=0: an unprotected loop is still inlined',
           impl_of(off.fetch('plain'), 'plain').include?('bc2cpp_each_i_') && impl_of(off.fetch('plain_spread'), 'plain_spread').include?('bc2cpp_row_'))
no_spread = generate_fixture('BC2CPP_EACH_SPREAD' => '0')
check.call('BC2CPP_EACH_SPREAD=0: no multi-parameter loop is inlined, the call is kept',
           no_spread.values.none? { |c| c.include?('bc2cpp_row_') } && !tries_of(no_spread.fetch('spread4'), 'spread4').include?('bc2cpp_each_i_') &&
           !no_spread.values.any? { |c| c.include?('#error') })
check.call('BC2CPP_EACH_SPREAD=0: single-parameter loops are unchanged',
           inlined.call('whole_each') && no_spread.fetch('whole_each') == codes.fetch('whole_each'))

# ---------------------------------------------------------------------------------------------------------
# Behaviour on real mruby.
if ENV['CC_GENERATED_ONLY'] == '1'
  puts '  SKIP behavioural comparison: CC_GENERATED_ONLY'
else
  build = Bc2cppFixtureRuntime.full_or_build
  if build.nil?
    puts '  SKIP behavioural comparison: needs a full-core libmruby (BC2CPP_MRUBY_FULL, or rake, g++ and 3rd/mruby)'
  else
    puts '-- fixtures on real mruby, interpreted and compiled'
    saved_flags = ENV.fetch('BC2CPP_CXXFLAGS', nil)
    ENV['BC2CPP_CXXFLAGS'] = '-DMRB_USE_BIGINT'
    begin
      Dir.mktmpdir do |dir|
        code, err = Bc2cppFixtureRuntime.generate(SRC, dir)
        names = %w[whole_each continue_after next_in_block break_in_block captured_write captured_write_raise spread4
                   spread5 spread_raise spread_param_write spread_nested hash_each times_in_rescue reraise unmatched
                   nested_rescue errinfo_after]
        check.call('the closed-world build inlines the protected loops too',
                   names.first(8).all? { |n| tries_of(code, n).match?(/bc2cpp_(each|row)_/) })
        check.call('the closed-world build compiles clean', !code.include?('#error'))
        body = <<~CPP
          static int scenario(mrb_state* M) {
            std::fflush(stdout);
            const char* src = R"BCD(#{DRIVER})BCD";
            mrb_load_string(M, src);
            if (M->exc) { mrb_print_error(M); M->exc = nullptr; return 1; }
            return 0;
          }
        CPP
        built, output = Bc2cppFixtureRuntime.run(dir, err, %w[RiFx RiPair], body, build: build, full: true)
        check.call('the fixtures build and run', built)
        sections = Bc2cppFixtureRuntime.sections(output)
        interpreted = sections['interpreted']
        compiled = sections['compiled']
        check.call("the driver prints #{interpreted&.size} lines in both runs",
                   interpreted && interpreted.last == 'end' && compiled&.last == 'end')
        check.call('interpreted and compiled runs print the same', interpreted == compiled)
        if interpreted && compiled
          interpreted.zip(compiled).reject { |a, b| a == b }.first(8).each { |a, b| puts "    interpreted: #{a}\n    compiled:    #{b}" }
          check.call('the raise inside the block reached the handler (whole_each(2) logs 1, 2)',
                     interpreted.include?('whole_each(2): [[1, 2], "at 2"]'))
          check.call('a return in a protected block returned from the method', interpreted.include?('return_in_block: 20'))
          check.call('the handler ran before the caller\'s ensure', interpreted.include?('log: [1, 2, :handler, :ensure]'))
          check.call('a short row leaves the missing parameters nil and a long one drops the extras',
                     interpreted.any? { |l| l.start_with?('spread4:') && l.include?('[6, 7, nil, nil]') && l.include?('[[10, 11], 12, 13, 14]') })
          check.call('an object with #to_ary is not spread', interpreted.any? { |l| l.include?('[:pair, nil, nil, nil]') })
        end
        puts output.lines.last(20).join unless built
      end
    ensure
      saved_flags.nil? ? ENV.delete('BC2CPP_CXXFLAGS') : ENV['BC2CPP_CXXFLAGS'] = saved_flags
    end
  end
end

if failures.empty?
  puts 'bc2cpp rescue inline-block check: PASS'
else
  warn "bc2cpp rescue inline-block check: #{failures.size} failure(s)"
  exit 1
end
