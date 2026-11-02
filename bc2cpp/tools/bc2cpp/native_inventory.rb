# frozen_string_literal: true

require 'digest'
require 'json'
require_relative 'static_dispatch_registrations'

module NativeInventory
  module_function

  def read(path)
    data = JSON.parse(File.read(path))
    raise 'unsupported native inventory format' unless data['format'] == 1

    data.fetch('dependencies').each do |file, digest|
      raise "stale preprocessed native inventory: #{file}; export it again" unless File.file?(file) && Digest::SHA256.file(file).hexdigest == digest
    end
    data
  end

  def clean(text)
    # Presym preprocessing uses -dD: macro definitions are not executable references.
    text = text.gsub(/\\\r?\n/, '').gsub(/^[ \t]*#[^\n]*\n?/, '')
    text = StaticDispatchRegistrations.strip_c_comments(text)
    # ROM rows define names, while their installation references the table as a whole.
    offset = 0
    while (match = /\b(?:static\s+)?const\s+mrb_mt_entry\s+\w+\s*\[\s*\]\s*=\s*\{/.match(text, offset))
      start = match.end(0) - 1
      masked = text.gsub(/"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'/) { |s| ' ' * s.size }
      body = NativeOwnerMap.brace_body(masked, start)
      raise 'unbalanced preprocessed ROM table' unless body

      finish = start + body.size + 2
      pure = body.gsub(/\(\s*mrb_aspec\s*\)\s*\(/, '((')
      text[match.begin(0)...finish] = ' ' * (finish - match.begin(0)) unless pure.match?(/[\w$>\]]\s*\(|\)\s*\(/)
      offset = finish
    end
    text = text.gsub(/<@!\s*((?:"(?:[^"\\]|\\.)*"\s*)+)\s*!@>/) do
      parts = Regexp.last_match(1).scan(StaticDispatchRegistrations::STRING_LITERAL).map { |(s)| StaticDispatchRegistrations.unescape(s) }
      JSON.generate(parts.join)
    end
    StaticDispatchRegistrations.blank_registration_names(text)
  end

  def export(inputs, output)
    raise 'empty native preprocessing inventory' if inputs.empty?

    deps = Dir[File.join(__dir__, '**/*.rb')].map { |path| File.realpath(path) }
    units = inputs.map do |entry|
      source = File.realpath(entry.fetch('source'))
      pi = File.realpath(entry.fetch('preprocessed'))
      depfile = File.realpath(entry.fetch('depfile'))
      included = File.read(depfile).sub(/\A[^:]*:/, '').gsub(/\\\n/, ' ').scan(/(?:\\.|[^\s])+/)
                     .map { |name| File.realpath(name.gsub(/\\(.)/, '\1')) }
      raise "dependency file omits its source: #{source}" unless included.include?(source)
      newer = included.find { |path| File.mtime(path) > File.mtime(pi) }
      raise "preprocessed input is stale: #{pi} (#{newer}); rebuild preprocessing first" if newer

      configs = Array(entry['configuration_dependencies']).map { |path| File.realpath(path) }
      deps |= [source, pi, depfile, *included, *configs]
      text = clean(File.binread(pi))
      names = Set.new
      StaticDispatchRegistrations.native_name_tokens(text, names, [])
      { source: source, preprocessed: pi, names: names.to_a.sort, implementations: text.scan(/[\w$]+_impl\b/).uniq.sort }
    end
    data = { format: 1, units: units, dependencies: deps.sort.to_h { |file| [file, Digest::SHA256.file(file).hexdigest] } }
    File.write(output, JSON.pretty_generate(data) + "\n")
  end

  def export_build(build, output)
    paths = Rake::Task[build.presym.list_path].prerequisites.select { |path| File.extname(path) == build.exts.presym_preprocessed }
    compilers = (build.compilers + build.gems.flat_map(&:compilers)).uniq
    saved = compilers.to_h { |compiler| [compiler, compiler.preprocess_options] }
    saved.each do |compiler, options|
      compiler.preprocess_options = options + ' -MD -MF "%{outfile}.inventory.d"'
    end
    begin
      inputs = paths.filter_map do |pi|
        task = Rake::Task[pi]
        source = task.prerequisites.find { |path| path.match?(/\.(?:c|cc|cxx|cpp)\z/) && File.file?(path) }
        raise "preprocessed input has no source: #{pi}" unless source

        wrapper = File.basename(source).match?(/-cxx\.cxx\z/)
        # Generated Ruby/codegen units are modeled by their Ruby IR, not a second scan of their definition data.
        generated = File.expand_path(source).start_with?(File.expand_path(build.build_dir) + '/')
        ruby_unit = File.basename(source).match?(/\A(?:mrblib\.c|gem_init\.c|\w+_gen(?:_(?:\d+|shard\d+))?\.cpp)\z/)
        registration = build.gems.any? do |gem|
          BC2CPP_COMPILED_GEMS.key?(gem.name) && File.expand_path(source) == File.join(gem.dir, 'src/register.cxx')
        end
        next if registration || (generated && ruby_unit && !wrapper)

        task.invoke
        task.execute
        depfile = "#{pi}.inventory.d"
        if wrapper
          original = File.basename(source).sub(/-cxx\.cxx\z/, '.c')
          source = File.read(depfile).gsub(/\\\n/, ' ').split.find { |path| File.basename(path) == original }
          raise "wrapper has no original source: #{pi}" unless source
        end
        configs = task.prerequisites.select { |path| File.file?(path) }
        { 'source' => source, 'preprocessed' => pi, 'depfile' => depfile, 'configuration_dependencies' => configs }
      end
      export(inputs, output)
    ensure
      saved.each { |compiler, options| compiler.preprocess_options = options }
    end
  end
end
