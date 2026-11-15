-- JuiceService: one event bus for feedback (spec: Audio, VFX and juice). Every event name maps to a row in
-- Config.Juice (shake, punch, vibration, sparks) and Config.Sounds (sound id), so the juice pass is a data
-- table, not scattered code. Driving and crash events are wired here; damage events (PanelTear,
-- GlassShatter, FireStart, Explosion, Repair) are fired by DamageController and DamageVisuals, and hit-stop
-- and the slow-mo replay live in CrashReplay.

local HapticService = game:GetService("HapticService")
local SoundService = game:GetService("SoundService")
local UserInputService = game:GetService("UserInputService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Config)
local Signal = require(Shared.Util.Signal)

local JuiceService = {}

JuiceService.Fired = Signal.new() -- (eventName, data) for the dev panel and later the HUD pop layer

local controllers: any = nil
local soundGroup: SoundGroup
local settings = { shake = true, vibration = true }

local function playSound(name: string, volume: number?, pitch: number?)
	local id = Config.Sounds[name]
	if not id or id == "" then
		return
	end
	local sound = Instance.new("Sound")
	sound.SoundId = id
	sound.Volume = volume or 0.6
	sound.PlaybackSpeed = pitch or 1
	sound.SoundGroup = soundGroup
	sound.Parent = SoundService
	sound:Play()
	sound.Ended:Once(function()
		sound:Destroy()
	end)
	task.delay(6, function()
		if sound.Parent then
			sound:Destroy()
		end
	end)
end

local function vibrate(strength: number, duration: number)
	if not settings.vibration or strength <= 0 then
		return
	end
	-- Gamepads only for now; phone vibration needs Roblox's haptics API checked on a device (verify).
	local pad = Enum.UserInputType.Gamepad1
	local ok, supported = pcall(function()
		return UserInputService.GamepadEnabled and HapticService:IsVibrationSupported(pad)
	end)
	if not ok or not supported then
		return
	end
	pcall(function()
		HapticService:SetMotor(pad, Enum.VibrationMotor.Large, strength)
	end)
	task.delay(duration, function()
		pcall(function()
			HapticService:SetMotor(pad, Enum.VibrationMotor.Large, 0)
		end)
	end)
end

-- data: { scale = 0..n, point = Vector3?, direction = Vector3? }
function JuiceService.fire(event: string, data: any?)
	data = data or {}
	local row = Config.Juice[event] or {}
	local scale = data.scale or 1
	if row.shake and settings.shake then
		controllers.Camera.shake(row.shake * scale, row.shakeTime or 0.1)
	end
	if row.punch and data.direction and settings.shake then
		controllers.Camera.punch(data.direction, row.punch * scale)
	end
	if row.vibration then
		vibrate(math.clamp(row.vibration * scale, 0, 1), row.vibrationTime or 0.05)
	end
	if row.sparks and data.point then
		local vehicle = controllers.Vehicle.getState()
		if vehicle and vehicle.effects then
			vehicle.effects:emitSparks(data.point, math.floor(row.sparks * math.min(scale, 1.5)))
		end
	end
	playSound(event, data.volume, data.pitch)
	JuiceService.Fired:Fire(event, data)
end

function JuiceService.setShake(enabled: boolean)
	settings.shake = enabled
	controllers.Camera.setReducedMotion(not enabled)
end

-- Sound effects volume (settings: 0..1)
function JuiceService.setVolume(value: number)
	if soundGroup then
		soundGroup.Volume = math.clamp(value, 0, 1)
	end
end

function JuiceService.init(all)
	controllers = all
	soundGroup = Instance.new("SoundGroup")
	soundGroup.Name = "SFX"
	soundGroup.Volume = 0.8
	soundGroup.Parent = SoundService
end

function JuiceService.start()
	local Vehicle = controllers.Vehicle
	Vehicle.Impact:Connect(function(info)
		-- Punch the camera the way the car was shoved (from the contact toward the car's centre)
		local chassis = Vehicle.getChassis()
		local direction = if chassis then chassis.Position - info.point else Vector3.zero
		if info.side == "Bottom" then
			JuiceService.fire(
				"Landing",
				{ scale = math.clamp(info.closingSpeed / 60, 0.2, 1.5), point = info.point }
			)
			return
		end
		if info.tier == "Scrape" then
			local vehicle = Vehicle.getState()
			if vehicle and vehicle.effects then
				vehicle.effects:emitSparks(info.point, 3)
			end
			return
		end
		JuiceService.fire(info.tier, {
			scale = math.clamp(info.impact / 60, 0.4, 1.5),
			point = info.point,
			direction = direction,
		})
	end)
	Vehicle.Landed:Connect(function(fallSpeed: number)
		JuiceService.fire("Landing", { scale = math.clamp(fallSpeed / 60, 0.2, 1.5) })
	end)
	Vehicle.Hopped:Connect(function()
		JuiceService.fire("Hop")
	end)
	Vehicle.CheckpointReached:Connect(function(index)
		JuiceService.fire("Checkpoint", { index = index })
	end)
	if controllers.Ragdoll then
		controllers.Ragdoll.Ejected:Connect(function()
			JuiceService.fire("RiderEject")
		end)
		controllers.Ragdoll.Respawned:Connect(function()
			JuiceService.fire("Respawn")
		end)
	end
end

return JuiceService
