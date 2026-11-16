-- HubHud: the hub's screens (spec: Hub and menus > Hub, Mode card detail, Party queue, Leaderboards).
-- * Mode picker: 3 big mode cards (Tracks, Bumper Brawl, Highway Havoc) with live player counts and
--   sub-choice chips (Free Run / Quick Race, Casual / Ranked, Co-op / Versus); PLAY is one tap. A
--   locked card shows a silhouette and when it opens; the last mode played glows. A PARTY strip under
--   the cards. "DRIVE AROUND" closes it; MODES (top centre in the hub) opens it again.
-- * Party panel: friends in this server with INVITE, your party with LEAVE PARTY. Invite card: a
--   friend's invite with JOIN and NO (names only, no text).
-- * Leaderboard panel: Friends / Weekly / All-time tabs, the top 10, your row pinned underneath.
-- Text is ours only, apart from Roblox display names. PLACEHOLDER ART: flat cards and text glyphs.

local TweenService = game:GetService("TweenService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Config)

local HubHud = {}

local FONT = Enum.Font.FredokaOne
local INK = Color3.fromRGB(35, 35, 45)
local WHITE = Color3.fromRGB(255, 255, 255)
local GOLD = Color3.fromRGB(255, 205, 40)
local GREEN = Color3.fromRGB(80, 210, 110)
local BLUE = Color3.fromRGB(86, 170, 255)
local GREY = Color3.fromRGB(110, 110, 125)
local PANEL = Color3.fromRGB(255, 250, 240)
local SILHOUETTE = Color3.fromRGB(70, 70, 85)
local MIN = Config.UI.minTapTarget

local gui: ScreenGui? = nil
local overlays: { [string]: GuiObject } = {}
local glowTween: Tween? = nil

local function corner(parent: Instance, radius: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(radius, 0)
	c.Parent = parent
end

local function stroke(parent: Instance, thickness: number?, color: Color3?)
	local s = Instance.new("UIStroke")
	s.Thickness = thickness or 2
	s.Color = color or INK
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	s.Parent = parent
	return s
end

local function text(parent: Instance, name: string, value: string, color: Color3?): TextLabel
	local label = Instance.new("TextLabel")
	label.Name = name
	label.BackgroundTransparency = 1
	label.Font = FONT
	label.TextScaled = true
	label.Text = value
	label.TextColor3 = color or INK
	label.Parent = parent
	return label
end

local function button(parent: Instance, name: string, label: string, color: Color3): TextButton
	local b = Instance.new("TextButton")
	b.Name = name
	b.Text = label
	b.Font = FONT
	b.TextScaled = true
	b.TextColor3 = INK
	b.BackgroundColor3 = color
	b.AutoButtonColor = true
	local padding = Instance.new("UIPadding")
	padding.PaddingTop = UDim.new(0.18, 0)
	padding.PaddingBottom = UDim.new(0.18, 0)
	padding.PaddingLeft = UDim.new(0.06, 0)
	padding.PaddingRight = UDim.new(0.06, 0)
	padding.Parent = b
	corner(b, 0.3)
	stroke(b, 2)
	local min = Instance.new("UISizeConstraint")
	min.MinSize = Vector2.new(MIN, MIN * 0.75)
	min.Parent = b
	b.Parent = parent
	return b
end

local function ensureGui(parent: Instance): ScreenGui
	if gui == nil then
		local g = Instance.new("ScreenGui")
		g.Name = "Hub"
		g.ResetOnSpawn = false
		g.DisplayOrder = 19
		g.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
		g.Parent = parent
		gui = g
	end
	return gui :: ScreenGui
end

local function closeOverlay(name: string)
	local o = overlays[name]
	if o then
		o:Destroy()
		overlays[name] = nil
	end
	if name == "modes" and glowTween then
		glowTween:Cancel()
		glowTween = nil
	end
end
HubHud.close = closeOverlay

function HubHud.isOpen(name: string): boolean
	return overlays[name] ~= nil
end

-- A dimmed full-screen panel with a title and a close button
local function panel(
	parent: Instance,
	name: string,
	title: string,
	closeLabel: string,
	onClose: () -> ()
): Frame
	closeOverlay(name)
	local g = ensureGui(parent)
	local shade = Instance.new("Frame")
	shade.Name = name
	shade.BackgroundColor3 = Color3.new(0, 0, 0)
	shade.BackgroundTransparency = 0.45
	shade.Size = UDim2.fromScale(1, 1)
	shade.Active = true
	shade.Parent = g
	overlays[name] = shade
	local p = Instance.new("Frame")
	p.Name = "Panel"
	p.AnchorPoint = Vector2.new(0.5, 0.5)
	p.Position = UDim2.fromScale(0.5, 0.5)
	p.Size = UDim2.fromScale(0.94, 0.9)
	p.BackgroundColor3 = PANEL
	corner(p, 0.04)
	stroke(p, 2)
	p.Parent = shade
	local aspect = Instance.new("UIAspectRatioConstraint")
	aspect.AspectRatio = 1.75
	aspect.Parent = p
	local t = text(p, "Title", title, INK)
	t.TextXAlignment = Enum.TextXAlignment.Left
	t.Position = UDim2.fromScale(0.03, 0.025)
	t.Size = UDim2.fromScale(0.5, 0.08)
	local close = button(p, "Close", closeLabel, WHITE)
	close.AnchorPoint = Vector2.new(1, 0)
	close.Position = UDim2.fromScale(0.975, 0.02)
	close.Size = UDim2.fromScale(if #closeLabel > 2 then 0.26 else 0.07, 0.1)
	close.Activated:Connect(function()
		closeOverlay(name)
		onClose()
	end)
	return p
end

---------------------------------------------------------------------------
-- Mode picker
---------------------------------------------------------------------------

export type Chip = { id: string, label: string, locked: boolean? }
export type ModeCard = {
	id: string,
	title: string,
	line: string, -- what it is, one line
	players: number,
	color: Color3,
	locked: boolean, -- silhouette (spec: until minute 7 of the first session)
	lockedLine: string?,
	soon: boolean, -- the mode's place doesn't exist yet
	glow: boolean, -- the last mode played
	chips: { Chip },
	chip: string, -- the selected chip
	onChip: (string) -> (),
	onPlay: () -> (),
}

export type PartyStrip = { members: { string }, onParty: () -> () }

function HubHud.openModes(parent: Instance, cards: { ModeCard }, party: PartyStrip, onClose: () -> ())
	local p = panel(parent, "modes", "TUMBLE PARK", "DRIVE AROUND", onClose)
	local row = Instance.new("Frame")
	row.Name = "Cards"
	row.BackgroundTransparency = 1
	row.Position = UDim2.fromScale(0.03, 0.15)
	row.Size = UDim2.fromScale(0.94, 0.66)
	row.Parent = p
	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.Padding = UDim.new(0.02, 0)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = row
	for index, card in cards do
		local f = Instance.new("Frame")
		f.Name = card.id
		f.LayoutOrder = index
		f.Size = UDim2.fromScale(0.32, 1)
		f.BackgroundColor3 = if card.locked then SILHOUETTE else card.color
		corner(f, 0.06)
		local outline = stroke(f, if card.glow then 3 else 2, if card.glow then GOLD else INK)
		f.Parent = row
		if card.glow then
			glowTween = TweenService:Create(
				outline,
				TweenInfo.new(0.7, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
				{ Thickness = 4 }
			)
			glowTween:Play()
		end
		local title =
			text(f, "Title", if card.locked then "?????" else card.title, if card.locked then GREY else INK)
		title.Position = UDim2.fromScale(0.06, 0.04)
		title.Size = UDim2.fromScale(0.88, 0.14)
		local line = text(
			f,
			"Line",
			if card.locked then (card.lockedLine or "Opens soon") else card.line,
			if card.locked then WHITE else INK
		)
		line.Position = UDim2.fromScale(0.06, 0.2)
		line.Size = UDim2.fromScale(0.88, 0.1)
		local count = text(
			f,
			"Players",
			if card.locked or card.soon then "" else string.format("● %d playing", card.players),
			INK
		)
		count.Position = UDim2.fromScale(0.06, 0.33)
		count.Size = UDim2.fromScale(0.88, 0.09)
		if not card.locked then
			local chips = Instance.new("Frame")
			chips.Name = "Chips"
			chips.BackgroundTransparency = 1
			chips.Position = UDim2.fromScale(0.06, 0.47)
			chips.Size = UDim2.fromScale(0.88, 0.17)
			chips.Parent = f
			local chipList = Instance.new("UIListLayout")
			chipList.FillDirection = Enum.FillDirection.Horizontal
			chipList.HorizontalAlignment = Enum.HorizontalAlignment.Center
			chipList.Padding = UDim.new(0.04, 0)
			chipList.Parent = chips
			for _, chip in card.chips do
				local c = button(
					chips,
					chip.id,
					if chip.locked then "🔒 " .. chip.label else chip.label,
					if chip.id == card.chip then GOLD else WHITE
				)
				c.Size = UDim2.fromScale(0.47, 1)
				c.Active = not chip.locked
				c.AutoButtonColor = not chip.locked
				c.TextTransparency = if chip.locked then 0.4 else 0
				c.Activated:Connect(function()
					if not chip.locked then
						card.onChip(chip.id)
					end
				end)
			end
			local play = button(
				f,
				"Play",
				if card.soon then "COMING SOON" else "PLAY",
				if card.soon then WHITE else GREEN
			)
			play.AnchorPoint = Vector2.new(0.5, 1)
			play.Position = UDim2.fromScale(0.5, 0.95)
			play.Size = UDim2.fromScale(0.84, 0.22)
			play.Activated:Connect(card.onPlay)
		end
	end
	-- Party strip
	local strip = Instance.new("TextButton")
	strip.Name = "Party"
	strip.Text = if #party.members > 1
		then "PARTY: " .. table.concat(party.members, ", ") .. "   ▸"
		else "PLAY WITH FRIENDS: PARTY ▸"
	strip.Font = FONT
	strip.TextScaled = true
	strip.TextColor3 = INK
	strip.BackgroundColor3 = BLUE
	strip.AnchorPoint = Vector2.new(0.5, 1)
	strip.Position = UDim2.fromScale(0.5, 0.97)
	strip.Size = UDim2.fromScale(0.6, 0.11)
	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0.2, 0)
	pad.PaddingBottom = UDim.new(0.2, 0)
	pad.Parent = strip
	corner(strip, 0.3)
	stroke(strip, 2)
	strip.Parent = p
	strip.Activated:Connect(party.onParty)
end

-- MODES (top centre, in the hub when no screen is open) opens the picker again
local modesButton: TextButton? = nil
function HubHud.modesButton(parent: Instance, visible: boolean, onPress: () -> ())
	if modesButton == nil then
		if not visible then
			return
		end
		local g = ensureGui(parent)
		local b = button(g, "Modes", "PLAY ▸", GREEN)
		b.AnchorPoint = Vector2.new(0.5, 0)
		b.Position = UDim2.fromScale(0.5, 0.03)
		b.SizeConstraint = Enum.SizeConstraint.RelativeYY
		b.Size = UDim2.fromScale(0.36, 0.1)
		b.Activated:Connect(onPress) -- created once; the picker opener never changes
		modesButton = b
	end
	(modesButton :: TextButton).Visible = visible
end

---------------------------------------------------------------------------
-- Party
---------------------------------------------------------------------------

export type PartyView = {
	members: { { name: string, leader: boolean, me: boolean } },
	friends: { { name: string, invited: boolean, onInvite: () -> () } },
	onLeave: (() -> ())?,
}

function HubHud.openParty(parent: Instance, view: PartyView, onClose: () -> ())
	local p = panel(parent, "party", "PARTY", "✕", onClose)
	local left = text(p, "MembersTitle", "YOUR PARTY", INK)
	left.Position = UDim2.fromScale(0.04, 0.14)
	left.Size = UDim2.fromScale(0.42, 0.07)
	local right = text(p, "FriendsTitle", "FRIENDS IN THIS SERVER", INK)
	right.Position = UDim2.fromScale(0.52, 0.14)
	right.Size = UDim2.fromScale(0.44, 0.07)
	for index, member in view.members do
		local label = text(
			p,
			"Member" .. index,
			(if member.leader then "★ " else "") .. member.name .. (if member.me then " (you)" else ""),
			INK
		)
		label.Position = UDim2.fromScale(0.04, 0.23 + (index - 1) * 0.1)
		label.Size = UDim2.fromScale(0.42, 0.08)
	end
	if view.onLeave then
		local leave = button(p, "Leave", "LEAVE PARTY", WHITE)
		leave.Position = UDim2.fromScale(0.08, 0.8)
		leave.Size = UDim2.fromScale(0.34, 0.12)
		leave.Activated:Connect(view.onLeave)
	end
	local list = Instance.new("ScrollingFrame")
	list.Name = "Friends"
	list.BackgroundTransparency = 1
	list.Position = UDim2.fromScale(0.52, 0.23)
	list.Size = UDim2.fromScale(0.44, 0.72)
	list.CanvasSize = UDim2.new()
	list.AutomaticCanvasSize = Enum.AutomaticSize.Y
	list.ScrollBarThickness = 6
	list.Parent = p
	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 8)
	layout.Parent = list
	if #view.friends == 0 then
		local none = text(list, "None", "No friends here yet. Roblox friends who join show up here.", GREY)
		none.Size = UDim2.new(1, 0, 0, 60)
		none.TextWrapped = true
	end
	for index, friend in view.friends do
		local b = button(
			list,
			"Friend" .. index,
			(if friend.invited then "INVITED: " else "INVITE ") .. friend.name,
			BLUE
		)
		b.Size = UDim2.new(1, -10, 0, MIN)
		b.Activated:Connect(friend.onInvite)
	end
end

-- A friend's invite: JOIN or NO (it goes by itself after `seconds`)
function HubHud.invite(parent: Instance, name: string, seconds: number, onJoin: () -> ())
	closeOverlay("invite")
	local g = ensureGui(parent)
	local card = Instance.new("Frame")
	card.Name = "invite"
	card.AnchorPoint = Vector2.new(0.5, 0)
	card.Position = UDim2.fromScale(0.5, 0.12)
	card.Size = UDim2.fromScale(0.42, 0.18)
	card.BackgroundColor3 = PANEL
	corner(card, 0.12)
	stroke(card, 2)
	card.Parent = g
	overlays.invite = card
	local label = text(card, "Text", name .. " invites you to their party!", INK)
	label.Position = UDim2.fromScale(0.05, 0.08)
	label.Size = UDim2.fromScale(0.9, 0.38)
	local join = button(card, "Join", "JOIN", GREEN)
	join.Position = UDim2.fromScale(0.06, 0.52)
	join.Size = UDim2.fromScale(0.42, 0.4)
	local no = button(card, "No", "NO", WHITE)
	no.Position = UDim2.fromScale(0.52, 0.52)
	no.Size = UDim2.fromScale(0.42, 0.4)
	join.Activated:Connect(function()
		closeOverlay("invite")
		onJoin()
	end)
	no.Activated:Connect(function()
		closeOverlay("invite")
	end)
	task.delay(seconds, function()
		if overlays.invite == card then
			closeOverlay("invite")
		end
	end)
end

---------------------------------------------------------------------------
-- Leaderboards
---------------------------------------------------------------------------

export type BoardRow = { rank: number?, name: string, time: string, me: boolean, friend: boolean }
export type BoardView = {
	mapName: string,
	tab: string,
	loading: boolean,
	rows: { BoardRow },
	mine: BoardRow?,
	noTimeLine: string, -- under the list when your row is not there
	onTab: (string) -> (),
}

local TABS = { { "friends", "FRIENDS" }, { "weekly", "WEEKLY" }, { "alltime", "ALL-TIME" } }

local function boardRow(parent: Instance, row: BoardRow, order: number, pinned: boolean)
	local f = Instance.new("Frame")
	f.Name = "Row" .. order
	f.LayoutOrder = order
	f.BackgroundColor3 = if row.me then GOLD elseif row.friend then Color3.fromRGB(205, 230, 255) else WHITE
	f.Size = UDim2.new(1, -10, 0, math.max(MIN * 0.6, 36))
	corner(f, 0.25)
	stroke(f, if pinned then 3 else 1)
	f.Parent = parent
	local rank = text(f, "Rank", if row.rank then "#" .. row.rank else "—", INK)
	rank.Position = UDim2.fromScale(0.02, 0.15)
	rank.Size = UDim2.fromScale(0.14, 0.7)
	local name = text(f, "Name", row.name, INK)
	name.TextXAlignment = Enum.TextXAlignment.Left
	name.Position = UDim2.fromScale(0.18, 0.15)
	name.Size = UDim2.fromScale(0.52, 0.7)
	local t = text(f, "Time", row.time, INK)
	t.TextXAlignment = Enum.TextXAlignment.Right
	t.Position = UDim2.fromScale(0.7, 0.15)
	t.Size = UDim2.fromScale(0.27, 0.7)
end

function HubHud.openBoard(parent: Instance, view: BoardView, onClose: () -> ())
	local p = panel(parent, "board", "TOP TIMES: " .. view.mapName, "✕", onClose)
	local tabs = Instance.new("Frame")
	tabs.BackgroundTransparency = 1
	tabs.Position = UDim2.fromScale(0.03, 0.13)
	tabs.Size = UDim2.fromScale(0.94, 0.1)
	tabs.Parent = p
	local tabList = Instance.new("UIListLayout")
	tabList.FillDirection = Enum.FillDirection.Horizontal
	tabList.Padding = UDim.new(0.02, 0)
	tabList.Parent = tabs
	for _, tab in TABS do
		local b = button(tabs, tab[1], tab[2], if tab[1] == view.tab then GOLD else WHITE)
		b.Size = UDim2.fromScale(0.3, 1)
		b.Activated:Connect(function()
			view.onTab(tab[1])
		end)
	end
	local list = Instance.new("ScrollingFrame")
	list.Name = "Rows"
	list.BackgroundTransparency = 1
	list.Position = UDim2.fromScale(0.03, 0.25)
	list.Size = UDim2.fromScale(0.94, 0.58)
	list.CanvasSize = UDim2.new()
	list.AutomaticCanvasSize = Enum.AutomaticSize.Y
	list.ScrollBarThickness = 6
	list.Parent = p
	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 6)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = list
	if view.loading then
		local wait = text(list, "Loading", "Loading times...", GREY)
		wait.Size = UDim2.new(1, 0, 0, 40)
	elseif #view.rows == 0 then
		local none = text(
			list,
			"None",
			if view.tab == "friends"
				then "No friends on this board yet. Invite some!"
				else "No times yet. Be the first!",
			GREY
		)
		none.Size = UDim2.new(1, 0, 0, 40)
	end
	for index, row in view.rows do
		boardRow(list, row, index, false)
	end
	-- Your row, always pinned under the list
	local pinned = Instance.new("Frame")
	pinned.Name = "Mine"
	pinned.BackgroundTransparency = 1
	pinned.Position = UDim2.fromScale(0.03, 0.85)
	pinned.Size = UDim2.fromScale(0.94, 0.12)
	pinned.Parent = p
	local pinnedList = Instance.new("UIListLayout")
	pinnedList.Parent = pinned
	if view.mine then
		boardRow(pinned, view.mine, 1, true)
	else
		local none = text(pinned, "NoTime", view.noTimeLine, GREY)
		none.Size = UDim2.fromScale(1, 0.8)
	end
end

return HubHud
