# frozen_string_literal: true

require 'digest'
require_relative 'source_text'

# ADR 0333: all native spellings of a name must belong to pinned, audited files.
# A result fact joins successful returns; it never bypasses the original call.
module NativeClassResults
  FILES = {
    '3rd/mruby/src/hash.c' => '42d9e2c6d836f08e73fff828fc2cf7988d18cd24c6ae3a29ee71a7d6ee019a16',
    '3rd/mruby/src/string.c' => '1ea0c045842b4feeefcad548ef79951a5fb3408d31908063fd9fec106de71f00',
    '3rd/mruby/src/array.c' => '5e0541466b6aa9c8eaab0bcc7d51db15babae7059871854eeef81f08ac53dc11',
    '3rd/mruby/mrbgems/mruby-struct/src/struct.c' => '2e536e12e4bcfc62d7581966860789eb31edcf6282e2ec67ec70e85db34fbec5',
    '3rd/mruby/mrbgems/mruby-proc-ext/src/proc.c' => %w[01a0156d300517eba92d8a00d36d8ee1b9d3cb7a29420d7b815711ab00a39e45 912d1b2ba1f94dbcb802e542844d9af4c10a7f1650c0bb6d14f529878a437c9f],
    '3rd/mruby/mrbgems/mruby-method/src/method.c' => 'd2a780ca6a3ef25297c8f60356ad56a61fb826a2d5759059a25cdddb9820b0eb',
    'mruby-rgss/src/lib.cxx' => '664be94f4af8b7081cbf5679267d6fca1a4ce713423d850ae5478ed2c4921f1e'
  }.freeze
  FACTS = {
    'keys' => ['Array', %w[3rd/mruby/src/hash.c]],
    'values' => ['Array', %w[3rd/mruby/src/hash.c 3rd/mruby/mrbgems/mruby-struct/src/struct.c]],
    'bytes' => ['Array', %w[3rd/mruby/src/string.c]],
    'split' => ['Array', %w[3rd/mruby/src/string.c]],
    'members' => ['Array', %w[3rd/mruby/mrbgems/mruby-struct/src/struct.c]],
    'to_a' => ['Array', %w[3rd/mruby/src/array.c 3rd/mruby/mrbgems/mruby-struct/src/struct.c]],
    'parameters' => ['Array', %w[3rd/mruby/mrbgems/mruby-proc-ext/src/proc.c 3rd/mruby/mrbgems/mruby-method/src/method.c]],
    'snap_to_bitmap' => [['RGSS::Bitmap', :nil], %w[mruby-rgss/src/lib.cxx]]
  }.freeze

  EXACT_CORE_KINDS = { 'Array' => { 'to_a' => 'Array' }, 'String' => { 'bytes' => 'Array' } }.freeze

  module_function

  def kinds(name, paths)
    return nil if ENV['BC2CPP_NATIVE_CLASS_RESULTS'] == '0'

    fact = FACTS[name]
    return nil unless fact && !paths.empty?

    kind, allowed = fact
    paths.each do |path|
      relative = allowed.find { |suffix| path.end_with?("/#{suffix}") }
      return nil unless relative

      source = SourceText.read(path, 'native class results', binary: true)
      return nil unless source && Array(FILES.fetch(relative)).include?(Digest::SHA256.hexdigest(source))
    end
    if name == 'parameters' && paths.any? { |path| path.end_with?('/mruby-method/src/method.c') }
      return nil unless paths.any? { |path| path.end_with?('/mruby-proc-ext/src/proc.c') }
    end
    { '<audited-native>' => kind }
  end
end
