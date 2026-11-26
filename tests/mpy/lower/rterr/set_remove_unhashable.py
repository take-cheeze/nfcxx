# remove hashes its item: a list is unhashable, a TypeError.
s = {1}
result = s.remove([1])
