-- BrawlClient: Bumper Brawl on this device (spec: Bumper Brawl; Brawl screens; Other modes' first 30
-- seconds). The server (BrawlService) runs the round and sends Round.State on every change; this shows it
-- and does the parts that must feel instant:
-- * Lobby: you drive in the foam-ball pen; the panel shows the slots filling (bots tagged BOT) and the
--   countdown ring. Countdown: you are on the arena, held (steering works, the gas does not), 3, 2, 1, BUMP!
-- * Play: the timer to 2:00, then SUDDEN DEATH to 2:30; cars left; the kill feed; name labels over every
--   car (BOT tags) and a RIVAL badge on the last driver who knocked you; the held powerup on the ACTION
--   button (or G / RB). RESET is off while you are on the arena.
-- * Bumps: your car's Touched plus last-frame velocities. When you are the one driving into the other car
--   (the same test the server uses for bots), the bump is reported (Brawl.Hit) and the thud, sparks and an
--   80 ms hit-stop play at once; the server checks it and knocks the other car. When you are knocked,
--   Brawl.Result "knock" kicks your car.
-- * Tiles flash for 3 s before they drop (WarnAt / DropAt attributes, server time) and fall here on time;
--   the server turns their collision off at DropAt. Gully the Gull flies over each powerup drop.
-- * Out: KNOCKED OUT, then WATCH (spectate the finalists), CHEER and QUEUE NEXT.
-- * Results: places, KOs, coins, the ranked bar and points change, QUEUE NEXT and LEAVE.
-- * Practice (first visit): BUMP! over a slow bot on a small disc, a 1 / 2 bar and SKIP.
-- HUB (top bar): back to Tumble Park. In ranked mid-round it asks for a second tap (leaving is a quit).
-- PLACEHOLDER ART: Gully, the shield bubble, the spring bar and the honk ring are plain parts.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Config)
local Net = require(Shared.Net)
local Place = require(Shared.Place)
local RaceMath = require(Shared.RaceMath)

local Client = script.Parent.Parent
local BrawlHud = require(Client.Ui.BrawlHud)
local TracksHud = require(Client.Ui.TracksHud)
local ExplosionFx = require(Client.Fx.ExplosionFx)

local LocalPlayer = Players.LocalPlayer
local cfg = Config.Brawl

local BrawlClient = {}

local controllers: any = nil
local state: { [string]: any }? = nil
local lastCue = -1
local rivalId: number? = nil
local watching: number? = nil
local camPosition: Vector3? = nil
local hubArmedUntil = 0
local practiceBot: number? = nil

-- Cars by owner id (players' user ids; bots are negative), refreshed a few times a second
local cars: { [number]: Model } = {}
local labels: { [Model]: BillboardGui } = {}
local lastVelocity: { [BasePart]: Vector3 } = {}
local localHitTimes: { [number]: number } = {}

-- Local visuals
local fxFolder: Folder? = nil
local tiles: { [BasePart]: { color: Color3, cf: CFrame, warned: boolean, dropped: boolean } } = {}
local powerups: { [BasePart]: CFrame } = {}
local bubbles: { [Model]: BasePart } = {}
local springs: { [Model]: BasePart } = {}
local lastWarnSound = 0

local function now(): number
	return Workspace:GetServerTimeNow()
end

local function playerGui(): Instance
	return LocalPlayer:WaitForChild("PlayerGui")
end

local function flat(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

local function folder(): Folder
	if fxFolder == nil or fxFolder.Parent == nil then
		local f = Instance.new("Folder")
		f.Name = "BrawlFx"
		f.Parent = Workspace
		fxFolder = f
	end
	return fxFolder :: Folder
end

local function fxPart(name: string, shape: Enum.PartType, color: Color3, size: Vector3): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Shape = shape
	part.Color = color
	part.Size = size
	part.Material = Enum.Material.SmoothPlastic
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Parent = folder()
	return part
end

local function myChassis(): BasePart?
	return controllers.Vehicle.getChassis()
end

local function phase(): string?
	return state and state.phase
end

local function isRanked(): boolean
	return Place.isRanked() or (state ~= nil and state.ranked == true)
end

local function brawlState(): string?
	return LocalPlayer:GetAttribute("BrawlState") :: string?
end

local function entrants(): { { [string]: any } }
	return state and state.entrants or {}
end

local function entrantName(id: number): string
	for _, e in entrants() do
		if e.id == id then
			return e.name
		end
	end
	local model = cars[id]
	if model then
		local bot = model:GetAttribute("BotName")
		if type(bot) == "string" then
			return bot
		end
	end
	local player = Players:GetPlayerByUserId(id)
	return if player then player.DisplayName else "Someone"
end

local function inRoundAlive(): boolean
	local p = phase()
	return (p == "Countdown" or p == "Play") and state ~= nil and state.entrant == true and state.out ~= true
end

---------------------------------------------------------------------------
-- Cars: the id cache, name labels, RIVAL, shield and spring visuals
---------------------------------------------------------------------------

local function vehiclesFolder(): Instance?
	return Workspace:FindFirstChild("Vehicles")
end

local function modelOf(part: Instance): (Model?, number?)
	local root = vehiclesFolder()
	if root == nil then
		return nil, nil
	end
	local model = part:FindFirstAncestorOfClass("Model")
	while model and model.Parent ~= root do
		model = model.Parent and model.Parent:FindFirstAncestorOfClass("Model") or nil
	end
	if model == nil then
		return nil, nil
	end
	local id = model:GetAttribute("OwnerUserId")
	return model, if type(id) == "number" then id else nil
end

local function makeLabel(model: Model, id: number): BillboardGui?
	local chassis = model.PrimaryPart or model:FindFirstChild("Chassis") :: BasePart?
	if chassis == nil then
		return nil
	end
	local gui = Instance.new("BillboardGui")
	gui.Name = "BrawlLabel_" .. id
	gui.Adornee = chassis
	gui.AlwaysOnTop = true
	gui.Size = UDim2.fromOffset(150, 46)
	gui.StudsOffsetWorldSpace = Vector3.new(0, 6, 0)
	gui.MaxDistance = 220
	gui.ResetOnSpawn = false
	local bot = model:GetAttribute("IsBot") == true
	local name = Instance.new("TextLabel")
	name.Name = "Name"
	name.BackgroundTransparency = 1
	name.Size = UDim2.fromScale(if bot then 0.72 else 1, 0.55)
	name.Position = UDim2.fromScale(0, 0.45)
	name.Font = Enum.Font.FredokaOne
	name.TextScaled = true
	name.TextColor3 = Color3.new(1, 1, 1)
	name.TextStrokeTransparency = 0.2
	name.Text = entrantName(id)
	name.Parent = gui
	if bot then
		local tag = Instance.new("TextLabel")
		tag.Name = "Bot"
		tag.Text = "BOT"
		tag.Font = Enum.Font.FredokaOne
		tag.TextScaled = true
		tag.TextColor3 = Color3.new(1, 1, 1)
		tag.BackgroundColor3 = Color3.fromRGB(35, 35, 45)
		tag.Size = UDim2.fromScale(0.26, 0.45)
		tag.Position = UDim2.fromScale(0.74, 0.5)
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0.3, 0)
		corner.Parent = tag
		tag.Parent = gui
	end
	local badge = Instance.new("TextLabel")
	badge.Name = "Badge"
	badge.Visible = false
	badge.Font = Enum.Font.FredokaOne
	badge.TextScaled = true
	badge.TextColor3 = Color3.new(1, 1, 1)
	badge.BackgroundColor3 = Color3.fromRGB(230, 60, 60)
	badge.AnchorPoint = Vector2.new(0.5, 0)
	badge.Position = UDim2.fromScale(0.5, 0)
	badge.Size = UDim2.fromScale(0.5, 0.42)
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.3, 0)
	corner.Parent = badge
	badge.Parent = gui
	gui.Parent = playerGui()
	return gui
end

local function setBadge(id: number, value: string?, color: Color3?)
	local model = cars[id]
	local gui = model and labels[model]
	local badge = gui and gui:FindFirstChild("Badge") :: TextLabel?
	if badge then
		badge.Visible = value ~= nil
		badge.Text = value or ""
		badge.BackgroundColor3 = color or Color3.fromRGB(230, 60, 60)
	end
end

local function refreshBadges()
	for id in cars do
		if id == practiceBot then
			setBadge(id, "BUMP! ▼", Color3.fromRGB(80, 210, 110))
		elseif id == rivalId then
			setBadge(id, "RIVAL", nil)
		else
			setBadge(id, nil)
		end
	end
end

local function refreshCars()
	local root = vehiclesFolder()
	local seen: { [Model]: boolean } = {}
	table.clear(cars)
	if root then
		for _, model in root:GetChildren() do
			local id = model:GetAttribute("OwnerUserId")
			if model:IsA("Model") and type(id) == "number" then
				cars[id] = model
				seen[model] = true
				if id ~= LocalPlayer.UserId and labels[model] == nil then
					labels[model] = makeLabel(model, id) :: BillboardGui
				end
			end
		end
	end
	for model, gui in labels do
		if not seen[model] then
			gui:Destroy()
			labels[model] = nil
		else
			local id = model:GetAttribute("OwnerUserId") :: number
			local name = gui:FindFirstChild("Name") :: TextLabel?
			if name then
				name.Text = entrantName(id)
			end
		end
	end
	for part in lastVelocity do
		if part.Parent == nil then
			lastVelocity[part] = nil
		end
	end
	refreshBadges()
end

local function carVisuals(t: number)
	for model, part in bubbles do
		if model.Parent == nil or (model:GetAttribute("BrawlShield") or 0) <= t then
			part:Destroy()
			bubbles[model] = nil
		end
	end
	for model, part in springs do
		if model.Parent == nil or (model:GetAttribute("BrawlSpring") or 0) <= t then
			part:Destroy()
			springs[model] = nil
		end
	end
	for id, model in cars do
		local chassis = model.PrimaryPart
		if chassis == nil then
			continue
		end
		local shield = model:GetAttribute("BrawlShield")
		if type(shield) == "number" and shield > t then
			local bubble = bubbles[model]
			if bubble == nil then
				local size = math.max(chassis.Size.X, chassis.Size.Z) * 1.5
				bubble =
					fxPart("Shield", Enum.PartType.Ball, Color3.fromRGB(110, 200, 255), Vector3.one * size)
				bubble.Material = Enum.Material.ForceField
				bubble.Transparency = 0.1
				bubbles[model] = bubble
				if id == LocalPlayer.UserId then
					controllers.Juice.fire("ShieldUp")
				end
			end
			-- Blink in the last second
			local left = shield - t
			bubble.Transparency = if left < 1 and math.floor(left * 8) % 2 == 0 then 0.7 else 0.1
			bubble.CFrame = CFrame.new(chassis.Position)
		end
		local spring = model:GetAttribute("BrawlSpring")
		if type(spring) == "number" and spring > t then
			local bar = springs[model]
			if bar == nil then
				bar = fxPart(
					"Spring",
					Enum.PartType.Block,
					Color3.fromRGB(120, 230, 90),
					Vector3.new(chassis.Size.X + 0.4, 0.8, 0.8)
				)
				bar.Material = Enum.Material.Neon
				springs[model] = bar
			end
			local wobble = math.sin(t * 18) * 0.15
			bar.CFrame = chassis.CFrame * CFrame.new(0, 0, -chassis.Size.Z / 2 - 0.6 - wobble)
		end
	end
end

---------------------------------------------------------------------------
-- Bumps
---------------------------------------------------------------------------

local function hitStop()
	controllers.Vehicle.freezeRender(0.08)
	controllers.Camera.freeze(0.08)
end

local function canBump(): boolean
	local where = brawlState()
	if where == "practice" then
		return practiceBot ~= nil
	end
	return where == "arena" and phase() == "Play" and inRoundAlive()
end

local function onTouched(mine: BasePart, hit: BasePart)
	if not canBump() then
		return
	end
	local model, id = modelOf(hit)
	if model == nil or id == nil or id == LocalPlayer.UserId then
		return
	end
	local other = model.PrimaryPart
	if other == nil then
		return
	end
	local clock = os.clock()
	if clock - (localHitTimes[id] or 0) < cfg.knockback.pairCooldown then
		return
	end
	local offset = flat(other.Position - mine.Position)
	if offset.Magnitude < 1e-3 then
		return
	end
	local direction = offset.Unit
	-- Velocities from the frame before the contact (the collision has already slowed both cars)
	local myVelocity = lastVelocity[mine] or mine.AssemblyLinearVelocity
	local theirVelocity = lastVelocity[other] or other.AssemblyLinearVelocity
	local own = myVelocity:Dot(direction)
	local closing = own - theirVelocity:Dot(direction)
	if own < cfg.knockback.minClosing or closing < cfg.knockback.minClosing then
		return
	end
	localHitTimes[id] = clock
	Net.send("Brawl.Hit", id, math.min(closing, 300), direction)
	controllers.Juice.fire("BrawlBump", {
		scale = math.clamp(closing / 40, 0.3, 1.5),
		point = mine.Position + direction * (mine.Size.Z / 2),
		direction = -direction,
	})
	hitStop()
end

local function watchChassis(model: Model)
	local chassis = model:WaitForChild("Chassis", 10) :: BasePart?
	if chassis == nil then
		return
	end
	chassis.Touched:Connect(function(hit)
		onTouched(chassis, hit)
	end)
end

local function onResult(result: any)
	if type(result) ~= "table" then
		return
	end
	if result.kind == "knock" and typeof(result.dv) == "Vector3" then
		local dv = result.dv :: Vector3
		controllers.Vehicle.applyKick(dv)
		controllers.Juice.fire("BrawlBump", {
			scale = math.clamp(dv.Magnitude / 45, 0.3, 1.5),
			direction = dv,
		})
		hitStop()
		if type(result.by) == "number" and result.by ~= LocalPlayer.UserId then
			rivalId = result.by
			refreshBadges()
		end
	elseif result.kind == "heal" and type(result.amount) == "number" then
		controllers.Damage.heal(result.amount)
	elseif result.kind == "hit" and type(result.power) == "number" then
		-- Confirmed: a little extra camera kick for the big ones
		if result.power >= cfg.knockback.cap * 0.8 then
			controllers.Camera.shake(0.25, 0.12)
		end
	end
end

---------------------------------------------------------------------------
-- Tiles and powerups
---------------------------------------------------------------------------

local function addTile(part: Instance)
	if part:IsA("BasePart") and tiles[part] == nil then
		tiles[part] = { color = part.Color, cf = part.CFrame, warned = false, dropped = false }
	end
end

local function tileSounds(part: BasePart, kind: string)
	local chassis = myChassis()
	if chassis == nil then
		return
	end
	local distance = (chassis.Position - part.Position).Magnitude
	if kind == "warn" then
		if distance < 45 and os.clock() - lastWarnSound > 0.8 then
			lastWarnSound = os.clock()
			controllers.Juice.fire("TileWarn", { volume = 0.6 })
		end
	elseif distance < 35 then
		controllers.Juice.fire("TileDrop", { scale = 1 - distance / 35, volume = 0.7 })
	end
end

local function stepTiles(t: number)
	local warnColor = Config.color3(cfg.warnColor)
	for part, info in tiles do
		if part.Parent == nil then
			tiles[part] = nil
			continue
		end
		local dropAt = part:GetAttribute("DropAt")
		local warnAt = part:GetAttribute("WarnAt")
		if type(dropAt) == "number" and t >= dropAt then
			local fall = t - dropAt
			if not info.dropped then
				info.dropped = true
				part.Color = info.color
				if fall < 0.5 then
					tileSounds(part, "drop")
				end
			end
			if fall < 2 then
				-- Falls away, tipping a little, then the server hides it
				local tip = math.rad(fall * 25)
				part.CFrame = info.cf
					* CFrame.new(0, -0.5 * 60 * fall * fall, 0)
					* CFrame.Angles(tip * 0.6, 0, tip)
				part.LocalTransparencyModifier = math.clamp(fall / 2, 0, 0.8)
			end
		elseif type(warnAt) == "number" and t >= warnAt then
			if not info.warned then
				info.warned = true
				tileSounds(part, "warn")
			end
			-- Flash faster as the drop gets close
			local left = if type(dropAt) == "number" then dropAt - t else cfg.warnTime
			local rate = if left < 1 then 12 else 6
			local on = math.floor(t * rate) % 2 == 0
			part.Color = if on then warnColor else info.color
			local shake = if left < 1 then 0.12 else 0.05
			part.CFrame = info.cf * CFrame.new(math.sin(t * 60) * shake, 0, math.cos(t * 53) * shake)
		end
	end
end

local function addPowerup(part: Instance)
	if part:IsA("BasePart") and powerups[part] == nil then
		powerups[part] = part.CFrame
	end
end

local function stepPowerups(t: number)
	for part, home in powerups do
		if part.Parent == nil then
			powerups[part] = nil
			continue
		end
		local landAt = part:GetAttribute("LandAt")
		local spin = CFrame.Angles(0, t * 2.5, 0)
		if type(landAt) == "number" and t < landAt then
			local k = math.clamp((landAt - t) / cfg.powerups.dropTime, 0, 1)
			part.CFrame = home * CFrame.new(0, 40 * k * k, 0) * spin
		else
			part.CFrame = home * CFrame.new(0, math.sin(t * 3) * 0.5, 0) * spin
		end
	end
end

-- Gully the Gull flies over the drop (PLACEHOLDER ART: a ball body, two flat wings and a beak)
local function gully(at: Vector3)
	local body =
		fxPart("Gully", Enum.PartType.Ball, Color3.fromRGB(250, 250, 250), Vector3.new(2.6, 2.2, 4.2))
	local wings = fxPart("Wings", Enum.PartType.Block, Color3.fromRGB(225, 230, 240), Vector3.new(9, 0.3, 2))
	local beak = fxPart("Beak", Enum.PartType.Block, Color3.fromRGB(255, 160, 40), Vector3.new(0.7, 0.6, 1.4))
	local from = at + Vector3.new(-18, 40, -10)
	local to = at + Vector3.new(80, 46, 30)
	local duration = 2.2
	local start = os.clock()
	local connection: RBXScriptConnection? = nil
	connection = RunService.RenderStepped:Connect(function()
		local k = (os.clock() - start) / duration
		if k >= 1 then
			body:Destroy()
			wings:Destroy()
			beak:Destroy()
			if connection then
				connection:Disconnect()
			end
			return
		end
		local position = from:Lerp(to, k)
		local cf = CFrame.lookAt(position, to)
		body.CFrame = cf
		wings.CFrame = cf * CFrame.Angles(0, 0, math.sin(os.clock() * 14) * 0.5)
		beak.CFrame = cf * CFrame.new(0, 0, -2.5)
	end)
end

-- The Honk Wave: a ring that grows to the push radius (PLACEHOLDER ART)
local function honkRing(at: Vector3)
	local ring = fxPart("Honk", Enum.PartType.Cylinder, Color3.fromRGB(255, 120, 200), Vector3.new(0.4, 1, 1))
	ring.Material = Enum.Material.Neon
	local start = os.clock()
	local connection: RBXScriptConnection? = nil
	connection = RunService.RenderStepped:Connect(function()
		local k = (os.clock() - start) / 0.4
		if k >= 1 then
			ring:Destroy()
			if connection then
				connection:Disconnect()
			end
			return
		end
		local d = cfg.honk.radius * 2 * k
		ring.Size = Vector3.new(0.4, d, d)
		ring.Transparency = k
		ring.CFrame = CFrame.new(at) * CFrame.Angles(0, 0, math.rad(90))
	end)
	local chassis = myChassis()
	if chassis and (chassis.Position - at).Magnitude < cfg.honk.radius + 8 then
		controllers.Juice.fire("HonkWave")
	end
end

---------------------------------------------------------------------------
-- Spectating
---------------------------------------------------------------------------

local function finalists(): { number }
	local list = {}
	for _, e in entrants() do
		if not e.out and e.id ~= LocalPlayer.UserId then
			table.insert(list, e.id)
		end
	end
	return list
end

local showOut: () -> ()

local function stopWatching()
	if watching ~= nil then
		watching = nil
		camPosition = nil
		controllers.Camera.setOverride(nil)
	end
end

local function watchNext()
	local list = finalists()
	if #list == 0 then
		stopWatching()
		return
	end
	local index = if watching then table.find(list, watching) else nil
	watching = list[((index or 0) % #list) + 1]
	controllers.Camera.setOverride(function(dt: number)
		local model = watching and cars[watching]
		local target = model and model.PrimaryPart
		local camera = Workspace.CurrentCamera
		if target == nil then
			return camera.CFrame, camera.FieldOfView
		end
		local velocity = flat(target.AssemblyLinearVelocity)
		local look = if velocity.Magnitude > 4 then velocity.Unit else flat(target.CFrame.LookVector).Unit
		local desired = target.Position - look * 26 + Vector3.new(0, 13, 0)
		camPosition = if camPosition then camPosition:Lerp(desired, math.clamp(dt * 4, 0, 1)) else desired
		return CFrame.lookAt(camPosition :: Vector3, target.Position + Vector3.new(0, 2, 0)), 70
	end)
	showOut()
end

function showOut()
	if not BrawlHud.isOut() and watching == nil and state == nil then
		return
	end
	local left = state and state.left or 0
	BrawlHud.eliminated(playerGui(), {
		line = string.format("KNOCKED OUT! %d still fighting", left),
		watching = if watching then entrantName(watching) else nil,
		onWatch = watchNext,
		onCheer = function()
			if watching then
				Net.send("Cheer", watching)
			end
		end,
		onQueue = function()
			stopWatching()
			BrawlHud.eliminated(playerGui(), nil)
			TracksHud.toast("You're in the next round. Drive around the pen!", 3)
		end,
	})
end

local function onCheer(fromId: any, targetId: any)
	if type(fromId) ~= "number" or type(targetId) ~= "number" then
		return
	end
	if targetId == LocalPlayer.UserId then
		TracksHud.toast(string.format("%s is cheering for you!", entrantName(fromId)), 2)
		controllers.Juice.fire("Cheer")
	elseif targetId == watching then
		controllers.Juice.fire("Cheer", { volume = 0.5 })
	end
	setBadge(targetId, "CHEER!", Color3.fromRGB(255, 205, 40))
	task.delay(1.2, refreshBadges)
end

---------------------------------------------------------------------------
-- Round state
---------------------------------------------------------------------------

local function timerLine(s: { [string]: any }, t: number): (string, boolean)
	local goAt = s.goAt or t
	local elapsed = t - goAt
	local length = s.roundLength or cfg.roundLength
	if s.suddenDeath or elapsed >= length then
		local left = math.max(0, (s.maxLength or cfg.maxLength) - elapsed)
		return string.format("SUDDEN DEATH %d", math.ceil(left)), true
	end
	local left = math.max(0, math.ceil(length - elapsed))
	return string.format("%d:%02d", left // 60, left % 60), false
end

local function lobbySlots(s: { [string]: any }): { BrawlHud.Slot }
	local slots = {}
	if type(s.entrants) == "table" then
		for _, e in s.entrants do
			table.insert(slots, { name = e.name, bot = e.bot == true })
		end
	elseif type(s.waiting) == "table" then
		for _, name in s.waiting do
			table.insert(slots, { name = name, bot = false })
		end
	end
	return slots
end

local function setReset()
	local allowed = brawlState() ~= "arena"
	controllers.Vehicle.setResetAllowed(allowed)
	controllers.Hud.setResetAllowed(allowed)
end

local function refresh()
	local s = state
	local gui = playerGui()
	if s == nil or brawlState() == "practice" then
		BrawlHud.lobby(gui, nil)
		BrawlHud.round(gui, nil)
		controllers.Input.setHold(false)
		return
	end
	local t = now()
	local title = if isRanked() then "RANKED BRAWL" else "BUMPER BRAWL"
	local max = s.max or cfg.maxPlayers
	if s.phase == "Lobby" or s.phase == "Requeue" then
		BrawlHud.round(gui, nil)
		local seconds = if s.endsAt then s.endsAt - t else nil
		BrawlHud.lobby(gui, {
			title = title,
			line = if seconds
				then string.format("Next round in %d", math.max(0, math.ceil(seconds)))
				else "Waiting for drivers...",
			seconds = seconds,
			slots = lobbySlots(s),
			max = max,
		})
		controllers.Input.setHold(false)
	elseif s.phase == "Countdown" then
		BrawlHud.round(gui, nil)
		BrawlHud.lobby(gui, {
			title = title .. (if s.arena then ": " .. string.upper(s.arena.name) else ""),
			line = if s.entrant
				then "Bump them all into the foam!"
				else "Round starting. You're in the next one!",
			seconds = if s.endsAt then s.endsAt - t else nil,
			slots = lobbySlots(s),
			max = max,
		})
		controllers.Input.setHold(s.entrant == true)
	elseif s.phase == "Play" then
		controllers.Input.setHold(false)
		if s.entrant then
			BrawlHud.lobby(gui, nil)
			local line, sudden = timerLine(s, t)
			BrawlHud.round(gui, line, s.left, sudden)
		else
			BrawlHud.round(gui, nil)
			BrawlHud.lobby(gui, {
				title = title,
				line = string.format("Round on: %d left. You're in the next one!", s.left or 0),
				seconds = nil,
				slots = lobbySlots(s),
				max = max,
			})
		end
	else
		controllers.Input.setHold(false)
		BrawlHud.lobby(gui, nil)
		BrawlHud.round(gui, nil)
	end
end

local function onState(s: any)
	if type(s) ~= "table" or s.kind ~= "brawl" then
		return
	end
	if s.phase == "Left" then
		state = nil
		stopWatching()
		BrawlHud.eliminated(playerGui(), nil)
		refresh()
		return
	end
	local previous = phase()
	local wasOut = state ~= nil and state.out == true
	state = s
	if s.phase == "Countdown" and previous ~= "Countdown" then
		lastCue = -1
		rivalId = nil
		BrawlHud.hideResults()
		BrawlHud.eliminated(playerGui(), nil)
		controllers.Shop.close()
	end
	if s.phase == "Play" and previous ~= "Play" and s.entrant then
		TracksHud.showCue("BUMP!", 1)
		controllers.Juice.fire("Finish", { volume = 0.4 })
	end
	if s.phase ~= "Play" then
		stopWatching()
		if s.phase ~= "Countdown" then
			BrawlHud.eliminated(playerGui(), nil)
		end
	elseif s.out and not wasOut then
		-- Just knocked out: the out panel (the ko event plays the splash)
		task.delay(1.2, function()
			if state and state.phase == "Play" and state.out then
				showOut()
			end
		end)
	elseif BrawlHud.isOut() then
		if watching and not table.find(finalists(), watching) then
			watchNext()
		else
			showOut()
		end
	end
	refresh()
	refreshCars()
end

local function onEvent(e: any)
	if type(e) ~= "table" then
		return
	end
	local me = LocalPlayer.UserId
	local kind = e.kind
	if kind == "ko" then
		local at = e.at
		if typeof(at) == "Vector3" then
			ExplosionFx.pop(at)
		end
		local victim = entrantName(e.id)
		local line
		if e.by then
			line = string.format("%s bumped %s out!", entrantName(e.by), victim)
		elseif e.how == "exploded" then
			line = string.format("%s blew up!", victim)
		else
			line = string.format("%s fell in the foam!", victim)
		end
		BrawlHud.feed(line, e.id == me or e.by == me)
		if e.by == me and e.id ~= me then
			TracksHud.showCue("KO!", 1.2)
			controllers.Juice.fire("KO")
		elseif e.id == me then
			controllers.Juice.fire("KO", { scale = 0.6 })
		end
		if e.id == rivalId then
			rivalId = nil
			refreshBadges()
		end
	elseif kind == "held" then
		BrawlHud.powerup(playerGui(), e.powerup, BrawlClient.usePowerup)
		controllers.Juice.fire("PowerupGrab")
		local info = BrawlHud.POWERUPS[e.powerup]
		if info then
			TracksHud.toast(string.format("%s! %s. Tap ACTION (G) to use it.", info.label, info.line), 2.5)
		end
	elseif kind == "used" then
		if e.id == me then
			BrawlHud.powerup(playerGui(), nil, BrawlClient.usePowerup)
		end
		if e.powerup == "honk" and typeof(e.at) == "Vector3" then
			honkRing(e.at)
		end
	elseif kind == "gully" and typeof(e.at) == "Vector3" then
		gully(e.at)
	elseif kind == "shieldBlock" then
		setBadge(e.id, "BLOCKED!", Color3.fromRGB(110, 200, 255))
		task.delay(0.8, refreshBadges)
	elseif kind == "suddenDeath" then
		TracksHud.showCue("SUDDEN DEATH!", 2)
		controllers.Juice.fire("TileWarn")
	elseif kind == "practice" then
		practiceBot = e.bot
		BrawlHud.practice(playerGui(), e.step, e.of, function()
			Net.send("Brawl.Practice")
		end)
		TracksHud.showCue("BUMP!", 1.5)
		refreshCars()
	elseif kind == "practiceCoins" then
		TracksHud.showCue(string.format("+%d", e.coins or 0), 1.5)
		controllers.Juice.fire("Coin")
	elseif kind == "practiceDone" then
		practiceBot = nil
		BrawlHud.practice(playerGui(), nil)
		if not e.skipped then
			TracksHud.showCue("NICE! NOW FOR REAL", 2)
			controllers.Juice.fire("StarEarned")
		end
		refreshBadges()
	elseif kind == "season" then
		local items = type(e.items) == "table" and #e.items or 0
		TracksHud.toast(
			string.format(
				"Ranked season %d! %d reward%s added to your garage%s.",
				e.season or 0,
				items,
				if items == 1 then "" else "s",
				if (e.coins or 0) > 0 then string.format(", plus %d coins", e.coins) else ""
			),
			5
		)
	end
end

local function onRound(result: any)
	if type(result) ~= "table" or type(result.places) ~= "table" then
		return
	end
	stopWatching()
	BrawlHud.eliminated(playerGui(), nil)
	BrawlHud.powerup(playerGui(), nil, BrawlClient.usePowerup)
	local me = LocalPlayer.UserId
	local rows = {}
	for _, p in result.places do
		table.insert(
			rows,
			{ place = p.place, name = p.name, bot = p.bot == true, kos = p.kos or 0, me = p.id == me }
		)
	end
	local mine = result.mine or {}
	local title = if mine.place == 1
		then "YOU WON!"
		else string.format("%s PLACE!", string.upper(RaceMath.ordinal(mine.place or 0)))
	if mine.place == 1 then
		controllers.Juice.fire("StarEarned")
	end
	local coinsLine
	if mine.idle then
		coinsLine = "No coins this time: you have to drive to earn"
	else
		coinsLine = string.format(
			"+%d coins  ·  %d KO%s",
			mine.coins or 0,
			mine.kos or 0,
			if mine.kos == 1 then "" else "s"
		)
		if mine.capped then
			coinsLine ..= " (today's Brawl coin limit)"
		end
	end
	local rankedView = nil
	local r = mine.ranked
	if type(r) == "table" then
		local note = nil
		if r.botWon then
			note = "A bot won, so nobody gets points this round"
		elseif (r.placementsLeft or 0) > 0 then
			note = string.format("Placement rounds left: %d (you can't lose points yet)", r.placementsLeft)
		end
		rankedView = {
			tierName = r.tierName or "",
			progress = r.progress or 0,
			points = r.points or 0,
			delta = r.delta or 0,
			rankUp = r.rankUp == true,
			note = note,
		}
		if r.rankUp then
			task.delay(0.6, function()
				TracksHud.showCue("RANK UP! " .. string.upper(r.tierName or ""), 2.5)
				controllers.Juice.fire("RankUp")
			end)
		end
	end
	BrawlHud.showResults(playerGui(), {
		title = title,
		arena = result.arena or "",
		rows = rows,
		coinsLine = coinsLine,
		ranked = rankedView,
		seconds = result.seconds or cfg.results,
		onQueue = function()
			Net.send("Brawl.Queue")
		end,
		onLeave = BrawlClient.leave,
	})
end

---------------------------------------------------------------------------
-- Public
---------------------------------------------------------------------------

function BrawlClient.usePowerup()
	if phase() == "Play" and inRoundAlive() then
		Net.send("Brawl.Powerup")
	end
end

function BrawlClient.leave()
	Net.send("Brawl.Leave")
end

-- HUB in the top bar: back to Tumble Park. Leaving a ranked round mid-way is a quit (-15), so that
-- asks for a second tap within 4 s.
function BrawlClient.goHome()
	if isRanked() and inRoundAlive() then
		local clock = os.clock()
		if clock > hubArmedUntil then
			hubArmedUntil = clock + 4
			TracksHud.toast(
				string.format(
					"Leaving now counts as a quit (%d points). Tap HUB again to leave.",
					cfg.ranked.afkOrQuit
				),
				4
			)
			return
		end
	end
	hubArmedUntil = 0
	BrawlClient.leave()
end

function BrawlClient.isOut(): boolean
	return state ~= nil and state.out == true
end

function BrawlClient.init(all)
	controllers = all
end

function BrawlClient.start()
	Net.listen("Round.State", onState)
	Net.listen("Brawl.Result", onResult)
	Net.listen("Brawl.Event", onEvent)
	Net.listen("Brawl.Round", onRound)
	Net.listen("Cheer", onCheer)
	-- Under the foam pit counts as off the map (the server calls the KO well before this)
	controllers.Vehicle.setKillY(cfg.origin[2] - cfg.pitDepth - 20)
	controllers.Vehicle.Spawned:Connect(function(model: Model)
		task.spawn(watchChassis, model)
	end)
	local current = myChassis()
	if current and current.Parent then
		task.spawn(watchChassis, current.Parent :: Model)
	end
	LocalPlayer:GetAttributeChangedSignal("BrawlState"):Connect(function()
		setReset()
		if brawlState() ~= "practice" then
			practiceBot = nil
			BrawlHud.practice(playerGui(), nil)
		end
		if brawlState() ~= "arena" then
			BrawlHud.powerup(playerGui(), nil, BrawlClient.usePowerup)
		end
		refresh()
	end)
	setReset()
	for _, part in CollectionService:GetTagged("BrawlTile") do
		addTile(part)
	end
	CollectionService:GetInstanceAddedSignal("BrawlTile"):Connect(addTile)
	for _, part in CollectionService:GetTagged("BrawlPowerup") do
		addPowerup(part)
	end
	CollectionService:GetInstanceAddedSignal("BrawlPowerup"):Connect(addPowerup)

	local clock, carClock = 0, 0
	RunService.Heartbeat:Connect(function(dt)
		if controllers.Input.consume("action") then
			BrawlClient.usePowerup()
		end
		-- Last-frame velocities for the bump test
		for _, model in cars do
			local chassis = model.PrimaryPart
			if chassis then
				lastVelocity[chassis] = chassis.AssemblyLinearVelocity
			end
		end
		clock += dt
		carClock += dt
		if carClock >= 0.5 then
			carClock = 0
			refreshCars()
		end
		if clock >= 0.2 then
			clock = 0
			local p = phase()
			if p == "Lobby" or p == "Requeue" or p == "Play" or p == "Countdown" then
				refresh()
			end
		end
		local s = state
		if s and s.phase == "Countdown" and s.endsAt and s.entrant then
			local left = math.ceil(s.endsAt - now())
			if left ~= lastCue and left >= 1 and left <= 3 then
				lastCue = left
				TracksHud.showCue(tostring(left), 0.9)
				controllers.Juice.fire("Coin", { pitch = 0.8, volume = 0.5 })
			end
		end
	end)
	RunService.RenderStepped:Connect(function()
		local t = now()
		stepTiles(t)
		stepPowerups(t)
		carVisuals(t)
	end)
end

return BrawlClient
