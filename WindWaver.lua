--[[
	WindWaver.lua
	--------------------------------------------------------------
	Place in: StarterPlayer > StarterPlayerScripts (LocalScript)

	What it does:
	Procedurally sways the character's limbs and head using sine-wave
	offsets applied directly to Motor6D.C0/C1 transforms every frame.
	This is NOT done via the Animation/Animator/AnimationTrack system —
	it's raw joint manipulation, so it layers on top of (and doesn't
	conflict with) walk/run/jump animations.

	Compatible with:
	- R15 rigs (uses arm/leg/head joints)
	- R6 rigs (uses arm/leg/head joints, different joint names)
	- Mobile, Console, PC (pure RenderStepped math, no input hooks,
	  no GUI, no platform-specific APIs)

	Effect: character gets a gentle "windswept" idle sway — arms drift,
	head tilts, legs shift slightly — like standing in a light breeze.
	Doesn't fight walking/running because it fades out automatically
	based on the character's horizontal speed.
--]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local player = Players.LocalPlayer

-- ================= CONFIG =================
local SPEED = 1.8          -- oscillation speed (radians/sec-ish)
local AMPLITUDE = 0.14     -- max radians of sway
local HEAD_AMPLITUDE = 0.06
local FADE_SPEED_THRESHOLD = 4  -- studs/sec: sway fades out above this speed
-- ============================================

-- Stores original C0 for every joint we touch, per-character, so we can
-- always compute offsets from a clean base (avoids drift/accumulation).
local originalC0 = {}

-- Maps rig type -> list of {jointName, parentPartName, waveFn}
-- waveFn(t) returns a CFrame offset to multiply onto the original C0.
local function getJointConfig(humanoid)
	local rigType = humanoid.RigType

	if rigType == Enum.HumanoidRigType.R15 then
		return {
			{ joint = "LeftShoulder",  part = "LeftUpperArm",  axis = "sway" },
			{ joint = "RightShoulder", part = "RightUpperArm", axis = "sway", invert = true },
			{ joint = "LeftHip",       part = "LeftUpperLeg",  axis = "swayLeg" },
			{ joint = "RightHip",      part = "RightUpperLeg", axis = "swayLeg", invert = true },
			{ joint = "Neck",          part = "Head",          axis = "head" },
		}
	else -- R6
		return {
			{ joint = "Left Shoulder",  part = "Left Arm",  axis = "sway" },
			{ joint = "Right Shoulder", part = "Right Arm",  axis = "sway", invert = true },
			{ joint = "Left Hip",       part = "Left Leg",   axis = "swayLeg" },
			{ joint = "Right Hip",      part = "Right Leg",  axis = "swayLeg", invert = true },
			{ joint = "Neck",           part = "Head",       axis = "head" },
		}
	end
end

-- Finds the Motor6D by name, searching the Torso/UpperTorso/HumanoidRootPart area
local function findMotor(character, jointName)
	for _, part in ipairs(character:GetDescendants()) do
		if part:IsA("Motor6D") and part.Name == jointName then
			return part
		end
	end
	return nil
end

local function setupCharacter(character)
	local humanoid = character:WaitForChild("Humanoid", 5)
	if not humanoid then return end

	local config = getJointConfig(humanoid)
	local motors = {}

	for _, entry in ipairs(config) do
		local motor = findMotor(character, entry.joint)
		if motor then
			originalC0[motor] = motor.C0
			table.insert(motors, {
				motor = motor,
				axis = entry.axis,
				invert = entry.invert and -1 or 1,
			})
		end
	end

	local rootPart = character:FindFirstChild("HumanoidRootPart") or character:FindFirstChild("Torso")
	local connection

	connection = RunService.RenderStepped:Connect(function(dt)
		if not character.Parent or humanoid.Health <= 0 then
			connection:Disconnect()
			return
		end

		-- Determine how fast the character is moving to fade the sway
		-- out during walking/running so it never fights locomotion anims.
		local speed = 0
		if rootPart then
			local vel = rootPart.AssemblyLinearVelocity
			speed = Vector3.new(vel.X, 0, vel.Z).Magnitude
		end
		local fade = math.clamp(1 - (speed / FADE_SPEED_THRESHOLD), 0, 1)

		if fade <= 0 then
			-- Snap back to original pose, do nothing else this frame
			for _, entry in ipairs(motors) do
				entry.motor.C0 = originalC0[entry.motor]
			end
			return
		end

		local t = os.clock() * SPEED

		for _, entry in ipairs(motors) do
			local motor = entry.motor
			local base = originalC0[motor]
			local inv = entry.invert
			local offset

			if entry.axis == "sway" then
				-- Arms: gentle forward/back + slight outward drift
				local a = math.sin(t) * AMPLITUDE * inv
				local b = math.cos(t * 0.6) * (AMPLITUDE * 0.5)
				offset = CFrame.Angles(a, 0, b * inv)

			elseif entry.axis == "swayLeg" then
				-- Legs: subtle weight-shift side to side
				local a = math.sin(t * 0.8 + math.pi) * (AMPLITUDE * 0.35) * inv
				offset = CFrame.Angles(0, 0, a)

			elseif entry.axis == "head" then
				-- Head: slow tilt/turn like looking around in the wind
				local a = math.sin(t * 0.5) * HEAD_AMPLITUDE
				local b = math.cos(t * 0.35) * HEAD_AMPLITUDE * 0.6
				offset = CFrame.Angles(b, a, 0)
			else
				offset = CFrame.new()
			end

			-- Blend smoothly between the resting pose and the swayed pose
			-- using CFrame:Lerp (handles rotation interpolation correctly).
			motor.C0 = base:Lerp(base * offset, fade)
		end
	end)

	character:SetAttribute("WindWaverActive", true)
end

-- Hook current + future characters
if player.Character then
	setupCharacter(player.Character)
end
player.CharacterAdded:Connect(setupCharacter)
