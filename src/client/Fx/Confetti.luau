-- Confetti: the finish-line burst (spec: Juice table > Finish; Pip's Hill beat sheet 0:28 "confetti").
-- Client-local: a short-lived anchored attachment part with a multicolour emitter, emitted once.
-- PLACEHOLDER ART: Roblox's default particle texture until the VFX pass.

local Debris = game:GetService("Debris")

local Confetti = {}

local COLORS = {
	Color3.fromRGB(255, 92, 92),
	Color3.fromRGB(255, 214, 10),
	Color3.fromRGB(80, 210, 110),
	Color3.fromRGB(86, 170, 255),
	Color3.fromRGB(255, 120, 200),
}

function Confetti.burst(position: Vector3, count: number?)
	local holder = Instance.new("Part")
	holder.Name = "Confetti"
	holder.Anchored = true
	holder.CanCollide = false
	holder.CanQuery = false
	holder.CanTouch = false
	holder.Transparency = 1
	holder.Size = Vector3.one
	holder.CFrame = CFrame.new(position)
	holder.Parent = workspace:FindFirstChild("LocalDebris") or workspace
	local total = count or 90
	for index, color in COLORS do
		local emitter = Instance.new("ParticleEmitter")
		emitter.Color = ColorSequence.new(color)
		emitter.LightEmission = 0.2
		emitter.Size = NumberSequence.new(0.5, 0.35)
		emitter.Lifetime = NumberRange.new(1.6, 2.6)
		emitter.Speed = NumberRange.new(30, 55)
		emitter.SpreadAngle = Vector2.new(60, 60)
		emitter.Acceleration = Vector3.new(0, -40, 0)
		emitter.Drag = 1.5
		emitter.RotSpeed = NumberRange.new(-360, 360)
		emitter.Rotation = NumberRange.new(0, 360)
		emitter.EmissionDirection = Enum.NormalId.Top
		emitter.Rate = 0
		emitter.Parent = holder
		emitter:Emit(math.ceil(total / #COLORS) + (if index == 1 then total % #COLORS else 0))
	end
	Debris:AddItem(holder, 4)
end

return Confetti
