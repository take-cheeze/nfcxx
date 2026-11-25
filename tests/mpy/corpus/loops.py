total = 0
for i in range(10):
    if i % 2 == 0:
        continue
    total += i
n = 0
while n < 5:
    n += 1
    if n == 3:
        break
print(total, n)
