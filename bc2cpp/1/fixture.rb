class Foo
  def initialize
    @v = 1
    nil
  end

  def size2
    @v + 1
  end
end

class Menu
  def pick(a, b = nil)
    return a.size2 if b.nil?

    b.size2
  end

  def add(a, b = 2)
    a.size2 + b
  end

  def computed(a, b = a)
    return 0 if b.nil?

    b.size2
  end

  def later(a, b = c, c = nil)
    return 1 if c.nil?

    c.size2
  end

  def loose(a, b = nil)
    return 0 if b.nil?

    b.size2
  end

  def sorted(a, xs = [])
    (xs || []).sort.size + a.size2
  end

  def keys_of(h)
    h.keys.size
  end

  def shout(s)
    s.upcase
  end

  def run
    f = Foo.new
    pick(f) + pick(f, f) + add(f) + add(f, 5) + computed(f) + later(f) + later(f, 1, f) + loose(f, f) +
      sorted(f) + sorted(f, [3, 1]) + sorted(f, nil) + keys_of({ a: 1 }) + shout('a').size
  end

  def wrong_sorted
    sorted(Foo.new, 'z')
  end

  def wrong
    pick(Foo.new, 'x')
  end

  def wrong_add
    add(Foo.new, 'y')
  end
end
