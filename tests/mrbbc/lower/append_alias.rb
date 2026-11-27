class TextLike
  def to_str
    "str" + "ing"
  end
end
a = []
b = a
s = "ab"
t = s
s << s
s << 0
s << 127
s << "\xff"
a << s
a << TextLike.new.to_str
converted = "converted:" << TextLike.new.to_str
k = "key"
h = {k => 1}
k << "!"
[a, b, s, t, converted, h, k]
