assert('Queue: producers and a consumer') do
  q = Queue.new
  producers = (1..3).map { |i| Thread.new { 50.times { |k| q << i * 1000 + k } } }
  consumer = Thread.new { sum = 0; 150.times { sum += q.pop }; sum }
  producers.each(&:join)
  assert_equal 303675, consumer.value  # 50*1000*(1+2+3) + 3*(0+1+...+49)
  assert_true q.empty?
end

assert('Queue: pop waits for a push, close wakes pop') do
  q = Queue.new
  t = Thread.new { q.pop }
  q.push(:hello)
  assert_equal :hello, t.value
  q.close
  assert_true q.closed?
  assert_nil q.pop
  assert_raise(StopIteration) { q.push(1) }
end

assert('Queue: non-blocking pop of an empty queue raises ThreadError') do
  assert_raise(ThreadError) { Queue.new.pop(true) }
end

assert('ConditionVariable: wait until signalled') do
  m = Mutex.new
  cv = ConditionVariable.new
  ready = false
  w = Thread.new { m.synchronize { cv.wait(m) until ready; :woke } }
  m.synchronize { ready = true; cv.signal }
  assert_equal :woke, w.value
end

assert('ConditionVariable: wait with a timeout returns') do
  m = Mutex.new
  cv = ConditionVariable.new
  m.synchronize { cv.wait(m, 0.01) }
  assert_true true
end

assert('Thread#alive? and #status') do
  t = Thread.new { 1 }
  t.join
  assert_false t.alive?
  assert_false t.status
  r = Thread.new { raise "x" }
  assert_raise(RuntimeError) { r.join }
  assert_nil r.status
end

assert('a thread that dies holding a mutex releases it') do
  m = Mutex.new
  Thread.new { m.lock }.join
  assert_false m.locked?
end

assert('sleep lets another thread run') do
  flag = false
  w = Thread.new { sleep 0.05; flag = true }
  w.join
  assert_true flag
  assert_equal 0, sleep(0)
end
