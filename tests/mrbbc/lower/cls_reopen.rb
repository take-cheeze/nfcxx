class Foo
  def a
    1
  end
end

class Foo
  def b
    a + 1
  end
end
Foo.new.b
