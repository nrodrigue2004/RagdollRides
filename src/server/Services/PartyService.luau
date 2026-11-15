-- PartyService: play together with friends (spec: Hub and menus > Party queue; Remotes Party.Invite,
-- Party.Join). Names only, no text: an invite is a card with the friend's Roblox display name.
-- * Party.Invite(userId): a Roblox friend in this server. Makes you a party leader if you were not in a
--   party. The friend gets Party.Invited; it stays open for Config.Party.inviteExpiry seconds.
-- * Party.Join(userId): accept an open invite from that player (leaving any party you were in).
-- * Party.Leave: leave; a leaving leader hands the party to the next member; a party of one ends.
-- * Party.State to every member on each change: { leader, members = { { userId, name } } }, or {}.
-- * The leader queues the party: a quick race (RaceService) takes every free member with them, and a
--   mode teleport (TeleportHub, milestones 7 and 8) sends the party to one server.
-- Parties live in this server only; following a friend to another server is Roblox's own Join.

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Config)
local Net = require(Shared.Net)
local Signal = require(Shared.Util.Signal)

local EconomyService = require(script.Parent.EconomyService)

local PartyService = {}

PartyService.Changed = Signal.new() -- (party members, as a list of players)

type Party = { leader: Player, members: { Player } }

local partyOf: { [Player]: Party } = {}
local invites: { [Player]: { [number]: number } } = {} -- target -> inviter userId -> expiry (os.clock)

local function send(party: Party?)
	if party == nil then
		return
	end
	local list = {}
	for _, member in party.members do
		table.insert(list, { userId = member.UserId, name = member.DisplayName })
	end
	local state = { leader = party.leader.UserId, members = list }
	for _, member in party.members do
		Net.fire("Party.State", member, state)
	end
	PartyService.Changed:Fire(table.clone(party.members))
end

-- Everyone in the player's party (the player first), or just the player
function PartyService.members(player: Player): { Player }
	local party = partyOf[player]
	if party == nil then
		return { player }
	end
	local list = { player }
	for _, member in party.members do
		if member ~= player then
			table.insert(list, member)
		end
	end
	return list
end

function PartyService.isLeader(player: Player): boolean
	local party = partyOf[player]
	return party == nil or party.leader == player
end

function PartyService.inParty(player: Player): boolean
	return partyOf[player] ~= nil
end

function PartyService.leave(player: Player)
	local party = partyOf[player]
	if party == nil then
		return
	end
	partyOf[player] = nil
	local index = table.find(party.members, player)
	if index then
		table.remove(party.members, index)
	end
	if player.Parent == Players then
		Net.fire("Party.State", player, {})
	end
	if #party.members <= 1 then
		-- A party of one is no party
		for _, member in party.members do
			partyOf[member] = nil
			Net.fire("Party.State", member, {})
		end
		PartyService.Changed:Fire({})
		return
	end
	if party.leader == player then
		party.leader = party.members[1]
	end
	send(party)
end

local function onInvite(player: Player, userId: number)
	local friend = Players:GetPlayerByUserId(userId)
	if friend == nil or friend == player then
		return
	end
	local party = partyOf[player]
	if party and table.find(party.members, friend) then
		return
	end
	if party and #party.members >= Config.Party.maxSize then
		Net.fire("Notice", player, "partyFull")
		return
	end
	if not EconomyService.areFriends(player, friend) then
		Net.fire("Notice", player, "partyFriendsOnly")
		return
	end
	local open = invites[friend] or {}
	invites[friend] = open
	open[player.UserId] = os.clock() + Config.Party.inviteExpiry
	Net.fire("Party.Invited", friend, {
		from = player.UserId,
		name = player.DisplayName,
		expires = Config.Party.inviteExpiry,
	})
	Net.fire("Notice", player, "partyInviteSent")
end

local function onJoin(player: Player, userId: number)
	local open = invites[player]
	local expiry = open and open[userId]
	local inviter = Players:GetPlayerByUserId(userId)
	if expiry == nil or os.clock() > expiry or inviter == nil then
		Net.fire("Notice", player, "partyInviteGone")
		return
	end
	open[userId] = nil
	local party = partyOf[inviter]
	if party and party == partyOf[player] then
		return
	end
	if party and #party.members >= Config.Party.maxSize then
		Net.fire("Notice", player, "partyFull")
		return
	end
	PartyService.leave(player)
	if party == nil then
		party = { leader = inviter, members = { inviter } }
		partyOf[inviter] = party
	end
	local p = party :: Party
	table.insert(p.members, player)
	partyOf[player] = p
	send(p)
end

function PartyService.init()
	Net.on("Party.Invite", onInvite)
	Net.on("Party.Join", onJoin)
	Net.on("Party.Leave", PartyService.leave)
	Players.PlayerRemoving:Connect(function(player)
		PartyService.leave(player)
		invites[player] = nil
	end)
end

return PartyService
