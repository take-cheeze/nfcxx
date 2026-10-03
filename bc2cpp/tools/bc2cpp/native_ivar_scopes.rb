# frozen_string_literal: true

require 'digest'
require_relative 'native_names'

# ADR 0332: audited native writes preserve their registered receiver family.
# Only unrelated Ruby families may pool the same names.
module NativeIvarScopes
  FILES = {
    'mruby-rgss/src/lib.cxx' => '664be94f4af8b7081cbf5679267d6fca1a4ce713423d850ae5478ed2c4921f1e',
    'include/rgss_construct.hxx' => 'f1c476607ff9bba32f33d77a088466150e717e329dff1fa8792027fa05d45e28',
    'include/rgss_native_direct.hxx' => '4e43a533ce6371f47b9ccb3dafb342405c4e63ad942347236fb0c4de71b11386'
  }.freeze
  SCOPES = {
    'contents' => ['RGSS::Window'],
    'cursor_rect' => ['RGSS::Window'],
    'viewport' => %w[RGSS::Sprite RGSS::Plane RGSS::Tilemap RGSS::Window]
  }.freeze
  NAMES = SCOPES.keys.freeze

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
    # Reject address taking and token pasting as well as ordinary writer calls.
    references = /\bwindow_(?!title(?:\b|_))\w*|\b(?:spr_init|sprite_new_direct|plane_init|tilemap_init)\b|\b(?:spr_|sprite_|plane_|tilemap_)\s*\#\#/
    outside = paths - audited.keys
    outside.each do |path|
      text = SourceText.read(path, 'native ivar scopes', binary: true)
      return [{}, "missing outside input: #{path}"] unless text
      return [{}, "outside audited receiver reference: #{path}"] if text.match?(references)
    end
    globally_spelled = outside_ivar_names(outside)
    scopes = NAMES.reject { |name| globally_spelled.include?(name) }.to_h { |name| [name, SCOPES.fetch(name)] }
    [scopes, scopes.empty? ? 'names spelled outside the audit' : nil]
  end
end
