# frozen_string_literal: true

class Array
  # Replaces Enumerable#drop (mruby-enum-ext), which runs `each { |*val| ... }`: a block call, a one-element Array for
  # `*val` and an __svalue per element. Same result, same ArgumentError for a negative count, same to_int conversion.
  # `self[n, size]` is nil only when n is past the end, and the drop is empty then.
  def drop(n)
    n = n.__to_int
    raise ArgumentError, 'attempt to drop negative size' if n < 0

    self[n, size] || []
  end
end
