# EnvironmentManager: Roblox environment system for Oddtide

Instructions for the AI installing this: create the **three** scripts below in Roblox Studio, with the exact types, names and locations given. Paste each code block into its script unchanged.

## Where each script goes

| # | Type | Name | Location |
|---|------|------|----------|
| 1 | **ModuleScript** | `EnvironmentManager` | `ReplicatedStorage` → Folder named `Shared` (create it if missing) |
| 2 | **Script** (server) | `Environment` | `ServerScriptService` |
| 3 | **LocalScript** | `Environment` | `StarterPlayer` → `StarterPlayerScripts` |

Scripts 2 and 3 load the module from `ReplicatedStorage.Shared.EnvironmentManager`. If you put the module somewhere else, update the `require` line in both of them.

## One manual step in Studio
Select **Lighting** in the Explorer and set **Technology** to **Future** in Properties. Roblox doesn't let scripts change this setting.

## Optional settings (inside the module's `Config` table)
- `Config.Sounds.Rain`, `.Wind` and `.Thunder`: paste `rbxassetid://` audio IDs to turn on sounds. They're off by default.
- `Config.Particles.RainTexture`: an uploaded raindrop-streak image looks better than the built-in placeholder.
- Set a weather preset's `Weight = 0` to stop it appearing in the automatic rotation (for example Snowy in a tropical game).

## Weather modes
Clear, Overcast, Foggy, Rainy, Stormy (rain and lightning), Snowy, Aurora (night only), BloodMoon (night only).

Server-side control, for example from an admin command:
```lua
local Env = require(game.ReplicatedStorage.Shared.EnvironmentManager)
Env.SetWeather("Stormy")              -- blends over 12 seconds
Env.SetWeather("Clear", 3)            -- blends over 3 seconds
Env.SetAutoWeather(false)             -- stop the random rotation
Env.SetTimeSpeed(0.05)                -- in-game hours per real second
Env.SetClockTime(18)                  -- jump to sunset
local luck = Env.GetWeatherInfo().LuckMultiplier  -- use in fishing code
```

---

## 1. ModuleScript `EnvironmentManager` (ReplicatedStorage → Shared)

```lua
--[[
	EnvironmentManager
	Unified environment system for the fishing game.

	  * Day/Night cycle with time-of-day color grading (golden sunrise, warm sunset,
	    purple dusk, cool blue nights)
	  * 8 weather modes: Clear, Overcast, Foggy, Rainy, Stormy, Snowy, Aurora, BloodMoon
	  * Automatic weighted weather rotation (Aurora and BloodMoon only roll at night)
	  * Rain and snow particles, lightning bolts with flashes and thunder, aurora ribbons,
	    wind, waves, clouds and optional ambient sounds
	  * Ultra Graphics Optimizer (shadows, reflections, grading, Bloom, SunRays, depth of field, water)
	  * Per-weather fishing data (LuckMultiplier) for your fishing scripts

	HOW IT WORKS
	The server owns the time and weather and replicates them as two attributes, so every
	player sees the same thing. Each client renders the visuals locally every frame.
	That keeps transitions perfectly smooth and costs almost no network traffic.

	SETUP (both are needed)
		-- Server Script (ServerScriptService):
		local EnvironmentManager = require(game.ReplicatedStorage.Shared.EnvironmentManager)
		EnvironmentManager.Init()

		-- LocalScript (StarterPlayerScripts):
		local EnvironmentManager = require(game.ReplicatedStorage.Shared.EnvironmentManager)
		EnvironmentManager.Init()

	SERVER API
		EnvironmentManager.SetWeather("Stormy")        -- blend over Config.TransitionTime
		EnvironmentManager.SetWeather("Clear", 3)      -- custom blend length (0 = instant)
		EnvironmentManager.SetAutoWeather(false)       -- stop random weather rotation
		EnvironmentManager.SetTimeSpeed(0.05)          -- in-game hours per real second (0 pauses)
		EnvironmentManager.SetClockTime(18)            -- jump to sunset

	SHARED API (server and client)
		EnvironmentManager.GetWeather()                -- "Rainy"
		EnvironmentManager.GetWeatherInfo()            -- { Name, DisplayName, Description, LuckMultiplier, NightOnly }
		EnvironmentManager.GetWeatherNames()
		EnvironmentManager.GetClockTime() / IsNight() / GetNightFactor()
		EnvironmentManager.WeatherChanged:Connect(function(newWeather, oldWeather) end)
		EnvironmentManager.LightningStruck:Connect(function(info) end)  -- client info has .Position

	Tweak EnvironmentManager.Config, .WeatherPresets or .TimeOfDay before calling Init().
]]

local Debris = game:GetService("Debris")
local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Terrain = Workspace:FindFirstChildOfClass("Terrain")

local STATE_FOLDER_NAME = "EnvironmentState"
local RENDER_STEP_NAME = "EnvironmentManager"

-- Every blendable section a weather preset can contain.
local SECTIONS = {
	"Lighting",
	"Atmosphere",
	"ColorCorrection",
	"Bloom",
	"SunRays",
	"Clouds",
	"Water",
	"Workspace",
	"Sky",
	"Effects",
}

local rgb = Color3.fromRGB

local EnvironmentManager = {}

--------------------------------------------------------------------------------
-- Configuration
--------------------------------------------------------------------------------

EnvironmentManager.Config = {
	-- Day/Night
	TimeSpeed = 0.02, -- in-game hours per real second (0.02 = a full day every 20 minutes)
	StartClockTime = 7.5,
	DayNightEnabled = true,

	-- Weather
	DefaultWeather = "Clear",
	BasePreset = "Clear", -- presets inherit any value they don't set from this one
	TransitionTime = 12,
	TransitionEasingStyle = Enum.EasingStyle.Sine,
	TransitionEasingDirection = Enum.EasingDirection.InOut,

	AutoWeather = true,
	AutoWeatherMinDuration = 180, -- seconds each weather lasts before rolling a new one
	AutoWeatherMaxDuration = 420,

	-- Baseline "ultra" grade used by the optimizer and the Clear preset.
	-- ColorCorrection Contrast/Saturation accept -1..1. Past ~0.4 shadows crush and
	-- the water turns neon, so these are the highest values that still look good.
	Ultra = {
		ExposureCompensation = 0.25,
		Contrast = 0.3,
		Saturation = 0.35,
		Brightness = 0.03,
		DepthOfField = true, -- soft blur far out at sea; never touches UI
	},

	Particles = {
		-- Built-in textures so it works out of the box. For the best rain, upload a thin
		-- vertical streak image and paste its "rbxassetid://..." here.
		RainTexture = "rbxasset://textures/particles/smoke_main.dds",
		SnowTexture = "rbxasset://textures/particles/smoke_main.dds",
		MaxRainRate = 1400, -- particles/sec at Rain = 1 on max graphics quality
		MaxSnowRate = 450,
		EmitterHeight = 45, -- studs above the camera
		EmitterSize = 160, -- width of the area around the camera that gets rain/snow
	},

	Lightning = {
		MinInterval = 5, -- seconds between strikes at Lightning = 1
		MaxInterval = 15,
		MinDistance = 250, -- studs from each player's camera
		MaxDistance = 800,
		BoltColor = rgb(205, 222, 255),
		BoltThickness = 2.5,
		BoltHeight = 450,
		BoltSegments = 14,
		FlashExposure = 1.4,
		FlashBrightness = 0.25,
	},

	Aurora = {
		Height = 420,
		Distance = 1100, -- how far "north" (-Z) of the camera the ribbons hang
		Width = 1800,
		Ribbons = 3,
		Colors = ColorSequence.new({
			ColorSequenceKeypoint.new(0, rgb(70, 255, 150)),
			ColorSequenceKeypoint.new(0.5, rgb(40, 210, 230)),
			ColorSequenceKeypoint.new(1, rgb(175, 95, 255)),
		}),
	},

	-- Optional looping sounds. Leave "" to disable. Use your own "rbxassetid://..." audio.
	Sounds = {
		Rain = "",
		Wind = "",
		Thunder = {}, -- list of ids; a random one plays per strike
		RainVolume = 0.6,
		WindVolume = 0.5,
		ThunderVolume = 1,
	},
}

local Config = EnvironmentManager.Config
local Ultra = Config.Ultra

--------------------------------------------------------------------------------
-- Weather presets
-- Values in the blendable sections are interpolated during transitions.
-- A preset only needs the values that differ from Config.BasePreset.
--
-- Effects (custom, 0..1):
--   Rain, Snow        particle intensity
--   Lightning         strike frequency
--   Aurora            ribbon strength (only visible at night)
--   TimeOfDayInfluence how strongly sunrise/sunset/night tints apply
--
-- Metadata (not blended): DisplayName, Description, Weight (auto-weather odds),
-- NightOnly, LuckMultiplier (for your fishing code).
--------------------------------------------------------------------------------

EnvironmentManager.WeatherPresets = {
	Clear = {
		DisplayName = "Clear Skies",
		Description = "Calm seas and bright sun.",
		Weight = 3,
		LuckMultiplier = 1,
		Lighting = {
			Brightness = 3,
			ExposureCompensation = Ultra.ExposureCompensation,
			OutdoorAmbient = rgb(128, 132, 140),
		},
		Atmosphere = {
			Density = 0.3,
			Offset = 0.25,
			Color = rgb(199, 206, 214),
			Decay = rgb(106, 120, 138),
			Glare = 0.35,
			Haze = 1,
		},
		ColorCorrection = {
			Brightness = Ultra.Brightness,
			Contrast = Ultra.Contrast,
			Saturation = Ultra.Saturation,
			TintColor = rgb(255, 252, 245),
		},
		Bloom = { Intensity = 0.7, Size = 24, Threshold = 0.9 },
		SunRays = { Intensity = 0.12, Spread = 0.8 },
		Clouds = { Cover = 0.45, Density = 0.35, Color = rgb(255, 255, 255) },
		Water = {
			WaterWaveSize = 0.15,
			WaterWaveSpeed = 10,
			WaterColor = rgb(28, 96, 112),
			WaterTransparency = 0.35,
		},
		Workspace = { GlobalWind = Vector3.new(6, 0, 3) },
		Sky = { StarCount = 3000 },
		Effects = { Rain = 0, Snow = 0, Lightning = 0, Aurora = 0, TimeOfDayInfluence = 1 },
	},

	Overcast = {
		DisplayName = "Overcast",
		Description = "Grey skies make the fish less wary.",
		Weight = 2,
		LuckMultiplier = 1.1,
		Lighting = { Brightness = 1.8, ExposureCompensation = 0.1, OutdoorAmbient = rgb(120, 124, 132) },
		Atmosphere = {
			Density = 0.42,
			Offset = 0.15,
			Color = rgb(170, 176, 184),
			Decay = rgb(120, 126, 136),
			Glare = 0,
			Haze = 1.4,
		},
		ColorCorrection = { Brightness = 0, Contrast = 0.12, Saturation = -0.1, TintColor = rgb(238, 242, 248) },
		Bloom = { Intensity = 0.5, Size = 24, Threshold = 1 },
		SunRays = { Intensity = 0.02 },
		Clouds = { Cover = 0.85, Density = 0.6, Color = rgb(200, 204, 210) },
		Water = { WaterWaveSize = 0.2, WaterWaveSpeed = 12, WaterColor = rgb(36, 84, 96) },
		Workspace = { GlobalWind = Vector3.new(12, 0, 6) },
		Sky = { StarCount = 500 },
		Effects = { TimeOfDayInfluence = 0.7 },
	},

	Foggy = {
		DisplayName = "Thick Fog",
		Description = "Visibility is low, but strange fish drift closer.",
		Weight = 1.2,
		LuckMultiplier = 1.15,
		Lighting = { Brightness = 2, ExposureCompensation = 0.1, OutdoorAmbient = rgb(150, 155, 162) },
		Atmosphere = {
			Density = 0.72,
			Offset = 0,
			Color = rgb(196, 202, 208),
			Decay = rgb(160, 166, 176),
			Glare = 0,
			Haze = 0.6,
		},
		ColorCorrection = { Brightness = 0.02, Contrast = -0.05, Saturation = -0.2, TintColor = rgb(236, 241, 246) },
		Bloom = { Intensity = 0.45, Size = 30, Threshold = 0.95 },
		SunRays = { Intensity = 0.03, Spread = 1 },
		Clouds = { Cover = 0.75, Density = 0.55, Color = rgb(225, 228, 232) },
		Water = { WaterWaveSize = 0.08, WaterWaveSpeed = 6 },
		Workspace = { GlobalWind = Vector3.new(2, 0, 1) },
		Sky = { StarCount = 0 },
		Effects = { TimeOfDayInfluence = 0.6 },
	},

	Rainy = {
		DisplayName = "Rain",
		Description = "Steady rain stirs the water and wakes the fish.",
		Weight = 1.5,
		LuckMultiplier = 1.25,
		Lighting = { Brightness = 1.5, ExposureCompensation = 0, OutdoorAmbient = rgb(105, 112, 124) },
		Atmosphere = {
			Density = 0.5,
			Offset = 0.1,
			Color = rgb(150, 160, 172),
			Decay = rgb(92, 100, 114),
			Glare = 0,
			Haze = 1.8,
		},
		ColorCorrection = { Brightness = -0.03, Contrast = 0.18, Saturation = -0.15, TintColor = rgb(220, 230, 242) },
		Bloom = { Intensity = 0.45, Size = 20, Threshold = 1 },
		SunRays = { Intensity = 0 },
		Clouds = { Cover = 0.9, Density = 0.75, Color = rgb(130, 136, 146) },
		Water = {
			WaterWaveSize = 0.28,
			WaterWaveSpeed = 16,
			WaterColor = rgb(30, 74, 88),
			WaterTransparency = 0.45,
		},
		Workspace = { GlobalWind = Vector3.new(18, 0, 8) },
		Sky = { StarCount = 0 },
		Effects = { Rain = 0.55, TimeOfDayInfluence = 0.6 },
	},

	Stormy = {
		DisplayName = "Thunderstorm",
		Description = "Dangerous seas. Legendary catches.",
		Weight = 0.8,
		LuckMultiplier = 1.5,
		Lighting = { Brightness = 1.2, ExposureCompensation = -0.3, OutdoorAmbient = rgb(88, 94, 108) },
		Atmosphere = {
			Density = 0.62,
			Offset = 0.1,
			Color = rgb(108, 116, 128),
			Decay = rgb(58, 64, 78),
			Glare = 0,
			Haze = 2.6,
		},
		-- Moody grade: darker, desaturated, cold blue tint, contrast kept high for drama.
		ColorCorrection = { Brightness = -0.08, Contrast = 0.22, Saturation = -0.35, TintColor = rgb(198, 212, 232) },
		Bloom = { Intensity = 0.3, Size = 18, Threshold = 1.2 },
		SunRays = { Intensity = 0, Spread = 0.5 },
		Clouds = { Cover = 0.95, Density = 0.9, Color = rgb(78, 84, 96) },
		Water = {
			WaterWaveSize = 0.4,
			WaterWaveSpeed = 22,
			WaterColor = rgb(24, 58, 70),
			WaterTransparency = 0.55,
		},
		Workspace = { GlobalWind = Vector3.new(40, 0, 18) },
		Sky = { StarCount = 0 },
		Effects = { Rain = 1, Lightning = 1, TimeOfDayInfluence = 0.5 },
	},

	Snowy = {
		DisplayName = "Snowfall",
		Description = "Cold-water species come out to feed.",
		Weight = 0.7,
		LuckMultiplier = 1.1,
		Lighting = { Brightness = 2.2, ExposureCompensation = 0.15, OutdoorAmbient = rgb(150, 158, 172) },
		Atmosphere = {
			Density = 0.45,
			Offset = 0.2,
			Color = rgb(215, 225, 235),
			Decay = rgb(170, 185, 205),
			Glare = 0.1,
			Haze = 1.2,
		},
		ColorCorrection = { Brightness = 0.04, Contrast = 0.12, Saturation = -0.25, TintColor = rgb(225, 238, 255) },
		Bloom = { Intensity = 0.8, Size = 28, Threshold = 0.85 },
		SunRays = { Intensity = 0.05 },
		Clouds = { Cover = 0.8, Density = 0.55, Color = rgb(230, 235, 242) },
		Water = {
			WaterWaveSize = 0.06,
			WaterWaveSpeed = 5,
			WaterColor = rgb(40, 80, 100),
			WaterTransparency = 0.25,
		},
		Workspace = { GlobalWind = Vector3.new(5, 0, 2) },
		Sky = { StarCount = 800 },
		Effects = { Snow = 1, TimeOfDayInfluence = 0.8 },
	},

	Aurora = {
		DisplayName = "Aurora Night",
		Description = "The sky glows and rare fish rise to the surface.",
		Weight = 0.6,
		NightOnly = true,
		LuckMultiplier = 2,
		Lighting = { Brightness = 2.5, ExposureCompensation = 0.3, OutdoorAmbient = rgb(110, 140, 150) },
		Atmosphere = {
			Density = 0.22,
			Offset = 0.3,
			Color = rgb(150, 190, 200),
			Decay = rgb(60, 110, 120),
			Glare = 0.2,
			Haze = 0.6,
		},
		ColorCorrection = { Brightness = 0.03, Contrast = 0.28, Saturation = 0.45, TintColor = rgb(215, 255, 235) },
		Bloom = { Intensity = 1, Size = 30, Threshold = 0.8 },
		SunRays = { Intensity = 0.05 },
		Clouds = { Cover = 0.2, Density = 0.2, Color = rgb(200, 230, 225) },
		Water = {
			WaterWaveSize = 0.1,
			WaterWaveSpeed = 7,
			WaterColor = rgb(20, 90, 100),
			WaterTransparency = 0.3,
		},
		Workspace = { GlobalWind = Vector3.new(3, 0, 1) },
		Sky = { StarCount = 5000 },
		Effects = { Aurora = 1, TimeOfDayInfluence = 0.5 },
	},

	BloodMoon = {
		DisplayName = "Blood Moon",
		Description = "The tide turns red. Something ancient is biting.",
		Weight = 0.25,
		NightOnly = true,
		LuckMultiplier = 2.5,
		Lighting = { Brightness = 1.8, ExposureCompensation = 0.2, OutdoorAmbient = rgb(140, 70, 70) },
		Atmosphere = {
			Density = 0.4,
			Offset = 0.2,
			Color = rgb(170, 60, 55),
			Decay = rgb(90, 20, 25),
			Glare = 0.5,
			Haze = 1.8,
		},
		ColorCorrection = { Brightness = -0.02, Contrast = 0.35, Saturation = 0.1, TintColor = rgb(255, 175, 165) },
		Bloom = { Intensity = 0.9, Size = 26, Threshold = 0.85 },
		SunRays = { Intensity = 0 },
		Clouds = { Cover = 0.35, Density = 0.3, Color = rgb(120, 40, 40) },
		Water = {
			WaterWaveSize = 0.2,
			WaterWaveSpeed = 12,
			WaterColor = rgb(80, 20, 24),
			WaterTransparency = 0.4,
		},
		Workspace = { GlobalWind = Vector3.new(8, 0, 4) },
		Sky = { StarCount = 1500 },
		Effects = { TimeOfDayInfluence = 0.4 },
	},
}

--------------------------------------------------------------------------------
-- Time-of-day keyframes (hour 0-24). Blended smoothly and layered over the weather:
--   Tint / AtmosphereTint / AmbientTint multiply the weather's colors
--   Ambient sets Lighting.Ambient, Exposure is added, SunRays multiplies
--   Night (0..1) drives IsNight() and aurora visibility
--------------------------------------------------------------------------------

local NIGHT = {
	Tint = rgb(175, 190, 235),
	AtmosphereTint = rgb(70, 86, 130),
	AmbientTint = rgb(115, 130, 180),
	Ambient = rgb(34, 40, 62),
	Exposure = 0.15,
	SunRays = 0,
	Night = 1,
}

local function keyframe(time, values)
	local frame = table.clone(values)
	frame.Time = time
	return frame
end

EnvironmentManager.TimeOfDay = {
	keyframe(0, NIGHT),
	keyframe(4.8, NIGHT),
	keyframe(6, { -- dawn
		Tint = rgb(235, 200, 210),
		AtmosphereTint = rgb(200, 140, 150),
		AmbientTint = rgb(200, 170, 185),
		Ambient = rgb(40, 34, 44),
		Exposure = 0.15,
		SunRays = 0.8,
		Night = 0.3,
	}),
	keyframe(6.8, { -- sunrise
		Tint = rgb(255, 212, 176),
		AtmosphereTint = rgb(255, 176, 120),
		AmbientTint = rgb(240, 200, 175),
		Ambient = rgb(44, 36, 32),
		Exposure = 0.1,
		SunRays = 1.7,
		Night = 0,
	}),
	keyframe(8.5, { -- morning
		Tint = rgb(255, 246, 232),
		AtmosphereTint = rgb(240, 232, 222),
		AmbientTint = rgb(248, 244, 238),
		Ambient = rgb(32, 32, 34),
		Exposure = 0.03,
		SunRays = 1.15,
		Night = 0,
	}),
	keyframe(12, { -- noon
		Tint = rgb(255, 255, 255),
		AtmosphereTint = rgb(255, 255, 255),
		AmbientTint = rgb(255, 255, 255),
		Ambient = rgb(28, 28, 30),
		Exposure = 0,
		SunRays = 0.9,
		Night = 0,
	}),
	keyframe(16.5, { -- afternoon
		Tint = rgb(255, 244, 226),
		AtmosphereTint = rgb(250, 236, 214),
		AmbientTint = rgb(250, 242, 232),
		Ambient = rgb(32, 30, 30),
		Exposure = 0.03,
		SunRays = 1.1,
		Night = 0,
	}),
	keyframe(17.9, { -- sunset
		Tint = rgb(255, 196, 156),
		AtmosphereTint = rgb(255, 146, 98),
		AmbientTint = rgb(245, 182, 158),
		Ambient = rgb(48, 34, 32),
		Exposure = 0.15,
		SunRays = 1.9,
		Night = 0,
	}),
	keyframe(19, { -- dusk
		Tint = rgb(210, 180, 235),
		AtmosphereTint = rgb(145, 110, 175),
		AmbientTint = rgb(175, 152, 205),
		Ambient = rgb(34, 28, 48),
		Exposure = 0.12,
		SunRays = 0.3,
		Night = 0.6,
	}),
	keyframe(20.2, NIGHT),
}

local TIME_OF_DAY_KEYS = { "Tint", "AtmosphereTint", "AmbientTint", "Ambient", "Exposure", "SunRays", "Night" }

--------------------------------------------------------------------------------
-- Shared state
--------------------------------------------------------------------------------

local state = {
	Weather = Config.DefaultWeather,
	PreviousWeather = nil,
	TransitionStart = 0,
	TransitionDuration = 0,
	ClockAnchor = Config.StartClockTime,
	ClockAnchorTime = 0,
	TimeSpeed = 0,
}

local initialized = false
local stateFolder = nil
local lightningRemote = nil
local connections = {}
local rng = Random.new()

local weatherChangedEvent = Instance.new("BindableEvent")
local lightningStruckEvent = Instance.new("BindableEvent")

-- Fires with (newWeatherName, oldWeatherName) on both server and client.
EnvironmentManager.WeatherChanged = weatherChangedEvent.Event
-- Server: fires with { Angle, Distance }. Client: fires with { Position, Distance }.
EnvironmentManager.LightningStruck = lightningStruckEvent.Event

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local function now()
	return Workspace:GetServerTimeNow()
end

local function lerp(a, b, t)
	local valueType = typeof(a)
	if valueType == "number" then
		return a + (b - a) * t
	elseif valueType == "Color3" or valueType == "Vector3" then
		return a:Lerp(b, t)
	end
	return if t < 0.5 then a else b
end

local WHITE = Color3.new(1, 1, 1)

local function multiplyColor(a, b)
	return Color3.new(a.R * b.R, a.G * b.G, a.B * b.B)
end

local resolvedPresets = {}

-- Merges a preset over the base preset so every section has every value.
local function resolvePreset(name)
	if name == nil then
		return nil
	end
	local cached = resolvedPresets[name]
	if cached then
		return cached
	end
	local presets = EnvironmentManager.WeatherPresets
	local preset = presets[name]
	if not preset then
		return nil
	end
	local base = presets[Config.BasePreset] or preset
	local resolved = {}
	for _, section in ipairs(SECTIONS) do
		local merged = {}
		for property, value in pairs(base[section] or {}) do
			merged[property] = value
		end
		for property, value in pairs(preset[section] or {}) do
			merged[property] = value
		end
		resolved[section] = merged
	end
	resolvedPresets[name] = resolved
	return resolved
end

-- Call after editing WeatherPresets at runtime.
function EnvironmentManager.RefreshPresets()
	table.clear(resolvedPresets)
end

local function copyWeather(source)
	local copy = {}
	for _, section in ipairs(SECTIONS) do
		copy[section] = table.clone(source[section])
	end
	return copy
end

local function blendWeather(from, to, t, out)
	for _, section in ipairs(SECTIONS) do
		local fromSection = from[section]
		local outSection = out[section]
		if not outSection then
			outSection = {}
			out[section] = outSection
		end
		for property, target in pairs(to[section]) do
			local start = fromSection[property]
			if start == nil then
				start = target
			end
			outSection[property] = lerp(start, target, t)
		end
	end
	return out
end

local timeOfDaySample = {}

local function sampleTimeOfDay(hour)
	local frames = EnvironmentManager.TimeOfDay
	local previous, nextFrame = frames[#frames], frames[1]
	for index, frame in ipairs(frames) do
		if frame.Time > hour then
			nextFrame = frame
			previous = frames[index - 1] or frames[#frames]
			break
		end
	end
	local span = (nextFrame.Time - previous.Time) % 24
	if span == 0 then
		span = 24
	end
	local t = ((hour - previous.Time) % 24) / span
	t = t * t * (3 - 2 * t) -- smoothstep
	for _, key in ipairs(TIME_OF_DAY_KEYS) do
		timeOfDaySample[key] = lerp(previous[key], nextFrame[key], t)
	end
	return timeOfDaySample
end

local function getTransitionAlpha()
	if state.TransitionDuration <= 0 then
		return 1
	end
	return math.clamp((now() - state.TransitionStart) / state.TransitionDuration, 0, 1)
end

-- State is replicated as two string attributes so each update arrives atomically.
local function encodeWeatherState()
	return string.format(
		"%s|%s|%.3f|%.3f",
		state.Weather,
		state.PreviousWeather or "",
		state.TransitionStart,
		state.TransitionDuration
	)
end

local function decodeWeatherState(value)
	local parts = string.split(value or "", "|")
	state.Weather = if parts[1] and parts[1] ~= "" then parts[1] else Config.DefaultWeather
	state.PreviousWeather = if parts[2] and parts[2] ~= "" then parts[2] else nil
	state.TransitionStart = tonumber(parts[3]) or 0
	state.TransitionDuration = tonumber(parts[4]) or 0
end

local function encodeClockState()
	return string.format("%.5f|%.3f|%.6f", state.ClockAnchor, state.ClockAnchorTime, state.TimeSpeed)
end

local function decodeClockState(value)
	local parts = string.split(value or "", "|")
	state.ClockAnchor = tonumber(parts[1]) or Config.StartClockTime
	state.ClockAnchorTime = tonumber(parts[2]) or now()
	state.TimeSpeed = tonumber(parts[3]) or 0
end

--------------------------------------------------------------------------------
-- Shared API
--------------------------------------------------------------------------------

function EnvironmentManager.GetClockTime()
	return (state.ClockAnchor + (now() - state.ClockAnchorTime) * state.TimeSpeed) % 24
end

-- 0 during the day, 1 at night, smooth in between.
function EnvironmentManager.GetNightFactor()
	return sampleTimeOfDay(EnvironmentManager.GetClockTime()).Night
end

function EnvironmentManager.IsNight()
	return EnvironmentManager.GetNightFactor() > 0.5
end

function EnvironmentManager.GetWeather()
	return state.Weather
end

function EnvironmentManager.GetWeatherNames()
	local names = {}
	for name in pairs(EnvironmentManager.WeatherPresets) do
		table.insert(names, name)
	end
	table.sort(names)
	return names
end

function EnvironmentManager.GetWeatherInfo(name)
	name = name or state.Weather
	local preset = EnvironmentManager.WeatherPresets[name]
	if not preset then
		return nil
	end
	return {
		Name = name,
		DisplayName = preset.DisplayName or name,
		Description = preset.Description or "",
		LuckMultiplier = preset.LuckMultiplier or 1,
		NightOnly = preset.NightOnly == true,
	}
end

--------------------------------------------------------------------------------
-- Server
--------------------------------------------------------------------------------

local server = {
	loopToken = 0,
	nextWeatherChangeAt = 0,
	nextLightningAt = 0,
}

local function writeWeatherState()
	stateFolder:SetAttribute("WeatherState", encodeWeatherState())
end

local function writeClockState()
	stateFolder:SetAttribute("ClockState", encodeClockState())
end

local function randomWeatherDuration()
	return rng:NextNumber(Config.AutoWeatherMinDuration, Config.AutoWeatherMaxDuration)
end

local function pickNextWeather()
	local night = EnvironmentManager.IsNight()
	local candidates = {}
	local totalWeight = 0
	for name, preset in pairs(EnvironmentManager.WeatherPresets) do
		local weight = preset.Weight or 1
		if name ~= state.Weather and weight > 0 and (night or not preset.NightOnly) then
			totalWeight += weight
			table.insert(candidates, { name, weight })
		end
	end
	if totalWeight <= 0 then
		return nil
	end
	local roll = rng:NextNumber(0, totalWeight)
	for _, candidate in ipairs(candidates) do
		roll -= candidate[2]
		if roll <= 0 then
			return candidate[1]
		end
	end
	return candidates[#candidates][1]
end

local function scheduleLightning(strength)
	local lightning = Config.Lightning
	server.nextLightningAt = now() + rng:NextNumber(lightning.MinInterval, lightning.MaxInterval) / strength
end

local function strikeLightning()
	local lightning = Config.Lightning
	local angle = rng:NextNumber(0, math.pi * 2)
	local distance = rng:NextNumber(lightning.MinDistance, lightning.MaxDistance)
	lightningRemote:FireAllClients(angle, distance)
	lightningStruckEvent:Fire({ Angle = angle, Distance = distance })
end

local function serverLoop(token)
	while server.loopToken == token do
		local currentTime = now()

		if Config.AutoWeather then
			local preset = EnvironmentManager.WeatherPresets[state.Weather]
			local wrongTimeOfDay = preset and preset.NightOnly and not EnvironmentManager.IsNight()
			if currentTime >= server.nextWeatherChangeAt or wrongTimeOfDay then
				local nextWeather = pickNextWeather()
				if nextWeather then
					EnvironmentManager.SetWeather(nextWeather)
				else
					server.nextWeatherChangeAt = currentTime + randomWeatherDuration()
				end
			end
		end

		local target = resolvePreset(state.Weather)
		local strength = if target then target.Effects.Lightning else 0
		if strength > 0 and getTransitionAlpha() > 0.4 then
			if server.nextLightningAt == 0 then
				scheduleLightning(strength)
			elseif currentTime >= server.nextLightningAt then
				strikeLightning()
				scheduleLightning(strength)
			end
		else
			server.nextLightningAt = 0
		end

		task.wait(0.2)
	end
end

local function tryForceFutureLighting()
	if Lighting.Technology == Enum.Technology.Future then
		return
	end
	-- Roblox only lets Studio/plugins change Technology; game scripts are blocked.
	local ok = pcall(function()
		Lighting.Technology = Enum.Technology.Future
	end)
	if not ok then
		warn(
			"[EnvironmentManager] Scripts can't set Lighting.Technology. "
				.. "Set it to Future in Studio: Explorer > Lighting > Properties > Technology."
		)
	end
end

local function initServer()
	stateFolder = ReplicatedStorage:FindFirstChild(STATE_FOLDER_NAME)
	local isNewFolder = stateFolder == nil
	if isNewFolder then
		stateFolder = Instance.new("Folder")
		stateFolder.Name = STATE_FOLDER_NAME
	end
	lightningRemote = stateFolder:FindFirstChild("LightningStrike")
	if not lightningRemote then
		lightningRemote = Instance.new("RemoteEvent")
		lightningRemote.Name = "LightningStrike"
		lightningRemote.Parent = stateFolder
	end

	state.ClockAnchor = Config.StartClockTime
	state.ClockAnchorTime = now()
	state.TimeSpeed = if Config.DayNightEnabled then Config.TimeSpeed else 0
	writeClockState()

	state.Weather = Config.DefaultWeather
	state.PreviousWeather = nil
	state.TransitionStart = now()
	state.TransitionDuration = 0
	writeWeatherState()

	-- Parent last so clients never see the folder without its attributes.
	if isNewFolder then
		stateFolder.Parent = ReplicatedStorage
	end

	tryForceFutureLighting()

	server.nextWeatherChangeAt = now() + randomWeatherDuration()
	server.loopToken += 1
	task.spawn(serverLoop, server.loopToken)
end

-- Server only. transitionTime defaults to Config.TransitionTime; 0 switches instantly.
function EnvironmentManager.SetWeather(weatherName, transitionTime)
	if not RunService:IsServer() then
		warn("[EnvironmentManager] SetWeather must be called from the server.")
		return false
	end
	if not EnvironmentManager.WeatherPresets[weatherName] then
		warn(("[EnvironmentManager] Unknown weather preset %q"):format(tostring(weatherName)))
		return false
	end
	if not stateFolder then
		Config.DefaultWeather = weatherName -- not initialized yet; start in this weather
		return true
	end

	server.nextWeatherChangeAt = now() + randomWeatherDuration()
	if weatherName == state.Weather then
		return true
	end

	local previousWeather = state.Weather
	state.PreviousWeather = previousWeather
	state.Weather = weatherName
	state.TransitionStart = now()
	state.TransitionDuration = transitionTime or Config.TransitionTime
	writeWeatherState()

	weatherChangedEvent:Fire(weatherName, previousWeather)
	return true
end

function EnvironmentManager.SetAutoWeather(enabled)
	Config.AutoWeather = enabled
	server.nextWeatherChangeAt = now() + randomWeatherDuration()
end

-- Server only. In-game hours per real second; 0 pauses the clock.
function EnvironmentManager.SetTimeSpeed(hoursPerSecond)
	Config.TimeSpeed = hoursPerSecond
	if not stateFolder or not RunService:IsServer() then
		return
	end
	state.ClockAnchor = EnvironmentManager.GetClockTime()
	state.ClockAnchorTime = now()
	state.TimeSpeed = hoursPerSecond
	writeClockState()
end

-- Server only.
function EnvironmentManager.SetClockTime(hours)
	if not stateFolder or not RunService:IsServer() then
		Config.StartClockTime = hours % 24
		return
	end
	state.ClockAnchor = hours % 24
	state.ClockAnchorTime = now()
	writeClockState()
end

--------------------------------------------------------------------------------
-- Client rendering
--------------------------------------------------------------------------------

local client = {
	effects = {},
	fromWeather = nil,
	rendered = {},
	hasRendered = false,
	flash = 0,
	qualityScale = 1,
	qualityCheckAt = 0,
	lastCameraPosition = nil,
	emitterPart = nil,
	rainEmitter = nil,
	snowEmitter = nil,
	aurora = nil,
	sounds = {},
	elapsed = 0,
}

local appliedValues = setmetatable({}, { __mode = "k" })
local failedProperties = {}

local function assign(instance, property, value)
	instance[property] = value
end

-- Only writes when the value changed, and never lets a bad preset key break the loop.
local function setProperty(instance, property, value)
	local cache = appliedValues[instance]
	if cache == nil then
		cache = {}
		appliedValues[instance] = cache
	end
	if cache[property] == value then
		return
	end
	cache[property] = value
	local ok, err = pcall(assign, instance, property, value)
	if not ok then
		local key = instance.ClassName .. "." .. property
		if not failedProperties[key] then
			failedProperties[key] = true
			warn(("[EnvironmentManager] Couldn't set %s: %s"):format(key, tostring(err)))
		end
	end
end

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
	local effects = client.effects
	effects.Atmosphere = getOrCreate(Lighting, "Atmosphere", "Atmosphere")
	effects.ColorCorrection = getOrCreate(Lighting, "ColorCorrectionEffect", "ColorCorrection")
	effects.Bloom = getOrCreate(Lighting, "BloomEffect", "Bloom")
	effects.SunRays = getOrCreate(Lighting, "SunRaysEffect", "SunRays")
	if Ultra.DepthOfField then
		effects.DepthOfField = getOrCreate(Lighting, "DepthOfFieldEffect", "DepthOfField")
	end
	if Terrain then
		effects.Clouds = getOrCreate(Terrain, "Clouds", "Clouds")
	end
end

local function getSectionTarget(section)
	if section == "Lighting" then
		return Lighting
	elseif section == "Water" then
		return Terrain
	elseif section == "Workspace" then
		return Workspace
	elseif section == "Sky" then
		return Lighting:FindFirstChildOfClass("Sky")
	end
	return client.effects[section]
end

-- Ultra Graphics Optimizer. Runs automatically on the client in Init().
function EnvironmentManager.OptimizeGraphics()
	ensureEffects()
	local effects = client.effects

	Lighting.GlobalShadows = true
	Lighting.ShadowSoftness = 0.15
	Lighting.EnvironmentDiffuseScale = 1
	Lighting.EnvironmentSpecularScale = 1 -- strongest sky reflections on water and metal
	Lighting.ExposureCompensation = Ultra.ExposureCompensation

	effects.ColorCorrection.Enabled = true
	effects.ColorCorrection.Brightness = Ultra.Brightness
	effects.ColorCorrection.Contrast = Ultra.Contrast
	effects.ColorCorrection.Saturation = Ultra.Saturation

	-- A high threshold means only bright highlights glow, so sun glints on the
	-- waves sparkle without washing out the scene.
	effects.Bloom.Enabled = true
	effects.SunRays.Enabled = true

	if effects.DepthOfField then
		local depthOfField = effects.DepthOfField
		depthOfField.Enabled = true
		depthOfField.NearIntensity = 0
		depthOfField.FarIntensity = 0.12
		depthOfField.FocusDistance = 80
		depthOfField.InFocusRadius = 120
	end

	if Terrain then
		Terrain.WaterReflectance = 1
		Terrain.Decoration = true
	end
end

local function updateQualityScale()
	local ok, level = pcall(function()
		return UserSettings():GetService("UserGameSettings").SavedQualityLevel
	end)
	if ok and level and level ~= Enum.SavedQualitySetting.Automatic then
		client.qualityScale = math.clamp(level.Value / 10, 0.25, 1)
	else
		client.qualityScale = 0.7
	end
end

local function createInvisiblePart(name, size)
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.Transparency = 1
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	return part
end

local function createWeatherEmitters()
	local particles = Config.Particles
	local part = createInvisiblePart(
		"WeatherEmitter",
		Vector3.new(particles.EmitterSize, 1, particles.EmitterSize)
	)

	local rain = Instance.new("ParticleEmitter")
	rain.Name = "Rain"
	rain.Texture = particles.RainTexture
	rain.EmissionDirection = Enum.NormalId.Bottom
	rain.Rate = 0
	rain.Lifetime = NumberRange.new(0.8, 1.1)
	rain.Speed = NumberRange.new(95, 120)
	rain.SpreadAngle = Vector2.new(4, 4)
	rain.Orientation = Enum.ParticleOrientation.VelocityParallel
	rain.Size = NumberSequence.new(0.14)
	rain.Squash = NumberSequence.new(2.5) -- stretch into streaks
	rain.Transparency = NumberSequence.new(0.4)
	rain.Color = ColorSequence.new(rgb(210, 225, 240))
	rain.LightEmission = 0.3
	rain.LightInfluence = 0.5
	rain.Parent = part

	local snow = Instance.new("ParticleEmitter")
	snow.Name = "Snow"
	snow.Texture = particles.SnowTexture
	snow.EmissionDirection = Enum.NormalId.Bottom
	snow.Rate = 0
	snow.Lifetime = NumberRange.new(7, 10)
	snow.Speed = NumberRange.new(5, 8)
	snow.SpreadAngle = Vector2.new(30, 30)
	snow.Rotation = NumberRange.new(0, 360)
	snow.RotSpeed = NumberRange.new(-45, 45)
	snow.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.3, 0.15),
		NumberSequenceKeypoint.new(1, 0.3, 0.15),
	})
	snow.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.1, 0.1),
		NumberSequenceKeypoint.new(0.9, 0.1),
		NumberSequenceKeypoint.new(1, 1),
	})
	snow.Color = ColorSequence.new(rgb(255, 255, 255))
	snow.LightEmission = 0.4
	snow.Parent = part

	client.emitterPart = part
	client.rainEmitter = rain
	client.snowEmitter = snow
end

local function updateParticles(weather, deltaTime)
	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end
	if not client.emitterPart then
		createWeatherEmitters()
	end
	local part = client.emitterPart
	if part.Parent ~= camera then
		part.Parent = camera
	end

	-- Lead the emitter in the direction the camera moves so rain doesn't lag behind boats.
	local position = camera.CFrame.Position
	local velocity = Vector3.zero
	if client.lastCameraPosition then
		velocity = (position - client.lastCameraPosition) / math.max(deltaTime, 1 / 240)
	end
	client.lastCameraPosition = position
	local lead = Vector3.new(velocity.X, 0, velocity.Z) * 0.6
	if lead.Magnitude > 60 then
		lead = lead.Unit * 60
	end
	part.CFrame = CFrame.new(position + lead + Vector3.new(0, Config.Particles.EmitterHeight, 0))

	local effects = weather.Effects
	local wind = weather.Workspace.GlobalWind
	local quality = client.qualityScale
	setProperty(client.rainEmitter, "Rate", math.floor(effects.Rain * Config.Particles.MaxRainRate * quality))
	setProperty(client.snowEmitter, "Rate", math.floor(effects.Snow * Config.Particles.MaxSnowRate * quality))
	setProperty(client.rainEmitter, "Acceleration", Vector3.new(wind.X, 0, wind.Z) * 1.5)
	setProperty(client.snowEmitter, "Acceleration", Vector3.new(wind.X, 0, wind.Z) * 0.25)
end

local function createLoopSound(name, soundId)
	if soundId == nil or soundId == "" then
		return nil
	end
	local sound = Instance.new("Sound")
	sound.Name = name
	sound.SoundId = soundId
	sound.Looped = true
	sound.Volume = 0
	sound.Parent = SoundService
	sound:Play()
	return sound
end

local function updateSounds(weather)
	local sounds = client.sounds
	local soundConfig = Config.Sounds
	if sounds.Rain then
		setProperty(sounds.Rain, "Volume", weather.Effects.Rain * soundConfig.RainVolume)
	end
	if sounds.Wind then
		local windStrength = math.clamp(weather.Workspace.GlobalWind.Magnitude / 45, 0, 1)
		setProperty(sounds.Wind, "Volume", windStrength * soundConfig.WindVolume)
	end
end

local function createAurora()
	local auroraConfig = Config.Aurora
	local anchor = createInvisiblePart("AuroraAnchor", Vector3.one)
	local beams = {}
	local halfWidth = auroraConfig.Width / 2
	for index = 1, auroraConfig.Ribbons do
		local start = Instance.new("Attachment")
		start.Position = Vector3.new(-halfWidth, index * 35, -index * 160)
		start.Parent = anchor
		local finish = Instance.new("Attachment")
		finish.Position = Vector3.new(halfWidth, index * 55, -index * 120)
		finish.Parent = anchor

		local beam = Instance.new("Beam")
		beam.Attachment0 = start
		beam.Attachment1 = finish
		beam.Color = auroraConfig.Colors
		beam.LightEmission = 1
		beam.LightInfluence = 0
		beam.Brightness = 2
		beam.Segments = 40
		beam.Width0 = 220
		beam.Width1 = 220
		beam.Transparency = NumberSequence.new(1)
		beam.Enabled = false
		beam.Parent = anchor
		table.insert(beams, beam)
	end
	client.aurora = { anchor = anchor, beams = beams, visibility = -1 }
end

local function updateAurora(visibility)
	if visibility < 0.01 and not client.aurora then
		return
	end
	if not client.aurora then
		createAurora()
	end
	local aurora = client.aurora
	local camera = Workspace.CurrentCamera
	local enabled = visibility >= 0.01 and camera ~= nil

	if math.abs(aurora.visibility - visibility) > 0.02 or (not enabled and aurora.visibility ~= 0) then
		aurora.visibility = if enabled then visibility else 0
		local middle = 1 - 0.7 * aurora.visibility
		local transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(0.2, middle),
			NumberSequenceKeypoint.new(0.8, middle),
			NumberSequenceKeypoint.new(1, 1),
		})
		for _, beam in ipairs(aurora.beams) do
			beam.Transparency = transparency
			beam.Enabled = enabled
		end
	end
	if not enabled then
		return
	end

	if aurora.anchor.Parent ~= camera then
		aurora.anchor.Parent = camera
	end
	local position = camera.CFrame.Position
	local auroraConfig = Config.Aurora
	aurora.anchor.CFrame = CFrame.new(position.X, position.Y + auroraConfig.Height, position.Z - auroraConfig.Distance)

	-- Slow, drifting waves.
	local t = client.elapsed
	for index, beam in ipairs(aurora.beams) do
		beam.CurveSize0 = math.sin(t * 0.15 + index) * 320
		beam.CurveSize1 = math.cos(t * 0.11 + index * 1.7) * 320
		beam.Width0 = 200 + math.sin(t * 0.3 + index * 2) * 70
		beam.Width1 = 200 + math.cos(t * 0.25 + index) * 70
	end
end

local function createBolt(from, to)
	local lightning = Config.Lightning
	local points = { from }
	local segments = lightning.BoltSegments
	for index = 1, segments - 1 do
		local alpha = index / segments
		local jitter = 18 * (1 - alpha * 0.5)
		local point = from:Lerp(to, alpha)
			+ Vector3.new(rng:NextNumber(-jitter, jitter), 0, rng:NextNumber(-jitter, jitter))
		table.insert(points, point)
	end
	table.insert(points, to)

	local bolt = Instance.new("Model")
	bolt.Name = "LightningBolt"
	local fade = TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.In, 0, false, 0.08)
	for index = 1, #points - 1 do
		local a, b = points[index], points[index + 1]
		local segment = createInvisiblePart("Segment", Vector3.new(lightning.BoltThickness, lightning.BoltThickness, (b - a).Magnitude))
		segment.Transparency = 0
		segment.Material = Enum.Material.Neon
		segment.Color = lightning.BoltColor
		segment.CFrame = CFrame.lookAt((a + b) / 2, b)
		segment.Parent = bolt
		TweenService:Create(segment, fade, { Transparency = 1 }):Play()
	end
	bolt.Parent = Workspace
	Debris:AddItem(bolt, 1)
end

local function playThunder(distance)
	local ids = Config.Sounds.Thunder
	if #ids == 0 then
		return
	end
	-- Delay scaled down from real speed of sound so it still feels connected to the flash.
	task.delay(distance / 600, function()
		local sound = Instance.new("Sound")
		sound.SoundId = ids[rng:NextInteger(1, #ids)]
		sound.Volume = Config.Sounds.ThunderVolume * (1 - distance / (Config.Lightning.MaxDistance * 1.6))
		sound.PlaybackSpeed = rng:NextNumber(0.85, 1.1)
		sound.Parent = SoundService
		sound:Play()
		Debris:AddItem(sound, 12)
	end)
end

local function onLightningStrike(angle, distance)
	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end
	local cameraPosition = camera.CFrame.Position
	local ground = cameraPosition + Vector3.new(math.cos(angle), 0, math.sin(angle)) * distance
	local skyPoint = Vector3.new(ground.X, cameraPosition.Y + Config.Lightning.BoltHeight, ground.Z)

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { camera }
	params.IgnoreWater = false
	local hit = Workspace:Raycast(skyPoint, Vector3.new(0, -Config.Lightning.BoltHeight * 3, 0), params)
	local impact = if hit then hit.Position else Vector3.new(ground.X, 0, ground.Z)

	createBolt(skyPoint, impact)

	-- Double flicker, brighter for closer strikes.
	local strength = 1 - (distance / Config.Lightning.MaxDistance) * 0.5
	client.flash = strength
	task.delay(0.07, function()
		client.flash = strength * 0.25
	end)
	task.delay(0.14, function()
		client.flash = strength * 0.9
	end)

	playThunder(distance)
	lightningStruckEvent:Fire({ Position = impact, Distance = distance })
end

local overrides = {
	Lighting = {},
	Atmosphere = {},
	ColorCorrection = {},
	SunRays = {},
}

-- Applies weather values with the time-of-day layer and lightning flash on top.
local function applyEnvironment(weather, timeOfDay)
	local influence = weather.Effects.TimeOfDayInfluence
	local tint = WHITE:Lerp(timeOfDay.Tint, influence)
	local atmosphereTint = WHITE:Lerp(timeOfDay.AtmosphereTint, influence)
	local ambientTint = WHITE:Lerp(timeOfDay.AmbientTint, influence)
	local flash = client.flash
	local lightning = Config.Lightning

	overrides.Lighting.ExposureCompensation = weather.Lighting.ExposureCompensation
		+ timeOfDay.Exposure * influence
		+ flash * lightning.FlashExposure
	overrides.Lighting.OutdoorAmbient = multiplyColor(weather.Lighting.OutdoorAmbient, ambientTint)
	overrides.Atmosphere.Color = multiplyColor(weather.Atmosphere.Color, atmosphereTint)
	overrides.Atmosphere.Decay = multiplyColor(weather.Atmosphere.Decay, atmosphereTint)
	overrides.ColorCorrection.TintColor = multiplyColor(weather.ColorCorrection.TintColor, tint)
	overrides.ColorCorrection.Brightness = weather.ColorCorrection.Brightness + flash * lightning.FlashBrightness
	overrides.SunRays.Intensity = weather.SunRays.Intensity * (1 + (timeOfDay.SunRays - 1) * influence)

	for _, section in ipairs(SECTIONS) do
		if section ~= "Effects" then
			local target = getSectionTarget(section)
			if target then
				local sectionOverrides = overrides[section]
				for property, value in pairs(weather[section]) do
					local override = sectionOverrides and sectionOverrides[property]
					setProperty(target, property, if override ~= nil then override else value)
				end
			end
		end
	end
	setProperty(Lighting, "Ambient", timeOfDay.Ambient)
end

local function renderStep(deltaTime)
	client.elapsed += deltaTime
	client.flash = math.max(0, client.flash - deltaTime * 4)

	if client.elapsed >= client.qualityCheckAt then
		client.qualityCheckAt = client.elapsed + 3
		updateQualityScale()
	end

	local clockTime = EnvironmentManager.GetClockTime()
	Lighting.ClockTime = clockTime

	local target = resolvePreset(state.Weather) or resolvePreset(Config.BasePreset)
	local alpha = getTransitionAlpha()
	local eased = TweenService:GetValue(alpha, Config.TransitionEasingStyle, Config.TransitionEasingDirection)
	local weather = blendWeather(client.fromWeather or target, target, eased, client.rendered)
	client.hasRendered = true

	local timeOfDay = sampleTimeOfDay(clockTime)
	applyEnvironment(weather, timeOfDay)
	updateParticles(weather, deltaTime)
	updateAurora(weather.Effects.Aurora * timeOfDay.Night)
	updateSounds(weather)
end

local function initClient()
	stateFolder = ReplicatedStorage:WaitForChild(STATE_FOLDER_NAME)
	lightningRemote = stateFolder:WaitForChild("LightningStrike")

	decodeClockState(stateFolder:GetAttribute("ClockState"))
	decodeWeatherState(stateFolder:GetAttribute("WeatherState"))

	EnvironmentManager.OptimizeGraphics()
	updateQualityScale()

	-- Late joiners mid-transition blend from the previous weather.
	local from = resolvePreset(state.PreviousWeather) or resolvePreset(state.Weather)
	if from then
		client.fromWeather = copyWeather(from)
	end

	client.sounds.Rain = createLoopSound("EnvironmentRain", Config.Sounds.Rain)
	client.sounds.Wind = createLoopSound("EnvironmentWind", Config.Sounds.Wind)

	table.insert(
		connections,
		stateFolder:GetAttributeChangedSignal("WeatherState"):Connect(function()
			local oldWeather = state.Weather
			-- Blend from whatever is on screen right now, so mid-transition changes never pop.
			if client.hasRendered then
				client.fromWeather = copyWeather(client.rendered)
			end
			decodeWeatherState(stateFolder:GetAttribute("WeatherState"))
			if state.Weather ~= oldWeather then
				weatherChangedEvent:Fire(state.Weather, oldWeather)
			end
		end)
	)
	table.insert(
		connections,
		stateFolder:GetAttributeChangedSignal("ClockState"):Connect(function()
			decodeClockState(stateFolder:GetAttribute("ClockState"))
		end)
	)
	table.insert(connections, lightningRemote.OnClientEvent:Connect(onLightningStrike))

	RunService:BindToRenderStep(RENDER_STEP_NAME, Enum.RenderPriority.Camera.Value + 1, renderStep)
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

-- Call once from a server Script and once from a LocalScript.
function EnvironmentManager.Init()
	if initialized then
		return
	end
	initialized = true
	table.clear(resolvedPresets)

	if RunService:IsServer() then
		initServer()
	elseif Players.LocalPlayer then
		initClient()
	end
end

function EnvironmentManager.Stop()
	server.loopToken += 1
	for _, connection in ipairs(connections) do
		connection:Disconnect()
	end
	table.clear(connections)

	if RunService:IsClient() then
		pcall(function()
			RunService:UnbindFromRenderStep(RENDER_STEP_NAME)
		end)
		if client.emitterPart then
			client.emitterPart:Destroy()
			client.emitterPart = nil
		end
		if client.aurora then
			client.aurora.anchor:Destroy()
			client.aurora = nil
		end
		for key, sound in pairs(client.sounds) do
			sound:Destroy()
			client.sounds[key] = nil
		end
	end
	initialized = false
end

return EnvironmentManager
```

---

## 2. Script `Environment` (ServerScriptService)

```lua
-- Starts the server side of EnvironmentManager (time, weather rotation, lightning).
-- Adjust the path if EnvironmentManager lives somewhere else in your game.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local EnvironmentManager = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("EnvironmentManager"))

EnvironmentManager.Init()
```

---

## 3. LocalScript `Environment` (StarterPlayer → StarterPlayerScripts)

```lua
-- Starts the client side of EnvironmentManager (lighting, particles, aurora, lightning visuals).
-- Adjust the path if EnvironmentManager lives somewhere else in your game.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local EnvironmentManager = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("EnvironmentManager"))

EnvironmentManager.Init()
```
