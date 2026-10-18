#!/usr/bin/env ruby
# frozen_string_literal: true

# Checks scripts/bc2cpp/base_rbs.rb: a superclass named in a class body is resolved the way Ruby resolves it (innermost
# enclosing namespace first), so the stub's `class X < Y` means the same class in RBS. Also checks the native
# textual scanner's body boundaries and core-owner matches. Host only, a few seconds.
#
#   ruby scripts/bc2cpp/base_rbs_check.rb

require 'rbs'
require 'tmpdir'
require 'tempfile'
require 'open3'
require_relative 'base_rbs_native'
require_relative 'base_rbs' unless defined?(BaseRbs)

ROOT = File.expand_path('../..', __dir__)
failures = []
checks = 0
check = lambda do |what, condition|
  checks += 1
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

FIXTURE = <<~RUBY
  module RPG
    class BaseItem; end
    class Actor < BaseItem; end
    class Armor < ::RPG::BaseItem; end
  end
  module RPG2k
    module Scene
      class Base; end
      class Battle < Base; end
      class Map < ::RPG::Actor; end
      class Menu < Helper; end
    end
    class Scene::Title < Scene::Base; end
  end
  class Standalone < File; end
  class Plain < Object; end
  class Implicit; end
RUBY

puts '== native textual scanning'
body = "{ if (true) { return mrb_fixnum_value(1); } return mrb_nil_value(); }"
text = "void before() {}\nmrb_value result() #{body}\nvoid after() {}"
check.call('nested bodies stop before the following function', BaseRbsNative.function_body_of(text, 'result') == body)
check.call('a missing function has no body', BaseRbsNative.function_body_of(text, 'missing').nil?)
check.call('a prototype has no body', BaseRbsNative.function_body_of('mrb_value result();', 'result').nil?)
check.call('an unterminated body stays empty', BaseRbsNative.function_body_of('mrb_value result() { if (true) { }', 'result') == '')
check.call('a nonidentifier function is refused', BaseRbsNative.function_body_of(text, 'result()').nil?)
unicode_body = "{ /* 日本語 */ if (true) { return mrb_nil_value(); } }"
unicode = "// café 日本語\nmrb_value result() #{unicode_body}\nvoid next() {}"
check.call('Unicode before and inside the body preserves character offsets',
           BaseRbsNative.function_body_of(unicode, 'result') == unicode_body)
large_body = "{ /* #{'nonbrace ' * 20_000} */ { return mrb_nil_value(); } }"
check.call('a long body retains every character', BaseRbsNative.function_body_of("mrb_value result() #{large_body}", 'result') == large_body)

# Reference semantics count every textual brace, including braces in strings and comments.
reference_body = lambda do |source, open|
  depth = 0
  result = ''
  (open...source.length).each do |i|
    depth += 1 if source[i] == '{'
    depth -= 1 if source[i] == '}'
    if depth.zero?
      result = source[open..i]
      break
    end
  end
  result
end
rng = Random.new(20_261_018)
pieces = ['{', '}', 'x', ' ', "\n", 'é', '日本語', '"{"', '/* } */', '\\']
same = 500.times.all? do
  prefix = ['é', '日本語', 'x'].sample(random: rng)
  source = prefix + '{' + Array.new(rng.rand(0..80)) { pieces.sample(random: rng) }.join
  BaseRbsNative.function_body(source, prefix.length) == reference_body.call(source, prefix.length)
end
check.call('500 random bodies retain the previous textual brace semantics', same)

owner_assignments = [
  'krn = mrb->kernel_module;', 'integer = M->fixnum_class;',
  'long_identifier = mrb->object_class;', 'prefixkrn = M->kernel_module;',
  'x = mrb->string_class ;', 'x == mrb->string_class;',
  'x = mrb->string_class_extra;', 'x = other->string_class;', 'x = mrb->string_class'
]
owner_same = 500.times.all? do
  source = Array.new(rng.rand(1..15)) { owner_assignments.sample(random: rng) }.join("\n")
  source.scan(/(\w+)\s*=\s*((?:M|mrb)->\w+_(?:class|module))\s*;/) ==
    source.scan(/(?<!\w)(\w+)\s*=\s*((?:M|mrb)->\w+_(?:class|module))\s*;/)
end
check.call('500 mixed assignment texts preserve core-owner matches', owner_same)
source = <<~CPP
  krn = mrb->kernel_module;
  mrb_value count(mrb_state *mrb, mrb_value self) { return mrb_fixnum_value(1); }
  mrb_define_method(mrb, krn, "count", count, 0);
CPP
kinds, supers, methods, skipped = BaseRbsNative.scan(source)
check.call('core-owner assignments still attach method signatures',
           kinds.empty? && supers.empty? && methods == [['Kernel', false, 'count', '() -> Integer']] && skipped.empty?)

puts '== superclass resolution'
Dir.mktmpdir('base-rbs-check') do |dir|
  src = File.join(dir, 'fixture.rb')
  File.write(src, FIXTURE)
  out = File.join(dir, 'out')
  files, = BaseRbs.run(out, [src])
  text = files.to_h { |path| [File.basename(path), File.read(path)] }
  lines = text.values.join.lines.map(&:strip)

  check.call('a sibling superclass resolves inside its namespace (RPG::Actor < RPG::BaseItem)',
             lines.include?('class RPG::Actor < RPG::BaseItem'))
  check.call('an absolute superclass is written as its full name (RPG::Armor < RPG::BaseItem)',
             lines.include?('class RPG::Armor < RPG::BaseItem'))
  check.call('a superclass in an inner namespace resolves to the outer one (RPG2k::Scene::Battle < RPG2k::Scene::Base)',
             lines.include?('class RPG2k::Scene::Battle < RPG2k::Scene::Base'))
  check.call('an absolute superclass defined elsewhere keeps its full name (RPG2k::Scene::Map < RPG::Actor)',
             lines.include?('class RPG2k::Scene::Map < RPG::Actor'))
  check.call('a compact nested name resolves from the enclosing namespace (RPG2k::Scene::Title < RPG2k::Scene::Base)',
             lines.include?('class RPG2k::Scene::Title < RPG2k::Scene::Base'))
  check.call('a name the sources do not define is written as it is (Standalone < File)',
             lines.include?('class Standalone < File'))
  check.call('an undefined name inside a namespace stays as written (RPG2k::Scene::Menu < Helper)',
             lines.include?('class RPG2k::Scene::Menu < Helper'))
  check.call('an explicit Object superclass is left out, as a class with none is (Plain, Implicit)',
             lines.include?('class Plain') && lines.include?('class Implicit') && lines.none? { |l| l.end_with?('< Object') })

  puts '== the output parses as RBS'
  text.each do |name, content|
    RBS::Parser.parse_signature(RBS::Buffer.new(name: name, content: content))
    check.call("#{name} parses", true)
  end
end

puts '== bounded native workers'
check.call('one job preserves serial results', BaseRbsWorkers.map([3, 1, 2], jobs: 1) { |n| n * 2 } == [6, 2, 4])
begin
  BaseRbsWorkers.map([], jobs: 0) { |n| n }
  check.call('zero jobs is rejected', false)
rescue ArgumentError => e
  check.call('zero jobs is rejected', e.message.include?('positive integer'))
end

if Process.respond_to?(:fork)
  parent = Process.pid
  rows = BaseRbsWorkers.map((0...5).to_a, jobs: 2) do |n|
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    sleep(n.zero? ? 0.12 : 0.02)
    [n, Process.pid, started, Process.clock_gettime(Process::CLOCK_MONOTONIC)]
  end
  events = rows.flat_map { |_, _, first, last| [[first, 1], [last, -1]] }.sort
  active = 0
  peak = events.map { |_, delta| active += delta }.max
  check.call('results retain input order across uneven jobs', rows.map(&:first) == (0...5).to_a)
  check.call('file scans run in child processes', rows.all? { |_, pid, *| pid != parent })
  check.call('two jobs overlap without exceeding the bound', peak == 2)
  check.call('empty input produces no results', BaseRbsWorkers.map([], jobs: 2) { raise 'unreachable' } == [])

  saved_stderr = $stderr
  begin
    Tempfile.create('base-rbs-stderr') do |file|
      $stderr = file
      BaseRbsWorkers.map([0, 1, 2], jobs: 2) do |n|
        sleep 0.05 if n.zero?
        warn "diagnostic #{n}"
        n
      end
      file.flush
      file.rewind
      check.call('diagnostics retain source order', file.read == "diagnostic 0\ndiagnostic 1\ndiagnostic 2\n")
    end
  ensure
    $stderr = saved_stderr
  end

  begin
    BaseRbsWorkers.map([0, 1, 2], jobs: 2) { |n| raise ArgumentError, 'fixture failure' if n == 2 }
    check.call('worker exceptions propagate', false)
  rescue ArgumentError => e
    check.call('worker exceptions propagate with their backtrace',
               e.message == 'fixture failure' && e.backtrace.any? { |line| line.include?(__FILE__) })
  end
  [0, 9].each do |signal|
    begin
      BaseRbsWorkers.map([0, 1, 2], jobs: 2) do |n|
        next n unless n == 2

        Process.kill(signal, Process.pid) if signal.positive?
        exit! 0
      end
      check.call("worker termination #{signal} cannot reuse a previous result", false)
    rescue RuntimeError => e
      check.call("worker termination #{signal} cannot reuse a previous result", e.message.include?('no result'))
    end
  end
  begin
    Process.wait(-1, Process::WNOHANG)
    check.call('all workers are reaped after failure', false)
  rescue Errno::ECHILD
    check.call('all workers are reaped after failure', true)
  end
end

%w[base_rbs_all.rb base_rbs_native.rb].each do |script|
  _out, err, status = Open3.capture3(RbConfig.ruby, File.join(__dir__, script), '--jobs', '0', 'unused')
  check.call("#{script} rejects nonpositive jobs before generation", !status.success? && err.include?('jobs must be positive'))
end

puts '== native RBS serial/parallel equivalence'
if system('clang', '--version', out: File::NULL, err: File::NULL)
  Dir.mktmpdir('base-rbs-native-check') do |dir|
    header = <<~CPP
      struct mrb_state {};
      struct RClass {};
      struct mrb_value { int v; };
      mrb_value mrb_fixnum_value(int);
      mrb_value mrb_nil_value();
      RClass *mrb_define_class(mrb_state*, const char*, RClass*);
      void mrb_define_method(mrb_state*, RClass*, const char*, mrb_value (*)(mrb_state*, mrb_value), int);
    CPP
    paths = [['Alpha', 'mrb_fixnum_value(1)'], ['Beta', 'mrb_nil_value()'], ['Gamma', 'mrb_fixnum_value(2)']].map do |name, expression|
      path = File.join(dir, "#{name}.cxx")
      File.write(path, header + <<~CPP)
        namespace Helpers {
          mrb_value helper(mrb_value self) { return #{expression}; }
        }
        mrb_value result(mrb_state *mrb, mrb_value self) { return Helpers::helper(self); }
        void install(mrb_state *mrb) {
          RClass *klass = mrb_define_class(mrb, "#{name}", 0);
          mrb_define_method(mrb, klass, "result", result, 0);
        }
      CPP
      path
    end
    serial, serial_skipped = BaseRbsNative.run(File.join(dir, 'serial'), paths, [], jobs: 1)
    parallel, parallel_skipped = BaseRbsNative.run(File.join(dir, 'parallel'), paths, [], jobs: 2)
    text = File.read(parallel)
    check.call('serial and parallel RBS are byte-identical', text == File.read(serial))
    check.call('serial and parallel skipped registrations agree', parallel_skipped == serial_skipped)
    check.call('same-named helpers retain per-file return kinds',
               text.include?("class Alpha\n  def result: () -> Integer") &&
               text.include?("class Beta\n  def result: () -> nil") &&
               text.include?("class Gamma\n  def result: () -> Integer"))
    RBS::Parser.parse_signature(text)
    check.call('parallel output parses as RBS', true)
    cli_out = File.join(dir, 'cli')
    _out, err, status = Open3.capture3(RbConfig.ruby, File.join(__dir__, 'base_rbs_native.rb'),
                                     '--jobs', '2', cli_out, '-I', dir, '-D', 'FIXTURE=1', *paths)
    check.call('native CLI accepts jobs alongside include/define flags',
               status.success? && File.read(File.join(cli_out, 'native.rbs')) == text)
    check.call('native CLI reports its output', err.include?('wrote') && err.include?("skipped #{serial_skipped.size}"))
  end
else
  puts '  SKIP native equivalence: clang is not installed'
end

if failures.empty?
  puts "base rbs check: #{checks} checks passed"
else
  abort "base rbs check: #{failures.size} failure(s)"
end
