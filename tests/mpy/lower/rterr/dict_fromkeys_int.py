# fromkeys takes an iterable: an int is a TypeError from getting its iterator.
d = {}
result = d.fromkeys(5)
