#!/usr/bin/env ruby
# frozen_string_literal: true

# COMPUTED_SEND_EXPANSION: a `__send__(name, ...)` whose name register provably holds one of a finite
# set of Symbols becomes a chain of direct calls (codegen_computed_send.rb, computed_send_names.rb).
# A generated fixture covers each proven shape (constant table, copy, join, hash table, constant
# element) and each refused one (a parameter name, a computed string), then checks the emitted C++:
# every proven site has its expansion and no by-name arm, every refused site keeps its by-name
# send, and BC2CPP_COMPUTED_SEND=0 restores the single computed send. Needs MRBC; without it the
# fixture part prints SKIP.
ENV['BC2CPP_SIG_DIRS'] = ''

require 'open3'
require 'rbconfig'
require 'tmpdir'
require_relative '../../tools/bc2cpp/closed_world_env'
require_relative 'fixture_runtime'

ROOT = File.expand_path('../..', __dir__)
BC2CPP = File.join(ROOT, 'tools/bc2cpp/bc2cpp.rb')

failures = []
check = lambda do |what, ok|
  puts "  #{ok ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless ok
end

# By-name dispatch the expansion must not leave behind in a live line.
BY_NAME = /\bbc2cpp_send\(|\bbc2cpp_owner_call(?:_named)?\(|\bmrb_funcall\w*\(|\bbc2cpp_funcall\w*\(/

FIXTURE = <<~RUBY
  module CsCheck
    TABLE = %i[alpha beta gamma].freeze
    BY_KEY = { 0 => :alpha, 1 => :beta }.freeze
    ELEMENT_ALPHA = :alpha
    ELEMENTS = [ELEMENT_ALPHA, :beta].freeze

    class Box
      def alpha(x) = x + 1
      def beta(x) = x + 2
      def gamma(x) = x + 3

      def table(i, x)
        __send__(TABLE[i], x)
      end

      def copy(i, x)
        name = TABLE[i]
        other = name
        __send__(other, x)
      end

      def join(c, x)
        name = c ? :alpha : :beta
        __send__(name, x)
      end

      def hash_table(k, x)
        __send__(BY_KEY[k], x)
      end

      def constant_element(i, x)
        __send__(ELEMENTS[i], x)
      end

      def from_param(name, x)
        __send__(name, x)
      end

      def computed_string(i, x)
        __send__(TABLE[i] + "", x)
      end
    end

    class Guarded
      NAMES = [:one, :two, :zero]

      def one(x) = x + 1
      def two(x) = x + 2
      def zero = 0

      def via_send(name, x)
        send(name, x)
      end

      def via_dunder(name, x)
        __send__(name, x)
      end

      def via_splat(args)
        send(*args)
      end

      def other_receiver(obj, name, x)
        obj.send(name, x)
      end
    end
  end
RUBY

MRBC_BIN = ENV['MRBC']
puts '  SKIP generated fixture: set MRBC' if MRBC_BIN.nil?
Dir.mktmpdir do |dir|
  src = File.join(dir, 'cs.rb')
  File.write(src, FIXTURE)
  generate = lambda do |switch, extra = {}|
    out_dir = File.join(dir, "out-#{switch}-#{extra.size}-#{extra.keys.join('-')}")
    Dir.mkdir(out_dir)
    env = { 'MRBC' => MRBC_BIN, 'SKIP_UNSUPPORTED' => '1', 'OUT_SYMBOL' => 'cs', 'OUT_DIR' => out_dir,
            'BC2CPP_SELF_REGISTERING' => '1', 'BC2CPP_SIG_DIRS' => '', 'BC2CPP_COMPUTED_SEND' => switch, **extra }
    out, err, status = Open3.capture3(bc2cpp_closed_world_probe_env(env), RbConfig.ruby, BC2CPP, '--annotated', src)
    abort "bc2cpp.rb failed:\n#{err[-3000..]}" unless status.success?
    out
  end
  if MRBC_BIN
    on = generate.call('1')
    off = generate.call('0')
    # The body of one generated method: from its _impl definition to the next top-level definition. A
    # nested block of the body can close at column 0, so a closing brace does not end it.
    body = lambda do |code, name|
      code[/^mrb_value CsCheck__Box_#{name}_impl\(mrb_state\* M.*?(?=^(?:static )?mrb_value |\z)/m].to_s
    end
    # By-name dispatch in the live lines of a body (the notes name the send they replaced, so they are skipped).
    by_name_lines = lambda do |text|
      text.lines.reject { |line| line.lstrip.start_with?('//') }.grep(BY_NAME)
    end
    expanded = ->(name) { body.call(on, name).include?('// COMPUTED_SEND :__send__') }
    by_name = ->(name) { by_name_lines.call(body.call(on, name)).any? }

    %w[table copy join hash_table].each do |name|
      check.call("#{name}: the name is expanded into direct arms", expanded.call(name))
      check.call("#{name}: the expanded method has no by-name send", !by_name.call(name))
    end
    %w[from_param computed_string constant_element].each do |name|
      check.call("#{name}: the unproven name is not expanded and keeps its by-name send",
                 !expanded.call(name) && by_name.call(name))
    end
    guarded_body = ->(code, name) { code[/^mrb_value CsCheck__Guarded_#{name}_impl\(mrb_state\* M.*?(?=^(?:static )?mrb_value |\z)/m].to_s }
    %w[via_send via_dunder].each do |name|
      text = guarded_body.call(on, name)
      check.call("#{name}: an unproven name on self takes the guarded expansion",
                 text.include?('// COMPUTED_SEND_GUARDED'))
      check.call("#{name}: each spelled one-argument name of the class is a direct arm, the zero-argument one is not",
                 text.include?('CsCheck__Guarded_one_impl(M') && text.include?('CsCheck__Guarded_two_impl(M') &&
                 !text.include?('CsCheck__Guarded_zero_impl(M'))
      check.call("#{name}: the guarded expansion keeps the original send for any other value",
                 by_name_lines.call(text).any?)
    end
    splat = guarded_body.call(on, 'via_splat')
    check.call('via_splat: a splat send on self takes the guarded expansion by arity',
               splat.include?('// COMPUTED_SEND_GUARDED :send n=*') && splat.include?('case 0:') && splat.include?('case 1:'))
    check.call('via_splat: every arity of the spelled names is a direct arm',
               %w[one two zero].all? { |name| splat.include?("CsCheck__Guarded_#{name}_impl(M") })
    check.call('via_splat: the guarded splat keeps the original send for any other value', by_name_lines.call(splat).any?)
    check.call('via_splat: SPLAT_SHARED reads the list in place and copies it only for the original send',
               splat.include?('// SPLAT_SHARED') && splat.scan('mrb_ary_splat(').size == 2)
    shared_off = guarded_body.call(generate.call('1', 'BC2CPP_SPLAT_SHARED' => '0'), 'via_splat')
    check.call('BC2CPP_SPLAT_SHARED=0 keeps the ARYCAT copy before the guarded splat',
               !shared_off.include?('// SPLAT_SHARED') && shared_off.include?('// COMPUTED_SEND_GUARDED :send n=*'))
    check.call('other_receiver: a computed send on another receiver is not guarded',
               !guarded_body.call(on, 'other_receiver').include?('// COMPUTED_SEND_GUARDED'))
    guarded_off = generate.call('1', 'BC2CPP_COMPUTED_SEND_GUARDED' => '0')
    check.call('BC2CPP_COMPUTED_SEND_GUARDED=0 emits no guarded expansion',
               guarded_off.lines.none? { |line| line.include?('// COMPUTED_SEND_GUARDED') })
    check.call('the kill switch BC2CPP_COMPUTED_SEND=0 emits no COMPUTED_SEND line',
               off.lines.none? { |line| line.include?('// COMPUTED_SEND') })
    check.call('the kill switch keeps the proven table site as a by-name send',
               by_name_lines.call(body.call(off, 'table')).any?)
  end
end if MRBC_BIN

# COMPUTED_SEND_GUARDED on real mruby: every arm, and every value that must take the original send, behaves as
# the interpreter does.
GUARDED_SRC = <<~RUBY
  class GsFx
    NAMES = %i[one two zero hidden].freeze

    def one(x) = x + 1
    def two(x, y = 10) = x + y
    def zero = :zero
    def keep(*rest) = rest << :kept

    def via_send(name, *rest)
      case rest.size
      when 0 then send(name)
      when 1 then send(name, rest[0])
      else send(name, rest[0], rest[1])
      end
    end

    def via_splat(args)
      send(*args)
    end

    private

    def hidden(x) = [:hidden, x]
  end
RUBY

GUARDED_DRIVER = <<~'RUBY'
  fx = GsFx.new
  show = lambda do |label, &blk|
    out = begin
      blk.call.inspect
    rescue Exception => e
      e.class.to_s
    end
    puts "#{label}: #{out}"
  end
  show.call('send one') { fx.via_send(:one, 1) }
  show.call('send two default') { fx.via_send(:two, 1) }
  show.call('send two both') { fx.via_send(:two, 1, 2) }
  show.call('send zero') { fx.via_send(:zero) }
  show.call('send private') { fx.via_send(:hidden, 3) }
  show.call('send string name') { fx.via_send('one', 4) }
  show.call('send unknown') { fx.via_send(:nope, 1) }
  # No zero-argument method with an argument: the runner registers every compiled method MRB_ARGS_ANY, so the
  # zero-argument wrapper would accept one whichever way the send went.
  show.call('send wrong arity') { fx.via_send(:one, 1, 2) }
  show.call('send non-name') { fx.via_send(5, 1) }
  show.call('splat one') { fx.via_splat([:one, 1]) }
  show.call('splat zero') { fx.via_splat([:zero]) }
  show.call('splat two') { fx.via_splat([:two, 1, 2]) }
  show.call('splat empty') { fx.via_splat([]) }
  show.call('splat wrong arity') { fx.via_splat([:one]) }
  show.call('splat unknown') { fx.via_splat([:nope]) }
  show.call('splat objects') { fx.via_splat([:two, 'a', 'b']) }
  show.call('splat rest') { fx.via_splat([:keep, 1, 2]) }
  list = [:keep, 3]
  show.call('splat list kept') { [fx.via_splat(list), list] }
  show.call('splat private') { fx.via_splat([:hidden, 4]) }
  show.call('splat long') { fx.via_splat([:keep, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10]) }
  puts 'end'
RUBY

if MRBC_BIN && ENV['CC_GENERATED_ONLY'] != '1'
  build = Bc2cppFixtureRuntime.full_or_build
  if build.nil?
    puts '  SKIP guarded behaviour: needs a full-core libmruby (BC2CPP_MRUBY_FULL, or rake, g++ and 3rd/mruby)'
  else
    dir = Dir.mktmpdir('bc2cpp-guarded-send')
    at_exit { FileUtils.remove_entry(dir) }
    code, err = Bc2cppFixtureRuntime.generate(GUARDED_SRC, dir, core: true, only_owners: %w[GsFx])
    check.call('guarded fixture: via_send and via_splat take the guarded expansion',
               code.scan('// COMPUTED_SEND_GUARDED').size >= 3)
    check.call('guarded fixture: via_splat reads its list in place (SPLAT_SHARED)', code.include?('// SPLAT_SHARED'))
    body = <<~CPP
      static int scenario(mrb_state* M) {
        std::fflush(stdout);
        const char* src = R"GSD(#{GUARDED_DRIVER})GSD";
        mrb_load_string(M, src);
        std::fflush(stdout);
        if (M->exc) { mrb_print_error(M); M->exc = nullptr; return 1; }
        return 0;
      }
    CPP
    built, output = Bc2cppFixtureRuntime.run(dir, err, %w[GsFx], body, build: build, full: true)
    check.call('guarded fixture: builds and runs', built)
    sections = Bc2cppFixtureRuntime.sections(output)
    interpreted = sections['interpreted']
    compiled = sections['compiled']
    check.call('guarded fixture: both runs reach the end', interpreted&.last == 'end' && compiled&.last == 'end')
    check.call('guarded fixture: interpreted and compiled runs print the same', interpreted == compiled)
    interpreted.to_a.zip(compiled.to_a).reject { |a, b| a == b }.first(10).each do |a, b|
      puts "    interpreted: #{a}\n    compiled:    #{b}"
    end
    check.call('guarded fixture: an arm returns the method result', interpreted.to_a.include?('send one: 2'))
    puts output.lines.last(30).join unless built && interpreted && compiled
  end
end

if failures.empty?
  puts 'bc2cpp computed send check: PASS'
else
  warn "bc2cpp computed send check: #{failures.size} failure(s)"
  exit 1
end
