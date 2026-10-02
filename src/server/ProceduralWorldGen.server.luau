-- Discord: its_whatitis | Roblox: Ribluxers
-- ProceduralWorldGen
-- ServerScriptService
--
-- Deterministic terrain generator. Same SEED → identical world on every
-- server, which is what makes CrossServerDestructionSync coherent:
-- without a shared baseline, server A would be carving into terrain that
-- server B doesn't have.
--
-- Generation is chunked with periodic yields so a large world doesn't
-- stall the server on boot.

local CollectionService = game:GetService("CollectionService")

local Terrain = workspace.Terrain

----------------------------------------------------------------
-- config
----------------------------------------------------------------

local SEED = 20260103
local WORLD_HALF = 128          -- world spans [-WORLD_HALF, +WORLD_HALF]
local CELL = 8                  -- studs per cell. voxel res is 4, so 2×2 voxels per cell
local FLOOR_Y = -32             -- bottom of the solid mass
local BASE_Y = 0                -- nominal sea level
local AMPLITUDE = 22            -- max height above BASE_Y
local COLUMNS_PER_YIELD = 96    -- task.wait() cadence during terrain paint
local STRUCTURE_COUNT = 10

local DESTRUCTIBLE_TAG = "Destructible"

----------------------------------------------------------------
-- seeded noise
--
-- math.noise is deterministic in Roblox but doesn't take a seed. We
-- derive a per-seed phase offset from Random.new(SEED) and shift the
-- sample coordinates by it — different seeds → different worlds, same
-- seed → identical worlds on every server.
----------------------------------------------------------------

local seedRng = Random.new(SEED)
local SEED_OFF_X = seedRng:NextNumber() * 1000
local SEED_OFF_Z = seedRng:NextNumber() * 1000

local function heightAt(x, z)
	local n1 = math.noise((x + SEED_OFF_X) * 0.008, (z + SEED_OFF_Z) * 0.008)
	local n2 = math.noise((x + SEED_OFF_X) * 0.030, (z + SEED_OFF_Z) * 0.030) * 0.30
	-- remap from roughly [-1, 1] to [0, 1], then scale to world height
	local n = (n1 + n2) * 0.5 + 0.5
	return BASE_Y + n * AMPLITUDE
end

----------------------------------------------------------------
-- terrain paint
--
-- three FillBlock calls per column: rock core, ground skin, grass cap.
-- FillBlock replaces the whole block region in one call, so this is
-- O(columns) terrain ops instead of O(voxels).
----------------------------------------------------------------

local function paintColumn(x, z, topY)
	local coreH = topY - FLOOR_Y
	if coreH <= 0 then return end

	Terrain:FillBlock(
		CFrame.new(x + CELL / 2, (topY + FLOOR_Y) / 2, z + CELL / 2),
		Vector3.new(CELL, coreH, CELL),
		Enum.Material.Rock)

	local skinH = math.min(3, coreH)
	Terrain:FillBlock(
		CFrame.new(x + CELL / 2, topY - skinH / 2, z + CELL / 2),
		Vector3.new(CELL, skinH, CELL),
		Enum.Material.Ground)

	Terrain:FillBlock(
		CFrame.new(x + CELL / 2, topY - 0.5, z + CELL / 2),
		Vector3.new(CELL, 1, CELL),
		Enum.Material.Grass)
end

----------------------------------------------------------------
-- structures
--
-- simple two-part pillars. tagged explicitly rather than relying on the
-- auto-tagger in DestructionAbilityService, which runs on its own
-- schedule and could race against generation.
----------------------------------------------------------------

local function makeStructurePart(size, pos, material, color)
	local p = Instance.new("Part")
	p.Size = size
	p.Position = pos
	p.Anchored = true
	p.Material = material
	p.Color = color
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = workspace
	CollectionService:AddTag(p, DESTRUCTIBLE_TAG)
	return p
end

local function spawnStructure(x, z, baseY, height)
	makeStructurePart(
		Vector3.new(CELL * 1.4, 2, CELL * 1.4),
		Vector3.new(x, baseY + 1, z),
		Enum.Material.Slate,
		Color3.fromRGB(70, 60, 55))

	makeStructurePart(
		Vector3.new(CELL * 0.6, height, CELL * 0.6),
		Vector3.new(x, baseY + 2 + height / 2, z),
		Enum.Material.Concrete,
		Color3.fromRGB(120, 110, 100))
end

local function scatterStructures()
	for _ = 1, STRUCTURE_COUNT do
		local x = seedRng:NextNumber(-WORLD_HALF + 24, WORLD_HALF - 24)
		local z = seedRng:NextNumber(-WORLD_HALF + 24, WORLD_HALF - 24)
		local y = heightAt(x, z)
		local h = seedRng:NextNumber(10, 26)
		spawnStructure(x, z, y, h)
	end
end

----------------------------------------------------------------
-- entry
----------------------------------------------------------------

local function generate()
	Terrain:Clear()

	local cols = math.floor((WORLD_HALF * 2) / CELL)
	local painted = 0

	for ix = 0, cols - 1 do
		for iz = 0, cols - 1 do
			local x = -WORLD_HALF + ix * CELL
			local z = -WORLD_HALF + iz * CELL
			paintColumn(x, z, heightAt(x, z))

			painted += 1
			if painted % COLUMNS_PER_YIELD == 0 then
				task.wait()
			end
		end
	end

	scatterStructures()
end

generate()