-- Mix: the sound mix groups (spec: Audio design > Mix groups: Master, Music, SFX, Vehicle, UI, Voice).
-- Groups nest, so a parent's volume scales its children: Master holds Music and SFX; SFX holds Vehicle,
-- UI and Voice, so the SFX volume setting moves all of them. Anyone can ask for a group first; it is
-- made on first use.

local SoundService = game:GetService("SoundService")

local Mix = {}

local PARENTS = { Music = "Master", SFX = "Master", Vehicle = "SFX", UI = "SFX", Voice = "SFX" }

function Mix.group(name: string): SoundGroup
	local parentName = PARENTS[name]
	local parent: Instance = if parentName then Mix.group(parentName) else SoundService
	local group = parent:FindFirstChild(name)
	if group == nil or not group:IsA("SoundGroup") then
		-- An older loose group of this name at the top (before the mix existed) moves under its parent
		local loose = SoundService:FindFirstChild(name)
		if loose and loose:IsA("SoundGroup") and parent ~= SoundService then
			loose.Parent = parent
			return loose
		end
		local g = Instance.new("SoundGroup")
		g.Name = name
		g.Parent = parent
		return g
	end
	return group :: SoundGroup
end

return Mix
