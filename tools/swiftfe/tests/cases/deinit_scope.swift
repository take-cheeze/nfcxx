class Noisy {
  let id: Int
  deinit {
    print(self.id)
  }
}
func scope() {
  let a = Noisy(id: 1)
  print(10)
}
scope()
print(20)
