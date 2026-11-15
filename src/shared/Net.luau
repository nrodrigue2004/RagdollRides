-- Net: the remote wrapper (spec: Remote rules).
-- * Every remote is declared in Shared/Remotes. The server creates them; clients wait for them.
-- * Client-to-server calls are schema-checked and rate-limited per player. A failing call is dropped and
--   logged; 20 failures in 60 s kicks the player (not in Studio unless Config.Net.kickInStudio).
-- * No RemoteFunction from server to client, ever.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = require(script.Parent.Config)
local NetSchema = require(script.Parent.NetSchema)
local Remotes = require(script.Parent.Remotes)

local FOLDER_NAME = "Remotes"

local Net = {}

local remoteInstances: { [string]: Instance } = {}
local buckets: { [Player]: { [string]: NetSchema.Bucket } } = {}
local failures: { [Player]: NetSchema.FailureLog } = {}
local handlers: { [string]: (Player, ...any) -> () } = {}

local function getDef(name: string): Remotes.RemoteDef
	local def = Remotes[name]
	assert(def, "Unknown remote " .. name)
	return def
end

local function noteFailure(player: Player, name: string, reason: string)
	local log = failures[player]
	if not log then
		log = { times = {} }
		failures[player] = log
	end
	local count = NetSchema.recordFailure(log, os.clock(), Config.Net.failureWindow)
	warn(string.format("[Net] dropped %s from %s (%d): %s", name, player.Name, player.UserId, reason))
	if count >= Config.Net.kickAfterFailures then
		if RunService:IsStudio() and not Config.Net.kickInStudio then
			warn("[Net] would kick " .. player.Name .. " (Studio: kick disabled)")
			log.times = {}
			return
		end
		player:Kick("Connection problem. Please rejoin.")
	end
end

local function allow(player: Player, name: string, def: Remotes.RemoteDef): boolean
	local perPlayer = buckets[player]
	if not perPlayer then
		perPlayer = {}
		buckets[player] = perPlayer
	end
	local burst = def.burst or 1
	local bucket = perPlayer[name]
	local now = os.clock()
	if not bucket then
		bucket = NetSchema.newBucket(burst, now)
		perPlayer[name] = bucket
	end
	return NetSchema.take(bucket, def.rate or 1, burst, now)
end

---------------------------------------------------------------------------
-- Server
---------------------------------------------------------------------------

function Net.initServer()
	assert(RunService:IsServer(), "Net.initServer on client")
	local folder = Instance.new("Folder")
	folder.Name = FOLDER_NAME
	for name, def in Remotes do
		local remote = Instance.new(if def.unreliable then "UnreliableRemoteEvent" else "RemoteEvent")
		remote.Name = name
		remote.Parent = folder
		remoteInstances[name] = remote
		if def.dir ~= "S2C" then
			(remote :: any).OnServerEvent:Connect(function(player: Player, ...)
				if not allow(player, name, def) then
					noteFailure(player, name, "rate limit")
					return
				end
				local args = table.pack(...)
				local ok, reason = NetSchema.validate(def.schema or {}, args, args.n)
				if not ok then
					noteFailure(player, name, reason or "schema")
					return
				end
				local handler = handlers[name]
				if handler then
					handler(player, ...)
				end
			end)
		end
	end
	folder.Parent = ReplicatedStorage
	Players.PlayerRemoving:Connect(function(player)
		buckets[player] = nil
		failures[player] = nil
	end)
end

-- Handle a client-to-server remote. Arguments arrive already validated.
function Net.on(name: string, handler: (Player, ...any) -> ())
	local def = getDef(name)
	assert(def.dir ~= "S2C", name .. " is server-to-client")
	assert(handlers[name] == nil, "Handler already set for " .. name)
	handlers[name] = handler
end

function Net.fire(name: string, player: Player, ...: any)
	local remote = remoteInstances[name] :: any
	assert(remote, "Remote not created: " .. name)
	remote:FireClient(player, ...)
end

function Net.fireAll(name: string, ...: any)
	local remote = remoteInstances[name] :: any
	assert(remote, "Remote not created: " .. name)
	remote:FireAllClients(...)
end

function Net.fireAllExcept(name: string, except: Player, ...: any)
	local remote = remoteInstances[name] :: any
	assert(remote, "Remote not created: " .. name)
	for _, player in Players:GetPlayers() do
		if player ~= except then
			remote:FireClient(player, ...)
		end
	end
end

---------------------------------------------------------------------------
-- Client
---------------------------------------------------------------------------

local clientFolder: Folder? = nil

local function clientRemote(name: string): any
	local cached = remoteInstances[name]
	if cached then
		return cached
	end
	getDef(name)
	if not clientFolder then
		clientFolder = ReplicatedStorage:WaitForChild(FOLDER_NAME) :: Folder
	end
	local remote = (clientFolder :: Folder):WaitForChild(name)
	remoteInstances[name] = remote
	return remote
end

-- Client: wait once for every remote so later sends never yield inside a frame callback.
function Net.waitForRemotes()
	for name in Remotes do
		clientRemote(name)
	end
end

function Net.send(name: string, ...: any)
	assert(RunService:IsClient(), "Net.send is client-only")
	local def = getDef(name)
	assert(def.dir ~= "S2C", name .. " is server-to-client")
	clientRemote(name):FireServer(...)
end

function Net.listen(name: string, handler: (...any) -> ()): RBXScriptConnection
	assert(RunService:IsClient(), "Net.listen is client-only")
	local def = getDef(name)
	assert(def.dir ~= "C2S", name .. " is client-to-server")
	return clientRemote(name).OnClientEvent:Connect(handler)
end

return Net
