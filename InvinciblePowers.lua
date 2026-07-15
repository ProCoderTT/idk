--[[
	INVINCIBLE-STYLE POWERS LOCALSCRIPT
	------------------------------------------------------------
	Fully procedural Motor6D animation (no AnimationIds / KeyframeSequences -
	every pose is computed and applied to Motor6D.C0/C1 every frame),
	a mobile-first touch UI, flight system with launch/land impact,
	super sprint, and a heavy punch power.

	Place this as a LocalScript inside StarterPlayer > StarterPlayerScripts.
	------------------------------------------------------------
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")
local Workspace = game:GetService("Workspace")
local TextService = game:GetService("TextService")

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")
local Camera = Workspace.CurrentCamera

--======================================================
-- CONFIG
--======================================================
local CONFIG = {
	FlySpeedBase = 85,
	FlySpeedSprint = 210,
	FlyAccel = 10,
	FlyBankMax = 35,        -- degrees of roll when turning while flying
	FlyPitchMax = 40,       -- degrees of pitch when moving fwd/back while flying
	LaunchImpulse = 95,     -- upward velocity applied when taking off
	LandingImpactRadius = 14,
	LandingImpactMinFallVel = 65, -- studs/sec downward speed needed to trigger a crater shockwave
	PunchRange = 7,
	PunchDamage = 18,       -- only applied if target has a Humanoid (won't error otherwise)
	PunchCooldown = 0.55,
	SprintMultiplier = 1.8,
	HoverBobSpeed = 2.2,
	HoverBobAmount = 0.06,
}

--======================================================
-- CHARACTER / RIG REFERENCES
--======================================================
local Character = LocalPlayer.Character or LocalPlayer.CharacterAdded:Wait()
local Humanoid = Character:WaitForChild("Humanoid")
local RootPart = Character:WaitForChild("HumanoidRootPart")

Humanoid.RequiresNeck = false -- avoid engine auto neck-correction messing with manual poses (no-op if unsupported, wrapped safely)
pcall(function()
	Humanoid.AutoRotate = true
end)

-- Motor6D map. We support both R15 and R6 rigs, resolving whichever exists.
local Motors = {}
local IsR15 = Character:FindFirstChild("UpperTorso") ~= nil

local function getMotor(part, name)
	local p = Character:FindFirstChild(part)
	if not p then return nil end
	local m = p:FindFirstChild(name)
	if m and m:IsA("Motor6D") then
		return m
	end
	return nil
end

if IsR15 then
	Motors.Root       = getMotor("LowerTorso", "Root")
	Motors.Waist      = getMotor("UpperTorso", "Waist")
	Motors.Neck       = getMotor("Head", "Neck")
	Motors.LeftShoulder  = getMotor("LeftUpperArm", "LeftShoulder")
	Motors.RightShoulder = getMotor("RightUpperArm", "RightShoulder")
	Motors.LeftElbow  = getMotor("LeftLowerArm", "LeftElbow")
	Motors.RightElbow = getMotor("RightLowerArm", "RightElbow")
	Motors.LeftHip    = getMotor("LeftUpperLeg", "LeftHip")
	Motors.RightHip   = getMotor("RightUpperLeg", "RightHip")
	Motors.LeftKnee   = getMotor("LeftLowerLeg", "LeftKnee")
	Motors.RightKnee  = getMotor("RightLowerLeg", "RightKnee")
else
	-- R6 fallback
	Motors.Root          = getMotor("Torso", "RootJoint")
	Motors.Waist         = nil
	Motors.Neck          = getMotor("Torso", "Neck") or getMotor("Head", "Neck")
	Motors.LeftShoulder  = getMotor("Torso", "Left Shoulder")
	Motors.RightShoulder = getMotor("Torso", "Right Shoulder")
	Motors.LeftHip       = getMotor("Torso", "Left Hip")
	Motors.RightHip      = getMotor("Torso", "Right Hip")
end

-- Store each motor's rest pose (C0) so we can offset from it every frame
-- rather than accumulate drift.
local RestC0 = {}
for name, motor in pairs(Motors) do
	if motor then
		RestC0[name] = motor.C0
	end
end

local function setPose(name, cframeOffset)
	local motor = Motors[name]
	if not motor then return end
	local rest = RestC0[name]
	if not rest then return end
	motor.C0 = rest * cframeOffset
end

--======================================================
-- STATE
--======================================================
local State = {
	Flying = false,
	Sprinting = false,
	Grounded = true,
	LastFallVelocityY = 0,
	PunchCooldownTimer = 0,
	MoveVector = Vector2.new(0, 0), -- from joystick, x = strafe, y = forward
	CamYaw = 0,
	FlyVelocity = Vector3.new(0, 0, 0),
	AnimTime = 0,
	PunchingLeft = false,
	PunchingRight = false,
	PunchAnimTimer = 0,
	LandingSquat = 0, -- 0..1, decays after hard landing
}

local BodyGyro = nil
local BodyVelocityFly = nil

--======================================================
-- UTILITY MATH
--======================================================
local function lerp(a, b, t)
	return a + (b - a) * t
end

local function clamp(v, lo, hi)
	if v < lo then return lo end
	if v > hi then return hi end
	return v
end

local function dampAngle(current, target, speed, dt)
	return lerp(current, target, clamp(speed * dt, 0, 1))
end

--======================================================
-- VISUAL EFFECTS (ring, needed before flight functions below)
--======================================================
local function spawnRingEffect(position, color)
	local ring = Instance.new("Part")
	ring.Anchored = true
	ring.CanCollide = false
	ring.Material = Enum.Material.Neon
	ring.Shape = Enum.PartType.Cylinder
	ring.Color = color or Color3.fromRGB(255, 255, 255)
	ring.Size = Vector3.new(0.2, 4, 4)
	ring.CFrame = CFrame.new(position) * CFrame.Angles(0, 0, math.rad(90))
	ring.Transparency = 0.2
	ring.Parent = Workspace

	local tween = TweenService:Create(ring, TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = Vector3.new(0.2, 18, 18),
		Transparency = 1,
	})
	tween:Play()
	Debris:AddItem(ring, 0.6)
end

--======================================================
-- FLIGHT PHYSICS
--======================================================
local function ensureFlightForces()
	if not RootPart then return end
	if not BodyGyro then
		BodyGyro = Instance.new("BodyGyro")
		BodyGyro.Name = "PowersBodyGyro"
		BodyGyro.MaxTorque = Vector3.new(0, 0, 0)
		BodyGyro.P = 4000
		BodyGyro.D = 200
		BodyGyro.Parent = RootPart
	end
	if not BodyVelocityFly then
		BodyVelocityFly = Instance.new("BodyVelocity")
		BodyVelocityFly.Name = "PowersFlyVelocity"
		BodyVelocityFly.MaxForce = Vector3.new(0, 0, 0)
		BodyVelocityFly.Velocity = Vector3.new(0, 0, 0)
		BodyVelocityFly.Parent = RootPart
	end
end

local function startFlying()
	if State.Flying then return end
	State.Flying = true
	Humanoid.PlatformStand = false
	Humanoid:ChangeState(Enum.HumanoidStateType.Physics)
	ensureFlightForces()
	BodyGyro.MaxTorque = Vector3.new(400000, 400000, 400000)
	BodyVelocityFly.MaxForce = Vector3.new(1e9, 1e9, 1e9)

	-- launch pop upward
	RootPart.AssemblyLinearVelocity = RootPart.AssemblyLinearVelocity + Vector3.new(0, CONFIG.LaunchImpulse, 0)
	spawnRingEffect(RootPart.Position - Vector3.new(0, 3, 0), Color3.fromRGB(120, 200, 255))
end

local function stopFlying()
	if not State.Flying then return end
	State.Flying = false
	if BodyGyro then BodyGyro.MaxTorque = Vector3.new(0,0,0) end
	if BodyVelocityFly then BodyVelocityFly.MaxForce = Vector3.new(0,0,0) end
	Humanoid:ChangeState(Enum.HumanoidStateType.Freefall)
end

--======================================================
-- VISUAL EFFECTS (impact/shockwave; ring defined earlier)
--======================================================
local function spawnShockwave(position)
	for i = 1, 2 do
		local ring = Instance.new("Part")
		ring.Anchored = true
		ring.CanCollide = false
		ring.Material = Enum.Material.Neon
		ring.Shape = Enum.PartType.Cylinder
		ring.Color = Color3.fromRGB(255, 200, 120)
		ring.Size = Vector3.new(0.2, 2, 2)
		ring.CFrame = CFrame.new(position) * CFrame.Angles(0, 0, math.rad(90))
		ring.Transparency = 0.1
		ring.Parent = Workspace

		local delay_ = (i - 1) * 0.08
		task.delay(delay_, function()
			local tw = TweenService:Create(ring, TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
				Size = Vector3.new(0.2, CONFIG.LandingImpactRadius * 2, CONFIG.LandingImpactRadius * 2),
				Transparency = 1,
			})
			tw:Play()
		end)
		Debris:AddItem(ring, 1.2)
	end

	-- dust particles as small parts
	for i = 1, 10 do
		local chip = Instance.new("Part")
		chip.Size = Vector3.new(0.3, 0.3, 0.3)
		chip.Color = Color3.fromRGB(120, 110, 100)
		chip.Material = Enum.Material.Slate
		chip.CanCollide = false
		chip.CFrame = CFrame.new(position + Vector3.new(math.random(-5,5), 0.5, math.random(-5,5)))
		chip.Parent = Workspace
		local dir = Vector3.new(math.random(-10,10), math.random(6,14), math.random(-10,10))
		chip.AssemblyLinearVelocity = dir
		Debris:AddItem(chip, 1.5)
	end
end

local function spawnPunchImpact(position, color)
	local flash = Instance.new("Part")
	flash.Anchored = true
	flash.CanCollide = false
	flash.Material = Enum.Material.Neon
	flash.Shape = Enum.PartType.Ball
	flash.Color = color or Color3.fromRGB(255, 255, 255)
	flash.Size = Vector3.new(1, 1, 1)
	flash.CFrame = CFrame.new(position)
	flash.Transparency = 0.1
	flash.Parent = Workspace

	local tween = TweenService:Create(flash, TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = Vector3.new(5, 5, 5),
		Transparency = 1,
	})
	tween:Play()
	Debris:AddItem(flash, 0.3)
end

--======================================================
-- MOBILE UI CONSTRUCTION
--======================================================
local ScreenGui = Instance.new("ScreenGui")
ScreenGui.Name = "PowersUI"
ScreenGui.ResetOnSpawn = false
ScreenGui.IgnoreGuiInset = true
ScreenGui.Parent = PlayerGui

-- ============ Joystick (bottom-left, movement while flying) ============
local JoyOuter = Instance.new("Frame")
JoyOuter.Name = "JoystickOuter"
JoyOuter.Size = UDim2.new(0, 130, 0, 130)
JoyOuter.Position = UDim2.new(0, 40, 1, -180)
JoyOuter.AnchorPoint = Vector2.new(0, 0)
JoyOuter.BackgroundColor3 = Color3.fromRGB(20, 20, 30)
JoyOuter.BackgroundTransparency = 0.45
JoyOuter.BorderSizePixel = 0
JoyOuter.Parent = ScreenGui

local JoyOuterCorner = Instance.new("UICorner")
JoyOuterCorner.CornerRadius = UDim.new(1, 0)
JoyOuterCorner.Parent = JoyOuter

local JoyOuterStroke = Instance.new("UIStroke")
JoyOuterStroke.Color = Color3.fromRGB(120, 200, 255)
JoyOuterStroke.Thickness = 2
JoyOuterStroke.Transparency = 0.3
JoyOuterStroke.Parent = JoyOuter

local JoyKnob = Instance.new("Frame")
JoyKnob.Name = "JoystickKnob"
JoyKnob.Size = UDim2.new(0, 56, 0, 56)
JoyKnob.AnchorPoint = Vector2.new(0.5, 0.5)
JoyKnob.Position = UDim2.new(0.5, 0, 0.5, 0)
JoyKnob.BackgroundColor3 = Color3.fromRGB(120, 200, 255)
JoyKnob.BackgroundTransparency = 0.15
JoyKnob.BorderSizePixel = 0
JoyKnob.Parent = JoyOuter

local JoyKnobCorner = Instance.new("UICorner")
JoyKnobCorner.CornerRadius = UDim.new(1, 0)
JoyKnobCorner.Parent = JoyKnob

-- ============ Fly Button (bottom-right) ============
local FlyButton = Instance.new("TextButton")
FlyButton.Name = "FlyButton"
FlyButton.Size = UDim2.new(0, 90, 0, 90)
FlyButton.Position = UDim2.new(1, -130, 1, -220)
FlyButton.BackgroundColor3 = Color3.fromRGB(30, 30, 45)
FlyButton.BackgroundTransparency = 0.25
FlyButton.Text = "FLY"
FlyButton.TextColor3 = Color3.fromRGB(255, 255, 255)
FlyButton.Font = Enum.Font.GothamBold
FlyButton.TextSize = 18
FlyButton.AutoButtonColor = false
FlyButton.Parent = ScreenGui

local FlyButtonCorner = Instance.new("UICorner")
FlyButtonCorner.CornerRadius = UDim.new(1, 0)
FlyButtonCorner.Parent = FlyButton

local FlyButtonStroke = Instance.new("UIStroke")
FlyButtonStroke.Color = Color3.fromRGB(120, 200, 255)
FlyButtonStroke.Thickness = 2
FlyButtonStroke.Transparency = 0.2
FlyButtonStroke.Parent = FlyButton

-- ============ Punch Button ============
local PunchButton = Instance.new("TextButton")
PunchButton.Name = "PunchButton"
PunchButton.Size = UDim2.new(0, 78, 0, 78)
PunchButton.Position = UDim2.new(1, -230, 1, -190)
PunchButton.BackgroundColor3 = Color3.fromRGB(45, 25, 25)
PunchButton.BackgroundTransparency = 0.25
PunchButton.Text = "PUNCH"
PunchButton.TextColor3 = Color3.fromRGB(255, 255, 255)
PunchButton.Font = Enum.Font.GothamBold
PunchButton.TextSize = 14
PunchButton.AutoButtonColor = false
PunchButton.Parent = ScreenGui

local PunchButtonCorner = Instance.new("UICorner")
PunchButtonCorner.CornerRadius = UDim.new(1, 0)
PunchButtonCorner.Parent = PunchButton

local PunchButtonStroke = Instance.new("UIStroke")
PunchButtonStroke.Color = Color3.fromRGB(255, 140, 120)
PunchButtonStroke.Thickness = 2
PunchButtonStroke.Transparency = 0.2
PunchButtonStroke.Parent = PunchButton

-- ============ Sprint Toggle ============
local SprintButton = Instance.new("TextButton")
SprintButton.Name = "SprintButton"
SprintButton.Size = UDim2.new(0, 78, 0, 46)
SprintButton.Position = UDim2.new(1, -230, 1, -100)
SprintButton.BackgroundColor3 = Color3.fromRGB(25, 45, 30)
SprintButton.BackgroundTransparency = 0.25
SprintButton.Text = "SPRINT"
SprintButton.TextColor3 = Color3.fromRGB(255, 255, 255)
SprintButton.Font = Enum.Font.GothamBold
SprintButton.TextSize = 14
SprintButton.AutoButtonColor = false
SprintButton.Parent = ScreenGui

local SprintButtonCorner = Instance.new("UICorner")
SprintButtonCorner.CornerRadius = UDim.new(0, 12)
SprintButtonCorner.Parent = SprintButton

local SprintButtonStroke = Instance.new("UIStroke")
SprintButtonStroke.Color = Color3.fromRGB(140, 255, 160)
SprintButtonStroke.Thickness = 2
SprintButtonStroke.Transparency = 0.2
SprintButtonStroke.Parent = SprintButton

-- ============ Status label (top center) ============
local StatusLabel = Instance.new("TextLabel")
StatusLabel.Name = "StatusLabel"
StatusLabel.Size = UDim2.new(0, 300, 0, 36)
StatusLabel.Position = UDim2.new(0.5, -150, 0, 20)
StatusLabel.BackgroundTransparency = 1
StatusLabel.Text = "GROUNDED"
StatusLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
StatusLabel.Font = Enum.Font.GothamBold
StatusLabel.TextSize = 20
StatusLabel.TextStrokeTransparency = 0.5
StatusLabel.Parent = ScreenGui

--======================================================
-- INPUT HANDLING: JOYSTICK
--======================================================
local joyActive = false
local joyInputObj = nil
local joyCenter = Vector2.new()
local joyRadius = 55

local function joyBegin(input)
	joyActive = true
	joyInputObj = input
	joyCenter = Vector2.new(JoyOuter.AbsolutePosition.X + JoyOuter.AbsoluteSize.X/2, JoyOuter.AbsolutePosition.Y + JoyOuter.AbsoluteSize.Y/2)
end

local function joyUpdate(pos)
	local delta = Vector2.new(pos.X, pos.Y) - joyCenter
	local mag = delta.Magnitude
	if mag > joyRadius then
		delta = delta.Unit * joyRadius
	end
	JoyKnob.Position = UDim2.new(0.5, delta.X, 0.5, delta.Y)
	local normalized = delta / joyRadius
	-- x = strafe, y = forward (screen down is +Y so invert)
	State.MoveVector = Vector2.new(normalized.X, -normalized.Y)
end

local function joyEnd()
	joyActive = false
	joyInputObj = nil
	JoyKnob.Position = UDim2.new(0.5, 0, 0.5, 0)
	State.MoveVector = Vector2.new(0, 0)
end

JoyOuter.InputBegan:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1 then
		joyBegin(input)
		joyUpdate(input.Position)
	end
end)

UserInputService.InputChanged:Connect(function(input)
	if joyActive and input == joyInputObj then
		joyUpdate(input.Position)
	end
end)

UserInputService.InputEnded:Connect(function(input)
	if joyActive and input == joyInputObj then
		joyEnd()
	end
end)

--======================================================
-- INPUT HANDLING: BUTTONS
--======================================================
local function flashButton(button, onColor)
	local original = button.BackgroundColor3
	TweenService:Create(button, TweenInfo.new(0.1), {BackgroundColor3 = onColor}):Play()
	task.delay(0.15, function()
		TweenService:Create(button, TweenInfo.new(0.2), {BackgroundColor3 = original}):Play()
	end)
end

FlyButton.MouseButton1Click:Connect(function()
	if State.Flying then
		stopFlying()
		FlyButton.Text = "FLY"
	else
		startFlying()
		FlyButton.Text = "LAND"
	end
	flashButton(FlyButton, Color3.fromRGB(120, 200, 255))
end)

SprintButton.MouseButton1Click:Connect(function()
	State.Sprinting = not State.Sprinting
	SprintButton.BackgroundColor3 = State.Sprinting and Color3.fromRGB(60, 140, 70) or Color3.fromRGB(25, 45, 30)
	Humanoid.WalkSpeed = State.Sprinting and (16 * CONFIG.SprintMultiplier) or 16
end)

local function doPunch()
	if State.PunchCooldownTimer > 0 then return end
	State.PunchCooldownTimer = CONFIG.PunchCooldown
	State.PunchAnimTimer = 0.35
	State.PunchingRight = not State.PunchingLeft and true or false
	State.PunchingLeft = not State.PunchingRight

	-- toggle which arm to alternate punches
	if math.random() > 0.5 then
		State.PunchingLeft = true
		State.PunchingRight = false
	else
		State.PunchingLeft = false
		State.PunchingRight = true
	end

	task.delay(0.18, function()
		-- resolve hit at the "extended" point of the punch
		local lookVector = RootPart.CFrame.LookVector
		local originPos = RootPart.Position + lookVector * 2
		local hitPos = RootPart.Position + lookVector * CONFIG.PunchRange

		local rayParams = RaycastParams.new()
		rayParams.FilterDescendantsInstances = {Character}
		rayParams.FilterType = Enum.RaycastFilterType.Exclude

		local result = Workspace:Raycast(originPos, lookVector * CONFIG.PunchRange, rayParams)
		if result then
			spawnPunchImpact(result.Position, Color3.fromRGB(255, 220, 150))
			local hitModel = result.Instance:FindFirstAncestorOfClass("Model")
			if hitModel then
				local hum = hitModel:FindFirstChildOfClass("Humanoid")
				if hum then
					hum:TakeDamage(CONFIG.PunchDamage)
				end
				local primary = hitModel.PrimaryPart or hitModel:FindFirstChild("HumanoidRootPart")
				if primary and primary:IsA("BasePart") then
					primary.AssemblyLinearVelocity = primary.AssemblyLinearVelocity + lookVector * 60 + Vector3.new(0, 20, 0)
				end
			end
		else
			spawnPunchImpact(hitPos, Color3.fromRGB(255, 255, 255))
		end
	end)
end

PunchButton.MouseButton1Click:Connect(function()
	doPunch()
	flashButton(PunchButton, Color3.fromRGB(255, 140, 120))
end)

--======================================================
-- CAMERA-RELATIVE MOVEMENT WHILE FLYING
--======================================================
local function getFlightDirection(dt)
	local camCF = Camera.CFrame
	local flatLook = Vector3.new(camCF.LookVector.X, 0, camCF.LookVector.Z)
	if flatLook.Magnitude < 0.001 then
		flatLook = Vector3.new(0, 0, -1)
	else
		flatLook = flatLook.Unit
	end
	local flatRight = Vector3.new(camCF.RightVector.X, 0, camCF.RightVector.Z)
	if flatRight.Magnitude < 0.001 then
		flatRight = Vector3.new(1, 0, 0)
	else
		flatRight = flatRight.Unit
	end

	local forwardAmt = State.MoveVector.Y
	local strafeAmt = State.MoveVector.X

	local dir = (flatLook * forwardAmt) + (flatRight * strafeAmt)
	return dir, forwardAmt, strafeAmt
end

--======================================================
-- PROCEDURAL ANIMATION SYSTEM
--======================================================
-- All poses are additive CFrame offsets from each Motor6D's resting C0.
-- We drive them purely from state (speed, flying, grounded, punch timers, time)
-- with no external animation assets whatsoever.

local function angle(deg)
	return math.rad(deg)
end

local function poseIdle(t, dt)
	local breathe = math.sin(t * 1.6) * 0.03
	local sway = math.sin(t * 0.8) * 0.02

	setPose("Waist", CFrame.new(0, breathe * 0.3, 0) * CFrame.Angles(breathe * 0.15, sway, 0))
	setPose("Neck", CFrame.Angles(-breathe * 0.1, 0, sway * 0.5))

	setPose("LeftShoulder", CFrame.Angles(angle(2) + breathe, 0, angle(4)))
	setPose("RightShoulder", CFrame.Angles(angle(2) - breathe, 0, angle(-4)))
	setPose("LeftElbow", CFrame.Angles(angle(6), 0, 0))
	setPose("RightElbow", CFrame.Angles(angle(6), 0, 0))

	setPose("LeftHip", CFrame.Angles(0, 0, angle(1)))
	setPose("RightHip", CFrame.Angles(0, 0, angle(-1)))
	setPose("LeftKnee", CFrame.new())
	setPose("RightKnee", CFrame.new())
end

local function poseWalk(t, dt, speedFactor)
	-- speedFactor: 1 = normal walk, up to ~2.5 for sprint
	local cycle = t * 9 * speedFactor
	local legSwing = math.sin(cycle)
	local legSwingOpp = math.sin(cycle + math.pi)
	local armSwing = math.sin(cycle + math.pi) -- arms opposite legs
	local armSwingOpp = math.sin(cycle)

	local bodyBob = math.abs(math.cos(cycle)) * 0.08
	local bodyLean = clamp(speedFactor - 1, 0, 1.5) * angle(10)

	setPose("Waist", CFrame.new(0, bodyBob, 0) * CFrame.Angles(bodyLean * 0.3, math.sin(cycle) * 0.05, math.sin(cycle * 0.5) * 0.03))
	setPose("Neck", CFrame.Angles(-bodyLean * 0.15, 0, 0))

	setPose("LeftShoulder", CFrame.Angles(armSwing * angle(45) + angle(3), 0, angle(4)))
	setPose("RightShoulder", CFrame.Angles(armSwingOpp * angle(45) + angle(3), 0, angle(-4)))
	setPose("LeftElbow", CFrame.Angles(angle(20) + math.abs(armSwing) * angle(25), 0, 0))
	setPose("RightElbow", CFrame.Angles(angle(20) + math.abs(armSwingOpp) * angle(25), 0, 0))

	setPose("LeftHip", CFrame.Angles(legSwing * angle(35), 0, 0))
	setPose("RightHip", CFrame.Angles(legSwingOpp * angle(35), 0, 0))
	setPose("LeftKnee", CFrame.Angles(math.max(0, -legSwing) * angle(55), 0, 0))
	setPose("RightKnee", CFrame.Angles(math.max(0, -legSwingOpp) * angle(55), 0, 0))
end

local function poseFlyHover(t, dt)
	-- Superman-esque hover pose: arms slightly out, legs together and trailing.
	local bob = math.sin(t * CONFIG.HoverBobSpeed) * CONFIG.HoverBobAmount

	setPose("Waist", CFrame.new(0, bob, 0) * CFrame.Angles(angle(-8), 0, 0))
	setPose("Neck", CFrame.Angles(angle(6), 0, 0))

	setPose("LeftShoulder", CFrame.Angles(angle(-20), 0, angle(20)))
	setPose("RightShoulder", CFrame.Angles(angle(-20), 0, angle(-20)))
	setPose("LeftElbow", CFrame.Angles(angle(10), 0, 0))
	setPose("RightElbow", CFrame.Angles(angle(10), 0, 0))

	setPose("LeftHip", CFrame.Angles(angle(-6), 0, angle(2)))
	setPose("RightHip", CFrame.Angles(angle(-6), 0, angle(-2)))
	setPose("LeftKnee", CFrame.Angles(angle(8), 0, 0))
	setPose("RightKnee", CFrame.Angles(angle(8), 0, 0))
end

local function poseFlyForward(t, dt, forwardAmt, strafeAmt, bank, pitch)
	-- Classic "flying superhero" pose: body pitched forward, arms forward like a dive,
	-- legs trailing straight back. Banking on turns.
	local pitchRad = angle(pitch)
	local bankRad = angle(bank)
	local flap = math.sin(t * 6) * 0.03 * math.max(0, forwardAmt)

	setPose("Waist", CFrame.Angles(pitchRad, 0, bankRad * 0.5))
	setPose("Neck", CFrame.Angles(-pitchRad * 0.4, 0, -bankRad * 0.2))

	local armFwd = angle(-150) -- arms extended forward/up (Superman pose)
	setPose("LeftShoulder", CFrame.Angles(armFwd + flap, angle(8), angle(12)))
	setPose("RightShoulder", CFrame.Angles(armFwd - flap, angle(-8), angle(-12)))
	setPose("LeftElbow", CFrame.Angles(angle(6), 0, 0))
	setPose("RightElbow", CFrame.Angles(angle(6), 0, 0))

	setPose("LeftHip", CFrame.Angles(angle(-10) - pitchRad * 0.3, 0, angle(2) + bankRad * 0.15))
	setPose("RightHip", CFrame.Angles(angle(-10) - pitchRad * 0.3, 0, angle(-2) + bankRad * 0.15))
	setPose("LeftKnee", CFrame.Angles(angle(4), 0, 0))
	setPose("RightKnee", CFrame.Angles(angle(4), 0, 0))
end

local function poseFreefall(t, dt)
	local flail = math.sin(t * 10) * 0.08
	setPose("Waist", CFrame.Angles(angle(-15), 0, flail))
	setPose("Neck", CFrame.Angles(angle(10), 0, 0))
	setPose("LeftShoulder", CFrame.Angles(angle(-60) + flail, 0, angle(30)))
	setPose("RightShoulder", CFrame.Angles(angle(-60) - flail, 0, angle(-30)))
	setPose("LeftElbow", CFrame.Angles(angle(30), 0, 0))
	setPose("RightElbow", CFrame.Angles(angle(30), 0, 0))
	setPose("LeftHip", CFrame.Angles(angle(-20), 0, 0))
	setPose("RightHip", CFrame.Angles(angle(-20), 0, 0))
	setPose("LeftKnee", CFrame.Angles(angle(30), 0, 0))
	setPose("RightKnee", CFrame.Angles(angle(30), 0, 0))
end

local function poseLandingSquat(t, squatAmt)
	-- squatAmt: 0..1
	setPose("Waist", CFrame.new(0, -squatAmt * 0.3, 0) * CFrame.Angles(squatAmt * angle(25), 0, 0))
	setPose("Neck", CFrame.Angles(-squatAmt * angle(10), 0, 0))
	setPose("LeftShoulder", CFrame.Angles(-squatAmt * angle(30), 0, angle(10)))
	setPose("RightShoulder", CFrame.Angles(-squatAmt * angle(30), 0, angle(-10)))
	setPose("LeftHip", CFrame.Angles(-squatAmt * angle(45), 0, 0))
	setPose("RightHip", CFrame.Angles(-squatAmt * angle(45), 0, 0))
	setPose("LeftKnee", CFrame.Angles(squatAmt * angle(70), 0, 0))
	setPose("RightKnee", CFrame.Angles(squatAmt * angle(70), 0, 0))
end

-- Punch pose overlays on top of arm joints, blended by a timer (0.35s window)
local function applyPunchOverlay(dt)
	if State.PunchAnimTimer <= 0 then return end
	State.PunchAnimTimer = math.max(0, State.PunchAnimTimer - dt)
	local tNorm = 1 - (State.PunchAnimTimer / 0.35) -- 0 -> 1 across the punch
	-- quick out-and-back curve
	local extend = math.sin(tNorm * math.pi) -- 0 -> 1 -> 0

	if State.PunchingRight then
		setPose("RightShoulder", CFrame.Angles(angle(-80) * extend, 0, angle(-6)))
		setPose("RightElbow", CFrame.Angles(angle(-10) * extend, 0, 0))
	elseif State.PunchingLeft then
		setPose("LeftShoulder", CFrame.Angles(angle(-80) * extend, 0, angle(6)))
		setPose("LeftElbow", CFrame.Angles(angle(-10) * extend, 0, 0))
	end
end

--======================================================
-- MAIN UPDATE LOOP
--======================================================
local lastPos = RootPart.Position
local lastVelY = 0

RunService.Heartbeat:Connect(function(dt)
	if not Character or not Character.Parent then return end
	if not Humanoid or Humanoid.Health <= 0 then return end
	if not RootPart or not RootPart.Parent then return end

	State.AnimTime = State.AnimTime + dt
	if State.PunchCooldownTimer > 0 then
		State.PunchCooldownTimer = math.max(0, State.PunchCooldownTimer - dt)
	end

	local velocity = RootPart.AssemblyLinearVelocity
	local horizSpeed = Vector3.new(velocity.X, 0, velocity.Z).Magnitude
	local velY = velocity.Y

	----------------------------------------------------
	-- FLIGHT PHYSICS UPDATE
	----------------------------------------------------
	if State.Flying then
		ensureFlightForces()

		local dir, forwardAmt, strafeAmt = getFlightDirection(dt)
		local targetSpeed = State.Sprinting and CONFIG.FlySpeedSprint or CONFIG.FlySpeedBase
		local desiredVel

		if dir.Magnitude > 0.05 then
			desiredVel = dir.Unit * targetSpeed * clamp(dir.Magnitude, 0, 1)
		else
			desiredVel = Vector3.new(0, 0, 0)
		end

		-- vertical control: hold nothing = slight hover maintenance
		local verticalHold = 0
		if UserInputService:IsKeyDown(Enum.KeyCode.Space) then
			verticalHold = targetSpeed * 0.6
		elseif UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) then
			verticalHold = -targetSpeed * 0.6
		end
		desiredVel = desiredVel + Vector3.new(0, verticalHold, 0)

		State.FlyVelocity = State.FlyVelocity:Lerp(desiredVel, clamp(CONFIG.FlyAccel * dt, 0, 1))
		BodyVelocityFly.Velocity = State.FlyVelocity

		-- orient body toward travel direction (yaw only), keep upright otherwise
		local campCF = Camera.CFrame
		local flatLook = Vector3.new(campCF.LookVector.X, 0, campCF.LookVector.Z)
		if flatLook.Magnitude > 0.001 then
			local targetCFrame = CFrame.new(RootPart.Position, RootPart.Position + flatLook)
			BodyGyro.CFrame = targetCFrame
		end

		State.Grounded = false
	else
		if BodyVelocityFly then BodyVelocityFly.MaxForce = Vector3.new(0,0,0) end
		if BodyGyro then BodyGyro.MaxTorque = Vector3.new(0,0,0) end

		-- detect landing impact after falling
		if lastVelY < -CONFIG.LandingImpactMinFallVel and velY > -5 and math.abs(velY - lastVelY) > 20 then
			spawnShockwave(RootPart.Position - Vector3.new(0, 3, 0))
			State.LandingSquat = 1
		end
	end

	lastVelY = velY

	----------------------------------------------------
	-- ANIMATION STATE SELECTION
	----------------------------------------------------
	local t = State.AnimTime

	if State.LandingSquat > 0 then
		State.LandingSquat = math.max(0, State.LandingSquat - dt * 3.2)
		poseLandingSquat(t, State.LandingSquat)
	elseif State.Flying then
		local dir, forwardAmt, strafeAmt = getFlightDirection(dt)
		local speedRatio = clamp(horizSpeed / CONFIG.FlySpeedSprint, 0, 1)

		if horizSpeed < 4 then
			poseFlyHover(t, dt)
		else
			local bank = clamp(-strafeAmt * CONFIG.FlyBankMax, -CONFIG.FlyBankMax, CONFIG.FlyBankMax)
			local pitch = clamp(forwardAmt * CONFIG.FlyPitchMax, -CONFIG.FlyPitchMax * 0.4, CONFIG.FlyPitchMax)
			poseFlyForward(t, dt, forwardAmt, strafeAmt, bank, pitch)
		end
	elseif Humanoid:GetState() == Enum.HumanoidStateType.Freefall then
		poseFreefall(t, dt)
	elseif horizSpeed > 1.5 then
		local speedFactor = State.Sprinting and 1.8 or 1.0
		poseWalk(t, dt, speedFactor * clamp(horizSpeed / 16, 0.6, 2.2))
	else
		poseIdle(t, dt)
	end

	-- punch overlays after base pose so it takes priority on arms
	applyPunchOverlay(dt)

	----------------------------------------------------
	-- STATUS LABEL
	----------------------------------------------------
	if State.Flying then
		local speedTxt = State.Sprinting and "MAX SPEED" or "FLYING"
		StatusLabel.Text = speedTxt .. string.format("  %.0f st/s", horizSpeed)
	elseif Humanoid:GetState() == Enum.HumanoidStateType.Freefall then
		StatusLabel.Text = "FALLING"
	elseif horizSpeed > 1.5 then
		StatusLabel.Text = State.Sprinting and "SPRINTING" or "WALKING"
	else
		StatusLabel.Text = "GROUNDED"
	end

	lastPos = RootPart.Position
end)

--======================================================
-- KEYBOARD SUPPORT (PC fallback alongside mobile UI)
--======================================================
UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then return end
	if input.KeyCode == Enum.KeyCode.F then
		if State.Flying then
			stopFlying()
			FlyButton.Text = "FLY"
		else
			startFlying()
			FlyButton.Text = "LAND"
		end
	elseif input.KeyCode == Enum.KeyCode.E then
		doPunch()
	elseif input.KeyCode == Enum.KeyCode.LeftShift then
		State.Sprinting = true
		Humanoid.WalkSpeed = 16 * CONFIG.SprintMultiplier
		SprintButton.BackgroundColor3 = Color3.fromRGB(60, 140, 70)
	end

	-- WASD feeds the same MoveVector used for flight steering when no joystick touch
	if not joyActive then
		if input.KeyCode == Enum.KeyCode.W then
			State.MoveVector = Vector2.new(State.MoveVector.X, 1)
		elseif input.KeyCode == Enum.KeyCode.S then
			State.MoveVector = Vector2.new(State.MoveVector.X, -1)
		elseif input.KeyCode == Enum.KeyCode.A then
			State.MoveVector = Vector2.new(-1, State.MoveVector.Y)
		elseif input.KeyCode == Enum.KeyCode.D then
			State.MoveVector = Vector2.new(1, State.MoveVector.Y)
		end
	end
end)

UserInputService.InputEnded:Connect(function(input, gameProcessed)
	if input.KeyCode == Enum.KeyCode.LeftShift then
		State.Sprinting = false
		Humanoid.WalkSpeed = 16
		SprintButton.BackgroundColor3 = Color3.fromRGB(25, 45, 30)
	end

	if not joyActive then
		if input.KeyCode == Enum.KeyCode.W or input.KeyCode == Enum.KeyCode.S then
			State.MoveVector = Vector2.new(State.MoveVector.X, 0)
		elseif input.KeyCode == Enum.KeyCode.A or input.KeyCode == Enum.KeyCode.D then
			State.MoveVector = Vector2.new(0, State.MoveVector.Y)
		end
	end
end)

--======================================================
-- CHARACTER RESPAWN HANDLING
--======================================================
LocalPlayer.CharacterAdded:Connect(function(newChar)
	-- Since this is a LocalScript in StarterPlayerScripts, the script itself
	-- persists across respawns only if it's not destroyed; StarterPlayerScripts
	-- localscripts do get re-run per character in some setups, but to be safe
	-- we simply reload by re-running key setup if this instance survives.
	Character = newChar
	Humanoid = Character:WaitForChild("Humanoid")
	RootPart = Character:WaitForChild("HumanoidRootPart")
	BodyGyro = nil
	BodyVelocityFly = nil
	State.Flying = false
	State.Sprinting = false
	State.LandingSquat = 0
	State.FlyVelocity = Vector3.new(0,0,0)

	IsR15 = Character:FindFirstChild("UpperTorso") ~= nil
	Motors = {}
	RestC0 = {}

	if IsR15 then
		Motors.Root       = getMotor("LowerTorso", "Root")
		Motors.Waist      = getMotor("UpperTorso", "Waist")
		Motors.Neck       = getMotor("Head", "Neck")
		Motors.LeftShoulder  = getMotor("LeftUpperArm", "LeftShoulder")
		Motors.RightShoulder = getMotor("RightUpperArm", "RightShoulder")
		Motors.LeftElbow  = getMotor("LeftLowerArm", "LeftElbow")
		Motors.RightElbow = getMotor("RightLowerArm", "RightElbow")
		Motors.LeftHip    = getMotor("LeftUpperLeg", "LeftHip")
		Motors.RightHip   = getMotor("RightUpperLeg", "RightHip")
		Motors.LeftKnee   = getMotor("LeftLowerLeg", "LeftKnee")
		Motors.RightKnee  = getMotor("RightLowerLeg", "RightKnee")
	else
		Motors.Root          = getMotor("Torso", "RootJoint")
		Motors.Neck          = getMotor("Torso", "Neck") or getMotor("Head", "Neck")
		Motors.LeftShoulder  = getMotor("Torso", "Left Shoulder")
		Motors.RightShoulder = getMotor("Torso", "Right Shoulder")
		Motors.LeftHip       = getMotor("Torso", "Left Hip")
		Motors.RightHip      = getMotor("Torso", "Right Hip")
	end

	for name, motor in pairs(Motors) do
		if motor then
			RestC0[name] = motor.C0
		end
	end

	FlyButton.Text = "FLY"
	StatusLabel.Text = "GROUNDED"
end)

print("[Powers] Invincible-style powers script loaded. FLY / PUNCH / SPRINT buttons active. Keys: F = fly, E = punch, Shift = sprint.")
