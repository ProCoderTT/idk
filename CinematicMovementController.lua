--[[
	CINEMATIC MOVEMENT CONTROLLER
	-----------------------------
	Single LocalScript. Drop into StarterPlayer > StarterPlayerScripts.

	Features:
	  - Smooth Sprint w/ FOV kick
	  - Slide (FPS style)
	  - Dive & Roll
	  - Wall Run
	  - Double Jump
	  - Camera Bob
	  - Directional Dash
	  - Speed motion blur / trails
	  - Shoulder camera toggle
	  - Procedural-ish animations (built from CFrame joint tweens, no external anim IDs needed)
	  - Material-based footstep sounds
	  - Draggable toggle button + settings UI
	  - Full PC (keyboard/mouse) + Mobile (touch buttons) support

	HOW TO USE:
	  - PC:   Shift = Sprint, Ctrl = Slide (while sprinting/moving), Space = Jump/DoubleJump,
	          Q/E/R/F = Dash Left/Right/Forward/Back (or use on-screen dash pad),
	          V = Toggle shoulder cam, C = Roll/Dive (press while airborne or moving fast)
	  - Mobile: on-screen buttons appear automatically (Sprint, Jump, Slide, Dash pad, Roll)
	  - Tap the round draggable icon (top-right by default) to show/hide the settings menu.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local ContextActionService = game:GetService("ContextActionService")
local Workspace = game:GetService("Workspace")
local Lighting = game:GetService("Lighting")
local SoundService = game:GetService("SoundService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local camera = Workspace.CurrentCamera

local IS_MOBILE = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled

----------------------------------------------------------------
-- CONFIG / STATE
----------------------------------------------------------------

local Settings = {
	SprintEnabled = true,
	SlideEnabled = true,
	DiveRollEnabled = true,
	WallRunEnabled = true,
	DoubleJumpEnabled = true,
	CameraBobEnabled = true,
	DashEnabled = true,
	MotionBlurEnabled = true,
	ShoulderCamEnabled = false, -- toggled live, not a "feature enable" but included in UI
	FootstepsEnabled = true,
	AnimationsEnabled = true,
}

local Config = {
	WalkSpeed = 16,
	SprintSpeed = 26,
	SlideSpeed = 34,
	SprintFOV = 100,
	BaseFOV = 70,
	FOVLerpSpeed = 6,

	SlideDuration = 0.75,
	SlideMinSpeed = 8, -- min horizontal speed required to start a slide

	DashPower = 55,
	DashDuration = 0.2,
	DashCooldown = 0.6,

	WallRunMaxDuration = 2,
	WallRunSpeed = 24,
	WallRunGravity = 0.15, -- fraction of normal gravity applied
	WallCheckDistance = 3.2,

	DoubleJumpPower = 50,

	BobFrequency = 8,
	BobAmplitude = 0.08,
	SprintBobAmplitudeMult = 1.6,

	RollDuration = 0.5,
	DiveMinFallVelocity = -25, -- must be falling at least this fast (negative) to "dive" instead of roll only

	ShoulderOffset = Vector3.new(1.75, 0.25, 0),
}

----------------------------------------------------------------
-- CHARACTER REFERENCES (re-hooked on respawn)
----------------------------------------------------------------

local character, humanoid, rootPart, humanoidRootPart, animator
local torso, rightUpperArm, leftUpperArm, rightUpperLeg, leftUpperLeg
local isR15 = true

local function getCharacterParts()
	character = player.Character or player.CharacterAdded:Wait()
	humanoid = character:WaitForChild("Humanoid")
	rootPart = character:WaitForChild("HumanoidRootPart")
	humanoidRootPart = rootPart
	animator = humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = humanoid
	end
	isR15 = humanoid.RigType == Enum.HumanoidRigType.R15
end

getCharacterParts()

----------------------------------------------------------------
-- MOVEMENT STATE FLAGS
----------------------------------------------------------------

local isSprinting = false
local isSliding = false
local isDashing = false
local isWallRunning = false
local isRolling = false
local wallRunSide = nil -- "Left" / "Right"
local jumpsUsed = 0
local canDoubleJump = false
local lastDashTime = 0
local slideStartTime = 0
local currentSpeed = Config.WalkSpeed
local moveDirectionInput = Vector3.new()

local camShakeTime = 0
local bobTime = 0

----------------------------------------------------------------
-- SOUND SETUP
----------------------------------------------------------------

local soundsFolder = Instance.new("Folder")
soundsFolder.Name = "CMC_Sounds"
soundsFolder.Parent = camera

local footstepSounds = {
	Plastic = "rbxasset://sounds/footsteps/footsteps_plastic.mp3",
	Concrete = "rbxasset://sounds/footsteps/footsteps_plastic.mp3",
	Grass = "rbxasset://sounds/footsteps/footsteps_plastic.mp3",
	Wood = "rbxasset://sounds/footsteps/footsteps_plastic.mp3",
	Metal = "rbxasset://sounds/footsteps/footsteps_plastic.mp3",
	Sand = "rbxasset://sounds/footsteps/footsteps_plastic.mp3",
	Water = "rbxasset://sounds/footsteps/footsteps_plastic.mp3",
	Snow = "rbxasset://sounds/footsteps/footsteps_plastic.mp3",
	Default = "rbxasset://sounds/footsteps/footsteps_plastic.mp3",
}
-- Roblox doesn't ship many public per-material asset ids reliably accessible this way,
-- so we synthesize pitch/volume variation per material instead of relying on unique files.
local materialProfile = {
	[Enum.Material.Plastic] = {Pitch = 1.0, Volume = 0.4},
	[Enum.Material.Concrete] = {Pitch = 0.9, Volume = 0.5},
	[Enum.Material.Grass] = {Pitch = 1.15, Volume = 0.3},
	[Enum.Material.Wood] = {Pitch = 1.05, Volume = 0.45},
	[Enum.Material.Metal] = {Pitch = 0.8, Volume = 0.55},
	[Enum.Material.DiamondPlate] = {Pitch = 0.75, Volume = 0.55},
	[Enum.Material.Sand] = {Pitch = 1.2, Volume = 0.25},
	[Enum.Material.Snow] = {Pitch = 1.25, Volume = 0.3},
	[Enum.Material.Water] = {Pitch = 1.3, Volume = 0.4},
	[Enum.Material.Ice] = {Pitch = 1.1, Volume = 0.35},
	[Enum.Material.Fabric] = {Pitch = 1.1, Volume = 0.25},
	[Enum.Material.Ground] = {Pitch = 0.95, Volume = 0.4},
}

local footstepSound = Instance.new("Sound")
footstepSound.Name = "Footstep"
footstepSound.SoundId = "rbxasset://sounds/footsteps/footsteps_plastic.mp3"
footstepSound.Volume = 0.4
footstepSound.Parent = soundsFolder

local whooshSound = Instance.new("Sound")
whooshSound.Name = "Whoosh"
whooshSound.SoundId = "rbxasset://sounds/action_jump.mp3"
whooshSound.Volume = 0.5
whooshSound.Pitch = 1.4
whooshSound.Parent = soundsFolder

local dashSound = Instance.new("Sound")
dashSound.Name = "Dash"
dashSound.SoundId = "rbxasset://sounds/impact_water.mp3"
dashSound.Volume = 0.45
dashSound.Pitch = 1.8
dashSound.Parent = soundsFolder

local landSound = Instance.new("Sound")
landSound.Name = "Land"
landSound.SoundId = "rbxasset://sounds/action_jump.mp3"
landSound.Volume = 0.4
landSound.Pitch = 0.6
landSound.Parent = soundsFolder

local function playFootstep()
	if not Settings.FootstepsEnabled then return end
	if not rootPart then return end
	local rayParams = RaycastParams.new()
	rayParams.FilterDescendantsInstances = {character}
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	local result = Workspace:Raycast(rootPart.Position, Vector3.new(0, -5, 0), rayParams)
	local material = result and result.Instance and result.Instance.Material or Enum.Material.Plastic
	local profile = materialProfile[material] or {Pitch = 1.0, Volume = 0.4}
	footstepSound.PlaybackSpeed = profile.Pitch + math.random(-5, 5) / 100
	footstepSound.Volume = profile.Volume
	footstepSound:Play()
end

----------------------------------------------------------------
-- MOTION BLUR / TRAIL SETUP
----------------------------------------------------------------

local blurEffect = Instance.new("BlurEffect")
blurEffect.Name = "CMC_MotionBlur"
blurEffect.Size = 0
blurEffect.Parent = Lighting

local speedTrails = {}

local function setupTrails()
	for _, v in pairs(speedTrails) do
		if v then v:Destroy() end
	end
	speedTrails = {}
	if not character then return end

	local partsToTrail = {}
	if isR15 then
		partsToTrail = {"LeftHand", "RightHand", "LeftFoot", "RightFoot"}
	else
		partsToTrail = {"Left Arm", "Right Arm", "Left Leg", "Right Leg"}
	end

	for _, name in ipairs(partsToTrail) do
		local part = character:FindFirstChild(name)
		if part then
			local a0 = Instance.new("Attachment")
			a0.Position = Vector3.new(0, 0.3, 0)
			a0.Parent = part
			local a1 = Instance.new("Attachment")
			a1.Position = Vector3.new(0, -0.3, 0)
			a1.Parent = part

			local trail = Instance.new("Trail")
			trail.Attachment0 = a0
			trail.Attachment1 = a1
			trail.Lifetime = 0.25
			trail.MinLength = 0.05
			trail.WidthScale = NumberSequence.new(0.4)
			trail.Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 0.6),
				NumberSequenceKeypoint.new(1, 1),
			})
			trail.Color = ColorSequence.new(Color3.fromRGB(150, 200, 255))
			trail.Enabled = false
			trail.Parent = part

			table.insert(speedTrails, trail)
			table.insert(speedTrails, a0)
			table.insert(speedTrails, a1)
		end
	end
end

local function setTrailsEnabled(state)
	for _, v in pairs(speedTrails) do
		if v:IsA("Trail") then
			v.Enabled = state
		end
	end
end

----------------------------------------------------------------
-- SIMPLE PROCEDURAL ANIMATION HELPERS (joint tweening, no anim assets needed)
----------------------------------------------------------------

local function getJoint(name)
	if not character then return nil end
	if isR15 then
		local part
		if name == "Waist" then part = character:FindFirstChild("UpperTorso")
		elseif name == "Neck" then part = character:FindFirstChild("Head")
		end
		if part then
			for _, c in ipairs(part:GetChildren()) do
				if c:IsA("Motor6D") and c.Name == name then
					return c
				end
			end
		end
	else
		local torsoPart = character:FindFirstChild("Torso")
		if torsoPart then
			return torsoPart:FindFirstChild(name)
		end
	end
	return nil
end

local function tweenJoint(joint, cframe, time, style)
	if not joint then return end
	local tw = TweenService:Create(joint, TweenInfo.new(time, style or Enum.EasingStyle.Quad), {C0 = joint.C0 * cframe})
	tw:Play()
	return tw
end

-- store original C0s so we can restore
local originalC0 = {}
local function cacheOriginal(joint)
	if joint and not originalC0[joint] then
		originalC0[joint] = joint.C0
	end
end

local function restoreJoint(joint, time)
	if not joint or not originalC0[joint] then return end
	local tw = TweenService:Create(joint, TweenInfo.new(time or 0.3, Enum.EasingStyle.Quad), {C0 = originalC0[joint]})
	tw:Play()
end

local function playDashAnim()
	if not Settings.AnimationsEnabled then return end
	local waist = getJoint("Waist")
	cacheOriginal(waist)
	if waist then
		local tw = TweenService:Create(waist, TweenInfo.new(0.1, Enum.EasingStyle.Back), {C0 = originalC0[waist] * CFrame.Angles(0.3, 0, 0)})
		tw:Play()
		task.delay(Config.DashDuration, function()
			restoreJoint(waist, 0.25)
		end)
	end
end

local function playSlideAnim(active)
	if not Settings.AnimationsEnabled then return end
	local waist = getJoint("Waist")
	cacheOriginal(waist)
	if waist then
		if active then
			local tw = TweenService:Create(waist, TweenInfo.new(0.2, Enum.EasingStyle.Quad), {C0 = originalC0[waist] * CFrame.Angles(-0.9, 0, 0)})
			tw:Play()
		else
			restoreJoint(waist, 0.25)
		end
	end
end

local function playRollAnim()
	if not Settings.AnimationsEnabled then return end
	local hrp = rootPart
	if not hrp then return end
	-- spin the whole character forward for a roll feel
	local startCF = hrp.CFrame
	local rollConn
	local elapsed = 0
	rollConn = RunService.RenderStepped:Connect(function(dt)
		elapsed += dt
		if elapsed >= Config.RollDuration or not isRolling then
			rollConn:Disconnect()
			return
		end
	end)
end

local function playWallRunAnim(active, side)
	if not Settings.AnimationsEnabled then return end
	local waist = getJoint("Waist")
	cacheOriginal(waist)
	if waist then
		if active then
			local tiltDir = (side == "Left") and 0.35 or -0.35
			local tw = TweenService:Create(waist, TweenInfo.new(0.25, Enum.EasingStyle.Quad), {C0 = originalC0[waist] * CFrame.Angles(0, 0, tiltDir)})
			tw:Play()
		else
			restoreJoint(waist, 0.3)
		end
	end
end

----------------------------------------------------------------
-- CAMERA HANDLING
----------------------------------------------------------------

local defaultCameraOffset = Vector3.new()
local currentFOV = Config.BaseFOV
camera.FieldOfView = Config.BaseFOV

local function updateCameraOffset(dt)
	if not humanoid then return end
	local targetOffset = Vector3.new()
	if Settings.ShoulderCamEnabled then
		targetOffset = Config.ShoulderOffset
	end

	-- camera bob
	if Settings.CameraBobEnabled and humanoid.MoveDirection.Magnitude > 0.1 and humanoid.FloorMaterial ~= Enum.Material.Air then
		local speedFactor = isSprinting and Config.SprintBobAmplitudeMult or 1
		bobTime += dt * Config.BobFrequency * (isSprinting and 1.4 or 1)
		local bobY = math.sin(bobTime) * Config.BobAmplitude * speedFactor
		local bobX = math.cos(bobTime * 0.5) * Config.BobAmplitude * 0.5 * speedFactor
		targetOffset += Vector3.new(bobX, bobY, 0)
	else
		bobTime = 0
	end

	humanoid.CameraOffset = humanoid.CameraOffset:Lerp(targetOffset, math.clamp(dt * 10, 0, 1))
end

local function updateFOV(dt)
	local target = Config.BaseFOV
	if isSprinting or isDashing then
		target = Config.SprintFOV
	end
	if isSliding then
		target = Config.SprintFOV + 15
	end
	currentFOV = currentFOV + (target - currentFOV) * math.clamp(dt * Config.FOVLerpSpeed, 0, 1)
	camera.FieldOfView = currentFOV
end

local function updateMotionBlur(dt)
	if not Settings.MotionBlurEnabled then
		blurEffect.Size = 0
		setTrailsEnabled(false)
		return
	end
	local speed = rootPart and rootPart.AssemblyLinearVelocity.Magnitude or 0
	local shouldBlur = speed > (Config.SprintSpeed + 4) or isDashing or isSliding
	local targetSize = shouldBlur and 12 or 0
	blurEffect.Size = blurEffect.Size + (targetSize - blurEffect.Size) * math.clamp(dt * 8, 0, 1)
	setTrailsEnabled(shouldBlur)
end

----------------------------------------------------------------
-- SPRINT
----------------------------------------------------------------

local function setSprinting(state)
	if not Settings.SprintEnabled then state = false end
	if isSliding or isWallRunning then return end
	isSprinting = state
	if humanoid then
		humanoid.WalkSpeed = state and Config.SprintSpeed or Config.WalkSpeed
	end
end

----------------------------------------------------------------
-- SLIDE
----------------------------------------------------------------

local function endSlide()
	if not isSliding then return end
	isSliding = false
	playSlideAnim(false)
	if humanoid then
		humanoid.WalkSpeed = isSprinting and Config.SprintSpeed or Config.WalkSpeed
	end
end

local function startSlide()
	if not Settings.SlideEnabled then return end
	if isSliding or isWallRunning or isDashing then return end
	if not humanoid or not rootPart then return end
	if humanoid.FloorMaterial == Enum.Material.Air then return end

	local horizontalSpeed = Vector3.new(rootPart.AssemblyLinearVelocity.X, 0, rootPart.AssemblyLinearVelocity.Z).Magnitude
	if horizontalSpeed < Config.SlideMinSpeed and not isSprinting then return end

	isSliding = true
	slideStartTime = os.clock()
	humanoid.WalkSpeed = Config.SlideSpeed
	playSlideAnim(true)

	-- give a burst in the current facing direction
	local dir = rootPart.CFrame.LookVector
	if humanoid.MoveDirection.Magnitude > 0.1 then
		dir = humanoid.MoveDirection.Unit
	end
	rootPart.AssemblyLinearVelocity = Vector3.new(dir.X * Config.SlideSpeed, rootPart.AssemblyLinearVelocity.Y, dir.Z * Config.SlideSpeed)

	task.delay(Config.SlideDuration, function()
		endSlide()
	end)
end

----------------------------------------------------------------
-- DASH
----------------------------------------------------------------

local function dash(direction)
	if not Settings.DashEnabled then return end
	if isDashing then return end
	if os.clock() - lastDashTime < Config.DashCooldown then return end
	if not rootPart or not humanoid then return end

	lastDashTime = os.clock()
	isDashing = true
	playDashAnim()
	dashSound:Play()

	local lookVector = camera.CFrame.LookVector
	local rightVector = camera.CFrame.RightVector
	lookVector = Vector3.new(lookVector.X, 0, lookVector.Z).Unit
	rightVector = Vector3.new(rightVector.X, 0, rightVector.Z).Unit

	local dashVector
	if direction == "Forward" then dashVector = lookVector
	elseif direction == "Back" then dashVector = -lookVector
	elseif direction == "Left" then dashVector = -rightVector
	elseif direction == "Right" then dashVector = rightVector
	else dashVector = lookVector end

	local bodyVel = Instance.new("BodyVelocity")
	bodyVel.MaxForce = Vector3.new(1e5, 0, 1e5)
	bodyVel.Velocity = dashVector * Config.DashPower
	bodyVel.Parent = rootPart

	task.delay(Config.DashDuration, function()
		if bodyVel then bodyVel:Destroy() end
		isDashing = false
	end)
end

----------------------------------------------------------------
-- DOUBLE JUMP
----------------------------------------------------------------

local function tryJump()
	if not humanoid then return end
	if humanoid.FloorMaterial ~= Enum.Material.Air then
		jumpsUsed = 0
		humanoid.Jump = true
		jumpsUsed = 1
	elseif Settings.DoubleJumpEnabled and jumpsUsed == 1 and not isWallRunning then
		jumpsUsed = 2
		whooshSound:Play()
		if rootPart then
			rootPart.AssemblyLinearVelocity = Vector3.new(
				rootPart.AssemblyLinearVelocity.X,
				Config.DoubleJumpPower,
				rootPart.AssemblyLinearVelocity.Z
			)
		end
		if Settings.AnimationsEnabled then
			local waist = getJoint("Waist")
			cacheOriginal(waist)
			if waist then
				local tw = TweenService:Create(waist, TweenInfo.new(0.15, Enum.EasingStyle.Back), {C0 = originalC0[waist] * CFrame.Angles(-0.4, 0, 0)})
				tw:Play()
				task.delay(0.3, function() restoreJoint(waist, 0.3) end)
			end
		end
	elseif isWallRunning then
		-- jumping off a wall run launches you away from the wall
		jumpsUsed = 1
		local awayDir = rootPart.CFrame.RightVector * (wallRunSide == "Left" and -1 or 1)
		rootPart.AssemblyLinearVelocity = Vector3.new(awayDir.X * 20, 35, awayDir.Z * 20)
		isWallRunning = false
		playWallRunAnim(false)
	end
end

----------------------------------------------------------------
-- DIVE & ROLL
----------------------------------------------------------------

local function diveRoll()
	if not Settings.DiveRollEnabled then return end
	if isRolling or isSliding then return end
	if not rootPart or not humanoid then return end

	isRolling = true
	local wasAirborne = humanoid.FloorMaterial == Enum.Material.Air
	local fallVel = rootPart.AssemblyLinearVelocity.Y

	if wasAirborne and fallVel < Config.DiveMinFallVelocity then
		-- DIVE: forward lunge + reduce fall damage feel
		whooshSound:Play()
		local dir = camera.CFrame.LookVector
		dir = Vector3.new(dir.X, 0, dir.Z).Unit
		rootPart.AssemblyLinearVelocity = Vector3.new(dir.X * 30, math.max(fallVel * 0.4, -25), dir.Z * 30)
	end

	playRollAnim()
	if Settings.AnimationsEnabled and rootPart then
		local hip = getJoint("Waist")
		cacheOriginal(hip)
		if hip then
			local tw = TweenService:Create(hip, TweenInfo.new(Config.RollDuration / 2, Enum.EasingStyle.Sine), {C0 = originalC0[hip] * CFrame.Angles(-1.4, 0, 0)})
			tw:Play()
		end
	end

	task.delay(Config.RollDuration, function()
		isRolling = false
		local hip = getJoint("Waist")
		if hip then restoreJoint(hip, 0.3) end
	end)
end

----------------------------------------------------------------
-- WALL RUN
----------------------------------------------------------------

local wallRunStartTime = 0
local wallRunGyro = nil

local function checkWallRun(dt)
	if not Settings.WallRunEnabled then return end
	if not humanoid or not rootPart then return end
	if humanoid.FloorMaterial ~= Enum.Material.Air then
		if isWallRunning then
			isWallRunning = false
			playWallRunAnim(false)
		end
		return
	end
	if humanoid.MoveDirection.Magnitude < 0.1 and not isWallRunning then return end

	local rayParams = RaycastParams.new()
	rayParams.FilterDescendantsInstances = {character}
	rayParams.FilterType = Enum.RaycastFilterType.Exclude

	local rightDir = rootPart.CFrame.RightVector
	local leftDir = -rightDir

	local rightRay = Workspace:Raycast(rootPart.Position, rightDir * Config.WallCheckDistance, rayParams)
	local leftRay = Workspace:Raycast(rootPart.Position, leftDir * Config.WallCheckDistance, rayParams)

	if isWallRunning then
		if os.clock() - wallRunStartTime > Config.WallRunMaxDuration then
			isWallRunning = false
			playWallRunAnim(false)
			return
		end
		local ray = (wallRunSide == "Left") and leftRay or rightRay
		if not ray then
			isWallRunning = false
			playWallRunAnim(false)
			return
		end
		-- sustain forward speed, reduce gravity
		local forward = rootPart.CFrame.LookVector
		local vel = rootPart.AssemblyLinearVelocity
		rootPart.AssemblyLinearVelocity = Vector3.new(forward.X * Config.WallRunSpeed, vel.Y * Config.WallRunGravity, forward.Z * Config.WallRunSpeed)
	else
		if rightRay or leftRay then
			-- start wall run only if moving with decent horizontal speed
			local horizSpeed = Vector3.new(rootPart.AssemblyLinearVelocity.X, 0, rootPart.AssemblyLinearVelocity.Z).Magnitude
			if horizSpeed > 6 then
				isWallRunning = true
				wallRunSide = rightRay and "Right" or "Left"
				wallRunStartTime = os.clock()
				jumpsUsed = 1 -- allow a double jump style launch off wall
				playWallRunAnim(true, wallRunSide)
			end
		end
	end
end

----------------------------------------------------------------
-- FOOTSTEPS (distance-based trigger)
----------------------------------------------------------------

local lastFootstepPos = Vector3.new()
local FOOTSTEP_DISTANCE = 2.6

local function updateFootsteps()
	if not rootPart or not humanoid then return end
	if humanoid.FloorMaterial == Enum.Material.Air then return end
	if humanoid.MoveDirection.Magnitude < 0.1 then return end

	local flatPos = Vector3.new(rootPart.Position.X, 0, rootPart.Position.Z)
	if lastFootstepPos.Magnitude == 0 then
		lastFootstepPos = flatPos
		return
	end
	local dist = (flatPos - lastFootstepPos).Magnitude
	local threshold = isSprinting and (FOOTSTEP_DISTANCE * 0.7) or FOOTSTEP_DISTANCE
	if dist >= threshold then
		lastFootstepPos = flatPos
		playFootstep()
	end
end

----------------------------------------------------------------
-- LANDING DETECTION (for land sound + squash animation)
----------------------------------------------------------------

local wasInAir = false
local function updateLanding()
	if not humanoid then return end
	local inAir = humanoid.FloorMaterial == Enum.Material.Air
	if wasInAir and not inAir then
		landSound.Volume = 0.4
		landSound:Play()
		jumpsUsed = 0
		if Settings.AnimationsEnabled then
			local waist = getJoint("Waist")
			cacheOriginal(waist)
			if waist then
				local tw = TweenService:Create(waist, TweenInfo.new(0.08, Enum.EasingStyle.Quad), {C0 = originalC0[waist] * CFrame.Angles(0.25, 0, 0)})
				tw:Play()
				task.delay(0.15, function() restoreJoint(waist, 0.2) end)
			end
		end
	end
	wasInAir = inAir
end

----------------------------------------------------------------
-- MAIN UPDATE LOOP
----------------------------------------------------------------

RunService.RenderStepped:Connect(function(dt)
	if not humanoid or humanoid.Health <= 0 then return end

	checkWallRun(dt)
	updateFootsteps()
	updateLanding()
	updateCameraOffset(dt)
	updateFOV(dt)
	updateMotionBlur(dt)
end)

----------------------------------------------------------------
-- INPUT BINDINGS (PC)
----------------------------------------------------------------

UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then return end

	if input.KeyCode == Enum.KeyCode.LeftShift or input.KeyCode == Enum.KeyCode.RightShift then
		setSprinting(true)
	elseif input.KeyCode == Enum.KeyCode.LeftControl or input.KeyCode == Enum.KeyCode.RightControl then
		startSlide()
	elseif input.KeyCode == Enum.KeyCode.Space then
		tryJump()
	elseif input.KeyCode == Enum.KeyCode.C then
		diveRoll()
	elseif input.KeyCode == Enum.KeyCode.V then
		Settings.ShoulderCamEnabled = not Settings.ShoulderCamEnabled
	elseif input.KeyCode == Enum.KeyCode.Q then
		dash("Left")
	elseif input.KeyCode == Enum.KeyCode.E then
		dash("Right")
	elseif input.KeyCode == Enum.KeyCode.R then
		dash("Forward")
	elseif input.KeyCode == Enum.KeyCode.F then
		dash("Back")
	end
end)

UserInputService.InputEnded:Connect(function(input, gameProcessed)
	if input.KeyCode == Enum.KeyCode.LeftShift or input.KeyCode == Enum.KeyCode.RightShift then
		setSprinting(false)
	end
end)

----------------------------------------------------------------
-- CHARACTER RESPAWN HANDLING
----------------------------------------------------------------

player.CharacterAdded:Connect(function(newChar)
	character = newChar
	humanoid = character:WaitForChild("Humanoid")
	rootPart = character:WaitForChild("HumanoidRootPart")
	isR15 = humanoid.RigType == Enum.HumanoidRigType.R15
	isSprinting, isSliding, isDashing, isWallRunning, isRolling = false, false, false, false, false
	jumpsUsed = 0
	originalC0 = {}
	lastFootstepPos = Vector3.new()
	humanoid.WalkSpeed = Config.WalkSpeed
	task.wait(0.2)
	setupTrails()
end)

setupTrails()

----------------------------------------------------------------
----------------------------------------------------------------
-- UI SECTION
----------------------------------------------------------------
----------------------------------------------------------------

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "CMC_UI"
screenGui.ResetOnSpawn = false
screenGui.IgnoreGuiInset = true
screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
screenGui.Parent = playerGui

-- ===== Draggable Toggle Button =====
local toggleButton = Instance.new("TextButton")
toggleButton.Name = "ToggleButton"
toggleButton.Size = UDim2.new(0, 54, 0, 54)
toggleButton.Position = UDim2.new(1, -70, 0, 90)
toggleButton.AnchorPoint = Vector2.new(0, 0)
toggleButton.BackgroundColor3 = Color3.fromRGB(35, 35, 45)
toggleButton.BorderSizePixel = 0
toggleButton.Text = "☰"
toggleButton.TextColor3 = Color3.fromRGB(255, 255, 255)
toggleButton.TextScaled = true
toggleButton.Font = Enum.Font.GothamBold
toggleButton.AutoButtonColor = false
toggleButton.ZIndex = 100
toggleButton.Parent = screenGui

local toggleCorner = Instance.new("UICorner")
toggleCorner.CornerRadius = UDim.new(1, 0)
toggleCorner.Parent = toggleButton

local toggleStroke = Instance.new("UIStroke")
toggleStroke.Color = Color3.fromRGB(100, 170, 255)
toggleStroke.Thickness = 2
toggleStroke.Parent = toggleButton

-- ===== Main Settings Panel =====
local mainPanel = Instance.new("Frame")
mainPanel.Name = "MainPanel"
mainPanel.Size = UDim2.new(0, 260, 0, 430)
mainPanel.Position = UDim2.new(1, -280, 0, 150)
mainPanel.BackgroundColor3 = Color3.fromRGB(25, 25, 32)
mainPanel.BorderSizePixel = 0
mainPanel.Visible = false
mainPanel.ZIndex = 90
mainPanel.Parent = screenGui

local panelCorner = Instance.new("UICorner")
panelCorner.CornerRadius = UDim.new(0, 12)
panelCorner.Parent = mainPanel

local panelStroke = Instance.new("UIStroke")
panelStroke.Color = Color3.fromRGB(100, 170, 255)
panelStroke.Thickness = 1.5
panelStroke.Transparency = 0.3
panelStroke.Parent = mainPanel

local titleBar = Instance.new("Frame")
titleBar.Size = UDim2.new(1, 0, 0, 36)
titleBar.BackgroundColor3 = Color3.fromRGB(35, 35, 45)
titleBar.BorderSizePixel = 0
titleBar.ZIndex = 91
titleBar.Parent = mainPanel

local titleCorner = Instance.new("UICorner")
titleCorner.CornerRadius = UDim.new(0, 12)
titleCorner.Parent = titleBar

local titleFix = Instance.new("Frame")
titleFix.Size = UDim2.new(1, 0, 0, 12)
titleFix.Position = UDim2.new(0, 0, 1, -12)
titleFix.BackgroundColor3 = Color3.fromRGB(35, 35, 45)
titleFix.BorderSizePixel = 0
titleFix.ZIndex = 91
titleFix.Parent = titleBar

local titleLabel = Instance.new("TextLabel")
titleLabel.Size = UDim2.new(1, -36, 1, 0)
titleLabel.Position = UDim2.new(0, 10, 0, 0)
titleLabel.BackgroundTransparency = 1
titleLabel.Text = "Movement Controller"
titleLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
titleLabel.Font = Enum.Font.GothamBold
titleLabel.TextSize = 14
titleLabel.TextXAlignment = Enum.TextXAlignment.Left
titleLabel.ZIndex = 92
titleLabel.Parent = titleBar

local closeBtn = Instance.new("TextButton")
closeBtn.Size = UDim2.new(0, 28, 0, 28)
closeBtn.Position = UDim2.new(1, -32, 0, 4)
closeBtn.BackgroundColor3 = Color3.fromRGB(200, 60, 60)
closeBtn.Text = "X"
closeBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
closeBtn.Font = Enum.Font.GothamBold
closeBtn.TextSize = 14
closeBtn.ZIndex = 92
closeBtn.Parent = titleBar

local closeCorner = Instance.new("UICorner")
closeCorner.CornerRadius = UDim.new(0, 8)
closeCorner.Parent = closeBtn

local scrollFrame = Instance.new("ScrollingFrame")
scrollFrame.Size = UDim2.new(1, -10, 1, -46)
scrollFrame.Position = UDim2.new(0, 5, 0, 40)
scrollFrame.BackgroundTransparency = 1
scrollFrame.BorderSizePixel = 0
scrollFrame.ScrollBarThickness = 4
scrollFrame.CanvasSize = UDim2.new(0, 0, 0, 0)
scrollFrame.AutomaticCanvasSize = Enum.AutomaticSize.Y
scrollFrame.ZIndex = 91
scrollFrame.Parent = mainPanel

local listLayout = Instance.new("UIListLayout")
listLayout.Padding = UDim.new(0, 6)
listLayout.SortOrder = Enum.SortOrder.LayoutOrder
listLayout.Parent = scrollFrame

local function createToggleRow(labelText, settingKey, order)
	local row = Instance.new("Frame")
	row.Size = UDim2.new(1, -10, 0, 34)
	row.BackgroundColor3 = Color3.fromRGB(35, 35, 45)
	row.BorderSizePixel = 0
	row.LayoutOrder = order
	row.ZIndex = 91
	row.Parent = scrollFrame

	local rowCorner = Instance.new("UICorner")
	rowCorner.CornerRadius = UDim.new(0, 8)
	rowCorner.Parent = row

	local label = Instance.new("TextLabel")
	label.Size = UDim2.new(1, -60, 1, 0)
	label.Position = UDim2.new(0, 10, 0, 0)
	label.BackgroundTransparency = 1
	label.Text = labelText
	label.TextColor3 = Color3.fromRGB(230, 230, 230)
	label.Font = Enum.Font.Gotham
	label.TextSize = 13
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.ZIndex = 92
	label.Parent = row

	local switch = Instance.new("TextButton")
	switch.Size = UDim2.new(0, 44, 0, 22)
	switch.Position = UDim2.new(1, -52, 0.5, -11)
	switch.BackgroundColor3 = Settings[settingKey] and Color3.fromRGB(80, 200, 120) or Color3.fromRGB(90, 90, 100)
	switch.Text = ""
	switch.AutoButtonColor = false
	switch.ZIndex = 92
	switch.Parent = row

	local switchCorner = Instance.new("UICorner")
	switchCorner.CornerRadius = UDim.new(1, 0)
	switchCorner.Parent = switch

	local knob = Instance.new("Frame")
	knob.Size = UDim2.new(0, 18, 0, 18)
	knob.Position = Settings[settingKey] and UDim2.new(1, -20, 0.5, -9) or UDim2.new(0, 2, 0.5, -9)
	knob.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	knob.ZIndex = 93
	knob.Parent = switch

	local knobCorner = Instance.new("UICorner")
	knobCorner.CornerRadius = UDim.new(1, 0)
	knobCorner.Parent = knob

	switch.MouseButton1Click:Connect(function()
		Settings[settingKey] = not Settings[settingKey]
		local on = Settings[settingKey]
		TweenService:Create(switch, TweenInfo.new(0.15), {BackgroundColor3 = on and Color3.fromRGB(80, 200, 120) or Color3.fromRGB(90, 90, 100)}):Play()
		TweenService:Create(knob, TweenInfo.new(0.15), {Position = on and UDim2.new(1, -20, 0.5, -9) or UDim2.new(0, 2, 0.5, -9)}):Play()

		-- side effects when disabling mid-use
		if settingKey == "SprintEnabled" and not on then setSprinting(false) end
		if settingKey == "SlideEnabled" and not on then endSlide() end
		if settingKey == "MotionBlurEnabled" and not on then
			blurEffect.Size = 0
			setTrailsEnabled(false)
		end
	end)

	return row
end

createToggleRow("🏃 Sprint + FOV", "SprintEnabled", 1)
createToggleRow("🛝 Slide", "SlideEnabled", 2)
createToggleRow("🤸 Dive & Roll", "DiveRollEnabled", 3)
createToggleRow("🧗 Wall Run", "WallRunEnabled", 4)
createToggleRow("🪂 Double Jump", "DoubleJumpEnabled", 5)
createToggleRow("🌊 Camera Bob", "CameraBobEnabled", 6)
createToggleRow("💨 Dash", "DashEnabled", 7)
createToggleRow("✨ Motion Blur/Trails", "MotionBlurEnabled", 8)
createToggleRow("🎥 Shoulder Cam", "ShoulderCamEnabled", 9)
createToggleRow("🎭 Animations", "AnimationsEnabled", 10)
createToggleRow("🔊 Footsteps", "FootstepsEnabled", 11)

-- ===== Toggle button open/close logic =====
local panelOpen = false
local function setPanelOpen(state)
	panelOpen = state
	mainPanel.Visible = state
end

closeBtn.MouseButton1Click:Connect(function()
	setPanelOpen(false)
end)

-- ===== Draggable behavior for the toggle button (works for mouse + touch) =====
local dragging = false
local dragStart, startPos
local dragMoved = false
local DRAG_THRESHOLD = 6

local function beginDrag(input)
	dragging = true
	dragMoved = false
	dragStart = input.Position
	startPos = toggleButton.Position
end

local function updateDrag(input)
	if not dragging then return end
	local delta = input.Position - dragStart
	if delta.Magnitude > DRAG_THRESHOLD then
		dragMoved = true
	end
	local newPos = UDim2.new(
		startPos.X.Scale, startPos.X.Offset + delta.X,
		startPos.Y.Scale, startPos.Y.Offset + delta.Y
	)
	toggleButton.Position = newPos
end

local function endDrag()
	if not dragging then return end
	dragging = false
	if not dragMoved then
		setPanelOpen(not panelOpen)
	end
end

toggleButton.InputBegan:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
		beginDrag(input)
	end
end)

UserInputService.InputChanged:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
		updateDrag(input)
	end
end)

UserInputService.InputEnded:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
		endDrag()
	end
end)

----------------------------------------------------------------
-- MOBILE ON-SCREEN CONTROLS
----------------------------------------------------------------

if IS_MOBILE then
	local mobileFrame = Instance.new("Frame")
	mobileFrame.Name = "MobileControls"
	mobileFrame.Size = UDim2.new(1, 0, 1, 0)
	mobileFrame.BackgroundTransparency = 1
	mobileFrame.ZIndex = 50
	mobileFrame.Parent = screenGui

	local function createActionButton(text, size, pos, callback, anchor)
		local btn = Instance.new("TextButton")
		btn.Size = size
		btn.Position = pos
		btn.AnchorPoint = anchor or Vector2.new(0, 0)
		btn.BackgroundColor3 = Color3.fromRGB(30, 30, 40)
		btn.BackgroundTransparency = 0.25
		btn.Text = text
		btn.TextColor3 = Color3.fromRGB(255, 255, 255)
		btn.Font = Enum.Font.GothamBold
		btn.TextScaled = true
		btn.AutoButtonColor = false
		btn.ZIndex = 51
		btn.Parent = mobileFrame

		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(1, 0)
		corner.Parent = btn

		local stroke = Instance.new("UIStroke")
		stroke.Color = Color3.fromRGB(255, 255, 255)
		stroke.Transparency = 0.6
		stroke.Thickness = 1.5
		stroke.Parent = btn

		btn.MouseButton1Down:Connect(function()
			callback(true)
		end)
		btn.MouseButton1Up:Connect(function()
			callback(false)
		end)
		btn.TouchTap:Connect(function()
			-- fallback for quick taps
		end)

		return btn
	end

	-- Sprint button (bottom left area, toggle-hold style)
	createActionButton("SPRINT", UDim2.new(0, 90, 0, 90), UDim2.new(0, 20, 1, -140), function(pressed)
		setSprinting(pressed)
	end, Vector2.new(0, 0))

	-- Jump button (bottom right, above dash pad)
	createActionButton("JUMP", UDim2.new(0, 80, 0, 80), UDim2.new(1, -110, 1, -260), function(pressed)
		if pressed then tryJump() end
	end, Vector2.new(0, 0))

	-- Slide button
	createActionButton("SLIDE", UDim2.new(0, 70, 0, 70), UDim2.new(0, 120, 1, -110), function(pressed)
		if pressed then startSlide() end
	end, Vector2.new(0, 0))

	-- Roll/Dive button
	createActionButton("ROLL", UDim2.new(0, 70, 0, 70), UDim2.new(1, -190, 1, -100), function(pressed)
		if pressed then diveRoll() end
	end, Vector2.new(0, 0))

	-- Shoulder cam toggle
	createActionButton("CAM", UDim2.new(0, 56, 0, 56), UDim2.new(1, -70, 0, 160), function(pressed)
		if pressed then
			Settings.ShoulderCamEnabled = not Settings.ShoulderCamEnabled
		end
	end, Vector2.new(0, 0))

	-- Dash pad: small directional cluster bottom-right
	local dashPadCenter = UDim2.new(1, -110, 1, -370)
	createActionButton("↑", UDim2.new(0, 50, 0, 50), dashPadCenter + UDim2.new(0, 25, 0, -25), function(pressed)
		if pressed then dash("Forward") end
	end, Vector2.new(0, 0))
	createActionButton("↓", UDim2.new(0, 50, 0, 50), dashPadCenter + UDim2.new(0, 25, 0, 75), function(pressed)
		if pressed then dash("Back") end
	end, Vector2.new(0, 0))
	createActionButton("←", UDim2.new(0, 50, 0, 50), dashPadCenter + UDim2.new(0, -25, 0, 25), function(pressed)
		if pressed then dash("Left") end
	end, Vector2.new(0, 0))
	createActionButton("→", UDim2.new(0, 50, 0, 50), dashPadCenter + UDim2.new(0, 75, 0, 25), function(pressed)
		if pressed then dash("Right") end
	end, Vector2.new(0, 0))

	local dashLabel = Instance.new("TextLabel")
	dashLabel.Size = UDim2.new(0, 100, 0, 16)
	dashLabel.Position = dashPadCenter + UDim2.new(0, 0, 0, -50)
	dashLabel.BackgroundTransparency = 1
	dashLabel.Text = "DASH"
	dashLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
	dashLabel.TextTransparency = 0.3
	dashLabel.Font = Enum.Font.GothamBold
	dashLabel.TextSize = 12
	dashLabel.ZIndex = 51
	dashLabel.Parent = mobileFrame
end

print("[CinematicMovementController] Loaded successfully. Tap the ☰ button to open settings.")
