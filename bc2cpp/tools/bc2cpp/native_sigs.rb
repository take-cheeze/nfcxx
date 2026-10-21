# frozen_string_literal: true

require_relative 'rbs_parse_memo'

# NativeSigs: the built-in and RGSS method declarations, all in sig/bc2cpp/declarations.rbs. Each native table is a group
# of declarations under a marker line directly above each one: `# bc2cpp-native: <table>`. A marker on a top-level block
# covers its members; a member may carry its own marker, which takes precedence (docs/adr/0516). A table is read by its
# own loader (NativeSigs.decls), and a native declaration is not a program hint: its C function or mruby body is checked
# by its own generator, not by a method the program defines. Program declarations carry no marker.
module NativeSigs
  FILE = File.expand_path('../../sig/bc2cpp/declarations.rbs', __dir__)
  MARKER = '# bc2cpp-native:'
  MARK_WORD = 'bc2cpp-native:'
  MARK_LINE = /^bc2cpp-native: (\S+)$/.freeze

  module_function

  # The table a declaration or member belongs to, or nil. `enclosing` lists the declarations it sits in, outermost first
  # (a member's block is its last entry); with no marker of its own a node takes the nearest enclosing marker.
  # RBS keeps the comment without its `#`.
  def table_of(node, enclosing = [])
    table = own_table(node)
    return table if table

    enclosing.reverse_each do |n|
      table = own_table(n)
      return table if table
    end
    nil
  end

  def native?(node, enclosing = [])
    !table_of(node, enclosing).nil?
  end

  # The identifier a loader takes for one table, e.g. sig/bc2cpp/declarations.rbs#core_results.
  def table(name)
    "#{FILE}##{name}"
  end

  def table_name(table)
    raise "bc2cpp: #{table} is not a native table of #{FILE}" unless table.start_with?("#{FILE}#")

    table.delete_prefix("#{FILE}#")
  end

  def table?(path)
    path.start_with?("#{FILE}#")
  end

  # The source text of one table, markers included: what the table's loader reads when it is a file. Each kept member
  # is written under its marker (its own, or one added for the block's table), so the text reads back as the same members.
  def table_source(table)
    source_text(parse, File.readlines(FILE), table_name(table))
  end

  # The declarations of one table, in file order: each top-level block restricted to the members whose table is it.
  def decls(table)
    select_table(parse, table_name(table))
  end

  # select_table and source_text take the parsed declarations and the file's lines, so a fixture can use them too.
  def select_table(decls, name)
    decls.filter_map { |decl| restrict(decl, name) }
  end

  def source_text(decls, lines, name)
    decls.map { |decl| source_of(decl, name, [], lines) }.join
  end

  # The source of every native declaration and member, each under its marker: the text a fixture gives the loader as a file.
  def native_source
    lines = File.readlines(FILE)
    parse.flat_map { |decl| tables_in(decl).map { |name| source_of(decl, name, [], lines) } }.join
  end

  # Every top-level declaration of the file, parsed once per process.
  def parse
    @parse ||= begin
      require 'rbs'
      RbsParseMemo.decls('declarations.rbs', File.read(FILE))
    rescue LoadError
      raise "bc2cpp: #{FILE} needs the rbs gem (gem install rbs)"
    end
  end

  # The marker a node carries itself, or nil. Members and blocks both keep their comment.
  # MARK_LINE needs this word on its line, so a comment without it cannot match; the test avoids the regex scan
  # and its match string on every node of every walk.
  def own_table(node)
    text = node.comment&.string
    return nil unless text&.include?(MARK_WORD)

    text[MARK_LINE, 1]
  end

  # The members of a block; a constant or type alias has none.
  def members_of(decl)
    decl.respond_to?(:members) ? decl.members : []
  end

  def nested?(node)
    node.is_a?(RBS::AST::Declarations::Base)
  end

  # The tables a block or its members name, in file order, the block's own first.
  def tables_in(decl, enclosing = [])
    chain = enclosing + [decl]
    found = [table_of(decl, enclosing)].compact
    members_of(decl).each do |m|
      found.concat(nested?(m) ? tables_in(m, chain) : [table_of(m, chain)].compact)
    end
    found.uniq
  end

  # `decl` restricted to the members of table +name+, as a new declaration with the same header; nil when none is.
  def restrict(decl, name, enclosing = [])
    return (table_of(decl, enclosing) == name ? decl : nil) if members_of(decl).empty?

    chain = enclosing + [decl]
    kept = decl.members.filter_map do |m|
      if nested?(m) then restrict(m, name, chain)
      elsif table_of(m, chain) == name then m
      end
    end
    kept.empty? ? nil : with_members(decl, kept)
  end

  # A copy of +decl+ holding +members+, every other constructor argument (name, super_class, type_params, annotations,
  # location, comment) taken from +decl+.
  def with_members(decl, members)
    args = decl.class.instance_method(:initialize).parameters.to_h do |_kind, arg|
      [arg, arg == :members ? members : decl.public_send(arg)]
    end
    decl.class.new(**args)
  end

  # The text of +decl+ for table +name+, '' when nothing of it is of that table. A block with no members is written whole
  # under a marker when its table is +name+; otherwise its header, each kept member and its footer.
  def source_of(decl, name, enclosing, lines)
    members = members_of(decl)
    if members.empty?
      return '' unless table_of(decl, enclosing) == name

      return "#{MARKER} #{name}\n" + slice(lines, decl.location.start_line, decl.location.end_line)
    end

    chain = enclosing + [decl]
    body = members.map { |m| member_source(m, name, chain, lines) }.join
    return '' if body.empty?

    slice(lines, decl.location.start_line, span_start(members.first) - 1) + body +
      slice(lines, members.last.location.end_line + 1, decl.location.end_line)
  end

  def member_source(member, name, chain, lines)
    return source_of(member, name, chain, lines) if nested?(member)
    return '' unless table_of(member, chain) == name

    marker = own_table(member) ? '' : "#{MARKER} #{name}\n"
    marker + slice(lines, span_start(member), member.location.end_line)
  end

  # The first line of a member's text: its comment when it has one, so the comment moves with the member.
  def span_start(node)
    node.comment ? node.comment.location.start_line : node.location.start_line
  end

  # Lines first..last of the file (1-based, inclusive), as text; '' when the range is empty.
  def slice(lines, first, last)
    return '' if last < first

    lines[(first - 1)..(last - 1)].to_a.join
  end
end
