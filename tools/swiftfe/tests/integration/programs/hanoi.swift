// Towers of Hanoi: count moves and check that each disc moves at most once per
// the classic recursion, using a checksum of the moves.
var moves = 0
var checksum = 0

func hanoi(_ n: Int, _ from: Int, _ to: Int, _ via: Int) {
  if n == 0 {
    return
  }
  hanoi(n - 1, from, via, to)
  moves = moves + 1
  checksum = (checksum * 31 + from * 10 + to) % 1000003
  hanoi(n - 1, via, to, from)
}

hanoi(10, 1, 3, 2)
print(moves)
print(checksum)
print(moves == 1023)
