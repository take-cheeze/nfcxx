# frozen_string_literal: true

# PROTECT_CXX (tools/bc2cpp/bc2cpp.rb, bc2cpp_protect; docs/bc2cpp-vm-free-runtime-plan.md Phase 3): rescue and ensure
# boundaries are one typed C++ catch of mruby's `throw (mrb_jmpbuf*)`, not a call into the VM's protect function.
#
#   generated code (needs a host mrbc)
#     - the output has bc2cpp_protect sites and no mrb_protect_error call, and its GC arena roots all go through
#       bc2cpp_root (one mrb_gc_protect), with the numeric slow paths on bc2cpp_arena_keep;
#   behaviour (needs a full-core libmruby; run it on the GC-stress build too)
#     - interpreted and compiled runs print the same for: clause matching by class (first match wins, an unmatched
#       class passes through), `rescue => e` with `raise` re-raised and chained, retry, ensure order, `return`,
#       `break` and `next` through ensure, an ensure that raises (it supersedes), `$!` after a rescue, a rescue inside
#       a block, a raise through a nested rescue, and the same calls with GC.stress.
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir | BC2CPP_FULL_BUILD_DIR=dir] ruby scripts/bc2cpp/protect_cxx_check.rb

require 'tmpdir'
require_relative 'fixture_runtime'

# The fixture is its own closed world: the repository signatures name classes it does not define.
ENV['BC2CPP_SIG_DIRS'] = ''

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

unless Bc2cppFixtureRuntime.mrbc && system(Bc2cppFixtureRuntime.mrbc, '--version', out: File::NULL, err: File::NULL)
  puts '  SKIP: no host mrbc (set MRBC); the generated-code and behavioural checks need it'
  exit 0
end

SRC = <<~'RUBY'
  class PcErrA < StandardError; end
  class PcErrB < PcErrA; end
  class PcErrC < StandardError; end

  class PcFx
    attr_reader :log
    def initialize; @log = []; end

    # Clause matching by class: the first matching clause runs, a subclass matches its parent, others pass through.
    def match(kind)
      raise PcErrB, 'b' if kind == :b
      raise PcErrC, 'c' if kind == :c
      raise ArgumentError, 'arg' if kind == :arg
      :none
    rescue PcErrA => e
      @log << [:a, e.class, e.message]
      :a
    rescue PcErrC => e
      @log << [:c, e.message]
      :c
    end

    # Ensure order and the value a plain ensure cannot change.
    def ensure_order(fail)
      @log << :body
      raise PcErrA, 'x' if fail
      :value
    rescue PcErrA
      @log << :rescue
      :rescued
    ensure
      @log << :ensure
    end

    def only_ensure(fail)
      begin
        @log << :body
        raise PcErrA, 'x' if fail
        :value
      ensure
        @log << :ensure
      end
    end

    # retry runs the protected region again.
    def retrying
      tries = 0
      begin
        tries += 1
        raise PcErrA, "try #{tries}" if tries < 3
        tries
      rescue PcErrA
        retry
      end
    end

    # A rescue body that raises, and the chain `$!` leaves.
    def reraise
      begin
        raise PcErrA, 'inner'
      rescue PcErrA => e
        @log << $!.equal?(e)
        raise PcErrC, 'outer'
      end
    end

    # return, break and next through ensure.
    def return_through
      [1, 2, 3].each do |i|
        begin
          return i * 10 if i == 2
        ensure
          @log << [:ens, i]
        end
      end
      :unreached
    end

    def break_through
      r = [1, 2, 3].each do |i|
        begin
          break i + 100 if i == 2
        ensure
          @log << [:brk, i]
        end
      end
      r
    end

    def next_through
      [1, 2, 3].map do |i|
        begin
          next -i if i == 2
          i
        ensure
          @log << [:nxt, i]
        end
      end
    end

    # An ensure that raises supersedes the exception in flight.
    def supersede
      begin
        raise PcErrA, 'first'
      ensure
        raise PcErrC, 'second'
      end
    rescue PcErrC => e
      e.message
    end

    # A rescue inside a block, and a raise that passes a nested rescue that does not match.
    def in_block(items)
      items.map do |x|
        begin
          Integer(x)
        rescue ArgumentError
          -1
        end
      end
    end

    def nested(kind)
      begin
        begin
          raise PcErrC, 'deep' if kind == :c
          raise PcErrA, 'a' if kind == :a
          :fine
        rescue PcErrA
          :inner
        end
      rescue PcErrC => e
        e.message
      end
    end

    def make_garbage(n)
      begin
        a = []
        n.times { |i| a << "s#{i}" * 3 }
        raise PcErrA, a.join(',')
      rescue PcErrA => e
        e.message.size
      end
    end
  end
RUBY

OWNERS = %w[PcFx PcErrA PcErrB PcErrC].freeze
# Shapes the generator compiles; ensure_order, retrying and supersede (rescue with ensure, retry, a raising ensure)
# are also in the driver and run interpreted when it declines them.
METHODS = %w[match only_ensure reraise return_through break_through next_through in_block nested make_garbage].freeze

def body_of(code, name)
  code.scan(/^(?:static )?mrb_value #{name}\w*\(mrb_state\* M.*?(?=^(?:static )?mrb_value \w+\(mrb_state\* M|\z)/m).join
end

baseline_dir = Dir.mktmpdir('bc2cpp-protect-cxx')
at_exit { FileUtils.remove_entry(baseline_dir) }
puts '-- generated code'
code, baseline_err = Bc2cppFixtureRuntime.generate(SRC, baseline_dir, core: true, only_owners: OWNERS, skip_unsupported: false)
check.call('the fixture generates', !code.empty?)
check.call('rescue and ensure boundaries are bc2cpp_protect sites', code.scan(/\bbc2cpp_protect(?:_call)?\(M, /).size >= 4)
check.call('no boundary calls the VM protect function (the Fiber loop included)',
           !code.match?(/\bmrb_protect\w*\(/))
check.call('every arena root goes through bc2cpp_root', code.scan(/\bmrb_gc_protect\b/).size <= 3)
check.call('the numeric slow paths use bc2cpp_arena_keep', code.include?('return bc2cpp_arena_keep(M, ai, r);'))
METHODS.each do |name|
  body = body_of(code, "PcFx_#{name}_impl")
  check.call("PcFx##{name} compiles", !body.empty? && !body.include?('#error'))
end

DRIVER = <<~'RUBY'
  show = lambda do |name, &blk|
    out = begin
      blk.call.inspect
    rescue Exception => e
      "#{e.class}: #{e.message}"
    end
    puts "#{name}: #{out}"
  end
  fx = PcFx.new
  [:a, :b, :c, :arg, :none].each { |k| show.call("match/#{k}") { fx.match(k) } }
  show.call('match log') { fx.log.dup }
  [false, true].each { |f| show.call("ensure_order/#{f}") { fx = PcFx.new; [fx.ensure_order(f), fx.log] } }
  [false, true].each { |f| show.call("only_ensure/#{f}") { fx = PcFx.new; [(fx.only_ensure(f) rescue $!.class), fx.log] } }
  show.call('retrying') { PcFx.new.retrying }
  show.call('reraise') { fx = PcFx.new; begin; fx.reraise; rescue PcErrC => e; [e.message, fx.log, $!.equal?(e)]; end }
  show.call('return_through') { fx = PcFx.new; [fx.return_through, fx.log] }
  show.call('break_through') { fx = PcFx.new; [fx.break_through, fx.log] }
  show.call('next_through') { fx = PcFx.new; [fx.next_through, fx.log] }
  show.call('supersede') { PcFx.new.supersede }
  show.call('in_block') { PcFx.new.in_block(['1', 'x', '3', nil.to_s]) }
  [:a, :c, :fine].each { |k| show.call("nested/#{k}") { PcFx.new.nested(k) } }
  show.call('errinfo') { begin; PcFx.new.match(:b); rescue Exception; end; $!.inspect }
  show.call('gc stress') do
    GC.stress = true if GC.respond_to?(:stress=)
    r = [PcFx.new.make_garbage(20), PcFx.new.match(:b), PcFx.new.retrying, PcFx.new.supersede,
         PcFx.new.in_block(%w[1 z]), (PcFx.new.match(:arg) rescue $!.message)]
    GC.stress = false if GC.respond_to?(:stress=)
    r
  end
  puts 'end'
RUBY

if ENV['CC_GENERATED_ONLY'] == '1'
  puts '  SKIP behavioural comparison: CC_GENERATED_ONLY'
else
  build = Bc2cppFixtureRuntime.full_or_build
  if build.nil?
    puts '  SKIP behavioural comparison: needs a full-core libmruby (BC2CPP_MRUBY_FULL, or rake, g++ and 3rd/mruby)'
  else
    puts '-- fixtures on real mruby, interpreted and compiled'
    run_dir = Dir.mktmpdir('bc2cpp-protect-cxx-run')
    at_exit { FileUtils.remove_entry(run_dir) }
    run_code, run_err = Bc2cppFixtureRuntime.generate(SRC, run_dir, core: true, only_owners: OWNERS)
    check.call('the run world compiles with', !run_code.empty?)
    body = <<~CPP
      static int scenario(mrb_state* M) {
        std::fflush(stdout);
        const char* src = R"PCX(#{DRIVER})PCX";
        mrb_load_string(M, src);
        std::fflush(stdout);
        if (M->exc) { mrb_print_error(M); M->exc = nullptr; return 1; }
        return 0;
      }
    CPP
    built, output = Bc2cppFixtureRuntime.run(run_dir, run_err, OWNERS, body, build: build, full: true)
    check.call('the fixtures build and run', built)
    sections = Bc2cppFixtureRuntime.sections(output)
    interpreted = sections['interpreted']
    compiled = sections['compiled']
    check.call("the driver prints #{interpreted&.size} lines in both runs",
               interpreted && interpreted.last == 'end' && compiled&.last == 'end')
    check.call('interpreted and compiled runs print the same', interpreted == compiled)
    if interpreted && compiled
      interpreted.zip(compiled).reject { |a, b| a == b }.first(10).each { |a, b| puts "    interpreted: #{a}\n    compiled:    #{b}" }
      check.call('a subclass matches its parent clause', interpreted.include?('match/b: :a'))
      check.call('an unmatched class passes through', interpreted.include?('match/arg: ArgumentError: arg'))
      check.call('retry runs the region again', interpreted.include?('retrying: 3'))
      check.call('break leaves through ensure', interpreted.include?('break_through: [102, [[:brk, 1], [:brk, 2]]]'))
      check.call('an ensure that raises supersedes', interpreted.include?('supersede: "second"'))
    end
    puts output.lines.last(30).join unless built && interpreted && compiled
  end
end

if failures.empty?
  puts 'bc2cpp protect cxx check: PASS'
else
  warn "bc2cpp protect cxx check: #{failures.size} failure(s)"
  exit 1
end
