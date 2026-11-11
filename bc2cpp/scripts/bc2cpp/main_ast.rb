#!/usr/bin/env ruby
# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'open3'
require 'tmpdir'
require_relative '../../tools/bc2cpp/main_roots'
require_relative '../../tools/bc2cpp/native_ast_source'

main, output, *flags = ARGV
abort 'usage: ruby scripts/bc2cpp/main_ast.rb MAIN OUTPUT [--lookup-names-only] [--unit NATIVE_SOURCE]... [-- CLANG_FLAGS...]' unless main && output
units = []
lookup_names_only = false
while %w[--unit --lookup-names-only].include?(flags.first)
  if flags.shift == '--lookup-names-only'
    lookup_names_only = true
  else
    units << File.realpath(flags.shift || abort('--unit requires a source path'))
  end
end
flags.shift if flags.first == '--'
main = File.realpath(main)
abort 'PCH/modules are not supported by main-root extraction' if flags.any? { |flag| flag.match?(/\A(?:-include-pch|-fpch-preprocess|-fmodules|-fmodule-)/) }
resolve = lambda do |name|
  path = if name.include?('/') then name
         else ENV.fetch('PATH').split(File::PATH_SEPARATOR).map { |dir| File.join(dir, name) }.find { |file| File.file?(file) && File.executable?(file) }
         end
  abort "compiler not found: #{name}" unless path

  File.realpath(path)
end
# The nfcxx front end's AST (scripts/nfcxx-ast-dump, docs/notes/nfcxx-ast.md) is the default where it is built; clang's is the
# fallback, and BC2CPP_AST_PRODUCER=clang opts out. The two manifests' roots agree on everything a consumer reads
# (scripts/bc2cpp/main_ast_producers_diff.rb). The nfcxx producer needs no clang at all when BC2CPP_HOST_CXX preprocesses.
producer = NativeAstSource.producer
clang = producer == 'clang' ? resolve.call(ENV.fetch('CLANG', 'clang++')) : nil
host_cxx = ENV['BC2CPP_HOST_CXX'] && resolve.call(ENV['BC2CPP_HOST_CXX'])
target = nil
if host_cxx
  machine, error, status = Open3.capture3(host_cxx, '-dumpmachine')
  abort "host compiler target query failed: #{error}" unless status.success? && machine.strip.match?(/\A[\w.-]+\z/)

  target = machine.strip
end
expected_command = { 'clang' => clang, 'host_cxx' => host_cxx, 'target' => target, 'flags' => flags,
                     'sources' => [main, *units], 'lookup_names_only' => lookup_names_only }
expected_command['ast_producer'] = producer unless producer == 'clang'
tools = [File.realpath(__FILE__), File.realpath(File.join(__dir__, '../../tools/bc2cpp/main_roots.rb')), clang, host_cxx].compact
tools += [File.realpath(NativeAstSource.nfcxx_tool), File.realpath(ENV.fetch('LIBCLANG_EDG_CPFE') { File.join(NativeAstSource::REPO_ROOT, 'build/libclang-edg/cmake/bin/cpfe') })] if producer == 'nfcxx'
tool_digests = tools.to_h { |path| [path, Digest::SHA256.file(path).hexdigest] }
if File.file?(output)
  previous = JSON.parse(File.read(output))
  if previous['format'] == 1 && previous['command'] == expected_command &&
     previous.fetch('dependencies').all? { |path, digest| File.file?(path) && Digest::SHA256.file(path).hexdigest == digest }
    exit 0
  end
end
Dir.mktmpdir('bc2cpp-main-ast') do |dir|
  deps = []
  ast = { 'kind' => 'TranslationUnitDecl', 'inner' => [] }
  namespace_ids = lambda do |value, prefix|
    case value
    when Hash
      value.each do |key, item|
        if %w[id referencedMemberDecl previousDecl parentDeclContextId].include?(key) && item.is_a?(String)
          value[key] = "#{prefix}:#{item}"
        else
          namespace_ids.call(item, prefix)
        end
      end
    when Array then value.each { |item| namespace_ids.call(item, prefix) }
    end
  end
  [main, *units].each_with_index do |source, index|
    depfile = File.join(dir, "#{index}.d")
    astfile = File.join(dir, "#{index}.json")
    input = source
    if host_cxx
      input = File.join(dir, "#{index}.ii")
      File.open(input, 'w') do |io|
        pid = Process.spawn(host_cxx, *flags, '-Werror=date-time', '-E', '-MD', '-MF', depfile, source, out: io)
        _, status = Process.wait2(pid)
        abort "target preprocessing failed: #{source}" unless status.success?
      end
    end
    json = nil
    if producer == 'nfcxx'
      # The front end's own dump; -MD/-MF make scripts/nfcxx-ast-dump list the headers it read (the host preprocess above already wrote them).
      dump_flags = host_cxx ? flags : [*flags, '-MD', '-MF', depfile]
      out, err, status = NativeAstSource.dump(input, dump_flags, lang: :cxx, name: 'nfcxx')
      abort "AST compilation failed: #{source}: #{err.lines.find { |l| l =~ /error/ } || err.lines.first}" unless status.success?

      json = out # parsed below without the scratch file round trip
    else
      command = [clang, *flags, '-Werror=date-time', '-fsyntax-only', '-Xclang', '-ast-dump=json']
      command += host_cxx ? ["--target=#{target}", '-x', 'c++-cpp-output', input] : ['-MD', '-MF', depfile, source]
      File.open(astfile, 'w') do |io|
        pid = Process.spawn(*command, out: io)
        _, status = Process.wait2(pid)
        abort "AST compilation failed: #{source}" unless status.success?
      end
    end
    unit = JSON.parse(json || File.read(astfile))
    namespace_ids.call(unit, index)
    unit['bc2cpp_native_unit'] = true unless index.zero?
    ast['inner'] << unit
    deps |= File.read(depfile).sub(/\A[^:]*:/, '').gsub(/\\\n/, ' ')
                .scan(/(?:\\.|[^\s])+/).map { |path| File.realpath(path.gsub(/\\(.)/, '\1')) }
    File.unlink(astfile) unless json
  end
  roots = MainRoots.analyze(ast, literal_roots: !lookup_names_only)
  tool_digests.each do |path, digest|
    abort "AST exporter changed while running: #{path}" unless Digest::SHA256.file(path).hexdigest == digest
  end
  inputs = deps | [main, *tools]
  data = { format: 1, main: main, native_paths: units, command: expected_command,
           dependencies: inputs.sort.to_h { |path| [path, Digest::SHA256.file(path).hexdigest] },
           roots: { names: roots.names.to_a.sort, functions: roots.functions.to_a.sort, refusals: roots.refusals.sort } }
  content = JSON.generate(data)
  next if File.file?(output) && File.read(output) == content

  FileUtils.mkdir_p(File.dirname(File.expand_path(output)))
  temp = "#{output}.#{Process.pid}.tmp"
  File.write(temp, content)
  File.rename(temp, output)
end
