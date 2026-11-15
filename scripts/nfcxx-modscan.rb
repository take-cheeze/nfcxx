#!/usr/bin/env ruby
# The source scans of nfcxx's C++ module build (docs/notes/modules.md), ported from nfcxx's bash mod_is_module_src,
# mod_decl_name, mod_imports and mod_check_src. Each reads the declarations at the start of a line only. The sources are
# read as bytes (any encoding, as grep reads them): a comment with a non-UTF-8 byte is not an error.
#
#   ruby scripts/nfcxx-modscan.rb is-module FILE   exit 0 when FILE declares or imports a module (grep's line test), 1 when
#                                                  not, 2 when FILE cannot be read (grep's status)
#   ruby scripts/nfcxx-modscan.rb decl-name FILE   prints NAME of "export module NAME;" (the first such line), or nothing
#   ruby scripts/nfcxx-modscan.rb imports FILE     prints each NAME of "import NAME;" / "export import NAME;"
#   ruby scripts/nfcxx-modscan.rb check FILE       refuses (exit 2, nfcxx's message on stderr) a module partition, a header
#                                                  unit, or an import of a standard library module
#
# The same functions are the module NfcxxModscan, which scripts/nfcxx-modules.rb (its build) requires.
# tests/nfcxx-modscan/run.sh checks each against the bash functions on the module sources and on edge cases.
module NfcxxModscan
  DECL_NAME = /\A[ \t]*export[ \t]+module[ \t]+([A-Za-z_][A-Za-z0-9_.]*)[ \t]*;/
  IMPORT = /\A[ \t]*(?:export[ \t]+)?import[ \t]+([A-Za-z_][A-Za-z0-9_.]*)[ \t]*;/
  PARTITION = /\A[ \t]*(?:export[ \t]+)?module[ \t]+[A-Za-z_][A-Za-z0-9_.]*[ \t]*:/
  HEADER_UNIT = /\A[ \t]*(?:export[ \t]+)?import[ \t]+[<"]/
  # mod_is_module_src's line test (the bash grep -E: [[:space:]] is space, tab, newline, vertical tab, form feed, carriage return)
  MODULE_LINE = /\A[[:space:]]*(?:export[[:space:]]+)?(?:module|import)[[:space:]]+[A-Za-z_<"]/

  module_function

  # each line of PATH as bytes (binary), as grep reads it; raises the system error when PATH cannot be read
  def each_line_bytes(path, &block)
    File.open(path, "rb") { |f| f.each_line(&block) }
  end

  # true when some line of FILE is a module declaration or import (mod_is_module_src)
  def module_src?(path)
    each_line_bytes(path) do |line|
      return true if MODULE_LINE.match?(line)
    end
    false
  end

  # the NAME of the first "export module NAME;" line, or nil
  def decl_name(path)
    each_line_bytes(path) do |line|
      m = DECL_NAME.match(line)
      return m[1] if m
    end
    nil
  end

  # every NAME of an "import NAME;" / "export import NAME;" line, in order
  def import_names(path)
    names = []
    each_line_bytes(path) do |line|
      m = IMPORT.match(line)
      names << m[1] if m
    end
    names
  end

  # [status, message]: [0, nil] when the source is accepted, else [2, nfcxx's message] for a partition, a header unit or an
  # import of a standard library module
  def check_source(path)
    each_line_bytes(path) do |line|
      return [2, "nfcxx: #{path}: module partitions are not supported yet (docs/notes/modules.md)"] if PARTITION.match?(line)
      return [2, "nfcxx: #{path}: header units are not supported yet (docs/notes/modules.md)"] if HEADER_UNIT.match?(line)
    end
    import_names(path).each do |name|
      next unless name == "std" || name.start_with?("std.")

      return [2, "nfcxx: #{path}: import #{name}: the standard library modules are not built yet (docs/notes/modules.md)"]
    end
    [0, nil]
  end
end

if $PROGRAM_NAME == __FILE__
  cmd, path = ARGV
  # the scans read the file; a file that cannot be read is a status of its own (grep's 2), not a crash
  unless %w[is-module decl-name imports check].include?(cmd) && path
    warn "usage: nfcxx-modscan.rb is-module|decl-name|imports|check FILE"
    exit 2
  end
  case cmd
  when "is-module"
    begin
      exit(NfcxxModscan.module_src?(path) ? 0 : 1)
    rescue SystemCallError => e
      # grep's status for a file it cannot read (mod_is_module_src: a false test)
      warn "nfcxx-modscan: #{path}: #{SystemCallError.new(e.errno).message}"
      exit 2
    end
  when "decl-name"
    name = NfcxxModscan.decl_name(path)
    puts name if name
  when "imports" then NfcxxModscan.import_names(path).each { |name| puts name }
  when "check"
    rc, msg = NfcxxModscan.check_source(path)
    if rc != 0
      warn msg
      exit rc
    end
  end
end
