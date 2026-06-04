-- HCBB Auto-Aim & Auto-Hit
-- Based on decompiled game scripts (PlaceId 7830150255)
-- Finds ball trajectory from GC, predicts position, aims & swings

local set = {
  AutoAim = true,
  AutoHit = true,
  BallESP = true,
  ShowPrediction = true,
  WindupDist = 67,
  HitDist = 14,
  OnlyHitInBox = false,
}

local plr = game:GetService("Players").LocalPlayer
local camera = workspace.CurrentCamera
local RS = game:GetService("RunService")
local UIS = game:GetService("UserInputService")

-- Find the ball trajectory table from GC
local ballTable = nil
for _, v in next, getgc(true) do
  if type(v) == "table" and rawget(v, "GetPos") then
    ballTable = v
    break
  end
end

if not ballTable then
  warn("HCBB: Ball trajectory table not found in GC")
end

-- State
local theBall = nil
local currentPath = {}
local predictedPos = Vector3.new()
local hasWinded = false
local hasSwung = false
local lastBallTime = 0

-- ESP Drawings
local ballCircle = Drawing.new("Circle")
ballCircle.Thickness = 2
ballCircle.Radius = 10
ballCircle.Color = Color3.fromRGB(0, 255, 0)
ballCircle.Visible = false

local predCircle = Drawing.new("Circle")
predCircle.Thickness = 2
predCircle.Radius = 30
predCircle.Color = Color3.fromRGB(255, 0, 0)
predCircle.Visible = false

local predFill = Drawing.new("Circle")
predFill.Thickness = 2
predFill.Radius = 28
predFill.Filled = true
predFill.Transparency = 0.5
predFill.Color = Color3.fromRGB(255, 0, 0)
predFill.Visible = false

-- Hook ball clone to track the ball object
local oldNamecall
oldNamecall = hookmetamethod(game, "__namecall", function(self, ...)
  local method = getnamecallmethod()
  if not checkcaller() and method == "Clone" and self and self.Parent and self.Parent.Name == "Ball" then
    if tick() > lastBallTime + 2 then
      lastBallTime = tick()
      theBall = self.Parent
    end
  end
  return oldNamecall(self, ...)
end)

-- Intercept SEVREPBALLTHROW to get path table
local pathConnection = game.ReplicatedStorage.RESC.SEVREPBALLTHROW.OnClientEvent:Connect(function(_, pathData)
  currentPath = pathData or {}
end)

-- Hook SetPitchtab to get trajectory data and find optimal hit point
if ballTable then
  local oldSetPitchtab = ballTable.SetPitchtab
  ballTable["SetPitchtab"] = function(self, thingy)
    task.spawn(function()
      task.wait(0.1)
      local borderBox = workspace.Ignore and workspace.Ignore:FindFirstChild("BGUI") and workspace.Ignore.BGUI:FindFirstChild("BlackBoarder")
      if not borderBox then return end

      local closest = math.huge
      local bestPos = Vector3.new()

      for t = 0, 1, 0.01 do
        local ok, posData = pcall(function()
          return ballTable:GetPos(t, currentPath, false, nil, thingy)
        end)
        if ok and posData and posData.p and posData.p ~= Vector3.new(0, 0, 0) then
          local mag = (posData.p - borderBox.Position).Magnitude
          if mag < closest then
            closest = mag
            bestPos = posData.p
          end
        end
      end

      if bestPos ~= Vector3.new() then
        predictedPos = bestPos
        local screenPos, onScreen = camera:WorldToViewportPoint(bestPos)
        if onScreen then
          predCircle.Position = Vector2.new(screenPos.X, screenPos.Y)
          predFill.Position = Vector2.new(screenPos.X, screenPos.Y)
          predCircle.Visible = set.ShowPrediction
          predFill.Visible = set.ShowPrediction
        end
      end
    end)
    return oldSetPitchtab(self, thingy)
  end
end

-- Find the special offset table from gc
local specialTable = nil
for _, v in next, getgc(true) do
  if type(v) == "table" and rawget(v, "CENT_VECTOR2_1") then
    specialTable = v
    break
  end
end

-- Hook Mouse.X/Y for auto-aim
local mouse = plr:GetMouse()
local oldMouseIndex
oldMouseIndex = hookmetamethod(mouse, "__index", function(self, idx)
  if not checkcaller() and theBall and theBall.Parent then
    if idx == "X" and set.AutoAim then
      local bPos = camera:WorldToScreenPoint(theBall.Position)
      local offset = specialTable and rawget(specialTable, "CENT_VECTOR2_1")
      if offset then
        return bPos.X - offset.X
      end
    end
    if idx == "Y" and set.AutoAim then
      local bPos = camera:WorldToScreenPoint(theBall.Position)
      local offset = specialTable and rawget(specialTable, "CENT_VECTOR2_1")
      if offset then
        return bPos.Y - offset.Y
      end
    end
  end
  return oldMouseIndex(self, idx)
end)

-- Track cursor parts
local cursorPart = nil

local function watchPart(part)
  if part.ClassName == "Part" and part.Name ~= "Shad" and part.Name ~= "Self" and part.Name ~= "HitTracker" then
    part:GetPropertyChangedSignal("CFrame"):Connect(function()
      cursorPart = part
    end)
  end
end

if workspace.Ignore then
  for _, v in next, workspace.Ignore:GetChildren() do
    watchPart(v)
  end
  workspace.Ignore.ChildAdded:Connect(watchPart)
end

-- Heartbeat loop
RS.Heartbeat:Connect(function()
  -- ESP
  if theBall and theBall.Parent then
    ballCircle.Visible = set.BallESP
    local pos, onScreen = camera:WorldToViewportPoint(theBall.Position)
    if onScreen then
      ballCircle.Position = Vector2.new(pos.X, pos.Y)
    end
  else
    ballCircle.Visible = false
  end

  -- Auto-aim and auto-hit logic
  if not theBall or not theBall.Parent then
    predCircle.Visible = false
    predFill.Visible = false
    return
  end

  local targetPos = predictedPos ~= Vector3.new() and predictedPos or theBall.Position

  -- Calculate aim position
  local ballScreen = camera:WorldToScreenPoint(targetPos + Vector3.new(0, -theBall.Size.Y / 2, 0))

  -- Auto-aim: move mouse to ball position
  if set.AutoAim then
    local aimX = ballScreen.X
    local aimY = ballScreen.Y

    if cursorPart then
      local cursorScreen = camera:WorldToScreenPoint(cursorPart.Position + Vector3.new(0, cursorPart.Size.Y / 2, 0))
      local mousePos = camera:WorldToScreenPoint(mouse.Hit.p)
      local diff = Vector2.new(mousePos.X - cursorScreen.X, mousePos.Y - cursorScreen.Y)
      aimX = ballScreen.X + diff.X
      aimY = ballScreen.Y + diff.Y
    end

    mousemoveabs(aimX, aimY)
  end

  -- Auto-hit logic
  if set.AutoHit then
    local swingTarget = workspace.Plates and workspace.Plates:FindFirstChild("SwingTarget")
    if not swingTarget then return end

    local hitPos = targetPos
    local ballMag = (theBall.Position - swingTarget.Position).Magnitude

    -- Windup swing at distance
    if ballMag <= set.WindupDist and not hasWinded then
      hasWinded = true
      mouse1click()
    end

    -- Check strike zone and swing
    if hasWinded and not hasSwung then
      local borderBox = workspace.Ignore and workspace.Ignore:FindFirstChild("BGUI") and workspace.Ignore.BGUI:FindFirstChild("BlackBoarder")
      local shouldSwing = true

      if set.OnlyHitInBox and borderBox then
        local bbPos = borderBox.Position
        local bbSize = borderBox.Size
        local ballView = camera:WorldToScreenPoint(targetPos)
        local corners = {
          TL = camera:WorldToScreenPoint(bbPos + Vector3.new(0, bbSize.Y / 2 + 0.45, bbSize.X / 2 + 0.45)),
          TR = camera:WorldToScreenPoint(bbPos + Vector3.new(0, bbSize.Y / 2 + 0.45, -bbSize.X / 2 - 0.45)),
          BR = camera:WorldToScreenPoint(bbPos + Vector3.new(0, -bbSize.Y / 2 - 0.45, -bbSize.X / 2 - 0.45)),
          BL = camera:WorldToScreenPoint(bbPos + Vector3.new(0, -bbSize.Y / 2 - 0.45, bbSize.X / 2 + 0.45)),
        }
        if not (ballView.X >= corners.TL.X and ballView.X <= corners.TR.X and ballView.Y >= corners.TR.Y and ballView.Y <= corners.BR.Y) then
          shouldSwing = false
        end
      end

      if shouldSwing and ballMag <= set.HitDist then
        mouse1click()
      end

      hasSwung = true
      delay(2, function()
        hasSwung = false
        hasWinded = false
        theBall = nil
      end)
    end
  end
end)

-- Cleanup
plr.OnTeleport:Connect(function()
  if pathConnection then pathConnection:Disconnect() end
  ballCircle:Remove()
  predCircle:Remove()
  predFill:Remove()
end)

warn("HCBB: Auto-Aim & Auto-Hit loaded")
