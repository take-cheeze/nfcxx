def each_it
  yield
end
def m(a)
  each_it do
    each_it do
      each_it do
        each_it do
          each_it do
            each_it do
              each_it do
                each_it do
                  each_it do
                    a
                  end
                end
              end
            end
          end
        end
      end
    end
  end
end
m(3)
