# frozen_string_literal: true

# Bakes the bc2cpp source graph into one mruby-loadable file, so that `require` can evaluate each source by its name.
#
#   ruby tools/bake_sources.rb ENTRY OUTPUT [EXTRA_ENTRY...]
#
# ENTRY is a path under the repository root (tools/bc2cpp/bc2cpp.rb). EXTRA_ENTRY names more files to bake, such as a
# script the tools load by name (scripts/rpg2k/closed_world_lint.rb). Every file reachable from an entry through
# require_relative is written into OUTPUT as a string, under the name it has in the repository (without `.rb`,
# e.g. 'tools/bc2cpp/escape_analysis'). The names are baked in at this point:
#
#   - `require_relative 'x'` (at any indentation, with any modifier) becomes `require 'tools/bc2cpp/x'`, so a lazy
#     load inside a method names the same file as a load at the top.
#   - `__FILE__` becomes the baked name of its own file, so `if $PROGRAM_NAME == __FILE__` works for the entry.
#
# Each file is then evaluated on its own by MRubyRequire (host-libs/mruby-require), which keeps a single method or
# constant table from growing into one oversized compilation unit.

require_relative 'world_root'
ROOT = BC2CPP_WORLD_ROOT
CHUNK = 1000
REQUIRE_RELATIVE = /\A(\s*)require_relative\s+(['"])([^'"]+)\2(.*)\n?\z/

def baked_name(path)
  path.delete_prefix("#{ROOT}/").delete_suffix('.rb')
end

def resolve(from_path, name)
  target = File.expand_path(name.end_with?('.rb') ? name : "#{name}.rb", File.dirname(from_path))
  abort "bake_sources: missing #{target} (required by #{from_path})" unless File.file?(target)
  target
end

def bake_file(path, sources, queue)
  name = baked_name(path)
  lines = File.readlines(path, encoding: 'UTF-8').map do |line|
    if (m = REQUIRE_RELATIVE.match(line))
      target = resolve(path, m[3])
      queue << target unless sources.key?(baked_name(target)) || queue.include?(target)
      line = "#{m[1]}require '#{baked_name(target)}'#{m[4]}#{line.end_with?("\n") ? "\n" : ''}"
    end
    line
  end
  # __dir__ is baked as the source's own directory, so a run from elsewhere resolves the same files.
  body = lines.join.gsub(/__FILE__/, "'#{name}'").gsub(/\b__dir__\b/, "'#{File.dirname(path)}'")
  sources[name] = body
end

def bake(*entries)
  sources = {}
  queue = entries.map { |entry| File.expand_path(entry, ROOT) }
  until queue.empty?
    path = queue.shift
    next if sources.key?(baked_name(path))

    bake_file(path, sources, queue)
  end
  sources
end

if $PROGRAM_NAME == __FILE__
  # --dir DIR: each baked source is written as DIR/<baked name>.rb, with DIR/index listing the names, for the build to
  # compile to bytecode (host-libs/mruby-bc2cpp-sources) instead of evaluating the text at run time.
  dir = nil
  if (i = ARGV.index('--dir'))
    dir = ARGV[i + 1] or abort 'bake_sources: --dir needs a directory'
    ARGV.slice!(i, 2)
  end
  entry, output, *extras = ARGV
  abort 'usage: bake_sources.rb [--dir DIR] ENTRY OUTPUT [EXTRA_ENTRY...]' unless output

  sources = bake(entry, *extras)
  if dir
    require 'fileutils'
    FileUtils.rm_rf(dir)
    sources.each do |name, body|
      path = File.join(dir, "#{name}.rb")
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, body)
    end
    File.write(File.join(dir, 'index'), "#{sources.keys.join("\n")}\n")
    File.write(output, "# the baked sources are compiled to bytecode under #{dir}\n")
    warn "bake_sources: #{sources.size} files into #{dir}"
    exit
  end
  # Each body is a list of single-quoted chunks, escaping only `\` and `'`, joined at load. A heredoc would not do:
  # mruby processes backslash escapes in `<<'EOS'` (CRuby does not), which halves every `\\` in the baked source.
  # A single literal over a few thousand bytes is refused by mruby's parser, so the chunks stay short.
  File.write(output, sources.map do |name, body|
    chunks = body.scan(/.{1,#{CHUNK}}/m).map { |chunk| "'#{chunk.gsub('\\') { '\\\\' }.gsub("'") { "\\'" }}'" }
    "MRubyRequire.bake('#{name}', [#{chunks.join(",\n")}].join)\n"
  end.join)
  warn "bake_sources: #{sources.size} files from #{[entry, *extras].join(' ')}"
end
