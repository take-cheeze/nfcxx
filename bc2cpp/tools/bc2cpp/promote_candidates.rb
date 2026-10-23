# frozen_string_literal: true

require 'rbs'
require 'set'

# PromoteCandidates: the reviewed step from candidate RBS to a checked-in signature file.
#
# A candidate directory is what `scripts/bc2cpp/type_check.rb --emit-rbs DIR` or `--emit-rbs-suggestions DIR` writes:
# one `.rbs` per class / module. Promotion adds to the target only what the target does not declare yet:
#   * a method, ivar or constant whose name the target already declares (in any section) is left alone, so an existing
#     declaration is never changed or removed;
#   * a member whose required parameter, keyword, return, ivar or constant type is `untyped`, or names a type that
#     neither the target nor CRuby's core RBS declares, is skipped and listed. Optional, rest and block parts are not
#     checked: the emitter writes `untyped` there for every method;
#   * a new class whose superclass is undeclared is skipped as a whole.
# Promoted members are appended after the last section under a `# ---- promoted candidates: DIR` heading, as reopened
# `class` / `module` blocks. The base section (everything before `# ---- block_types.rbs`) is generator output and is
# never written. The result must parse with RBS before it is written, and the written file is parsed again.
module PromoteCandidates
  class Refusal < StandardError; end

  END_MARKER = '# ---- block_types.rbs'
  # Lines only the base generators write: a candidate carrying one would land in the base section.
  BASE_MARKER = /^# (?:bc2cpp-native: |Base RBS|Native base RBS|---- base stubs|---- block_types\.rbs)/
  DATE = /\d{4}-\d{2}-\d{2}/
  CONTEXT = 3
  KINDS = { instance: [:instance], singleton: [:singleton], singleton_instance: %i[instance singleton] }.freeze
  PLAIN = [RBS::Types::Bases::Bool, RBS::Types::Bases::Nil, RBS::Types::Bases::Top, RBS::Types::Bases::Bottom,
           RBS::Types::Bases::Self, RBS::Types::Bases::Instance, RBS::Types::Bases::Class,
           RBS::Types::Bases::Void, RBS::Types::Literal].freeze

  # One member the candidate offers: its declaration key, its RBS line, and why it cannot be promoted (or nil).
  Item = Struct.new(:key, :line, :label, :problem, keyword_init: true)
  # added: [class, line]; skipped: [label, reason]; already: count; text: the target with the promoted section appended.
  Plan = Struct.new(:text, :added, :skipped, :already, keyword_init: true)

  # The members the target declares for one class or module name. Reopened declarations and base-section
  # declarations share one entry.
  class Index
    Entry = Struct.new(:kind, :superclass, :methods, :ivars, :consts, keyword_init: true)

    def initialize(decls)
      @entries = {}
      walk(decls, nil)
    end

    def entry(name)
      @entries[name]
    end

    def declared?(name)
      @entries.key?(name)
    end

    def declare(name, kind, superclass)
      @entries[name] ||= Entry.new(kind: kind, superclass: superclass, methods: Set.new, ivars: Set.new, consts: Set.new)
    end

    private

    def walk(decls, prefix)
      decls.each do |decl|
        next unless decl.is_a?(RBS::AST::Declarations::Class) || decl.is_a?(RBS::AST::Declarations::Module)

        full = PromoteCandidates.qualified(decl.name, prefix)
        superclass = decl.is_a?(RBS::AST::Declarations::Class) && decl.super_class ? PromoteCandidates.name_string(decl.super_class.name) : nil
        kind = decl.is_a?(RBS::AST::Declarations::Module) ? :module : :class
        entry = declare(full, kind, superclass)
        entry.superclass ||= superclass
        decl.members.each do |member|
          if member.is_a?(RBS::AST::Declarations::Class) || member.is_a?(RBS::AST::Declarations::Module)
            walk([member], full)
          else
            record(entry, member)
          end
        end
      end
    end

    def record(entry, member)
      case member
      when RBS::AST::Members::MethodDefinition
        PromoteCandidates.kinds(member.kind).each { |k| entry.methods << [member.name, k] }
      when RBS::AST::Members::AttrReader
        entry.methods << [member.name, :instance]
      when RBS::AST::Members::AttrWriter
        entry.methods << [:"#{member.name}=", :instance]
      when RBS::AST::Members::AttrAccessor
        entry.methods << [member.name, :instance]
        entry.methods << [:"#{member.name}=", :instance]
      when RBS::AST::Members::InstanceVariable
        entry.ivars << member.name.to_s
      when RBS::AST::Declarations::Constant
        entry.consts << member.name.name.to_s
      end
    end
  end

  module_function

  def qualified(name, prefix)
    return name.to_s.delete_prefix('::') if name.absolute?

    [prefix, name.to_s].compact.join('::')
  end

  def name_string(name)
    name.to_s.delete_prefix('::')
  end

  def kinds(kind)
    KINDS.fetch(kind)
  end

  # CRuby's core RBS class and module names. A candidate may name these without the target declaring them.
  def core_names
    @core_names ||= RBS::Environment.from_loader(RBS::EnvironmentLoader.new)
                                    .resolve_type_names.class_decls.keys.map { |n| name_string(n) }.to_set
  end

  def parse(text)
    RBS::Parser.parse_signature(text)[2]
  end

  # nil when the text parses with RBS, otherwise the parser's message.
  def verify(text)
    parse(text)
    nil
  rescue RBS::ParsingError => e
    e.message
  end

  # The post-write check: the file as it is on disk must still parse.
  def written_error(path)
    verify(File.read(path))
  end

  # The leading comment lines of a candidate file, without dates (a date would make every promotion a diff). nil when
  # the file opens with no comment.
  def provenance_lines(text)
    lines = []
    text.each_line do |line|
      stripped = line.strip
      next if stripped.empty? && lines.empty?
      break unless stripped.empty? || stripped.start_with?('#')

      lines << stripped unless stripped.empty? || DATE.match?(stripped)
    end
    lines.empty? ? nil : lines
  end

  # The type problem of a candidate type, or nil. The first problem found is reported.
  def type_problem(type, declared)
    case type
    when RBS::Types::Bases::Any then 'untyped'
    when RBS::Types::ClassInstance, RBS::Types::ClassSingleton
      name = name_string(type.name)
      return "#{name} is not declared by the target" unless declared.call(name)

      type.respond_to?(:args) ? first_problem(type.args, declared) : nil
    when RBS::Types::Union, RBS::Types::Intersection, RBS::Types::Tuple then first_problem(type.types, declared)
    when RBS::Types::Optional then type_problem(type.type, declared)
    when RBS::Types::Record then first_problem(type.fields.values, declared)
    when RBS::Types::Proc then function_problem(type.type, declared)
    when *PLAIN then nil
    else "#{type} is not supported"
    end
  end

  def first_problem(types, declared)
    types.each do |type|
      problem = type_problem(type, declared)
      return problem if problem
    end
    nil
  end

  # Required positionals, keywords and the return. The emitter's optional, rest, trailing and block parts are
  # `untyped` placeholders, so they are not checked.
  def function_problem(fn, declared)
    types = fn.required_positionals.map(&:type) + fn.required_keywords.values.map(&:type) +
            fn.optional_keywords.values.map(&:type) + [fn.return_type]
    first_problem(types, declared)
  end

  def method_problem(member, declared)
    member.overloads.each do |overload|
      problem = function_problem(overload.method_type.type, declared)
      return problem if problem
    end
    nil
  end

  # The items a member offers, or nil for a member kind the promotion does not write.
  def member_items(member, owner, declared)
    case member
    when RBS::AST::Members::MethodDefinition
      problem = method_problem(member, declared)
      rendered = member.overloads.map { |o| o.method_type.to_s }.join(' | ')
      kinds(member.kind).map do |kind|
        prefix = kind == :singleton ? 'self.' : ''
        Item.new(key: [:method, member.name, kind], line: "def #{prefix}#{member.name}: #{rendered}",
                 label: "#{owner}#{kind == :singleton ? '.' : '#'}#{member.name}", problem: problem)
      end
    when RBS::AST::Members::InstanceVariable
      [Item.new(key: [:ivar, member.name.to_s], line: "#{member.name}: #{member.type}",
                label: "#{owner}##{member.name}", problem: type_problem(member.type, declared))]
    when RBS::AST::Declarations::Constant
      name = member.name.name.to_s
      [Item.new(key: [:const, name], line: "#{name}: #{member.type}", label: "#{owner}::#{name}",
                problem: type_problem(member.type, declared))]
    end
  end

  def present?(entry, key)
    return false unless entry

    case key.first
    when :method then entry.methods.include?([key[1], key[2]])
    when :ivar then entry.ivars.include?(key[1])
    when :const then entry.consts.include?(key[1])
    end
  end

  def add_key(entry, key)
    case key.first
    when :method then entry.methods << [key[1], key[2]]
    when :ivar then entry.ivars << key[1]
    when :const then entry.consts << key[1]
    end
  end

  # Every class or module of a candidate file with its own members (nested declarations are returned separately).
  def candidate_classes(decls, prefix = nil, out = [])
    decls.each do |decl|
      next unless decl.is_a?(RBS::AST::Declarations::Class) || decl.is_a?(RBS::AST::Declarations::Module)

      full = qualified(decl.name, prefix)
      out << [full, decl]
      candidate_classes(decl.members.select { |m| m.is_a?(RBS::AST::Declarations::Class) || m.is_a?(RBS::AST::Declarations::Module) }, full, out)
    end
    out
  end

  def valid_line?(line)
    verify("class X\n  #{line}\nend\n").nil?
  end

  # Plans the promotion of CANDIDATE_DIR into TARGET_TEXT. Raises Refusal on any condition that must stop the whole run.
  def plan(target_text, candidate_dir, target_label: 'target')
    dirname = File.basename(File.expand_path(candidate_dir))
    cut = target_text.index(END_MARKER)
    raise Refusal, "#{target_label} has no `#{END_MARKER}` line, so its base section cannot be told apart" unless cut

    error = verify(target_text)
    raise Refusal, "#{target_label} does not parse (#{error}); nothing was promoted" if error

    index = Index.new(parse(target_text))
    files = Dir.glob(File.join(candidate_dir, '**', '*.rbs')).sort
    raise Refusal, "no .rbs candidates under #{candidate_dir}" if files.empty?

    declared = ->(name) { index.declared?(name) || core_names.include?(name) }
    result = Plan.new(text: target_text, added: [], skipped: [], already: 0)
    blocks = []
    files.each do |path|
      rel = path.delete_prefix(File.join(candidate_dir, ''))
      text = File.read(path)
      marker = text.each_line.find { |line| BASE_MARKER.match?(line) }
      if marker
        raise Refusal, "#{dirname}/#{rel} has base-section line #{marker.strip.inspect}: it would land in the base " \
                       'section, which scripts/bc2cpp/base_section_check.rb owns; nothing was promoted'
      end

      begin
        decls = parse(text)
      rescue RBS::ParsingError => e
        raise Refusal, "candidate #{dirname}/#{rel} does not parse (#{e.message}); nothing was promoted"
      end
      provenance = provenance_lines(text) || ["# candidate: #{dirname}/#{rel}"]
      decls.each do |decl|
        next if decl.is_a?(RBS::AST::Declarations::Class) || decl.is_a?(RBS::AST::Declarations::Module)

        result.skipped << ["#{dirname}/#{rel}", "#{decl.class.name.split('::').last} declarations are not promoted"]
      end
      candidate_classes(decls).each do |full, decl|
        block = promote_class(full, decl, index, declared, result, provenance)
        blocks << block if block
      end
    end
    return result if blocks.empty?

    base = target_text.end_with?("\n") ? target_text : "#{target_text}\n"
    new_text = "#{base}\n# ---- promoted candidates: #{dirname}\n#{blocks.join("\n")}"
    raise Refusal, 'the promoted section would change the base section' unless new_text[0...cut] == target_text[0...cut]

    error = verify(new_text)
    raise Refusal, "the promoted text does not parse (#{error}); nothing was written" if error

    result.text = new_text
    result
  end

  # Adds the absent, typeable members of one candidate class to the plan. Returns its block, or nil when nothing is added.
  def promote_class(full, decl, index, declared, result, provenance)
    kind = decl.is_a?(RBS::AST::Declarations::Module) ? :module : :class
    superclass = kind == :class && decl.super_class ? name_string(decl.super_class.name) : nil
    entry = index.entry(full)
    core = core_names.include?(full)
    if entry && entry.kind != kind
      result.skipped << [full, "the target declares it as a #{entry.kind}, the candidate as a #{kind}"]
      return nil
    end
    if entry && superclass && entry.superclass && superclass != entry.superclass
      result.skipped << [full, "the target's superclass is #{entry.superclass}, the candidate's is #{superclass}"]
      return nil
    end
    if !entry && !core && superclass && !declared.call(superclass)
      result.skipped << [full, "superclass #{superclass} is not declared by the target"]
      return nil
    end

    reopened = entry || core
    public_lines = []
    private_lines = []
    visibility = :public
    decl.members.each do |member|
      if member.is_a?(RBS::AST::Members::Private)
        visibility = :private
        next
      elsif member.is_a?(RBS::AST::Members::Public)
        visibility = :public
        next
      elsif member.is_a?(RBS::AST::Declarations::Class) || member.is_a?(RBS::AST::Declarations::Module)
        next
      end

      items = member_items(member, full, declared)
      if items.nil?
        result.skipped << ["#{full}: #{member.class.name.split('::').last}", 'member kind is not promoted']
        next
      end
      items.each do |item|
        if present?(index.entry(full), item.key)
          result.already += 1
          next
        end
        if item.problem
          result.skipped << [item.label, item.problem]
          next
        end
        unless valid_line?(item.line)
          result.skipped << [item.label, 'the rendered declaration does not parse']
          next
        end
        (visibility == :private ? private_lines : public_lines) << item.line
        result.added << [full, item.line]
        add_key(index.declare(full, kind, superclass), item.key)
      end
    end
    return nil if public_lines.empty? && private_lines.empty?

    header = if reopened then "#{kind == :module ? 'module' : 'class'} #{full}"
             elsif kind == :module then "module #{full}"
             else superclass ? "class #{full} < #{superclass}" : "class #{full}"
             end
    members = public_lines + (private_lines.empty? ? [] : ['private'] + private_lines)
    (provenance + [header] + members.map { |line| "  #{line}" } + ['end']).join("\n") + "\n"
  end

  # A unified diff of an append-style change (context of CONTEXT lines), with the paths as given.
  def unified_diff(old_text, new_text, path)
    old_lines = old_text.lines
    new_lines = new_text.lines
    return '' if old_lines == new_lines

    prefix = 0
    prefix += 1 while prefix < old_lines.size && prefix < new_lines.size && old_lines[prefix] == new_lines[prefix]
    suffix = 0
    while suffix < old_lines.size - prefix && suffix < new_lines.size - prefix &&
          old_lines[-1 - suffix] == new_lines[-1 - suffix]
      suffix += 1
    end
    old_change = old_lines[prefix...(old_lines.size - suffix)]
    new_change = new_lines[prefix...(new_lines.size - suffix)]
    start = [prefix - CONTEXT, 0].max
    before = old_lines[start...prefix]
    tail = [CONTEXT, suffix].min
    after = old_lines[(old_lines.size - suffix)...(old_lines.size - suffix + tail)]
    out = ["--- a/#{path}", "+++ b/#{path}",
           "@@ -#{start + 1},#{before.size + old_change.size + after.size} +#{start + 1},#{before.size + new_change.size + after.size} @@"]
    out.concat(before.map { |l| " #{l}" })
    out.concat(old_change.map { |l| "-#{l}" })
    out.concat(new_change.map { |l| "+#{l}" })
    out.concat(after.map { |l| " #{l}" })
    out.map { |l| l.end_with?("\n") ? l : "#{l}\n" }.join
  end
end
