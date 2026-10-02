-- Discord: its_whatitis | Roblox: Ribluxers
-- DestructionClient
-- StarterPlayerScripts
-- Demo-only. Input + HUD + cosmetics.
-- LMB        = explosion
-- hold RMB   = beam channel

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")

local player = Players.LocalPlayer
local camera = workspace.CurrentCamera
local localUserId = player.UserId

local reqExplosion = ReplicatedStorage:WaitForChild("ExplosionRequest")
local reqBeam = ReplicatedStorage:WaitForChild("BeamRequest")
local repRemote = ReplicatedStorage:WaitForChild("VFXReplication")

local BLAST_RADIUS = 24
local MANA_MAX = 100
local EXPLOSION_MANA = 25
local EXPLOSION_COOLDOWN = 6
-- grace window for the server ack. If it doesn't arrive in this time the
-- pending flag self-clears so the player isn't locked out by a lost reply.
local EXPLOSION_ACK_TIMEOUT = 1.0

-- mirrors of server values. Keep these in sync with DestructionAbilityService.
local MAX_CAST_DISTANCE = 120
local LOS_TOLERANCE = 8
local LOS_MIN_DIST = 10
local BEAM_MIN_MANA = 1
local BEAM_COOLDOWN = 1.5

local VFX_EXPLOSION = 1
local VFX_BEAM = 2

local BEAM_PART_NAME = "BeamVFX_Local"
local IMPACT_PART_NAME = "BeamVFX_ImpactLocal"
local REMOTE_BEAM_PREFIX = "BeamVFX_Remote_"
local REMOTE_IMPACT_PREFIX = "BeamVFX_ImpactRemote_"

local beamHeld = false
local beamLastStartAt = -math.huge
local explosionCooldownUntil = 0

-- forward declaration: the Mana attribute handler calls stopBeam, but the
-- handler is installed before the input section defines it.
local stopBeam

----------------------------------------------------------------
-- HUD
-- anchored top-center: away from Roblox's chat (top-left), leaderboard
-- and settings (top-right), and mobile control hints (bottom).
----------------------------------------------------------------

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "DestructionHUD"
screenGui.ResetOnSpawn = false
screenGui.IgnoreGuiInset = true
screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
screenGui.Parent = player:WaitForChild("PlayerGui")

local statusFrame = Instance.new("Frame")
statusFrame.Size = UDim2.new(0, 460, 0, 52)
statusFrame.Position = UDim2.new(0.5, -230, 0, 24)
statusFrame.BackgroundColor3 = Color3.fromRGB(12, 12, 16)
statusFrame.BackgroundTransparency = 0.1
statusFrame.BorderSizePixel = 0
statusFrame.Parent = screenGui

local statusCorner = Instance.new("UICorner")
statusCorner.CornerRadius = UDim.new(0, 12)
statusCorner.Parent = statusFrame

local statusStroke = Instance.new("UIStroke")
statusStroke.Color = Color3.fromRGB(70, 70, 80)
statusStroke.Thickness = 1.5
statusStroke.Transparency = 0.4
statusStroke.Parent = statusFrame

local statusLabel = Instance.new("TextLabel")
statusLabel.Size = UDim2.new(1, 0, 1, 0)
statusLabel.BackgroundTransparency = 1
statusLabel.Font = Enum.Font.GothamBold
statusLabel.TextSize = 24
statusLabel.TextColor3 = Color3.fromRGB(240, 240, 240)
statusLabel.TextStrokeTransparency = 0.7
statusLabel.Text = "Ready"
statusLabel.Parent = statusFrame

local manaBack = Instance.new("Frame")
manaBack.Size = UDim2.new(0, 460, 0, 20)
manaBack.Position = UDim2.new(0.5, -230, 0, 84)
manaBack.BackgroundColor3 = Color3.fromRGB(20, 20, 26)
manaBack.BorderSizePixel = 0
manaBack.Parent = screenGui

local manaCorner = Instance.new("UICorner")
manaCorner.CornerRadius = UDim.new(0, 10)
manaCorner.Parent = manaBack

local manaStroke = Instance.new("UIStroke")
manaStroke.Color = Color3.fromRGB(70, 70, 80)
manaStroke.Thickness = 1.5
manaStroke.Transparency = 0.4
manaStroke.Parent = manaBack

local manaFill = Instance.new("Frame")
manaFill.Size = UDim2.new(1, 0, 1, 0)
manaFill.BackgroundColor3 = Color3.fromRGB(90, 140, 255)
manaFill.BorderSizePixel = 0
manaFill.Parent = manaBack

local fillCorner = Instance.new("UICorner")
fillCorner.CornerRadius = UDim.new(0, 10)
fillCorner.Parent = manaFill

local manaText = Instance.new("TextLabel")
manaText.Size = UDim2.new(1, 0, 1, 0)
manaText.BackgroundTransparency = 1
manaText.Font = Enum.Font.GothamBold
manaText.TextSize = 14
manaText.TextColor3 = Color3.fromRGB(250, 250, 250)
manaText.TextStrokeTransparency = 0.5
manaText.Text = "100 / 100"
manaText.ZIndex = 2
manaText.Parent = manaBack

local hintLabel = Instance.new("TextLabel")
hintLabel.Size = UDim2.new(0, 520, 0, 24)
hintLabel.Position = UDim2.new(0, 24, 1, -60)
hintLabel.AnchorPoint = Vector2.new(0, 1)
hintLabel.BackgroundColor3 = Color3.fromRGB(12, 12, 16)
hintLabel.BackgroundTransparency = 0.4
hintLabel.BorderSizePixel = 0
hintLabel.Font = Enum.Font.Gotham
hintLabel.TextSize = 15
hintLabel.TextXAlignment = Enum.TextXAlignment.Center
hintLabel.TextColor3 = Color3.fromRGB(220, 220, 220)
hintLabel.Text = "LMB — explosion    ·    hold RMB — beam"
hintLabel.Parent = screenGui

local hintCorner = Instance.new("UICorner")
hintCorner.CornerRadius = UDim.new(0, 8)
hintCorner.Parent = hintLabel

local fpsLabel = Instance.new("TextLabel")
fpsLabel.Size = UDim2.new(0, 140, 0, 22)
fpsLabel.Position = UDim2.new(1, -156, 0, 60)
fpsLabel.BackgroundTransparency = 1
fpsLabel.Font = Enum.Font.Code
fpsLabel.TextSize = 15
fpsLabel.TextXAlignment = Enum.TextXAlignment.Right
fpsLabel.TextColor3 = Color3.fromRGB(120, 220, 120)
fpsLabel.TextStrokeTransparency = 0.5
fpsLabel.Text = "60 fps"
fpsLabel.Parent = screenGui

local function setStatus(text, color)
	statusLabel.Text = text
	statusLabel.TextColor3 = color
	-- retint the border to match, reads as a state indicator at a glance
	statusStroke.Color = Color3.fromRGB(
		math.floor(color.R * 180 + 40),
		math.floor(color.G * 180 + 40),
		math.floor(color.B * 180 + 40)
	)
end

local function updateManaBar(current)
	local ratio = math.clamp(current / MANA_MAX, 0, 1)
	TweenService:Create(manaFill, TweenInfo.new(0.1), {
		Size = UDim2.new(ratio, 0, 1, 0),
	}):Play()
	manaText.Text = string.format("%d / %d", math.floor(current), MANA_MAX)
	if current < 25 then
		manaFill.BackgroundColor3 = Color3.fromRGB(200, 80, 80)
	elseif current < 50 then
		manaFill.BackgroundColor3 = Color3.fromRGB(230, 180, 90)
	else
		manaFill.BackgroundColor3 = Color3.fromRGB(90, 140, 255)
	end
end

-- mana comes from the server at 10Hz while channeling. when it drops
-- below the threshold we kill the beam client-side so the drawn effect
-- matches what the server is actually doing.
player:GetAttributeChangedSignal("Mana"):Connect(function()
	local current = player:GetAttribute("Mana") or MANA_MAX
	updateManaBar(current)

	if beamHeld and current < BEAM_MIN_MANA and stopBeam then
		stopBeam()
	end
end)
updateManaBar(player:GetAttribute("Mana") or MANA_MAX)

----------------------------------------------------------------
-- fps meter
----------------------------------------------------------------

local frameCount, frameAccum = 0, 0

RunService.RenderStepped:Connect(function(dt)
	frameCount += 1
	frameAccum += dt
	if frameAccum >= 0.5 then
		fpsLabel.Text = string.format("%d fps", math.floor(frameCount / frameAccum + 0.5))
		frameCount, frameAccum = 0, 0
	end
end)

----------------------------------------------------------------
-- explosion VFX
----------------------------------------------------------------

local function playExplosion(pos, radius)
	local snd = Instance.new("Sound")
	snd.SoundId = "rbxasset://sounds/impact_water.mp3"
	snd.Volume = 1.6
	snd.RollOffMaxDistance = radius * 6
	snd.RollOffMinDistance = radius * 0.5
	snd.Parent = SoundService
	snd:Play()
	task.delay(2, function() snd:Destroy() end)

	local fireball = Instance.new("Part")
	fireball.Shape = Enum.PartType.Ball
	fireball.Size = Vector3.new(4, 4, 4)
	fireball.Anchored = true
	fireball.CanCollide = false
	fireball.CanQuery = false
	fireball.CanTouch = false
	fireball.Material = Enum.Material.Neon
	fireball.Color = Color3.fromRGB(255, 140, 40)
	fireball.CFrame = CFrame.new(pos)
	fireball.Parent = workspace

	TweenService:Create(fireball, TweenInfo.new(0.25, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), {
		Size = Vector3.new(radius * 2, radius * 2, radius * 2),
		Color = Color3.fromRGB(120, 20, 0),
		Transparency = 1,
	}):Play()
	task.delay(0.4, function() fireball:Destroy() end)

	local ring = Instance.new("Part")
	ring.Shape = Enum.PartType.Cylinder
	ring.Size = Vector3.new(1, 4, 4)
	ring.Anchored = true
	ring.CanCollide = false
	ring.CanQuery = false
	ring.CanTouch = false
	ring.Material = Enum.Material.Neon
	ring.Color = Color3.fromRGB(255, 220, 160)
	ring.Transparency = 0.2
	ring.CFrame = CFrame.new(pos) * CFrame.Angles(0, 0, math.rad(90))
	ring.Parent = workspace

	TweenService:Create(ring, TweenInfo.new(0.45, Enum.EasingStyle.Quart, Enum.EasingDirection.Out), {
		Size = Vector3.new(1, radius * 3, radius * 3),
		Transparency = 1,
	}):Play()
	task.delay(0.6, function() ring:Destroy() end)
end

----------------------------------------------------------------
-- beam VFX
----------------------------------------------------------------

local beamVFX = { beam = nil, impact = nil, expiresAt = 0 }

local function ensureBeamVFX()
	if beamVFX.beam and beamVFX.beam.Parent
		and beamVFX.impact and beamVFX.impact.Parent
	then
		return
	end

	if beamVFX.beam then beamVFX.beam:Destroy() end
	if beamVFX.impact then beamVFX.impact:Destroy() end

	local beam = Instance.new("Part")
	beam.Name = BEAM_PART_NAME
	beam.Anchored = true
	beam.CanCollide = false
	beam.CanQuery = false
	beam.CanTouch = false
	beam.Material = Enum.Material.Neon
	beam.Color = Color3.fromRGB(255, 150, 60)
	beam.Transparency = 0.35
	beam.Parent = workspace

	local impact = Instance.new("Part")
	impact.Name = IMPACT_PART_NAME
	impact.Shape = Enum.PartType.Ball
	impact.Size = Vector3.new(2, 2, 2)
	impact.Anchored = true
	impact.CanCollide = false
	impact.CanQuery = false
	impact.CanTouch = false
	impact.Material = Enum.Material.Neon
	impact.Color = Color3.fromRGB(255, 210, 120)
	impact.Transparency = 0.05
	impact.Parent = workspace

	local light = Instance.new("PointLight")
	light.Brightness = 5
	light.Range = 16
	light.Color = Color3.fromRGB(255, 170, 90)
	light.Parent = impact

	local emitter = Instance.new("ParticleEmitter")
	emitter.Rate = 90
	emitter.Lifetime = NumberRange.new(0.2, 0.5)
	emitter.Speed = NumberRange.new(10, 22)
	emitter.SpreadAngle = Vector2.new(180, 180)
	emitter.Size = NumberSequence.new(0.35)
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.Color = ColorSequence.new(
		Color3.fromRGB(255, 220, 140),
		Color3.fromRGB(255, 70, 20)
	)
	emitter.LightEmission = 1
	emitter.LightInfluence = 0
	emitter.Parent = impact

	beamVFX.beam = beam
	beamVFX.impact = impact
end

local function updateBeamVFX(origin, endpoint)
	local delta = endpoint - origin
	local length = delta.Magnitude
	if length < 0.5 then return end

	ensureBeamVFX()

	beamVFX.beam.Size = Vector3.new(0.25, 0.25, length)
	beamVFX.beam.CFrame = CFrame.new(origin + delta * 0.5, endpoint)

	-- throb the impact so it feels alive instead of a static ball
	local pulse = 1 + math.sin(os.clock() * 22) * 0.18
	beamVFX.impact.Size = Vector3.new(2 * pulse, 2 * pulse, 2 * pulse)
	beamVFX.impact.CFrame = CFrame.new(endpoint)

	beamVFX.expiresAt = os.clock() + 0.3
end

local function hideBeamVFX()
	if beamVFX.beam then beamVFX.beam:Destroy() end
	if beamVFX.impact then beamVFX.impact:Destroy() end
	beamVFX.beam = nil
	beamVFX.impact = nil
end

local remoteBeams = {} -- [userId] = { beam, impact, expiresAt }

local function ensureRemoteBeam(userId)
	local entry = remoteBeams[userId]
	if entry
		and entry.beam and entry.beam.Parent
		and entry.impact and entry.impact.Parent
	then
		return entry
	end

	if entry then
		if entry.beam then entry.beam:Destroy() end
		if entry.impact then entry.impact:Destroy() end
	end

	local beam = Instance.new("Part")
	beam.Name = REMOTE_BEAM_PREFIX .. userId
	beam.Anchored = true
	beam.CanCollide = false
	beam.CanQuery = false
	beam.CanTouch = false
	beam.Material = Enum.Material.Neon
	beam.Color = Color3.fromRGB(255, 120, 50)
	beam.Transparency = 0.4
	beam.Parent = workspace

	local impact = Instance.new("Part")
	impact.Name = REMOTE_IMPACT_PREFIX .. userId
	impact.Shape = Enum.PartType.Ball
	impact.Size = Vector3.new(1.6, 1.6, 1.6)
	impact.Anchored = true
	impact.CanCollide = false
	impact.CanQuery = false
	impact.CanTouch = false
	impact.Material = Enum.Material.Neon
	impact.Color = Color3.fromRGB(255, 200, 110)
	impact.Transparency = 0.15
	impact.Parent = workspace

	local newEntry = { beam = beam, impact = impact, expiresAt = 0 }
	remoteBeams[userId] = newEntry
	return newEntry
end

local function updateRemoteBeam(userId, origin, endpoint)
	local delta = endpoint - origin
	local length = delta.Magnitude
	if length < 0.5 then return end

	local entry = ensureRemoteBeam(userId)
	entry.beam.Size = Vector3.new(0.25, 0.25, length)
	entry.beam.CFrame = CFrame.new(origin + delta * 0.5, endpoint)
	entry.impact.CFrame = CFrame.new(endpoint)
	entry.expiresAt = os.clock() + 0.4
end

local function killRemoteBeam(userId)
	local entry = remoteBeams[userId]
	if not entry then return end
	if entry.beam then entry.beam:Destroy() end
	if entry.impact then entry.impact:Destroy() end
	remoteBeams[userId] = nil
end

task.spawn(function()
	while true do
		task.wait(0.2)
		local now = os.clock()
		for userId, entry in pairs(remoteBeams) do
			if entry.expiresAt < now then
				entry.beam:Destroy()
				entry.impact:Destroy()
				remoteBeams[userId] = nil
			end
		end
		if beamVFX.beam and beamVFX.expiresAt < now then
			hideBeamVFX()
		end
	end
end)

repRemote.OnClientEvent:Connect(function(buf)
	if typeof(buf) ~= "buffer" or buffer.len(buf) < 1 then return end
	local kind = buffer.readu8(buf, 0)

	if kind == VFX_EXPLOSION and buffer.len(buf) == 21 then
		local pos = Vector3.new(
			buffer.readf32(buf, 5),
			buffer.readf32(buf, 9),
			buffer.readf32(buf, 13)
		)
		local radius = buffer.readf32(buf, 17)
		playExplosion(pos, radius)

	elseif kind == VFX_BEAM and buffer.len(buf) == 37 then
		local senderId = buffer.readu32(buf, 5)
		if senderId == localUserId then
			-- the server already skips the caster, but if that ever changes
			-- we don't want to double-draw against the local preview
			killRemoteBeam(localUserId)
			return
		end

		local origin = Vector3.new(
			buffer.readf32(buf, 9),
			buffer.readf32(buf, 13),
			buffer.readf32(buf, 17)
		)
		local endpoint = Vector3.new(
			buffer.readf32(buf, 21),
			buffer.readf32(buf, 25),
			buffer.readf32(buf, 29)
		)
		updateRemoteBeam(senderId, origin, endpoint)
	end
end)

----------------------------------------------------------------
-- local beam preview
----------------------------------------------------------------

local function updateLocalBeam()
	local char = player.Character
	if not char then return end
	local root = char:FindFirstChild("HumanoidRootPart")
	if not root then return end

	local origin = root.Position + Vector3.new(0, 1, 0)

	local rp = RaycastParams.new()
	rp.FilterType = Enum.RaycastFilterType.Exclude
	rp.FilterDescendantsInstances = { char }

	local dir = camera.CFrame.LookVector
	local hit = workspace:Raycast(origin, dir * 200, rp)
	local endpoint = hit and hit.Position or (origin + dir * 200)

	updateBeamVFX(origin, endpoint)
end

----------------------------------------------------------------
-- cooldown readout
----------------------------------------------------------------

task.spawn(function()
	while true do
		task.wait(0.1)

		if beamHeld then
			setStatus("Channeling beam", Color3.fromRGB(255, 130, 60))
		else
			local left = explosionCooldownUntil - os.clock()
			if left > 0 then
				setStatus(string.format("Explosion ready in %.1fs", left), Color3.fromRGB(230, 180, 90))
			else
				setStatus("Ready", Color3.fromRGB(120, 220, 120))
			end
		end
	end
end)

----------------------------------------------------------------
-- input
----------------------------------------------------------------

local mouse = player:GetMouse()

local function startBeam()
	if beamHeld then return end

	-- client-side gates mirror the server's. without these the client
	-- would draw a beam the server never accepts (no drain, no terrain
	-- damage) and the effect would look broken.
	local currentMana = player:GetAttribute("Mana") or MANA_MAX
	if currentMana < BEAM_MIN_MANA then return end
	if (os.clock() - beamLastStartAt) < BEAM_COOLDOWN then return end

	beamHeld = true
	beamLastStartAt = os.clock()

	task.spawn(function()
		while beamHeld do
			reqBeam:FireServer(camera.CFrame.LookVector)
			task.wait(0.1)
		end
	end)
end

stopBeam = function()
	if not beamHeld then return end
	beamHeld = false
	reqBeam:FireServer(nil)
	hideBeamVFX()
end

local explosionPendingUntil = 0

local function castExplosion()
	local now = os.clock()
	-- blocks repeat clicks while the server ack is in flight, and self-
	-- clears after ACK_TIMEOUT in case the reply never arrives (player
	-- left mid-cast, remote recreated, etc.)
	if now < explosionPendingUntil then return end
	if now < explosionCooldownUntil then return end

	local currentMana = player:GetAttribute("Mana") or MANA_MAX
	if currentMana < EXPLOSION_MANA then
		print(string.format("[Explosion] blocked: mana %d < %d", currentMana, EXPLOSION_MANA))
		return
	end

	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if not root then
		print("[Explosion] blocked: no character")
		return
	end

	local targetPos = mouse.Hit.Position
	local dist = (targetPos - root.Position).Magnitude

	if dist > MAX_CAST_DISTANCE then
		print(string.format("[Explosion] blocked: distance %.1f > %d", dist, MAX_CAST_DISTANCE))
		return
	end

	local rp = RaycastParams.new()
	rp.FilterType = Enum.RaycastFilterType.Exclude
	rp.FilterDescendantsInstances = { char }
	rp.IgnoreWater = true
	local hit = workspace:Raycast(root.Position, targetPos - root.Position, rp)

	-- mirror the server's LOS: only enforce above LOS_MIN_DIST, and only
	-- when the ray actually stopped short of the target. Any hit at or
	-- past the target's depth means nothing is between caster and target.
	if hit and dist >= LOS_MIN_DIST then
		local rayLen = (hit.Position - root.Position).Magnitude
		if rayLen < dist - LOS_TOLERANCE then
			print(string.format("[Explosion] blocked: line of sight (gap %.1f)",
				dist - rayLen))
			return
		end
	end

	-- cooldown is NOT committed here. The server has the final say and
	-- will echo back ok/reason. Committing locally used to strand the
	-- player in a 6s lockout whenever server-side gates disagreed.
	explosionPendingUntil = now + EXPLOSION_ACK_TIMEOUT
	reqExplosion:FireServer(targetPos, BLAST_RADIUS)
end

reqExplosion.OnClientEvent:Connect(function(ok, reason)
	explosionPendingUntil = 0

	if ok then
		explosionCooldownUntil = os.clock() + EXPLOSION_COOLDOWN
		if reason then
			-- accepted but worth surfacing — e.g. "fired, nothing in range"
			print("[Explosion] " .. reason)
		end
	else
		print("[Explosion] rejected: " .. tostring(reason or "unknown"))
	end
end)

UserInputService.InputBegan:Connect(function(input, processed)
	if processed then return end

	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		castExplosion()
	elseif input.UserInputType == Enum.UserInputType.MouseButton2 then
		startBeam()
	end
end)

UserInputService.InputEnded:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton2 then
		stopBeam()
	end
end)

RunService.RenderStepped:Connect(function()
	if beamHeld then
		updateLocalBeam()
	end
end)

-- sweep leftover named beam parts from a previous session or a client
-- that disconnected mid-channel
for _, obj in ipairs(workspace:GetChildren()) do
	if obj.Name == BEAM_PART_NAME or obj.Name == IMPACT_PART_NAME then
		obj:Destroy()
	elseif obj.Name:sub(1, #REMOTE_BEAM_PREFIX) == REMOTE_BEAM_PREFIX then
		obj:Destroy()
	elseif obj.Name:sub(1, #REMOTE_IMPACT_PREFIX) == REMOTE_IMPACT_PREFIX then
		obj:Destroy()
	end
end

player.CharacterRemoving:Connect(function()
	if beamHeld then
		stopBeam()
	end
end)