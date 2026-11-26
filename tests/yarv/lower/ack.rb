def ack_small(m, n)
  m < 1 ? n + 1 : (n < 1 ? ack_small(m - 1, 1) : ack_small(m - 1, ack_small(m, n - 1)))
end
ack_small(2, 3)
