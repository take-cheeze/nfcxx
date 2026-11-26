def g
  block_given? ? 1 : 0
end
g * 10 + (g { 2 }) * 100
