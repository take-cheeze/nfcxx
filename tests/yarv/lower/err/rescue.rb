x = 0
begin
  x = 1 / x
rescue ZeroDivisionError
  x = 2
end
x
