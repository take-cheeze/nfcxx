class JoinText
  def to_s
    "string"
  end
  def to_str
    "unused"
  end
  def to_ary
    ["unused"]
  end
end
[JoinText.new].join
