-- Pool: recycles instances (debris, sparks, pops) so effects never allocate mid-crash.

local Pool = {}
Pool.__index = Pool

-- create() makes a fresh instance; reset(instance) readies a returned one (optional).
function Pool.new(create: () -> Instance, reset: ((Instance) -> ())?, max: number?)
	return setmetatable({ _free = {}, _create = create, _reset = reset, _max = max or 64, _out = 0 }, Pool)
end

function Pool:Get(): Instance?
	local item = table.remove(self._free)
	if item == nil then
		if self._out >= self._max then
			return nil
		end
		item = self._create()
	end
	self._out += 1
	return item
end

function Pool:Return(item: Instance)
	self._out = math.max(0, self._out - 1)
	if self._reset then
		self._reset(item)
	end
	table.insert(self._free, item)
end

function Pool:Destroy()
	for _, item in self._free do
		item:Destroy()
	end
	self._free = {}
end

return Pool
