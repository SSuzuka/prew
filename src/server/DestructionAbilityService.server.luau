-- Discord: its_whatitis | Roblox: Ribluxers
-- DestructionAbilityService
-- ServerScriptService

local Players = game:GetService("Players")
local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local CollectionService = game:GetService("CollectionService")

local Terrain = workspace.Terrain

----------------------------------------------------------------
-- tuning
----------------------------------------------------------------

local MIN_RADIUS = 4
local MAX_RADIUS = 48
local MAX_CAST_DISTANCE = 120

-- 8 studs of tolerance. The client's mouse-hit and the server's root
-- position are never exactly aligned — replication delay puts them
-- 1–3 studs apart on a moving character, and voxel terrain has enough
-- surface irregularity that a camera-origin ray and a root-origin ray
-- land on different blocks. 4 was tight enough to false-positive
-- "blocked" on obvious ground hits.
local LOS_TOLERANCE = 8
-- below this range we skip LOS entirely. There's no room for a wall
-- between caster and target inside 10 studs, and casting at your feet
-- used to be the most common false positive.
local LOS_MIN_DIST = 10

local MANA_MAX = 100
local MANA_REGEN = 8

local BEAM_RANGE = 200
local BEAM_RADIUS = 4
local BEAM_TICK = 0.1
local BEAM_MANA_PER_SECOND = 2
local BEAM_STALE_AFTER = 0.35
local BEAM_VFX_INTERVAL = 0.2
local BEAM_COOLDOWN = 1.5
local BEAM_PART_INTERVAL = 0.5

local VFX_EXPLOSION = 1
local VFX_BEAM = 2

local DESTRUCTIBLE_TAG = "Destructible"

local nextVfxId = 0

----------------------------------------------------------------
-- player character detection
----------------------------------------------------------------

local function isPlayerCharacterPart(part)
	local model = part:FindFirstAncestorWhichIsA("Model")
	if not model then return false end
	return Players:GetPlayerFromCharacter(model) ~= nil
end

----------------------------------------------------------------
-- auto-tag
-- demo convenience. a real map would carry the tag at build time,
-- otherwise late-spawned models stay unbreakable forever.
----------------------------------------------------------------

task.spawn(function()
	local batch = 0
	for _, part in ipairs(workspace:GetDescendants()) do
		if part:IsA("BasePart")
			and part.Anchored
			and part.Name ~= "Baseplate"
			and not isPlayerCharacterPart(part)
		then
			CollectionService:AddTag(part, DESTRUCTIBLE_TAG)
		end
		batch += 1
		if batch >= 500 then
			batch = 0
			task.wait()
		end
	end
end)

----------------------------------------------------------------
-- mana
----------------------------------------------------------------

local manaState = {} -- [Player] = { value, lastRegen }

local function ensureMana(player)
	local s = manaState[player]
	if not s then
		s = { value = MANA_MAX, lastRegen = os.clock() }
		manaState[player] = s
	end
	return s
end

-- regen is opt-out: while channeling we still advance lastRegen, so the
-- channel window doesn't retroactively grant mana the moment it ends.
local function tickMana(player, regen)
	local s = ensureMana(player)
	local now = os.clock()
	local elapsed = now - s.lastRegen
	if elapsed > 0 then
		if regen ~= false then
			s.value = math.min(MANA_MAX, s.value + MANA_REGEN * elapsed)
		end
		s.lastRegen = now
	end
	return s.value
end

local function spendMana(player, cost)
	local s = ensureMana(player)
	if s.value < cost then return false end
	s.value -= cost
	return true
end

local function syncManaAttribute(player)
	local v = math.floor(tickMana(player))
	if player:GetAttribute("Mana") ~= v then
		player:SetAttribute("Mana", v)
	end
end

----------------------------------------------------------------
-- ability base
----------------------------------------------------------------

local Ability = {}
Ability.__index = Ability

function Ability.new(config)
	assert(config and config.name, "ability needs a name")
	return setmetatable({
		name = config.name,
		cooldown = config.cooldown or 0,
		lastUsed = {},
	}, Ability)
end

function Ability:IsReady(player)
	local stamp = self.lastUsed[player]
	return not stamp or (os.clock() - stamp) >= self.cooldown
end

function Ability:Consume(player)
	self.lastUsed[player] = os.clock()
end

function Ability:Cleanup(player)
	self.lastUsed[player] = nil
end

----------------------------------------------------------------
-- shared helpers
----------------------------------------------------------------

local function clampRadius(r)
	if type(r) ~= "number" or r ~= r then return nil end
	if r == math.huge or r == -math.huge then return nil end
	return math.clamp(r, MIN_RADIUS, MAX_RADIUS)
end

local function makeSelfExcludeParams(char)
	local rp = RaycastParams.new()
	rp.FilterType = Enum.RaycastFilterType.Exclude
	rp.FilterDescendantsInstances = { char }
	return rp
end

-- fallback voxel probe, only reached when the cast ray misses Terrain
-- itself. ±3 studs and 0.2 fill threshold: mouse.Hit lands on the
-- *surface* of terrain where the top voxel is often only partially
-- filled, and a ±2 / 0.5 probe misses a direct hit on the ground.
local function hasTerrainAt(pos)
	local half = Vector3.new(3, 3, 3)
	local okRegion, region = pcall(function()
		return Region3.new(pos - half, pos + half):ExpandToGrid(4)
	end)
	if not okRegion or not region then return true end

	local okRead, _, occ = pcall(function()
		return Terrain:ReadVoxels(region, 4)
	end)
	if not okRead or not occ then return true end

	for x = 1, occ.Size.X do
		for y = 1, occ.Size.Y do
			for z = 1, occ.Size.Z do
				if occ[x][y][z] > 0.2 then return true end
			end
		end
	end
	return false
end

----------------------------------------------------------------
-- buffer codec
-- Explosion: u8 kind + u32 id + f32*3 pos + f32 radius          = 21 bytes
-- Beam:      u8 kind + u32 id + u32 sender + f32*6 pts + f32 w  = 37 bytes
----------------------------------------------------------------

local EXPLOSION_PACKET_SIZE = 21
local BEAM_PACKET_SIZE = 37

local function serializeExplosion(id, pos, radius)
	local buf = buffer.create(EXPLOSION_PACKET_SIZE)
	buffer.writeu8(buf, 0, VFX_EXPLOSION)
	buffer.writeu32(buf, 1, id)
	buffer.writef32(buf, 5, pos.X)
	buffer.writef32(buf, 9, pos.Y)
	buffer.writef32(buf, 13, pos.Z)
	buffer.writef32(buf, 17, radius)
	return buf
end

local function serializeBeam(id, senderId, origin, endpoint, width)
	local buf = buffer.create(BEAM_PACKET_SIZE)
	buffer.writeu8(buf, 0, VFX_BEAM)
	buffer.writeu32(buf, 1, id)
	buffer.writeu32(buf, 5, senderId)
	buffer.writef32(buf, 9, origin.X)
	buffer.writef32(buf, 13, origin.Y)
	buffer.writef32(buf, 17, origin.Z)
	buffer.writef32(buf, 21, endpoint.X)
	buffer.writef32(buf, 25, endpoint.Y)
	buffer.writef32(buf, 29, endpoint.Z)
	buffer.writef32(buf, 33, width)
	return buf
end

----------------------------------------------------------------
-- remotes + bus
----------------------------------------------------------------

local function ensureInst(parent, className, name)
	local inst = parent:FindFirstChild(name)
	if not inst then
		inst = Instance.new(className)
		inst.Name = name
		inst.Parent = parent
	end
	return inst
end

local repRemote = ensureInst(ReplicatedStorage, "RemoteEvent", "VFXReplication")
local reqExplosion = ensureInst(ReplicatedStorage, "RemoteEvent", "ExplosionRequest")
local reqBeam = ensureInst(ReplicatedStorage, "RemoteEvent", "BeamRequest")

-- server-only fan-out. keeping it out of ReplicatedStorage removes a
-- needless client-side surface for the event.
local bus = ensureInst(ServerStorage, "BindableEvent", "DestructionBus")

----------------------------------------------------------------
-- geometry
----------------------------------------------------------------

local function blastParts(center, radius, caster)
	-- build a character set once. GetPlayerFromCharacter per part is a
	-- linear scan over the player list, and this loop can hit 200 parts.
	local playerChars = {}
	for _, plr in ipairs(Players:GetPlayers()) do
		local c = plr.Character
		if c then playerChars[c] = true end
	end

	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = caster and { caster } or {}
	params.MaxParts = 200

	local parts = workspace:GetPartBoundsInRadius(center, radius, params)
	local touched = 0

	for _, part in ipairs(parts) do
		if not part.Parent or not part:IsA("BasePart") then continue end

		-- other players standing nearby shouldn't get flung by raw
		-- AssemblyLinearVelocity; caster is pre-filtered by OverlapParams.
		local model = part:FindFirstAncestorWhichIsA("Model")
		if model and playerChars[model] then continue end

		if part.Anchored then
			if CollectionService:HasTag(part, DESTRUCTIBLE_TAG) then
				part:Destroy()
				touched += 1
			end
		else
			-- don't re-apply velocity to parts that are already moving.
			-- without this a channeled beam pinballs the same debris
			-- every tick and it looks stuck rather than launched.
			if part.AssemblyLinearVelocity.Magnitude < 5 then
				local dir = part.Position - center
				if dir.Magnitude < 0.1 then
					dir = Vector3.new(0, 1, 0)
				end
				part.AssemblyLinearVelocity = dir.Unit * (60 + math.random() * 40)
				part.AssemblyAngularVelocity = Vector3.new(
					math.random(-20, 20), math.random(-20, 20), math.random(-20, 20)
				)
			end
			touched += 1
		end
	end
	return touched
end

local function spawnDebris(center, radius)
	local count = math.clamp(math.floor(radius * 0.6), 4, 24)

	for _ = 1, count do
		local angle = math.random() * math.pi * 2
		local pitch = math.random() * math.pi - math.pi * 0.5
		local dist = math.random() * radius * 0.7

		local offset = Vector3.new(
			math.cos(angle) * math.cos(pitch) * dist,
			math.sin(pitch) * dist + 2,
			math.sin(angle) * math.cos(pitch) * dist
		)

		local part = Instance.new("Part")
		part.Size = Vector3.new(1.2, 1.2, 1.2)
		part.Material = Enum.Material.Slate
		part.Color = Color3.fromRGB(60, 55, 50)
		part.CanCollide = false
		part.CFrame = CFrame.new(center) * CFrame.new(offset)
			* CFrame.Angles(math.random(), math.random(), math.random())
		part.AssemblyLinearVelocity = offset.Unit * (20 + math.random() * 20)
		part.Parent = workspace

		Debris:AddItem(part, 6)
	end
end

----------------------------------------------------------------
-- Explosion
----------------------------------------------------------------

local Explosion = setmetatable({}, { __index = Ability })
Explosion.__index = Explosion

function Explosion.new()
	local self = Ability.new({ name = "Explosion", cooldown = 6 })
	self.manaCost = 25
	return setmetatable(self, Explosion)
end

function Explosion:Activate(player, targetPos, radius)
	if typeof(targetPos) ~= "Vector3" then
		return false, "target not a Vector3"
	end

	local clamped = clampRadius(radius)
	if not clamped then
		return false, "radius out of range"
	end

	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if not root then
		return false, "no character"
	end

	local dist = (targetPos - root.Position).Magnitude
	if dist > MAX_CAST_DISTANCE then
		return false, string.format("too far (%.1f > %d)", dist, MAX_CAST_DISTANCE)
	end

	local rp = makeSelfExcludeParams(char)
	rp.IgnoreWater = true
	local hit = workspace:Raycast(root.Position, targetPos - root.Position, rp)

	-- LOS: clear unless the ray stopped short of the target's depth.
	-- Skipped under LOS_MIN_DIST because there's no room for an occluder
	-- at that range, and casting at your feet was the common false hit.
	local hitTerrain = false
	if hit and dist >= LOS_MIN_DIST then
		local rayLen = (hit.Position - root.Position).Magnitude
		if rayLen < dist - LOS_TOLERANCE then
			return false, string.format("line of sight blocked (gap %.1f)",
				dist - rayLen)
		end
	end

	if hit then
		hitTerrain = hit.Instance == Terrain
	end

	if not self:IsReady(player) then
		return false, "on cooldown"
	end
	if tickMana(player) < self.manaCost then
		return false, string.format("not enough mana (%.0f < %d)",
			tickMana(player), self.manaCost)
	end

	self:Consume(player)
	spendMana(player, self.manaCost)
	syncManaAttribute(player)

	-- the raycast already told us whether terrain is at the impact. If
	-- it hit Terrain and the hit is close to targetPos, no need to spend
	-- a ReadVoxels call. Only probe when the ray missed or passed clean
	-- through (steep angles over uneven voxels can slip past a face).
	local onTerrain = hitTerrain
		and (hit.Position - targetPos).Magnitude <= LOS_TOLERANCE
	if not onTerrain then
		onTerrain = hasTerrainAt(targetPos)
	end

	local partsHit = blastParts(targetPos, clamped, char)

	if onTerrain then
		Terrain:FillBall(targetPos, clamped, Enum.Material.Air)
	end

	if onTerrain or partsHit > 0 then
		spawnDebris(targetPos, clamped)
		nextVfxId += 1
		repRemote:FireAllClients(serializeExplosion(nextVfxId, targetPos, clamped))
		bus:Fire("explosion", targetPos, clamped)
		return true
	end

	-- cast fired, cooldown and mana spent, but there was nothing in the
	-- sphere to break. Surfacing this stops the player from thinking
	-- the ability is broken.
	return true, "fired, nothing in range"
end

----------------------------------------------------------------
-- Beam — held channel
----------------------------------------------------------------

local activeBeams = {} -- [Player] = { dir, lastSeen, lastVfx, lastTick, lastPartCheck }

local Beam = setmetatable({}, { __index = Ability })
Beam.__index = Beam

function Beam.new()
	return setmetatable(Ability.new({ name = "Beam", cooldown = BEAM_COOLDOWN }), Beam)
end

local beamAbility = Beam.new()

reqBeam.OnServerEvent:Connect(function(player, direction)
	if direction == nil then
		activeBeams[player] = nil
		return
	end

	if typeof(direction) ~= "Vector3" then
		player:Kick("malformed beam request")
		return
	end

	local mag = direction.Magnitude
	if mag < 0.1 or mag > 10 or mag ~= mag then return end

	local state = activeBeams[player]
	if not state then
		if not beamAbility:IsReady(player) then return end
		-- mirror the explosion gate: check mana before committing the
		-- cooldown, so a modified client can't burn a channel it can't
		-- sustain anyway.
		if tickMana(player, false) <= 0 then return end
		beamAbility:Consume(player)
		local now = os.clock()
		activeBeams[player] = {
			dir = direction.Unit,
			lastSeen = now,
			lastVfx = 0,
			lastTick = now,
			lastPartCheck = 0,
		}
	else
		state.dir = direction.Unit
		state.lastSeen = os.clock()
	end
end)

task.spawn(function()
	while true do
		task.wait(BEAM_TICK)
		local now = os.clock()

		for player, state in pairs(activeBeams) do
			if now - state.lastSeen > BEAM_STALE_AFTER then
				activeBeams[player] = nil
				continue
			end

			local char = player.Character
			local root = char and char:FindFirstChild("HumanoidRootPart")
			if not root then
				activeBeams[player] = nil
				continue
			end

			-- cost tracks real elapsed time, not the nominal tick.
			-- task.wait drifts under load, and charging a flat per-tick
			-- value would under-drain on a slow server.
			local elapsed = math.min(now - state.lastTick, 0.5)
			state.lastTick = now
			local cost = BEAM_MANA_PER_SECOND * elapsed

			if tickMana(player, false) < cost then
				activeBeams[player] = nil
				continue
			end
			spendMana(player, cost)
			syncManaAttribute(player)

			local origin = root.Position + Vector3.new(0, 1, 0)

			local rp = makeSelfExcludeParams(char)
			local hit = workspace:Raycast(origin, state.dir * BEAM_RANGE, rp)
			local endpoint = hit and hit.Position or (origin + state.dir * BEAM_RANGE)

			-- extend the carve one radius past the surface hit. without
			-- this the last sphere is centered exactly on the surface and
			-- only shaves the top voxels — the beam visually stutters
			-- when you're already looking down into the hole.
			local carveEnd = hit and (hit.Position + state.dir * BEAM_RADIUS) or endpoint
			local delta = carveEnd - origin
			local length = delta.Magnitude
			if length > 0.5 then
				-- one rotated box covers the whole segment. the previous
				-- FillBall loop was 67 calls per tick on a full-range beam.
				local cf = CFrame.new(origin + delta * 0.5, carveEnd)
				Terrain:FillBlock(cf,
					Vector3.new(BEAM_RADIUS * 2, BEAM_RADIUS * 2, length),
					Enum.Material.Air)
				-- rounded caps so the tunnel mouth isn't a square
				Terrain:FillBall(origin, BEAM_RADIUS, Enum.Material.Air)
				Terrain:FillBall(carveEnd, BEAM_RADIUS, Enum.Material.Air)
			end

			-- parts are expensive to query. hitting this every tick
			-- re-applies velocity to the same debris before it can move,
			-- which is exactly what made rubble look pinned to the beam.
			if now - state.lastPartCheck >= BEAM_PART_INTERVAL then
				state.lastPartCheck = now
				blastParts(endpoint, BEAM_RADIUS * 2, char)
			end

			if now - state.lastVfx >= BEAM_VFX_INTERVAL then
				state.lastVfx = now
				nextVfxId += 1
				local pkt = serializeBeam(nextVfxId, player.UserId, origin, endpoint, BEAM_RADIUS)
				-- skip the caster: their client draws its own beam every
				-- frame, and a lagging server copy is what caused the
				-- "two beams" reports.
				for _, plr in ipairs(Players:GetPlayers()) do
					if plr ~= player then
						repRemote:FireClient(plr, pkt)
					end
				end
			end

			bus:Fire("beam", origin, endpoint)
		end
	end
end)

----------------------------------------------------------------
-- entry point
----------------------------------------------------------------

local explosionAbility = Explosion.new()

reqExplosion.OnServerEvent:Connect(function(player, targetPos, radius)
	if typeof(targetPos) ~= "Vector3" or type(radius) ~= "number" then
		player:Kick("malformed explosion request")
		return
	end

	local ok, reason = explosionAbility:Activate(player, targetPos, radius)
	reqExplosion:FireClient(player, ok, reason)
end)

local function initMana(player)
	ensureMana(player)
	player:SetAttribute("Mana", MANA_MAX)
end

for _, plr in ipairs(Players:GetPlayers()) do
	initMana(plr)
end
Players.PlayerAdded:Connect(initMana)

Players.PlayerRemoving:Connect(function(player)
	explosionAbility:Cleanup(player)
	beamAbility:Cleanup(player)
	activeBeams[player] = nil
	manaState[player] = nil
end)

task.spawn(function()
	while true do
		task.wait(0.2)
		for _, plr in ipairs(Players:GetPlayers()) do
			if not activeBeams[plr] then
				syncManaAttribute(plr)
			else
				local v = math.floor(tickMana(plr, false))
				if plr:GetAttribute("Mana") ~= v then
					plr:SetAttribute("Mana", v)
				end
			end
		end
	end
end)

-- TODO: consider an "overheat" mechanic — right now you can hold forever
-- as long as you have mana.