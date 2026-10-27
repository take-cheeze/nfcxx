#!/usr/bin/env ruby
# frozen_string_literal: true

# KERNEL_LOOP_INLINE (tools/bc2cpp/codegen_kernel_loop.rb): `loop do ... end` is inlined as a `for (;;)` under its
# own mrb_jmpbuf. The generated part checks which sites are inlined and that BC2CPP_KERNEL_LOOP=0 keeps the call;
# the runtime part runs every way out of a loop (break with and without a value, next, a method return, a
# StopIteration from `raise` and from Enumerator#next, other errors, nested loops, a break from a block inside the
# loop) interpreted and compiled, and compares the output. Needs MRBC; the runtime part also needs a full-core
# libmruby (BC2CPP_MRUBY_FULL, or rake and a C++ compiler).
ENV['BC2CPP_SIG_DIRS'] = ''

require 'fileutils'
require 'tmpdir'
require_relative 'fixture_runtime'

failures = []
check = lambda do |what, ok|
  puts "  #{ok ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless ok
end

SOURCE = <<~RUBY
  class KlFx
    def initialize(bytes) = (@bytes = bytes)

    def read_ber(s)
      ret = 0
      loop do
        b = s.shift
        raise 'truncated' if b.nil?
        ret = (ret << 7) | (b & 0x7f)
        break if (b & 0x80) == 0
      end
      ret
    end

    def break_value(n)
      i = 0
      loop do
        i += 1
        break i * 10 if i >= n
      end
    end

    def skip_odd(n)
      i = 0
      out = []
      loop do
        i += 1
        break if i > n
        next if i.odd?
        out << i
      end
      out
    end

    def early_return(list)
      loop do
        x = list.shift
        return [:found, x] if x == 3
        break :none if x.nil?
      end
    end

    def stop_raise(n)
      i = 0
      r = loop do
        i += 1
        raise StopIteration if i == n
      end
      [i, r]
    end

    def stop_enum(list)
      e = list.each
      out = []
      r = loop { out << e.next }
      [out, r]
    end

    def other_error(n)
      i = 0
      begin
        loop do
          i += 1
          raise ArgumentError, "at \#{i}" if i == n
        end
      rescue ArgumentError => e
        [:rescued, e.message, i]
      end
    end

    def nested(n)
      out = []
      i = 0
      loop do
        i += 1
        break if i > n
        j = 0
        loop do
          j += 1
          break if j > i
          out << [i, j]
        end
      end
      out
    end

    def inner_block_break(rows)
      found = nil
      loop do
        row = rows.shift
        break if row.nil?
        found = row.each { |v| break v if v > 5 }
        break unless found.is_a?(Array)
      end
      found
    end
  end
RUBY

DRIVER = <<~'RUBY'
  fx = KlFx.new([])
  show = lambda do |label, &blk|
    out = begin
      blk.call.inspect
    rescue Exception => e
      "#{e.class}: #{e.message}"
    end
    puts "#{label}: #{out}"
  end
  show.call('ber one') { fx.read_ber([0x05]) }
  show.call('ber two') { fx.read_ber([0x81, 0x01]) }
  show.call('ber truncated') { fx.read_ber([0x81]) }
  show.call('break value') { fx.break_value(4) }
  show.call('next') { fx.skip_odd(7) }
  show.call('return') { fx.early_return([1, 2, 3, 4]) }
  show.call('break none') { fx.early_return([1, 2]) }
  show.call('stop raise') { fx.stop_raise(3) }
  show.call('stop enum') { fx.stop_enum([1, 2, 3]) }
  show.call('other error') { fx.other_error(2) }
  show.call('nested') { fx.nested(3) }
  show.call('inner break') { fx.inner_block_break([[1, 2], [3, 9, 1], [4]]) }
  show.call('after') { fx.break_value(1) }
  puts 'end'
RUBY

# other_error (a loop inside begin/rescue), nested and inner_block_break (a body whose own block breaks) keep the call;
# they run below as behaviour cases.
INLINED = %w[read_ber break_value skip_odd early_return stop_raise stop_enum].freeze

if ENV['MRBC'].nil?
  puts '  SKIP kernel loop check: set MRBC'
  exit 0
end

body = ->(code, name) { code[/^mrb_value KlFx_#{name}_impl\(mrb_state\* M.*?(?=^(?:static )?mrb_value |\z)/m].to_s }

Dir.mktmpdir('bc2cpp-kernel-loop') do |dir|
  code, err = Bc2cppFixtureRuntime.generate(SOURCE, dir, core: true, only_owners: %w[KlFx])
  INLINED.each do |name|
    check.call("#{name}: the loop is inlined", body.call(code, name).include?('// KERNEL_LOOP_INLINE'))
  end
  check.call('read_ber: no block fallback is left for the loop', !body.call(code, 'read_ber').include?('BLOCK_FALLBACK'))

  off_dir = File.join(dir, 'off')
  FileUtils.mkdir_p(off_dir)
  saved = ENV['BC2CPP_KERNEL_LOOP']
  ENV['BC2CPP_KERNEL_LOOP'] = '0'
  begin
    off, = Bc2cppFixtureRuntime.generate(SOURCE, off_dir, core: true, only_owners: %w[KlFx])
  ensure
    ENV['BC2CPP_KERNEL_LOOP'] = saved
  end
  check.call('BC2CPP_KERNEL_LOOP=0 inlines no loop', !off.include?('// KERNEL_LOOP_INLINE'))

  build = ENV['CC_GENERATED_ONLY'] == '1' ? nil : Bc2cppFixtureRuntime.full_or_build
  if build.nil?
    puts '  SKIP kernel loop behaviour: needs a full-core libmruby (BC2CPP_MRUBY_FULL, or rake, g++ and 3rd/mruby)'
  else
    scenario = <<~CPP
      static int scenario(mrb_state* M) {
        std::fflush(stdout);
        const char* src = R"KLD(#{DRIVER})KLD";
        mrb_load_string(M, src);
        std::fflush(stdout);
        if (M->exc) { mrb_print_error(M); M->exc = nullptr; return 1; }
        return 0;
      }
    CPP
    built, output = Bc2cppFixtureRuntime.run(dir, err, %w[KlFx], scenario, build: build, full: true)
    check.call('fixture builds and runs', built)
    sections = Bc2cppFixtureRuntime.sections(output)
    interpreted = sections['interpreted']
    compiled = sections['compiled']
    check.call('both runs reach the end', interpreted&.last == 'end' && compiled&.last == 'end')
    check.call('interpreted and compiled runs print the same', interpreted == compiled)
    interpreted.to_a.zip(compiled.to_a).reject { |a, b| a == b }.first(10).each do |a, b|
      puts "    interpreted: #{a}\n    compiled:    #{b}"
    end
    check.call('a read_ber result is the number', interpreted.to_a.include?('ber two: 129'))
    puts output.lines.last(30).join unless built && interpreted && compiled
  end
end

if failures.empty?
  puts 'bc2cpp kernel loop check: PASS'
else
  warn "bc2cpp kernel loop check: #{failures.size} failure(s)"
  exit 1
end
