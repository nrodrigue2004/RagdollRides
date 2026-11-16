--!strict
-- VehicleMath: pure driving formulas from the spec (no Roblox types), shared by the vehicle
-- controller and the unit tests.

local VehicleMath = {}

-- Spring and damper coefficients for one corner.
-- k = m_corner * (2*pi*f)^2, c = 2 * zeta * m_corner * 2*pi*f
function VehicleMath.springCoefficients(
	cornerMass: number,
	frequency: number,
	dampingRatio: number
): (number, number)
	local omega = 2 * math.pi * frequency
	return cornerMass * omega * omega, 2 * dampingRatio * cornerMass * omega
end

-- Engine force fraction for a speed fraction (0..1 of top speed):
-- 100% up to `flat` (0.6), then falling linearly to 0 at top speed.
function VehicleMath.torqueCurve(speedFraction: number, flat: number): number
	if speedFraction <= flat then
		return 1
	elseif speedFraction >= 1 then
		return 0
	end
	return (1 - speedFraction) / (1 - flat)
end

-- Base acceleration (studs/s^2) so that full throttle on flat ground reaches `reach` (0.98) of top speed
-- in exactly `timeToTop` seconds with the torque curve above and no other drag.
-- Phase 1 (0 to flat*V) is constant accel; phase 2 is exponential with time constant (1-flat)*V/a0.
function VehicleMath.baseAcceleration(
	topSpeed: number,
	timeToTop: number,
	flat: number,
	reach: number
): number
	local phase1 = flat
	local phase2 = (1 - flat) * math.log((1 - flat) / (1 - reach))
	return topSpeed * (phase1 + phase2) / timeToTop
end

-- Max wheel angle in degrees: 32 at standstill, falling linearly to 10 at top speed.
function VehicleMath.maxSteerAngle(speedFraction: number, atZero: number, atTop: number): number
	local s = math.clamp(speedFraction, 0, 1)
	return atZero + (atTop - atZero) * s
end

-- Moves `current` toward `target` at 1/rampTime per second (digital inputs).
function VehicleMath.rampInput(current: number, target: number, rampTime: number, dt: number): number
	if rampTime <= 0 then
		return target
	end
	local maxDelta = dt / rampTime
	local delta = math.clamp(target - current, -maxDelta, maxDelta)
	return current + delta
end

-- Lateral tyre force: clamp(-slip * stiffness, +-mu * load)
function VehicleMath.lateralForce(slipSpeed: number, stiffness: number, maxForce: number): number
	return math.clamp(-slipSpeed * stiffness, -maxForce, maxForce)
end

-- Friction circle: scales (fx, fy) down so the combined force never exceeds maxForce.
function VehicleMath.frictionCircle(fx: number, fy: number, maxForce: number): (number, number)
	local magnitude = math.sqrt(fx * fx + fy * fy)
	if magnitude <= maxForce or magnitude == 0 then
		return fx, fy
	end
	local scale = maxForce / magnitude
	return fx * scale, fy * scale
end

-- A force that stops `speed` (along its axis) without overshooting in one step.
function VehicleMath.stoppingForce(speed: number, maxForce: number, mass: number, dt: number): number
	local needed = math.abs(speed) * mass / dt
	local force = math.min(maxForce, needed)
	if speed > 0 then
		return -force
	elseif speed < 0 then
		return force
	end
	return 0
end

-- Downforce = coefficient * weight * (speed fraction)^2
function VehicleMath.downforce(weight: number, speedFraction: number, coefficient: number): number
	local s = math.clamp(speedFraction, 0, 1)
	return coefficient * weight * s * s
end

-- Suspension compression for a ray hit (0 = full extension, travel = fully compressed) and the bump-stop
-- overshoot (how far the wheel would sit past full compression).
function VehicleMath.compression(hitDistance: number, travel: number, wheelRadius: number): (number, number)
	local raw = travel + wheelRadius - hitDistance
	local compression = math.clamp(raw, 0, travel)
	local overshoot = math.max(0, raw - travel)
	return compression, overshoot
end

export type SuspensionParams = {
	k: number,
	c: number,
	bumpK: number,
	bumpDampingMultiplier: number,
	cornerMass: number,
	travel: number,
	radius: number,
	progressiveSpeed: number,
	reboundMultiplier: number,
}

-- One corner of the suspension for one frame.
-- The spring is a force (k * compression, plus a bump stop past full compression). The damper is applied
-- as an immediate velocity change at the mount (exponential decay), which never overshoots at any frame
-- rate. Damping is progressive (stronger the faster the wheel is pushed in) so big landings land heavy and
-- dead instead of bouncing, and contact is predicted one frame ahead so a fast drop at 30 fps is caught
-- before the chassis belly hits the ground.
-- compressionSpeed > 0 means the wheel is being pushed in. hitDistance is the ray distance from the mount
-- (math.huge for no hit). Returns: springForce, dampingDeltaV (per corner, along the car's up axis),
-- touching (the tyre is on the ground now), compression, overshoot.
function VehicleMath.suspensionStep(
	p: SuspensionParams,
	hitDistance: number,
	compressionSpeed: number,
	dt: number
): (number, number, boolean, number, number)
	local reach = p.travel + p.radius
	local lookahead = math.max(0, compressionSpeed) * dt
	if hitDistance - lookahead > reach then
		return 0, 0, false, 0, 0
	end
	local compression, overshoot = VehicleMath.compression(hitDistance, p.travel, p.radius)
	local _, predictedOvershoot = VehicleMath.compression(hitDistance - lookahead, p.travel, p.radius)
	local spring = p.k * compression + p.bumpK * overshoot
	local damping
	if compressionSpeed > 0 then
		damping = p.c * (1 + compressionSpeed / p.progressiveSpeed)
		if predictedOvershoot > 0 then
			damping += p.c * p.bumpDampingMultiplier
		end
	else
		damping = p.c * p.reboundMultiplier
	end
	local deltaV = (1 - math.exp(-(damping / p.cornerMass) * dt)) * compressionSpeed
	if deltaV < 0 then
		-- Rebound damping may slow the extension but never pulls the car into the ground
		deltaV = math.max(deltaV, -spring * dt / p.cornerMass)
	end
	return spring, deltaV, hitDistance <= reach, compression, overshoot
end

-- Kinematic yaw rate (rad/s) a car "should" have for its speed and steer angle (bicycle model).
function VehicleMath.expectedYawRate(forwardSpeed: number, steerRadians: number, wheelbase: number): number
	if wheelbase <= 0 then
		return 0
	end
	return forwardSpeed * math.tan(steerRadians) / wheelbase
end

-- Solid box moments of inertia about its own x, y, z axes.
function VehicleMath.boxInertia(mass: number, sx: number, sy: number, sz: number): (number, number, number)
	return mass / 12 * (sy * sy + sz * sz), mass / 12 * (sx * sx + sz * sz), mass / 12 * (sx * sx + sy * sy)
end

-- 1D simulation of full throttle on flat ground; returns the time to reach `reach` of top speed.
-- Used by the unit tests to check the class table against the "3.3 s or less" feel test.
function VehicleMath.simulateTimeToTop(
	topSpeed: number,
	timeToTop: number,
	flat: number,
	reach: number
): number
	local a0 = VehicleMath.baseAcceleration(topSpeed, timeToTop, flat, reach)
	local v, t, dt = 0, 0, 1 / 240
	while v < topSpeed * reach and t < 30 do
		v += a0 * VehicleMath.torqueCurve(v / topSpeed, flat) * dt
		t += dt
	end
	return t
end

-- Suspension damping as impulses that work together. Each grounded corner asks for a change dv[i] in its
-- vertical speed; a car is one rigid body, so an impulse at one corner also moves the others through roll
-- and pitch. Applied corner by corner (each as if it were a quarter of the mass), a roll or pitch change
-- overshoots by about mass * x^2 / inertia, 3x for these boxes, and the car shook itself over at low fps.
-- This solves for the impulses (along the chassis up, at mounts x[i] right and z[i] back of the centre of
-- mass) whose combined effect gives each corner its change; what a rigid body can't do (one diagonal
-- against the other) is left out. Returns one impulse per corner.
function VehicleMath.dampingImpulses(
	x: { number },
	z: { number },
	dv: { number },
	mass: number,
	rollInertia: number,
	pitchInertia: number
): { number }
	local n = #dv
	if n == 0 then
		return {}
	end
	-- K[i][j]: corner i's speed change per unit (impulse / mass) at corner j
	local k = {}
	for i = 1, n do
		k[i] = {}
		for j = 1, n do
			k[i][j] = 1 + mass * x[i] * x[j] / rollInertia + mass * z[i] * z[j] / pitchInertia
		end
	end
	-- Ridge least squares: (K K + mu I) u = K dv
	local a = {}
	local b = {}
	local mu = 1e-4
	for i = 1, n do
		a[i] = {}
		local rhs = 0
		for j = 1, n do
			local sum = 0
			for m = 1, n do
				sum += k[i][m] * k[m][j]
			end
			a[i][j] = sum + (if i == j then mu else 0)
			rhs += k[i][j] * dv[j]
		end
		b[i] = rhs
	end
	-- Gaussian elimination with partial pivoting
	for col = 1, n do
		local pivot = col
		for row = col + 1, n do
			if math.abs(a[row][col]) > math.abs(a[pivot][col]) then
				pivot = row
			end
		end
		a[col], a[pivot] = a[pivot], a[col]
		b[col], b[pivot] = b[pivot], b[col]
		local d = a[col][col]
		if math.abs(d) < 1e-12 then
			continue
		end
		for row = col + 1, n do
			local f = a[row][col] / d
			if f ~= 0 then
				for c = col, n do
					a[row][c] -= f * a[col][c]
				end
				b[row] -= f * b[col]
			end
		end
	end
	local u = table.create(n, 0)
	for row = n, 1, -1 do
		local sum = b[row]
		for c = row + 1, n do
			sum -= a[row][c] * u[c]
		end
		local d = a[row][row]
		u[row] = if math.abs(d) < 1e-12 then 0 else sum / d
	end
	local impulses = table.create(n, 0)
	for i = 1, n do
		impulses[i] = u[i] * mass
	end
	return impulses
end

-- How much more a roll or pitch change at the corners moves them than the same force on a quarter of the
-- mass would (1 = no more). Spring step guards divide by it.
function VehicleMath.cornerAmplification(
	x: { number },
	z: { number },
	mass: number,
	rollInertia: number,
	pitchInertia: number
): number
	local n = #x
	if n == 0 then
		return 1
	end
	local xx, zz = 0, 0
	for i = 1, n do
		xx += x[i] * x[i]
		zz += z[i] * z[i]
	end
	return math.max(1, mass * xx / n / rollInertia, mass * zz / n / pitchInertia)
end

return VehicleMath
