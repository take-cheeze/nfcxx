#!/usr/bin/env ruby
# encoding: UTF-8
# frozen_string_literal: true

# Literal-block sends to a class method of a stable class constant (`Klass.each_x(n) { }`): CLOSED_WORLD_CONSTANT_OBJECT
# takes SENDB sites, and CONSTANT_OBJECT_CORE_BLOCK calls a compiled core class method (tools/bc2cpp/codegen_constant_object.rb).
#
#   generated code (needs a host mrbc)
#     - a program class method, own and inherited, is a direct `_impl` call with the block (frame-local when the
#       callee only yields it);
#     - StringIO.open { } calls the compiled core StringIO.open behind the root-context test, the send as the else;
#     - File.open { } calls mruby-io's compiled IO.open (File < IO, declarations.rbs#core_hierarchy) the same way,
#       also inside a rescue body and written `::File`;
#     - a program `def StringIO.open` takes the program definition, and BC2CPP_BLOCK_CORE_DIRECT=0 keeps the
#       core send.
#   behaviour (needs a full-core libmruby, see Bc2cppFixtureRuntime.full_or_build)
#     - interpreted and compiled runs print the same for captured-variable writes, `break` and `next` in the block,
#       an exception raised in the block (StringIO.open's io is still closed), a block that stores itself, GC.stress
#       and the same calls inside a Fiber (the core call's else).
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir | BC2CPP_FULL_BUILD_DIR=dir] ruby scripts/bc2cpp/class_method_block_check.rb

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
  class CmBase
    def self.each_x(n); i = 0; while i < n; yield i; i += 1; end; :done; end
    def self.keep(&b); @kept = b; :kept; end
    def self.kept; @kept; end
  end

  class CmSub < CmBase
  end

  class CmFx
    def own(n); s = 0; r = CmBase.each_x(n) { |x| s += x }; [r, s]; end
    def inh(n); s = 0; r = CmSub.each_x(n) { |x| s += x * 10 }; [r, s]; end
    def brk(n); CmBase.each_x(n) { |x| break [:stop, x] if x == 2 }; end
    def nxt(n); r = []; CmBase.each_x(n) { |x| next if x.odd?; r << x }; r; end
    def boom(n); CmBase.each_x(n) { |x| raise ArgumentError, "at #{x}" if x == 1 }; rescue ArgumentError => e; e.message; end
    def keep(n); CmBase.keep { |x| x + 1 }; [n, CmBase.kept.call(5)]; end
    def sio(s); r = nil; StringIO.open(s) { |io| r = io.read }; r; end
    def sio_boom(s); keep = nil; StringIO.open(s) { |io| keep = io; raise ArgumentError, 'in' }; rescue ArgumentError; keep.closed?; end
    def fopen(p); File.open(p, 'w') { |f| f.write('x') }; end
    def fread(p); File.open(p, 'r') { |f| f.read }; rescue IOError => e; "io: #{e.message}"; end
    def ftop(p); ::File.open(p, 'a') { |f| f.write('y') }; end
  end
RUBY

OWNERS = %w[CmBase CmBase.singleton CmSub CmSub.singleton CmFx].freeze

# The method's body and its helpers (a `rescue` body is its own `_impl_rescue_try` function).
def code_of(code, name)
  code.scan(/^(?:static )?mrb_value CmFx_#{name}_impl\w*\(mrb_state\* M.*?(?=^(?:static )?mrb_value \w+\(mrb_state\* M|\z)/m).join
end

def generate_world(src = SRC, env = {})
  saved = env.keys.to_h { |k| [k, ENV.fetch(k, nil)] }
  env.each { |k, v| ENV[k] = v }
  Dir.mktmpdir { |dir| Bc2cppFixtureRuntime.generate(src, dir, core: true, only_owners: OWNERS) }
ensure
  saved&.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
end

DYNAMIC = 'mrb_funcall_with_block('

baseline_dir = Dir.mktmpdir('bc2cpp-class-method-block')
at_exit { FileUtils.remove_entry(baseline_dir) }
puts '-- generated code'
code, baseline_err = Bc2cppFixtureRuntime.generate(SRC, baseline_dir, core: true, only_owners: OWNERS)
check.call('own: a program class method is a direct call with the frame-local block, no send',
           code_of(code, 'own').match?(/CmBase_singleton_each_x_impl\(M, r\d+, r\d+, bc2cpp_blk_stack_\d+\.value\(\)\)/) &&
             !code_of(code, 'own').include?(DYNAMIC))
check.call('inh: an inherited class method (CmSub.each_x is CmBase.each_x) is the same direct call',
           code_of(code, 'inh').include?('CmBase_singleton_each_x_impl(M, ') && !code_of(code, 'inh').include?(DYNAMIC))
check.call('keep: a class method that stores its block gets the heap block',
           code_of(code, 'keep').include?('CmBase_singleton_keep_impl(M, ') &&
             !code_of(code, 'keep').include?('Bc2cppStackBlock'))
sio = code_of(code, 'sio')
check.call('sio: StringIO.open calls the compiled core class method at the root context, the send as the else',
           sio.match?(/if \(M->c == M->root_c\) \{\n\s+r\d+ = StringIO_singleton_open_impl\(M, /) && sio.include?(DYNAMIC))
%w[fopen fread ftop].each do |m|
  check.call("#{m}: File.open calls the compiled IO.open at the root context, the send as the else",
             code_of(code, m).match?(/if \(M->c == M->root_c\) \{\n\s+r\d+ = IO_singleton_open_impl\(M, /) &&
               code_of(code, m).include?(DYNAMIC))
end
c, = generate_world(SRC + "class StringIO\n  def self.open(*a); yield :mine; end\nend\n")
check.call('a program StringIO.open withdraws the core call', !code_of(c, 'sio').include?('StringIO_singleton_open_impl(M, '))
c, = generate_world(SRC, { 'BC2CPP_BLOCK_CORE_DIRECT' => '0' })
check.call('BC2CPP_BLOCK_CORE_DIRECT=0: no core class-method call', !code_of(c, 'sio').include?('StringIO_singleton_open_impl(M, '))

DRIVER = <<~'RUBY'
  fx = CmFx.new
  show = lambda do |name, &blk|
    out = begin
      blk.call.inspect
    rescue Exception => e
      "#{e.class}: #{e.message}"
    end
    puts "#{name}: #{out}"
  end
  [0, 1, 4].each do |n|
    %i[own inh brk nxt boom keep].each { |m| show.call("#{m}/#{n}") { fx.send(m, n) } }
  end
  show.call('sio') { fx.sio('abc') }
  show.call('sio_boom') { fx.sio_boom('abc') }
  show.call('fopen') { fx.fopen('bc2cpp_cm_fopen.txt'); fx.ftop('bc2cpp_cm_fopen.txt'); fx.fread('bc2cpp_cm_fopen.txt') }
  show.call('fread missing') { fx.fread('bc2cpp_cm_missing/none.txt') }
  File.delete('bc2cpp_cm_fopen.txt') if File.exist?('bc2cpp_cm_fopen.txt')
  show.call('gc stress') do
    GC.stress = true if GC.respond_to?(:stress=)
    r = [fx.own(3), fx.inh(2), fx.sio('xy')]
    GC.stress = false if GC.respond_to?(:stress=)
    r
  end
  f = Fiber.new do
    out = [fx.own(3), fx.sio('fib')]
    Fiber.yield out
    fx.brk(5)
  end
  show.call('fiber') { [f.resume, f.resume] }
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
    body = <<~CPP
      static int scenario(mrb_state* M) {
        std::fflush(stdout);
        const char* src = R"CMB(#{DRIVER})CMB";
        mrb_load_string(M, src);
        std::fflush(stdout);
        if (M->exc) { mrb_print_error(M); M->exc = nullptr; return 1; }
        return 0;
      }
    CPP
    built, output = Bc2cppFixtureRuntime.run(baseline_dir, baseline_err, OWNERS, body, build: build, full: true)
    check.call('the fixtures build and run', built)
    sections = Bc2cppFixtureRuntime.sections(output)
    interpreted = sections['interpreted']
    compiled = sections['compiled']
    check.call("the driver prints #{interpreted&.size} lines in both runs",
               interpreted && interpreted.last == 'end' && compiled&.last == 'end')
    check.call('interpreted and compiled runs print the same', interpreted == compiled)
    if interpreted && compiled
      interpreted.zip(compiled).reject { |a, b| a == b }.first(10).each { |a, b| puts "    interpreted: #{a}\n    compiled:    #{b}" }
      check.call('a captured variable written by the block is seen after the call', interpreted.include?('own/4: [:done, 6]'))
      check.call('StringIO.open closes its io when the block raises', interpreted.include?('sio_boom: true'))
    end
    puts output.lines.last(30).join unless built && interpreted && compiled
  end
end

if failures.empty?
  puts 'bc2cpp class method block check: PASS'
else
  warn "bc2cpp class method block check: #{failures.size} failure(s)"
  exit 1
end
