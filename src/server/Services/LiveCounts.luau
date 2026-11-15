-- LiveCounts: live player counts across every server of every place (spec: Hub > mode cards with live
-- player counts). Each server writes its own counts ({ tracks, race, brawl, highway }) to one
-- MemoryStore sorted map every Config.Hub.countsInterval s (each entry expires after countsExpiry s,
-- so a closed server drops out), then sums every server's entries. The totals go on the Workspace
-- attributes LiveTracks, LiveRace, LiveBrawl and LiveHighway. Tumble Park (HubService) and the mode
-- places (BrawlService) each start it with their own count function.

local MemoryStoreService = game:GetService("MemoryStoreService")
local Workspace = game:GetService("Workspace")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Config)

local LiveCounts = {}

local cfg = Config.Hub
local NAMES = { "tracks", "race", "brawl", "highway" }
local ATTRIBUTES = { tracks = "LiveTracks", race = "LiveRace", brawl = "LiveBrawl", highway = "LiveHighway" }

local localCounts: (() -> { [string]: number })? = nil

local function show(totals: { [string]: number })
	for _, name in NAMES do
		Workspace:SetAttribute(ATTRIBUTES[name], totals[name] or 0)
	end
end

local function publish()
	if localCounts == nil then
		return
	end
	local mine = localCounts()
	local key = if game.JobId ~= "" then game.JobId else "studio"
	local totals: { [string]: number } = mine
	local ok = pcall(function()
		local map = MemoryStoreService:GetSortedMap(cfg.countsStore)
		map:SetAsync(key, mine, cfg.countsExpiry)
		local sum = { tracks = 0, race = 0, brawl = 0, highway = 0 }
		local exclusive: string? = nil
		repeat
			local items = map:GetRangeAsync(Enum.SortDirection.Ascending, 200, exclusive)
			for _, item in items do
				if type(item.value) == "table" then
					for _, name in NAMES do
						sum[name] += tonumber(item.value[name]) or 0
					end
				end
			end
			exclusive = if #items == 200 then items[#items].key else nil
		until exclusive == nil
		totals = sum
	end)
	if not ok then
		-- No MemoryStore (Studio without API access): this server's own counts
		totals = mine
	end
	show(totals)
end

-- Start writing this server's counts (fn returns { tracks?, race?, brawl?, highway? })
function LiveCounts.start(fn: () -> { [string]: number })
	localCounts = fn
	task.spawn(function()
		while true do
			publish()
			task.wait(cfg.countsInterval)
		end
	end)
end

-- Raise a total at once to at least this server's own count (a new arrival sees itself counted)
function LiveCounts.bump()
	if localCounts == nil then
		return
	end
	local mine = localCounts()
	for _, name in NAMES do
		local attribute = ATTRIBUTES[name]
		if (Workspace:GetAttribute(attribute) or 0) < (mine[name] or 0) then
			Workspace:SetAttribute(attribute, mine[name])
		end
	end
end

return LiveCounts
