def s(*a)
  a
end
x = [1, 2]
[s(*x), s(0, *x), s(*[]), s(x, *x)]
