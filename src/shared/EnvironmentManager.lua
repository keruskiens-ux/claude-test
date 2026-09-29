--[[
	EnvironmentManager
	Unified environment controller for the fishing game:
	  * Day/Night cycle (drives Lighting.ClockTime)
	  * Weather system ("Clear", "Foggy", "Stormy") with smooth TweenService transitions
	  * Ultra Graphics Optimizer (Future lighting, exposure, color grading, Bloom, SunRays, water)

	Usage (from a server Script, so every player sees the same time and weather):

		local EnvironmentManager = require(path.to.EnvironmentManager)
		EnvironmentManager.Init()                  -- runs the optimizer, starts the cycle
		EnvironmentManager.SetWeather("Stormy")    -- tweens over Config.TransitionTime
		EnvironmentManager.SetWeather("Clear", 2)  -- custom transition length
		EnvironmentManager.SetTimeSpeed(0.1)       -- in-game hours per real second
		EnvironmentManager.SetClockTime(18.5)      -- jump to sunset

	Speed and presets can also be changed through EnvironmentManager.Config
	and EnvironmentManager.WeatherPresets before calling Init().
]]

local Lighting = game:GetService("Lighting")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Terrain = workspace:FindFirstChildOfClass("Terrain")

local EnvironmentManager = {}

--------------------------------------------------------------------------------
-- Configuration
--------------------------------------------------------------------------------

EnvironmentManager.Config = {
	-- In-game hours that pass per real second. 0.02 = one full day every 20 minutes.
	TimeSpeed = 0.02,
	StartClockTime = 7.5,
	DayNightEnabled = true,

	DefaultWeather = "Clear",
	-- Seconds a weather change takes to blend in.
	TransitionTime = 8,
	TransitionEasingStyle = Enum.EasingStyle.Sine,
	TransitionEasingDirection = Enum.EasingDirection.InOut,

	-- Baseline "ultra" grade used by the optimizer and the Clear preset.
	-- ColorCorrection Contrast/Saturation accept -1..1; values above ~0.4
	-- start to crush shadows and blow out the water, so these are the highest
	-- values that still look good. Raise them if you want an even punchier look.
	Ultra = {
		ExposureCompensation = 0.25,
		Contrast = 0.3,
		Saturation = 0.35,
		Brightness = 0.03,
	},
}

--------------------------------------------------------------------------------
-- Weather presets
-- Each section is optional. Keys are property names on the matching instance;
-- every value is tweened, so only tweenable types (number, Color3, etc.) belong here.
--------------------------------------------------------------------------------

local Ultra = EnvironmentManager.Config.Ultra

EnvironmentManager.WeatherPresets = {
	Clear = {
		Lighting = {
			Brightness = 3,
			ExposureCompensation = Ultra.ExposureCompensation,
			OutdoorAmbient = Color3.fromRGB(128, 132, 140),
		},
		Atmosphere = {
			Density = 0.3,
			Offset = 0.25,
			Color = Color3.fromRGB(199, 206, 214),
			Decay = Color3.fromRGB(106, 120, 138),
			Glare = 0.35,
			Haze = 1,
		},
		ColorCorrection = {
			Brightness = Ultra.Brightness,
			Contrast = Ultra.Contrast,
			Saturation = Ultra.Saturation,
			TintColor = Color3.fromRGB(255, 252, 245),
		},
		Bloom = { Intensity = 0.7, Size = 24, Threshold = 0.9 },
		SunRays = { Intensity = 0.12, Spread = 0.8 },
		Clouds = { Cover = 0.45, Density = 0.35, Color = Color3.fromRGB(255, 255, 255) },
		Water = { WaterWaveSize = 0.15, WaterWaveSpeed = 10 },
	},

	Foggy = {
		Lighting = {
			Brightness = 2,
			ExposureCompensation = 0.1,
			OutdoorAmbient = Color3.fromRGB(150, 155, 162),
		},
		Atmosphere = {
			Density = 0.72,
			Offset = 0,
			Color = Color3.fromRGB(196, 202, 208),
			Decay = Color3.fromRGB(160, 166, 176),
			Glare = 0,
			Haze = 0.6,
		},
		ColorCorrection = {
			Brightness = 0.02,
			Contrast = -0.05,
			Saturation = -0.2,
			TintColor = Color3.fromRGB(236, 241, 246),
		},
		Bloom = { Intensity = 0.45, Size = 30, Threshold = 0.95 },
		SunRays = { Intensity = 0.03, Spread = 1 },
		Clouds = { Cover = 0.75, Density = 0.55, Color = Color3.fromRGB(225, 228, 232) },
		Water = { WaterWaveSize = 0.08, WaterWaveSpeed = 6 },
	},

	Stormy = {
		Lighting = {
			Brightness = 1.2,
			ExposureCompensation = -0.3,
			OutdoorAmbient = Color3.fromRGB(88, 94, 108),
		},
		Atmosphere = {
			Density = 0.62,
			Offset = 0.1,
			Color = Color3.fromRGB(108, 116, 128),
			Decay = Color3.fromRGB(58, 64, 78),
			Glare = 0,
			Haze = 2.6,
		},
		-- Moody grade: darker, desaturated, cold blue tint, contrast kept high for drama.
		ColorCorrection = {
			Brightness = -0.08,
			Contrast = 0.22,
			Saturation = -0.35,
			TintColor = Color3.fromRGB(198, 212, 232),
		},
		Bloom = { Intensity = 0.3, Size = 18, Threshold = 1.2 },
		SunRays = { Intensity = 0, Spread = 0.5 },
		Clouds = { Cover = 0.95, Density = 0.9, Color = Color3.fromRGB(78, 84, 96) },
		Water = { WaterWaveSize = 0.4, WaterWaveSpeed = 22 },
	},
}

--------------------------------------------------------------------------------
-- Internal state
--------------------------------------------------------------------------------

local initialized = false
local currentWeather = nil
local clockTime = 0
local heartbeatConnection = nil
local activeTweens = {}
local effects = {}

local weatherChangedEvent = Instance.new("BindableEvent")
-- Fires with (newWeatherName, oldWeatherName).
EnvironmentManager.WeatherChanged = weatherChangedEvent.Event

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local function getOrCreate(parent, className, name)
	local existing = parent:FindFirstChildOfClass(className)
	if existing then
		return existing
	end
	local instance = Instance.new(className)
	instance.Name = name
	instance.Parent = parent
	return instance
end

local function ensureEffects()
	effects.Lighting = Lighting
	effects.Atmosphere = getOrCreate(Lighting, "Atmosphere", "Atmosphere")
	effects.ColorCorrection = getOrCreate(Lighting, "ColorCorrectionEffect", "ColorCorrection")
	effects.Bloom = getOrCreate(Lighting, "BloomEffect", "Bloom")
	effects.SunRays = getOrCreate(Lighting, "SunRaysEffect", "SunRays")
	if Terrain then
		effects.Clouds = getOrCreate(Terrain, "Clouds", "Clouds")
		effects.Water = Terrain
	end
end

local function cancelActiveTweens()
	for _, tween in ipairs(activeTweens) do
		tween:Cancel()
	end
	table.clear(activeTweens)
end

local function applyProperties(instance, properties, tweenInfo)
	if not instance or not properties then
		return
	end
	if tweenInfo then
		local tween = TweenService:Create(instance, tweenInfo, properties)
		table.insert(activeTweens, tween)
		tween:Play()
	else
		for property, value in pairs(properties) do
			instance[property] = value
		end
	end
end

--------------------------------------------------------------------------------
-- Ultra Graphics Optimizer
--------------------------------------------------------------------------------

function EnvironmentManager.OptimizeGraphics()
	ensureEffects()
	local ultra = EnvironmentManager.Config.Ultra

	-- Technology can only be changed from Studio/plugins; game scripts are
	-- blocked from setting it. Try anyway and tell the developer if it fails.
	local ok = pcall(function()
		Lighting.Technology = Enum.Technology.Future
	end)
	if not ok and Lighting.Technology ~= Enum.Technology.Future then
		warn(
			"[EnvironmentManager] Scripts can't set Lighting.Technology. "
				.. "Set it to Future in Studio: Explorer > Lighting > Properties > Technology."
		)
	end

	-- Lighting: full PBR environment lighting and crisp soft shadows.
	Lighting.GlobalShadows = true
	Lighting.ShadowSoftness = 0.15
	Lighting.EnvironmentDiffuseScale = 1
	Lighting.EnvironmentSpecularScale = 1 -- strongest sky reflections on water and metal
	Lighting.ExposureCompensation = ultra.ExposureCompensation

	-- Color grading.
	local colorCorrection = effects.ColorCorrection
	colorCorrection.Enabled = true
	colorCorrection.Brightness = ultra.Brightness
	colorCorrection.Contrast = ultra.Contrast
	colorCorrection.Saturation = ultra.Saturation

	-- Bloom: a high threshold means only bright highlights glow,
	-- so sun glints on the waves sparkle without washing out the scene.
	local bloom = effects.Bloom
	bloom.Enabled = true
	bloom.Intensity = 0.7
	bloom.Size = 24
	bloom.Threshold = 0.9

	-- SunRays: subtle god rays off the sun and water.
	local sunRays = effects.SunRays
	sunRays.Enabled = true
	sunRays.Intensity = 0.12
	sunRays.Spread = 0.8

	-- Water: fully reflective, slightly clear, gentle waves.
	if Terrain then
		Terrain.WaterReflectance = 1
		Terrain.WaterTransparency = 0.35
		Terrain.WaterWaveSize = 0.15
		Terrain.WaterWaveSpeed = 10
		Terrain.WaterColor = Color3.fromRGB(28, 96, 112)
		Terrain.Decoration = true
	end
end

--------------------------------------------------------------------------------
-- Weather
--------------------------------------------------------------------------------

-- Changes the weather. transitionTime defaults to Config.TransitionTime; pass 0 for an instant switch.
function EnvironmentManager.SetWeather(weatherName, transitionTime)
	local preset = EnvironmentManager.WeatherPresets[weatherName]
	if not preset then
		warn(("[EnvironmentManager] Unknown weather preset %q"):format(tostring(weatherName)))
		return false
	end

	ensureEffects()
	cancelActiveTweens()

	local config = EnvironmentManager.Config
	local duration = transitionTime or config.TransitionTime
	local tweenInfo = nil
	if duration > 0 then
		tweenInfo = TweenInfo.new(duration, config.TransitionEasingStyle, config.TransitionEasingDirection)
	end

	for section, properties in pairs(preset) do
		applyProperties(effects[section], properties, tweenInfo)
	end

	local previousWeather = currentWeather
	currentWeather = weatherName
	weatherChangedEvent:Fire(weatherName, previousWeather)
	return true
end

function EnvironmentManager.GetWeather()
	return currentWeather
end

--------------------------------------------------------------------------------
-- Day/Night cycle
--------------------------------------------------------------------------------

-- In-game hours per real second. 0 pauses the clock.
function EnvironmentManager.SetTimeSpeed(hoursPerSecond)
	EnvironmentManager.Config.TimeSpeed = hoursPerSecond
end

function EnvironmentManager.SetClockTime(hours)
	clockTime = hours % 24
	Lighting.ClockTime = clockTime
end

function EnvironmentManager.GetClockTime()
	return clockTime
end

function EnvironmentManager.IsNight()
	return clockTime < 6 or clockTime >= 18
end

local function startDayNightCycle()
	if heartbeatConnection then
		heartbeatConnection:Disconnect()
	end
	heartbeatConnection = RunService.Heartbeat:Connect(function(deltaTime)
		local speed = EnvironmentManager.Config.TimeSpeed
		if speed == 0 then
			return
		end
		clockTime = (clockTime + deltaTime * speed) % 24
		Lighting.ClockTime = clockTime
	end)
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function EnvironmentManager.Init()
	if initialized then
		return
	end
	initialized = true

	local config = EnvironmentManager.Config
	EnvironmentManager.OptimizeGraphics()
	EnvironmentManager.SetClockTime(config.StartClockTime)
	EnvironmentManager.SetWeather(config.DefaultWeather, 0)

	if config.DayNightEnabled then
		startDayNightCycle()
	end
end

-- Stops the cycle and any running transitions. Init() can be called again afterwards.
function EnvironmentManager.Stop()
	if heartbeatConnection then
		heartbeatConnection:Disconnect()
		heartbeatConnection = nil
	end
	cancelActiveTweens()
	initialized = false
end

return EnvironmentManager
