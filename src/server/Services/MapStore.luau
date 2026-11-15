-- MapStore: the DataStores behind player maps (spec: Data model > stores), with the same API in memory
-- for Studio without API access (DataService's memory mode), so every map rule can be tried in Studio.
--   Maps_v1        M_<mapId> map record, N_<a>_<n>_<p> name counters, C_<userId> a creator's map ids,
--                  R_<userId> royalties waiting for a creator who was not in the server
--   MapIndex_v1    ordered, one scope per tab: Newest (publish time), Popular (score x 100), Featured
--   Moderation_v1  U_<userId> publish strikes and bans, R_<mapId> report tallies
-- Reads go through a short cache (records change rarely; plays and ratings are batched anyway).

local DataStoreService = game:GetService("DataStoreService")

local DataService = require(script.Parent.DataService)

local MapStore = {}

MapStore.MAPS = "Maps_v1"
MapStore.MODERATION = "Moderation_v1"
MapStore.INDEX = "MapIndex_v1"

local CACHE_SECONDS = 120

local stores: { [string]: DataStore } = {}
local ordered: { [string]: OrderedDataStore } = {}
local memory: { [string]: { [string]: any } } = {}
local memoryOrdered: { [string]: { [string]: number } } = {}
local cache: { [string]: { value: any, time: number } } = {}

local function useMemory(): boolean
	return DataService.isMemoryMode()
end
MapStore.useMemory = useMemory

local function storeFor(name: string): DataStore?
	if stores[name] == nil then
		local ok, store = pcall(function()
			return DataStoreService:GetDataStore(name)
		end)
		if ok then
			stores[name] = store
		end
	end
	return stores[name]
end

local function orderedFor(scope: string): OrderedDataStore?
	if ordered[scope] == nil then
		local ok, store = pcall(function()
			return DataStoreService:GetOrderedDataStore(MapStore.INDEX, scope)
		end)
		if ok then
			ordered[scope] = store
		end
	end
	return ordered[scope]
end

-- Read a key (cached for 2 minutes unless fresh is asked for). Returns ok, value.
function MapStore.get(storeName: string, key: string, fresh: boolean?): (boolean, any)
	local cacheKey = storeName .. "/" .. key
	local hit = cache[cacheKey]
	if not fresh and hit and os.clock() - hit.time < CACHE_SECONDS then
		return true, hit.value
	end
	if useMemory() then
		local bucket = memory[storeName] or {}
		return true, bucket[key]
	end
	local store = storeFor(storeName)
	if store == nil then
		return false, nil
	end
	local ok, value = pcall(function()
		return store:GetAsync(key)
	end)
	if ok then
		cache[cacheKey] = { value = value, time = os.clock() }
	end
	return ok, value
end

-- UpdateAsync: fn(old) returns the new value, or nil to leave it. Returns ok, the stored value.
function MapStore.update(storeName: string, key: string, fn: (any) -> any): (boolean, any)
	local cacheKey = storeName .. "/" .. key
	if useMemory() then
		local bucket = memory[storeName] or {}
		memory[storeName] = bucket
		local value = fn(bucket[key])
		if value ~= nil then
			bucket[key] = value
		end
		cache[cacheKey] = nil
		return true, bucket[key]
	end
	local store = storeFor(storeName)
	if store == nil then
		return false, nil
	end
	local ok, value = pcall(function()
		return store:UpdateAsync(key, fn)
	end)
	if ok then
		cache[cacheKey] = { value = value, time = os.clock() }
	else
		warn(string.format("[MapStore] update %s/%s failed: %s", storeName, key, tostring(value)))
	end
	return ok, value
end

function MapStore.forget(storeName: string, key: string)
	cache[storeName .. "/" .. key] = nil
end

-- Ordered indexes (browse tabs)
function MapStore.indexSet(scope: string, mapId: string, score: number)
	score = math.floor(score)
	if useMemory() then
		local list = memoryOrdered[scope] or {}
		memoryOrdered[scope] = list
		list[mapId] = score
		return
	end
	local store = orderedFor(scope)
	if store then
		pcall(function()
			store:SetAsync(mapId, score)
		end)
	end
end

function MapStore.indexRemove(scope: string, mapId: string)
	if useMemory() then
		local list = memoryOrdered[scope]
		if list then
			list[mapId] = nil
		end
		return
	end
	local store = orderedFor(scope)
	if store then
		pcall(function()
			store:RemoveAsync(mapId)
		end)
	end
end

-- The top n map ids of a tab, highest score first
function MapStore.indexTop(scope: string, n: number): (boolean, { string })
	if useMemory() then
		local list = {}
		for id, score in memoryOrdered[scope] or {} do
			table.insert(list, { id = id, score = score })
		end
		table.sort(list, function(a, b)
			return a.score > b.score
		end)
		local ids = {}
		for i = 1, math.min(n, #list) do
			ids[i] = list[i].id
		end
		return true, ids
	end
	local store = orderedFor(scope)
	if store == nil then
		return false, {}
	end
	local ok, result = pcall(function()
		local pages = store:GetSortedAsync(false, math.min(n, 100))
		local ids = {}
		for _, entry in pages:GetCurrentPage() do
			table.insert(ids, entry.key)
		end
		return ids
	end)
	return ok, if ok then result else {}
end

return MapStore
