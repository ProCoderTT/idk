--[[
    Part Dot Tracker
    ------------------------------------------------------------
    A LocalScript that draws a small on-screen dot over a chosen
    body part of every player (or a specific player), with an
    optional velocity-based prediction so the dot leads slightly
    ahead of fast-moving parts instead of lagging behind them.

    HOW TO USE
    - Place this as a LocalScript inside StarterPlayerScripts
      (or StarterGui, wrapped so it runs once per client).
    - Run the game. A dark-themed floating panel appears.
    - Pick R6 or R15, pick the part from the dropdown list,
      toggle "Track All Players" or type a specific name,
      toggle "Prediction" if you want lead-prediction,
      then press "Start".
    - Press "Stop" to remove all dots.

    NOTES
    - This only draws 2D GUI dots (Billboard-free, pure ScreenGui
      + world-to-screen projection) — it does not alter physics,
      give wallhacks beyond what's already client-visible, or
      touch other players' data. It's meant as an in-house dev/
      QA tool (e.g. verifying hitbox/attachment placement,
      animation part offsets, network-prediction smoothing, etc).
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local LocalPlayer = Players.LocalPlayer
local Camera = workspace.CurrentCamera

----------------------------------------------------------------
-- CONFIG / STATE
----------------------------------------------------------------

local R6_PARTS = {
	"Head", "Torso",
	"Left Arm", "Right Arm",
	"Left Leg", "Right Leg",
	"HumanoidRootPart",
}

local R15_PARTS = {
	"Head", "UpperTorso", "LowerTorso",
	"LeftUpperArm", "LeftLowerArm", "LeftHand",
	"RightUpperArm", "RightLowerArm", "RightHand",
	"LeftUpperLeg", "LeftLowerLeg", "LeftFoot",
	"RightUpperLeg", "RightLowerLeg", "RightFoot",
	"HumanoidRootPart",
}

local state = {
	rigType = "R15",          -- "R6" or "R15"
	partName = "Head",        -- selected part name
	trackAll = true,          -- track every player, or...
	targetName = "",          -- ...only this player's name
	prediction = false,       -- lead-prediction toggle
	predictionTime = 0.15,    -- seconds to predict ahead
	running = false,
}

-- velocity tracking cache: [player] = {lastPos = Vector3, lastTime = number, vel = Vector3}
local velocityCache = {}

-- active dot frames: [player] = Frame
local activeDots = {}

local heartbeatConn = nil

----------------------------------------------------------------
-- GUI CONSTRUCTION
----------------------------------------------------------------

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "PartDotTrackerGui"
screenGui.ResetOnSpawn = false
screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
screenGui.DisplayOrder = 999
screenGui.Parent = LocalPlayer:WaitForChild("PlayerGui")

-- Dots live in a separate ScreenGui so we can toggle main panel visibility
-- without hiding active dots.
local dotsGui = Instance.new("ScreenGui")
dotsGui.Name = "PartDotTrackerDots"
dotsGui.ResetOnSpawn = false
dotsGui.IgnoreGuiInset = true
dotsGui.DisplayOrder = 998
dotsGui.Parent = LocalPlayer:WaitForChild("PlayerGui")

local COLOR_BG        = Color3.fromRGB(24, 24, 28)
local COLOR_BG_ALT    = Color3.fromRGB(32, 32, 38)
local COLOR_BORDER    = Color3.fromRGB(52, 52, 60)
local COLOR_ACCENT    = Color3.fromRGB(90, 130, 255)
local COLOR_ACCENT_D  = Color3.fromRGB(70, 100, 210)
local COLOR_TEXT      = Color3.fromRGB(235, 235, 240)
local COLOR_SUBTEXT   = Color3.fromRGB(150, 150, 160)
local COLOR_GREEN     = Color3.fromRGB(90, 200, 130)
local COLOR_RED       = Color3.fromRGB(220, 90, 90)

local function corner(parent, radius)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius or 8)
	c.Parent = parent
	return c
end

local function stroke(parent, color, thickness)
	local s = Instance.new("UIStroke")
	s.Color = color or COLOR_BORDER
	s.Thickness = thickness or 1
	s.Parent = parent
	return s
end

-- Main draggable panel
local mainFrame = Instance.new("Frame")
mainFrame.Name = "MainPanel"
mainFrame.Size = UDim2.fromOffset(280, 420)
mainFrame.Position = UDim2.fromOffset(40, 40)
mainFrame.BackgroundColor3 = COLOR_BG
mainFrame.BorderSizePixel = 0
mainFrame.Parent = screenGui
corner(mainFrame, 10)
stroke(mainFrame, COLOR_BORDER, 1)

-- subtle shadow
local shadow = Instance.new("ImageLabel")
shadow.Name = "Shadow"
shadow.BackgroundTransparency = 1
shadow.Image = "rbxassetid://1316045217"
shadow.ImageColor3 = Color3.new(0, 0, 0)
shadow.ImageTransparency = 0.55
shadow.ScaleType = Enum.ScaleType.Slice
shadow.SliceCenter = Rect.new(10, 10, 118, 118)
shadow.Size = UDim2.new(1, 40, 1, 40)
shadow.Position = UDim2.new(0, -20, 0, -20)
shadow.ZIndex = -1
shadow.Parent = mainFrame

-- Title bar
local titleBar = Instance.new("Frame")
titleBar.Name = "TitleBar"
titleBar.Size = UDim2.new(1, 0, 0, 36)
titleBar.BackgroundColor3 = COLOR_BG_ALT
titleBar.BorderSizePixel = 0
titleBar.Parent = mainFrame
corner(titleBar, 10)

-- mask the bottom corners of the title bar so it looks flush
local titleMask = Instance.new("Frame")
titleMask.BackgroundColor3 = COLOR_BG_ALT
titleMask.BorderSizePixel = 0
titleMask.Size = UDim2.new(1, 0, 0, 10)
titleMask.Position = UDim2.new(0, 0, 1, -10)
titleMask.Parent = titleBar

local titleText = Instance.new("TextLabel")
titleText.BackgroundTransparency = 1
titleText.Text = "Part Dot Tracker"
titleText.Font = Enum.Font.GothamBold
titleText.TextSize = 14
titleText.TextColor3 = COLOR_TEXT
titleText.TextXAlignment = Enum.TextXAlignment.Left
titleText.Position = UDim2.fromOffset(12, 0)
titleText.Size = UDim2.new(1, -40, 1, 0)
titleText.Parent = titleBar

local closeBtn = Instance.new("TextButton")
closeBtn.Text = "âœ•"
closeBtn.Font = Enum.Font.GothamBold
closeBtn.TextSize = 14
closeBtn.TextColor3 = COLOR_SUBTEXT
closeBtn.BackgroundTransparency = 1
closeBtn.Size = UDim2.fromOffset(28, 28)
closeBtn.Position = UDim2.new(1, -32, 0, 4)
closeBtn.Parent = titleBar

closeBtn.MouseButton1Click:Connect(function()
	mainFrame.Visible = not mainFrame.Visible
end)

-- Drag logic
do
	local dragging, dragStart, startPos
	titleBar.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			dragStart = input.Position
			startPos = mainFrame.Position
			input.Changed:Connect(function()
				if input.UserInputState == Enum.UserInputState.End then
					dragging = false
				end
			end)
		end
	end)
	UserInputService.InputChanged:Connect(function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			local delta = input.Position - dragStart
			mainFrame.Position = UDim2.fromOffset(startPos.X.Offset + delta.X, startPos.Y.Offset + delta.Y)
		end
	end)
end

-- Content container
local content = Instance.new("Frame")
content.Name = "Content"
content.BackgroundTransparency = 1
content.Size = UDim2.new(1, -20, 1, -48)
content.Position = UDim2.fromOffset(10, 42)
content.Parent = mainFrame

local layout = Instance.new("UIListLayout")
layout.Padding = UDim.new(0, 10)
layout.SortOrder = Enum.SortOrder.LayoutOrder
layout.Parent = content

local function sectionLabel(text, order)
	local lbl = Instance.new("TextLabel")
	lbl.BackgroundTransparency = 1
	lbl.Text = text
	lbl.Font = Enum.Font.GothamBold
	lbl.TextSize = 12
	lbl.TextColor3 = COLOR_SUBTEXT
	lbl.TextXAlignment = Enum.TextXAlignment.Left
	lbl.Size = UDim2.new(1, 0, 0, 16)
	lbl.LayoutOrder = order
	lbl.Parent = content
	return lbl
end

----------------------------------------------------------------
-- Rig type selector (segmented control)
----------------------------------------------------------------

sectionLabel("RIG TYPE", 1)

local rigRow = Instance.new("Frame")
rigRow.BackgroundTransparency = 1
rigRow.Size = UDim2.new(1, 0, 0, 30)
rigRow.LayoutOrder = 2
rigRow.Parent = content

local rigLayout = Instance.new("UIListLayout")
rigLayout.FillDirection = Enum.FillDirection.Horizontal
rigLayout.Padding = UDim.new(0, 8)
rigLayout.Parent = rigRow

local rigButtons = {}

local function styleToggleButton(btn, active)
	if active then
		btn.BackgroundColor3 = COLOR_ACCENT
		btn.TextColor3 = Color3.fromRGB(255, 255, 255)
	else
		btn.BackgroundColor3 = COLOR_BG_ALT
		btn.TextColor3 = COLOR_SUBTEXT
	end
end

local function makeRigButton(name)
	local btn = Instance.new("TextButton")
	btn.Text = name
	btn.Font = Enum.Font.GothamSemibold
	btn.TextSize = 13
	btn.Size = UDim2.new(0.5, -4, 1, 0)
	btn.AutoButtonColor = false
	btn.Parent = rigRow
	corner(btn, 6)
	styleToggleButton(btn, state.rigType == name)
	rigButtons[name] = btn
	return btn
end

local r6Btn = makeRigButton("R6")
local r15Btn = makeRigButton("R15")

----------------------------------------------------------------
-- Part dropdown
----------------------------------------------------------------

sectionLabel("BODY PART", 3)

local dropdownBtn = Instance.new("TextButton")
dropdownBtn.Text = ""
dropdownBtn.AutoButtonColor = false
dropdownBtn.BackgroundColor3 = COLOR_BG_ALT
dropdownBtn.Size = UDim2.new(1, 0, 0, 32)
dropdownBtn.LayoutOrder = 4
dropdownBtn.Parent = content
corner(dropdownBtn, 6)
stroke(dropdownBtn, COLOR_BORDER, 1)

local dropdownLabel = Instance.new("TextLabel")
dropdownLabel.BackgroundTransparency = 1
dropdownLabel.Text = state.partName
dropdownLabel.Font = Enum.Font.Gotham
dropdownLabel.TextSize = 13
dropdownLabel.TextColor3 = COLOR_TEXT
dropdownLabel.TextXAlignment = Enum.TextXAlignment.Left
dropdownLabel.Position = UDim2.fromOffset(10, 0)
dropdownLabel.Size = UDim2.new(1, -30, 1, 0)
dropdownLabel.Parent = dropdownBtn

local dropdownArrow = Instance.new("TextLabel")
dropdownArrow.BackgroundTransparency = 1
dropdownArrow.Text = "â–¾"
dropdownArrow.Font = Enum.Font.Gotham
dropdownArrow.TextSize = 13
dropdownArrow.TextColor3 = COLOR_SUBTEXT
dropdownArrow.Position = UDim2.new(1, -22, 0, 0)
dropdownArrow.Size = UDim2.fromOffset(20, 32)
dropdownArrow.Parent = dropdownBtn

-- The scrolling list itself, shown/hidden as an overlay
local dropdownList = Instance.new("Frame")
dropdownList.Name = "DropdownList"
dropdownList.BackgroundColor3 = COLOR_BG_ALT
dropdownList.BorderSizePixel = 0
dropdownList.Visible = false
dropdownList.ZIndex = 5
dropdownList.Parent = mainFrame
corner(dropdownList, 6)
stroke(dropdownList, COLOR_BORDER, 1)

local dropdownScroll = Instance.new("ScrollingFrame")
dropdownScroll.BackgroundTransparency = 1
dropdownScroll.BorderSizePixel = 0
dropdownScroll.Size = UDim2.new(1, -8, 1, -8)
dropdownScroll.Position = UDim2.fromOffset(4, 4)
dropdownScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
dropdownScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
dropdownScroll.ScrollBarThickness = 4
dropdownScroll.ScrollBarImageColor3 = COLOR_ACCENT
dropdownScroll.ZIndex = 5
dropdownScroll.Parent = dropdownList

local dropdownListLayout = Instance.new("UIListLayout")
dropdownListLayout.SortOrder = Enum.SortOrder.LayoutOrder
dropdownListLayout.Parent = dropdownScroll

local partOptionButtons = {}

local function rebuildPartOptions()
	for _, child in ipairs(dropdownScroll:GetChildren()) do
		if child:IsA("TextButton") then
			child:Destroy()
		end
	end
	table.clear(partOptionButtons)

	local list = state.rigType == "R6" and R6_PARTS or R15_PARTS
	for i, partName in ipairs(list) do
		local optBtn = Instance.new("TextButton")
		optBtn.Text = "  " .. partName
		optBtn.Font = Enum.Font.Gotham
		optBtn.TextSize = 13
		optBtn.TextXAlignment = Enum.TextXAlignment.Left
		optBtn.TextColor3 = COLOR_TEXT
		optBtn.BackgroundColor3 = COLOR_BG_ALT
		optBtn.AutoButtonColor = false
		optBtn.Size = UDim2.new(1, 0, 0, 28)
		optBtn.LayoutOrder = i
		optBtn.ZIndex = 6
		optBtn.Parent = dropdownScroll

		optBtn.MouseEnter:Connect(function()
			optBtn.BackgroundColor3 = COLOR_BORDER
		end)
		optBtn.MouseLeave:Connect(function()
			optBtn.BackgroundColor3 = COLOR_BG_ALT
		end)

		optBtn.MouseButton1Click:Connect(function()
			state.partName = partName
			dropdownLabel.Text = partName
			dropdownList.Visible = false
		end)

		partOptionButtons[partName] = optBtn
	end

	-- if current selection isn't valid for the new rig type, reset to Head
	if not table.find(list, state.partName) then
		state.partName = "Head"
		dropdownLabel.Text = "Head"
	end
end

dropdownBtn.MouseButton1Click:Connect(function()
	dropdownList.Visible = not dropdownList.Visible
	if dropdownList.Visible then
		local absPos = dropdownBtn.AbsolutePosition
		local absSize = dropdownBtn.AbsoluteSize
		local framePos = mainFrame.AbsolutePosition
		dropdownList.Position = UDim2.fromOffset(
			absPos.X - framePos.X,
			absPos.Y - framePos.Y + absSize.Y + 4
		)
		dropdownList.Size = UDim2.new(0, absSize.X, 0, 150)
	end
end)

local function setRigType(rig)
	state.rigType = rig
	styleToggleButton(r6Btn, rig == "R6")
	styleToggleButton(r15Btn, rig == "R15")
	rebuildPartOptions()
end

r6Btn.MouseButton1Click:Connect(function() setRigType("R6") end)
r15Btn.MouseButton1Click:Connect(function() setRigType("R15") end)

rebuildPartOptions()

----------------------------------------------------------------
-- Target selection: All players / specific name
----------------------------------------------------------------

sectionLabel("TARGET", 5)

local targetRow = Instance.new("Frame")
targetRow.BackgroundTransparency = 1
targetRow.Size = UDim2.new(1, 0, 0, 30)
targetRow.LayoutOrder = 6
targetRow.Parent = content

local targetLayout = Instance.new("UIListLayout")
targetLayout.FillDirection = Enum.FillDirection.Horizontal
targetLayout.Padding = UDim.new(0, 8)
targetLayout.Parent = targetRow

local allBtn = Instance.new("TextButton")
allBtn.Text = "All Players"
allBtn.Font = Enum.Font.GothamSemibold
allBtn.TextSize = 13
allBtn.AutoButtonColor = false
allBtn.Size = UDim2.new(0.5, -4, 1, 0)
allBtn.Parent = targetRow
corner(allBtn, 6)

local specificBtn = Instance.new("TextButton")
specificBtn.Text = "Specific"
specificBtn.Font = Enum.Font.GothamSemibold
specificBtn.TextSize = 13
specificBtn.AutoButtonColor = false
specificBtn.Size = UDim2.new(0.5, -4, 1, 0)
specificBtn.Parent = targetRow
corner(specificBtn, 6)

local nameBox = Instance.new("TextBox")
nameBox.PlaceholderText = "Exact username..."
nameBox.Text = ""
nameBox.Font = Enum.Font.Gotham
nameBox.TextSize = 13
nameBox.TextColor3 = COLOR_TEXT
nameBox.PlaceholderColor3 = COLOR_SUBTEXT
nameBox.BackgroundColor3 = COLOR_BG_ALT
nameBox.Size = UDim2.new(1, 0, 0, 30)
nameBox.LayoutOrder = 7
nameBox.ClearTextOnFocus = false
nameBox.Visible = false
nameBox.Parent = content
corner(nameBox, 6)
stroke(nameBox, COLOR_BORDER, 1)

local nameBoxPad = Instance.new("UIPadding")
nameBoxPad.PaddingLeft = UDim.new(0, 8)
nameBoxPad.Parent = nameBox

nameBox:GetPropertyChangedSignal("Text"):Connect(function()
	state.targetName = nameBox.Text
end)

local function setTargetMode(all)
	state.trackAll = all
	styleToggleButton(allBtn, all)
	styleToggleButton(specificBtn, not all)
	nameBox.Visible = not all
end

allBtn.MouseButton1Click:Connect(function() setTargetMode(true) end)
specificBtn.MouseButton1Click:Connect(function() setTargetMode(false) end)
setTargetMode(true)

----------------------------------------------------------------
-- Prediction checkbox
----------------------------------------------------------------

sectionLabel("OPTIONS", 8)

local predictRow = Instance.new("TextButton")
predictRow.Text = ""
predictRow.AutoButtonColor = false
predictRow.BackgroundTransparency = 1
predictRow.Size = UDim2.new(1, 0, 0, 26)
predictRow.LayoutOrder = 9
predictRow.Parent = content

local checkbox = Instance.new("Frame")
checkbox.Size = UDim2.fromOffset(18, 18)
checkbox.Position = UDim2.fromOffset(0, 4)
checkbox.BackgroundColor3 = COLOR_BG_ALT
checkbox.Parent = predictRow
corner(checkbox, 4)
stroke(checkbox, COLOR_BORDER, 1)

local checkmark = Instance.new("TextLabel")
checkmark.BackgroundTransparency = 1
checkmark.Text = "âœ“"
checkmark.Font = Enum.Font.GothamBold
checkmark.TextSize = 14
checkmark.TextColor3 = COLOR_ACCENT
checkmark.Size = UDim2.fromScale(1, 1)
checkmark.Visible = false
checkmark.Parent = checkbox

local predictLabel = Instance.new("TextLabel")
predictLabel.BackgroundTransparency = 1
predictLabel.Text = "Movement Prediction"
predictLabel.Font = Enum.Font.Gotham
predictLabel.TextSize = 13
predictLabel.TextColor3 = COLOR_TEXT
predictLabel.TextXAlignment = Enum.TextXAlignment.Left
predictLabel.Position = UDim2.fromOffset(26, 0)
predictLabel.Size = UDim2.new(1, -26, 1, 0)
predictLabel.Parent = predictRow

predictRow.MouseButton1Click:Connect(function()
	state.prediction = not state.prediction
	checkmark.Visible = state.prediction
	checkbox.BackgroundColor3 = state.prediction and COLOR_ACCENT_D or COLOR_BG_ALT
end)

----------------------------------------------------------------
-- Start / Stop buttons + status
----------------------------------------------------------------

local statusLabel = Instance.new("TextLabel")
statusLabel.BackgroundTransparency = 1
statusLabel.Text = "Status: Stopped"
statusLabel.Font = Enum.Font.GothamSemibold
statusLabel.TextSize = 12
statusLabel.TextColor3 = COLOR_RED
statusLabel.TextXAlignment = Enum.TextXAlignment.Left
statusLabel.Size = UDim2.new(1, 0, 0, 16)
statusLabel.LayoutOrder = 10
statusLabel.Parent = content

local buttonRow = Instance.new("Frame")
buttonRow.BackgroundTransparency = 1
buttonRow.Size = UDim2.new(1, 0, 0, 36)
buttonRow.LayoutOrder = 11
buttonRow.Parent = content

local buttonLayout = Instance.new("UIListLayout")
buttonLayout.FillDirection = Enum.FillDirection.Horizontal
buttonLayout.Padding = UDim.new(0, 8)
buttonLayout.Parent = buttonRow

local startBtn = Instance.new("TextButton")
startBtn.Text = "Start"
startBtn.Font = Enum.Font.GothamBold
startBtn.TextSize = 14
startBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
startBtn.BackgroundColor3 = COLOR_GREEN
startBtn.AutoButtonColor = false
startBtn.Size = UDim2.new(0.5, -4, 1, 0)
startBtn.Parent = buttonRow
corner(startBtn, 6)

local stopBtn = Instance.new("TextButton")
stopBtn.Text = "Stop"
stopBtn.Font = Enum.Font.GothamBold
stopBtn.TextSize = 14
stopBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
stopBtn.BackgroundColor3 = COLOR_RED
stopBtn.AutoButtonColor = false
stopBtn.Size = UDim2.new(0.5, -4, 1, 0)
stopBtn.Parent = buttonRow
corner(stopBtn, 6)

----------------------------------------------------------------
-- DOT MANAGEMENT
----------------------------------------------------------------

local function createDot()
	local dot = Instance.new("Frame")
	dot.Name = "Dot"
	dot.Size = UDim2.fromOffset(10, 10)
	dot.AnchorPoint = Vector2.new(0.5, 0.5)
	dot.BackgroundColor3 = COLOR_ACCENT
	dot.BorderSizePixel = 0
	dot.Visible = false
	corner(dot, 5)
	stroke(dot, Color3.fromRGB(255, 255, 255), 1.5)
	dot.Parent = dotsGui
	return dot
end

local function getTargetPart(character, rigType, partName)
	if not character then return nil end
	-- direct match first
	local part = character:FindFirstChild(partName)
	if part and part:IsA("BasePart") then
		return part
	end
	return nil
end

local function clearAllDots()
	for plr, frame in pairs(activeDots) do
		frame:Destroy()
	end
	table.clear(activeDots)
	table.clear(velocityCache)
end

local function getDotForPlayer(plr)
	if not activeDots[plr] then
		activeDots[plr] = createDot()
	end
	return activeDots[plr]
end

local function updateVelocity(plr, part, dt)
	local cache = velocityCache[plr]
	local currentPos = part.Position

	if not cache then
		velocityCache[plr] = { lastPos = currentPos, vel = Vector3.new(0, 0, 0) }
		return Vector3.new(0, 0, 0)
	end

	if dt > 0 then
		local rawVel = (currentPos - cache.lastPos) / dt
		-- smooth the velocity a bit so the dot doesn't jitter
		cache.vel = cache.vel:Lerp(rawVel, 0.5)
	end
	cache.lastPos = currentPos
	return cache.vel
end

local function stepDots(dt)
	for _, plr in ipairs(Players:GetPlayers()) do
		if plr == LocalPlayer and false then
			-- (kept for clarity: LocalPlayer is included by default)
		end

		local shouldTrack = state.trackAll or (state.targetName ~= "" and plr.Name:lower() == state.targetName:lower())
		if not shouldTrack then
			if activeDots[plr] then
				activeDots[plr].Visible = false
			end
			continue
		end

		local character = plr.Character
		local part = character and getTargetPart(character, state.rigType, state.partName)

		if not part then
			if activeDots[plr] then
				activeDots[plr].Visible = false
			end
			continue
		end

		local worldPos = part.Position

		if state.prediction then
			local vel = updateVelocity(plr, part, dt)
			-- Predict position after predictionTime seconds, then damp it
			-- (a stopped/decelerating player should have the dot settle
			-- back onto them rather than overshoot indefinitely).
			worldPos = worldPos + vel * state.predictionTime
		end

		local screenPos, onScreen = Camera:WorldToViewportPoint(worldPos)

		local dot = getDotForPlayer(plr)
		if onScreen and screenPos.Z > 0 then
			dot.Visible = true
			dot.Position = UDim2.fromOffset(screenPos.X, screenPos.Y)
		else
			dot.Visible = false
		end
	end

	-- clean up dots for players who left or are no longer tracked at all
	for plr, frame in pairs(activeDots) do
		if not plr.Parent then
			frame:Destroy()
			activeDots[plr] = nil
			velocityCache[plr] = nil
		end
	end
end

local function startTracking()
	if state.running then return end
	state.running = true
	statusLabel.Text = "Status: Running"
	statusLabel.TextColor3 = COLOR_GREEN

	heartbeatConn = RunService.Heartbeat:Connect(function(dt)
		stepDots(dt)
	end)
end

local function stopTracking()
	if not state.running then return end
	state.running = false
	statusLabel.Text = "Status: Stopped"
	statusLabel.TextColor3 = COLOR_RED

	if heartbeatConn then
		heartbeatConn:Disconnect()
		heartbeatConn = nil
	end
	clearAllDots()
end

startBtn.MouseButton1Click:Connect(startTracking)
stopBtn.MouseButton1Click:Connect(stopTracking)

-- Clean up if the script/gui gets destroyed
screenGui.Destroying:Connect(function()
	stopTracking()
	if dotsGui then dotsGui:Destroy() end
end)
