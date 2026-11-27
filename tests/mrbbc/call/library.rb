def sum(a, b)
  a - b
end

def sum(a, b)
  a + b
end

def divide(a, b)
  a / b
end

def answer
  42
end

def wrong_result
  "not an integer"
end

class BadCallText
  def to_s
    1 / 0
  end
  def inspect
    1 / 0
  end
end

def failed_join
  ["already buffered", BadCallText.new].join
end

def failed_inspect
  ["already buffered", BadCallText.new].inspect.size
end

def after_error
  ["safe", [1, 2]].inspect.size
end
