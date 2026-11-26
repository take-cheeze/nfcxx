// instance() makes an instance with no constructor and locks the class: a rawset of a field is then refused, silently.
class K { x = 1; function m() { return 4; } }
local k = K.instance();
print(K.rawin("q")); print(" ");
print(K.rawset("x", 8).rawget("x")); print(" ");
print(k.x); print(" ");
print(K.rawget("m")()); print(" ");
print(k.rawget("m")()); print(" ");
return K.rawin("m");
