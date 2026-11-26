# setdefault hashes its key even when the dict has no table yet, so an unhashable key is a TypeError.
d = {}
result = d.setdefault([1], 2)
