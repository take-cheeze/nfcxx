#!/usr/bin/env ruby
# The source scans of nfcxx's C++ module build (docs/notes/modules.md), ported from nfcxx's bash mod_decl_name, mod_imports and
# mod_check_src. Each reads the declarations at the start of a line only.
#
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

  module_function

  # the NAME of the first "export module NAME;" line, or nil
  def decl_name(path)
    File.foreach(path) do |line|
      m = DECL_NAME.match(line)
      return m[1] if m
    end
    nil
  end

  # every NAME of an "import NAME;" / "export import NAME;" line, in order
  def import_names(path)
    names = []
    File.foreach(path) do |line|
      m = IMPORT.match(line)
      names << m[1] if m
    end
    names
  end

  # [status, message]: [0, nil] when the source is accepted, else [2, nfcxx's message] for a partition, a header unit or an
  # import of a standard library module
  def check_source(path)
    File.foreach(path) do |line|
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
  case cmd
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
  else
    warn "usage: nfcxx-modscan.rb decl-name|imports|check FILE"
    exit 2
  end
end
