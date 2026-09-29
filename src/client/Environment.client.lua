-- Starts the client side of EnvironmentManager (lighting, particles, aurora, lightning visuals).
-- Adjust the path if EnvironmentManager lives somewhere else in your game.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local EnvironmentManager = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("EnvironmentManager"))

EnvironmentManager.Init()
