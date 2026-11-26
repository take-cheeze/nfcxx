def each_it
  yield
end
def m
  each_it do
    each_it do
      each_it do
        return 5
      end
    end
  end
  6
end
m
