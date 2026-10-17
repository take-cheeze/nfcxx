# frozen_string_literal: true

# NativeSigs: the built-in and RGSS method declarations, all in sig/bc2cpp/declarations.rbs. Each native table is a group
# of top-level declarations under a marker line directly above each one: `# bc2cpp-native: <table>`. A table is read by
# its own loader (NativeSigs.decls), and a native declaration is not a program hint: its C function or mruby body is
# checked by its own generator, not by a method the program defines. Program declarations carry no marker.
module NativeSigs
  FILE = File.expand_path('../../sig/bc2cpp/declarations.rbs', __dir__)
  MARKER = '# bc2cpp-native:'
  MARK_LINE = /^bc2cpp-native: (\S+)$/.freeze

  module_function

  # The table a declaration belongs to, or nil for a program declaration. RBS keeps the comment without its `#`.
  def table_of(decl)
    decl.comment&.string.to_s[MARK_LINE, 1]
  end

  def native?(decl)
    !table_of(decl).nil?
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

  # The source text of one table, marker included: what the table's loader reads when it is a file.
  def table_source(table)
    name = table_name(table)
    lines = File.readlines(FILE)
    parse.select { |decl| table_of(decl) == name }.map do |decl|
      "#{MARKER} #{name}\n" + lines[(decl.location.start_line - 1)...decl.location.end_line].join
    end.join
  end

  # The declarations of one table, in file order.
  def decls(table)
    name = table_name(table)
    parse.select { |decl| table_of(decl) == name }
  end

  # Every top-level declaration of the file, parsed once per process.
  def parse
    @parse ||= begin
      require 'rbs'
      _buf, _dirs, decls = RBS::Parser.parse_signature(RBS::Buffer.new(name: 'declarations.rbs', content: File.read(FILE)))
      decls
    rescue LoadError
      raise "bc2cpp: #{FILE} needs the rbs gem (gem install rbs)"
    end
  end

  # The source of every native declaration, each under its marker: the text a fixture gives the loader as a file.
  def native_source
    lines = File.readlines(FILE)
    parse.select { |decl| native?(decl) }.map do |decl|
      "#{MARKER} #{table_of(decl)}\n" + lines[(decl.location.start_line - 1)...decl.location.end_line].join
    end.join
  end
end
