xs = [1, 2]
out = ""
try:
    xs[5]
except IndexError as e:
    out = out + str(e) + "|"
try:
    result_int = 1 // 0
except ZeroDivisionError as e:
    out = out + str(e) + "|"
try:
    d = {}
    d['k']
except KeyError as e:
    out = out + str(e)
result = out
