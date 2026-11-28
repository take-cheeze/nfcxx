# frozen_string_literal: true

require 'digest'
require 'stringio'

# OWNER_SET_SHARE: owner calls with the same method, level and owner list share one descriptor and one
# bc2cpp_owner_set, where each would otherwise declare its own (BC2CPP_OWNERS, symbol_cache.rb). Everything the set
# keeps is a function of those three: the matched owners (`seen`) of the owner list, and the inline cache, a found
# method for (receiver class, argc) of the site's method id; the level decides the private, protected and
# argument-count checks a hit skips, so a self call (level 0) never shares with an explicit-receiver one. A shared
# site reads `BC2CPP_SHARED(<key>, <slot>, <level>, <owners>...)`, which names bc2cpp_owner_sd_<key>; the owner list,
# the descriptor and the set are defined once, after DEFS_AT, as inline variables: one per program across the shards.
# The key hashes the gem's symbol in too, since the method id indexes the gem's own symbol table. Sites with direct
# rows (BC2CPP_OWNERS_D) keep their own.
#
# Only a real gem build shares (the proof's generation and a fixture keep the sites as they are);
# BC2CPP_OWNER_SET_SHARE=1 or =0 forces either.
module OwnerSetShare
  SITE = /(bc2cpp_owner_call(?:_argv)?\(M, [^\n]*?, )BC2CPP_OWNERS\((\d+), ([0-2]), ("[^"\\\n]*"(?:, "[^"\\\n]*")*)\)/
  # The line of symbol_cache.rb's OWNER_CALL the definitions follow: after the macro, before every site.
  DEFS_AT = "#define BC2CPP_SHARED(K, ...) (&bc2cpp_owner_sd_##K)\n"

  module_function

  # +real+: the run is a real gem build.
  def enabled?(real)
    case ENV['BC2CPP_OWNER_SET_SHARE']
    when '1' then true
    when '0' then false
    else real
    end
  end

  def key(salt, mid, level, set)
    Digest::SHA256.hexdigest("#{salt}\0#{mid}\0#{level}\0#{set}")[0, 16]
  end

  # +code+ with each set that two or more sites have in common shared. +salt+ is the gem's symbol.
  def rewrite(code, salt)
    count = Hash.new(0)
    code.scan(SITE) { |_, mid, level, list| count[[mid, level, list]] += 1 }
    keys = {}
    owner = {}
    count.each do |site, n|
      next if n < 2

      k = key(salt, *site)
      # A collision of two different sites would merge their states; neither shares then.
      if owner.key?(k)
        keys.delete(owner[k])
        next
      end
      owner[k] = site
      keys[site] = k
    end
    return code if keys.empty?

    code = code.gsub(SITE) do
      head, mid, level, list = Regexp.last_match.captures
      k = keys[[mid, level, list]]
      k ? "#{head}BC2CPP_SHARED(0x#{k}, #{mid}, #{level}, #{list})" : Regexp.last_match(0)
    end
    at = code.index(DEFS_AT) or raise "OWNER_SET_SHARE: no #{DEFS_AT.chomp} before the shared sites"
    code.insert(at + DEFS_AT.size, keys.map { |(mid, level, list), k| definitions(k, mid, level, list) }.join)
  end

  def definitions(key, mid, level, list)
    k = "0x#{key}"
    "inline const char* const bc2cpp_owner_sn_#{k}[] = { #{list}, nullptr };\n" \
      "inline bc2cpp_owner_set* bc2cpp_owner_ss_#{k}{};\n" \
      "inline const bc2cpp_owner_desc bc2cpp_owner_sd_#{k} = { bc2cpp_owner_sn_#{k}, nullptr, &bc2cpp_owner_ss_#{k}, #{mid}, #{level} };\n"
  end

  def capture_stdout(salt)
    original = $stdout
    buffer = StringIO.new
    $stdout = buffer
    at_exit do
      $stdout = original
      original.write(rewrite(buffer.string, salt)) unless $!
    end
  end
end
