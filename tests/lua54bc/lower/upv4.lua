local function shared()
  local n = 1
  local function inc() n = n + 1 end
  local function get() return n end
  inc()
  inc()
  return get()
end
return shared()
