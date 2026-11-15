-- CollisionGroups: registered once on the server (groups replicate to clients).
--   Vehicles  every chassis
--   Rider     ragdolled riders (client-local parts). Riders never hit each other.
--   Debris    flying panels and wheels. Debris hits the world but never players' cars or riders.
--   Ghost     other players' cars in Tracks free runs (milestone 2).

local PhysicsService = game:GetService("PhysicsService")

local CollisionGroups = {}

CollisionGroups.GROUPS = { "Vehicles", "Rider", "Debris", "Ghost" }

function CollisionGroups.init()
	for _, name in CollisionGroups.GROUPS do
		if not PhysicsService:IsCollisionGroupRegistered(name) then
			PhysicsService:RegisterCollisionGroup(name)
		end
	end
	PhysicsService:CollisionGroupSetCollidable("Rider", "Rider", false)
	PhysicsService:CollisionGroupSetCollidable("Debris", "Vehicles", false)
	PhysicsService:CollisionGroupSetCollidable("Debris", "Rider", false)
	PhysicsService:CollisionGroupSetCollidable("Debris", "Debris", false)
	PhysicsService:CollisionGroupSetCollidable("Ghost", "Vehicles", false)
	PhysicsService:CollisionGroupSetCollidable("Ghost", "Ghost", false)
	PhysicsService:CollisionGroupSetCollidable("Ghost", "Rider", false)
end

return CollisionGroups
