# frozen_string_literal: true

require 'digest'

# Outside Ruby definitions of inspect and to_s that the unknown-receiver join may count as String results (NativeReturnClasses
# admission, option B). Each file is pinned by digest and every listed definition was read: each returns a String on every
# path, as a literal, an interpolation or String#%. An edited file drops out of the audit, and a definition not listed here
# keeps its name refused.
module ForeignStringResults
  AUDITED = {
    'mrbgems/mruby-benchmark/mrblib/benchmark.rb' => ['to_s', '38042e44f3794f4e23ee6f05a6247e59214275bcc7b978af84ecc3ef3cd40fb0'],
    'mrbgems/mruby-complex/mrblib/complex.rb' => %w[inspect to_s 33f49419f99ed0094e0024b7ca280ad902986e04aa4ff2163d33aaa0f3f8f59f],
    'mrbgems/mruby-enum-chain/mrblib/chain.rb' => ['inspect', 'a46e4264354951cd19e3ed861dfbfb2b9ad20b9e58b5259cf6d80422a4ec3247'],
    'mrbgems/mruby-enumerator/mrblib/enumerator.rb' => ['inspect', 'da54cc883fb56a855c3a76625501182873aa8c43bbbf787ec8dd7958d72b622b'],
    'mrbgems/mruby-io/mrblib/file.rb' => ['inspect', '032de8f73926513294a9ea8f6e5cdbeaf11489377290298b2a902aeb3bf00cac'],
    'mrbgems/mruby-rational/mrblib/rational.rb' => %w[inspect to_s 0f773e69e017c487bd9f6a504b2db13226b50a6d8444bf86c1700a0c82810db7],
    'mrbgems/mruby-socket/mrblib/socket.rb' => ['inspect', '4b5b8edf257e496c42a834249cc0cf180bcffe49928eba9068e33867b32bedcf']
  }.freeze

  module_function

  # The paths of +paths+ whose audited definitions of +name+ return a String. A path is audited for the name only when
  # the file's digest matches and the name is one of its listed definitions.
  def audited_string_paths(name, paths)
    paths.select do |path|
      AUDITED.any? do |relative, (*names, digest)|
        next false unless path.end_with?("/3rd/mruby/#{relative}") && names.include?(name)

        Digest::SHA256.file(path).hexdigest == digest
      end
    end
  end
end
