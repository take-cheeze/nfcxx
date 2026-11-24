local n = 0
for i = 1, 20000 do
  local ok, e = pcall(error, "x" .. i)
  if not ok and e == "x" .. i then n = n + 1 end
end
return n
