--[[
	RodBuilder.lua  ·  Oddtide rod drafts (ArtRevision "new1")

	HOW TO RUN
	  Roblox Studio > View > Command Bar. Paste this whole file and press Enter.
	  It builds 10 rods as Tools into  game.ServerStorage.NewRodDrafts.
	  It only creates (or replaces) that one folder and touches nothing else.
	  It sets a ChangeHistory waypoint, so Ctrl+Z should undo it.
	  If the Command Bar won't take a paste this long: put the file in a ModuleScript named
	  RodBuilder anywhere outside a running game, then run  require(<that ModuleScript>)
	  in the Command Bar (re-running needs a fresh copy of the ModuleScript; require caches).

	CONVENTIONS (RodFX.lua relies on these)
	  * The Handle is the grip: a 1.2-stud cylinder, 0.4 studs thick.
	  * Every rod is modelled in "rod space": +Y runs from the grip to the tip,
	    the reel hangs on -Z, the hero piece reads best seen from +Z.
	    Tool.Grip is set so the rod points forward and up (GRIP_TILT_DEGREES).
	  * Attachment "Tip"  = where the fishing line leaves the rod.
	    Attachment "Core" = centre of the hero piece (bursts and lights live there).
	  * Effects are named by the moment they belong to:
	      Idle*   ParticleEmitters/Beams that run while the rod is held
	      Equip*  Charge*  Cast*  Bite*  Reel*  Catch*   (emitters, trails, beams)
	      GlowLight (PointLight, follows the glow level)  FlashLight (PointLight, catch flash)
	    Burst emitters have a BurstCount attribute (and optional BurstDelay, seconds).
	  * Parts with the attribute FXGlow = true are the neon accent; RodFX pulses them.
	  * Parts with FXPivot/FXAxis + FXSpin/FXSwayAngle/FXBobDistance float, spin or sway.
	    FXPivot and FXAxis are in the Handle's object space.
	  * Tool attributes: OddtideRod, RodId, ArtRevision, Tier, AccentColor,
	    FXPulseShape ("sine" | "flicker" | "heartbeat"), FXPulseSpeed (Hz), FXPulseDepth,
	    FXCatchRings (shockwave rings on catch), FXRingSize, FXIdleRingPeriod.

	Only Parts, WedgeParts, cylinders and balls. No meshes, no uploaded images;
	particles use built-in rbxasset:// textures.
]]

local ServerStorage = game:GetService("ServerStorage")
local ChangeHistoryService = game:GetService("ChangeHistoryService")

local FOLDER_NAME = "NewRodDrafts"
local ART_REVISION = "new1"
local GRIP_TILT_DEGREES = 45 -- how far the rod leans forward from straight up when held
local MAX_PARTS = 60
local ROD_SPACING = 6 -- studs between rods if you drag the whole folder into Workspace

local TEXTURE = {
	Sparkle = "rbxasset://textures/particles/sparkles_main.dds",
	Smoke = "rbxasset://textures/particles/smoke_main.dds",
	Fire = "rbxasset://textures/particles/fire_main.dds",
}

local rgb = Color3.fromRGB
local v3 = Vector3.new
local Mat = Enum.Material
local UP = Vector3.new(0, 1, 0)
local WHITE = Color3.new(1, 1, 1)

-- Roblox cylinders run along their X axis, so the Handle is turned to lie along rod +Y.
local HANDLE_IN_ROD = CFrame.Angles(0, 0, math.pi / 2)
-- Hand frame -> rod: lean the rod's +Y forward by GRIP_TILT_DEGREES (forward is -Z in the hand frame).
local GRIP = (CFrame.Angles(-math.rad(GRIP_TILT_DEGREES), 0, 0) * HANDLE_IN_ROD):Inverse()

-- Hanging pieces (lanterns, lures, chains) are modelled straight down from their pivot, then
-- pre-rotated by the grip tilt so they hang plumb while the rod is held.
local HANG = CFrame.Angles(math.rad(GRIP_TILT_DEGREES), 0, 0)
-- The player's forward direction (horizontal) expressed in rod space while held:
-- swinging about it moves a hanging piece side to side.
local HELD_FORWARD = HANG * Vector3.new(0, 0, -1)

local function hangFrom(pivot)
	return CFrame.new(pivot) * HANG * CFrame.new(-pivot)
end

local function lighten(color, amount)
	return color:Lerp(WHITE, amount)
end

--------------------------------------------------------------------------------
-- Part helpers. Every position/CFrame passed in is in rod space.
--------------------------------------------------------------------------------

local function applyMotion(part, motion)
	-- Stored in the Handle's object space so RodFX can animate without knowing rod space.
	part:SetAttribute("FXPivot", HANDLE_IN_ROD:PointToObjectSpace(motion.pivot or Vector3.zero))
	part:SetAttribute("FXAxis", HANDLE_IN_ROD:VectorToObjectSpace((motion.axis or UP).Unit))
	if motion.spin then
		part:SetAttribute("FXSpin", motion.spin)
	end
	if motion.sway then
		part:SetAttribute("FXSwayAngle", motion.sway)
		part:SetAttribute("FXSwaySpeed", motion.swaySpeed or 1.5)
	end
	if motion.bob then
		part:SetAttribute("FXBobDistance", motion.bob)
		part:SetAttribute("FXBobSpeed", motion.bobSpeed or 1.5)
		part:SetAttribute("FXBobAxis", HANDLE_IN_ROD:VectorToObjectSpace((motion.bobAxis or UP).Unit))
	end
	if motion.phase then
		part:SetAttribute("FXPhase", motion.phase)
	end
	if motion.scalePulse then
		part:SetAttribute("FXScalePulse", motion.scalePulse)
	end
end

local function makePart(ctx, className, shape, size, rodCFrame, spec)
	local part
	if className == "WedgePart" then
		part = Instance.new("WedgePart")
	else
		local basic = Instance.new("Part")
		basic.Shape = shape
		part = basic
	end
	part.Name = spec.name or "Detail"
	part.Size = size
	part.CFrame = ctx.origin * (if spec.hang then spec.hang * rodCFrame else rodCFrame)
	part.Color = spec.color
	part.Material = spec.material or Mat.SmoothPlastic
	part.Transparency = spec.transparency or 0
	part.Reflectance = spec.reflectance or 0
	part.Anchored = false
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.Massless = true
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	local largest = math.max(size.X, size.Y, size.Z)
	if largest < 1 or part.Material == Mat.Neon or part.Material == Mat.ForceField or part.Transparency > 0.3 then
		part.CastShadow = false
	end
	if spec.glow then
		part:SetAttribute("FXGlow", true)
		part:SetAttribute("FXGlowPhase", spec.glowPhase or 0)
	end
	if spec.motion then
		applyMotion(part, spec.motion)
	end

	local weld = Instance.new("WeldConstraint")
	weld.Name = "RodWeld"
	weld.Part0 = ctx.handle
	weld.Part1 = part
	weld.Parent = part

	part.Parent = ctx.tool
	ctx.count += 1
	return part
end

-- CFrame at the midpoint of a->b whose X axis points along the segment (for cylinders).
local function frameAlongX(from, to)
	local x = (to - from).Unit
	local hint = v3(0, 0, 1)
	if math.abs(x:Dot(hint)) > 0.95 then
		hint = v3(1, 0, 0)
	end
	local y = hint:Cross(x).Unit
	local z = x:Cross(y)
	return CFrame.fromMatrix((from + to) / 2, x, y, z), (to - from).Magnitude
end

-- CFrame at the midpoint of a->b whose Y axis points along the segment and Z faces `depthHint`.
local function frameAlongY(from, to, depthHint)
	local y = (to - from).Unit
	local hint = depthHint or v3(0, 0, 1)
	if math.abs(y:Dot(hint)) > 0.95 then
		hint = v3(1, 0, 0)
	end
	local x = y:Cross(hint).Unit
	local z = x:Cross(y)
	return CFrame.fromMatrix((from + to) / 2, x, y, z), (to - from).Magnitude
end

local function block(ctx, size, cframe, spec)
	return makePart(ctx, "Part", Enum.PartType.Block, size, cframe, spec)
end

local function ball(ctx, diameter, position, spec)
	return makePart(ctx, "Part", Enum.PartType.Ball, v3(diameter, diameter, diameter), CFrame.new(position), spec)
end

local function cyl(ctx, from, to, diameter, spec)
	local cframe, length = frameAlongX(from, to)
	return makePart(ctx, "Part", Enum.PartType.Cylinder, v3(length, diameter, diameter), cframe, spec)
end

local function disc(ctx, center, axis, diameter, thickness, spec)
	local half = axis.Unit * (thickness / 2)
	return cyl(ctx, center - half, center + half, diameter, spec)
end

local function bar(ctx, from, to, width, depth, spec, depthHint)
	local cframe, length = frameAlongY(from, to, depthHint)
	return makePart(ctx, "Part", Enum.PartType.Block, v3(width, length, depth), cframe, spec)
end

-- Any flat triangle a,b,c (two WedgeParts). `thickness` is measured along the triangle's normal.
local function tri(ctx, a, b, c, thickness, spec)
	local ab, ac, bc = b - a, c - a, c - b
	local abd, acd, bcd = ab:Dot(ab), ac:Dot(ac), bc:Dot(bc)
	if abd > acd and abd > bcd then
		c, a = a, c
	elseif acd > bcd and acd > abd then
		a, b = b, a
	end
	ab, ac, bc = b - a, c - a, c - b
	local right = ac:Cross(ab).Unit
	local up = bc:Cross(right).Unit
	local back = bc.Unit
	local height = math.abs(ab:Dot(up))
	local first = makePart(
		ctx,
		"WedgePart",
		nil,
		v3(thickness, height, math.abs(ab:Dot(back))),
		CFrame.fromMatrix((a + b) / 2, right, up, back),
		spec
	)
	local second = makePart(
		ctx,
		"WedgePart",
		nil,
		v3(thickness, height, math.abs(ac:Dot(back))),
		CFrame.fromMatrix((a + c) / 2, -right, up, -back),
		spec
	)
	return first, second
end

-- One WedgePart shaped like a fang/icicle: a right-angled blade whose base runs from `base`
-- along `along` for `baseLength`, rising `height` toward `pointDir`.
local function fang(ctx, base, along, pointDir, baseLength, height, thickness, spec)
	local z = -along.Unit
	local y = (pointDir - z * pointDir:Dot(z)).Unit
	local x = y:Cross(z)
	local front = base + along.Unit * baseLength
	local top = base + y * height
	return makePart(ctx, "WedgePart", nil, v3(thickness, height, baseLength), CFrame.fromMatrix((front + top) / 2, x, y, z), spec)
end

-- `count` small blocks evenly spaced on a circle around `axis`.
local function ringOf(ctx, count, center, axis, radius, size, spec, startAngle)
	local n = axis.Unit
	local reference = if math.abs(n.X) > 0.9 then v3(0, 0, 1) else v3(1, 0, 0)
	local u = n:Cross(reference).Unit
	local w = n:Cross(u)
	local parts = {}
	for i = 0, count - 1 do
		local angle = (startAngle or 0) + i * 2 * math.pi / count
		local radial = u * math.cos(angle) + w * math.sin(angle)
		local cframe = CFrame.fromMatrix(center + radial * radius, radial, n, radial:Cross(n))
		table.insert(parts, block(ctx, size, cframe, spec))
	end
	return parts
end

--------------------------------------------------------------------------------
-- Effect helpers
--------------------------------------------------------------------------------

local function attachment(ctx, name, part, rodPosition)
	local att = Instance.new("Attachment")
	att.Name = name
	att.CFrame = part.CFrame:ToObjectSpace(ctx.origin * CFrame.new(rodPosition))
	att.Parent = part
	return att
end

local function numberSeq(points)
	local keypoints = {}
	for _, point in ipairs(points) do
		table.insert(keypoints, NumberSequenceKeypoint.new(point[1], point[2]))
	end
	return NumberSequence.new(keypoints)
end

-- Builds a ParticleEmitter from a named look. Names starting with "Idle" start enabled;
-- everything else is driven by RodFX (Rate for loops, Emit(BurstCount) for bursts).
local function emitter(parent, name, preset, color1, color2, opts)
	opts = opts or {}
	local scale = opts.scale or 1
	local e = Instance.new("ParticleEmitter")
	e.Name = name
	e.Texture = TEXTURE.Sparkle
	e.Color = ColorSequence.new(color1, color2 or color1)
	e.LightEmission = 1
	e.LightInfluence = 0
	e.ZOffset = 0.2
	e.Rate = 0

	if preset == "embers" then
		e.Size = numberSeq({ { 0, 0.16 * scale }, { 1, 0 } })
		e.Transparency = numberSeq({ { 0, 0.1 }, { 0.7, 0.3 }, { 1, 1 } })
		e.Lifetime = NumberRange.new(1.2, 2.2)
		e.Speed = NumberRange.new(0.6, 1.6)
		e.SpreadAngle = Vector2.new(30, 30)
		e.Acceleration = v3(0, 1.4, 0)
		e.Drag = 0.6
		e.RotSpeed = NumberRange.new(-90, 90)
		e.Rate = 5
	elseif preset == "motes" then
		e.Size = numberSeq({ { 0, 0 }, { 0.2, 0.12 * scale }, { 1, 0 } })
		e.Transparency = numberSeq({ { 0, 0.3 }, { 1, 1 } })
		e.Lifetime = NumberRange.new(2, 3.5)
		e.Speed = NumberRange.new(0.2, 0.7)
		e.SpreadAngle = Vector2.new(180, 180)
		e.Acceleration = v3(0, 0.3, 0)
		e.Drag = 1
		e.Rate = 6
	elseif preset == "bubbles" then
		e.Size = numberSeq({ { 0, 0.08 * scale }, { 1, 0.2 * scale } })
		e.Transparency = numberSeq({ { 0, 0.25 }, { 0.8, 0.5 }, { 1, 1 } })
		e.Lifetime = NumberRange.new(1.4, 2.4)
		e.Speed = NumberRange.new(0.4, 1)
		e.SpreadAngle = Vector2.new(35, 35)
		e.Acceleration = v3(0, 1.2, 0)
		e.LightEmission = 0.6
		e.Rate = 5
	elseif preset == "smoke" then
		e.Texture = TEXTURE.Smoke
		e.Size = numberSeq({ { 0, 0.35 * scale }, { 1, 1.1 * scale } })
		e.Transparency = numberSeq({ { 0, 1 }, { 0.2, 0.65 }, { 1, 1 } })
		e.Lifetime = NumberRange.new(1.5, 2.5)
		e.Speed = NumberRange.new(0.3, 0.8)
		e.SpreadAngle = Vector2.new(30, 30)
		e.Acceleration = v3(0, 0.6, 0)
		e.Rotation = NumberRange.new(0, 360)
		e.RotSpeed = NumberRange.new(-40, 40)
		e.LightEmission = 0.3
		e.Rate = 3
	elseif preset == "sparks" then
		e.Size = numberSeq({ { 0, 0.14 * scale }, { 1, 0 } })
		e.Lifetime = NumberRange.new(0.15, 0.35)
		e.Speed = NumberRange.new(4, 9)
		e.SpreadAngle = Vector2.new(180, 180)
		e.Drag = 4
		e.Rate = 6
	elseif preset == "frost" then
		e.Size = numberSeq({ { 0, 0.1 * scale }, { 1, 0.04 * scale } })
		e.Transparency = numberSeq({ { 0, 0.2 }, { 1, 1 } })
		e.Lifetime = NumberRange.new(1.5, 2.5)
		e.Speed = NumberRange.new(0.2, 0.6)
		e.SpreadAngle = Vector2.new(180, 180)
		e.Acceleration = v3(0, -0.8, 0)
		e.Rotation = NumberRange.new(0, 360)
		e.RotSpeed = NumberRange.new(-60, 60)
		e.Rate = 6
	elseif preset == "fire" then
		e.Texture = TEXTURE.Fire
		e.Size = numberSeq({ { 0, 0.5 * scale }, { 1, 0 } })
		e.Transparency = numberSeq({ { 0, 0.3 }, { 1, 1 } })
		e.Lifetime = NumberRange.new(0.5, 0.9)
		e.Speed = NumberRange.new(1, 2)
		e.SpreadAngle = Vector2.new(15, 15)
		e.Acceleration = v3(0, 3, 0)
		e.Rotation = NumberRange.new(0, 360)
		e.RotSpeed = NumberRange.new(-60, 60)
		e.Rate = 8
	elseif preset == "petals" then
		e.Size = numberSeq({ { 0, 0.22 * scale }, { 1, 0.1 * scale } })
		e.Transparency = numberSeq({ { 0, 0.1 }, { 0.8, 0.3 }, { 1, 1 } })
		e.Lifetime = NumberRange.new(1.8, 3)
		e.Speed = NumberRange.new(0.4, 1)
		e.SpreadAngle = Vector2.new(180, 180)
		e.Acceleration = v3(0, -0.5, 0)
		e.Rotation = NumberRange.new(0, 360)
		e.RotSpeed = NumberRange.new(-120, 120)
		e.Drag = 0.5
		e.LightEmission = 0.6
		e.Rate = 3
	elseif preset == "swirl" then
		e.Size = numberSeq({ { 0, 0.15 * scale }, { 1, 0 } })
		e.Lifetime = NumberRange.new(0.6, 1)
		e.Speed = NumberRange.new(1, 2)
		e.SpreadAngle = Vector2.new(180, 180)
		e.Drag = 2
		e.RotSpeed = NumberRange.new(-180, 180)
		e.Rate = 10
	elseif preset == "burst" then
		e.Size = numberSeq({ { 0, 0.35 * scale }, { 1, 0 } })
		e.Lifetime = NumberRange.new(0.5, 0.9)
		e.Speed = NumberRange.new(7, 13)
		e.SpreadAngle = Vector2.new(180, 180)
		e.Drag = 3
		e.RotSpeed = NumberRange.new(-200, 200)
	elseif preset == "shards" then
		e.Size = numberSeq({ { 0, 0.3 * scale }, { 1, 0.05 * scale } })
		e.Lifetime = NumberRange.new(0.6, 1)
		e.Speed = NumberRange.new(8, 14)
		e.SpreadAngle = Vector2.new(180, 180)
		e.Acceleration = v3(0, -18, 0)
		e.Drag = 1.5
		e.Rotation = NumberRange.new(0, 360)
		e.RotSpeed = NumberRange.new(-300, 300)
	elseif preset == "flare" then
		e.Size = numberSeq({ { 0, 0.4 * scale }, { 0.3, 2.2 * scale }, { 1, 0 } })
		e.Transparency = numberSeq({ { 0, 0.1 }, { 1, 1 } })
		e.Lifetime = NumberRange.new(0.25, 0.35)
		e.Speed = NumberRange.new(0, 0)
		e.LockedToPart = true
	elseif preset == "puff" then
		e.Texture = TEXTURE.Smoke
		e.Size = numberSeq({ { 0, 0.8 * scale }, { 1, 2.8 * scale } })
		e.Transparency = numberSeq({ { 0, 0.3 }, { 1, 1 } })
		e.Lifetime = NumberRange.new(0.4, 0.7)
		e.Speed = NumberRange.new(1, 3)
		e.SpreadAngle = Vector2.new(180, 180)
		e.Rotation = NumberRange.new(0, 360)
	elseif preset == "fountain" then
		e.Size = numberSeq({ { 0, 0.45 * scale }, { 1, 0.1 * scale } })
		e.Lifetime = NumberRange.new(0.9, 1.4)
		e.Speed = NumberRange.new(12, 18)
		e.SpreadAngle = Vector2.new(22, 22)
		e.Acceleration = v3(0, -28, 0)
		e.Drag = 0.5
		e.EmissionDirection = Enum.NormalId.Top
	elseif preset == "implode" then
		-- Parent this to a part: particles start on its surface and rush inward.
		e.Size = numberSeq({ { 0, 0.05 * scale }, { 1, 0.22 * scale } })
		e.Lifetime = NumberRange.new(0.3, 0.35)
		e.Speed = NumberRange.new(2.5, 3.5)
		e.Shape = Enum.ParticleEmitterShape.Sphere
		e.ShapeStyle = Enum.ParticleEmitterShapeStyle.Surface
		e.ShapeInOut = Enum.ParticleEmitterShapeInOut.Inward
	end

	if opts.rate then
		e.Rate = opts.rate
	end
	e.Enabled = string.sub(name, 1, 4) == "Idle"
	if opts.count then
		e:SetAttribute("BurstCount", opts.count)
	end
	if opts.delay then
		e:SetAttribute("BurstDelay", opts.delay)
	end
	e.Parent = parent
	return e
end

local function pointLight(parent, name, color, brightness, range)
	local light = Instance.new("PointLight")
	light.Name = name
	light.Color = color
	light.Brightness = brightness
	light.Range = range
	light.Shadows = false
	light.Parent = parent
	return light
end

-- The effects every rod gets: glow + flash lights, equip/charge/cast/bite/reel/catch,
-- the cast trail and the "energy flowing up the rod" reel beam. Scaled by tier.
local function standardFX(ctx, p)
	local tier = ctx.def.tier
	local accent = p.accent
	local accent2 = p.accent2 or lighten(accent, 0.5)
	local range = p.lightRange or (6 + tier * 2)

	pointLight(p.lightParent or p.core, "GlowLight", accent, p.lightBrightness or (0.8 + tier * 0.4), range)
	pointLight(p.core, "FlashLight", accent2, 0, range * 1.8)

	emitter(p.core, "EquipBurst", p.equipPreset or "burst", accent, accent2, { count = 8 + tier * 6, scale = 0.8 })
	emitter(p.core, "ChargeSwirl", p.chargePreset or "swirl", accent, accent2, { rate = 6 + tier * 4 })
	emitter(p.tip, "CastBurst", p.castPreset or "burst", accent, accent2, { count = 8 + tier * 6, scale = 0.7 })
	emitter(p.tip, "BiteFlare", "flare", accent2, accent, { count = 1, scale = 0.6 + tier * 0.15 })
	emitter(p.tip, "BiteSparks", "sparks", accent, accent2, { count = 6 + tier * 4 })
	emitter(p.core, "ReelSparks", p.reelPreset or "motes", accent, accent2, { rate = 8 + tier * 6 })
	emitter(p.core, "CatchBurst", p.catchPreset or "burst", accent, accent2, {
		count = 20 + tier * 18,
		scale = 0.8 + tier * 0.15,
		delay = p.catchDelay,
	})
	emitter(p.core, "CatchFlare", "flare", accent2, accent, {
		count = if tier >= 3 then 2 else 1,
		scale = 1 + tier * 0.4,
		delay = p.catchDelay,
	})

	-- Cast trail: two attachments straddling the tip.
	local trailPart = p.tip.Parent
	local halfWidth = 0.15 + tier * 0.08
	local trail = Instance.new("Trail")
	trail.Name = "CastTrail"
	trail.Attachment0 = attachment(ctx, "TrailA", trailPart, p.tipPosition - v3(halfWidth, 0, 0))
	trail.Attachment1 = attachment(ctx, "TrailB", trailPart, p.tipPosition + v3(halfWidth, 0, 0))
	trail.Color = ColorSequence.new(accent, accent2)
	trail.Transparency = numberSeq({ { 0, 0.1 }, { 1, 1 } })
	trail.WidthScale = numberSeq({ { 0, 1 }, { 1, 0.1 } })
	trail.Lifetime = 0.25 + tier * 0.06
	trail.MinLength = 0.05
	trail.LightEmission = 1
	trail.LightInfluence = 0
	trail.FaceCamera = true
	trail.Enabled = false
	trail.Parent = trailPart

	-- Reel beam: a scrolling sparkle stream running up the shaft.
	local beam = Instance.new("Beam")
	beam.Name = "ReelFlow"
	beam.Attachment0 = attachment(ctx, "FlowStart", ctx.handle, p.flowFrom)
	beam.Attachment1 = attachment(ctx, "FlowEnd", ctx.handle, p.flowTo)
	beam.Texture = TEXTURE.Sparkle
	beam.TextureMode = Enum.TextureMode.Wrap
	beam.TextureLength = 1.2
	beam.TextureSpeed = 2.5
	beam.Width0 = 0.45
	beam.Width1 = 0.3
	beam.Color = ColorSequence.new(accent, accent2)
	beam.Transparency = numberSeq({ { 0, 0.6 }, { 0.5, 0.15 }, { 1, 0.6 } })
	beam.LightEmission = 1
	beam.LightInfluence = 0
	beam.FaceCamera = true
	beam.Segments = 8
	beam.Enabled = false
	beam.Parent = ctx.handle
end

--------------------------------------------------------------------------------
-- Shared anatomy: wrapped grip, ferrules, a real reel and line guides.
--------------------------------------------------------------------------------

local function buildAnatomy(ctx, a)
	local handle = ctx.handle
	handle.Color = a.grip
	handle.Material = a.gripMaterial

	for _, y in ipairs({ -0.42, -0.14, 0.14, 0.42 }) do
		disc(ctx, v3(0, y, 0), UP, 0.47, 0.07, { name = "GripWrap", color = a.wrap, material = a.wrapMaterial })
	end
	disc(ctx, v3(0, -0.64, 0), UP, 0.5, 0.08, { name = "LowerFerrule", color = a.metal, material = a.metalMaterial })
	disc(ctx, v3(0, 0.64, 0), UP, 0.5, 0.08, { name = "UpperFerrule", color = a.metal, material = a.metalMaterial })

	local reelY = 0.98
	disc(ctx, v3(0, reelY, 0), UP, 0.36, 0.56, { name = "ReelSeat", color = a.reel, material = a.reelMaterial })
	block(ctx, v3(0.12, 0.44, 0.14), CFrame.new(0, reelY, -0.22), {
		name = "ReelFoot",
		color = a.metal,
		material = a.metalMaterial,
	})
	block(ctx, v3(0.1, 0.1, 0.2), CFrame.new(0, reelY, -0.36), {
		name = "ReelStem",
		color = a.metal,
		material = a.metalMaterial,
	})
	cyl(ctx, v3(-0.15, reelY, -0.6), v3(0.15, reelY, -0.6), 0.56, {
		name = "ReelSpool",
		color = a.reel,
		material = a.reelMaterial,
	})
	cyl(ctx, v3(-0.21, reelY, -0.6), v3(-0.15, reelY, -0.6), 0.62, {
		name = "ReelRim",
		color = a.reelAccent,
		material = a.reelAccentMaterial,
		glow = a.reelGlow,
	})
	bar(ctx, v3(0.2, reelY, -0.6), v3(0.2, reelY - 0.3, -0.6), 0.06, 0.06, {
		name = "ReelCrank",
		color = a.metal,
		material = a.metalMaterial,
	})
	ball(ctx, 0.15, v3(0.28, reelY - 0.3, -0.6), { name = "ReelKnob", color = a.reelAccent, material = a.reelAccentMaterial })

	local radius = a.shaftRadius or 0.12
	for _, position in ipairs(a.guides) do
		block(ctx, v3(0.05, 0.05, 0.2), CFrame.new(position + v3(0, 0, -(radius + 0.08))), {
			name = "GuideStalk",
			color = a.metal,
			material = a.metalMaterial,
		})
		disc(ctx, position + v3(0, 0, -(radius + 0.22)), UP, 0.2, 0.04, {
			name = "LineGuide",
			color = a.metal,
			material = a.metalMaterial,
		})
	end
end

--------------------------------------------------------------------------------
-- 1 · Wickwood Lantern (tier 1)
--------------------------------------------------------------------------------

local function buildWickwoodLantern(ctx)
	local WOOD = rgb(122, 92, 66)
	local WOOD_DARK = rgb(84, 60, 42)
	local BRASS = rgb(196, 150, 72)
	local AMBER = rgb(255, 170, 60)
	local FLAME = rgb(255, 214, 140)

	buildAnatomy(ctx, {
		grip = rgb(66, 46, 32),
		gripMaterial = Mat.Leather,
		wrap = BRASS,
		wrapMaterial = Mat.Metal,
		metal = BRASS,
		metalMaterial = Mat.Metal,
		reel = WOOD_DARK,
		reelMaterial = Mat.Wood,
		reelAccent = BRASS,
		reelAccentMaterial = Mat.Metal,
		shaftRadius = 0.11,
		guides = { v3(0.03, 2.5, 0), v3(0, 4.2, 0) },
	})

	disc(ctx, v3(0, -0.74, 0), UP, 0.32, 0.12, { name = "PommelCap", color = WOOD_DARK, material = Mat.Wood })
	ball(ctx, 0.36, v3(0, -0.9, 0), { name = "Pommel", color = BRASS, material = Mat.Metal })

	-- Driftwood shaft that bends over into a shepherd's crook.
	local crook = {
		v3(0, 1.2, 0),
		v3(0.05, 3.2, 0),
		v3(-0.04, 5, 0),
		v3(0.1, 5.75, 0),
		v3(0.5, 6.2, 0),
		v3(1, 6.22, 0),
		v3(1.32, 5.92, 0),
	}
	local widths = { 0.22, 0.2, 0.19, 0.18, 0.17, 0.15 }
	for i = 1, #crook - 1 do
		cyl(ctx, crook[i], crook[i + 1], widths[i], { name = "Driftwood", color = WOOD, material = Mat.Wood })
		if i > 1 then
			ball(ctx, widths[i], crook[i], { name = "DriftwoodBend", color = WOOD, material = Mat.Wood })
		end
	end
	ball(ctx, 0.2, v3(0.1, 2, 0.04), { name = "Knot", color = WOOD_DARK, material = Mat.Wood })
	ball(ctx, 0.17, v3(-0.09, 4, -0.02), { name = "Knot", color = WOOD_DARK, material = Mat.Wood })
	local tipPosition = v3(1.36, 5.87, 0)
	local tipCap = ball(ctx, 0.16, crook[#crook], { name = "TipCap", color = BRASS, material = Mat.Metal })

	-- The lantern hangs from the crook and swings gently.
	local pivot = v3(0.78, 6.14, 0)
	local hanging = hangFrom(pivot)
	local swing = { pivot = pivot, axis = HELD_FORWARD, sway = 0.12, swaySpeed = 1.6 }
	local L = v3(0.78, 5.42, 0)
	bar(ctx, v3(0.78, 6.16, 0), v3(0.78, 5.84, 0), 0.05, 0.05, {
		name = "LanternHanger",
		color = BRASS,
		material = Mat.Metal,
		motion = swing, hang = hanging,
	})
	disc(ctx, L + v3(0, 0.44, 0), UP, 0.3, 0.14, { name = "LanternRoof", color = BRASS, material = Mat.Metal, motion = swing, hang = hanging })
	disc(ctx, L + v3(0, 0.34, 0), UP, 0.56, 0.08, { name = "LanternCap", color = BRASS, material = Mat.Metal, motion = swing, hang = hanging })
	disc(ctx, L - v3(0, 0.34, 0), UP, 0.56, 0.1, { name = "LanternBase", color = BRASS, material = Mat.Metal, motion = swing, hang = hanging })
	for _, corner in ipairs({ v3(0.2, 0, 0.2), v3(-0.2, 0, 0.2), v3(0.2, 0, -0.2), v3(-0.2, 0, -0.2) }) do
		block(ctx, v3(0.06, 0.62, 0.06), CFrame.new(L + corner), {
			name = "LanternPost",
			color = BRASS,
			material = Mat.Metal,
			motion = swing, hang = hanging,
		})
	end
	block(ctx, v3(0.38, 0.6, 0.38), CFrame.new(L), {
		name = "LanternGlass",
		color = rgb(255, 224, 180),
		material = Mat.Glass,
		transparency = 0.55,
		motion = swing, hang = hanging,
	})
	local flame = ball(ctx, 0.2, L - v3(0, 0.06, 0), {
		name = "LanternFlame",
		color = AMBER,
		material = Mat.Neon,
		glow = true,
		motion = swing, hang = hanging,
	})
	block(ctx, v3(0.08, 0.2, 0.08), CFrame.new(L + v3(0, 0.1, 0)) * CFrame.Angles(0, math.rad(45), 0), {
		name = "LanternFlameTongue",
		color = FLAME,
		material = Mat.Neon,
		glow = true,
		glowPhase = 0.3,
		motion = swing, hang = hanging,
	})
	ball(ctx, 0.12, L - v3(0, 0.44, 0), { name = "LanternFinial", color = BRASS, material = Mat.Metal, motion = swing, hang = hanging })

	local core = attachment(ctx, "Core", flame, hanging * L)
	local tip = attachment(ctx, "Tip", tipCap, tipPosition)
	emitter(core, "IdleEmbers", "embers", AMBER, FLAME, { rate = 3, scale = 0.8 })
	standardFX(ctx, {
		core = core,
		tip = tip,
		tipPosition = tipPosition,
		accent = AMBER,
		accent2 = FLAME,
		flowFrom = v3(0, 1.3, 0),
		flowTo = v3(0, 4.9, 0),
		castPreset = "sparks",
		reelPreset = "embers",
	})
end

--------------------------------------------------------------------------------
-- 2 · Kelpcoil Whip (tier 2)
--------------------------------------------------------------------------------

local function buildKelpcoilWhip(ctx)
	local KELP = rgb(34, 78, 48)
	local KELP_DARK = rgb(22, 52, 34)
	local OLIVE = rgb(120, 118, 52)
	local LIME = rgb(160, 255, 80)

	buildAnatomy(ctx, {
		grip = KELP_DARK,
		gripMaterial = Mat.Rubber,
		wrap = OLIVE,
		wrapMaterial = Mat.SmoothPlastic,
		metal = OLIVE,
		metalMaterial = Mat.Metal,
		reel = KELP_DARK,
		reelMaterial = Mat.Rubber,
		reelAccent = LIME,
		reelAccentMaterial = Mat.Neon,
		reelGlow = true,
		shaftRadius = 0.12,
		guides = { v3(0.05, 2.7, 0), v3(0.05, 4.6, 0) },
	})

	-- Holdfast roots for a pommel.
	ball(ctx, 0.3, v3(0, -0.84, 0), { name = "Holdfast", color = KELP_DARK, material = Mat.Rubber })
	ball(ctx, 0.24, v3(0.13, -0.98, 0.06), { name = "Holdfast", color = KELP, material = Mat.Rubber })
	ball(ctx, 0.22, v3(-0.11, -1, -0.05), { name = "Holdfast", color = KELP, material = Mat.Rubber })

	-- A living S-curved stalk.
	local stalk = {
		v3(0, 1.2, 0),
		v3(0.12, 2.2, 0),
		v3(-0.1, 3.2, 0),
		v3(0.12, 4.2, 0),
		v3(-0.08, 5.1, 0),
		v3(0.08, 5.9, 0),
		v3(0, 6.6, 0),
	}
	local widths = { 0.26, 0.24, 0.22, 0.2, 0.18, 0.16 }
	local topJoint
	for i = 1, #stalk - 1 do
		cyl(ctx, stalk[i], stalk[i + 1], widths[i], { name = "KelpStalk", color = KELP, material = Mat.Rubber })
		if i > 1 then
			local joint = ball(ctx, widths[i], stalk[i], { name = "KelpNode", color = KELP, material = Mat.Rubber })
			if i == 6 then
				topJoint = joint
			end
		end
	end

	-- Frond blades that ripple.
	local fronds = {
		{ v3(0.08, 2.45, 0), v3(0.08, 2.85, 0), v3(0.85, 3.25, 0.1), 0 },
		{ v3(-0.08, 3.45, 0), v3(-0.08, 3.85, 0), v3(-0.8, 4.3, -0.1), 1.3 },
		{ v3(0.09, 4.5, 0), v3(0.09, 4.85, 0), v3(0.75, 5.3, 0.05), 2.6 },
		{ v3(-0.06, 5.3, 0), v3(-0.06, 5.6, 0), v3(-0.65, 6, 0), 3.9 },
	}
	for _, frond in ipairs(fronds) do
		tri(ctx, frond[1], frond[2], frond[3], 0.04, {
			name = "KelpFrond",
			color = OLIVE,
			motion = { pivot = frond[1], axis = v3(0, 0, 1), sway = 0.1, swaySpeed = 1.3, phase = frond[4] },
		})
	end

	-- Three float bladders with glowing cores, bobbing out of step.
	local bulbs = {
		{ v3(0.52, 5.78, 0.1), 0.5, v3(0.08, 5.6, 0) },
		{ v3(-0.46, 6.18, -0.05), 0.44, v3(-0.03, 6.05, 0) },
		{ v3(0.34, 6.78, 0), 0.38, v3(0.04, 6.45, 0) },
	}
	for i, bulb in ipairs(bulbs) do
		local center, size, root = bulb[1], bulb[2], bulb[3]
		local bob = { pivot = center, bob = 0.06, bobSpeed = 1.5, phase = i * 2.1 }
		cyl(ctx, root, center, 0.07, { name = "BulbStem", color = KELP, material = Mat.Rubber })
		ball(ctx, size, center, {
			name = "FloatBladder",
			color = rgb(150, 200, 90),
			material = Mat.Glass,
			transparency = 0.45,
			motion = bob,
		})
		ball(ctx, size * 0.6, center, {
			name = "BladderGlow",
			color = LIME,
			material = Mat.Neon,
			glow = true,
			glowPhase = i / 3,
			motion = bob,
		})
	end

	-- Curled frond tip where the line leaves.
	local tipPosition = v3(0.14, 6.98, 0)
	cyl(ctx, v3(0, 6.6, 0), v3(0.12, 6.92, 0), 0.14, { name = "CurledTip", color = KELP, material = Mat.Rubber })
	local tipCap = ball(ctx, 0.14, v3(0.12, 6.92, 0), { name = "TipCap", color = OLIVE, material = Mat.Metal })

	local core = attachment(ctx, "Core", topJoint, v3(0.05, 6.2, 0))
	local tip = attachment(ctx, "Tip", tipCap, tipPosition)
	emitter(core, "IdleBubbles", "bubbles", rgb(220, 255, 200), LIME, { rate = 5 })
	emitter(core, "IdleMotes", "motes", LIME, rgb(220, 255, 180), { rate = 3 })
	standardFX(ctx, {
		core = core,
		tip = tip,
		tipPosition = tipPosition,
		accent = LIME,
		accent2 = rgb(220, 255, 190),
		flowFrom = v3(0, 1.3, 0),
		flowTo = v3(0, 5.2, 0),
		reelPreset = "bubbles",
		catchPreset = "burst",
	})
end

--------------------------------------------------------------------------------
-- 3 · Tollkeeper's Bell (tier 2)
--------------------------------------------------------------------------------

local function buildTollkeepersBell(ctx)
	local IRON = rgb(52, 54, 60)
	local IRON_DARK = rgb(34, 35, 40)
	local VERDIGRIS = rgb(78, 150, 130)
	local GHOST = rgb(225, 238, 255)

	buildAnatomy(ctx, {
		grip = IRON_DARK,
		gripMaterial = Mat.Fabric,
		wrap = VERDIGRIS,
		wrapMaterial = Mat.Metal,
		metal = IRON,
		metalMaterial = Mat.Metal,
		reel = IRON,
		reelMaterial = Mat.CorrodedMetal,
		reelAccent = VERDIGRIS,
		reelAccentMaterial = Mat.Metal,
		shaftRadius = 0.12,
		guides = { v3(0, 2.6, 0), v3(0, 4, 0) },
	})

	-- Iron counterweight pommel.
	disc(ctx, v3(0, -0.78, 0), UP, 0.42, 0.18, { name = "Counterweight", color = IRON, material = Mat.Metal })
	ball(ctx, 0.24, v3(0, -0.95, 0), { name = "Pommel", color = VERDIGRIS, material = Mat.Metal })

	-- Buoy pole.
	cyl(ctx, v3(0, 1.2, 0), v3(0, 5, 0), 0.24, { name = "BuoyPole", color = IRON, material = Mat.CorrodedMetal })
	for _, y in ipairs({ 2, 3.3, 4.6 }) do
		disc(ctx, v3(0, y, 0), UP, 0.32, 0.1, { name = "PoleBand", color = VERDIGRIS, material = Mat.Metal })
	end

	-- Buoy cage.
	local corners = { v3(0.52, 0, 0.52), v3(-0.52, 0, 0.52), v3(0.52, 0, -0.52), v3(-0.52, 0, -0.52) }
	disc(ctx, v3(0, 5.02, 0), UP, 1.35, 0.08, { name = "CageFloor", color = VERDIGRIS, material = Mat.Metal })
	for _, corner in ipairs(corners) do
		bar(ctx, v3(corner.X, 5.06, corner.Z), v3(corner.X, 6.86, corner.Z), 0.08, 0.08, {
			name = "CagePost",
			color = IRON,
			material = Mat.Metal,
		})
	end
	local cageTop = disc(ctx, v3(0, 6.9, 0), UP, 1.28, 0.08, { name = "CageTop", color = IRON, material = Mat.Metal })
	ball(ctx, 0.6, v3(0, 7, 0), { name = "CageDome", color = IRON, material = Mat.Metal })
	cyl(ctx, v3(0, 7.25, 0), v3(0, 7.7, 0), 0.09, { name = "Finial", color = IRON, material = Mat.Metal })
	local tipPosition = v3(0, 7.83, 0)
	local tipLamp = ball(ctx, 0.16, v3(0, 7.75, 0), {
		name = "BeaconLamp",
		color = GHOST,
		material = Mat.Neon,
		glow = true,
	})
	for i, corner in ipairs(corners) do
		ball(ctx, 0.15, v3(corner.X, 6.98, corner.Z), {
			name = "CageLamp",
			color = GHOST,
			material = Mat.Neon,
			glow = true,
			glowPhase = (i % 2) * 0.5,
		})
	end

	-- The bell swings like a pendulum inside the cage.
	local swing = { pivot = v3(0, 6.86, 0), axis = v3(0, 0, 1), sway = 0.2, swaySpeed = 1.8 }
	bar(ctx, v3(0, 6.86, 0), v3(0, 6.5, 0), 0.06, 0.06, { name = "BellHanger", color = IRON, material = Mat.Metal, motion = swing })
	disc(ctx, v3(0, 6.46, 0), UP, 0.36, 0.12, { name = "BellCrown", color = VERDIGRIS, material = Mat.Metal, motion = swing })
	disc(ctx, v3(0, 6.15, 0), UP, 0.62, 0.52, {
		name = "Bell",
		color = VERDIGRIS,
		material = Mat.Metal,
		reflectance = 0.1,
		motion = swing,
	})
	disc(ctx, v3(0, 5.86, 0), UP, 0.84, 0.1, { name = "BellLip", color = VERDIGRIS, material = Mat.Metal, motion = swing })
	ball(ctx, 0.2, v3(0, 5.7, 0), {
		name = "BellClapper",
		color = GHOST,
		material = Mat.Neon,
		glow = true,
		motion = swing,
	})

	-- A short chain dangling off the cage floor.
	local chainPivot = v3(0.62, 5, 0)
	local chainSwing = { pivot = chainPivot, axis = HELD_FORWARD, sway = 0.12, swaySpeed = 1.8, phase = 0.5 }
	for i, y in ipairs({ 4.88, 4.72, 4.56 }) do
		local size = if i % 2 == 1 then v3(0.06, 0.2, 0.12) else v3(0.12, 0.2, 0.06)
		block(ctx, size, CFrame.new(0.62, y, 0), {
			name = "ChainLink",
			color = IRON,
			material = Mat.Metal,
			motion = chainSwing,
			hang = hangFrom(chainPivot),
		})
	end

	local core = attachment(ctx, "Core", cageTop, v3(0, 6.15, 0))
	local tip = attachment(ctx, "Tip", tipLamp, tipPosition)
	emitter(core, "IdleMist", "smoke", GHOST, rgb(170, 190, 210), { rate = 2, scale = 0.8 })
	emitter(core, "IdleMotes", "motes", GHOST, rgb(160, 220, 255), { rate = 3 })
	standardFX(ctx, {
		core = core,
		tip = tip,
		tipPosition = tipPosition,
		accent = GHOST,
		accent2 = rgb(170, 220, 255),
		flowFrom = v3(0, 1.3, 0),
		flowTo = v3(0, 4.9, 0),
		reelPreset = "motes",
		catchPreset = "sparks",
	})
end

--------------------------------------------------------------------------------
-- 4 · Reefbranch Crook (tier 2)
--------------------------------------------------------------------------------

local function buildReefbranchCrook(ctx)
	local BONE = rgb(236, 226, 206)
	local CORAL = rgb(232, 112, 104)
	local CORAL_DARK = rgb(176, 74, 78)
	local PINK = rgb(255, 70, 150)

	buildAnatomy(ctx, {
		grip = CORAL_DARK,
		gripMaterial = Mat.Fabric,
		wrap = BONE,
		wrapMaterial = Mat.Marble,
		metal = BONE,
		metalMaterial = Mat.Marble,
		reel = BONE,
		reelMaterial = Mat.Marble,
		reelAccent = PINK,
		reelAccentMaterial = Mat.Neon,
		reelGlow = true,
		shaftRadius = 0.13,
		guides = { v3(0, 2.3, 0), v3(0, 3.7, 0) },
	})

	-- Coral knot pommel.
	ball(ctx, 0.34, v3(0, -0.84, 0), { name = "CoralKnot", color = CORAL, material = Mat.Pebble })
	ball(ctx, 0.18, v3(0.13, -0.98, 0.05), { name = "CoralKnot", color = CORAL_DARK, material = Mat.Pebble })
	ball(ctx, 0.18, v3(-0.12, -0.98, -0.05), { name = "CoralKnot", color = CORAL_DARK, material = Mat.Pebble })

	-- Bleached bone shaft with barnacles.
	cyl(ctx, v3(0, 1.2, 0), v3(0, 4.5, 0), 0.26, { name = "BoneShaft", color = BONE, material = Mat.Marble })
	ball(ctx, 0.2, v3(0.12, 2, 0.05), { name = "Barnacle", color = CORAL, material = Mat.Pebble })
	ball(ctx, 0.17, v3(-0.11, 3, -0.06), { name = "Barnacle", color = CORAL, material = Mat.Pebble })
	ball(ctx, 0.16, v3(0.1, 3.95, 0.08), { name = "Barnacle", color = CORAL, material = Mat.Pebble })

	-- Branching coral antlers.
	local F0 = v3(0, 4.5, 0)
	local L1, L2, LS = v3(-0.5, 5.35, 0.12), v3(-0.75, 6.25, 0.2), v3(-1.05, 5.85, 0.05)
	local R1, R2, RS = v3(0.48, 5.25, -0.12), v3(0.8, 6.1, -0.2), v3(1, 5.65, -0.05)
	local C1, C2 = v3(0.04, 5.7, 0), v3(0, 6.9, 0)
	local CS1, CS2 = v3(-0.32, 6.35, -0.1), v3(0.36, 6.45, 0.12)
	local branches = {
		{ F0, L1, 0.2 },
		{ L1, L2, 0.15 },
		{ L1, LS, 0.12 },
		{ F0, R1, 0.2 },
		{ R1, R2, 0.15 },
		{ R1, RS, 0.12 },
		{ F0, C1, 0.2 },
		{ C1, C2, 0.15 },
		{ C1, CS1, 0.12 },
		{ C1, CS2, 0.12 },
	}
	for _, branch in ipairs(branches) do
		local color = if branch[3] < 0.13 then lighten(CORAL, 0.15) else CORAL
		cyl(ctx, branch[1], branch[2], branch[3], { name = "CoralBranch", color = color, material = Mat.SmoothPlastic })
	end
	ball(ctx, 0.3, F0, { name = "CoralFork", color = CORAL, material = Mat.SmoothPlastic })
	ball(ctx, 0.2, L1, { name = "CoralFork", color = CORAL, material = Mat.SmoothPlastic })
	ball(ctx, 0.2, R1, { name = "CoralFork", color = CORAL, material = Mat.SmoothPlastic })
	local centreFork = ball(ctx, 0.2, C1, { name = "CoralFork", color = CORAL, material = Mat.SmoothPlastic })

	-- Glowing polyps that pulse one after another.
	for i, position in ipairs({ LS, L2, CS1, CS2, R2, RS }) do
		ball(ctx, 0.17, position, {
			name = "Polyp",
			color = PINK,
			material = Mat.Neon,
			glow = true,
			glowPhase = (i - 1) / 6,
		})
	end
	local tipPosition = v3(0, 6.97, 0)
	local tipCap = ball(ctx, 0.16, C2, { name = "TipCap", color = BONE, material = Mat.Marble })

	local core = attachment(ctx, "Core", centreFork, v3(0, 5.75, 0))
	local tip = attachment(ctx, "Tip", tipCap, tipPosition)
	emitter(core, "IdlePlankton", "motes", PINK, rgb(255, 220, 235), { rate = 6 })
	emitter(core, "IdleSpores", "smoke", PINK, CORAL, { rate = 1, scale = 0.6 })
	standardFX(ctx, {
		core = core,
		tip = tip,
		tipPosition = tipPosition,
		accent = PINK,
		accent2 = rgb(255, 190, 220),
		flowFrom = v3(0, 1.3, 0),
		flowTo = v3(0, 4.4, 0),
		reelPreset = "motes",
		catchPreset = "petals",
	})
end

--------------------------------------------------------------------------------
-- 5 · Squall Cleaver (tier 3)
--------------------------------------------------------------------------------

local function buildSquallCleaver(ctx)
	local SLATE = rgb(54, 58, 70)
	local SLATE_DARK = rgb(36, 38, 48)
	local BLADE = rgb(72, 78, 94)
	local COPPER = rgb(184, 110, 60)
	local VOLT = rgb(255, 232, 70)

	buildAnatomy(ctx, {
		grip = SLATE_DARK,
		gripMaterial = Mat.Leather,
		wrap = COPPER,
		wrapMaterial = Mat.Metal,
		metal = COPPER,
		metalMaterial = Mat.Metal,
		reel = SLATE,
		reelMaterial = Mat.Slate,
		reelAccent = VOLT,
		reelAccentMaterial = Mat.Neon,
		reelGlow = true,
		shaftRadius = 0.14,
		guides = { v3(0, 2, 0), v3(0, 3, 0) },
	})

	-- Copper spike pommel.
	ball(ctx, 0.3, v3(0, -0.74, 0), { name = "PommelKnob", color = SLATE, material = Mat.Slate })
	tri(ctx, v3(-0.14, -0.78, 0), v3(0.14, -0.78, 0), v3(0, -1.3, 0), 0.14, { name = "PommelSpike", color = COPPER, material = Mat.Metal })

	-- Haft.
	cyl(ctx, v3(0, 1.2, 0), v3(0, 6.45, 0), 0.28, { name = "Haft", color = SLATE, material = Mat.Slate })
	for _, y in ipairs({ 2.5, 3.5 }) do
		disc(ctx, v3(0, y, 0), UP, 0.36, 0.1, { name = "HaftBand", color = COPPER, material = Mat.Metal })
	end

	-- Tesla coil: two counter-rotating copper rings around a charged core.
	disc(ctx, v3(0, 4.35, 0), UP, 0.34, 0.16, { name = "CoilCore", color = VOLT, material = Mat.Neon, glow = true })
	for ringIndex, y in ipairs({ 4.15, 4.55 }) do
		local spin = if ringIndex == 1 then 2.2 else -2.2
		ringOf(ctx, 4, v3(0, y, 0), UP, 0.3, v3(0.14, 0.12, 0.14), {
			name = "CoilRing",
			color = COPPER,
			material = Mat.Metal,
			motion = { pivot = v3(0, y, 0), axis = UP, spin = spin },
		}, ringIndex * 0.4)
	end

	-- Axe head.
	local socket = block(ctx, v3(0.44, 1.3, 0.36), CFrame.new(0, 5.7, 0), { name = "HeadSocket", color = SLATE_DARK, material = Mat.Metal })
	local N1, N2 = v3(0.2, 6.15, 0), v3(0.2, 5.25, 0)
	local E = v3(1.5, 5.7, 0)
	local H1, H2 = v3(1.3, 6.8, 0), v3(1.3, 4.6, 0)
	local bladeSpec = { name = "AxeBlade", color = BLADE, material = Mat.Slate }
	tri(ctx, N1, N2, E, 0.12, bladeSpec)
	tri(ctx, N1, E, H1, 0.12, bladeSpec)
	tri(ctx, N2, H2, E, 0.12, bladeSpec)
	bar(ctx, H1, E, 0.09, 0.18, { name = "StormEdge", color = VOLT, material = Mat.Neon, glow = true })
	bar(ctx, E, H2, 0.09, 0.18, { name = "StormEdge", color = VOLT, material = Mat.Neon, glow = true, glowPhase = 0.2 })
	local zigzag = { v3(0.45, 6.15, 0), v3(0.82, 5.88, 0), v3(0.6, 5.62, 0), v3(0.98, 5.3, 0) }
	for i = 1, #zigzag - 1 do
		bar(ctx, zigzag[i], zigzag[i + 1], 0.07, 0.16, {
			name = "BoltInlay",
			color = VOLT,
			material = Mat.Neon,
			glow = true,
			glowPhase = i * 0.15,
		})
	end
	tri(ctx, v3(-0.2, 5.98, 0), v3(-0.2, 5.42, 0), v3(-1.05, 5.7, 0), 0.14, { name = "BackSpike", color = COPPER, material = Mat.Metal })

	-- Three-pronged top with lightning crawling between the prongs.
	tri(ctx, v3(-0.16, 6.45, 0), v3(0.16, 6.45, 0), v3(0, 7.55, 0), 0.12, { name = "Spearhead", color = COPPER, material = Mat.Metal })
	local prongTips = {}
	for _, side in ipairs({ -1, 1 }) do
		cyl(ctx, v3(0.1 * side, 6.4, 0), v3(0.48 * side, 6.85, 0), 0.09, { name = "Prong", color = COPPER, material = Mat.Metal })
		cyl(ctx, v3(0.48 * side, 6.85, 0), v3(0.48 * side, 7.2, 0), 0.09, { name = "Prong", color = COPPER, material = Mat.Metal })
		table.insert(prongTips, ball(ctx, 0.15, v3(0.48 * side, 7.24, 0), {
			name = "ProngNode",
			color = VOLT,
			material = Mat.Neon,
			glow = true,
			glowPhase = 0.5 + side * 0.25,
		}))
	end
	local tipPosition = v3(0, 7.62, 0)
	local spearNode = ball(ctx, 0.15, v3(0, 7.55, 0), { name = "ProngNode", color = VOLT, material = Mat.Neon, glow = true })

	local arcLeft = attachment(ctx, "ArcLeft", prongTips[1], v3(-0.48, 7.24, 0))
	local arcCentre = attachment(ctx, "ArcCentre", spearNode, v3(0, 7.5, 0))
	local arcRight = attachment(ctx, "ArcRight", prongTips[2], v3(0.48, 7.24, 0))
	for _, pair in ipairs({ { "IdleArcLeft", arcLeft, arcCentre }, { "IdleArcRight", arcCentre, arcRight } }) do
		local beam = Instance.new("Beam")
		beam.Name = pair[1]
		beam.Attachment0 = pair[2]
		beam.Attachment1 = pair[3]
		beam.Color = ColorSequence.new(rgb(255, 250, 200), VOLT)
		beam.Width0 = 0.07
		beam.Width1 = 0.07
		beam.LightEmission = 1
		beam.LightInfluence = 0
		beam.FaceCamera = true
		beam.Segments = 12
		beam.CurveSize0 = 0.3
		beam.CurveSize1 = -0.3
		beam.Parent = spearNode
	end

	local core = attachment(ctx, "Core", socket, v3(0.55, 5.7, 0))
	local tip = attachment(ctx, "Tip", spearNode, tipPosition)
	emitter(core, "IdleSparks", "sparks", VOLT, WHITE, { rate = 5 })
	emitter(arcCentre, "IdleCrackle", "sparks", WHITE, VOLT, { rate = 3, scale = 0.7 })
	standardFX(ctx, {
		core = core,
		tip = tip,
		tipPosition = tipPosition,
		accent = VOLT,
		accent2 = rgb(255, 252, 210),
		flowFrom = v3(0, 1.3, 0),
		flowTo = v3(0, 4.9, 0),
		equipPreset = "sparks",
		chargePreset = "sparks",
		castPreset = "sparks",
		reelPreset = "sparks",
		catchPreset = "burst",
	})
	emitter(core, "CatchSparks", "sparks", WHITE, VOLT, { count = 40, scale = 1.4 })
end

--------------------------------------------------------------------------------
-- 6 · Hexjaw Reliquary (tier 3)
--------------------------------------------------------------------------------

local function buildHexjawReliquary(ctx)
	local BONE = rgb(222, 212, 186)
	local BONE_DARK = rgb(170, 158, 132)
	local BLACK = rgb(30, 28, 36)
	local HEX = rgb(170, 70, 255)

	buildAnatomy(ctx, {
		grip = BLACK,
		gripMaterial = Mat.Leather,
		wrap = BONE,
		wrapMaterial = Mat.Marble,
		metal = BLACK,
		metalMaterial = Mat.Metal,
		reel = BLACK,
		reelMaterial = Mat.Slate,
		reelAccent = HEX,
		reelAccentMaterial = Mat.Neon,
		reelGlow = true,
		shaftRadius = 0.13,
		guides = { v3(0, 2, 0), v3(0, 3, 0) },
	})

	ball(ctx, 0.3, v3(0, -0.76, 0), { name = "PommelKnob", color = BLACK, material = Mat.Slate })
	tri(ctx, v3(-0.12, -0.8, 0), v3(0.12, -0.8, 0), v3(0, -1.3, 0), 0.12, { name = "BoneSpike", color = BONE, material = Mat.Marble })

	cyl(ctx, v3(0, 1.2, 0), v3(0, 4.7, 0), 0.26, { name = "Staff", color = BLACK, material = Mat.Slate })

	-- Vertebrae neck.
	for _, y in ipairs({ 3.7, 4.05, 4.4 }) do
		disc(ctx, v3(0, y, 0), UP, 0.44, 0.14, { name = "Vertebra", color = BONE, material = Mat.Marble })
	end
	for _, side in ipairs({ -1, 1 }) do
		fang(ctx, v3(0.2 * side, 3.97, 0), UP, v3(side, 0, 0), 0.16, 0.35, 0.1, { name = "VertebraSpine", color = BONE_DARK, material = Mat.Marble })
	end

	-- Eel skull staring back at the angler, jaws gaping upward.
	ball(ctx, 0.95, v3(0, 5.1, 0), { name = "Cranium", color = BONE, material = Mat.Marble })
	for _, side in ipairs({ -1, 1 }) do
		ball(ctx, 0.3, v3(0.25 * side, 5.2, 0.32), { name = "EyeSocket", color = BLACK, material = Mat.Slate })
		ball(ctx, 0.13, v3(0.25 * side, 5.2, 0.45), { name = "HexEye", color = HEX, material = Mat.Neon, glow = true })
	end
	ball(ctx, 0.14, v3(0, 4.96, 0.42), { name = "NasalCavity", color = BLACK, material = Mat.Slate })
	local TEETH = rgb(245, 240, 225)
	local jaws = {
		{ v3(-0.48, 5.25, 0), v3(-0.14, 5.5, 0), v3(-0.9, 6.95, 0) },
		{ v3(0.48, 5.25, 0), v3(0.14, 5.5, 0), v3(0.85, 6.85, 0) },
	}
	for _, jaw in ipairs(jaws) do
		tri(ctx, jaw[1], jaw[2], jaw[3], 0.28, { name = "Jaw", color = BONE, material = Mat.Marble })
		-- Teeth along the inner edge, pointing into the mouth.
		local inner = jaw[3] - jaw[2]
		local along = inner.Unit
		local inward = v3(-jaw[2].X, 0, 0).Unit
		for _, t in ipairs({ 0.2, 0.46, 0.72 }) do
			fang(ctx, jaw[2] + inner * t, along, inward, 0.18, 0.3, 0.12, { name = "Tooth", color = TEETH, material = Mat.Marble })
		end
	end

	-- The hexed orb floats in the jaws inside a shimmering shell, circled by runes.
	local O = v3(0, 6.25, 0)
	local float = { pivot = O, bob = 0.1, bobSpeed = 1.2 }
	local orb = ball(ctx, 0.5, O, { name = "HexOrb", color = HEX, material = Mat.Neon, glow = true, motion = float })
	local shell = ball(ctx, 0.85, O, { name = "HexShell", color = HEX, material = Mat.ForceField, motion = float })
	ringOf(ctx, 6, O, v3(0.35, 1, 0.2), 0.72, v3(0.1, 0.22, 0.05), {
		name = "Rune",
		color = HEX,
		material = Mat.Neon,
		glow = true,
		glowPhase = 0.25,
		motion = { pivot = O, axis = v3(0.35, 1, 0.2), spin = 1, bob = 0.1, bobSpeed = 1.2 },
	})

	-- Chains hanging from the skull.
	for _, side in ipairs({ -1, 1 }) do
		local chainPivot = v3(0.42 * side, 4.9, 0)
		local chainSwing = { pivot = chainPivot, axis = HELD_FORWARD, sway = 0.12, swaySpeed = 1.1, phase = side }
		for i, y in ipairs({ 4.78, 4.62, 4.46 }) do
			local size = if i % 2 == 1 then v3(0.06, 0.2, 0.12) else v3(0.12, 0.2, 0.06)
			block(ctx, size, CFrame.new(0.42 * side, y, 0), {
				name = "ChainLink",
				color = BLACK,
				material = Mat.Metal,
				motion = chainSwing,
				hang = hangFrom(chainPivot),
			})
		end
	end

	local tipPosition = O + v3(0, 0.26, 0)
	local core = attachment(ctx, "Core", orb, O)
	local tip = attachment(ctx, "Tip", orb, tipPosition)
	emitter(core, "IdleSmoke", "smoke", HEX, rgb(60, 20, 90), { rate = 3, scale = 0.7 })
	emitter(core, "IdleMotes", "motes", HEX, rgb(220, 180, 255), { rate = 4 })
	standardFX(ctx, {
		core = core,
		tip = tip,
		tipPosition = tipPosition,
		accent = HEX,
		accent2 = rgb(215, 170, 255),
		flowFrom = v3(0, 1.3, 0),
		flowTo = v3(0, 4.6, 0),
		chargePreset = "swirl",
		reelPreset = "smoke",
		catchPreset = "burst",
		catchDelay = 0.3,
	})
	emitter(shell, "CatchImplode", "implode", rgb(220, 180, 255), HEX, { count = 40, scale = 1.5 })
end

--------------------------------------------------------------------------------
-- 7 · Rimefall Glaive (tier 3)
--------------------------------------------------------------------------------

local function buildRimefallGlaive(ctx)
	local SILVER = rgb(200, 214, 228)
	local SILVER_DARK = rgb(120, 134, 150)
	local ICE = rgb(150, 205, 240)
	local CYAN = rgb(120, 225, 255)

	buildAnatomy(ctx, {
		grip = rgb(52, 64, 84),
		gripMaterial = Mat.Fabric,
		wrap = SILVER,
		wrapMaterial = Mat.Foil,
		metal = SILVER,
		metalMaterial = Mat.Foil,
		reel = SILVER_DARK,
		reelMaterial = Mat.Metal,
		reelAccent = CYAN,
		reelAccentMaterial = Mat.Neon,
		reelGlow = true,
		shaftRadius = 0.12,
		guides = { v3(0, 2.2, 0), v3(0, 3.4, 0) },
	})

	disc(ctx, v3(0, -0.72, 0), UP, 0.34, 0.1, { name = "PommelCap", color = SILVER, material = Mat.Foil })
	tri(ctx, v3(-0.13, -0.76, 0), v3(0.13, -0.76, 0), v3(0, -1.35, 0), 0.14, {
		name = "IcePommel",
		color = ICE,
		material = Mat.Ice,
		transparency = 0.15,
	})

	cyl(ctx, v3(0, 1.2, 0), v3(0, 4.5, 0), 0.24, { name = "Shaft", color = SILVER, material = Mat.Foil })
	for _, y in ipairs({ 2.8, 3.9 }) do
		disc(ctx, v3(0, y, 0), UP, 0.32, 0.12, { name = "IceBand", color = ICE, material = Mat.Ice, transparency = 0.2 })
	end

	-- Crossguard with ice crystals and a frozen gem.
	block(ctx, v3(1.5, 0.16, 0.3), CFrame.new(0.1, 4.55, 0), { name = "Crossguard", color = SILVER, material = Mat.Foil })
	tri(ctx, v3(-0.65, 4.5, 0), v3(-0.5, 4.62, 0), v3(-0.95, 5.25, 0), 0.16, { name = "GuardCrystal", color = ICE, material = Mat.Ice })
	tri(ctx, v3(0.85, 4.5, 0), v3(0.7, 4.62, 0), v3(1.2, 5.15, 0), 0.16, { name = "GuardCrystal", color = ICE, material = Mat.Ice })
	ball(ctx, 0.34, v3(0.1, 4.55, 0), { name = "FrostGem", color = CYAN, material = Mat.Neon, glow = true })

	-- Icicles hanging under the guard.
	for i, icicle in ipairs({ { -0.45, 0.35 }, { -0.15, 0.5 }, { 0.35, 0.4 }, { 0.65, 0.3 } }) do
		fang(ctx, v3(icicle[1], 4.47, 0), v3(if i % 2 == 0 then 1 else -1, 0, 0), v3(0, -1, 0), 0.12, icicle[2], 0.1, {
			name = "Icicle",
			color = ICE,
			material = Mat.Ice,
			transparency = 0.1,
		})
	end

	-- The curved ice blade.
	local s0, s1, s2 = v3(-0.12, 4.65, 0), v3(-0.06, 5.75, 0), v3(0.18, 6.85, 0)
	local e0, e1, e2 = v3(0.38, 4.65, 0), v3(0.5, 5.75, 0), v3(0.68, 6.75, 0)
	local T = v3(0.62, 7.85, 0)
	local bladeSpec = { name = "IceBlade", color = ICE, material = Mat.Ice, transparency = 0.2 }
	tri(ctx, s0, s1, e0, 0.12, bladeSpec)
	tri(ctx, s1, e1, e0, 0.12, bladeSpec)
	tri(ctx, s1, s2, e1, 0.12, bladeSpec)
	tri(ctx, s2, e2, e1, 0.12, bladeSpec)
	tri(ctx, s2, T, e2, 0.12, bladeSpec)
	local edgeTop
	for i, segment in ipairs({ { e0, e1 }, { e1, e2 }, { e2, T } }) do
		edgeTop = bar(ctx, segment[1], segment[2], 0.07, 0.16, {
			name = "FrostEdge",
			color = CYAN,
			material = Mat.Neon,
			glow = true,
			glowPhase = i * 0.12,
		})
	end
	local spine = bar(ctx, s0, s1, 0.09, 0.18, { name = "BladeSpine", color = SILVER, material = Mat.Foil })
	bar(ctx, s1, s2, 0.09, 0.18, { name = "BladeSpine", color = SILVER, material = Mat.Foil })

	-- Frost crystals circling the blade.
	for i = 1, 3 do
		local angle = (i - 1) * 2 * math.pi / 3
		local position = v3(0.25 + math.cos(angle) * 0.75, 4.6 + i * 0.7, math.sin(angle) * 0.75)
		block(ctx, v3(0.16, 0.34, 0.16), CFrame.new(position) * CFrame.Angles(0, angle, math.rad(45)), {
			name = "FrostCrystal",
			color = CYAN,
			material = Mat.Neon,
			glow = true,
			glowPhase = i / 3,
			motion = { pivot = v3(0.25, 6, 0), axis = UP, spin = 0.7, bob = 0.08, bobSpeed = 1.6, phase = i * 2 },
		})
	end

	local tipPosition = T + v3(0, 0.04, 0)
	local core = attachment(ctx, "Core", spine, v3(0.22, 6, 0))
	local tip = attachment(ctx, "Tip", edgeTop, tipPosition)
	emitter(core, "IdleSnow", "frost", WHITE, CYAN, { rate = 6 })
	emitter(core, "IdleGlint", "motes", CYAN, WHITE, { rate = 3 })
	standardFX(ctx, {
		core = core,
		tip = tip,
		tipPosition = tipPosition,
		accent = CYAN,
		accent2 = rgb(225, 248, 255),
		flowFrom = v3(0, 1.3, 0),
		flowTo = v3(0, 4.4, 0),
		chargePreset = "frost",
		reelPreset = "frost",
		catchPreset = "shards",
	})
	emitter(core, "CatchMist", "puff", WHITE, CYAN, { count = 6, scale = 0.8 })
end

--------------------------------------------------------------------------------
-- 8 · Calderaheart Maul (tier 4)
--------------------------------------------------------------------------------

local function buildCalderaheartMaul(ctx)
	local OBSIDIAN = rgb(24, 20, 24)
	local BASALT = rgb(64, 50, 44)
	local LAVA = rgb(255, 96, 24)
	local EMBER = rgb(255, 190, 80)

	buildAnatomy(ctx, {
		grip = rgb(40, 30, 28),
		gripMaterial = Mat.Leather,
		wrap = BASALT,
		wrapMaterial = Mat.Basalt,
		metal = BASALT,
		metalMaterial = Mat.Basalt,
		reel = OBSIDIAN,
		reelMaterial = Mat.Basalt,
		reelAccent = LAVA,
		reelAccentMaterial = Mat.Neon,
		reelGlow = true,
		shaftRadius = 0.16,
		guides = { v3(0, 2.2, 0), v3(0, 3.4, 0) },
	})

	ball(ctx, 0.46, v3(0, -0.86, 0), { name = "MagmaPommel", color = BASALT, material = Mat.CrackedLava })
	for _, side in ipairs({ -1, 1 }) do
		fang(ctx, v3(0.12 * side, -0.95, 0), v3(side, 0, 0), v3(0.5 * side, -1, 0), 0.14, 0.3, 0.1, {
			name = "PommelSpike",
			color = OBSIDIAN,
			material = Mat.Basalt,
		})
	end

	-- Obsidian haft with lava veins.
	cyl(ctx, v3(0, 1.2, 0), v3(0, 5.25, 0), 0.32, { name = "Haft", color = OBSIDIAN, material = Mat.Basalt })
	for i, side in ipairs({ -1, 1 }) do
		bar(ctx, v3(0.15 * side, 1.6, 0), v3(0.15 * side, 4.9, 0), 0.05, 0.06, {
			name = "LavaVein",
			color = LAVA,
			material = Mat.Neon,
			glow = true,
			glowPhase = i * 0.1,
		})
	end
	for _, y in ipairs({ 2.8, 4 }) do
		disc(ctx, v3(0, y, 0), UP, 0.4, 0.14, { name = "MagmaBand", color = BASALT, material = Mat.CrackedLava })
	end

	-- Maul head with molten end caps.
	block(ctx, v3(2.2, 0.85, 0.85), CFrame.new(0, 5.55, 0), { name = "MaulHead", color = OBSIDIAN, material = Mat.Basalt })
	for _, side in ipairs({ -1, 1 }) do
		disc(ctx, v3(1.15 * side, 5.55, 0), v3(1, 0, 0), 1.05, 0.28, { name = "MaulCap", color = BASALT, material = Mat.CrackedLava })
		disc(ctx, v3(1.31 * side, 5.55, 0), v3(1, 0, 0), 0.75, 0.06, {
			name = "MaulCapGlow",
			color = LAVA,
			material = Mat.Neon,
			glow = true,
			glowPhase = 0.1,
		})
		fang(ctx, v3(0.6 * side, 5.12, 0), v3(side, 0, 0), v3(0, -1, 0), 0.2, 0.35, 0.16, {
			name = "HeadSpike",
			color = OBSIDIAN,
			material = Mat.Basalt,
		})
	end

	-- The beating molten heart, held by four obsidian claws.
	local H = v3(0, 6.45, 0)
	local heart = ball(ctx, 1, H, {
		name = "MoltenHeart",
		color = LAVA,
		material = Mat.Neon,
		glow = true,
		motion = { pivot = H, scalePulse = 0.08 },
	})
	local clawSpec = { name = "HeartClaw", color = OBSIDIAN, material = Mat.Basalt }
	tri(ctx, v3(-0.45, 5.95, 0), v3(-0.2, 5.95, 0), v3(-0.62, 6.95, 0), 0.22, clawSpec)
	tri(ctx, v3(0.45, 5.95, 0), v3(0.2, 5.95, 0), v3(0.62, 6.95, 0), 0.22, clawSpec)
	tri(ctx, v3(0, 5.95, -0.45), v3(0, 5.95, -0.2), v3(0, 6.95, -0.62), 0.22, clawSpec)
	tri(ctx, v3(0, 5.95, 0.45), v3(0, 5.95, 0.2), v3(0, 6.95, 0.62), 0.22, clawSpec)

	-- Horns sweeping up from the caps, with molten tips.
	for _, side in ipairs({ -1, 1 }) do
		local a, b, c = v3(0.95 * side, 5.95, 0), v3(1.3 * side, 6.55, 0), v3(1.28 * side, 7.05, 0)
		cyl(ctx, a, b, 0.3, { name = "Horn", color = OBSIDIAN, material = Mat.Basalt })
		ball(ctx, 0.26, b, { name = "Horn", color = OBSIDIAN, material = Mat.Basalt })
		cyl(ctx, b, c, 0.24, { name = "Horn", color = OBSIDIAN, material = Mat.Basalt })
		tri(ctx, v3(1.16 * side, 7, 0), v3(1.4 * side, 7, 0), v3(1.05 * side, 7.65, 0), 0.2, {
			name = "HornTip",
			color = LAVA,
			material = Mat.Neon,
			glow = true,
			glowPhase = 0.2,
		})
	end

	-- Magma rocks orbiting the heart.
	local orbitAxis = v3(0.25, 1, -0.15)
	for i = 1, 4 do
		local angle = (i - 1) * math.pi / 2
		local offset = v3(math.cos(angle) * 1.2, 0, math.sin(angle) * 1.2)
		ball(ctx, 0.28 + (i % 2) * 0.08, H + offset, {
			name = "OrbitingMagma",
			color = BASALT,
			material = Mat.CrackedLava,
			motion = { pivot = H, axis = orbitAxis, spin = 0.9, bob = 0.06, bobSpeed = 2, phase = i },
		})
	end

	-- Crown spike where the line leaves.
	tri(ctx, v3(-0.14, 6.9, 0), v3(0.14, 6.9, 0), v3(0, 7.75, 0), 0.16, { name = "CrownSpike", color = OBSIDIAN, material = Mat.Basalt })
	local tipPosition = v3(0, 7.85, 0)
	local tipNode = ball(ctx, 0.14, v3(0, 7.78, 0), { name = "TipNode", color = LAVA, material = Mat.Neon, glow = true })

	local core = attachment(ctx, "Core", heart, H)
	local tip = attachment(ctx, "Tip", tipNode, tipPosition)
	emitter(core, "IdleEmbers", "embers", LAVA, EMBER, { rate = 10 })
	emitter(core, "IdleFlames", "fire", LAVA, EMBER, { rate = 5, scale = 0.8 })
	emitter(core, "IdleHeat", "smoke", rgb(70, 46, 34), rgb(30, 24, 22), { rate = 2 })
	standardFX(ctx, {
		core = core,
		tip = tip,
		tipPosition = tipPosition,
		accent = LAVA,
		accent2 = EMBER,
		lightRange = 16,
		flowFrom = v3(0, 1.3, 0),
		flowTo = v3(0, 5, 0),
		equipPreset = "fire",
		chargePreset = "embers",
		castPreset = "fire",
		reelPreset = "fire",
		catchPreset = "burst",
	})
	emitter(core, "CatchEruption", "fountain", EMBER, LAVA, { count = 80 })
	emitter(core, "CatchSmoke", "puff", rgb(90, 60, 40), rgb(30, 24, 22), { count = 10, scale = 1.2 })
end

--------------------------------------------------------------------------------
-- 9 · Deepmaw Beacon (tier 4)
--------------------------------------------------------------------------------

local function buildDeepmawBeacon(ctx)
	local NAVY = rgb(16, 24, 44)
	local NAVY_LIGHT = rgb(30, 44, 74)
	local BONE = rgb(226, 220, 198)
	local TEAL = rgb(0, 255, 200)

	buildAnatomy(ctx, {
		grip = rgb(24, 32, 52),
		gripMaterial = Mat.Leather,
		wrap = BONE,
		wrapMaterial = Mat.Marble,
		metal = BONE,
		metalMaterial = Mat.Marble,
		reel = NAVY,
		reelMaterial = Mat.Slate,
		reelAccent = TEAL,
		reelAccentMaterial = Mat.Neon,
		reelGlow = true,
		shaftRadius = 0.15,
		guides = { v3(0, 2.2, 0), v3(0, 3.4, 0) },
	})

	ball(ctx, 0.36, v3(0, -0.78, 0), { name = "PommelKnob", color = NAVY, material = Mat.Slate })
	tri(ctx, v3(0, -0.84, 0), v3(-0.35, -1.35, 0), v3(0.35, -1.35, 0), 0.05, {
		name = "TailFin",
		color = BONE,
		material = Mat.Glass,
		transparency = 0.3,
	})

	-- Spine shaft with photophores.
	cyl(ctx, v3(0, 1.2, 0), v3(0, 4.9, 0), 0.3, { name = "SpineShaft", color = NAVY, material = Mat.Slate })
	for _, y in ipairs({ 2.6, 3.4, 4.2 }) do
		disc(ctx, v3(0, y, 0), UP, 0.4, 0.12, { name = "Vertebra", color = BONE, material = Mat.Marble })
	end
	for i, y in ipairs({ 3, 3.8 }) do
		ball(ctx, 0.1, v3(0, y, 0.15), { name = "Photophore", color = TEAL, material = Mat.Neon, glow = true, glowPhase = i * 0.3 })
	end

	-- Anglerfish head facing +X with a huge underbite.
	local cranium = ball(ctx, 1.3, v3(-0.15, 5.85, 0), { name = "Cranium", color = NAVY, material = Mat.Slate })
	local upperC, upperB = v3(0.15, 5.85, 0), v3(1.25, 6.3, 0)
	tri(ctx, v3(-0.55, 6.4, 0), upperB, upperC, 0.7, { name = "UpperJaw", color = NAVY_LIGHT, material = Mat.Slate })
	local hinge = { pivot = v3(-0.1, 5.6, 0), axis = v3(0, 0, 1), sway = 0.07, swaySpeed = 0.9 }
	local lowerF, lowerE = v3(0.15, 5.62, 0), v3(1.4, 5, 0)
	tri(ctx, v3(-0.55, 5.15, 0), lowerE, lowerF, 0.75, { name = "LowerJaw", color = NAVY, material = Mat.Slate, motion = hinge })

	local fangSpec = { name = "Fang", color = BONE, material = Mat.Glass, transparency = 0.15 }
	local upperAlong = (upperB - upperC).Unit
	for i, t in ipairs({ 0.35, 0.7, 1 }) do
		local z = if i % 2 == 0 then -0.15 else 0.15
		fang(ctx, upperC + upperAlong * t + v3(0, 0, z), upperAlong, v3(0, -1, 0), 0.14, 0.2 + i * 0.07, 0.12, fangSpec)
	end
	local lowerAlong = (lowerE - lowerF).Unit
	local lowerFangSpec = { name = "Fang", color = BONE, material = Mat.Glass, transparency = 0.15, motion = hinge }
	for i, t in ipairs({ 0.35, 0.75, 1.1 }) do
		local z = if i % 2 == 0 then 0.15 else -0.15
		fang(ctx, lowerF + lowerAlong * t + v3(0, 0, z), lowerAlong, v3(0, 1, 0), 0.14, 0.24 + i * 0.07, 0.12, lowerFangSpec)
	end
	for _, side in ipairs({ -1, 1 }) do
		ball(ctx, 0.16, v3(0.1, 6.15, 0.36 * side), { name = "PaleEye", color = TEAL, material = Mat.Neon, glow = true })
	end
	tri(ctx, v3(-0.6, 6.2, 0), v3(-0.4, 6.4, 0), v3(-1.15, 6.95, 0), 0.06, { name = "DorsalSpine", color = NAVY_LIGHT, material = Mat.Slate })
	tri(ctx, v3(-0.75, 5.9, 0), v3(-0.6, 6.15, 0), v3(-1.35, 6.35, 0), 0.06, { name = "DorsalSpine", color = NAVY_LIGHT, material = Mat.Slate })
	for i, position in ipairs({ v3(-0.35, 6.1, 0.56), v3(-0.55, 5.75, 0.5) }) do
		ball(ctx, 0.09, position, { name = "BioSpot", color = TEAL, material = Mat.Neon, glow = true, glowPhase = 0.4 + i * 0.2 })
	end

	-- The illicium arches over the mouth and dangles the glowing lure.
	local stalk = { v3(-0.2, 6.5, 0), v3(0, 7.25, 0), v3(0.6, 7.7, 0), v3(1.25, 7.55, 0), v3(1.6, 7.05, 0) }
	local stalkWidths = { 0.12, 0.1, 0.09, 0.08 }
	for i = 1, #stalk - 1 do
		cyl(ctx, stalk[i], stalk[i + 1], stalkWidths[i], { name = "Illicium", color = BONE, material = Mat.Marble })
		if i > 1 then
			ball(ctx, stalkWidths[i], stalk[i], { name = "Illicium", color = BONE, material = Mat.Marble })
		end
	end
	local lureCenter = v3(1.6, 6.45, 0)
	local lureHang = hangFrom(stalk[5])
	local lureSwing = { pivot = stalk[5], axis = HELD_FORWARD, sway = 0.22, swaySpeed = 1.3 }
	cyl(ctx, stalk[5], lureCenter + v3(0, 0.18, 0), 0.04, {
		name = "LureThread",
		color = BONE,
		material = Mat.Marble,
		motion = lureSwing,
		hang = lureHang,
	})
	local esca = ball(ctx, 0.38, lureCenter, {
		name = "Esca",
		color = TEAL,
		material = Mat.Neon,
		glow = true,
		motion = lureSwing,
		hang = lureHang,
	})
	ball(ctx, 0.62, lureCenter, {
		name = "EscaHalo",
		color = TEAL,
		material = Mat.ForceField,
		motion = lureSwing,
		hang = lureHang,
	})

	local tipPosition = lureHang * (lureCenter - v3(0, 0.2, 0))
	local core = attachment(ctx, "Core", cranium, v3(0.45, 5.75, 0))
	local lure = attachment(ctx, "Lure", esca, lureHang * lureCenter)
	local tip = attachment(ctx, "Tip", esca, tipPosition)
	emitter(core, "IdleMotes", "motes", TEAL, rgb(200, 255, 240), { rate = 8 })
	emitter(lure, "IdleLureGlints", "sparks", WHITE, TEAL, { rate = 4, scale = 0.7 })
	standardFX(ctx, {
		core = core,
		tip = tip,
		tipPosition = tipPosition,
		lightParent = lure,
		lightRange = 16,
		accent = TEAL,
		accent2 = rgb(190, 255, 240),
		flowFrom = v3(0, 1.3, 0),
		flowTo = v3(0, 4.8, 0),
		reelPreset = "motes",
		catchPreset = "burst",
	})
	emitter(core, "CatchPlankton", "motes", TEAL, WHITE, { count = 90, scale = 1.6 })
	emitter(core, "CatchGlow", "puff", TEAL, rgb(0, 120, 110), { count = 6 })
end

--------------------------------------------------------------------------------
-- 10 · Redtide Sovereign (tier 4)
--------------------------------------------------------------------------------

local function buildRedtideSovereign(ctx)
	local BLACK = rgb(18, 14, 18)
	local GOLD = rgb(188, 146, 70)
	local BLOOD = rgb(255, 28, 52)

	buildAnatomy(ctx, {
		grip = rgb(40, 18, 24),
		gripMaterial = Mat.Leather,
		wrap = GOLD,
		wrapMaterial = Mat.Foil,
		metal = GOLD,
		metalMaterial = Mat.Foil,
		reel = BLACK,
		reelMaterial = Mat.Slate,
		reelAccent = BLOOD,
		reelAccentMaterial = Mat.Neon,
		reelGlow = true,
		shaftRadius = 0.14,
		guides = { v3(0, 2.2, 0), v3(0, 3.3, 0) },
	})

	ball(ctx, 0.34, v3(0, -0.78, 0), { name = "PommelOrb", color = GOLD, material = Mat.Foil })
	tri(ctx, v3(-0.12, -0.85, 0), v3(0.12, -0.85, 0), v3(0, -1.35, 0), 0.12, { name = "PommelSpike", color = BLACK, material = Mat.Slate })

	-- Sceptre shaft.
	cyl(ctx, v3(0, 1.2, 0), v3(0, 5, 0), 0.28, { name = "Sceptre", color = BLACK, material = Mat.Slate })
	for _, y in ipairs({ 2, 2.9, 4 }) do
		disc(ctx, v3(0, y, 0), UP, 0.36, 0.1, { name = "GoldBand", color = GOLD, material = Mat.Foil })
	end
	block(ctx, v3(0.12, 0.3, 0.12), CFrame.new(0, 3.45, 0.14) * CFrame.Angles(0, math.rad(45), 0), {
		name = "BloodGem",
		color = BLOOD,
		material = Mat.Neon,
		glow = true,
	})
	local collar = disc(ctx, v3(0, 5, 0), UP, 0.5, 0.18, { name = "Collar", color = GOLD, material = Mat.Foil })
	for _, side in ipairs({ -1, 1 }) do
		bar(ctx, v3(0.12 * side, 5.05, 0), v3(0.55 * side, 5.55, 0), 0.08, 0.08, { name = "Cradle", color = GOLD, material = Mat.Foil })
	end

	-- The eclipse: a black moon in front of a blood-red corona.
	local O = v3(0, 6.05, 0)
	disc(ctx, O, v3(0, 0, 1), 1.75, 0.06, { name = "Corona", color = BLOOD, material = Mat.Neon, glow = true })
	local moon = ball(ctx, 1.3, O, { name = "EclipsedMoon", color = BLACK, material = Mat.Slate, reflectance = 0.05 })
	for i = 0, 5 do
		local angle = math.rad(30 + i * 60)
		local direction = v3(math.cos(angle), math.sin(angle), 0)
		bar(ctx, O + direction * 0.9, O + direction * 1.32, 0.07, 0.06, {
			name = "CoronaRay",
			color = BLOOD,
			material = Mat.Neon,
			glow = true,
			glowPhase = i / 6,
			motion = { pivot = O, axis = v3(0, 0, 1), spin = 0.5 },
		})
	end

	-- Gold spire through a floating, spinning crown.
	tri(ctx, v3(-0.11, 6.65, 0), v3(0.11, 6.65, 0), v3(0, 7.95, 0), 0.12, { name = "Spire", color = GOLD, material = Mat.Foil })
	local crownCenter = v3(0, 7.15, 0)
	local crownMotion = { pivot = crownCenter, axis = UP, spin = 0.8, bob = 0.1, bobSpeed = 1.4 }
	disc(ctx, crownCenter, UP, 0.8, 0.22, { name = "CrownBand", color = GOLD, material = Mat.Foil, motion = crownMotion })
	for k = 0, 4 do
		local angle = k * 2 * math.pi / 5
		local radial = v3(math.cos(angle), 0, math.sin(angle))
		local tangent = v3(-math.sin(angle), 0, math.cos(angle))
		fang(ctx, crownCenter + radial * 0.4 + v3(0, 0.1, 0) - tangent * 0.1, tangent, UP, 0.2, 0.32, 0.06, {
			name = "CrownPoint",
			color = GOLD,
			material = Mat.Foil,
			motion = crownMotion,
		})
	end

	-- Translucent blood wings with gold leading edges, flapping slowly.
	for _, side in ipairs({ -1, 1 }) do
		local wingMotion = { pivot = v3(0.7 * side, 6.05, 0), axis = v3(0, side, 0), sway = 0.22, swaySpeed = 1.2 }
		local root, rootLow = v3(0.65 * side, 6.15, 0), v3(0.65 * side, 5.95, 0)
		local tipHigh, mid, tipLow = v3(2.1 * side, 7.35, 0.1), v3(1.55 * side, 5.75, 0.1), v3(1.25 * side, 4.95, 0.05)
		local wingSpec = { name = "BloodWing", color = BLOOD, material = Mat.ForceField, glow = true, glowPhase = 0.3, motion = wingMotion }
		tri(ctx, root, tipHigh, mid, 0.05, wingSpec)
		tri(ctx, rootLow, mid, tipLow, 0.05, wingSpec)
		bar(ctx, root, tipHigh, 0.08, 0.08, { name = "WingBone", color = GOLD, material = Mat.Foil, motion = wingMotion })
		bar(ctx, rootLow, tipLow, 0.07, 0.07, { name = "WingBone", color = GOLD, material = Mat.Foil, motion = wingMotion })
	end

	local tipPosition = v3(0, 7.97, 0)
	local spireTop = ball(ctx, 0.1, v3(0, 7.92, 0), { name = "SpireTip", color = BLOOD, material = Mat.Neon, glow = true })
	local core = attachment(ctx, "Core", moon, O)
	local aura = attachment(ctx, "Aura", collar, v3(0, 5.2, 0))
	local tip = attachment(ctx, "Tip", spireTop, tipPosition)
	emitter(aura, "IdleMotes", "embers", BLOOD, rgb(255, 140, 150), { rate = 8 })
	emitter(core, "IdlePetals", "petals", BLOOD, rgb(120, 0, 20), { rate = 2 })
	standardFX(ctx, {
		core = core,
		tip = tip,
		tipPosition = tipPosition,
		lightRange = 16,
		accent = BLOOD,
		accent2 = rgb(255, 150, 160),
		flowFrom = v3(0, 1.3, 0),
		flowTo = v3(0, 4.9, 0),
		equipPreset = "petals",
		reelPreset = "embers",
		catchPreset = "burst",
	})
	emitter(core, "CatchPetals", "petals", BLOOD, rgb(120, 0, 20), { count = 70, scale = 1.3 })
end

--------------------------------------------------------------------------------
-- The lineup
--------------------------------------------------------------------------------

local RODS = {
	{
		name = "Wickwood Lantern",
		id = "wickwood_lantern",
		tier = 1,
		tooltip = "Tier 1 · A lighthouse keeper's driftwood crook",
		accent = rgb(255, 170, 60),
		pulse = { shape = "flicker", speed = 1, depth = 0.25 },
		build = buildWickwoodLantern,
	},
	{
		name = "Kelpcoil Whip",
		id = "kelpcoil_whip",
		tier = 2,
		tooltip = "Tier 2 · A living stalk from the kelp forest",
		accent = rgb(160, 255, 80),
		pulse = { shape = "sine", speed = 0.9, depth = 0.3 },
		build = buildKelpcoilWhip,
	},
	{
		name = "Tollkeeper's Bell",
		id = "tollkeepers_bell",
		tier = 2,
		tooltip = "Tier 2 · Rings the bell buoy's warning",
		accent = rgb(225, 238, 255),
		pulse = { shape = "sine", speed = 0.57, depth = 0.3 },
		catchRings = 1,
		ringSize = 7,
		idleRingPeriod = 3.5,
		build = buildTollkeepersBell,
	},
	{
		name = "Reefbranch Crook",
		id = "reefbranch_crook",
		tier = 2,
		tooltip = "Tier 2 · Coral antlers from the shelves",
		accent = rgb(255, 70, 150),
		pulse = { shape = "sine", speed = 0.6, depth = 0.5 },
		build = buildReefbranchCrook,
	},
	{
		name = "Squall Cleaver",
		id = "squall_cleaver",
		tier = 3,
		tooltip = "Tier 3 · Forged in the eye of a storm",
		accent = rgb(255, 232, 70),
		pulse = { shape = "flicker", speed = 1.5, depth = 0.35 },
		build = buildSquallCleaver,
	},
	{
		name = "Hexjaw Reliquary",
		id = "hexjaw_reliquary",
		tier = 3,
		tooltip = "Tier 3 · An eel skull that never stopped hungering",
		accent = rgb(170, 70, 255),
		pulse = { shape = "sine", speed = 0.45, depth = 0.4 },
		build = buildHexjawReliquary,
	},
	{
		name = "Rimefall Glaive",
		id = "rimefall_glaive",
		tier = 3,
		tooltip = "Tier 3 · Cut from the frozen waterfall",
		accent = rgb(120, 225, 255),
		pulse = { shape = "sine", speed = 0.35, depth = 0.25 },
		build = buildRimefallGlaive,
	},
	{
		name = "Calderaheart Maul",
		id = "calderaheart_maul",
		tier = 4,
		tooltip = "Tier 4 · The volcano's heart, still beating",
		accent = rgb(255, 96, 24),
		pulse = { shape = "heartbeat", speed = 1.1, depth = 0.55 },
		catchRings = 2,
		ringSize = 16,
		build = buildCalderaheartMaul,
	},
	{
		name = "Deepmaw Beacon",
		id = "deepmaw_beacon",
		tier = 4,
		tooltip = "Tier 4 · What waits below the bell buoy",
		accent = rgb(0, 255, 200),
		pulse = { shape = "sine", speed = 0.35, depth = 0.45 },
		catchRings = 2,
		ringSize = 18,
		build = buildDeepmawBeacon,
	},
	{
		name = "Redtide Sovereign",
		id = "redtide_sovereign",
		tier = 4,
		tooltip = "Tier 4 · Crowned by the Blood Moon",
		accent = rgb(255, 28, 52),
		pulse = { shape = "sine", speed = 0.6, depth = 0.45 },
		catchRings = 2,
		ringSize = 18,
		build = buildRedtideSovereign,
	},
}

--------------------------------------------------------------------------------
-- Build
--------------------------------------------------------------------------------

local function newRod(index, def)
	local tool = Instance.new("Tool")
	tool.Name = def.name
	tool.ToolTip = def.tooltip
	tool.CanBeDropped = false
	tool.RequiresHandle = true
	tool.Grip = GRIP
	tool:SetAttribute("OddtideRod", true)
	tool:SetAttribute("RodId", def.id)
	tool:SetAttribute("ArtRevision", ART_REVISION)
	tool:SetAttribute("Tier", def.tier)
	tool:SetAttribute("AccentColor", def.accent)
	tool:SetAttribute("FXPulseShape", def.pulse.shape)
	tool:SetAttribute("FXPulseSpeed", def.pulse.speed)
	tool:SetAttribute("FXPulseDepth", def.pulse.depth)
	tool:SetAttribute("FXCatchRings", def.catchRings or 0)
	tool:SetAttribute("FXRingSize", def.ringSize or 10)
	tool:SetAttribute("FXIdleRingPeriod", def.idleRingPeriod or 0)

	local origin = CFrame.new((index - 1) * ROD_SPACING, 5, 0)
	local handle = Instance.new("Part")
	handle.Name = "Handle"
	handle.Shape = Enum.PartType.Cylinder
	handle.Size = v3(1.2, 0.4, 0.4)
	handle.CFrame = origin * HANDLE_IN_ROD
	handle.Anchored = false
	handle.CanCollide = false
	handle.CanQuery = false
	handle.Massless = true
	handle.CastShadow = false
	handle.TopSurface = Enum.SurfaceType.Smooth
	handle.BottomSurface = Enum.SurfaceType.Smooth
	handle.Parent = tool

	return { tool = tool, handle = handle, origin = origin, count = 1, def = def }
end

local function validate(ctx)
	local problems = {}
	if not ctx.tool:FindFirstChild("Tip", true) then
		table.insert(problems, "no Tip attachment")
	end
	if not ctx.tool:FindFirstChild("Core", true) then
		table.insert(problems, "no Core attachment")
	end
	if ctx.count > MAX_PARTS then
		table.insert(problems, ("%d parts (budget %d)"):format(ctx.count, MAX_PARTS))
	end
	return problems
end

pcall(function()
	ChangeHistoryService:SetWaypoint("Before building Oddtide rod drafts")
end)

local existing = ServerStorage:FindFirstChild(FOLDER_NAME)
if existing then
	existing:Destroy()
end
local folder = Instance.new("Folder")
folder.Name = FOLDER_NAME

local built = 0
for index, def in ipairs(RODS) do
	local ctx = newRod(index, def)
	local ok, err = pcall(def.build, ctx)
	if ok then
		local problems = validate(ctx)
		ctx.tool.Parent = folder
		built += 1
		if #problems > 0 then
			warn(("[RodBuilder] %s built with warnings: %s"):format(def.name, table.concat(problems, ", ")))
		else
			print(("[RodBuilder] %s (tier %d): %d parts"):format(def.name, def.tier, ctx.count))
		end
	else
		ctx.tool:Destroy()
		warn(("[RodBuilder] %s failed to build: %s"):format(def.name, tostring(err)))
	end
end

folder.Parent = ServerStorage
pcall(function()
	ChangeHistoryService:SetWaypoint("Built Oddtide rod drafts")
end)
print(("[RodBuilder] Done: %d/%d rods in ServerStorage.%s"):format(built, #RODS, FOLDER_NAME))

-- Lets this file also run as a ModuleScript: require(game.ServerStorage.RodBuilder)
return true
