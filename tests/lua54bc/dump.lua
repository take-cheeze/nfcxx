-- dump.lua SOURCE OUT full|strip: writes the binary chunk string.dump makes of SOURCE (what luac -o / -s writes).
local f = assert(loadfile(arg[1]))
local o = assert(io.open(arg[2], "wb"))
o:write(string.dump(f, arg[3] == "strip"))
o:close()
