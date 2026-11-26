-- methods and fields of a table that is not a library: "in method 'name'", "in field 'name'"
local Account = {}
Account.__index = Account

function Account.new(balance)
  return setmetatable({balance = balance}, Account)
end

function Account:withdraw(n)
  if n > self.balance then
    error("insufficient funds")
  end
  self.balance = self.balance - n
end

local bank = {}
function bank.run(acc)
  acc:withdraw(500)
end

bank.run(Account.new(100))
