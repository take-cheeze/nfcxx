#!/usr/bin/env ruby
# frozen_string_literal: true

# Base RBS for Ruby sources: one stub per class or module, from the AST (Prism), with no types guessed.
#
#   ruby scripts/bc2cpp/base_rbs.rb OUT_DIR SRC.rb...
#
# Each class or module the sources define becomes `class X < Super` / `module X` with every method's shape:
# the required, optional, rest, keyword and block parameters as `untyped`, so the arity is right and the types are
# not claimed. `def self.x` is a singleton method; `attr_reader` / `attr_accessor` / `attr_writer` declare their
# accessors. A name that is not a plain identifier (an operator, `[]`, `x=`) is skipped and listed, since RBS would
# need its own syntax for it. Every file is parsed with the rbs gem before it is written.
#
# This replaces the names-only pass in class_hierarchy.rb for the signatures; class_hierarchy.rb is still the
# hierarchy the review candidates use.

require 'prism'
require 'fileutils'
require 'set'

module BaseRbs
  IDENT = /\A[a-z_]\w*[?!]?\z/i.freeze
  # Method names RBS spells: identifiers, setters, `[]` / `[]=`, and the operators.
  METHOD_NAME = %r{\A(?:\[\]=?|[a-z_]\w*[?!=]?|[+\-*/%<>=!~^&|]+@?)\z}i.freeze

  Klass = Struct.new(:name, :kind, :super_expr, :nest, :methods, :singletons, :accessors)

  module_function

  def const_path(node)
    case node
    when Prism::ConstantReadNode then node.name.to_s
    when Prism::ConstantPathNode
      return "::#{node.child.name}" if node.parent.nil?

      "#{const_path(node.parent)}::#{node.child.name}"
    end
  end

  def scan(path, decls, skipped)
    walk(Prism.parse_file(path).value, [], decls, skipped)
  end

  def walk(node, nest, decls, skipped)
    case node
    when Prism::ClassNode, Prism::ModuleNode
      name = const_path(node.constant_path)
      full = (nest + [name]).join('::')
      decl = decls[full] ||= Klass.new(full, node.is_a?(Prism::ClassNode) ? 'class' : 'module',
                                       nil, nest.dup, [], [], [])
      decl.super_expr = const_path(node.superclass) if node.is_a?(Prism::ClassNode) && node.superclass
      node.body&.then { |b| walk(b, nest + [name], decls, skipped) }
      return
    when Prism::DefNode
      owner = nest.join('::')
      decl = decls[owner]
      if decl
        target = node.receiver ? decl.singletons : decl.methods
        if node.name.to_s.match?(METHOD_NAME)
          target << [node.name.to_s, shape(node.parameters)]
        else
          skipped << "#{owner}##{node.name}"
        end
      end
      return
    when Prism::CallNode
      owner = nest.join('::')
      decl = decls[owner]
      if decl && node.receiver.nil? && %w[attr_reader attr_accessor attr_writer].include?(node.name.to_s)
        (node.arguments&.arguments || []).each do |arg|
          next unless arg.is_a?(Prism::SymbolNode)

          attr = arg.unescaped
          decl.accessors << [attr, node.name.to_s] if attr.match?(IDENT)
        end
      end
    end
    node.compact_child_nodes.each { |child| walk(child, nest, decls, skipped) }
  end

  # The parameter shape of a method: `untyped` per parameter, in order, with the optional and keyword forms.
  def shape(params)
    return [] unless params

    out = []
    params.requireds.each { out << ['req', nil] }
    params.optionals.each { out << ['opt', nil] }
    out << ['rest', nil] if params.rest.is_a?(Prism::RestParameterNode)
    params.posts.each { out << ['req', nil] }
    (params.keywords || []).each do |kw|
      next unless kw.respond_to?(:name)

      out << [kw.is_a?(Prism::RequiredKeywordParameterNode) ? 'kwreq' : 'kwopt', kw.name.to_s]
    end
    out << ['kwrest', nil] if params.keyword_rest.is_a?(Prism::KeywordRestParameterNode)
    out << ['block', nil] if params.block.is_a?(Prism::BlockParameterNode)
    out
  end

  # Attribute readers whose stored value the program always sets to one class (mruby-rgss/mrblib/lib.rb).
  ATTR_RETURNS = {
    ['RGSS::Plane', 'ox'] => 'Integer', ['RGSS::Plane', 'oy'] => 'Integer',
    ['RGSS::Tilemap', 'ox'] => 'Integer', ['RGSS::Tilemap', 'oy'] => 'Integer',
    ['RGSS::Window', 'ox'] => 'Integer', ['RGSS::Window', 'oy'] => 'Integer',
    ['RGSS::Window', 'contents'] => 'RGSS::Bitmap'
  }.freeze

  def method_line(name, shape, singleton: false)
    positional = []
    shape.each do |kind, _|
      case kind
      when 'req' then positional << 'untyped'
      when 'opt' then positional << '?untyped'
      when 'rest' then positional << '*untyped'
      end
    end
    keywords = shape.filter_map do |kind, kw|
      case kind
      when 'kwreq' then "#{kw}: untyped"
      when 'kwopt' then "?#{kw}: untyped"
      when 'kwrest' then '**untyped'
      end
    end
    params = (positional + keywords).join(', ')
    "def #{singleton ? 'self.' : ''}#{name}: (#{params}) -> untyped"
  end

  # A member line the RBS parser rejects is dropped (and counted), so the file always parses.
  def valid_member?(line)
    require 'rbs'
    RBS::Parser.parse_signature("class X\n  #{line}\nend\n")
    true
  rescue RBS::ParsingError
    false
  end

  def render(decls)
    decls.values.sort_by(&:name).map do |d|
      head = if d.kind == 'module' then "module #{d.name}"
             else
               d.super_expr ? "class #{d.name} < #{d.super_expr}" : "class #{d.name}"
             end
      body = []
      d.accessors.each do |attr, kind|
        body << "def #{attr}: () -> #{ATTR_RETURNS.fetch([d.name, attr], 'untyped')}" if %w[attr_reader attr_accessor].include?(kind)
        body << "def #{attr}=: (untyped) -> untyped" if %w[attr_writer attr_accessor].include?(kind)
      end
      d.methods.uniq { |m, _| m }.sort_by { |m, _| m }.each { |m, shape| body << method_line(m, shape) }
      d.singletons.uniq { |m, _| m }.sort_by { |m, _| m }.each { |m, shape| body << method_line(m, shape, singleton: true) }
      body = body.select { |line| valid_member?(line) }
      "#{head}\n#{body.map { |l| "  #{l}\n" }.join}end\n"
    end
  end

  # A superclass is looked up the way Ruby looks a constant up: the innermost enclosing namespace first, then outward,
  # then the top level. RBS resolves a name in the declaration's own scope, so the resolved full name is written. A name
  # the sources do not define is written as it is (an external class such as File).
  def resolve_super(expr, nest, decls)
    return expr.delete_prefix('::') if expr.start_with?('::')

    nest.length.downto(0) do |i|
      candidate = (nest[0, i] + [expr]).join('::')
      return candidate if decls.key?(candidate)
    end
    expr
  end

  def run(out_dir, paths)
    decls = {}
    skipped = []
    paths.each { |path| scan(path, decls, skipped) }
    decls.each_value { |decl| decl.super_expr = resolve_super(decl.super_expr, decl.nest, decls) if decl.super_expr }
    # Object is the superclass a class gets when none is written, so the stub omits it, as the Ruby source does.
    decls.each_value { |decl| decl.super_expr = nil if decl.super_expr == 'Object' }
    FileUtils.mkdir_p(out_dir)
    files = []
    decls.values.group_by { |d| d.name.split('::').first }.each do |top, list|
      text = render(list.to_h { |d| [d.name, d] }).join("\n")
      path = File.join(out_dir, "#{top}.rbs")
      File.write(path, "# Base RBS (scripts/bc2cpp/base_rbs.rb): shapes from the AST, no types.\n#{text}")
      files << path
    end
    [files, skipped]
  end
end

if $PROGRAM_NAME == __FILE__
  abort 'usage: base_rbs.rb OUT_DIR SRC.rb...' if ARGV.size < 2

  files, skipped = BaseRbs.run(ARGV.shift, ARGV)
  warn "base_rbs: wrote #{files.size} file(s), skipped #{skipped.size} non-identifier method(s)"
  skipped.first(10).each { |s| warn "  skipped #{s}" }
end
