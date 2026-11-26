// The attributes of a member made before and after an instance (the class is locked); a value of any kind is an attribute.
class K { </ role = "admin" /> name = 1; </ n = 3 /> function m() { return 4; } }
local k = K();
print(K.getattributes("name").role); print(" ");
print(K.getattributes("m").n); print(" ");
print(k.m()); print(" ");
print(K.setattributes("m", null).n); print(" ");
print(K.getattributes("m") == null); print(" ");
return k.name;
