#!/usr/bin/env ruby
# frozen_string_literal: true

# PROC_CALL_HELPER (bc2cpp_proc_call_argv) and STDERR_REPORT (bc2cpp_stderr_report): `x.call(*args)` in a core body looks
# `call` up once and runs the found method (no by-name send), and the failure reports print through one helper. Core
# Enumerable runs a Proc, a lambda, a Method's proc, Proc subclasses (an own `call`, none with method_missing, a private
# one), a nil receiver, and the report goes to the real $stderr, a user object with `puts`; the
# interpreted and compiled runs print the same.
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir] ruby scripts/bc2cpp/proc_call_helper_check.rb

require_relative 'fixture_runtime'

suite = Bc2cppStepCheck.new('bc2cpp proc call helper check')

SRC = <<~'RUBY'
class PcSrc
  include Enumerable
  def each
    yield 1, 2
    yield 3
    yield [4, 5]
    yield({ a: 1 })
    self
  end
end
class PcProc < Proc; end
class PcOwn < Proc
  def call(*a, **k) = [:own, a, k]
end
class PcNoCall < Proc
  undef_method :call
  def method_missing(n, *a) = [:mm, n, a]
end
class PcPriv < Proc
  private :call
end
RUBY

OWNERS = %w[PcSrc PcProc PcOwn PcNoCall PcPriv Enumerable Array Hash Range Kernel Proc].freeze
code = suite.generate(SRC, OWNERS)
suite.check('core bodies call the helper', code.include?('bc2cpp_proc_call_argv(M, '))
helper = code[/static mrb_value bc2cpp_proc_call_argv\(mrb_state\* M.*?\n *\}\n/m].to_s
suite.check('the helper no longer sends call by name', !helper.empty? && !helper.include?('mrb_funcall_argv'))
suite.check('the helper runs the method it found', code.include?('mrb_funcall_with_method(M, recv, call_id, &m, c, argc, argv'))
suite.check('the failure reports share one helper', code.scan(/mrb_funcall_id\(M, err, puts_id/).size <= 1)

DRIVER = <<~'RUBY'
def shown(label)
  puts "#{label}: #{yield.inspect}"
rescue StandardError => e
  puts "#{label}: raised #{e.class}: #{e.message}"
end
s = PcSrc.new
m = 5.method(:+)
shown('proc') { s.map(&proc { |*a| a }) }
shown('lambda') { s.map(&->(*a) { a.size }) }
shown('method') { s.select(&m.to_proc) }
pp = PcProc.new { |*a| a.size }
shown('subclass') { s.map(&pp) }
shown('own') { s.map(&PcOwn.new { |*a| a }) }
shown('nocall') { s.map(&PcNoCall.new { |*a| a }) }
shown('priv') { s.map(&PcPriv.new { |*a| a }) }
shown('all') { s.all?(&PcProc.new { |*a| a }) }
shown('any') { s.any?(&PcOwn.new { |*a| false }) }
shown('nil') { PcProbe.nil_call(1, 2) }
shown('nil bare') { PcProbe.nil_call }
PcProbe.report('plain report')
class PcCapture
  attr_reader :lines
  def initialize = (@lines = [])
  def puts(*a) = (@lines << a)
end
real = $stderr
cap = PcCapture.new
$stderr = cap
PcProbe.report('captured report')
$stderr = real
p cap.lines
puts 'end'
RUBY

# The probe: compiled, it is the helpers themselves; interpreted, the Ruby they stand for.
body = <<~CPP
  static mrb_value probe_nil_call(mrb_state* M, mrb_value) {
    mrb_value* argv; mrb_int argc;
    mrb_get_args(M, "*", &argv, &argc);
    return bc2cpp_proc_call_argv(M, mrb_nil_value(), argc, argv);
  }
  static mrb_value probe_report(mrb_state* M, mrb_value) {
    mrb_value msg;
    mrb_get_args(M, "S", &msg);
    bc2cpp_stderr_report(M, "[RPG2k] ", msg);
    return mrb_nil_value();
  }
  static int scenario(mrb_state* M) {
    std::fflush(stdout);
    if (compiled) {
      struct RClass* probe = mrb_define_module(M, "PcProbe");
      mrb_define_class_method(M, probe, "nil_call", probe_nil_call, MRB_ARGS_ANY());
      mrb_define_class_method(M, probe, "report", probe_report, MRB_ARGS_REQ(1));
    } else {
      mrb_load_string(M, "module PcProbe; def self.nil_call(*a) = nil.call(*a); def self.report(m) = $stderr.puts('[RPG2k] ' + m); end");
    }
    const char* src = R"RBC(#{DRIVER})RBC";
    mrb_load_string(M, src);
    std::fflush(stdout);
    if (M->exc) { mrb_print_error(M); M->exc = nullptr; return 1; }
    return 0;
  }
CPP
build = ENV['CC_GENERATED_ONLY'] == '1' ? nil : Bc2cppFixtureRuntime.full_or_build
if build.nil?
  puts '  SKIP behaviour: needs a full-core libmruby (BC2CPP_MRUBY_FULL, or rake and g++)'
else
  built, output = Bc2cppFixtureRuntime.run(suite.dir, suite.err, OWNERS, body, build: build, full: true)
  suite.check('the fixture builds and runs', built)
  sections = Bc2cppFixtureRuntime.sections(output)
  interpreted = sections['interpreted'].to_a.reject { |l| l.start_with?('  dispatches=') }
  compiled = sections['compiled'].to_a.reject { |l| l.start_with?('  dispatches=') }
  suite.check('both runs reach the end', interpreted.last == 'end' && compiled.last == 'end')
  suite.check('interpreted and compiled runs print the same', interpreted == compiled)
  suite.check('a missing call goes through method_missing', interpreted.any? { |l| l.start_with?('nocall: [[:mm, :call') })
  suite.check('a private call raises as the interpreter does', interpreted.any? { |l| l.include?("private method 'call'") })
  suite.check('nil.call raises the interpreter text', interpreted.any? { |l| l.include?("undefined method 'call' for") })
  suite.check('the report reaches $stderr.puts', interpreted.include?('[["[RPG2k] captured report"]]'))
  report_diff = interpreted.zip(compiled).reject { |a, b| a == b }
  report_diff.first(10).each { |a, b| puts "    interpreted: #{a}\n    compiled:    #{b}" }
  puts output.lines.last(30).join unless built
end
suite.finish
