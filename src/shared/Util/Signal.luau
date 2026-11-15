--!strict
-- Signal: a tiny synchronous event (connect, fire, disconnect).

export type Connection = { Disconnect: (self: Connection) -> (), Connected: boolean }

local Signal = {}
Signal.__index = Signal

export type Signal = typeof(setmetatable(
	{} :: { _handlers: { [number]: (...any) -> () }, _nextId: number },
	Signal
))

function Signal.new(): Signal
	return setmetatable({ _handlers = {}, _nextId = 0 }, Signal)
end

function Signal.Connect(self: Signal, handler: (...any) -> ()): Connection
	self._nextId += 1
	local id = self._nextId
	self._handlers[id] = handler
	local connection = { Connected = true } :: any
	function connection.Disconnect(conn: Connection)
		conn.Connected = false
		self._handlers[id] = nil
	end
	return connection
end

function Signal.Fire(self: Signal, ...: any)
	-- Copy so handlers can disconnect while firing
	local list = {}
	for id, handler in self._handlers do
		list[#list + 1] = { id, handler }
	end
	table.sort(list, function(a, b)
		return a[1] < b[1]
	end)
	for _, entry in list do
		entry[2](...)
	end
end

function Signal.DisconnectAll(self: Signal)
	table.clear(self._handlers)
end

return Signal
