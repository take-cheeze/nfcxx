def make_adder(n):
    def add(x):
        return x + n
    return add

add5 = make_adder(5)
add7 = make_adder(7)
result = add5(1) * 10 + add7(2)
