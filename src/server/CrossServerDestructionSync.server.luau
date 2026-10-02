-- Discord: its_whatitis | Roblox: Ribluxers
-- CrossServerDestructionSync
-- ServerScriptService
--
-- MessagingService in Studio has a much tighter quota than in prod — a
-- couple of publishes per second will rate-limit you. This file is
-- deliberately stingy: one global publish every MIN_PUBLISH_INTERVAL at
-- most, everything else batched into that one message. On failure we
-- back off hard instead of retrying immediately, because retrying into
-- a rate limit just deepens it.

local MessagingService = game:GetService("MessagingService")
local ServerStorage = game:GetService("ServerStorage")
local CollectionService = game:GetService("CollectionService")

local Terrain = workspace.Terrain

local TOPIC_NAME = "WorldDestructionSync"
local BATCH_WINDOW = 0.6
local MIN_PUBLISH_INTERVAL = 2.0
local RETRY_BACKOFF = 6
-- 25s of slack so a key survives worst-case backoff + echo round-trip.
-- An expired key only costs one redundant FillBall over already-carved
-- air, but the margin is cheap.
local DEDUP_TTL = 25
local MAX_PAYLOAD = 900 -- well under the 1kb publish cap
local BEAM_RADIUS = 4
local BEAM_PUBLISH_INTERVAL = 1.0
local DESTRUCTIBLE_TAG = "Destructible"

local function shortHash(s)
	local h = 5381
	for i = 1, #s do
		h = ((h * 33) + s:byte(i)) % 0xFFFFFFFF
	end
	return string.format("%07x", h)
end

-- JobId alone isn't safe as a session identity: it's often empty in
-- Studio, and in Local Server Test two servers can even return the same
-- value. If two servers end up with the same SESSION_TAG, their first
-- entries collide on "tag:1" — one server silently drops the other's
-- blast as a "duplicate" before coordinates are even compared.
--
-- Random.new() is unseeded, so it draws from an OS-provided entropy
-- source. NextInteger(1, 2147483647) matches the int32 ceiling exactly;
-- math.random(1, 2^31) used to overflow on the conversion and abort
-- with "interval is empty". os.clock()/tick() add microsecond variation
-- in case two servers boot in the same millisecond.
local sessionRng = Random.new()
local SESSION_TAG = shortHash(
	game.JobId
	.. "_" .. tostring(sessionRng:NextInteger(1, 2147483647))
	.. "_" .. tostring(os.clock())
	.. "_" .. tostring(tick())
)

local pendingBatch = {}
local appliedKeys = {} -- [string key] = os.clock() stamp
local localSeq = 0
local lastBeamPublish = 0
local lastPublishAt = 0
local retryAt = 0
local publishing = false

local bus = ServerStorage:WaitForChild("DestructionBus")

----------------------------------------------------------------
-- dedup
----------------------------------------------------------------

local function makeKey(tag, seq)
	return tag .. ":" .. seq
end

local function pruneDedup()
	local now = os.clock()
	for k, t in pairs(appliedKeys) do
		if now - t > DEDUP_TTL then
			appliedKeys[k] = nil
		end
	end
end

-- dedup table also needs to age out on its own. if a publish failed and
-- no echo ever came back, waiting on the next subscribe callback to prune
-- would leave the key sitting there indefinitely.
task.spawn(function()
	while true do
		task.wait(DEDUP_TTL)
		pruneDedup()
	end
end)

----------------------------------------------------------------
-- publish pipeline
----------------------------------------------------------------

local flushScheduled = false
local scheduleFlush
local tryPublish

local function isRateLimitError(msg)
	msg = string.lower(tostring(msg))
	-- narrow. bare "rate" matches "moderate", "generate", "separate",
	-- which would send us into a backoff for a non-quota failure.
	return string.find(msg, "too many", 1, true) ~= nil
		or string.find(msg, "rate limit", 1, true) ~= nil
		or string.find(msg, "throttl", 1, true) ~= nil
end

local function currentPayloadLen()
	if #pendingBatch == 0 then return 0 end
	return #table.concat(pendingBatch, ";")
end

local function buildPayload()
	if #pendingBatch == 0 then return nil end
	local payload = table.concat(pendingBatch, ";")
	table.clear(pendingBatch)
	return payload
end

tryPublish = function()
	-- if a publish is already in flight, don't drop the request: reschedule
	-- so entries queued during the yield still go out.
	if publishing then
		scheduleFlush(BATCH_WINDOW)
		return
	end
	if #pendingBatch == 0 then return end

	local now = os.clock()

	if now < retryAt then
		scheduleFlush(retryAt - now + 0.1)
		return
	end
	if now - lastPublishAt < MIN_PUBLISH_INTERVAL then
		scheduleFlush(MIN_PUBLISH_INTERVAL - (now - lastPublishAt) + 0.05)
		return
	end

	local payload = buildPayload()
	if not payload then return end

	publishing = true
	lastPublishAt = now

	local ok, err = pcall(function()
		MessagingService:PublishAsync(TOPIC_NAME, payload)
	end)
	publishing = false

	if ok then return end

	if isRateLimitError(err) then
		-- hard backoff, do NOT requeue. resending into a throttle just
		-- deepens it. losing one beam segment or one explosion on a
		-- distant server is fine; losing the sync loop is not.
		retryAt = os.clock() + RETRY_BACKOFF
	else
		warn("[CrossServer] publish failed: " .. tostring(err))
	end
end

scheduleFlush = function(delay)
	if flushScheduled then return end
	flushScheduled = true
	task.delay(delay, function()
		flushScheduled = false
		tryPublish()
	end)
end

local function appendEntry(entry)
	if currentPayloadLen() + #entry + 1 > MAX_PAYLOAD then
		tryPublish()
	end

	table.insert(pendingBatch, entry)

	-- emergency trim bounded by bytes, not entry count. 40 small entries
	-- can still exceed the publish cap during a long backoff, and a
	-- "message too large" error wouldn't match isRateLimitError — it
	-- would warn-loop instead of backing off.
	while currentPayloadLen() > MAX_PAYLOAD and #pendingBatch > 0 do
		table.remove(pendingBatch, 1)
	end

	scheduleFlush(BATCH_WINDOW)
end

----------------------------------------------------------------
-- local bus feed
----------------------------------------------------------------

bus.Event:Connect(function(kind, a, b)
	local now = os.clock()

	if kind == "explosion" then
		local pos, radius = a, b
		localSeq += 1
		-- register locally before publishing: MessagingService echoes
		-- the message back to us, and without this stamp we'd re-apply
		-- our own blast a second time.
		appliedKeys[makeKey(SESSION_TAG, localSeq)] = now
		appendEntry(string.format("E,%s,%d,%d,%d,%d,%d",
			SESSION_TAG, localSeq,
			math.floor(pos.X), math.floor(pos.Y), math.floor(pos.Z),
			math.floor(radius)))

	elseif kind == "beam" then
		-- beam fires on every server tick. coalesce hard: one entry per
		-- BEAM_PUBLISH_INTERVAL, regardless of how many ticks happened.
		if now - lastBeamPublish < BEAM_PUBLISH_INTERVAL then return end
		lastBeamPublish = now

		local origin, endpoint = a, b
		localSeq += 1
		appliedKeys[makeKey(SESSION_TAG, localSeq)] = now
		appendEntry(string.format("B,%s,%d,%d,%d,%d,%d,%d,%d",
			SESSION_TAG, localSeq,
			math.floor(origin.X), math.floor(origin.Y), math.floor(origin.Z),
			math.floor(endpoint.X), math.floor(endpoint.Y), math.floor(endpoint.Z)))
	end
end)

----------------------------------------------------------------
-- receive side
----------------------------------------------------------------

local function parseFields(s)
	local out = {}
	for f in s:gmatch("[^,]+") do
		table.insert(out, f)
	end
	return out
end

-- parts are per-server instances: a Destroy on server A doesn't touch
-- server B's copy. So the receiving side has to re-sweep its own tagged
-- parts in the blast radius. We don't apply velocity here — anything the
-- blast would have moved was already settled on the source server.
local function sweepTaggedParts(center, radius)
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.MaxParts = 200

	local parts = workspace:GetPartBoundsInRadius(center, radius, params)
	for _, part in ipairs(parts) do
		if not part.Parent or not part:IsA("BasePart") then continue end
		if not part.Anchored then continue end
		if CollectionService:HasTag(part, DESTRUCTIBLE_TAG) then
			part:Destroy()
		end
	end
end

local function applyExplosionEntry(tag, seq, x, y, z, r)
	local key = makeKey(tag, seq)
	if appliedKeys[key] then return end
	appliedKeys[key] = os.clock()

	if r <= 0 or r > 64 then return end
	-- keep Y bounded too. FillBall at Y = -1e6 is harmless but it's a
	-- sanity hole worth closing.
	if math.abs(x) > 2000 or math.abs(y) > 2000 or math.abs(z) > 2000 then return end

	local pos = Vector3.new(x, y, z)
	pcall(function()
		Terrain:FillBall(pos, r, Enum.Material.Air)
	end)
	pcall(function()
		sweepTaggedParts(pos, r)
	end)
end

local function applyBeamEntry(tag, seq, ox, oy, oz, ex, ey, ez)
	local key = makeKey(tag, seq)
	if appliedKeys[key] then return end
	appliedKeys[key] = os.clock()

	local origin = Vector3.new(ox, oy, oz)
	local endpoint = Vector3.new(ex, ey, ez)
	local delta = endpoint - origin
	local dist = delta.Magnitude
	if dist < 0.1 or dist > 400 then return end

	-- mirror the source server's carve: one rotated block plus round caps.
	-- endpoint-only sweep, not path-wide — that's what blastParts does on
	-- the source server, and structs placed along the beam's length are
	-- untouched there either.
	local cf = CFrame.new(origin + delta * 0.5, endpoint)
	pcall(function()
		Terrain:FillBlock(cf,
			Vector3.new(BEAM_RADIUS * 2, BEAM_RADIUS * 2, dist),
			Enum.Material.Air)
		Terrain:FillBall(origin, BEAM_RADIUS, Enum.Material.Air)
		Terrain:FillBall(endpoint, BEAM_RADIUS, Enum.Material.Air)
		sweepTaggedParts(endpoint, BEAM_RADIUS * 2)
	end)
end

local function onMessage(message)
	local payload = message.Data
	if type(payload) ~= "string" then return end

	for entry in payload:gmatch("[^;]+") do
		local kind = entry:sub(1, 1)
		local fields = parseFields(entry:sub(3))

		if kind == "E" and #fields == 6 then
			applyExplosionEntry(
				fields[1], tonumber(fields[2]),
				tonumber(fields[3]), tonumber(fields[4]),
				tonumber(fields[5]), tonumber(fields[6]))
		elseif kind == "B" and #fields == 8 then
			applyBeamEntry(
				fields[1], tonumber(fields[2]),
				tonumber(fields[3]), tonumber(fields[4]), tonumber(fields[5]),
				tonumber(fields[6]), tonumber(fields[7]), tonumber(fields[8]))
		end
	end
end

-- SubscribeAsync fails noticeably more often in Studio than in prod.
-- without the retry, one bad attempt kills cross-server until restart.
task.spawn(function()
	while true do
		local ok, err = pcall(function()
			MessagingService:SubscribeAsync(TOPIC_NAME, onMessage)
		end)
		if ok then return end
		warn("[CrossServer] subscribe failed, retrying in 5s: " .. tostring(err))
		task.wait(5)
	end
end)

-- TODO: if the quota ever gets raised in prod, drop MIN_PUBLISH_INTERVAL
-- and let BATCH_WINDOW be the only throttle.