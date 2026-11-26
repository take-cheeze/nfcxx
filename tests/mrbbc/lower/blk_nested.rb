def f
  yield 2
end
f { |a| f { |b| b + a } }
