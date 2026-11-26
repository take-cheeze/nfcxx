def g
  block_given?
end
[g, g { 1 }]
