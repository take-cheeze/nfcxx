-- A known small program for the node-evaluation count (State::stats.node_evals; tests/ast/run.sh checks the number, 28).
-- The count is of dispatches: each call of a node's eval, evalMulti or exec. How the operands of s + i are reached depends on the
-- phase of the arithmetic node (docs/notes/ast.md, "Feedback"):
--   the chunk's body (a block, run once)                                                        1
--   local s = 0: the declaration, and the constant 0                                            2
--   for i = 1, 5: the loop, and its start and limit constants (the step is absent)              3
--   iterations 1 and 2 (the node is still recording its operands, ArithUninit and ArithProfile):
--     the body (a block), s = s + i (the assignment), s + i, and both operands, which the
--     generic evaluation dispatches (LocalNode s, LocalNode i)                            5 + 5
--   iterations 3 to 5 (the node is specialized, ArithII, which reads its local operands in place):
--     the body, the assignment, the addition                                              3 x 3
--   print(s): the call, the global print, and the local s as an argument                        3
-- total 1 + 2 + 3 + 10 + 9 + 3 = 28
local s = 0
for i = 1, 5 do
  s = s + i
end
print(s)
