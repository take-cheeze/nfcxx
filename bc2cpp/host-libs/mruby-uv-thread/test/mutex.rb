assert('Mutex serializes threads') do
  m = Mutex.new
  count = 0
  ts = (1..10).map { Thread.new { 200.times { m.synchronize { count += 1 } } } }
  ts.each(&:join)
  assert_equal 2000, count
end

assert('Mutex lock state') do
  m = Mutex.new
  assert_false m.locked?
  m.lock
  assert_true m.locked?
  assert_true m.owned?
  m.unlock
  assert_false m.locked?
end

assert('Mutex recursive lock and bad unlock raise ThreadError') do
  m = Mutex.new
  m.lock
  assert_raise(ThreadError) { m.lock }
  m.unlock
  assert_raise(ThreadError) { m.unlock }
end

assert('Mutex#synchronize unlocks on exception') do
  m = Mutex.new
  assert_raise(RuntimeError) { m.synchronize { raise "in sync" } }
  assert_false m.locked?
end
