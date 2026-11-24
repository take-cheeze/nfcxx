assert('Thread#value') do
  t = Thread.new { 1 + 2 }
  assert_equal 3, t.value
end

assert('Thread with arguments') do
  t = Thread.new(4, 5) { |a, b| a * b }
  assert_equal 20, t.value
end

assert('Thread shares variables with its creator') do
  x = 0
  t = Thread.new { x = 5 }
  t.join
  assert_equal 5, x
end

assert('two threads, each with its own value') do
  a = Thread.new { 10 }
  b = Thread.new { 20 }
  assert_equal 30, a.value + b.value
end

assert('Thread.current is the thread running the block') do
  t = Thread.new { Thread.current }
  assert_equal t, t.value
end

assert('an exception in a thread is raised by join') do
  t = Thread.new { raise "boom" }
  assert_raise(RuntimeError) { t.join }
end
