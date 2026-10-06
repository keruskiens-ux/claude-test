--[[
	RodFX.lua  ·  client effects for Oddtide rods built by RodBuilder (ArtRevision "new1")

	Put this ModuleScript where LocalScripts can require it (e.g. ReplicatedStorage).
	Everything it does is local to the client and is fully undone by :destroy().

		local RodFX = require(ReplicatedStorage.RodFX)

		local fx = RodFX.attach(tool, reducedMotion) -- once per tool
		fx:equip()             -- burst + glow ramp-up, starts the idle animation
		fx:charge(alpha)       -- 0..1, call every frame while the cast charges
		fx:cast()              -- burst at the tip + glowing trail
		fx:bite()              -- flare + shake
		fx:reel(true)          -- intense glow, energy flowing up the rod (false to stop)
		fx:catch("Legendary")  -- explosion + light flash (rarity name or 1-7); tier 4 adds shockwaves
		fx:unequip()           -- back to the resting look, keeps the controller
		fx:setReducedMotion(true)
		fx:destroy()           -- restores everything and disconnects

	reducedMotion: 40% of the particles, half-strength floating/spinning, no shake.

	How the rod is read (all set by RodBuilder):
	  * ParticleEmitters/Beams/Trails are grouped by name prefix:
	    Idle* Equip* Charge* Cast* Bite* Reel* Catch*. Beams named IdleArc* crackle.
	  * Bursts emit their BurstCount attribute (delayed by BurstDelay seconds if set).
	  * PointLights named GlowLight follow the glow level; FlashLight flashes on catch.
	  * Parts with FXGlow pulse; parts with FXPivot float/spin/sway/scale.
	    Moving parts are driven by a client-only Weld while equipped (their WeldConstraint is
	    switched off locally and switched back on when the rod rests).
]]

local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local RodFX = {}

local MOMENTS = { "Idle", "Equip", "Charge", "Cast", "Bite", "Reel", "Catch" }
local REDUCED_PARTICLES = 0.4
local REDUCED_MOTION = 0.5
local MAX_BURST = 300
local SHAKE_TIME = 0.45
local TRAIL_TIME = 0.9

local RARITY_LEVELS = {
	common = 1,
	uncommon = 2,
	rare = 3,
	epic = 4,
	legendary = 5,
	mythic = 6,
	mythical = 6,
	exotic = 7,
	secret = 7,
	divine = 7,
}

local BLACK = Color3.new(0, 0, 0)
local WHITE = Color3.new(1, 1, 1)
local TAU = math.pi * 2
local random = Random.new()

local function momentOf(name)
	for _, moment in ipairs(MOMENTS) do
		if string.sub(name, 1, #moment) == moment then
			return moment
		end
	end
	return nil
end

-- 1 for common up to ~3.1 for the rarest catches.
local function rarityMultiplier(rarity)
	local level = 1
	if type(rarity) == "number" then
		level = rarity
	elseif type(rarity) == "string" then
		level = RARITY_LEVELS[string.lower(rarity)] or 1
	end
	return 1 + (math.clamp(level, 1, 7) - 1) * 0.35
end

-- Pulse waveforms, roughly -1..1. `cycles` is time multiplied by frequency.
local function pulseWave(shape, cycles)
	if shape == "heartbeat" then
		local p = cycles % 1
		local beat = math.exp(-((p - 0.1) / 0.05) ^ 2) + 0.7 * math.exp(-((p - 0.32) / 0.06) ^ 2)
		return beat * 2 - 0.6
	elseif shape == "flicker" then
		local t = cycles * TAU
		return math.sin(t * 2.1) * 0.4 + math.sin(t * 3.7 + 1.3) * 0.35 + math.sin(t * 7.3 + 0.4) * 0.25
	end
	return math.sin(cycles * TAU)
end

-- Below 1 the neon dims toward black; above 1 it runs hot toward white.
local function glowColor(base, level)
	if level <= 1 then
		return BLACK:Lerp(base, 0.25 + 0.75 * math.max(level, 0))
	end
	return base:Lerp(WHITE, math.min((level - 1) * 0.45, 0.7))
end

local function findGripWeld(tool, handle)
	local character = tool.Parent
	if not character then
		return nil
	end
	for _, limbName in ipairs({ "RightHand", "Right Arm" }) do
		local limb = character:FindFirstChild(limbName)
		local grip = limb and limb:FindFirstChild("RightGrip")
		if grip and grip:IsA("JointInstance") and grip.Part1 == handle then
			return grip
		end
	end
	return nil
end

local Controller = {}
Controller.__index = Controller

function RodFX.attach(tool, reducedMotion)
	local self = setmetatable({ destroyed = true }, Controller)
	if not RunService:IsClient() then
		warn("[RodFX] attach() only works on the client.")
		return self
	end
	local handle = if tool then tool:FindFirstChild("Handle") else nil
	if not handle or not handle:IsA("BasePart") then
		warn(("[RodFX] %s has no Handle; effects disabled."):format(if tool then tool:GetFullName() else "nil"))
		return self
	end

	self.destroyed = false
	self.tool = tool
	self.handle = handle
	self.reducedMotion = reducedMotion == true
	self.equipped = false

	self.clock = 0
	self.glowLevel = 1
	self.glowTarget = 1
	self.glowFlash = 0
	self.kick = 1
	self.chargeAlpha = 0
	self.reeling = false
	self.motionTime = 0
	self.trailOffAt = nil
	self.nextIdleRing = 0
	self.gripWeld = nil
	self.shakeUntil = 0

	self.scheduled = {}
	self.tweens = {}
	self.temporary = {}
	self.connections = {}

	self.tier = tool:GetAttribute("Tier") or 1
	self.accent = tool:GetAttribute("AccentColor") or WHITE
	self.pulseShape = tool:GetAttribute("FXPulseShape") or "sine"
	self.pulseSpeed = tool:GetAttribute("FXPulseSpeed") or 0.5
	self.pulseDepth = tool:GetAttribute("FXPulseDepth") or 0.25
	self.catchRings = tool:GetAttribute("FXCatchRings") or 0
	self.ringSize = tool:GetAttribute("FXRingSize") or 10
	self.idleRingPeriod = tool:GetAttribute("FXIdleRingPeriod") or 0
	local core = tool:FindFirstChild("Core", true)
	self.core = if core and core:IsA("Attachment") then core else nil

	self:_collect()

	table.insert(
		self.connections,
		RunService.RenderStepped:Connect(function(deltaTime)
			self:_step(deltaTime)
		end)
	)
	table.insert(
		self.connections,
		tool.Destroying:Connect(function()
			self:destroy()
		end)
	)
	return self
end

--------------------------------------------------------------------------------
-- Setup
--------------------------------------------------------------------------------

function Controller:_collect()
	self.emitters = {}
	for _, moment in ipairs(MOMENTS) do
		self.emitters[moment] = {}
	end
	self.emitterState = {}
	self.beamState = {}
	self.arcs = {}
	self.idleBeams = {}
	self.reelBeams = {}
	self.trails = {}
	self.trailState = {}
	self.glowLights = {}
	self.flashLights = {}
	self.lightState = {}
	self.glowParts = {}
	self.motions = {}

	local handleCFrame = self.handle.CFrame
	for _, item in ipairs(self.tool:GetDescendants()) do
		if item:IsA("ParticleEmitter") then
			local moment = momentOf(item.Name)
			if moment then
				table.insert(self.emitters[moment], item)
				self.emitterState[item] = { Enabled = item.Enabled, Rate = item.Rate }
			end
		elseif item:IsA("Beam") then
			self.beamState[item] = {
				Enabled = item.Enabled,
				CurveSize0 = item.CurveSize0,
				CurveSize1 = item.CurveSize1,
				Transparency = item.Transparency,
			}
			local moment = momentOf(item.Name)
			if string.sub(item.Name, 1, 7) == "IdleArc" then
				table.insert(self.arcs, { beam = item, nextFlip = 0 })
			elseif moment == "Idle" then
				table.insert(self.idleBeams, item)
			elseif moment == "Reel" then
				table.insert(self.reelBeams, item)
			end
		elseif item:IsA("Trail") then
			if momentOf(item.Name) == "Cast" then
				table.insert(self.trails, item)
				self.trailState[item] = item.Enabled
			end
		elseif item:IsA("Light") then
			if string.sub(item.Name, 1, 9) == "GlowLight" then
				table.insert(self.glowLights, item)
				self.lightState[item] = item.Brightness
			elseif string.sub(item.Name, 1, 10) == "FlashLight" then
				table.insert(self.flashLights, item)
				self.lightState[item] = item.Brightness
			end
		elseif item:IsA("BasePart") and item ~= self.handle then
			if item:GetAttribute("FXGlow") then
				table.insert(self.glowParts, {
					part = item,
					color = item.Color,
					phase = item:GetAttribute("FXGlowPhase") or 0,
				})
			end
			local pivot = item:GetAttribute("FXPivot")
			if typeof(pivot) == "Vector3" then
				local spin = item:GetAttribute("FXSpin") or 0
				local swayAngle = item:GetAttribute("FXSwayAngle") or 0
				local bobDistance = item:GetAttribute("FXBobDistance") or 0
				table.insert(self.motions, {
					part = item,
					base = handleCFrame:ToObjectSpace(item.CFrame),
					size = item.Size,
					pivot = pivot,
					axis = item:GetAttribute("FXAxis") or Vector3.yAxis,
					spin = spin,
					swayAngle = swayAngle,
					swaySpeed = item:GetAttribute("FXSwaySpeed") or 1.5,
					bobDistance = bobDistance,
					bobSpeed = item:GetAttribute("FXBobSpeed") or 1.5,
					bobAxis = item:GetAttribute("FXBobAxis") or Vector3.yAxis,
					phase = item:GetAttribute("FXPhase") or 0,
					scalePulse = item:GetAttribute("FXScalePulse") or 0,
					moves = spin ~= 0 or swayAngle ~= 0 or bobDistance ~= 0,
					spinAngle = 0,
					weld = nil,
					constraints = {},
				})
			end
		end
	end
end

-- Moving parts get a client-only Weld we can animate; their WeldConstraint is paused.
function Controller:_startMotion()
	for _, record in ipairs(self.motions) do
		if record.moves and not record.weld then
			local weld = Instance.new("Weld")
			weld.Name = "RodFXMotion"
			weld.Part0 = self.handle
			weld.Part1 = record.part
			weld.C0 = record.base
			weld.Parent = record.part
			record.weld = weld
			record.spinAngle = 0
			record.constraints = {}
			for _, child in ipairs(record.part:GetChildren()) do
				if child:IsA("WeldConstraint") and child.Enabled then
					child.Enabled = false
					table.insert(record.constraints, child)
				end
			end
		end
	end
end

function Controller:_stopMotion()
	local handleCFrame = self.handle.CFrame
	for _, record in ipairs(self.motions) do
		if record.weld then
			-- Remove our weld first so the part can be put back exactly where it was built,
			-- then let its WeldConstraint lock that position in again.
			record.weld:Destroy()
			record.weld = nil
			record.part.CFrame = handleCFrame * record.base
			for _, constraint in ipairs(record.constraints) do
				constraint.Enabled = true
			end
			record.constraints = {}
		end
		if record.scalePulse ~= 0 then
			record.part.Size = record.size
		end
	end
end

--------------------------------------------------------------------------------
-- Per-frame
--------------------------------------------------------------------------------

function Controller:_step(deltaTime)
	if self.destroyed then
		return
	end
	local dt = math.min(deltaTime, 0.1)
	self.clock += dt
	self:_runScheduled()

	if self.trailOffAt and self.clock >= self.trailOffAt then
		self.trailOffAt = nil
		for _, trail in ipairs(self.trails) do
			trail.Enabled = false
		end
	end
	if not self.equipped then
		return
	end

	self.glowLevel += (self.glowTarget - self.glowLevel) * (1 - math.exp(-dt * 5))
	self.glowFlash *= math.exp(-dt * 3.5)
	self.kick = 1 + (self.kick - 1) * math.exp(-dt * 2.5)

	local speed = 1 + self.chargeAlpha * 1.2 + (if self.reeling then 0.8 else 0)
	self:_updateMotion(dt * speed)
	self:_updateGlow()
	self:_updateArcs()
	self:_updateShake()

	if self.idleRingPeriod > 0 and self.clock >= self.nextIdleRing then
		self.nextIdleRing = self.clock + self.idleRingPeriod
		self:_spawnRing(0.45, 0.6, 1)
	end
end

function Controller:_updateMotion(motionDelta)
	local amplitude = if self.reducedMotion then REDUCED_MOTION else 1
	self.motionTime += motionDelta
	local t = self.motionTime
	local pulse = pulseWave(self.pulseShape, self.clock * self.pulseSpeed)
	for _, record in ipairs(self.motions) do
		if record.weld then
			record.spinAngle += record.spin * motionDelta * amplitude
			local wave = math.sin(record.swaySpeed * t + record.phase)
			local angle = record.spinAngle + record.swayAngle * amplitude * self.kick * wave
			local rotation = CFrame.new(record.pivot)
				* CFrame.fromAxisAngle(record.axis, angle)
				* CFrame.new(-record.pivot)
			local bob = record.bobAxis
				* (record.bobDistance * amplitude * self.kick * math.sin(record.bobSpeed * t + record.phase))
			record.weld.C0 = CFrame.new(bob) * rotation * record.base
		end
		if record.scalePulse ~= 0 then
			record.part.Size = record.size * (1 + record.scalePulse * amplitude * pulse)
		end
	end
end

function Controller:_updateGlow()
	local level = self.glowLevel + self.glowFlash
	local cycles = self.clock * self.pulseSpeed
	for _, glow in ipairs(self.glowParts) do
		local wave = pulseWave(self.pulseShape, cycles + glow.phase)
		glow.part.Color = glowColor(glow.color, level * (1 + self.pulseDepth * wave))
	end
	local lightLevel = math.max(0, level * (1 + self.pulseDepth * pulseWave(self.pulseShape, cycles)))
	for _, light in ipairs(self.glowLights) do
		light.Brightness = self.lightState[light] * lightLevel
	end
end

function Controller:_updateArcs()
	if #self.arcs == 0 then
		return
	end
	local energy = 0.4 + self.chargeAlpha * 0.6 + (if self.reeling then 0.5 else 0)
	local calm = if self.reducedMotion then 2.5 else 1
	for _, arc in ipairs(self.arcs) do
		if self.clock >= arc.nextFlip then
			arc.nextFlip = self.clock + random:NextNumber(0.04, 0.12) * calm
			local beam = arc.beam
			beam.CurveSize0 = random:NextNumber(-0.6, 0.6) * energy
			beam.CurveSize1 = random:NextNumber(-0.6, 0.6) * energy
			beam.Transparency = NumberSequence.new(random:NextNumber(0, 0.35))
			beam.Enabled = random:NextNumber() > 0.15
		end
	end
end

function Controller:_startShake()
	local weld = self.gripWeld or findGripWeld(self.tool, self.handle)
	if weld then
		self.gripWeld = weld
		self.shakeUntil = self.clock + SHAKE_TIME
	end
end

function Controller:_updateShake()
	local weld = self.gripWeld
	if not weld then
		return
	end
	if self.clock < self.shakeUntil then
		local strength = 0.07 * (self.shakeUntil - self.clock) / SHAKE_TIME
		weld.C1 = self.tool.Grip
			* CFrame.Angles(random:NextNumber(-strength, strength), 0, random:NextNumber(-strength, strength))
	else
		self:_endShake()
	end
end

function Controller:_endShake()
	if self.gripWeld then
		self.gripWeld.C1 = self.tool.Grip
		self.gripWeld = nil
	end
	self.shakeUntil = 0
end

--------------------------------------------------------------------------------
-- Building blocks
--------------------------------------------------------------------------------

function Controller:_schedule(delay, callback)
	table.insert(self.scheduled, { at = self.clock + delay, callback = callback })
end

function Controller:_runScheduled()
	if #self.scheduled == 0 then
		return
	end
	local due = {}
	local waiting = {}
	for _, item in ipairs(self.scheduled) do
		table.insert(if self.clock >= item.at then due else waiting, item)
	end
	self.scheduled = waiting
	for _, item in ipairs(due) do
		item.callback()
	end
end

function Controller:_particleScale()
	return if self.reducedMotion then REDUCED_PARTICLES else 1
end

function Controller:_burst(moment, multiplier)
	local scale = (multiplier or 1) * self:_particleScale()
	for _, emitter in ipairs(self.emitters[moment]) do
		local count = math.clamp(math.floor((emitter:GetAttribute("BurstCount") or 12) * scale + 0.5), 1, MAX_BURST)
		local delay = emitter:GetAttribute("BurstDelay") or 0
		if delay > 0 then
			self:_schedule(delay, function()
				emitter:Emit(count)
			end)
		else
			emitter:Emit(count)
		end
	end
end

function Controller:_setLoop(moment, enabled, rateScale)
	local scale = (rateScale or 1) * self:_particleScale()
	for _, emitter in ipairs(self.emitters[moment]) do
		emitter.Rate = self.emitterState[emitter].Rate * scale
		emitter.Enabled = enabled
	end
end

function Controller:_retarget()
	self.glowTarget = if self.reeling then 1.7 else 1 + 0.9 * self.chargeAlpha
end

function Controller:_play(tween, onDone)
	self.tweens[tween] = true
	tween.Completed:Connect(function()
		self.tweens[tween] = nil
		if onDone then
			onDone()
		end
	end)
	tween:Play()
end

function Controller:_flash(strength)
	for _, light in ipairs(self.flashLights) do
		light.Brightness = 3 + 2 * strength
		self:_play(TweenService:Create(light, TweenInfo.new(0.45 + 0.1 * strength, Enum.EasingStyle.Quad), {
			Brightness = self.lightState[light],
		}))
	end
end

-- A flat ForceField disc that expands from the hero piece: reads as a glowing ring.
function Controller:_spawnRing(sizeScale, startTransparency, duration)
	local position = if self.core then self.core.WorldPosition else self.handle.Position
	local diameter = self.ringSize * sizeScale
	local ring = Instance.new("Part")
	ring.Name = "RodFXRing"
	ring.Shape = Enum.PartType.Cylinder
	ring.Material = Enum.Material.ForceField
	ring.Color = self.accent
	ring.Transparency = startTransparency
	ring.Anchored = true
	ring.CanCollide = false
	ring.CanQuery = false
	ring.CanTouch = false
	ring.CastShadow = false
	ring.Size = Vector3.new(0.2, 0.6, 0.6)
	ring.CFrame = CFrame.new(position) * CFrame.Angles(0, 0, math.pi / 2)
	ring.Parent = Workspace.CurrentCamera or Workspace
	self.temporary[ring] = true
	local tween = TweenService:Create(ring, TweenInfo.new(duration, Enum.EasingStyle.Quart, Enum.EasingDirection.Out), {
		Size = Vector3.new(0.2, diameter, diameter),
		Transparency = 1,
	})
	self:_play(tween, function()
		self.temporary[ring] = nil
		ring:Destroy()
	end)
end

-- Puts every effect back exactly how RodBuilder left it.
function Controller:_rest()
	self.chargeAlpha = 0
	self.reeling = false
	self.trailOffAt = nil
	self.kick = 1
	self.glowFlash = 0
	table.clear(self.scheduled)
	for emitter, state in pairs(self.emitterState) do
		emitter.Rate = state.Rate
		emitter.Enabled = state.Enabled
	end
	for beam, state in pairs(self.beamState) do
		beam.Enabled = state.Enabled
		beam.CurveSize0 = state.CurveSize0
		beam.CurveSize1 = state.CurveSize1
		beam.Transparency = state.Transparency
	end
	for trail, enabled in pairs(self.trailState) do
		trail.Enabled = enabled
	end
	for light, brightness in pairs(self.lightState) do
		light.Brightness = brightness
	end
	for _, glow in ipairs(self.glowParts) do
		glow.part.Color = glow.color
	end
	self:_stopMotion()
	self:_endShake()
end

function Controller:_ensureEquipped()
	if not self.equipped then
		self:equip(true)
	end
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

function Controller:equip(quiet)
	if self.destroyed or self.equipped then
		return
	end
	self.equipped = true
	self.chargeAlpha = 0
	self.reeling = false
	self.glowTarget = 1
	self:_startMotion()
	self:_setLoop("Idle", true)
	for _, beam in ipairs(self.idleBeams) do
		beam.Enabled = true
	end
	self.nextIdleRing = self.clock + 1
	if quiet then
		self.glowLevel = 1
	else
		self.glowLevel = 0.15
		self.glowFlash = 0.8
		self:_burst("Equip")
	end
end

function Controller:unequip()
	if self.destroyed or not self.equipped then
		return
	end
	self.equipped = false
	self:_rest()
end

function Controller:charge(alpha)
	if self.destroyed then
		return
	end
	self:_ensureEquipped()
	self.chargeAlpha = math.clamp(tonumber(alpha) or 0, 0, 1)
	self:_setLoop("Charge", self.chargeAlpha > 0.02, 0.25 + self.chargeAlpha)
	self:_retarget()
end

function Controller:cast()
	if self.destroyed then
		return
	end
	self:_ensureEquipped()
	self.chargeAlpha = 0
	self:_setLoop("Charge", false)
	self:_burst("Cast")
	for _, trail in ipairs(self.trails) do
		trail:Clear()
		trail.Enabled = true
	end
	self.trailOffAt = self.clock + TRAIL_TIME
	self.glowFlash = math.max(self.glowFlash, 1.2)
	self.kick = math.max(self.kick, 1.6)
	self:_retarget()
end

function Controller:bite()
	if self.destroyed then
		return
	end
	self:_ensureEquipped()
	self:_burst("Bite")
	self.glowFlash = math.max(self.glowFlash, 1.5)
	self.kick = math.max(self.kick, 2.2)
	if not self.reducedMotion then
		self:_startShake()
	end
end

function Controller:reel(isReeling)
	if self.destroyed then
		return
	end
	self:_ensureEquipped()
	self.reeling = isReeling == true
	self:_setLoop("Reel", self.reeling)
	for _, beam in ipairs(self.reelBeams) do
		beam.Enabled = self.reeling
	end
	if self.reeling and self.chargeAlpha > 0 then
		self.chargeAlpha = 0
		self:_setLoop("Charge", false)
	end
	self:_retarget()
end

function Controller:catch(rarity)
	if self.destroyed then
		return
	end
	self:_ensureEquipped()
	self:reel(false)
	local multiplier = rarityMultiplier(rarity)
	self:_burst("Catch", multiplier)
	self.glowFlash = 1.5 + multiplier * 0.5
	self.kick = math.max(self.kick, 3)
	self:_flash(multiplier)
	for i = 1, self.catchRings do
		self:_schedule((i - 1) * 0.15, function()
			self:_spawnRing(1 + (multiplier - 1) * 0.15, 0.1, 0.6 + i * 0.1)
		end)
	end
end

function Controller:setReducedMotion(enabled)
	if self.destroyed then
		return
	end
	self.reducedMotion = enabled == true
	if self.equipped then
		self:_setLoop("Idle", true)
		if self.reeling then
			self:_setLoop("Reel", true)
		end
		if self.chargeAlpha > 0.02 then
			self:_setLoop("Charge", true, 0.25 + self.chargeAlpha)
		end
	end
	if self.reducedMotion then
		self:_endShake()
	end
end

function Controller:destroy()
	if self.destroyed then
		return
	end
	self.equipped = false
	self:_rest()
	self.destroyed = true

	for _, connection in ipairs(self.connections) do
		connection:Disconnect()
	end
	table.clear(self.connections)

	local running = {}
	for tween in pairs(self.tweens) do
		table.insert(running, tween)
	end
	for _, tween in ipairs(running) do
		tween:Cancel()
	end
	table.clear(self.tweens)
	for part in pairs(self.temporary) do
		part:Destroy()
	end
	table.clear(self.temporary)
	-- Cancelled flash tweens stop mid-way, so put the lights back once more.
	for light, brightness in pairs(self.lightState) do
		light.Brightness = brightness
	end
end

return RodFX
