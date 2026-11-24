class ClosedQueueError < StopIteration
end

class Queue
  def initialize(items = nil)
    @items = items ? items.to_a : []
    @closed = false
    @mutex = Mutex.new
    @cond = ConditionVariable.new
  end

  def push(value)
    @mutex.synchronize do
      raise ClosedQueueError, "queue closed" if @closed
      @items.push(value)
      @cond.signal
    end
    self
  end
  alias << push
  alias enq push

  def pop(non_block = false)
    @mutex.synchronize do
      raise ThreadError, "queue empty" if non_block && @items.empty?
      while @items.empty? && !@closed
        @cond.wait(@mutex)
      end
      @items.empty? ? nil : @items.shift
    end
  end
  alias shift pop
  alias deq pop

  def size
    @mutex.synchronize { @items.size }
  end
  alias length size

  def empty?
    @mutex.synchronize { @items.empty? }
  end

  def clear
    @mutex.synchronize { @items.clear }
    self
  end

  def close
    @mutex.synchronize do
      @closed = true
      @cond.broadcast
    end
    self
  end

  def closed?
    @closed
  end
end
