--!strict
-- MapCodec: a builder map as bytes (spec: Map record > Piece encoding, 11 bytes a piece; pure, tested).
-- Header (8 bytes): version u8, flags u8 (bit 0 full damage, bits 1-2 theme), tags u8 (one bit per tag
-- in MapNames.TAGS), name word ids u8 x 3 (adjective, noun, place; 0 = not picked yet), piece count u16.
-- Piece (11 bytes): type u8, x i16, y i16, z i16 (grid units: x and z in 2 studs, y in studs),
-- rotation u8 (yaw step 0..23 + 24 x tilt 0..6), size u8, colour u8, param u8 (moving-piece phase).
-- 250 pieces = 2,758 bytes; base64 (for the DataStore) is about 3.7 KB.

-- Roblox finds siblings beside this module; the Lune test runner (no `script`) uses the file path.
local PieceCatalog = if script
	then require(script.Parent.PieceCatalog)
	else (require :: any)("./PieceCatalog")

local MapCodec = {}

MapCodec.VERSION = 1
MapCodec.HEADER = 8
MapCodec.PIECE = 11
MapCodec.MAX_PIECES = 250

export type MapData = {
	flags: number,
	tags: number,
	name: { number }, -- adjective, noun, place word ids (MapNames); 0 = not picked yet
	pieces: { PieceCatalog.Entry },
}

function MapCodec.empty(): MapData
	return { flags = 0, tags = 0, name = { 0, 0, 0 }, pieces = {} }
end

local function i16(value: number): number
	return math.clamp(math.floor(value + 0.5), -32768, 32767)
end

function MapCodec.encode(map: MapData): buffer
	local count = math.min(#map.pieces, 65535)
	local b = buffer.create(MapCodec.HEADER + count * MapCodec.PIECE)
	buffer.writeu8(b, 0, MapCodec.VERSION)
	buffer.writeu8(b, 1, bit32.band(map.flags, 0xFF))
	buffer.writeu8(b, 2, bit32.band(map.tags, 0xFF))
	for i = 1, 3 do
		buffer.writeu8(b, 2 + i, math.clamp(map.name[i] or 0, 0, 255))
	end
	buffer.writeu16(b, 6, count)
	for index = 1, count do
		local e = map.pieces[index]
		local o = MapCodec.HEADER + (index - 1) * MapCodec.PIECE
		buffer.writeu8(b, o, math.clamp(e.t, 0, 255))
		buffer.writei16(b, o + 1, i16(e.x))
		buffer.writei16(b, o + 3, i16(e.y))
		buffer.writei16(b, o + 5, i16(e.z))
		buffer.writeu8(b, o + 7, math.clamp((e.r % 24) + 24 * math.clamp(e.tilt, 0, 6), 0, 255))
		buffer.writeu8(b, o + 8, math.clamp(e.s, 0, 255))
		buffer.writeu8(b, o + 9, math.clamp(e.c, 0, 255))
		buffer.writeu8(b, o + 10, math.clamp(e.p, 0, 255))
	end
	return b
end

-- Returns the map, or nil and why. Only checks the byte layout; MapRules checks the content.
function MapCodec.decode(b: buffer): (MapData?, string?)
	local length = buffer.len(b)
	if length < MapCodec.HEADER then
		return nil, "too short"
	end
	if buffer.readu8(b, 0) ~= MapCodec.VERSION then
		return nil, "unknown version"
	end
	local count = buffer.readu16(b, 6)
	if count > MapCodec.MAX_PIECES then
		return nil, "too many pieces"
	end
	if length ~= MapCodec.HEADER + count * MapCodec.PIECE then
		return nil, "wrong length"
	end
	local pieces = table.create(count)
	for index = 1, count do
		local o = MapCodec.HEADER + (index - 1) * MapCodec.PIECE
		local rotation = buffer.readu8(b, o + 7)
		pieces[index] = {
			t = buffer.readu8(b, o),
			x = buffer.readi16(b, o + 1),
			y = buffer.readi16(b, o + 3),
			z = buffer.readi16(b, o + 5),
			r = rotation % 24,
			tilt = rotation // 24,
			s = buffer.readu8(b, o + 8),
			c = buffer.readu8(b, o + 9),
			p = buffer.readu8(b, o + 10),
		}
	end
	return {
		flags = buffer.readu8(b, 1),
		tags = buffer.readu8(b, 2),
		name = { buffer.readu8(b, 3), buffer.readu8(b, 4), buffer.readu8(b, 5) },
		pieces = pieces,
	},
		nil
end

function MapCodec.fullDamage(map: MapData): boolean
	return bit32.btest(map.flags, 1)
end

function MapCodec.setFullDamage(map: MapData, on: boolean)
	map.flags = if on then bit32.bor(map.flags, 1) else bit32.band(map.flags, bit32.bnot(1))
end

-- A short fingerprint of a buffer (FNV-1a, 32 bit, hex): for logs and change checks, not security.
-- from = the first byte to hash (MapCodec.PIECES_FROM skips the version, flags, tags and name, so
-- changing the map settings after a TEST does not count as changing the map).
MapCodec.PIECES_FROM = 6

-- The piece count without decoding (the draft list)
function MapCodec.count(b: buffer): number
	return if buffer.len(b) >= MapCodec.HEADER then buffer.readu16(b, 6) else 0
end
function MapCodec.fingerprint(b: buffer, from: number?): string
	local hash = 2166136261
	for i = from or 0, buffer.len(b) - 1 do
		hash = bit32.bxor(hash, buffer.readu8(b, i))
		hash = (hash * 16777619) % 4294967296
	end
	return string.format("%08x", hash)
end

return MapCodec
