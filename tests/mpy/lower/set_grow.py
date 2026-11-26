big = {x * 7 % 20 for x in range(12)}
grown = {}
for i in range(9):
    grown[i * 5 % 13] = i
result = (big, len(big), 14 in big, 15 in big, grown, len(grown), grown.get(0), grown.get(1, 'none'))
