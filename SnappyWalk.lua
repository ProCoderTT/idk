-- LocalScript
-- Place in: StarterPlayer > StarterPlayerScripts

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local player = Players.LocalPlayer

-- === Wait for character to fully load ===
local function waitForCharacter()
	local character = player.Character or player.CharacterAdded:Wait()

	if not character.Parent then
		character.AncestryChanged:Wait()
	end

	local humanoid = character:WaitForChild("Humanoid")
	local rootPart = character:WaitForChild("HumanoidRootPart")

	local requiredParts = {"HumanoidRootPart", "Torso", "Head"}
	for _, name in ipairs(requiredParts) do
		if character:FindFirstChild(name) then
			character:WaitForChild(name)
		end
	end

	humanoid:WaitForChild("Animator", 5)

	return character, humanoid, rootPart
end

local character, humanoid, rootPart = waitForCharacter()

-- === Remove the default Animate script ===
local animateScript = character:FindFirstChild("Animate")
if animateScript then
	animateScript:Destroy()
end

-- Stop any currently playing animation tracks (in case Animate already started one)
local animator = humanoid:FindFirstChildOfClass("Animator")
if animator then
	for _, track in ipairs(animator:GetPlayingAnimationTracks()) do
		track:Stop(0)
	end
end

-- === Determine rig type ===
local isR15 = humanoid.RigType == Enum.HumanoidRigType.R15

-- Cache joints we need to snap
local joints = {}

local function getJoint(partName, jointName)
	local part = character:FindFirstChild(partName)
	if part then
		return part:FindFirstChild(jointName)
	end
	return nil
end

if isR15 then
	joints.LeftHip = getJoint("LeftUpperLeg", "LeftHip")
	joints.RightHip = getJoint("RightUpperLeg", "RightHip")
	joints.LeftShoulder = getJoint("LeftUpperArm", "LeftShoulder")
	joints.RightShoulder = getJoint("RightUpperArm", "RightShoulder")
else
	-- R6
	joints.LeftHip = getJoint("Left Leg", "LeftHip")
	joints.RightHip = getJoint("Right Leg", "RightHip")
	joints.LeftShoulder = getJoint("Left Arm", "LeftShoulder")
	joints.RightShoulder = getJoint("Right Arm", "RightShoulder")
end

-- Store default C0 CFrames so poses offset correctly from the rig's rest pose
local baseC0 = {}
for name, joint in pairs(joints) do
	if joint then
		baseC0[name] = joint.C0
	end
end

-- === Snappy walk settings ===
local STEP_INTERVAL = 0.15 -- seconds between each "snap" pose (lower = faster steps)
local SWING_ANGLE = 45 -- degrees of leg/arm swing
local stepTimer = 0
local poseIndex = 1 -- alternates between 1 and 2
local currentlyPosed = false

-- Two poses: forward-swing and back-swing. Setting C0 directly (no tweening)
-- is what creates the instant "snap" rather than smooth interpolation.
local function applyPose(index)
	local angle = math.rad(SWING_ANGLE)
	local sign = (index == 1) and 1 or -1

	if joints.LeftHip then
		joints.LeftHip.C0 = baseC0.LeftHip * CFrame.Angles(sign * angle, 0, 0)
	end
	if joints.RightHip then
		joints.RightHip.C0 = baseC0.RightHip * CFrame.Angles(-sign * angle, 0, 0)
	end
	if joints.LeftShoulder then
		joints.LeftShoulder.C0 = baseC0.LeftShoulder * CFrame.Angles(-sign * angle, 0, 0)
	end
	if joints.RightShoulder then
		joints.RightShoulder.C0 = baseC0.RightShoulder * CFrame.Angles(sign * angle, 0, 0)
	end
end

local function resetPose()
	for name, joint in pairs(joints) do
		if joint then
			joint.C0 = baseC0[name]
		end
	end
	currentlyPosed = false
end

-- === Main loop: detect movement and snap-step ===
RunService.RenderStepped:Connect(function(dt)
	if not character.Parent or humanoid.Health <= 0 then
		return
	end

	local moveVector = humanoid.MoveDirection
	local isMoving = moveVector.Magnitude > 0.05
	local state = humanoid:GetState()
	local isGrounded = (state == Enum.HumanoidStateType.Running or state == Enum.HumanoidStateType.RunningNoPhysics)

	if isMoving and isGrounded then
		stepTimer = stepTimer + dt
		if stepTimer >= STEP_INTERVAL then
			stepTimer = 0
			poseIndex = (poseIndex == 1) and 2 or 1
			applyPose(poseIndex)
			currentlyPosed = true
		end
	else
		stepTimer = 0
		if currentlyPosed then
			resetPose()
		end
	end
end)

-- === Handle character respawning ===
player.CharacterAdded:Connect(function(newCharacter)
	-- Re-run the whole setup for the new character by reloading this script's logic.
	-- Simplest robust approach: just reload the player scripts.
	local playerScripts = player:FindFirstChild("PlayerScripts")
	if playerScripts then
		-- Roblox will automatically re-run StarterPlayerScripts on respawn,
		-- so no manual action is needed here in most cases.
	end
end)
