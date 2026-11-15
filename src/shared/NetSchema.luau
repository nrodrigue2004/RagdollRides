--!strict
-- NetSchema: argument checks and rate limiting for remotes (pure, unit tested).
-- A schema is a list of argument specs, for example:
--   { { t = "string", max = 32 }, { t = "number", min = 0, max = 1 }, { t = "buffer", len = { 7, 127 } } }

local NetSchema = {}

export type ArgSpec = {
	t: string, -- "string" | "number" | "integer" | "boolean" | "buffer" | "Vector3" | "CFrame" | "any"
	optional: boolean?,
	min: number?,
	max: number?, -- numbers: max value; strings: max length
	len: { number }?, -- buffers: allowed exact lengths
	maxLen: number?, -- buffers: max length
	oneOf: { string }?, -- strings: allowed values
}

local function isFiniteNumber(value: any): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function checkVector(value: any): boolean
	if typeof(value) ~= "Vector3" then
		return false
	end
	return isFiniteNumber(value.X) and isFiniteNumber(value.Y) and isFiniteNumber(value.Z)
end

local function checkArg(spec: ArgSpec, value: any): (boolean, string?)
	if value == nil then
		if spec.optional then
			return true
		end
		return false, "missing"
	end
	local t = spec.t
	if t == "any" then
		return true
	elseif t == "string" then
		if type(value) ~= "string" then
			return false, "not a string"
		end
		if spec.max and #value > spec.max then
			return false, "string too long"
		end
		if spec.oneOf and not table.find(spec.oneOf, value) then
			return false, "string not allowed"
		end
		return true
	elseif t == "number" or t == "integer" then
		if not isFiniteNumber(value) then
			return false, "not a finite number"
		end
		if t == "integer" and value % 1 ~= 0 then
			return false, "not an integer"
		end
		if spec.min and value < spec.min then
			return false, "below min"
		end
		if spec.max and value > spec.max then
			return false, "above max"
		end
		return true
	elseif t == "boolean" then
		if type(value) ~= "boolean" then
			return false, "not a boolean"
		end
		return true
	elseif t == "buffer" then
		if type(value) ~= "buffer" then
			return false, "not a buffer"
		end
		local length = buffer.len(value)
		if spec.len and not table.find(spec.len, length) then
			return false, "bad buffer length"
		end
		if spec.maxLen and length > spec.maxLen then
			return false, "buffer too long"
		end
		return true
	elseif t == "Vector3" then
		if not checkVector(value) then
			return false, "bad Vector3"
		end
		return true
	elseif t == "CFrame" then
		if typeof(value) ~= "CFrame" then
			return false, "not a CFrame"
		end
		local ok = true
		for _, n in { value:GetComponents() } do
			if not isFiniteNumber(n) then
				ok = false
			end
		end
		if not ok then
			return false, "bad CFrame"
		end
		return true
	end
	return false, "unknown schema type " .. t
end

-- Returns true when the argument list matches the schema exactly (extra arguments fail).
function NetSchema.validate(schema: { ArgSpec }, args: { any }, argCount: number): (boolean, string?)
	if argCount > #schema then
		return false, "too many arguments"
	end
	for index, spec in schema do
		local ok, reason = checkArg(spec, args[index])
		if not ok then
			return false, string.format("arg %d: %s", index, reason or "invalid")
		end
	end
	return true
end

-- Token bucket: `rate` tokens per second, holding at most `burst` tokens.
export type Bucket = { tokens: number, last: number }

function NetSchema.newBucket(burst: number, now: number): Bucket
	return { tokens = burst, last = now }
end

function NetSchema.take(bucket: Bucket, rate: number, burst: number, now: number): boolean
	local elapsed = math.max(0, now - bucket.last)
	bucket.last = now
	bucket.tokens = math.min(burst, bucket.tokens + elapsed * rate)
	if bucket.tokens >= 1 then
		bucket.tokens -= 1
		return true
	end
	return false
end

-- Sliding failure counter for the kick rule (20 failures in 60 s).
export type FailureLog = { times: { number } }

function NetSchema.recordFailure(log: FailureLog, now: number, window: number): number
	table.insert(log.times, now)
	local cutoff = now - window
	while #log.times > 0 and log.times[1] < cutoff do
		table.remove(log.times, 1)
	end
	return #log.times
end

return NetSchema
