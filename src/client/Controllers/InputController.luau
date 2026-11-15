-- InputController: one input snapshot per physics step from keyboard, gamepad, touch buttons, or a
-- scripted override (the dev panel's feel tests).
-- Keyboard: W/S or Up/Down gas and brake, A/D or Left/Right steer, Space jump, Q lean back, E lean
-- forward, Left Shift handbrake, R reset (or respawn while ragdolled), F flip.
-- Gamepad: RT gas, LT brake, left stick steer and lean, A jump, B handbrake, X reset/respawn, Y flip.
-- Digital steering ramps 0 to full in 0.12 s; analog sticks are instant (spec: Steering).

local UserInputService = game:GetService("UserInputService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Config)
local VehicleMath = require(Shared.VehicleMath)

local InputController = {}

export type Snapshot = {
	throttle: number, -- 0..1
	brake: number, -- 0..1
	steer: number, -- -1 (left) .. 1 (right)
	lean: number, -- -1 (back) .. 1 (forward)
	handbrake: boolean,
	analogSteer: boolean,
}

local touch = {
	gas = false,
	brake = false,
	left = false,
	right = false,
	leanForward = false,
	leanBack = false,
}

local pad = { throttle = 0, brake = 0, stickX = 0, stickY = 0, handbrake = false }
local pressed: { [string]: boolean } = {}
local override: Snapshot? = nil
local rampedSteer = 0
local lastDevice = "keyboard"

local DEADZONE = 0.12

local function keyDown(...: Enum.KeyCode): boolean
	for _, key in { ... } do
		if UserInputService:IsKeyDown(key) then
			return true
		end
	end
	return false
end

local function deadzone(value: number): number
	if math.abs(value) < DEADZONE then
		return 0
	end
	return math.sign(value) * (math.abs(value) - DEADZONE) / (1 - DEADZONE)
end

local function press(action: string)
	pressed[action] = true
end

-- Edge-triggered actions: "jump", "reset", "flip", "respawn", "flail". Returns true once per press.
function InputController.consume(action: string): boolean
	if pressed[action] then
		pressed[action] = false
		return true
	end
	return false
end

function InputController.setTouch(action: string, value: boolean)
	if (touch :: any)[action] ~= nil then
		(touch :: any)[action] = value
		lastDevice = "touch"
	end
end

function InputController.tap(action: string)
	press(action)
end

function InputController.setOverride(snapshot: Snapshot?)
	override = snapshot
end

-- Held at a start line (a quick race countdown): steering works, gas does not, the brake is on
local held = false
function InputController.setHold(on: boolean)
	held = on
end

function InputController.isHeld(): boolean
	return held
end

function InputController.lastDevice(): string
	return lastDevice
end

function InputController.read(dt: number): Snapshot
	if override then
		return override
	end
	if UserInputService:GetFocusedTextBox() then
		rampedSteer = 0
		return { throttle = 0, brake = 0, steer = 0, lean = 0, handbrake = false, analogSteer = false }
	end

	local throttle =
		math.max(if keyDown(Enum.KeyCode.W, Enum.KeyCode.Up) or touch.gas then 1 else 0, pad.throttle)
	local brake =
		math.max(if keyDown(Enum.KeyCode.S, Enum.KeyCode.Down) or touch.brake then 1 else 0, pad.brake)

	local digitalSteer = 0
	if keyDown(Enum.KeyCode.A, Enum.KeyCode.Left) or touch.left then
		digitalSteer -= 1
	end
	if keyDown(Enum.KeyCode.D, Enum.KeyCode.Right) or touch.right then
		digitalSteer += 1
	end

	local steer: number
	local analog = false
	local stick = deadzone(pad.stickX)
	if stick ~= 0 and digitalSteer == 0 then
		steer = stick
		rampedSteer = stick
		analog = true
	else
		rampedSteer = VehicleMath.rampInput(rampedSteer, digitalSteer, Config.Driving.steerRampTime, dt)
		steer = rampedSteer
	end

	local lean = 0
	if keyDown(Enum.KeyCode.E) or touch.leanForward then
		lean += 1
	end
	if keyDown(Enum.KeyCode.Q) or touch.leanBack then
		lean -= 1
	end
	local stickLean = deadzone(pad.stickY) -- stick up (+Y) = lean forward
	if lean == 0 then
		lean = stickLean
	end

	if held then
		throttle = 0
		brake = 1
	end
	return {
		throttle = throttle,
		brake = brake,
		steer = math.clamp(steer, -1, 1),
		lean = math.clamp(lean, -1, 1),
		handbrake = keyDown(Enum.KeyCode.LeftShift) or pad.handbrake,
		analogSteer = analog,
	}
end

function InputController.init()
	UserInputService.InputBegan:Connect(function(input, processed)
		if input.UserInputType == Enum.UserInputType.Keyboard then
			lastDevice = "keyboard"
			if processed then
				return
			end
			if input.KeyCode == Enum.KeyCode.Space then
				press("jump")
				press("flail")
			elseif input.KeyCode == Enum.KeyCode.R then
				press("reset")
				press("respawn")
			elseif input.KeyCode == Enum.KeyCode.F then
				press("flip")
			end
		elseif input.UserInputType.Name:sub(1, 7) == "Gamepad" then
			lastDevice = "gamepad"
			if input.KeyCode == Enum.KeyCode.ButtonA then
				press("jump")
				press("flail")
			elseif input.KeyCode == Enum.KeyCode.ButtonX then
				press("reset")
				press("respawn")
			elseif input.KeyCode == Enum.KeyCode.ButtonY then
				press("flip")
			elseif input.KeyCode == Enum.KeyCode.ButtonB then
				pad.handbrake = true
			end
		elseif input.UserInputType == Enum.UserInputType.Touch then
			lastDevice = "touch"
		end
	end)

	UserInputService.InputEnded:Connect(function(input)
		if input.KeyCode == Enum.KeyCode.ButtonB then
			pad.handbrake = false
		elseif input.KeyCode == Enum.KeyCode.ButtonR2 then
			pad.throttle = 0
		elseif input.KeyCode == Enum.KeyCode.ButtonL2 then
			pad.brake = 0
		elseif input.KeyCode == Enum.KeyCode.Thumbstick1 then
			pad.stickX = 0
			pad.stickY = 0
		end
	end)

	UserInputService.InputChanged:Connect(function(input)
		if input.KeyCode == Enum.KeyCode.ButtonR2 then
			pad.throttle = math.clamp(input.Position.Z, 0, 1)
			lastDevice = "gamepad"
		elseif input.KeyCode == Enum.KeyCode.ButtonL2 then
			pad.brake = math.clamp(input.Position.Z, 0, 1)
			lastDevice = "gamepad"
		elseif input.KeyCode == Enum.KeyCode.Thumbstick1 then
			pad.stickX = input.Position.X
			pad.stickY = input.Position.Y
			if math.abs(input.Position.X) > DEADZONE or math.abs(input.Position.Y) > DEADZONE then
				lastDevice = "gamepad"
			end
		end
	end)

	UserInputService.GamepadDisconnected:Connect(function()
		pad.throttle, pad.brake, pad.stickX, pad.stickY, pad.handbrake = 0, 0, 0, 0, false
	end)
end

return InputController
