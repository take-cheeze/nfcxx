#!/usr/bin/env ruby
# frozen_string_literal: true

# PATH_FORM (tools/bc2cpp/load_compile.rb): a nesting header with no kept text of its own is removed, and the kept
# bodies under it are written with their full path (`class M::Inner`). This check needs no mruby build:
#
#   fixtures     each fixture is a few files, loaded in order, with defs and nested bodies only (nothing a load
#                compiles, so the residual is the whole program). The planner rewrites the residual; the original and
#                the residual are each loaded in a fresh CRuby process and must end with the same constants (their
#                kind, superclass, instance and singleton methods, nested constants) and the same probe results.
#                `accept` fixtures must have a header removed and equal results; `refuse` fixtures must have none
#                removed (the cref proof says the lookups would change) and equal results.
#   mutants      each rule the proof uses is turned off in a fresh process; a mutant must change the results of at
#                least one fixture, so the fixtures do exercise each rule.
#
# The equivalence of the compiled load (class_body_check.rb, equivalence section) needs the full-core libmruby and runs
# in CI; this check covers the residual rewrite alone.
ENV['BC2CPP_SIG_DIRS'] = ''

require 'json'
require 'open3'
require 'rbconfig'
require 'set'
require 'tmpdir'
require_relative 'check_support'
require_relative '../../tools/bc2cpp/load_compile'

suite = FixtureCheck.new('path_form_check')
ROOT = File.expand_path('../..', __dir__)

RUNNER = <<~'RUBY'
  require 'json'
  base = Object.constants
  JSON.parse(ENV.fetch('FILES')).each { |f| load f }
  def describe(mod, depth)
    return '...' if depth > 6

    out = { 'kind' => mod.class.name, 'name' => mod.name }
    out['superclass'] = mod.superclass&.name if mod.is_a?(Class)
    out['methods'] = mod.instance_methods(false).sort.map(&:to_s)
    out['private'] = mod.private_instance_methods(false).sort.map(&:to_s)
    out['singleton'] = mod.singleton_methods(false).sort.map(&:to_s)
    out['constants'] = mod.constants(false).sort.to_h { |c| [c.to_s, describe_value(mod.const_get(c, false), depth + 1)] }
    out
  end
  def describe_value(v, depth)
    v.is_a?(Module) ? describe(v, depth) : v.inspect
  end
  tree = (Object.constants - base).sort.to_h { |c| [c.to_s, describe_value(Object.const_get(c), 0)] }
  probes = JSON.parse(ENV.fetch('PROBES')).map do |expr|
    TOPLEVEL_BINDING.eval(expr).inspect
  rescue StandardError => e
    "ERR #{e.class}"
  end
  puts JSON.generate('constants' => tree, 'probes' => probes)
RUBY

# [name, expectation, [[file, source]...], probes]
OTHER = ['00_other.rb', <<~RUBY]
  class Other
    def self.v
      1
    end
  end
RUBY

FIXTURES = [
  ['accept: a header with a kept body under it', :accept,
   [OTHER, ['01_m.rb', <<~RUBY], ['02_inner.rb', <<~RUBY]],
     module M
       def m
         1
       end
     end
   RUBY
     module M
       class Inner
         def k
           Other.v
         end
       end
     end
   RUBY
   ['M::Inner.new.k', 'M.instance_methods(false).sort']],
  ['accept: a chain of headers with no text of their own', :accept,
   [OTHER, ['01_abc.rb', <<~RUBY], ['02_abc.rb', <<~RUBY]],
     module A
       module B
         def x
           2
         end
       end
     end
   RUBY
     module A
       module B
         class C
           def c
             Other.v + 1
           end
         end
       end
     end
   RUBY
   ['A::B::C.new.c', 'A::B.instance_methods(false)']],
  ['accept: a name the scope holds that the body does not use', :accept,
   [OTHER, ['01_holder.rb', <<~RUBY], ['02_inner.rb', <<~RUBY]],
     module M
       class Holder
         def h
           :holder
         end
       end
     end
   RUBY
     module M
       class Inner
         def k
           Other.v
         end
       end
     end
   RUBY
   ['M::Inner.new.k', 'M::Holder.new.h']],
  ['accept: a kept body with text, under a removed header, and its own kept child', :accept,
   [OTHER, ['01_m.rb', <<~RUBY], ['02_inner.rb', <<~RUBY]],
     module M
       def m
         1
       end
     end
   RUBY
     module M
       class Inner
         def k
           Other.v
         end

         class Deeper
           def j
             Other.v + 1
           end
         end
       end
     end
   RUBY
   ['M::Inner.new.k', 'M::Inner::Deeper.new.j']],
  ['refuse: a kept body under the header names a constant the header holds', :refuse,
   [OTHER, ['01_holder.rb', <<~RUBY], ['02_inner.rb', <<~RUBY]],
     module M
       class Holder
         def h
           :holder
         end
       end
     end
   RUBY
     module M
       class Inner
         def k
           Holder.new.h
         end
       end
     end
   RUBY
   ['M::Inner.new.k']],
  ['refuse: a nested body names a constant of the header that is not its own', :refuse,
   [OTHER, ['01_m.rb', <<~RUBY], ['02_inner.rb', <<~RUBY]],
     module M
       def m
         1
       end
     end
   RUBY
     module M
       class Inner
         def k
           Other.v
         end

         class Deeper
           def j
             Inner.new.k
           end
         end
       end
     end
   RUBY
   ['M::Inner::Deeper.new.j']],
  ['refuse: the superclass of a kept body is a constant of the header', :refuse,
   [OTHER, ['01_base.rb', <<~RUBY], ['02_inner.rb', <<~RUBY]],
     module M
       class Base
         def b
           1
         end
       end
     end
   RUBY
     module M
       class Inner < Base
         def k
           2
         end
       end
     end
   RUBY
   ['M::Inner.new.k']],
  ['refuse: the header is not created before (its first definition is itself)', :refuse,
   [OTHER, ['01_inner.rb', <<~RUBY]],
     module M
       class Inner
         def k
           3
         end
       end
     end
   RUBY
   ['M::Inner.new.k']],
  ['refuse: the first segment of the path is a constant of a scope that encloses it', :refuse,
   [OTHER, ['01_q.rb', <<~RUBY], ['02_q.rb', <<~RUBY]],
     module Q
       module Q
         def a
           1
         end
       end

       module M
         def m
           1
         end
       end

       def z
         2
       end
     end
   RUBY
     module Q
       def y
         3
       end

       module M
         class X
           def k
             Other.v
           end
         end
       end
     end
   RUBY
   ['Q::M::X.new.k']],
  ['refuse: a superclass expression reaches a scope\'s superclass constants (plain scopes only)', :refuse,
   [OTHER, ['01_base.rb', <<~RUBY], ['02_p.rb', <<~RUBY], ['03_p.rb', <<~RUBY]],
     class Base0
       class Deep
         def d
           :deep
         end
       end
     end
   RUBY
     class P < Base0
       def p
         1
       end
     end
   RUBY
     class P
       class Inner < Deep
         def k
           :k
         end
       end
     end
   RUBY
   ['P::Inner.new.k', 'P::Inner.superclass.name']],
  ['refuse: Module.nesting in a kept body (the scopes it reports would change)', :refuse,
   [OTHER, ['01_m.rb', <<~RUBY], ['02_inner.rb', <<~RUBY]],
     module M
       def m
         1
       end
     end
   RUBY
     module M
       class Inner
         def n
           Module.nesting.inspect
         end
       end
     end
   RUBY
   ['M::Inner.new.n']],
  ['refuse: a call that reads constants by name anywhere in the world', :refuse,
   [['00_other.rb', <<~RUBY], ['01_m.rb', <<~RUBY], ['02_inner.rb', <<~RUBY]],
     class Other
       def self.v
         1
       end

       def self.r
         Object.const_set(:Zed, 2)
       end
     end
   RUBY
     module M
       def m
         1
       end
     end
   RUBY
     module M
       class Inner
         def k
           Other.v
         end
       end
     end
   RUBY
   ['M::Inner.new.k']],
  ['refuse: a class variable anywhere in the world', :refuse,
   [['00_other.rb', <<~RUBY], ['01_m.rb', <<~RUBY], ['02_inner.rb', <<~RUBY]],
     class Other
       def self.v
         @@v ||= 1
       end
     end
   RUBY
     module M
       def m
         1
       end
     end
   RUBY
     module M
       class Inner
         def k
           Other.v
         end
       end
     end
   RUBY
   ['M::Inner.new.k']]
]

def run_ruby(runner, files, probes)
  env = { 'FILES' => JSON.generate(files), 'PROBES' => JSON.generate(probes) }
  out, err, status = Open3.capture3(env, RbConfig.ruby, runner)
  # A load that raises is an outcome like any other: it must match the original's outcome.
  status.success? ? out : "RAISED #{err.lines.grep(/Error/).first&.strip}"
end

# Residual texts for a fixture: the planner's rewrite of each file, applied as the build applies it.
def residual(fixture_files, dir)
  paths = fixture_files.map do |name, source|
    path = File.join(dir, name)
    File.write(path, source)
    path
  end
  plan = LoadCompile.plan({ 'fx' => paths }, gem: 'fx', drop_keys: Set.new, symbol: 'fx')
  texts = paths.map { |path| LoadCompile.apply(File.binread(path), plan.ranges.fetch(path, [])) }
  removed, = LoadCompile.path_form_sets
  [paths, texts, removed.size]
end

def evaluate(texts_by_name, probes, dir, runner)
  out_dir = Dir.mktmpdir('pf', dir)
  files = texts_by_name.map do |name, text|
    path = File.join(out_dir, name)
    File.binwrite(path, text)
    path
  end
  run_ruby(runner, files, probes)
end

def run_fixtures(dir, runner)
  FIXTURES.map do |name, expect, files, probes|
    fdir = Dir.mktmpdir('fx', dir)
    paths, texts, removed = residual(files, fdir)
    original = files.to_h
    residual_texts = files.zip(texts).to_h { |(fname, _), t| [fname, t] }
    a = evaluate(original, probes, dir, runner)
    b = evaluate(residual_texts, probes, dir, runner)
    { name: name, expect: expect, removed: removed, same: a == b, original: a, residual: b }
  end
end

def mutant_detected?(name, dir, runner)
  # Run in a fresh process with the rule turned off: the process prints whether any fixture changed.
  env = { 'PATH_FORM_MUTANT' => name }
  out, status = Open3.capture2(env, RbConfig.ruby, __FILE__, '--mutant-probe', dir, runner)
  status.success? && out.include?('DIFFERS')
end

def apply_mutant(name)
  case name
  when 'cref' then LoadCompile.define_singleton_method(:cref_conflict?) { |_refs, _lost| false }
  when 'first_segment' then LoadCompile.define_singleton_method(:first_segment_conflict?) { |_f, _n| false }
  when 'prereq' then LoadCompile.define_singleton_method(:created_before?) { |_ub, _created| true }
  when 'plain' then LoadCompile.define_singleton_method(:plain_scopes) { |_all| Hash.new(true) }
  when 'reflective' then LoadCompile.define_singleton_method(:reflective_world?) { |_all| false }
  else raise "unknown mutant #{name}"
  end
end

if ARGV[0] == '--mutant-probe'
  dir, runner = ARGV[1], ARGV[2]
  apply_mutant(ENV.fetch('PATH_FORM_MUTANT'))
  results = run_fixtures(dir, runner)
  puts(results.any? { |r| !r[:same] } ? 'DIFFERS' : 'SAME')
  exit 0
end

Dir.mktmpdir('path_form_check') do |dir|
  runner = File.join(dir, 'runner.rb')
  File.write(runner, RUNNER)
  results = run_fixtures(dir, runner)
  results.each do |r|
    removal = r[:expect] == :accept ? r[:removed].positive? : r[:removed].zero?
    suite.check("#{r[:name]}: #{r[:removed]} header(s) removed, residual #{r[:same] ? 'loads' : 'DIFFERS from'} the original",
                removal && r[:same])
  end
  suite.check("accept fixtures remove a header and refuse fixtures remove none (#{results.count { |r| r[:expect] == :accept }} " \
              "accept, #{results.count { |r| r[:expect] == :refuse }} refuse)",
              results.all? { |r| r[:expect] == :accept ? r[:removed].positive? : r[:removed].zero? })

  %w[cref first_segment prereq plain reflective].each do |mutant|
    suite.check("mutant #{mutant} (rule off) changes the results of a fixture", mutant_detected?(mutant, dir, runner))
  end
end

suite.finish!
