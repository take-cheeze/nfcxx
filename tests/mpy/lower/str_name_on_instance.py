# A class's method named like a str method is the class's method: the receiver decides, at run time.
class K:
    def count(self):
        return 7

    def upper(self, x=1):
        return x

k = K()
result = (k.count(), k.upper(), k.upper(5), 'ab'.count('a'))
