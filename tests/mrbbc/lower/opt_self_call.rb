def inc(x, by = 1)
  x + by
end
def run(n)
  inc(inc(n), 10)
end
[inc(1), run(1), inc(1, 2)]
