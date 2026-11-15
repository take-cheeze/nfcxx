#!/usr/bin/env ruby
# The source scans of nfcxx's C++ module build (docs/notes/modules.md), ported from nfcxx's bash mod_decl_name, mod_imports and
# mod_check_src. Each reads the declarations at the start of a line only.
#
#   ruby scripts/nfcxx-modscan.rb decl-name FILE   prints NAME of "export module NAME;" (the first such line), or nothing
#   ruby scripts/nfcxx-modscan.rb imports FILE     prints each NAME of "import NAME;" / "export import NAME;"
#   ruby scripts/nfcxx-modscan.rb check FILE       refuses (exit 2, nfcxx's message on stderr) a module partition, a header
#                                                  unit, or an import of a standard library module
#
# tests/nfcxx-modscan/run.sh checks each against the bash functions on the module sources and on edge cases.

DECL_NAME = /\A[ \t]*export[ \t]+module[ \t]+([A-Za-z_][A-Za-z0-9_.]*)[ \t]*;/
IMPORT = /\A[ \t]*(?:export[ \t]+)?import[ \t]+([A-Za-z_][A-Za-z0-9_.]*)[ \t]*;/
PARTITION = /\A[ \t]*(?:export[ \t]+)?module[ \t]+[A-Za-z_][A-Za-z0-9_.]*[ \t]*:/
HEADER_UNIT = /\A[ \t]*(?:export[ \t]+)?import[ \t]+[<"]/

def decl_name(path)
  File.foreach(path) do |line|
    m = DECL_NAME.match(line)
    if m
      puts m[1]
      return
    end
  end
end

def import_names(path)
  names = []
  File.foreach(path) do |line|
    m = IMPORT.match(line)
    names << m[1] if m
  end
  names
end

def imports(path)
  import_names(path).each { |name| puts name }
end

def check(path)
  File.foreach(path) do |line|
    if PARTITION.match?(line)
      warn "nfcxx: #{path}: module partitions are not supported yet (docs/notes/modules.md)"
      exit 2
    end
    if HEADER_UNIT.match?(line)
      warn "nfcxx: #{path}: header units are not supported yet (docs/notes/modules.md)"
      exit 2
    end
  end
  import_names(path).each do |name|
    next unless name == "std" || name.start_with?("std.")

    warn "nfcxx: #{path}: import #{name}: the standard library modules are not built yet (docs/notes/modules.md)"
    exit 2
  end
end

if $PROGRAM_NAME == __FILE__
  cmd, path = ARGV
  case cmd
  when "decl-name" then decl_name(path)
  when "imports" then imports(path)
  when "check" then check(path)
  else
    warn "usage: nfcxx-modscan.rb decl-name|imports|check FILE"
    exit 2
  end
end
