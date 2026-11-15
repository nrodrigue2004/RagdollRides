-- AudioController: music, engines and voice lines (spec: Audio design; Juice table > Accelerate).
-- * Music: this place's loop (Tumble Park calm, Cinder Cove busy, Sunny Pass driving) in the Music
--   group, crossfaded over 1.5 s when it changes and ducked 6 dB while any results card shows.
-- * Engines: a looping hum on your car and the 3 nearest other cars (workspace.Vehicles), its pitch
--   rising with speed; 3D, so nothing is heard past 150 studs. Vehicle group.
-- * Voice: JuiceService calls voice(event); a juice event with a line in Config.Audio.voice for this
--   place plays it (Voice group), at most one every 2.5 s.
-- All ids are empty until nate picks licence-checked sounds, so nothing plays yet (and nothing breaks).

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Config)
local Place = require(Shared.Place)

local Client = script.Parent.Parent
local BrawlHud = require(Client.Ui.BrawlHud)
local HighwayHud = require(Client.Ui.HighwayHud)
local Mix = require(Client.Fx.Mix)
local TracksHud = require(Client.Ui.TracksHud)

local LocalPlayer = Players.LocalPlayer
local cfg = Config.Audio

local AudioController = {}

local current: Sound? = nil
local currentId = ""
local ducked = false
local lastVoice = -math.huge
local engines: { [Model]: Sound } = {}

local function fade(sound: Sound, volume: number, seconds: number)
	TweenService:Create(sound, TweenInfo.new(seconds, Enum.EasingStyle.Sine), { Volume = volume }):Play()
end

local function musicVolume(): number
	local v = cfg.musicVolume
	if ducked then
		v *= 10 ^ (-cfg.duckDb / 20)
	end
	return v
end

-- Play a loop (crossfading from the one before); "" stops the music
function AudioController.playMusic(id: string)
	if id == currentId then
		return
	end
	currentId = id
	local old = current
	if old then
		fade(old, 0, cfg.crossfade)
		task.delay(cfg.crossfade + 0.1, function()
			old:Destroy()
		end)
	end
	current = nil
	if id == "" then
		return
	end
	local sound = Instance.new("Sound")
	sound.Name = "Music"
	sound.SoundId = id
	sound.Looped = true
	sound.Volume = 0
	sound.SoundGroup = Mix.group("Music")
	sound.Parent = Mix.group("Music")
	sound:Play()
	fade(sound, musicVolume(), cfg.crossfade)
	current = sound
end

local function setDucked(on: boolean)
	if ducked == on then
		return
	end
	ducked = on
	if current then
		fade(current, musicVolume(), 0.4)
	end
end

function AudioController.voice(event: string)
	local line = cfg.voice[event]
	if line == nil or line.id == "" or line.place ~= Place.role() then
		return
	end
	local t = os.clock()
	if t - lastVoice < cfg.voiceGap then
		return
	end
	lastVoice = t
	local sound = Instance.new("Sound")
	sound.SoundId = line.id
	sound.Volume = 0.9
	sound.SoundGroup = Mix.group("Voice")
	sound.Parent = Mix.group("Voice")
	sound:Play()
	sound.Ended:Once(function()
		sound:Destroy()
	end)
	task.delay(8, function()
		if sound.Parent then
			sound:Destroy()
		end
	end)
end

local function engineFor(model: Model): Sound?
	local existing = engines[model]
	if existing and existing.Parent then
		return existing
	end
	local id = Config.Sounds.Engine
	local chassis = model.PrimaryPart
	if id == nil or id == "" or chassis == nil then
		return nil
	end
	local e = cfg.engine
	local sound = Instance.new("Sound")
	sound.Name = "Engine"
	sound.SoundId = id
	sound.Looped = true
	sound.Volume = e.volume
	sound.RollOffMode = Enum.RollOffMode.LinearSquare
	sound.RollOffMinDistance = 10
	sound.RollOffMaxDistance = e.maxDistance
	sound.SoundGroup = Mix.group("Vehicle")
	sound.Parent = chassis
	sound:Play()
	engines[model] = sound
	return sound
end

local function stepEngines()
	local folder = Workspace:FindFirstChild("Vehicles")
	local camera = Workspace.CurrentCamera
	if folder == nil or camera == nil then
		return
	end
	local e = cfg.engine
	local origin = camera.CFrame.Position
	local list: { { model: Model, d: number } } = {}
	for _, model in folder:GetChildren() do
		if model:IsA("Model") and model.PrimaryPart then
			local mine = model:GetAttribute("OwnerUserId") == LocalPlayer.UserId
			local d = if mine then -1 else (model.PrimaryPart.Position - origin).Magnitude
			if d <= e.maxDistance then
				table.insert(list, { model = model, d = d })
			end
		end
	end
	table.sort(list, function(a, b)
		return a.d < b.d
	end)
	local keep: { [Model]: boolean } = {}
	for i = 1, math.min(e.cars, #list) do
		local model = list[i].model
		local sound = engineFor(model)
		if sound then
			keep[model] = true
			local speed = (model.PrimaryPart :: BasePart).AssemblyLinearVelocity.Magnitude
			local f = math.clamp(speed / e.topSpeed, 0, 1)
			sound.PlaybackSpeed = e.minPitch + (e.maxPitch - e.minPitch) * f
		end
	end
	for model, sound in engines do
		if not keep[model] or model.Parent == nil then
			sound:Destroy()
			engines[model] = nil
		end
	end
end

function AudioController.start()
	AudioController.playMusic(cfg.music[Place.role()] or "")
	local clock = 0
	RunService.Heartbeat:Connect(function(dt)
		clock += dt
		if clock < 0.25 then
			return
		end
		clock = 0
		setDucked(TracksHud.resultsOpen() or BrawlHud.resultsOpen() or HighwayHud.resultsOpen())
		stepEngines()
	end)
end

return AudioController
