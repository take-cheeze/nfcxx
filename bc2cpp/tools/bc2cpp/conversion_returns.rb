# frozen_string_literal: true

require 'fileutils'
require 'prism'
require 'tmpdir'
require_relative 'ruby_parse_cache'

# ConversionReturns: the instance methods the language calls to convert an object (to_s for interpolation and join,
# to_str, to_int, to_ary, to_hash for implicit conversions) return the class mruby expects. Such a method takes only
# optional positional parameters, so a call the language makes with no arguments always reaches it.
#
# Its return is declared as a runtime-checked hint (%a{bc2cpp:hint}, ADR 0455): a method whose return the compiler can
# prove is the declared class costs nothing, and any other value raises BC2cppHintViolation when it runs. A conversion
# method with a required parameter, a rest parameter or a keyword is a build error, because the hint would not apply.
module ConversionReturns
  RETURNS = { to_s: 'String', to_str: 'String', to_int: 'Integer', to_ary: 'Array', to_hash: 'Hash' }.freeze

  Found = Struct.new(:path, :owner, :kind, :node)

  module_function

  # Every conversion method of one source text, with the lexical owner path and whether it sits in a class or a module.
  def found_in(path, source = nil)
    parsed = source ? RubyParseCache.parse(source, path) : RubyParseCache.parse_file(path)
    out = []
    walk = lambda do |node, owner, kind|
      case node
      when Prism::ClassNode, Prism::ModuleNode
        inner = [owner, node.constant_path.slice].compact.join('::')
        node.compact_child_nodes.each { |child| walk.call(child, inner, node.is_a?(Prism::ClassNode) ? 'class' : 'module') }
        next
      when Prism::DefNode
        out << Found.new(path, owner || 'Object', kind || 'class', node) if RETURNS.key?(node.name) && node.receiver.nil?
      end
      node.compact_child_nodes.each { |child| walk.call(child, owner, kind) }
    end
    walk.call(parsed.value, nil, nil)
    out
  end

  # The problems with one conversion method's parameters, as messages. Only optional positional parameters are allowed.
  def parameter_problems(node)
    params = node.parameters
    return [] if params.nil?

    problems = []
    problems << 'a required parameter' unless params.requireds.empty? && params.posts.empty?
    problems << 'a rest parameter' if params.rest && !params.rest.is_a?(Prism::ImplicitRestNode)
    problems << 'a keyword parameter' unless params.keywords.empty? && params.keyword_rest.nil?
    problems
  end

  # Build gate: a conversion method with a parameter other than an optional positional one raises, naming the method.
  def enforce!(paths)
    problems = paths.flat_map do |path|
      found_in(path).flat_map do |f|
        parameter_problems(f.node).map { |p| "  #{f.path}:#{f.node.location.start_line}: #{f.owner}##{f.node.name} takes #{p}" }
      end
    end
    return if problems.empty?

    raise "bc2cpp: conversion methods take only optional positional parameters (to_s, to_str, to_int, to_ary, to_hash):\n" \
          "#{problems.join("\n")}"
  end

  # The RBS that declares each conversion method's return as a runtime-checked hint, or nil when there is none. The
  # optional positional parameters are written as `?untyped`; the hint keeps the method's own arity.
  def rbs_text(paths)
    found = paths.flat_map { |path| found_in(path) }.reject { |f| parameter_problems(f.node).any? }
    return nil if found.empty?

    by_owner = found.group_by { |f| [f.kind, f.owner] }
    by_owner.map do |(kind, owner), methods|
      body = methods.uniq { |f| f.node.name }.map do |f|
        optional = f.node.parameters&.optionals&.size.to_i
        params = Array.new(optional) { '?untyped' }.join(', ')
        "  %a{bc2cpp:hint}\n  def #{f.node.name}: (#{params}) -> #{RETURNS.fetch(f.node.name)}\n"
      end.join
      "#{kind} #{owner}\n#{body}end\n"
    end.join("\n")
  end

  # Writes rbs_text to a directory of this process and returns the file's path, or nil when no conversion method exists.
  # Not written beside the sources, which the build compiles from.
  def write_sigs(paths)
    text = rbs_text(paths)
    return nil unless text

    dir = Dir.mktmpdir('bc2cpp-conversion-sigs')
    at_exit { FileUtils.rm_rf(dir) }
    path = File.join(dir, 'conversion_returns.rbs')
    File.write(path, "# Conversion return hints (tools/bc2cpp/conversion_returns.rb), generated from the program sources.\n#{text}")
    path
  end
end
