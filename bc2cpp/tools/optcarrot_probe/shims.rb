class File
  def self.binread(path)
    IO.read(path, mode: "rb")
  end
end

class Integer
  def [](i)
    (self >> i) & 1
  end
end

# Real identity semantics (keyed by object_id), not a value-equality Hash --
# only implements the []/[]= subset optcarrot's ppu.rb actually calls.
class IdentityHashShim
  def initialize
    @h = {}
  end

  def [](k)
    @h[k.object_id]
  end

  def []=(k, v)
    @h[k.object_id] = v
  end
end

class Hash
  def compare_by_identity
    IdentityHashShim.new
  end
end

# mruby has no Process module/clock_gettime at all -- Time.now is not truly
# monotonic (wall-clock can jump), but is good enough to unblock this probe's
# FPS-measurement-only usage of it.
module Process
  CLOCK_MONOTONIC = :monotonic

  def self.clock_gettime(_clock_id)
    Time.now.to_f
  end
end

class String
  def sum(n = 16)
    total = 0
    each_byte { |b| total += b }
    n <= 0 ? total : total & ((1 << n) - 1)
  end
end
