--!strict
-- GhostCodec: a run's path as a small string that fits in the saved profile (pure, unit tested).
-- The server samples the car 5 times a second during a run. Each sample: position relative to the map's
-- origin as 3 x i16 at 1/8 stud (+-4096 studs) and the rotation as a quaternion in 4 x i16 = 14 bytes.
-- A 90 s run is about 6.3 KB raw; base64 makes it DataStore-safe text.

local GhostCodec = {}

GhostCodec.SAMPLE_SIZE = 14
GhostCodec.HEADER_SIZE = 2 -- u16 sample rate x 10
local POSITION_SCALE = 8

export type Sample = { x: number, y: number, z: number, qx: number, qy: number, qz: number, qw: number }

local function i16(value: number): number
	return math.clamp(math.floor(value + 0.5), -32768, 32767)
end

function GhostCodec.encode(samples: { Sample }, rate: number): buffer
	local b = buffer.create(GhostCodec.HEADER_SIZE + #samples * GhostCodec.SAMPLE_SIZE)
	buffer.writeu16(b, 0, math.clamp(math.floor(rate * 10 + 0.5), 1, 65535))
	for index, s in samples do
		local o = GhostCodec.HEADER_SIZE + (index - 1) * GhostCodec.SAMPLE_SIZE
		buffer.writei16(b, o, i16(s.x * POSITION_SCALE))
		buffer.writei16(b, o + 2, i16(s.y * POSITION_SCALE))
		buffer.writei16(b, o + 4, i16(s.z * POSITION_SCALE))
		buffer.writei16(b, o + 6, i16(s.qx * 32767))
		buffer.writei16(b, o + 8, i16(s.qy * 32767))
		buffer.writei16(b, o + 10, i16(s.qz * 32767))
		buffer.writei16(b, o + 12, i16(s.qw * 32767))
	end
	return b
end

function GhostCodec.decode(b: buffer): ({ Sample }?, number)
	local length = buffer.len(b)
	if length < GhostCodec.HEADER_SIZE or (length - GhostCodec.HEADER_SIZE) % GhostCodec.SAMPLE_SIZE ~= 0 then
		return nil, 0
	end
	local rate = buffer.readu16(b, 0) / 10
	local samples = {}
	for o = GhostCodec.HEADER_SIZE, length - 1, GhostCodec.SAMPLE_SIZE do
		local qx = buffer.readi16(b, o + 6) / 32767
		local qy = buffer.readi16(b, o + 8) / 32767
		local qz = buffer.readi16(b, o + 10) / 32767
		local qw = buffer.readi16(b, o + 12) / 32767
		local n = math.sqrt(qx * qx + qy * qy + qz * qz + qw * qw)
		if n > 1e-6 then
			qx, qy, qz, qw = qx / n, qy / n, qz / n, qw / n
		else
			qx, qy, qz, qw = 0, 0, 0, 1
		end
		table.insert(samples, {
			x = buffer.readi16(b, o) / POSITION_SCALE,
			y = buffer.readi16(b, o + 2) / POSITION_SCALE,
			z = buffer.readi16(b, o + 4) / POSITION_SCALE,
			qx = qx,
			qy = qy,
			qz = qz,
			qw = qw,
		})
	end
	return samples, rate
end

---------------------------------------------------------------------------
-- Base64 (standard alphabet, padded)
---------------------------------------------------------------------------

local ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local ENCODE: { string } = {}
local DECODE: { [number]: number } = {}
for i = 1, 64 do
	local c = string.sub(ALPHABET, i, i)
	ENCODE[i - 1] = c
	DECODE[string.byte(c)] = i - 1
end

function GhostCodec.toBase64(b: buffer): string
	local out = table.create(math.ceil(buffer.len(b) / 3) * 4)
	local length = buffer.len(b)
	for i = 0, length - 1, 3 do
		local a = buffer.readu8(b, i)
		local c2 = if i + 1 < length then buffer.readu8(b, i + 1) else 0
		local c3 = if i + 2 < length then buffer.readu8(b, i + 2) else 0
		local n = a * 65536 + c2 * 256 + c3
		table.insert(out, ENCODE[bit32.extract(n, 18, 6)])
		table.insert(out, ENCODE[bit32.extract(n, 12, 6)])
		table.insert(out, if i + 1 < length then ENCODE[bit32.extract(n, 6, 6)] else "=")
		table.insert(out, if i + 2 < length then ENCODE[bit32.extract(n, 0, 6)] else "=")
	end
	return table.concat(out)
end

function GhostCodec.fromBase64(text: string): buffer?
	if #text % 4 ~= 0 then
		return nil
	end
	local padding = 0
	if string.sub(text, -2) == "==" then
		padding = 2
	elseif string.sub(text, -1) == "=" then
		padding = 1
	end
	local b = buffer.create(#text // 4 * 3 - padding)
	local o = 0
	for i = 1, #text, 4 do
		local n = 0
		for j = 0, 3 do
			local byte = string.byte(text, i + j)
			local v = DECODE[byte]
			if v == nil then
				if byte ~= 61 then -- "="
					return nil
				end
				v = 0
			end
			n = n * 64 + v
		end
		for shift = 16, 0, -8 do
			if o < buffer.len(b) then
				buffer.writeu8(b, o, bit32.extract(n, shift, 8))
				o += 1
			end
		end
	end
	return b
end

return GhostCodec
