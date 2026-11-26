# The set comparisons: < and > are proper subset and superset, <= and >= the subset and superset, == compares the items, and
# != is its negation. A set against a value that is not a set is False for == and True for !=, and an ordering is a TypeError.
a = {1, 2}
b = {1, 2, 3}
c = {2, 1}
d = {4}
first = (a < b, a <= b, b > a, b >= a, a < c, a <= c, a > c, a >= c, a == c, a != c, a == b, a != b, a < d, b > b)
second = (a == 1, a != 1, a == [1, 2], [1, 2] != a, 1 == a, a == a, d == {4}, ({1, 2},) in [({2, 1},)], a in [b, c])
third = (a >= {1, 2, 3, 4}, {4} <= {1, 2}, b <= b, b < b, {7, 8} != {8, 7}, {1, 2, 3} == {3, 2, 1})
result = (first, second, third)
