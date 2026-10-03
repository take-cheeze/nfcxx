# frozen_string_literal: true

require 'digest'
require_relative 'native_names'

# ADR 0332: the audited Window call graph preserves self. Native writes still
# poison its entire family; unrelated Ruby families may pool the same names.
module NativeIvarScopes
  FILES = {
    'mruby-rgss/src/lib.cxx' => '664be94f4af8b7081cbf5679267d6fca1a4ce713423d850ae5478ed2c4921f1e',
    'include/rgss_construct.hxx' => 'f1c476607ff9bba32f33d77a088466150e717e329dff1fa8792027fa05d45e28',
    'include/rgss_native_direct.hxx' => '4e43a533ce6371f47b9ccb3dafb342405c4e63ad942347236fb0c4de71b11386'
  }.freeze
  NAMES = %w[contents cursor_rect].freeze

  module_function

  def canonical_path(path)
    File.exist?(path) ? File.realpath(path) : File.expand_path(path)
  end

  def analyze(native_paths, ruby_paths, root: File.expand_path('../..', __dir__))
    return [{}, 'disabled'] if ENV['BC2CPP_NATIVE_IVAR_SCOPES'] == '0'

    paths = (Array(native_paths) + Array(ruby_paths)).map { |p| canonical_path(p) }.uniq
    audited = {}
    FILES.each do |relative, digest|
      path = canonical_path(File.join(root, relative))
      return [{}, "missing audit input: #{relative}"] unless paths.include?(path)

      text = SourceText.read(path, 'native ivar scopes', binary: true)
      return [{}, "audit changed: #{relative}"] unless text && Digest::SHA256.hexdigest(text) == digest

      audited[path] = text
    end
    functions = audited.fetch(canonical_path(File.join(root, 'mruby-rgss/src/lib.cxx'))).scan(/\bwindow_(?!title_)\w+(?=\s*\()/).uniq
    references = /\b(?:#{functions.map { |f| Regexp.escape(f) }.join('|')})\b/
    outside = paths - audited.keys
    outside.each do |path|
      text = SourceText.read(path, 'native ivar scopes', binary: true)
      return [{}, "missing outside input: #{path}"] unless text
      return [{}, "outside Window reference: #{path}"] if text.match?(references)
    end
    globally_spelled = outside_ivar_names(outside)
    scopes = NAMES.reject { |name| globally_spelled.include?(name) }.to_h { |name| [name, ['RGSS::Window']] }
    [scopes, scopes.empty? ? 'names spelled outside the audit' : nil]
  end
end
