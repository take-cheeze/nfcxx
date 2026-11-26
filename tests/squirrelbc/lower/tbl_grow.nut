// Many keys: the table grows and every key is found again.
local t = {};
local i = 0;
while (i < 200) {
  t[i] <- i * 2;
  i = i + 1;
}
local sum = 0;
i = 0;
while (i < 200) {
  sum = sum + t[i];
  i = i + 1;
}
return sum;
