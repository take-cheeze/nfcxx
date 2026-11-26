def helper(n)
  n * 3
end

class Calc
  def base
    4
  end

  def run
    helper(base) + base
  end
end
Calc.new.run
