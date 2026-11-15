-- ProfileClient: this player's profile as the server shows it (ProfileSchema.clientView, on Profile.Data).
-- Display data only: coins, stars, best times, tutorial flags and settings. The server decides everything.

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Config)
local Net = require(Shared.Net)
local Signal = require(Shared.Util.Signal)

local ProfileClient = {}

ProfileClient.Changed = Signal.new() -- (view, previous)
ProfileClient.Notice = Signal.new() -- (key) a preset server message

local view: { [string]: any }? = nil

function ProfileClient.get(): { [string]: any }?
	return view
end

function ProfileClient.isLoaded(): boolean
	return view ~= nil
end

-- The best entry for a map, if any: { best = ms, stars, splits }
function ProfileClient.track(mapId: string): { [string]: any }?
	return view and view.tracks[mapId]
end

-- The next thing to save up for: the first goal the player doesn't own yet
function ProfileClient.goal(): { label: string, coins: number, stars: number? }?
	if not view then
		return nil
	end
	for _, goal in Config.Goals do
		if not table.find(view.owned, goal.id) and not table.find(view.inventory, goal.id) then
			return goal
		end
	end
	return nil
end

function ProfileClient.start()
	Net.listen("Profile.Data", function(data)
		if type(data) ~= "table" then
			return
		end
		local previous = view
		view = data
		ProfileClient.Changed:Fire(data, previous)
	end)
	Net.listen("Notice", function(key)
		if type(key) == "string" then
			ProfileClient.Notice:Fire(key)
		end
	end)
end

return ProfileClient
