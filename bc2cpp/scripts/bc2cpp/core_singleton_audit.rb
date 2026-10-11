#!/usr/bin/env ruby
# frozen_string_literal: true

# CORE_BODY_EXACT audit (docs/adr/0359). ClosedWorld#exact_instances_singleton_free? scans the
# engine's own Ruby, and the one source it skips is mruby's core Ruby (ADR 0280), which is compiled
# into the same VM. A core body's receiver proof relies on that Ruby never giving an Array, Hash,
# Range or String a singleton class or a mixin, and the generated class test (ADR 0359) turns a
# violation into BC2cppGuardViolation. This check keeps the assumption from being a grep: every
# singleton-making construct in a core Ruby source (and in an external gem's C source) must be a
# reviewed site below, a site that is not listed fails, and so does a listed one that is gone.
#
# A construct is: a call of instance_eval, instance_exec, singleton_class, define_singleton_method,
# extend (also as a symbol argument, for `send(:extend, ...)`), `class << expr` other than `class << self`
# in a class body, and `def expr.name` for a non-self expr.
#
#   ruby scripts/bc2cpp/core_singleton_audit.rb          # check
#   ruby scripts/bc2cpp/core_singleton_audit.rb --list   # print the keys found
#
# Needs 3rd/mruby (and the external gems); skips without it.

require 'prism'
require_relative '../../tools/bc2cpp/compiled_gems'

ROOT = File.expand_path('../..', __dir__)

MAKERS = %w[instance_eval instance_exec singleton_class define_singleton_method extend].freeze
NATIVE_MAKER = /\bmrb_singleton_class(?:_ptr|_clone)?\b|\bmrb_define_singleton_method(?:_id)?\b|\bmrb_obj_extend\b/

# "path-from-3rd :: construct" => why its receiver is never an Array, Hash, Range or String.
REVIEWED = {
  'mruby/mrbgems/mruby-enumerator/mrblib/enumerator.rb :: instance_eval obj' =>
    'obj is an Enumerator: initialize_copy checks kind_of? Enumerator, Enumerator#each dups self',
  'mruby/mrbgems/mruby-enum-lazy/mrblib/lazy.rb :: instance_eval lz' => 'lz is the Enumerator::Lazy it just built',
  'mruby/mrbgems/mruby-socket/mrblib/socket.rb :: instance_eval s' => 's is a TCPSocket it just allocated',
  'mruby/mrbgems/mruby-enumerator/mrblib/enumerator.rb :: def Enumerator.produce' => 'the Enumerator class',
  'mruby/mrbgems/mruby-errno/mrblib/errno.rb :: def Errno.const_defined?' => 'the Errno module',
  'mruby/mrbgems/mruby-errno/mrblib/errno.rb :: def Errno.const_missing' => 'the Errno module',
  'mruby/mrbgems/mruby-errno/mrblib/errno.rb :: def Errno.constants' => 'the Errno module'
}.freeze

def source_files
  srcs = foreign_mrblib_srcs(ROOT).sort
  srcs.map { |path| [path, path.delete_prefix("#{ROOT}/3rd/")] }
end

def native_files
  %w[mruby-stringio mruby-marshal mruby-onig-regexp].flat_map { |gem| Dir["#{ROOT}/3rd/#{gem}/src/**/*.{c,cc,cpp,cxx,h}"] }.sort
end

# Walks a Prism tree, yielding every node and whether it sits inside a method body (where `self`
# is an instance, not a class body or main).
def each_node(node, in_def = false, &block)
  block.call(node, in_def)
  inner = in_def || node.is_a?(Prism::DefNode)
  node.compact_child_nodes.each { |child| each_node(child, inner, &block) }
end

def receiver_text(node, source)
  node ? source.byteslice(node.location.start_offset, node.location.length) : 'self'
end

def constructs_in(path, display)
  source = File.read(path)
  result = Prism.parse(source)
  raise "#{display}: #{result.errors.map(&:message).join('; ')}" unless result.success?

  found = []
  each_node(result.value) do |node, in_def|
    case node
    when Prism::CallNode
      if MAKERS.include?(node.name.to_s)
        found << "#{display} :: #{node.name} #{receiver_text(node.receiver, source)}"
      else
        # send(:extend, x) and friends: a maker named by symbol.
        node.arguments&.arguments&.each do |arg|
          found << "#{display} :: #{arg.unescaped} (symbol)" if arg.is_a?(Prism::SymbolNode) && MAKERS.include?(arg.unescaped)
        end
      end
    when Prism::SingletonClassNode
      # `class << self` in a class body or at the top level opens the class's or main's own singleton.
      found << "#{display} :: class << #{receiver_text(node.expression, source)}" unless node.expression.is_a?(Prism::SelfNode) && !in_def
    when Prism::DefNode
      found << "#{display} :: def #{receiver_text(node.receiver, source)}.#{node.name}" if node.receiver && !node.receiver.is_a?(Prism::SelfNode)
    end
  end
  found
end

def audit
  keys = source_files.flat_map { |path, display| constructs_in(path, display) }
  natives = native_files.flat_map do |path|
    File.read(path).scan(NATIVE_MAKER).uniq.map { |name| "#{path.delete_prefix("#{ROOT}/3rd/")} :: native #{name}" }
  end
  (keys + natives).uniq.sort
end

# The scanner itself: every construct it is meant to find, and the ones it must leave alone.
require 'tmpdir'
Dir.mktmpdir do |dir|
  sample = File.join(dir, 'sample.rb')
  File.write(sample, <<~RUBY)
    class K
      class << self; def ok; end; end
      def self.fine; end
      def a(x, y); x.instance_eval { 1 }; y.extend(Mod); x.singleton_class; x.define_singleton_method(:m) { }; end
      def b(x); send(:extend, x); class << x; end; def x.m; end; end
      def c; class << self; end; end
    end
  RUBY
  found = constructs_in(sample, 's').to_set
  wanted = ['s :: instance_eval x', 's :: extend y', 's :: singleton_class x', 's :: define_singleton_method x', 's :: extend (symbol)',
            's :: class << x', 's :: def x.m', 's :: class << self'].to_set
  unless found == wanted
    abort "bc2cpp core singleton audit: the scanner is broken, found #{found.to_a.sort} (wanted #{wanted.to_a.sort})"
  end
end

unless File.directory?(File.join(ROOT, '3rd/mruby/mrblib'))
  puts 'bc2cpp core singleton audit: SKIP (no 3rd/mruby)'
  exit 0
end

found = audit
if ARGV.include?('--list')
  puts found
  exit 0
end

failures = []
found.each do |key|
  next if REVIEWED.key?(key)

  failures << "unreviewed singleton-making construct in core Ruby/native: #{key}"
end
(REVIEWED.keys - found).each { |key| failures << "stale reviewed entry (no such construct any more): #{key}" }

if failures.empty?
  puts "bc2cpp core singleton audit: PASS (#{found.size} reviewed site(s) in #{source_files.size} Ruby and #{native_files.size} native sources)"
else
  warn failures
  abort "bc2cpp core singleton audit: #{failures.size} failure(s) (docs/adr/0359)"
end
