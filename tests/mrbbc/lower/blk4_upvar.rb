def each_it
  yield
end
def m(a)
  each_it do
    b = 5
    each_it do
      c = 6
      each_it do
        d = 7
        each_it do
          a + b + c + d
        end
      end
    end
  end
end
x = m(1)
[x, m(10)]
