def once(v)
  yield v
end
def run(base)
  total = 0
  once(3) { |x, k = base| total = total + x + k }
  total
end
run(10)
