-- The stack functions in a source chunk: there is no bytecode frame, so each one raises an error (run as source only).
print(pcall(stack_get, 0))
print(pcall(function() return stack_top() end))
