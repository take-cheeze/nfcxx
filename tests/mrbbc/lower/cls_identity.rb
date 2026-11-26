class Z
end
a = Z.new
b = a
c = Z.new
[a == b, a == c, !a]
