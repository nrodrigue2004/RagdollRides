--!strict
-- PoseCodec: packs a vehicle pose into a small buffer for Vehicle.Pose (10 Hz, unreliable).
-- Layout (7 bytes, or 127 when the rider is ragdolled):
--   0   steer      i8   -127..127
--   1   throttle   i8   -127..127 (negative = brake / reverse)
--   2   flags      u8   bit0 ragdolled, bit1 braking, bit2 skidding, bit3 airborne, bit4 handbrake
--   3-6 compression u8 x4 (0..255 of suspension travel), wheel order FL, FR, RL, RR
--   7+  6 rider transforms, 20 bytes each: position f32 x3, rotation quaternion i16 x4
-- The numeric half is pure so the tests can run it outside Roblox; toCFrame/fromCFrame wrap it.

local PoseCodec = {}

PoseCodec.BASE_SIZE = 7
PoseCodec.TRANSFORM_SIZE = 20
PoseCodec.RIDER_PIECES = 6
PoseCodec.RAGDOLL_SIZE = 7 + 6 * 20

PoseCodec.FLAG_RAGDOLL = 1
PoseCodec.FLAG_BRAKING = 2
PoseCodec.FLAG_SKIDDING = 4
PoseCodec.FLAG_AIRBORNE = 8
PoseCodec.FLAG_HANDBRAKE = 16

export type Pose = {
	steer: number, -- -1..1
	throttle: number, -- -1..1
	flags: number,
	compression: { number }, -- 4 values, 0..1
	-- 6 entries of { px, py, pz, qx, qy, qz, qw } when ragdolled
	rider: { { number } }?,
}

local function toI8(value: number): number
	return math.clamp(math.round(value * 127), -127, 127)
end

local function toU8(value: number): number
	return math.clamp(math.round(value * 255), 0, 255)
end

local function toI16(value: number): number
	return math.clamp(math.round(value * 32767), -32767, 32767)
end

function PoseCodec.encode(pose: Pose): buffer
	local ragdolled = pose.rider ~= nil and bit32.band(pose.flags, PoseCodec.FLAG_RAGDOLL) ~= 0
	local size = if ragdolled then PoseCodec.RAGDOLL_SIZE else PoseCodec.BASE_SIZE
	local b = buffer.create(size)
	buffer.writei8(b, 0, toI8(pose.steer))
	buffer.writei8(b, 1, toI8(pose.throttle))
	buffer.writeu8(b, 2, bit32.band(pose.flags, 0xFF))
	for i = 1, 4 do
		buffer.writeu8(b, 2 + i, toU8(pose.compression[i] or 0))
	end
	if ragdolled then
		local rider = pose.rider :: { { number } }
		for piece = 1, PoseCodec.RIDER_PIECES do
			local t = rider[piece]
			local offset = PoseCodec.BASE_SIZE + (piece - 1) * PoseCodec.TRANSFORM_SIZE
			buffer.writef32(b, offset, t[1])
			buffer.writef32(b, offset + 4, t[2])
			buffer.writef32(b, offset + 8, t[3])
			-- Keep w >= 0 so the quaternion sign is canonical
			local sign = if t[7] < 0 then -1 else 1
			buffer.writei16(b, offset + 12, toI16(t[4] * sign))
			buffer.writei16(b, offset + 14, toI16(t[5] * sign))
			buffer.writei16(b, offset + 16, toI16(t[6] * sign))
			buffer.writei16(b, offset + 18, toI16(t[7] * sign))
		end
	end
	return b
end

function PoseCodec.decode(b: buffer): Pose?
	local size = buffer.len(b)
	if size ~= PoseCodec.BASE_SIZE and size ~= PoseCodec.RAGDOLL_SIZE then
		return nil
	end
	local pose: Pose = {
		steer = buffer.readi8(b, 0) / 127,
		throttle = buffer.readi8(b, 1) / 127,
		flags = buffer.readu8(b, 2),
		compression = {},
		rider = nil,
	}
	for i = 1, 4 do
		pose.compression[i] = buffer.readu8(b, 2 + i) / 255
	end
	if size == PoseCodec.RAGDOLL_SIZE then
		local rider = {}
		for piece = 1, PoseCodec.RIDER_PIECES do
			local offset = PoseCodec.BASE_SIZE + (piece - 1) * PoseCodec.TRANSFORM_SIZE
			local px = buffer.readf32(b, offset)
			local py = buffer.readf32(b, offset + 4)
			local pz = buffer.readf32(b, offset + 8)
			local qx = buffer.readi16(b, offset + 12) / 32767
			local qy = buffer.readi16(b, offset + 14) / 32767
			local qz = buffer.readi16(b, offset + 16) / 32767
			local qw = buffer.readi16(b, offset + 18) / 32767
			local length = math.sqrt(qx * qx + qy * qy + qz * qz + qw * qw)
			if length < 1e-6 or px ~= px or py ~= py or pz ~= pz then
				return nil
			end
			rider[piece] = { px, py, pz, qx / length, qy / length, qz / length, qw / length }
		end
		pose.rider = rider
	end
	return pose
end

-- Rotation matrix (row-major, as CFrame:GetComponents returns) to a unit quaternion (x, y, z, w).
function PoseCodec.matrixToQuaternion(
	r00: number,
	r01: number,
	r02: number,
	r10: number,
	r11: number,
	r12: number,
	r20: number,
	r21: number,
	r22: number
): (number, number, number, number)
	local trace = r00 + r11 + r22
	local qx, qy, qz, qw
	if trace > 0 then
		local s = math.sqrt(trace + 1) * 2
		qw = 0.25 * s
		qx = (r21 - r12) / s
		qy = (r02 - r20) / s
		qz = (r10 - r01) / s
	elseif r00 > r11 and r00 > r22 then
		local s = math.sqrt(1 + r00 - r11 - r22) * 2
		qw = (r21 - r12) / s
		qx = 0.25 * s
		qy = (r01 + r10) / s
		qz = (r02 + r20) / s
	elseif r11 > r22 then
		local s = math.sqrt(1 + r11 - r00 - r22) * 2
		qw = (r02 - r20) / s
		qx = (r01 + r10) / s
		qy = 0.25 * s
		qz = (r12 + r21) / s
	else
		local s = math.sqrt(1 + r22 - r00 - r11) * 2
		qw = (r10 - r01) / s
		qx = (r02 + r20) / s
		qy = (r12 + r21) / s
		qz = 0.25 * s
	end
	return qx, qy, qz, qw
end

-- Roblox wrappers
function PoseCodec.fromCFrame(cf: CFrame): { number }
	local x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22 = cf:GetComponents()
	local qx, qy, qz, qw = PoseCodec.matrixToQuaternion(r00, r01, r02, r10, r11, r12, r20, r21, r22)
	return { x, y, z, qx, qy, qz, qw }
end

function PoseCodec.toCFrame(t: { number }): CFrame
	return CFrame.new(t[1], t[2], t[3], t[4], t[5], t[6], t[7])
end

return PoseCodec
