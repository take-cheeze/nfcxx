# Digest::SHA256 (FIPS 180-4) in Ruby: new, update, hexdigest, and the class methods hexdigest and file.
module Digest
  class SHA256
    K = [
      0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
      0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
      0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
      0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
      0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
      0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
      0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
      0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
    ].freeze

    INITIAL = [
      0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
    ].freeze

    MASK = 0xffffffff

    def self.hexdigest(data)
      new.update(data).hexdigest
    end

    def self.file(path)
      digest = new
      File.open(path, "rb") { |io| digest.update(io.read) }
      digest
    end

    def initialize
      @buffer = "".b
    end

    def update(data)
      @buffer << data.to_s.b
      self
    end
    alias << update

    # The 32-byte binary digest, as CRuby's Digest::Base#digest returns it.
    def digest
      [hexdigest].pack("H*")
    end

    def hexdigest
      words = INITIAL.dup
      buf = @buffer
      n = buf.bytesize
      bit_length = n * 8
      full = n - (n % 64)
      offset = 0
      while offset < full
        compress(words, buf, offset)
        offset += 64
      end
      # Padding for the final partial block (a single 0x80, zeros, then the 64-bit length), in one short string:
      # the message is never copied into an array of bytes.
      tail = buf.byteslice(full, n - full) + 0x80.chr
      tail << 0.chr * ((56 - tail.bytesize) % 64)
      8.times { |i| tail << ((bit_length >> (56 - 8 * i)) & 0xff).chr }
      offset = 0
      while offset < tail.bytesize
        compress(words, tail, offset)
        offset += 64
      end
      words.map { |word| format("%08x", word) }.join
    end

    private

    def rotr(value, count)
      ((value >> count) | (value << (32 - count))) & MASK
    end

    def compress(words, message, offset)
      w = Array.new(64, 0)
      16.times do |t|
        base = offset + 4 * t
        w[t] = (message.getbyte(base) << 24) | (message.getbyte(base + 1) << 16) | (message.getbyte(base + 2) << 8) | message.getbyte(base + 3)
      end
      (16...64).each do |t|
        s0 = rotr(w[t - 15], 7) ^ rotr(w[t - 15], 18) ^ (w[t - 15] >> 3)
        s1 = rotr(w[t - 2], 17) ^ rotr(w[t - 2], 19) ^ (w[t - 2] >> 10)
        w[t] = (w[t - 16] + s0 + w[t - 7] + s1) & MASK
      end

      a, b, c, d, e, f, g, h = words
      64.times do |t|
        big_s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
        choose = (e & f) ^ ((~e & MASK) & g)
        temp1 = (h + big_s1 + choose + K[t] + w[t]) & MASK
        big_s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
        majority = (a & b) ^ (a & c) ^ (b & c)
        temp2 = (big_s0 + majority) & MASK
        h = g
        g = f
        f = e
        e = (d + temp1) & MASK
        d = c
        c = b
        b = a
        a = (temp1 + temp2) & MASK
      end

      [a, b, c, d, e, f, g, h].each_with_index { |value, i| words[i] = (words[i] + value) & MASK }
    end
  end
end

MRubyRequire.provide('digest') { defined?(Digest::SHA256) } if defined?(MRubyRequire)
MRubyRequire.provide('digest/sha2') { defined?(Digest::SHA256) } if defined?(MRubyRequire)
