--!strict
-- Emotes: the rider's emote wheel (spec: Hub and menus > Rider: emote wheel slots; Robux catalog > Rider
-- Pass: 4 emotes and emote wheel slots 5 and 6). Pure data and maths, so tests/run.luau checks it in Lune.
-- * The wheel has 4 slots, 6 with the Rider Pass. It starts with the 4 free emotes; the Rider tab of the
--   garage swaps any emote you may use into any slot you have (profile.rider.emotes, "" is an empty slot).
-- * An emote is a short seated pose played on top of the driving pose: the rider never leaves the seat,
--   hands come back to the wheel, and the car drives exactly the same (looks only).
-- * pose(id, t) gives each piece's angles (degrees) at time t, plus a 0 to 1 blend that eases in and out.
--   Arms swing from the shoulder (x forward and up, z out to the side; a seated arm rests at x 70), the
--   torso turns about the seat and the head tilts at the neck.

local Catalog = if script then require(script.Parent.Catalog) else (require :: any)("./Catalog")

local Emotes = {}

Emotes.BASE_SLOTS = 4
Emotes.PASS_SLOTS = 6
Emotes.EASE = 0.2 -- seconds to blend in and out

-- The 4 free emotes, in their starting slots
Emotes.DEFAULT = { "emote_thumbs", "emote_point", "emote_laugh", "emote_shrug" }

export type Angles = { x: number?, y: number?, z: number? }
export type Wiggle = { piece: string, axis: string, amp: number, hz: number }
export type Def = {
	duration: number,
	pose: { [string]: Angles }, -- target angles per piece (Torso, Head, LeftArm, RightArm)
	wiggle: { Wiggle }?, -- oscillations on top
	spin: number?, -- whole turns of the torso over the emote
	label: string, -- the short word on the wheel (preset, never typed)
}

-- PLACEHOLDER ART: poses are rough block-rider poses until the rider model has a proper rig.
Emotes.defs = {
	emote_thumbs = {
		duration = 1.8,
		label = "Nice!",
		pose = { RightArm = { x = 120, z = 15 }, Head = { x = -8 } },
		wiggle = { { piece = "Head", axis = "x", amp = 8, hz = 2.5 } },
	},
	emote_point = {
		duration = 1.8,
		label = "Look!",
		pose = { RightArm = { x = 95, z = -10 }, Torso = { y = -12 }, LeftArm = { x = 20, z = -35 } },
		wiggle = { { piece = "RightArm", axis = "x", amp = 4, hz = 3 } },
	},
	emote_laugh = {
		duration = 2,
		label = "Ha ha!",
		pose = { LeftArm = { x = 45, z = 20 }, RightArm = { x = 45, z = -20 }, Head = { x = -20 } },
		wiggle = {
			{ piece = "Torso", axis = "x", amp = 8, hz = 6 },
			{ piece = "Head", axis = "x", amp = 10, hz = 6 },
		},
	},
	emote_shrug = {
		duration = 1.6,
		label = "Oops",
		pose = { LeftArm = { x = 40, z = -40 }, RightArm = { x = 40, z = 40 }, Head = { z = 15 } },
		wiggle = {
			{ piece = "LeftArm", axis = "z", amp = 8, hz = 2 },
			{ piece = "RightArm", axis = "z", amp = 8, hz = 2 },
		},
	},
	-- Rider Pass
	emote_wave = {
		duration = 2,
		label = "Hi!",
		pose = { RightArm = { x = 20, z = 150 }, Head = { z = -10 } },
		wiggle = { { piece = "RightArm", axis = "z", amp = 20, hz = 3 } },
	},
	emote_cheer = {
		duration = 2,
		label = "Yay!",
		pose = { LeftArm = { x = 10, z = -160 }, RightArm = { x = 10, z = 160 }, Head = { x = -15 } },
		wiggle = {
			{ piece = "LeftArm", axis = "x", amp = 12, hz = 4 },
			{ piece = "RightArm", axis = "x", amp = 12, hz = 4 },
			{ piece = "Torso", axis = "z", amp = 5, hz = 4 },
		},
	},
	emote_flex = {
		duration = 2,
		label = "Strong!",
		pose = { LeftArm = { x = 0, z = -95 }, RightArm = { x = 0, z = 95 } },
		wiggle = {
			{ piece = "LeftArm", axis = "z", amp = 12, hz = 2.5 },
			{ piece = "RightArm", axis = "z", amp = 12, hz = 2.5 },
			{ piece = "Torso", axis = "y", amp = 10, hz = 1.25 },
		},
	},
	emote_spin = {
		duration = 2.2,
		label = "Wheee!",
		pose = { LeftArm = { x = 0, z = -80 }, RightArm = { x = 0, z = 80 } },
		spin = 2,
		wiggle = { { piece = "Head", axis = "z", amp = 15, hz = 3 } },
	},
} :: { [string]: Def }

Emotes.PIECES = { "Torso", "Head", "LeftArm", "RightArm" }

-- How many wheel slots this player has
function Emotes.slotCount(riderPass: boolean): number
	return if riderPass then Emotes.PASS_SLOTS else Emotes.BASE_SLOTS
end

-- May this player play this emote? Free emotes always; pass emotes with their pass; others if owned.
function Emotes.canUse(profile: { [string]: any }, id: string): boolean
	local item = Catalog.byId[id]
	if item == nil or item.kind ~= "emote" or Emotes.defs[id] == nil then
		return false
	end
	if item.source == "free" then
		return true
	end
	if item.pass then
		return (profile.passes or {})[item.pass] == true
	end
	return (profile.inventory or {})[id] ~= nil
end

-- The wheel as the player sees it: slotCount entries, "" for an empty slot. Saved slots win; with no
-- saved wheel the free emotes fill the first 4. A slot holding an emote the player can no longer use
-- (a refunded pass) shows empty.
function Emotes.wheel(profile: { [string]: any }): { string }
	local saved = ((profile.rider or {}).emotes or {}) :: { [any]: any }
	local count = Emotes.slotCount((profile.passes or {}).rider == true)
	local fresh = next(saved) == nil
	local out = {}
	for i = 1, count do
		local id = if fresh then (Emotes.DEFAULT[i] or "") else (saved[i] or saved[tostring(i)] or "")
		if type(id) ~= "string" or (id ~= "" and not Emotes.canUse(profile, id)) then
			id = ""
		end
		out[i] = id
	end
	return out
end

-- Put an emote in a slot (or "" to empty it). Returns the new saved list, or nil when not allowed.
-- The same emote can't sit in two slots: it moves.
function Emotes.setSlot(profile: { [string]: any }, slot: number, id: string): { string }?
	local count = Emotes.slotCount((profile.passes or {}).rider == true)
	if slot ~= math.floor(slot) or slot < 1 or slot > count then
		return nil
	end
	if id ~= "" and not Emotes.canUse(profile, id) then
		return nil
	end
	local current = Emotes.wheel(profile)
	-- Keep the hidden pass slots as they were saved, so buying the pass back restores them
	local saved = ((profile.rider or {}).emotes or {}) :: { [any]: any }
	local out = {}
	for i = 1, Emotes.PASS_SLOTS do
		local v = current[i]
		if v == nil then
			v = saved[i] or ""
		end
		out[i] = if v == id and id ~= "" then "" else v
	end
	out[slot] = id
	return out
end

local function ease(t: number, duration: number): number
	local e = Emotes.EASE
	local w = math.min(t / e, (duration - t) / e, 1)
	w = math.clamp(w, 0, 1)
	return w * w * (3 - 2 * w) -- smoothstep
end

-- The pose at time t (seconds): angles per piece in degrees, and the blend weight (0 when finished)
function Emotes.pose(id: string, t: number): ({ [string]: { x: number, y: number, z: number } }, number)
	local def = Emotes.defs[id]
	local out: { [string]: { x: number, y: number, z: number } } = {}
	if def == nil or t < 0 or t >= def.duration then
		return out, 0
	end
	for _, piece in Emotes.PIECES do
		local a = def.pose[piece] or {}
		out[piece] = { x = a.x or 0, y = a.y or 0, z = a.z or 0 }
	end
	-- Arms with no target stay at the wheel
	for _, arm in { "LeftArm", "RightArm" } do
		if def.pose[arm] == nil then
			out[arm].x = 70
		end
	end
	for _, w in def.wiggle or {} do
		local p = out[w.piece]
		if p then
			p[w.axis] += math.sin(t * w.hz * 2 * math.pi) * w.amp
		end
	end
	if def.spin then
		local f = t / def.duration
		out.Torso.y += 360 * def.spin * (f * f * (3 - 2 * f))
	end
	return out, ease(t, def.duration)
end

return Emotes
