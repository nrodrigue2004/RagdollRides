-- LookFx: trail cosmetics on every car (spec: Coin sinks > Wheel or crash trail). The server puts the
-- equipped trail ids on the car model (Shared/Looks: Trail, and Trail2 for VIP's extra trail slot);
-- each client draws them as Roblox Trails behind the rear wheels (Trail2 behind the front wheels).
-- Looks only; the low graphics preset and Reduced motion keep them shorter.
-- PLACEHOLDER ART: plain colour trails (the Rainbow trail fades through colours) until the VFX pass.

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Catalog = require(Shared.Catalog)
local Config = require(Shared.Config)

local LookFx = {}

local RAINBOW = ColorSequence.new({
	ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 90, 90)),
	ColorSequenceKeypoint.new(0.25, Color3.fromRGB(255, 200, 60)),
	ColorSequenceKeypoint.new(0.5, Color3.fromRGB(90, 220, 110)),
	ColorSequenceKeypoint.new(0.75, Color3.fromRGB(80, 160, 255)),
	ColorSequenceKeypoint.new(1, Color3.fromRGB(190, 110, 255)),
})

local function clear(chassis: BasePart, tag: string)
	for _, child in chassis:GetChildren() do
		if child:GetAttribute("LookTrail") == tag then
			child:Destroy()
		end
	end
end

local function addTrail(chassis: BasePart, tag: string, itemId: string?, mounts: { string })
	clear(chassis, tag)
	local item = itemId and Catalog.byId[itemId]
	if item == nil or item.kind ~= "trail" then
		return
	end
	local color = if item.color then Config.color3(item.color) else Color3.new(1, 1, 1)
	for _, mountName in mounts do
		local mount = chassis:FindFirstChild(mountName)
		if mount and mount:IsA("Attachment") then
			local top = Instance.new("Attachment")
			top.Position = mount.Position + Vector3.new(0, 0.5, 0.6)
			top:SetAttribute("LookTrail", tag)
			top.Parent = chassis
			local bottom = Instance.new("Attachment")
			bottom.Position = mount.Position + Vector3.new(0, -0.3, 0.6)
			bottom:SetAttribute("LookTrail", tag)
			bottom.Parent = chassis
			local trail = Instance.new("Trail")
			trail.Attachment0 = top
			trail.Attachment1 = bottom
			trail.Color = if item.id == "trail_rainbow" then RAINBOW else ColorSequence.new(color)
			trail.Transparency = NumberSequence.new(0.2, 1)
			trail.Lifetime = 0.5
			trail.MinLength = 0.2
			trail.FaceCamera = true
			trail.LightEmission = if item.rarity == "legendary" or item.rarity == "epic" then 0.6 else 0
			trail:SetAttribute("LookTrail", tag)
			trail.Parent = chassis
		end
	end
end

local function watch(model: Instance)
	if not model:IsA("Model") then
		return
	end
	local chassis = model:WaitForChild("Chassis", 10)
	if chassis == nil or not chassis:IsA("BasePart") then
		return
	end
	local function refresh()
		addTrail(chassis, "1", model:GetAttribute("Trail"), { "Mount_RL", "Mount_RR" })
		addTrail(chassis, "2", model:GetAttribute("Trail2"), { "Mount_FL", "Mount_FR" })
	end
	-- Wheel mounts arrive with the car (streaming); give them a moment
	task.delay(0.5, refresh)
	model:GetAttributeChangedSignal("Trail"):Connect(refresh)
	model:GetAttributeChangedSignal("Trail2"):Connect(refresh)
end

function LookFx.start()
	local vehicles = workspace:WaitForChild("Vehicles")
	vehicles.ChildAdded:Connect(function(model)
		task.spawn(watch, model)
	end)
	for _, model in vehicles:GetChildren() do
		task.spawn(watch, model)
	end
end

return LookFx
