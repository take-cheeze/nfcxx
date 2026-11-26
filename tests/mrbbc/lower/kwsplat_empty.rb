def one(x)
  x
end
def two(a, b)
  [a, b]
end
def m(a, b = 1)
  [a, b]
end
def n(a, k: 1)
  [a, k]
end
def r(*a)
  a
end
def q(a, &nil)
  a
end
class Foo
  def v
    5
  end
end
h = {}
[one(**{}), two(1, **{}), m(1, **{}), n(1, **{}), r(**{}), q(1, **{}), r(1, **h), Foo.new(**{}).v]
