# frozen_string_literal: true

require 'digest'
require_relative 'source_text'

# ADRs 0333–0336: all native spellings of a name must belong to pinned, audited files.
# A result fact joins successful returns; it never bypasses the original call.
module NativeClassResults
  FILES = {
    '3rd/mruby/mrbgems/mruby-io/src/file.c' => %w[cc1202e26515fcf1af8b6014359b05b198bc81214ce20348c07778f037271102 dec83df295fbae0157686e55882e73acebdfa0825edf2ab542cfe51d7f03c53e 2bf54ced4214251c7706ca7bcef3e9ee35293313f10d06cea2ba1d7ab43754fb],
    '3rd/mruby/mrbgems/mruby-array-ext/src/array.c' => '8065d3073a5bb5290cafe20df0785ccdfecc0563ef14ac211f203915c1a2fc29',
    '3rd/mruby/src/hash.c' => '42d9e2c6d836f08e73fff828fc2cf7988d18cd24c6ae3a29ee71a7d6ee019a16',
    '3rd/mruby/src/string.c' => %w[1ea0c045842b4feeefcad548ef79951a5fb3408d31908063fd9fec106de71f00 d4cbdaef5a4e33016077ee8f3855df407edb065a749f0c7ecffc9bf53d6d78bb],
    '3rd/mruby/src/array.c' => %w[5e0541466b6aa9c8eaab0bcc7d51db15babae7059871854eeef81f08ac53dc11 7cc81d821c7893fd5bbc510cdaa3c2601d752e7fbf3947466c55620732cdf815],
    '3rd/mruby/mrbgems/mruby-struct/src/struct.c' => %w[2e536e12e4bcfc62d7581966860789eb31edcf6282e2ec67ec70e85db34fbec5 bb57a55a157602b58e0218f3f5e2d1f5175a0d1b36e43388af390896fb672027],
    '3rd/mruby/mrbgems/mruby-proc-ext/src/proc.c' => %w[01a0156d300517eba92d8a00d36d8ee1b9d3cb7a29420d7b815711ab00a39e45 912d1b2ba1f94dbcb802e542844d9af4c10a7f1650c0bb6d14f529878a437c9f],
    '3rd/mruby/mrbgems/mruby-method/src/method.c' => 'd2a780ca6a3ef25297c8f60356ad56a61fb826a2d5759059a25cdddb9820b0eb',
    '3rd/mruby/src/symbol.c' => %w[2fc364c65eda66d2bc4f2345150c394e1666678b55b93bf6f2d0fb47e5bc1c09 4c4326db94944063fc45340b57bd98e3f3ee2c7df49d3e9455e85061a4f737ee],
    '3rd/mruby/src/numeric.c' => %w[acbb9d47dd61e15a87ffbdae468884e977ce09f73e2a8fa5f52e63cb71a7400e f0aca40e0aa523deaa32325a6bca09ddd6ad6626b05e089323461dc45739c33f],
    '3rd/mruby/src/error.c' => %w[8c87c4fd2d130cd3dab0309c23ec5d7948f6f0c9e8f44a59e6c0e574ff02b4ea 96399cfebc605a210926137a909c4b9eba51bf6f5119c0421c4f5071d566200f],
    '3rd/mruby/src/range.c' => '9125dd2ce60f6055e1f81a645a5bf752e96cc44438e90384b8dcb4870dc12326',
    '3rd/mruby/src/class.c' => %w[71a68c2a3624847a6b0b96702c11b2b19e379eda5b2218290c59579825717d34 2eb5cdb68a72c0ab7dbc7649ede45305608e73a558fbcef3250d5138edf3df3d],
    '3rd/mruby/src/kernel.c' => %w[21d203d387e8ec2f87b59c80baf53e40840901d7bb74ce0d3c22ea22bca9c9a5 16cece84c81806a95bdd1e99008cf3f38b94cd66c48f3c915ae059a915a5b6e9],
    '3rd/mruby/src/object.c' => 'a96aa77eef22b24563f79423d4f041694d7a5fc1b2a004f53fa9b01a59afd631',
    '3rd/mruby/mrbgems/mruby-time/src/time.c' => '57977397bbf2cc3aa29eae3dacae862b3c4a49810fb588dc7702e784279490a9',
    '3rd/mruby/mrbgems/mruby-bigint/core/bigint.c' => 'dcc607215eb53346f5a2e5b760314f06afa9f629ad3c2f14e18f56059a29117f',
    '3rd/mruby-onig-regexp/src/mruby_onig_regexp.c' => '2c2bf2d5a96850e22b791b7e191e37867d1a3f2892e0ae5be632d71cc97d1884',
    '3rd/mruby/mrbgems/mruby-fiber/src/fiber.c' => '5b8aa22575a772a0fb0a194c1720233307f7034a0704e362a315bd30fb44512f',
    'mruby-rgss/src/lib.cxx' => %w[664be94f4af8b7081cbf5679267d6fca1a4ce713423d850ae5478ed2c4921f1e 24834066d96a347cbd2671459e67b544f684d78bb27ae7419750c7e77a083b2c]
  }.freeze
  ARRAY_TRANSFORMS = %w[compact flatten __uniq join].freeze
  FACTS = {
    'join' => ['String', %w[3rd/mruby/src/array.c 3rd/mruby/mrbgems/mruby-io/src/file.c]],
    'compact' => ['Array', %w[3rd/mruby/mrbgems/mruby-array-ext/src/array.c]],
    'flatten' => ['Array', %w[3rd/mruby/mrbgems/mruby-array-ext/src/array.c]],
    '__uniq' => ['Array', %w[3rd/mruby/mrbgems/mruby-array-ext/src/array.c]],
    '__num_to_a' => [['Array', :nil], %w[3rd/mruby/src/range.c]],
    'keys' => ['Array', %w[3rd/mruby/src/hash.c]],
    'values' => ['Array', %w[3rd/mruby/src/hash.c 3rd/mruby/mrbgems/mruby-struct/src/struct.c]],
    'bytes' => ['Array', %w[3rd/mruby/src/string.c]],
    'split' => ['Array', %w[3rd/mruby/src/string.c]],
    'members' => ['Array', %w[3rd/mruby/mrbgems/mruby-struct/src/struct.c]],
    'to_a' => ['Array', %w[3rd/mruby/src/array.c 3rd/mruby/mrbgems/mruby-struct/src/struct.c]],
    'parameters' => ['Array', %w[3rd/mruby/mrbgems/mruby-proc-ext/src/proc.c 3rd/mruby/mrbgems/mruby-method/src/method.c]],
    'to_s' => ['String', %w[
      3rd/mruby/mrbgems/mruby-fiber/src/fiber.c
      3rd/mruby/src/symbol.c
      3rd/mruby/src/numeric.c
      3rd/mruby/src/error.c
      3rd/mruby/src/range.c
      3rd/mruby/src/class.c
      3rd/mruby/src/kernel.c
      3rd/mruby/src/object.c
      3rd/mruby/mrbgems/mruby-time/src/time.c
      3rd/mruby/mrbgems/mruby-bigint/core/bigint.c
      3rd/mruby/src/hash.c
      3rd/mruby/src/string.c
      3rd/mruby/src/array.c
      3rd/mruby/mrbgems/mruby-struct/src/struct.c
      3rd/mruby/mrbgems/mruby-proc-ext/src/proc.c
      3rd/mruby/mrbgems/mruby-method/src/method.c
      3rd/mruby-onig-regexp/src/mruby_onig_regexp.c
      mruby-rgss/src/lib.cxx
    ]],
    'snap_to_bitmap' => [['RGSS::Bitmap', :nil], %w[mruby-rgss/src/lib.cxx]]
  }.freeze

  STRUCT_ALIAS_PATH = '3rd/mruby/mrbgems/mruby-struct/mrblib/struct.rb'
  STRUCT_ALIAS_SHA = '6d651f44caf2f46e15ee6569426cdaabe8721c1405fdcfa6592a767aca1cb5e1'

  EXACT_CORE_KINDS = { 'Array' => { 'to_a' => 'Array', 'compact' => 'Array', 'join' => 'String' }, 'String' => { 'bytes' => 'Array' } }.freeze

  module_function

  def source_matches?(path, relative, digest = FILES[relative])
    return false unless path.is_a?(String) && path.end_with?("/#{relative}") && digest

    source = SourceText.read(path, 'native class results', binary: true)
    source && Array(digest).include?(Digest::SHA256.hexdigest(source))
  end

  # compact delegates allocation to core Array; both complete bodies are pinned.
  def core_result_pinned?(name, klass, paths)
    if klass == 'Array' && name == 'compact'
      relative = '3rd/mruby/mrbgems/mruby-array-ext/src/array.c'
      path = paths.find { |candidate| source_matches?(candidate, relative) }
      return false unless path

      helper = path.delete_suffix('/mrbgems/mruby-array-ext/src/array.c') + '/src/array.c'
      return source_matches?(helper, '3rd/mruby/src/array.c')
    end
    relative = klass == 'Array' ? '3rd/mruby/src/array.c' : '3rd/mruby/src/string.c'
    paths.any? { |path| source_matches?(path, relative) }
  end

  def kinds(name, paths, string_subclass_free: false)
    return nil if ENV['BC2CPP_NATIVE_CLASS_RESULTS'] == '0'
    return nil if name == '__num_to_a' && ENV['BC2CPP_CORE_RUBY_NESTED_RESULTS'] == '0'

    return nil if ARRAY_TRANSFORMS.include?(name) && ENV['BC2CPP_NATIVE_ARRAY_TRANSFORMS'] == '0'
    return nil if %w[compact join].include?(name) && ENV['BC2CPP_NATIVE_COLLECTION_RESULTS'] == '0'

    return nil if name == 'to_s' && (ENV['BC2CPP_NATIVE_STRING_RESULTS'] == '0' || !string_subclass_free)

    fact = FACTS[name]
    return nil unless fact && !paths.empty?

    kind, allowed = fact
    paths.each do |path|
      relative = allowed.find { |suffix| path.end_with?("/#{suffix}") }
      return nil unless relative

      source = SourceText.read(path, 'native class results', binary: true)
      return nil unless source && Array(FILES.fetch(relative)).include?(Digest::SHA256.hexdigest(source))
    end
    # File.join's single-component path returns its argument unchanged (ADR 0336).
    if name == 'join' && paths.any? { |path| path.end_with?('/mruby-io/src/file.c') }
      return nil unless string_subclass_free
    end
    if ARRAY_TRANSFORMS.include?(name)
      paths.each do |path|
        relative = name == 'join' ? '3rd/mruby/src/string.c' : '3rd/mruby/src/array.c'
        if name == 'join'
          root = path.end_with?('/src/array.c') ? path.delete_suffix('/src/array.c') : path.delete_suffix('/mrbgems/mruby-io/src/file.c')
          return nil unless source_matches?(root + '/src/array.c', '3rd/mruby/src/array.c')

          helper = root + '/src/string.c'
        else
          helper = path.delete_suffix('/mrbgems/mruby-array-ext/src/array.c') + '/src/array.c'
        end
        return nil unless source_matches?(helper, relative)
      end
    end
    if name == '__num_to_a'
      paths.each do |path|
        helper = path.delete_suffix('/src/range.c') + '/src/array.c'
        return nil unless source_matches?(helper, '3rd/mruby/src/array.c')
      end
    end
    if name == 'to_s'
      numeric = paths.find { |path| path.end_with?('/3rd/mruby/src/numeric.c') }
      return nil unless numeric

      kind = ['String', :nil] if paths.any? { |path| path.end_with?('/mruby-onig-regexp/src/mruby_onig_regexp.c') }
      helper = numeric.delete_suffix('/src/numeric.c') + '/mrbgems/mruby-bigint/core/bigint.c'
      source = SourceText.read(helper, 'native class results', binary: true)
      return nil unless source && Digest::SHA256.hexdigest(source) == FILES.fetch('3rd/mruby/mrbgems/mruby-bigint/core/bigint.c')
    end
    if name == 'parameters' && paths.any? { |path| path.end_with?('/mruby-method/src/method.c') }
      return nil unless paths.any? { |path| path.end_with?('/mruby-proc-ext/src/proc.c') }
    end
    { '<audited-native>' => kind }
  end
end
