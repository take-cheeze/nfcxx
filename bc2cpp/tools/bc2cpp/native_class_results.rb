# frozen_string_literal: true

require 'digest'
require_relative 'source_text'
require_relative 'world_audit_pins'

# All native spellings of a name must belong to pinned, audited files.
# A result fact joins successful returns; it never bypasses the original call.
module NativeClassResults
  BASE_FILES = {
    '3rd/mruby/mrbgems/mruby-io/src/file.c' => %w[cc1202e26515fcf1af8b6014359b05b198bc81214ce20348c07778f037271102 dec83df295fbae0157686e55882e73acebdfa0825edf2ab542cfe51d7f03c53e 2bf54ced4214251c7706ca7bcef3e9ee35293313f10d06cea2ba1d7ab43754fb 762601d078c5ba3c3bee3ea7eaf247e7b61324e06b5e975c363036eb9c25070e e76fb737d2e1f0728e554f34cc53b3b194792ffd5406b58cda716b231156e96d 5faa351f6365b009cd795c90f3b20d6f36ec09df9d38bd80a60d8e78ab4b490d c91d78d0a09ff1e3391606a35e4c2b5e6ade3c1788018071e4721070c8b653ca 55f2068bc101b47740ba55a72298a00e33fbdf91e0fee79cd0b382d703919f6c 23085b96748406651288a3b1a3138baf7f8862f2e09061c49abb2611ff41b85f],
    '3rd/mruby/mrbgems/mruby-array-ext/src/array.c' => %w[8065d3073a5bb5290cafe20df0785ccdfecc0563ef14ac211f203915c1a2fc29 da9cfd32fe7f43f0c6038dc6ba7b773803924e99ccdfbccd56c22cd03ca62fb9 237ee07f0418f986d721ab255b0d0832b9fc552a448c051d7ca78ca12757b0f9],
    '3rd/mruby/src/hash.c' => %w[42d9e2c6d836f08e73fff828fc2cf7988d18cd24c6ae3a29ee71a7d6ee019a16 a2f064d6a6def159eb9209feafb6796925938c7f372ab2be9c6ca008dac991ea 2c5b569866628c74d24b3c0eb7d80ad056054a5bec575004f145089ed87ba3bd 117b20906acbccc99bd3ec2009f7a38e4417be62d64aa77f31abf6b12544e5c8 39b750c1f106a877e68f3fd5fc530da68453368fec46ba3dfbdb98d94dcbe2d7 3deb92092e3cc2ff141f6389ceb9c8c58a6dbec826c366590afe49e1f792f783 77cb6e9212d13461d1d820f4450937c61ca4c7052d60d8220d19b8a45e61dd17 13dcb55856546382bde86692b0f4aace864d6b2fc13528ae69d92338d5db9790 a99e0e4b76be89cd6bb5befae102b54b6b3693ce55a24b109eed7a0c06e1f90c b889e189d6654fa2a468a90a25859dc2d63d167b1a4709f3ee534c3e04b8f9d0],
    '3rd/mruby/src/string.c' => %w[1ea0c045842b4feeefcad548ef79951a5fb3408d31908063fd9fec106de71f00 d4cbdaef5a4e33016077ee8f3855df407edb065a749f0c7ecffc9bf53d6d78bb 816452d8da507aa55a530e92009d779ed13e33a23efd4a59ad0c4914fca49435 185f644347da24d6e737edfcfa8cb397fa1b129802f371547fd7bda3fa86083e 12d6509d187f49322dfe97e553cf5cc9158e1232c06e06c4d6e9ad9c8e3b25a2 2dba5a985cc69589b0716ddf49c97f03e5219e764cdf43dc7adbfbbb1592515e 3cc0244e365e2d2da00902f7cfd76154bf471df9c9d720c5c1b0d5e8ef477193 a17be9146b224e4d14322f26491c77b27b2bfdfcb3ca5c802ad279f4c068d2c9 736df1d65c97341beb4d38b94fe7e4628abc33bd32c6a1dcf32d746e00b7fb35 4acc3c23c91cbb67a22893770fc6c982d777f70e125b5a0f98b86754f335634f],
    '3rd/mruby/src/array.c' => %w[5e0541466b6aa9c8eaab0bcc7d51db15babae7059871854eeef81f08ac53dc11 7cc81d821c7893fd5bbc510cdaa3c2601d752e7fbf3947466c55620732cdf815 f1005278741bcca9df7af75eb91fed84f1fd73e8ba19bc69bd402475359a9c24 0e73f68c2aa22a497b9106d043931f5e4bbebef1b6c56f3acd8395bdf04cb30f a6e2a6f1c458a8038194d412a6c4d6dc9492df37a077060bed4c1ef4b9eac990 2b40b18506870ad9abe76c0464ae654336fd51b3c19ff4091ee913726da8b953 50974198d1a5b991d91371b29b60e2c2cc6aa231593162b1f5e735f14f5f66f5 227b0d17190eb8d440fb919ea47df4e1c77c6e34c170ad1381d39f1a2fd8b11d],
    '3rd/mruby/mrbgems/mruby-struct/src/struct.c' => %w[2e536e12e4bcfc62d7581966860789eb31edcf6282e2ec67ec70e85db34fbec5 bb57a55a157602b58e0218f3f5e2d1f5175a0d1b36e43388af390896fb672027 4595331af0ecdba1bc68e4aeb51f7370626a9ce7cb18bb6ee66f52aa2d4d2201 87b19876a9a6e6ffbe40f66a59c964a1f7c8c854905b99cf4949dac3f81e75cc],
    '3rd/mruby/mrbgems/mruby-proc-ext/src/proc.c' => %w[01a0156d300517eba92d8a00d36d8ee1b9d3cb7a29420d7b815711ab00a39e45 912d1b2ba1f94dbcb802e542844d9af4c10a7f1650c0bb6d14f529878a437c9f 697406b57d58d9b175d3370776648d1699e098aaca541466bb1288086306af64 ee85e4424372ca2070e81349fb50236acc491e99ed1e37e4b897f3e888eb057e],
    '3rd/mruby/mrbgems/mruby-method/src/method.c' => %w[d2a780ca6a3ef25297c8f60356ad56a61fb826a2d5759059a25cdddb9820b0eb 993cb705bfd9e6392afc71bac97b8e8d6dee758b40b98528d477badb0248b9f4 c418c0c335065591394b055558e3c312413d0eacaf4aabc932855284b6c54525],
    '3rd/mruby/src/symbol.c' => %w[67b5e5b5908086aea28495c0f66bcf70fdab5c2e3d8347d49bda7b31e4683f5b 2fc364c65eda66d2bc4f2345150c394e1666678b55b93bf6f2d0fb47e5bc1c09 4c4326db94944063fc45340b57bd98e3f3ee2c7df49d3e9455e85061a4f737ee 27a6b09818ddbd633e3dcdfa47e520b6f97ba19544632d98259cd8e0cf75c7ce 235ce9931f27e0dfd1f0330c6a22bf69f1a3b1cfa57cc2005a89bb6e2d0a9621 ec0b8f106cee07acd2c960c8607cfce95a2597d5792e1a58b9656c2daf6c3b80 8c7b6e3cc3349a2779725fbcb83ba072104df8aebe288f9dbf97c8d07d947850 9cefc2d7d49de23dcae14e0922ed33e0fe1d4b72bba269c78c097187de4ee82b 8161a2a0c9d93eb3c5f0bb4ef7b21dc19da47607589feaf0fb2f74d29a1122c7],
    '3rd/mruby/src/numeric.c' => %w[acbb9d47dd61e15a87ffbdae468884e977ce09f73e2a8fa5f52e63cb71a7400e f0aca40e0aa523deaa32325a6bca09ddd6ad6626b05e089323461dc45739c33f a04d6dda0b7809ccfda3ada4a8d8be599424ea365bafaedee0e09e2ab010e40a 707769a6e38d955b9f6969dc768d2ea46cf9538996ad76e91514f9daa2613c4c 6f2295f582a3eb4ab951d5e252f41052d1fc353638f7af63bfa262c2ae77b5e0 510e63059d5b4e695ecde5fd759876cce097c496df79610458f750d90e9fe365 5a084e6f7c265b87fc229aa71747a74eb1c4b77657ecb55ef5731dca63c12457 d561495b2df083bc60302fbe989f7b80b227963bbbf527986ef934435143ceb6],
    '3rd/mruby/src/error.c' => %w[8c87c4fd2d130cd3dab0309c23ec5d7948f6f0c9e8f44a59e6c0e574ff02b4ea 96399cfebc605a210926137a909c4b9eba51bf6f5119c0421c4f5071d566200f 84c4050fdaec7290a580881a101a74fb484a2b2feb4d03bebd303f937382b4e7 82e7258260d880795fe335f058a9822c7a599e8a32ed58cc453f45102baf24d3 db034099628c92025e7ff856405a7be863d0978998c871c973044dfd2c6f4d72 65a3978970527ef59625b2487b3c90f33b0e292cd28543d933abc9445649b54c],
    '3rd/mruby/src/range.c' => %w[9125dd2ce60f6055e1f81a645a5bf752e96cc44438e90384b8dcb4870dc12326 91e951ba6346662401fc5bccc3d47445c308c0ceb8f9812deb2f84def5a9f8a6 47018ff7d5c46fc05e468f5dee97319f4c6a0585f6e62054b3cc6c840381266d],
    '3rd/mruby/src/class.c' => %w[1ebf572f5176de2cb7bae543074fe478bcbcba4b176874993c4385053650ea6e 71a68c2a3624847a6b0b96702c11b2b19e379eda5b2218290c59579825717d34 2eb5cdb68a72c0ab7dbc7649ede45305608e73a558fbcef3250d5138edf3df3d 9517813ebc5ee9522f7f8ff0c28d8b5dd7d48a3c8dc672bcba099dd32f74df16 e31af101ae0cea10e919a5c35e793367bd39fc474f2c79ef71d595104b9f8c6a 83642280c9dc2c8bc92cf39e3bc7ec6ca73c772f9d0f587ae6e5094fb602832b 8727b48cf07a6608c9ff4120a4e290262f8c043e78193bcb7ef1638618a23cd6 c154da7c93744b13ff753fbbbc19a87da1e72f093267423002fec31db34f4e56 7d5ad8134920af2b93d86dad5028902f648c89b94a615116b85b236f026678e8 07e41a2c3b3dc93f6a0b5546f1196c99d3c3b17626bab640ae7301821b92f78b 4b3b42896d13be5979bfbc750b71e8a28d8b1714ab119a3835db4379eb0b1026 3a6546b95fd9364cfcdeff6980bbce603b37de33e9be1881df275944cdb77230 80d31fda8e4f8b3333cc7a0be601884b158b4100bdb9f4c9435e4a77bbf9f395 2f1c9cacb4094de2a980e7277797903043bd7a74b21b53cd1dacdbd5c0d734e2 a12c0735e9469d46bfa4ec0da71c673453ec81a29d3f08ce49d79565a818ed41 0b1d312ef08ac6f7d47d9da4f23e826d4a4988deba78dd052152828bd0e912cc b124568b776f132f71468b4fba08c2dba900d7842d35b302419adbe5fa88bfa4 a4bacdd7523ac55649ccb66dd72f4d7bf6d4e7726779cb45605f1f0b3bd0c2d6 4eeabaf3e3fb0a0c79f7831efa0d81194783d9f1dc4bb5ca8925fa846954133c c61bc1d54bb309a4dfd1d5e7f2fe2780f19c9b03d3d5a3fc08a934906c1059ce b38db94d096b1a9c00851adb53d273d09c46e5b43baddaf7289266740e538e26],
    '3rd/mruby/src/kernel.c' => %w[21d203d387e8ec2f87b59c80baf53e40840901d7bb74ce0d3c22ea22bca9c9a5 16cece84c81806a95bdd1e99008cf3f38b94cd66c48f3c915ae059a915a5b6e9 3081a504dd1822a192885c40fb2a58d7f2edee2b7d6ec9a89b09b83a293724a4 ffd6aaf983f0fb1d371962e64abfe04f34fee3f16a70f7c117c5fbb723b84e53 c6d2091a72b80ce296843db25fbc8f3693638e260423d7724d13f4302033c638 d3359c10fc49f1a6f821c9fbff3fb7e5d22fa08939fcc0a8ba417d9a64317412 f52c304bbc644730d685e93f93d903b146e9c0b2393a9444770d6e28a639b6b5 b3f8c6e9cd41c35fdeed002efe8b9317d54c04bea22fa8503cd0ca33e50ebd12 e4fd7418f5976062218786f5a9bc7137b2ea7f8fc4f7b079cdbb3c6c428fea24 f2eeaec1fd8510cc05d3b2cae317d424db6f922a869876ff0d19bdd9e310b28e],
    '3rd/mruby/src/object.c' => %w[a96aa77eef22b24563f79423d4f041694d7a5fc1b2a004f53fa9b01a59afd631 93634c98042c08fba168f63b2e58c069cb5eedee172da45d0ecb3f4025880347 4f59d60231f66a29226c76f0f2d9b33e2e1b78c416c1a539dc4781fd2ef112af bf56e47011e6f2447c19e5d79b8f882e82eb327e7f3d52c4ba1c2b5dbe613b9b c681a2afcca9835af7ad3d639bacf36d2e8bd2cea25dbb1b21d637aa891673a3 41d34c7035b42c9a85ba19ed01962269a62a097a8a00c629cade9057a677cd22 c7523f7c3c07021e4765aae3a1ed2d840ac6c6340a084091d38b0a9a69a2738c ad9931909eb250d0d16d40bc18e9ab9a1e46d1d65ac7fa8ada3df77c0a76fb1f],
    '3rd/mruby/mrbgems/mruby-time/src/time.c' => %w[57977397bbf2cc3aa29eae3dacae862b3c4a49810fb588dc7702e784279490a9 5b1d0eefeafff9cc6a445f3acf9b4e594a4be16dddbfbba7d8a08fa60c35345d f0b0ed9be8a59fd8709430177c446997418188957d84a72d6881329a991f53fb b8e190bd03002adb8f6b2898402e5a537df9e95a0a5f41a31ba5892b897151cb b96bb62f73e43c0053649f4a35a8d00e87e5f433a314a9b7fad0aa5e0bcc177b],
    '3rd/mruby/mrbgems/mruby-bigint/core/bigint.c' => %w[dcc607215eb53346f5a2e5b760314f06afa9f629ad3c2f14e18f56059a29117f c32092a6670bc77ca978eb093cd8af6d4dcfa947ce826bbe30834483fde5dad4 70323f33bac648d3749f118a482652ac07c3845d497f2fcbd31d1ec7a96ad5fa],
    '3rd/mruby-onig-regexp/src/mruby_onig_regexp.c' => '4b00efbb0d4b26bb8310aff773b8e4d2abf05dca6a993ebd963f69fa9c6cf397',
    '3rd/mruby/mrbgems/mruby-fiber/src/fiber.c' => '5b8aa22575a772a0fb0a194c1720233307f7034a0704e362a315bd30fb44512f',
    '3rd/mruby/mrbgems/mruby-symbol-ext/src/symbol.c' => 'ed25d0529c93ebbddb6fc5c27bf011a677e6d0816a938168c49ab71d716ac71b',
    '3rd/mruby/mrbgems/mruby-set/src/set.c' => 'c710f64f2a50650c0be29c01bb96f00fb61c01d1d3f1e0fa99816ecf29d06912',
    '3rd/mruby-stringio/src/stringio.c' => '624a40811e85cd00d92afaffc251a7b9c55f564c87eb71115e9e7d88cb68f716',
    '3rd/mruby/mrbgems/mruby-object-ext/src/object.c' => '4de3d5c2ca92e7ca4a5236140a330684dc29d8b7ef29cff178642b5fa43c79a1',
    '3rd/mruby/mrbgems/mruby-io/src/io.c' => %w[a5acfe9c7071406389df5aaa036f9619de1cba65f78eeffeefd8786144d74e9b eb0952cb7bfc2ed0f82cd73c00b9daf8309dad5ce6c6b3b69996648d314cc6a5],
  }.freeze
  FILES = BASE_FILES.merge(WorldAuditPins.class_result_files).freeze
  ARRAY_TRANSFORMS = %w[compact flatten __uniq join].freeze
  # NATIVE_INTEGER_RESULTS: every registration of these names in the listed files returns mrb_int_value or
  # mrb_fixnum_value (an Integer, maybe a heap one) or raises. Time#to_i is a Float when time_t passes mrb_int
  # without mruby-bigint, so a to_i that time.c also defines joins Float in (see kinds).
  INTEGER_RESULTS = %w[length bytesize to_i].freeze
  BASE_FACTS = {
    'join' => ['String', %w[3rd/mruby/src/array.c 3rd/mruby/mrbgems/mruby-io/src/file.c]],
    'compact' => ['Array', %w[3rd/mruby/mrbgems/mruby-array-ext/src/array.c]],
    'flatten' => ['Array', %w[3rd/mruby/mrbgems/mruby-array-ext/src/array.c]],
    '__uniq' => ['Array', %w[3rd/mruby/mrbgems/mruby-array-ext/src/array.c]],
    '__num_to_a' => [['Array', :nil], %w[3rd/mruby/src/range.c]],
    'length' => [:integer, %w[
      3rd/mruby/src/array.c 3rd/mruby/src/string.c 3rd/mruby/src/hash.c 3rd/mruby/mrbgems/mruby-struct/src/struct.c
      3rd/mruby/mrbgems/mruby-symbol-ext/src/symbol.c 3rd/mruby/mrbgems/mruby-set/src/set.c
      3rd/mruby-onig-regexp/src/mruby_onig_regexp.c 3rd/mruby-stringio/src/stringio.c
    ]],
    'bytesize' => [:integer, %w[3rd/mruby/src/string.c]],
    'to_i' => [:integer, %w[
      3rd/mruby/src/string.c 3rd/mruby/src/numeric.c 3rd/mruby/mrbgems/mruby-object-ext/src/object.c
      3rd/mruby/mrbgems/mruby-time/src/time.c 3rd/mruby/mrbgems/mruby-io/src/io.c
    ]],
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
    ]]
  }.freeze

  FACTS = WorldAuditPins.merge_facts(BASE_FACTS)

  STRUCT_ALIAS_PATH = '3rd/mruby/mrbgems/mruby-struct/mrblib/struct.rb'
  STRUCT_ALIAS_SHA = '6d651f44caf2f46e15ee6569426cdaabe8721c1405fdcfa6592a767aca1cb5e1'

  module_function

  # Kill switch for NATIVE_INTEGER_RESULTS: BC2CPP_NATIVE_INTEGER_RESULTS=0 drops those facts.
  def integer_results?
    ENV['BC2CPP_NATIVE_INTEGER_RESULTS'] != '0'
  end

  def source_matches?(path, relative, digest = FILES[relative])
    return false unless path.is_a?(String) && path.end_with?("/#{relative}") && digest

    source = SourceText.read(path, 'native class results', binary: true)
    source && Array(digest).include?(Digest::SHA256.hexdigest(source))
  end

  def kinds(name, paths, string_subclass_free: false)
    return nil if ENV['BC2CPP_NATIVE_CLASS_RESULTS'] == '0'
    return nil if name == '__num_to_a' && ENV['BC2CPP_CORE_RUBY_NESTED_RESULTS'] == '0'

    return nil if ARRAY_TRANSFORMS.include?(name) && ENV['BC2CPP_NATIVE_ARRAY_TRANSFORMS'] == '0'
    return nil if INTEGER_RESULTS.include?(name) && !integer_results?
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
    kind = [:integer, :float] if name == 'to_i' && paths.any? { |path| path.end_with?('/mruby-time/src/time.c') }
    if name == 'parameters' && paths.any? { |path| path.end_with?('/mruby-method/src/method.c') }
      return nil unless paths.any? { |path| path.end_with?('/mruby-proc-ext/src/proc.c') }
    end
    { '<audited-native>' => kind }
  end
end
