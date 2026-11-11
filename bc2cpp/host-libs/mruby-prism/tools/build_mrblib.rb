# frozen_string_literal: true

# Builds the mruby-prism Ruby half: prism's Ruby wrapper (the deserializer and node classes) from the pinned
# submodule, with the parts mruby does not provide replaced by equivalents. Run by mrbgem.rake at build time.
#
#   ruby tools/build_mrblib.rb PRISM_ROOT ENCODING_FILE OUTPUT
#
# PRISM_ROOT is 3rd/prism. The generated files (node.rb, visitor.rb, inspect_visitor.rb, serialize.rb) are rendered
# from its templates here, since the fork does not commit them.
#
# Deviations from the CRuby sources (each is a change of mechanism, not of the parsed result):
#   - `require`, `require_relative`: dropped. The mrblib is one compiled unit, and polyfill/unpack1.rb is not needed
#     because the offset calls below slice first.
#   - private_constant, autoload: dropped. mruby has no constant visibility or autoload; the constants stay public
#     and the files are concatenated in load order.
#   - unpack1("L", offset:): rewritten as byteslice(offset, 4).unpack1("L"). Only "L" is used by the deserializer.
#   - The light encoding model (ruby/encoding_light.rb) is prepended.
#
# The transform fails, rather than passing a call through, if an unhandled offset or require is left.

require 'fileutils'
require 'tmpdir'

prism_root, encoding_file, output = ARGV
abort 'usage: build_mrblib.rb PRISM_ROOT ENCODING_FILE OUTPUT' unless output

generated = %w[lib/prism/node.rb lib/prism/visitor.rb lib/prism/inspect_visitor.rb lib/prism/serialize.rb]
tracked = %w[lib/prism/node_ext.rb lib/prism/parse_result.rb]
tracked += Dir[File.join(prism_root, 'lib/prism/parse_result/*.rb')].sort.map { |p| p.delete_prefix("#{prism_root}/") }

Dir.mktmpdir('prism-mrblib') do |scratch|
  require File.join(prism_root, 'templates', 'template')
  generated.each { |name| Prism::Template.render(name, write_to: File.join(scratch, name)) }

  parts = [File.read(encoding_file, encoding: 'UTF-8')]
  (generated.take(2).map { |n| File.join(scratch, n) } +
   [File.join(scratch, generated[2]), File.join(prism_root, tracked[0]), File.join(prism_root, tracked[1])] +
   tracked.drop(2).map { |n| File.join(prism_root, n) } +
   [File.join(scratch, generated[3])]).each do |path|
    parts << File.read(path, encoding: 'UTF-8')
  end

  text = parts.join("\n")
  text = text.lines.reject { |line| line.match?(/\A\s*(private_constant|autoload)\b/) }.join
  text = text.lines.reject { |line| line.match?(/\A\s*require(_relative)?\b/) }.join
  text = text.gsub(/(\w+)\.unpack1\("L", offset: offset \+ 4\)/, '\1.byteslice(offset + 4, 4).unpack1("L")')
  text = text.gsub(/(\w+)\.unpack1\("L", offset: offset\)/, '\1.byteslice(offset, 4).unpack1("L")')
  text = text.gsub(/\(io\.read\(8\) or raise\)\.unpack1\("L", offset: 4\)/, '(io.read(8) or raise).byteslice(4, 4).unpack1("L")')

  leftover = text.lines.reject { |line| line.lstrip.start_with?("#") }.grep(/unpack1\(.*offset:|^\s*require\b|private_constant|autoload/)
  abort "build_mrblib.rb: untransformed mruby incompatibilities:\n#{leftover.join}" unless leftover.empty?

  FileUtils.mkdir_p(File.dirname(output))
  File.write(output, text)
end
