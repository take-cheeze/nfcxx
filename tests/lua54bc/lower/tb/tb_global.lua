-- global functions are named by their global name: "in function 'name'"
function helper(x)
  return x.missing.field
end

function driver(x)
  local v = helper(x)
  return v
end

driver({})
