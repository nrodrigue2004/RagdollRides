-- MapSpace: piece frames in world space, shared by the server's MapBuilder and the client's TracksClient
-- so both agree on where every piece is (Roblox types; the pure maths is in StarterMaps).
-- A piece's frame: its position, then yaw, then pitch, then roll (positive yaw turns left, positive
-- pitch climbs). Builder maps use the same frames (PieceCatalog.toMapDef makes a MapDef).

local StarterMaps = require(script.Parent.StarterMaps)

local MapSpace = {}

function MapSpace.point(map: StarterMaps.MapDef, x: number, y: number, z: number): Vector3
	local wx, wy, wz = StarterMaps.toWorld(map, x, y, z)
	return Vector3.new(wx, wy, wz)
end

function MapSpace.pieceCFrame(map: StarterMaps.MapDef, piece: StarterMaps.Piece): CFrame
	return CFrame.new(MapSpace.point(map, piece.x, piece.y, piece.z))
		* CFrame.Angles(0, math.rad(piece.yaw), 0)
		* CFrame.Angles(math.rad(piece.pitch), 0, 0)
		* CFrame.Angles(0, 0, math.rad(piece.roll or 0))
end

-- Where a car is put down at the start of a map: ground level, facing along the road
function MapSpace.startCFrame(map: StarterMaps.MapDef): CFrame
	local start = StarterMaps.startPiece(map)
	if not start then
		return CFrame.new(MapSpace.point(map, 0, 0, 0))
	end
	return CFrame.new(MapSpace.point(map, start.x, start.y, start.z))
		* CFrame.Angles(0, math.rad(start.yaw), 0)
end

return MapSpace
