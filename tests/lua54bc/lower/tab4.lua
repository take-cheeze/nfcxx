local obj = {n = 4}
function obj.get(self) return self.n end
return obj:get()
