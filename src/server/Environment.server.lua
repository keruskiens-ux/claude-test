-- Starts the server side of EnvironmentManager (time, weather rotation, lightning).
-- Adjust the path if EnvironmentManager lives somewhere else in your game.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local EnvironmentManager = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("EnvironmentManager"))

EnvironmentManager.Init()
