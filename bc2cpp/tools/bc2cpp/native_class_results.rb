# frozen_string_literal: true

require 'digest'
require_relative 'source_text'

# All native spellings of a name must belong to pinned, audited files.
# A result fact joins successful returns; it never bypasses the original call.
module NativeClassResults
  FILES = {
    '3rd/mruby/mrbgems/mruby-io/src/file.c' => %w[cc1202e26515fcf1af8b6014359b05b198bc81214ce20348c07778f037271102 dec83df295fbae0157686e55882e73acebdfa0825edf2ab542cfe51d7f03c53e 2bf54ced4214251c7706ca7bcef3e9ee35293313f10d06cea2ba1d7ab43754fb 762601d078c5ba3c3bee3ea7eaf247e7b61324e06b5e975c363036eb9c25070e e76fb737d2e1f0728e554f34cc53b3b194792ffd5406b58cda716b231156e96d],
    '3rd/mruby/mrbgems/mruby-array-ext/src/array.c' => %w[8065d3073a5bb5290cafe20df0785ccdfecc0563ef14ac211f203915c1a2fc29 da9cfd32fe7f43f0c6038dc6ba7b773803924e99ccdfbccd56c22cd03ca62fb9],
    '3rd/mruby/src/hash.c' => %w[42d9e2c6d836f08e73fff828fc2cf7988d18cd24c6ae3a29ee71a7d6ee019a16 a2f064d6a6def159eb9209feafb6796925938c7f372ab2be9c6ca008dac991ea 2c5b569866628c74d24b3c0eb7d80ad056054a5bec575004f145089ed87ba3bd 117b20906acbccc99bd3ec2009f7a38e4417be62d64aa77f31abf6b12544e5c8],
    '3rd/mruby/src/string.c' => %w[1ea0c045842b4feeefcad548ef79951a5fb3408d31908063fd9fec106de71f00 d4cbdaef5a4e33016077ee8f3855df407edb065a749f0c7ecffc9bf53d6d78bb 816452d8da507aa55a530e92009d779ed13e33a23efd4a59ad0c4914fca49435 185f644347da24d6e737edfcfa8cb397fa1b129802f371547fd7bda3fa86083e 12d6509d187f49322dfe97e553cf5cc9158e1232c06e06c4d6e9ad9c8e3b25a2],
    '3rd/mruby/src/array.c' => %w[5e0541466b6aa9c8eaab0bcc7d51db15babae7059871854eeef81f08ac53dc11 7cc81d821c7893fd5bbc510cdaa3c2601d752e7fbf3947466c55620732cdf815 f1005278741bcca9df7af75eb91fed84f1fd73e8ba19bc69bd402475359a9c24 0e73f68c2aa22a497b9106d043931f5e4bbebef1b6c56f3acd8395bdf04cb30f],
    '3rd/mruby/mrbgems/mruby-struct/src/struct.c' => %w[2e536e12e4bcfc62d7581966860789eb31edcf6282e2ec67ec70e85db34fbec5 bb57a55a157602b58e0218f3f5e2d1f5175a0d1b36e43388af390896fb672027 4595331af0ecdba1bc68e4aeb51f7370626a9ce7cb18bb6ee66f52aa2d4d2201],
    '3rd/mruby/mrbgems/mruby-proc-ext/src/proc.c' => %w[01a0156d300517eba92d8a00d36d8ee1b9d3cb7a29420d7b815711ab00a39e45 912d1b2ba1f94dbcb802e542844d9af4c10a7f1650c0bb6d14f529878a437c9f 697406b57d58d9b175d3370776648d1699e098aaca541466bb1288086306af64 ee85e4424372ca2070e81349fb50236acc491e99ed1e37e4b897f3e888eb057e],
    '3rd/mruby/mrbgems/mruby-method/src/method.c' => %w[d2a780ca6a3ef25297c8f60356ad56a61fb826a2d5759059a25cdddb9820b0eb 993cb705bfd9e6392afc71bac97b8e8d6dee758b40b98528d477badb0248b9f4],
    '3rd/mruby/src/symbol.c' => %w[2fc364c65eda66d2bc4f2345150c394e1666678b55b93bf6f2d0fb47e5bc1c09 4c4326db94944063fc45340b57bd98e3f3ee2c7df49d3e9455e85061a4f737ee 27a6b09818ddbd633e3dcdfa47e520b6f97ba19544632d98259cd8e0cf75c7ce 235ce9931f27e0dfd1f0330c6a22bf69f1a3b1cfa57cc2005a89bb6e2d0a9621],
    '3rd/mruby/src/numeric.c' => %w[acbb9d47dd61e15a87ffbdae468884e977ce09f73e2a8fa5f52e63cb71a7400e f0aca40e0aa523deaa32325a6bca09ddd6ad6626b05e089323461dc45739c33f a04d6dda0b7809ccfda3ada4a8d8be599424ea365bafaedee0e09e2ab010e40a 707769a6e38d955b9f6969dc768d2ea46cf9538996ad76e91514f9daa2613c4c],
    '3rd/mruby/src/error.c' => %w[8c87c4fd2d130cd3dab0309c23ec5d7948f6f0c9e8f44a59e6c0e574ff02b4ea 96399cfebc605a210926137a909c4b9eba51bf6f5119c0421c4f5071d566200f 84c4050fdaec7290a580881a101a74fb484a2b2feb4d03bebd303f937382b4e7 82e7258260d880795fe335f058a9822c7a599e8a32ed58cc453f45102baf24d3],
    '3rd/mruby/src/range.c' => %w[9125dd2ce60f6055e1f81a645a5bf752e96cc44438e90384b8dcb4870dc12326 91e951ba6346662401fc5bccc3d47445c308c0ceb8f9812deb2f84def5a9f8a6],
    '3rd/mruby/src/class.c' => %w[71a68c2a3624847a6b0b96702c11b2b19e379eda5b2218290c59579825717d34 2eb5cdb68a72c0ab7dbc7649ede45305608e73a558fbcef3250d5138edf3df3d 9517813ebc5ee9522f7f8ff0c28d8b5dd7d48a3c8dc672bcba099dd32f74df16 e31af101ae0cea10e919a5c35e793367bd39fc474f2c79ef71d595104b9f8c6a 83642280c9dc2c8bc92cf39e3bc7ec6ca73c772f9d0f587ae6e5094fb602832b 8727b48cf07a6608c9ff4120a4e290262f8c043e78193bcb7ef1638618a23cd6 c154da7c93744b13ff753fbbbc19a87da1e72f093267423002fec31db34f4e56],
    '3rd/mruby/src/kernel.c' => %w[21d203d387e8ec2f87b59c80baf53e40840901d7bb74ce0d3c22ea22bca9c9a5 16cece84c81806a95bdd1e99008cf3f38b94cd66c48f3c915ae059a915a5b6e9 3081a504dd1822a192885c40fb2a58d7f2edee2b7d6ec9a89b09b83a293724a4],
    '3rd/mruby/src/object.c' => %w[a96aa77eef22b24563f79423d4f041694d7a5fc1b2a004f53fa9b01a59afd631 93634c98042c08fba168f63b2e58c069cb5eedee172da45d0ecb3f4025880347],
    '3rd/mruby/mrbgems/mruby-time/src/time.c' => %w[57977397bbf2cc3aa29eae3dacae862b3c4a49810fb588dc7702e784279490a9 5b1d0eefeafff9cc6a445f3acf9b4e594a4be16dddbfbba7d8a08fa60c35345d f0b0ed9be8a59fd8709430177c446997418188957d84a72d6881329a991f53fb],
    '3rd/mruby/mrbgems/mruby-bigint/core/bigint.c' => 'dcc607215eb53346f5a2e5b760314f06afa9f629ad3c2f14e18f56059a29117f',
    '3rd/mruby-onig-regexp/src/mruby_onig_regexp.c' => '2c2bf2d5a96850e22b791b7e191e37867d1a3f2892e0ae5be632d71cc97d1884',
    '3rd/mruby/mrbgems/mruby-fiber/src/fiber.c' => '5b8aa22575a772a0fb0a194c1720233307f7034a0704e362a315bd30fb44512f',
    'mruby-rgss/src/lib.cxx' => %w[664be94f4af8b7081cbf5679267d6fca1a4ce713423d850ae5478ed2c4921f1e 24834066d96a347cbd2671459e67b544f684d78bb27ae7419750c7e77a083b2c
                                 0dc8534bc7cabd36a10818deedd7559a61691dee1bf23d5e05febf11e3ca202e
                                 105657191ab86f45ba563ddf8e5818c1cb5a912d7cfce02c7b6ffe32a2a5f12b
                                 eda898bc7ee051089bbba85bdb74f7cd4f892966c8df49a687ea7f7c9d570eb0]
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

  module_function

  def source_matches?(path, relative, digest = FILES[relative])
    return false unless path.is_a?(String) && path.end_with?("/#{relative}") && digest

    source = SourceText.read(path, 'native class results', binary: true)
    source && Array(digest).include?(Digest::SHA256.hexdigest(source))
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
    # File.join's single-component path returns its argument unchanged.
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
