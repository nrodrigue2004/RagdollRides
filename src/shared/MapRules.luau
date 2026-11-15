--!strict
-- MapRules: the builder's limits (spec: Map builder > Grid and limits; pure, unit tested). The client
-- uses them to show counters and block a placement; the server runs them again on every draft save,
-- TEST and publish, so a modified client can never get past them.

local PieceCatalog = if script
	then require(script.Parent.PieceCatalog)
	else (require :: any)("./PieceCatalog")
local MapCodec = if script then require(script.Parent.MapCodec) else (require :: any)("./MapCodec")
local MapNames = if script then require(script.Parent.MapNames) else (require :: any)("./MapNames")

local MapRules = {}

MapRules.LIMITS = {
	pieces = 250,
	parts = 400,
	checkpoints = 10,
	moving = 12,
	pads = 40,
	volume = { 1024, 256, 1024 }, -- studs, x and z centred on the plot, y from 0 up
}

export type Counts = {
	pieces: number,
	parts: number,
	starts: number,
	finishes: number,
	checkpoints: number,
	moving: number,
	pads: number,
}

export type Options = {
	vip: boolean?, -- fine grid and the 24 colours
}

function MapRules.count(map: MapCodec.MapData): Counts
	local counts =
		{ pieces = #map.pieces, parts = 0, starts = 0, finishes = 0, checkpoints = 0, moving = 0, pads = 0 }
	for _, entry in map.pieces do
		local def = PieceCatalog.get(entry.t)
		if def then
			counts.parts += def.cost
			if def.group == "start" then
				counts.starts += 1
			elseif def.group == "finish" then
				counts.finishes += 1
			elseif def.group == "checkpoint" then
				counts.checkpoints += 1
			elseif def.group == "pad" then
				counts.pads += 1
			end
			if def.moving then
				counts.moving += 1
			end
		end
	end
	return counts
end

-- One entry on its own: a known type, a valid size, rotation, colour and position. Returns ok, reason.
function MapRules.checkEntry(entry: PieceCatalog.Entry, options: Options?): (boolean, string?)
	local def = PieceCatalog.get(entry.t)
	if def == nil then
		return false, "unknown piece"
	end
	if entry.s < 0 or entry.s >= def.sizes then
		return false, "bad size"
	end
	if entry.r < 0 or entry.r > 23 or entry.tilt < 0 or entry.tilt > 6 then
		return false, "bad rotation"
	end
	if entry.tilt ~= 0 and not def.tilt then
		return false, "this piece cannot tilt"
	end
	local colours = if options and options.vip then #PieceCatalog.PALETTE else PieceCatalog.FREE_COLOURS
	if entry.c < 0 or entry.c > colours then
		return false, "bad colour"
	end
	if entry.p < 0 or entry.p > 255 then
		return false, "bad phase"
	end
	local step = if options and options.vip then 1 else PieceCatalog.NORMAL_STEP
	if entry.x % step ~= 0 or entry.z % step ~= 0 then
		return false, "off the grid"
	end
	local volume = MapRules.LIMITS.volume
	local x, y, z = PieceCatalog.anchor(entry)
	if math.abs(x) > volume[1] / 2 or math.abs(z) > volume[3] / 2 or y < 0 or y > volume[2] then
		return false, "outside the build area"
	end
	return true, nil
end

-- Limits that hold for any draft (a draft may still be missing its start or finish)
function MapRules.checkDraft(map: MapCodec.MapData, options: Options?): (boolean, string?)
	if not MapNames.validTags(map.tags) then
		return false, "bad tags"
	end
	if map.flags < 0 or map.flags > 7 then
		return false, "bad flags"
	end
	local name = map.name
	if
		not (name[1] == 0 and name[2] == 0 and name[3] == 0) and not MapNames.valid(name[1], name[2], name[3])
	then
		return false, "bad name"
	end
	for _, entry in map.pieces do
		local ok, reason = MapRules.checkEntry(entry, options)
		if not ok then
			return false, reason
		end
	end
	local counts = MapRules.count(map)
	local limits = MapRules.LIMITS
	if counts.pieces > limits.pieces then
		return false, "too many pieces"
	elseif counts.parts > limits.parts then
		return false, "too many parts"
	elseif counts.checkpoints > limits.checkpoints then
		return false, "too many checkpoints"
	elseif counts.moving > limits.moving then
		return false, "too many moving pieces"
	elseif counts.pads > limits.pads then
		return false, "too many pads"
	elseif counts.starts > 1 then
		return false, "only one start gate"
	elseif counts.finishes > 1 then
		return false, "only one finish arch"
	end
	return true, nil
end

-- A map that can be driven (TEST) and published: a draft with exactly one start gate and one finish arch
function MapRules.checkPlayable(map: MapCodec.MapData, options: Options?): (boolean, string?)
	local ok, reason = MapRules.checkDraft(map, options)
	if not ok then
		return false, reason
	end
	local counts = MapRules.count(map)
	if counts.starts ~= 1 then
		return false, "needs a start gate"
	elseif counts.finishes ~= 1 then
		return false, "needs a finish arch"
	end
	return true, nil
end

-- Could one more piece of this type go in? (the tray greys out pieces that would break a limit)
function MapRules.canAdd(map: MapCodec.MapData, typeId: number): (boolean, string?)
	local def = PieceCatalog.get(typeId)
	if def == nil then
		return false, "unknown piece"
	end
	local counts = MapRules.count(map)
	local limits = MapRules.LIMITS
	if counts.pieces + 1 > limits.pieces then
		return false, "Piece limit"
	elseif counts.parts + def.cost > limits.parts then
		return false, "Part limit"
	elseif def.group == "start" and counts.starts >= 1 then
		return false, "One start"
	elseif def.group == "finish" and counts.finishes >= 1 then
		return false, "One finish"
	elseif def.group == "checkpoint" and counts.checkpoints >= limits.checkpoints then
		return false, "Max 10"
	elseif def.group == "pad" and counts.pads >= limits.pads then
		return false, "Pad limit"
	elseif def.moving and counts.moving >= limits.moving then
		return false, "Moving limit"
	end
	return true, nil
end

return MapRules
