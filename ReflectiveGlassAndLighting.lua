--[[
	ReflectiveGlassAndLighting.lua
	Place this LocalScript in: StarterPlayer > StarterPlayerScripts

	What it does:
	1. Finds all "glass" parts in the workspace (by name or existing Glass material)
	   and converts them to reflective glass.
	2. Watches for new parts added later and converts those too.
	3. Boosts Lighting properties for nicer shadows, sun glow, and atmosphere
	   using only built-in Lighting properties (no external shader plugins needed).
--]]

local Lighting = game:GetService("Lighting")
local Workspace = game:GetService("Workspace")

--------------------------------------------------
-- 1. REFLECTIVE GLASS
--------------------------------------------------

local REFLECTANCE = 0.4        -- 0 = no reflection, 1 = mirror-like
local MIN_TRANSPARENCY = 0.3
local MAX_TRANSPARENCY = 0.6

local function isGlass(part)
	if not part:IsA("BasePart") then
		return false
	end

	local nameMatch = string.find(string.lower(part.Name), "glass") ~= nil
	local materialMatch = part.Material == Enum.Material.Glass

	return nameMatch or materialMatch
end

local function makeReflective(part)
	part.Material = Enum.Material.Glass
	part.Reflectance = REFLECTANCE
	part.Transparency = math.clamp(part.Transparency, MIN_TRANSPARENCY, MAX_TRANSPARENCY)
end

local function scanAndConvert(root)
	for _, descendant in ipairs(root:GetDescendants()) do
		if isGlass(descendant) then
			makeReflective(descendant)
		end
	end
end

-- Initial pass over everything already in the workspace
scanAndConvert(Workspace)

-- Convert new parts as they're added (e.g. streamed in, spawned, etc.)
Workspace.DescendantAdded:Connect(function(descendant)
	task.defer(function()
		if isGlass(descendant) then
			makeReflective(descendant)
		end
	end)
end)

--------------------------------------------------
-- 2. LIGHTING / VISUAL UPGRADE
--------------------------------------------------

-- Core lighting technology: Future is the best built-in option
-- for real shadows, reflections, and bloom.
Lighting.Technology = Enum.Technology.Future

-- Global lighting tweaks
Lighting.GlobalShadows = true
Lighting.Brightness = 3
Lighting.ExposureCompensation = 0.2
Lighting.ClockTime = 15 -- afternoon sun angle, adjust 0-24 as you like
Lighting.EnvironmentDiffuseScale = 0.5
Lighting.EnvironmentSpecularScale = 0.7

-- Shadow softness (only affects certain Technology modes, safe to set anyway)
Lighting.ShadowSoftness = 0.2

-- Fog for depth/atmosphere
Lighting.FogStart = 200
Lighting.FogEnd = 3000
Lighting.FogColor = Color3.fromRGB(180, 190, 210)

--------------------------------------------------
-- Post-processing effects (Bloom, ColorCorrection, SunRays)
--------------------------------------------------

local function getOrCreate(className, name)
	local existing = Lighting:FindFirstChild(name)
	if existing and existing:IsA(className) then
		return existing
	end
	if existing then
		existing:Destroy()
	end
	local inst = Instance.new(className)
	inst.Name = name
	inst.Parent = Lighting
	return inst
end

local bloom = getOrCreate("BloomEffect", "AutoBloom")
bloom.Intensity = 0.6
bloom.Size = 24
bloom.Threshold = 1.2

local colorCorrection = getOrCreate("ColorCorrectionEffect", "AutoColorCorrection")
colorCorrection.Brightness = 0.02
colorCorrection.Contrast = 0.1
colorCorrection.Saturation = 0.05
colorCorrection.TintColor = Color3.fromRGB(255, 250, 245)

local sunRays = getOrCreate("SunRaysEffect", "AutoSunRays")
sunRays.Intensity = 0.2
sunRays.Spread = 0.5

print("[ReflectiveGlassAndLighting] Glass converted and lighting upgraded.")
