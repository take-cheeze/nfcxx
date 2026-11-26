k = 5
def m
  yield 2
end
m { |v| v + k }
