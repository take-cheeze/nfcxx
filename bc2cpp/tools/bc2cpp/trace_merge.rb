# frozen_string_literal: true

require 'rbs'
require 'set'

# TraceMerge: compares the trace candidates (scripts/bc2cpp/trace_types.rb candidates) with the committed declarations
# and proposes only what the committed file does not already declare. A proposal is never written into
# sig/bc2cpp/declarations.rbs, and a proposal file must not live under sig/: rbs_signatures.rb loads every sig/**/*.rbs,
# so anything there becomes a hint. Promotion into the loaded file stays a reviewed step.
module TraceMerge
  Member = Struct.new(:owner, :singleton, :name, :signature) do
    def key
      [owner, singleton, name]
    end

    def render
      head = singleton ? "def self.#{name}" : "def #{name}"
      "  #{head}: #{signature}\n"
    end
  end

  Result = Struct.new(:proposed, :same, :conflicts, :skipped_interfaces)

  module_function

  # Every method of every class or module in RBS text, with its owner's full name. Interfaces are counted, not read: a
  # candidate interface names no class to add to.
  def members(text)
    _buf, _dirs, decls = RBS::Parser.parse_signature(RBS::Buffer.new(name: 'trace.rbs', content: text))
    found = []
    interfaces = 0
    walk = lambda do |owner, nodes|
      nodes.each do |node|
        case node
        when RBS::AST::Declarations::Class, RBS::AST::Declarations::Module
          name = [owner, node.name.to_s.delete_prefix('::')].reject(&:empty?).join('::')
          walk.call(name, node.members)
        when RBS::AST::Declarations::Interface
          interfaces += 1
        when RBS::AST::Members::MethodDefinition
          signature = node.overloads.map { |o| o.method_type.to_s }.join(' | ')
          found << Member.new(owner, node.singleton?, node.name.to_s, signature)
        end
      end
    end
    walk.call('', decls)
    [found, interfaces]
  end

  # Candidates against declarations: `proposed` are methods the declarations do not name at all, `same` are named with the
  # same signature already, `conflicts` are named with a different one (the declared signature is kept, the candidate is
  # reported).
  def compare(candidates_text, declarations_text)
    cands, interfaces = members(candidates_text)
    declared = members(declarations_text).first.group_by(&:key)
    result = Result.new([], [], [], interfaces)
    cands.each do |cand|
      existing = declared[cand.key]
      if existing.nil?
        result.proposed << cand
      elsif existing.any? { |m| m.signature == cand.signature }
        result.same << cand
      else
        result.conflicts << [cand, existing.map(&:signature)]
      end
    end
    result
  end

  # The proposals as RBS text, grouped by owner. Only `proposed` members are written.
  def render(proposed)
    header = "# Trace proposals (scripts/bc2cpp/trace_merge.rb). Not loaded by bc2cpp: this file is outside sig/, and a\n" \
             "# method moves into sig/bc2cpp/declarations.rbs only after review.\n"
    body = proposed.group_by(&:owner).sort.map do |owner, list|
      "class #{owner}\n" + list.sort_by { |m| [m.singleton ? 0 : 1, m.name] }.map(&:render).join + "end\n"
    end
    header + body.join("\n")
  end
end
