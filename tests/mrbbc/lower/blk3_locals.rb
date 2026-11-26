def each_it
  yield
end
def m(a)
  out = []
  each_it do
    b = 2
    each_it do
      c = 3
      each_it do
        out = out + [a + b + c]
        b = b + 10
        c = c + 20
      end
      out = out + [b, c]
    end
  end
  out
end
m(1)
