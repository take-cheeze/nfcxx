def m
  3.times { |i| yield i }
end
m { |v| v }
