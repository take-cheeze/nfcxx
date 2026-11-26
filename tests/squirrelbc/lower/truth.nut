local n = null
local z = 0
local r = 0
if (n) { r = r + 1 }
if (z) { r = r + 2 }
if (true) { r = r + 4 }
if (!n) { r = r + 8 }
if (!z) { r = r + 16 }
if (!false) { r = r + 32 }
return r
