-- An opcode outside the nfcast subset: a to-be-closed variable (TBC). The binary chunk is refused at load time
-- (run.sh checks the message); as source the same program is not part of the test.
local x <close> = nil
return 1
