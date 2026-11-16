-- EmoteClient: the emote wheel while driving (spec: Rider > emote wheel slots; Rider Pass: slots 5 and 6).
-- * EMOTE in the MENU (B on a keyboard, d-pad up on a gamepad) opens a ring of your 4 slots
--   (6 with the Rider Pass). Tap one to play it, tap the middle to close. On a keyboard, 1 to 6 pick a
--   slot while the ring is open. An empty slot opens the garage's RIDER tab to fill it.
-- * Your rider plays it at once on this device; the server checks it is on your wheel and passes it to
--   everyone else, whose devices play it on your rider (Rider.Emote, one every 2 s).
-- * Only while seated in a car, never in the builder. Looks only: the car drives the same.
-- PLACEHOLDER ART: the ring is plain round buttons with the emote's word.

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Catalog = require(Shared.Catalog)
local Config = require(Shared.Config)
local Emotes = require(Shared.Emotes)
local TracksHud = require(script.Parent.Parent.Ui.TracksHud)
local Net = require(Shared.Net)

local LocalPlayer = Players.LocalPlayer

local EmoteClient = {}

local FONT = Enum.Font.FredokaOne
local INK = Color3.fromRGB(35, 35, 45)
local GAP = 2.1 -- seconds between emotes (the remote allows one every 2 s)
local KEYS = {
	[Enum.KeyCode.One] = 1,
	[Enum.KeyCode.Two] = 2,
	[Enum.KeyCode.Three] = 3,
	[Enum.KeyCode.Four] = 4,
	[Enum.KeyCode.Five] = 5,
	[Enum.KeyCode.Six] = 6,
}

local controllers: any = nil
local button: TextButton? = nil
local ring: Frame? = nil
local lastPlay = -math.huge

local function wheel(): { string }
	local profile = controllers.Profile.get()
	local rider = profile and profile.rider
	if rider and rider.emotes then
		return rider.emotes
	end
	return table.clone(Emotes.DEFAULT)
end

local function canEmote(): boolean
	if controllers.Vehicle.getChassis() == nil or controllers.Ragdoll.isRagdolled() then
		return false
	end
	if controllers.Builder and controllers.Builder.isBuilding() then
		return false
	end
	return true
end

local function corner(parent: Instance)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0.5, 0)
	c.Parent = parent
	local s = Instance.new("UIStroke")
	s.Thickness = 2
	s.Color = INK
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	s.Parent = parent
end

function EmoteClient.close()
	if ring then
		ring:Destroy()
		ring = nil
	end
	if
		GuiService.SelectedObject
		and button
		and GuiService.SelectedObject:IsDescendantOf(button.Parent :: Instance)
	then
		GuiService.SelectedObject = nil
	end
end

function EmoteClient.isOpen(): boolean
	return ring ~= nil
end

function EmoteClient.play(id: string): boolean
	local t = os.clock()
	if id == "" or Emotes.defs[id] == nil or t - lastPlay < GAP or not canEmote() then
		return false
	end
	if not controllers.Ragdoll.playEmote(LocalPlayer.UserId, id) then
		return false
	end
	lastPlay = t
	Net.send("Rider.Emote", id)
	return true
end

local function pick(slot: number)
	local id = wheel()[slot]
	EmoteClient.close()
	if id == nil then
		return
	end
	if id == "" then
		controllers.Shop.open("garage", "rider")
		return
	end
	EmoteClient.play(id)
end

function EmoteClient.open()
	if ring or not canEmote() then
		return
	end
	local gui = controllers.Hud.getGui()
	if gui == nil then
		return
	end
	local slots = wheel()
	local frame = Instance.new("Frame")
	frame.Name = "EmoteWheel"
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.Position = UDim2.fromScale(0.5, 0.45)
	frame.SizeConstraint = Enum.SizeConstraint.RelativeYY
	frame.Size = UDim2.fromScale(0.62, 0.62)
	frame.BackgroundTransparency = 1
	frame.ZIndex = 5
	frame.Parent = gui
	local middle = Instance.new("TextButton")
	middle.Name = "Close"
	middle.AnchorPoint = Vector2.new(0.5, 0.5)
	middle.Position = UDim2.fromScale(0.5, 0.5)
	middle.Size = UDim2.fromScale(0.24, 0.24)
	middle.BackgroundColor3 = Color3.fromRGB(240, 240, 245)
	middle.Font = FONT
	middle.TextScaled = true
	middle.Text = "X"
	middle.TextColor3 = INK
	middle.ZIndex = 6
	corner(middle)
	middle.Parent = frame
	middle.Activated:Connect(EmoteClient.close)
	local first: GuiObject? = nil
	for i, id in slots do
		local angle = -math.pi / 2 + (i - 1) * (2 * math.pi / #slots)
		local b = Instance.new("TextButton")
		b.Name = "Slot" .. i
		b.AnchorPoint = Vector2.new(0.5, 0.5)
		b.Position = UDim2.fromScale(0.5 + math.cos(angle) * 0.36, 0.5 + math.sin(angle) * 0.36)
		b.Size = UDim2.fromScale(0.27, 0.27)
		b.BackgroundColor3 = if id == "" then Color3.fromRGB(200, 200, 210) else Color3.fromRGB(255, 205, 40)
		b.Font = FONT
		b.TextScaled = true
		b.TextColor3 = INK
		b.ZIndex = 6
		local def = Emotes.defs[id]
		local item = Catalog.byId[id]
		b.Text = if def then def.label elseif id == "" then "+" else (item and item.name or "?")
		local pad = Instance.new("UIPadding")
		pad.PaddingTop = UDim.new(0.22, 0)
		pad.PaddingBottom = UDim.new(0.22, 0)
		pad.PaddingLeft = UDim.new(0.1, 0)
		pad.PaddingRight = UDim.new(0.1, 0)
		pad.Parent = b
		local size = Instance.new("UISizeConstraint")
		size.MinSize = Vector2.new(Config.UI.minTapTarget, Config.UI.minTapTarget)
		size.Parent = b
		corner(b)
		b.Parent = frame
		b.Activated:Connect(function()
			pick(i)
		end)
		first = first or b
	end
	ring = frame
	if controllers.Input.lastDevice() == "gamepad" and first then
		GuiService.SelectedObject = first
	end
end

function EmoteClient.toggle()
	if ring then
		EmoteClient.close()
	else
		EmoteClient.open()
	end
end

function EmoteClient.init(all)
	controllers = all
end

function EmoteClient.start()
	Net.listen("Rider.Emote", function(userId: number, id: string)
		if type(userId) == "number" and type(id) == "string" and userId ~= LocalPlayer.UserId then
			controllers.Ragdoll.playEmote(userId, id)
		end
	end)
	UserInputService.InputBegan:Connect(function(input, processed)
		if input.KeyCode == Enum.KeyCode.DPadUp then
			EmoteClient.toggle()
			return
		end
		if processed or input.UserInputType ~= Enum.UserInputType.Keyboard then
			return
		end
		if input.KeyCode == Enum.KeyCode.B then
			EmoteClient.toggle()
		elseif ring and KEYS[input.KeyCode] then
			local slot = KEYS[input.KeyCode]
			if slot <= #wheel() then
				pick(slot)
			end
		end
	end)
	-- The item lives in the HUD's MENU (calm pass); it shows only while you could emote
	local clock = 0
	RunService.Heartbeat:Connect(function(dt)
		clock += dt
		if clock < 0.25 then
			return
		end
		clock = 0
		if button == nil and TracksHud.hasMenu() then
			button = TracksHud.addMenuItem("Emote", "EMOTE", 8, EmoteClient.toggle)
		end
		local can = canEmote()
		if button then
			button.Visible = can
		end
		if ring and not can then
			EmoteClient.close()
		end
	end)
end

return EmoteClient
