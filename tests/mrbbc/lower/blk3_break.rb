def each_it
  yield
end
out = []
each_it do
  each_it do
    x = each_it do
      break 9
    end
    out = out + [x]
  end
end
out
