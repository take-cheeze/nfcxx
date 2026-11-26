begin
  raise ArgumentError, "bad"
rescue ArgumentError => e
  e.message
ensure
  $done = true
end
x = [1,2,3].each { |v| break v * 10 if v == 2 }
x
