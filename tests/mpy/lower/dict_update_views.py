src = {'a': 1, 'b': 2}
dst = {'z': 0}
dst.update(src.items())
dst.update(src)
dst.update([(k, v * 10) for k, v in src.items()])
seen = {}
seen.update(dst.items())
result = (dst, seen, len(seen), dst.get([1], 'miss'), {}.get((1,), 'nope'), dst.pop('a', 'gone'), dst.pop('a', 'gone'))
