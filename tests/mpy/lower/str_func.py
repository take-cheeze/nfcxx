def join(a, b):
    return a + b

def same(a, b):
    return a == b

word = join('ne', 'st')
result = 0
if same(word, 'nest'):
    result = 5
if same(word, 'nes'):
    result = result + 100
result = join(word, '!') if result == 5 else 'no'
