// Order of strings: by their bytes, a proper prefix first.
local r = 0;
if ("abc" < "abd") r += 1;
if ("b" > "abc") r += 2;
if ("ab" < "abc") r += 4;
if ("abc" <= "abc") r += 8;
if ("abd" >= "abe") r += 16;
return r;
