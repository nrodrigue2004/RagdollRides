--!strict
-- Damage: impact value and crash tiers (pure functions, unit tested).
-- Milestone 1 uses impact and tiers to decide feedback and rider ejection. Zone health, panel states,
-- handling effects and explosions are added in milestone 1b on top of these functions.

local Damage = {}

export type ImpactConfig = {
	massFactorMin: number,
	massFactorMax: number,
	staticMassFactor: number,
	tiers: { { name: string, min: number } },
}

-- mass factor = clamp(other mass / own mass, 0.5, 2.0); static world geometry counts as 2.0
function Damage.massFactor(ownMass: number, otherMass: number?, cfg: ImpactConfig): number
	if otherMass == nil or otherMass <= 0 then
		return cfg.staticMassFactor
	end
	return math.clamp(otherMass / ownMass, cfg.massFactorMin, cfg.massFactorMax)
end

-- Closing speed along the contact normal, estimated from our own unexplained change in velocity.
-- Against static geometry (perfectly inelastic) our change in velocity equals the closing speed. Against a
-- moving body of mass m2, our change is closing * m2 / (m1 + m2), so we scale it back up.
function Damage.closingSpeedFromDeltaV(deltaV: number, ownMass: number, otherMass: number?): number
	if otherMass == nil or otherMass <= 0 then
		return deltaV
	end
	return deltaV * (ownMass + otherMass) / otherMass
end

-- Impact I = closing speed * mass factor
function Damage.impact(closingSpeed: number, massFactor: number): number
	return math.max(0, closingSpeed) * massFactor
end

-- Tier name for an impact value: "Scrape" (<10), "Bump" (10-25), "HardHit" (25-60), "HugeCrash" (60+)
function Damage.tier(impact: number, cfg: ImpactConfig): string
	local name = cfg.tiers[1].name
	for _, tier in cfg.tiers do
		if impact >= tier.min then
			name = tier.name
		end
	end
	return name
end

-- Which side of the car a contact came from, from the contact normal in the car's local space
-- (the normal points from the obstacle toward the car).
-- Returns "Bottom", "Roof", "Front", "Rear", "Left" or "Right".
function Damage.contactSide(nx: number, ny: number, nz: number, landingDot: number, roofDot: number): string
	if ny >= landingDot then
		return "Bottom"
	elseif ny <= roofDot then
		return "Roof"
	end
	-- The obstacle is opposite the normal. Roblox cars face -Z, so an obstacle ahead pushes us toward +Z.
	if math.abs(nz) >= math.abs(nx) then
		return if nz > 0 then "Front" else "Rear"
	end
	return if nx > 0 then "Left" else "Right"
end

return Damage
