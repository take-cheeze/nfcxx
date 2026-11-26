class M
  def <(o)
    :lt
  end

  def <=(o)
    9
  end

  def >(o)
    o == 0
  end
end
[M.new < 1, M.new <= 1, M.new > 0]
