--[[
  Universal Dumper v2 — Mobile Optimized
  Combines: Better Script Dumper, Pro Script Dumper, Function Dumper
  Features: Script dumping with hierarchy, function decompilation, mobile UI
]]

warn("UD: Starting load...")
pcall(function() writefile("_UD_STARTED.txt", "UD script started executing at " .. tick()) end)

-- Settings
local Settings = {
  decompile = true,
  dump_debug = false,
  detailed_info = false,
  threads = 3,
  timeout = 5,
  delay = 0.05,
  include_nil = false,
  replace_username = true,
  disable_render = true,
  ignore_empty = true,
  func_return_values = true,
  func_max_table_size = 3,
  func_decode_bytes = true,
}

local decompile = decompile or disassemble
local getnilinstances = getnilinstances or get_nil_instances
local getscripthash = getscripthash or get_script_hash
local getscriptclosure = getscriptclosure
local getconstants = getconstants or debug.getconstants
local getprotos = getprotos or debug.getprotos
local getinfo = getinfo or debug.getinfo
local format = string.format
local concat = table.concat

-- State
local threads = 0
local scriptsdumped = 0
local timedoutscripts = {}
local decompilecache = {}
local progressbind = Instance.new("BindableEvent")
local threadbind = Instance.new("BindableEvent")
local active = false
local plr = game:GetService("Players").LocalPlayer

local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local HttpService = game:GetService("HttpService")

-- Detect mobile
local isMobile = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
local hasFS = pcall(function()
  writefile("_ud_test_.txt", "ok")
  local r = readfile("_ud_test_.txt")
  writefile("_ud_test_.txt", "")
  return r == "ok"
end)
if hasFS then
  pcall(function() writefile("_UD_LOADED.txt", "Universal Dumper loaded at " .. tick()) end)
  warn("UD: hasFS = true, writefile works")
else
  warn("UD: hasFS = false, using clipboard fallback")
end

-- UI Constants
local colors = {
  bg = Color3.fromRGB(18, 18, 22),
  surface = Color3.fromRGB(26, 26, 33),
  surface2 = Color3.fromRGB(34, 34, 42),
  accent = Color3.fromRGB(88, 101, 242),
  accent2 = Color3.fromRGB(120, 130, 255),
  text = Color3.fromRGB(220, 220, 230),
  textDim = Color3.fromRGB(140, 140, 155),
  danger = Color3.fromRGB(237, 66, 69),
  success = Color3.fromRGB(87, 200, 120),
  warn = Color3.fromRGB(250, 180, 60),
}

local function makeDraggable(frame)
  local dragging, dragStart, startPos
  frame.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1 then
      dragging = true
      dragStart = input.Position
      startPos = frame.Position
      input.Changed:Connect(function()
        if input.UserInputState == Enum.UserInputState.End then dragging = false end
      end)
    end
  end)
  frame.InputChanged:Connect(function(input)
    if dragging and (input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseMovement) then
      local delta = input.Position - dragStart
      frame.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
    end
  end)
end

local function createUI()
  local screenGui = Instance.new("ScreenGui")
  screenGui.Name = "UniversalDumper"
  screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
  screenGui.ResetOnSpawn = false
  pcall(function()
    if syn and syn.protect_gui then syn.protect_gui(screenGui) end
  end)
  screenGui.Parent = plr:WaitForChild("PlayerGui")

  local main = Instance.new("Frame")
  main.Size = UDim2.fromOffset(360, 520)
  main.Position = UDim2.fromOffset(20, 60)
  main.BackgroundColor3 = colors.bg
  main.BorderSizePixel = 0
  main.BackgroundTransparency = 0.05
  main.ClipsDescendants = true
  main.Parent = screenGui
  makeDraggable(main)

  local corner = Instance.new("UICorner", main)
  corner.CornerRadius = UDim.new(0, 12)

  local stroke = Instance.new("UIStroke", main)
  stroke.Thickness = 1
  stroke.Color = Color3.fromRGB(40, 40, 50)

  -- Shadow
  local shadow = Instance.new("ImageLabel")
  shadow.Size = UDim2.fromScale(1, 1)
  shadow.Position = UDim2.fromOffset(8, 8)
  shadow.BackgroundTransparency = 1
  shadow.Image = "rbxassetid://6014261993"
  shadow.ImageColor3 = Color3.fromRGB(0, 0, 0)
  shadow.ImageTransparency = 0.6
  shadow.ScaleType = Enum.ScaleType.Slice
  shadow.SliceCenter = Rect.new(49, 49, 50, 50)
  shadow.ZIndex = -1
  shadow.Parent = main

  -- Header
  local header = Instance.new("Frame")
  header.Size = UDim2.fromScale(1, 0.1)
  header.BackgroundColor3 = colors.accent
  header.BorderSizePixel = 0
  header.Parent = main

  local headerCorner = Instance.new("UICorner", header)
  headerCorner.CornerRadius = UDim.new(0, 12)

  local headerFill = Instance.new("Frame")
  headerFill.Size = UDim2.fromScale(1, 0.5)
  headerFill.Position = UDim2.fromScale(0, 0.5)
  headerFill.BackgroundColor3 = colors.accent
  headerFill.BorderSizePixel = 0
  headerFill.Parent = header

  local title = Instance.new("TextLabel")
  title.Size = UDim2.fromScale(1, 1)
  title.BackgroundTransparency = 1
  title.Text = "Universal Dumper"
  title.TextColor3 = colors.text
  title.Font = Enum.Font.GothamBold
  title.TextSize = isMobile and 16 or 18
  title.Parent = header

  local closeBtn = Instance.new("TextButton")
  closeBtn.Size = UDim2.fromOffset(30, 30)
  closeBtn.Position = UDim2.fromScale(1, 0)
  closeBtn.AnchorPoint = Vector2.new(1, 0)
  closeBtn.BackgroundTransparency = 1
  closeBtn.Text = "X"
  closeBtn.TextColor3 = colors.text
  closeBtn.TextSize = 16
  closeBtn.Font = Enum.Font.GothamBold
  closeBtn.Parent = header
  closeBtn.MouseButton1Click:Connect(function() screenGui:Destroy() end)

  -- Tab buttons
  local tabBar = Instance.new("Frame")
  tabBar.Size = UDim2.fromScale(1, 0.07)
  tabBar.Position = UDim2.fromScale(0, 0.1)
  tabBar.BackgroundColor3 = colors.surface
  tabBar.BorderSizePixel = 0
  tabBar.Parent = main

  local tabLayout = Instance.new("UIListLayout", tabBar)
  tabLayout.FillDirection = Enum.FillDirection.Horizontal
  tabLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
  tabLayout.VerticalAlignment = Enum.VerticalAlignment.Center
  tabLayout.Padding = UDim.new(0, 4)

  local tabs = {"Dumper", "Function", "Output"}
  local tabFrames = {}
  local tabBtns = {}

  local contentArea = Instance.new("Frame")
  contentArea.Size = UDim2.fromScale(1, 0.83)
  contentArea.Position = UDim2.fromScale(0, 0.17)
  contentArea.BackgroundColor3 = colors.bg
  contentArea.BorderSizePixel = 0
  contentArea.Parent = main

  local scrollPrototype = Instance.new("ScrollingFrame")
  scrollPrototype.Size = UDim2.fromScale(1, 1)
  scrollPrototype.BackgroundTransparency = 1
  scrollPrototype.ScrollBarThickness = isMobile and 3 or 6
  scrollPrototype.ScrollBarImageColor3 = colors.accent
  scrollPrototype.CanvasSize = UDim2.fromScale(0, 0)
  scrollPrototype.AutomaticCanvasSize = Enum.AutomaticSize.Y

  -- Helper
  local function makeBtn(text, cb)
    local b = Instance.new("TextButton")
    b.Size = UDim2.fromScale(1, 0)
    b.BackgroundColor3 = colors.accent
    b.TextColor3 = colors.text
    b.Font = Enum.Font.GothamSemibold
    b.TextSize = 14
    b.Text = text
    b.AutomaticSize = Enum.AutomaticSize.Y
    b.BorderSizePixel = 0
    local c = Instance.new("UICorner", b)
    c.CornerRadius = UDim.new(0, 8)
    b.MouseButton1Click:Connect(cb)
    return b
  end

  local function makeToggle(text, def, cb)
    local frame = Instance.new("Frame")
    frame.Size = UDim2.fromScale(1, 0)
    frame.BackgroundTransparency = 1
    frame.AutomaticSize = Enum.AutomaticSize.Y

    local label = Instance.new("TextLabel")
    label.Size = UDim2.fromScale(0.75, 1)
    label.BackgroundTransparency = 1
    label.Text = text
    label.TextColor3 = colors.text
    label.Font = Enum.Font.Gotham
    label.TextSize = 14
    label.TextXAlignment = Enum.TextXAlignment.Left
    label.AutomaticSize = Enum.AutomaticSize.Y
    label.Parent = frame

    local tog = Instance.new("TextButton")
    tog.Size = UDim2.fromOffset(44, 24)
    tog.Position = UDim2.fromScale(1, 0)
    tog.AnchorPoint = Vector2.new(1, 0)
    tog.BackgroundColor3 = def and colors.accent or colors.surface2
    tog.BorderSizePixel = 0
    tog.Text = ""
    tog.Parent = frame
    local togCorner = Instance.new("UICorner", tog)
    togCorner.CornerRadius = UDim.new(0, 12)

    local togCircle = Instance.new("Frame")
    togCircle.Size = UDim2.fromOffset(18, 18)
    togCircle.Position = UDim2.fromOffset(def and 23 or 3, 3)
    togCircle.BackgroundColor3 = colors.text
    togCircle.BorderSizePixel = 0
    togCircle.Parent = tog
    local cirCorner = Instance.new("UICorner", togCircle)
    cirCorner.CornerRadius = UDim.new(0, 9)

    local state = def
    tog.MouseButton1Click:Connect(function()
      state = not state
      tog.BackgroundColor3 = state and colors.accent or colors.surface2
      togCircle:TweenPosition(UDim2.fromOffset(state and 23 or 3, 3), "Out", "Sine", 0.15, true)
      cb(state)
    end)

    return frame
  end

  local function makeSlider(text, min, max, def, suffix, cb)
    local frame = Instance.new("Frame")
    frame.Size = UDim2.fromScale(1, 0)
    frame.BackgroundTransparency = 1
    frame.AutomaticSize = Enum.AutomaticSize.Y

    local label = Instance.new("TextLabel")
    label.Size = UDim2.fromScale(1, 0)
    label.BackgroundTransparency = 1
    label.Text = text .. ": " .. def .. (suffix or "")
    label.TextColor3 = colors.text
    label.Font = Enum.Font.Gotham
    label.TextSize = 13
    label.TextXAlignment = Enum.TextXAlignment.Left
    label.AutomaticSize = Enum.AutomaticSize.Y
    label.Parent = frame

    local sliderBg = Instance.new("Frame")
    sliderBg.Size = UDim2.fromScale(1, 6)
    sliderBg.Position = UDim2.fromOffset(0, 4)
    sliderBg.BackgroundColor3 = colors.surface2
    sliderBg.BorderSizePixel = 0
    sliderBg.Parent = frame
    local sCorner = Instance.new("UICorner", sliderBg)
    sCorner.CornerRadius = UDim.new(0, 3)

    local sliderFill = Instance.new("Frame")
    sliderFill.Size = UDim2.fromScale((def - min) / (max - min), 1)
    sliderFill.BackgroundColor3 = colors.accent
    sliderFill.BorderSizePixel = 0
    sliderFill.Parent = sliderBg
    local fillCorner = Instance.new("UICorner", sliderFill)
    fillCorner.CornerRadius = UDim.new(0, 3)

    local val = def
    sliderBg.InputBegan:Connect(function(input)
      if input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1 then
        local conn
        conn = UserInputService.InputChanged:Connect(function(i)
          if i.UserInputType == Enum.UserInputType.Touch or i.UserInputType == Enum.UserInputType.MouseMovement then
            local pos = UserInputService:GetMouseLocation()
            local absPos = sliderBg.AbsolutePosition
            local absSize = sliderBg.AbsoluteSize.X
            local pct = math.clamp((pos.X - absPos.X) / absSize, 0, 1)
            val = math.floor(min + (max - min) * pct + 0.5)
            sliderFill.Size = UDim2.fromScale(pct, 1)
            label.Text = text .. ": " .. val .. (suffix or "")
            cb(val)
          end
        end)
        input.Changed:Connect(function()
          if input.UserInputState == Enum.UserInputState.End then
            if conn then conn:Disconnect() end
          end
        end)
      end
    end)

    return frame
  end

  local function makeLabel(text)
    local l = Instance.new("TextLabel")
    l.Size = UDim2.fromScale(1, 0)
    l.BackgroundTransparency = 1
    l.Text = text
    l.TextColor3 = colors.textDim
    l.Font = Enum.Font.Gotham
    l.TextSize = 12
    l.TextXAlignment = Enum.TextXAlignment.Left
    l.AutomaticSize = Enum.AutomaticSize.Y
    l.TextWrapped = true
    return l
  end

  local function makeTextbox(placeholder, multi)
    local frame = Instance.new("Frame")
    frame.Size = UDim2.fromScale(1, 0)
    frame.BackgroundColor3 = colors.surface2
    frame.BorderSizePixel = 0
    frame.AutomaticSize = Enum.AutomaticSize.Y
    local c = Instance.new("UICorner", frame)
    c.CornerRadius = UDim.new(0, 8)

    local box
    if multi then
      box = Instance.new("TextBox")
      box.Size = UDim2.fromScale(1, 80)
      box.BackgroundTransparency = 1
      box.PlaceholderText = placeholder
      box.Text = ""
      box.TextColor3 = colors.text
      box.Font = Enum.Font.Code
      box.TextSize = 12
      box.TextXAlignment = Enum.TextXAlignment.Left
      box.TextYAlignment = Enum.TextYAlignment.Top
      box.ClearTextOnFocus = false
      box.MultiLine = true
    else
      box = Instance.new("TextBox")
      box.Size = UDim2.fromScale(1, 32)
      box.BackgroundTransparency = 1
      box.PlaceholderText = placeholder
      box.Text = ""
      box.TextColor3 = colors.text
      box.Font = Enum.Font.Gotham
      box.TextSize = 14
      box.ClearTextOnFocus = false
    end
    box.Parent = frame

    return frame, box
  end

  -- Build Tabs
  local padding = 8
  local function addContent(tabName, buildFn)
    local scroll = scrollPrototype:Clone()
    scroll.Parent = contentArea
    scroll.Visible = false
    tabFrames[tabName] = scroll

    local list = Instance.new("UIListLayout", scroll)
    list.Padding = UDim.new(0, 6)
    local pad = Instance.new("UIPadding", scroll)
    pad.PaddingLeft = UDim.new(0, padding)
    pad.PaddingRight = UDim.new(0, padding)
    pad.PaddingTop = UDim.new(0, padding)
    pad.PaddingBottom = UDim.new(0, padding)

    buildFn(scroll, list)
  end

  -- Tab: Dumper
  addContent("Dumper", function(scroll)
    makeToggle("Decompile Scripts", Settings.decompile, function(v) Settings.decompile = v end):Parent = scroll
    makeToggle("Dump Debug Info", Settings.dump_debug, function(v) Settings.dump_debug = v end):Parent = scroll
    makeToggle("Detailed Info", Settings.detailed_info, function(v) Settings.detailed_info = v end):Parent = scroll
    makeSlider("Max Threads", 1, 10, Settings.threads, " threads", function(v) Settings.threads = v end):Parent = scroll
    makeSlider("Delay", 0, 1, Settings.delay, "s", function(v) Settings.delay = v end):Parent = scroll
    makeSlider("Timeout", 1, 30, Settings.timeout, "s", function(v) Settings.timeout = v end):Parent = scroll
    makeToggle("Include Nil Scripts", Settings.include_nil, function(v) Settings.include_nil = v end):Parent = scroll
    makeToggle("Replace Username", Settings.replace_username, function(v) Settings.replace_username = v end):Parent = scroll
    makeToggle("Disable 3D Rendering", Settings.disable_render, function(v) Settings.disable_render = v end):Parent = scroll
    makeToggle("Ignore Empty Scripts", Settings.ignore_empty, function(v) Settings.ignore_empty = v end):Parent = scroll

    local spacer = Instance.new("Frame")
    spacer.Size = UDim2.fromScale(1, 0)
    spacer.BackgroundTransparency = 1
    spacer.AutomaticSize = Enum.AutomaticSize.Y
    spacer.Parent = scroll

    local status = Instance.new("TextLabel")
    status.Size = UDim2.fromScale(1, 0)
    status.BackgroundTransparency = 1
    status.Text = "Ready"
    status.TextColor3 = colors.textDim
    status.Font = Enum.Font.Gotham
    status.TextSize = 12
    status.TextXAlignment = Enum.TextXAlignment.Left
    status.AutomaticSize = Enum.AutomaticSize.Y
    status.Parent = scroll

    local progress = Instance.new("Frame")
    progress.Size = UDim2.fromScale(1, 4)
    progress.BackgroundColor3 = colors.surface2
    progress.BorderSizePixel = 0
    progress.Parent = scroll
    local pCorner = Instance.new("UICorner", progress)
    pCorner.CornerRadius = UDim.new(0, 2)

    local progressFill = Instance.new("Frame")
    progressFill.Size = UDim2.fromScale(0, 1)
    progressFill.BackgroundColor3 = colors.accent
    progressFill.BorderSizePixel = 0
    progressFill.Parent = progress
    local pfCorner = Instance.new("UICorner", progressFill)
    pfCorner.CornerRadius = UDim.new(0, 2)

    local saveLoc = makeLabel(hasFS and "Saving to: Delta/Workspace/UD_*.lua" or "No writefile — using clipboard")
    saveLoc.TextColor3 = hasFS and colors.success or colors.warn
    saveLoc.Parent = scroll

    local startBtn = makeBtn("Start Dumping", function()
      if active then
        status.Text = "Already running!"
        return
      end
      active = true
      startBtn.Text = "Running..."
      startBtn.BackgroundColor3 = colors.surface2
      status.Text = "Scanning scripts..."
      progressFill.Size = UDim2.fromScale(0, 1)

      local totalScripts = 0
      local dumped = 0
      local timeouts = {}
      local scriptList = {}
      local nilList = {}

      -- Gather
      for _,v in next, game:GetDescendants() do
        if (v:IsA("LocalScript") or v:IsA("ModuleScript")) then
          local ignored = false
          if v:FindFirstAncestor("CoreGui") or v:FindFirstAncestor("CorePackages") or v:FindFirstAncestor("Chat") then
            ignored = true
          end
          if not ignored then
            table.insert(scriptList, v)
          end
        end
      end
      if Settings.include_nil then
        for _,v in next, getnilinstances() do
          if v:IsA("LocalScript") or v:IsA("ModuleScript") then
            table.insert(nilList, v)
          end
        end
      end

      totalScripts = #scriptList + #nilList
      if totalScripts == 0 then
        status.Text = "No scripts found!"
        active = false
        startBtn.Text = "Start Dumping"
        startBtn.BackgroundColor3 = colors.accent
        return
      end

      status.Text = "Dumping " .. totalScripts .. " scripts..."

      local function doDump(v, isNil)
        threads = threads + 1
        local ok, src = pcall(decompile, v)
        if Settings.ignore_empty and ok and #src < 200 then
          local hasCode = false
          for _,line in next, string.split(src, "\n") do
            if line:sub(1,2) ~= "--" and line:gsub("%s", "") ~= "" then
              hasCode = true
              break
            end
          end
          if not hasCode then
            threads = threads - 1
            dumped = dumped + 1
            progressFill.Size = UDim2.fromScale(dumped / totalScripts, 1)
            status.Text = dumped .. "/" .. totalScripts
            return
          end
        end
        if ok and src and #src > 0 then
          local header = format("-- Name: %s\n-- Class: %s\n-- Path: %s\n\n", v.Name, v.ClassName, v:GetFullName())
          local output = header .. src

          if hasFS then
            local ok = false
            local fname = v.Name .. "_" .. v:GetDebugId() .. ".lua"
            for _, attempt in next, {
              "UniversalDumper/" .. fname,
              "UD_" .. fname,
              "Workspace/UD_" .. fname,
              fname,
            } do
              local s, e = pcall(writefile, attempt, output)
              if s then ok = true; break end
            end
            if not ok then
              pcall(writefile, "UD_" .. game.PlaceId .. "_" .. fname, output)
            end
          end

          if isMobile or not hasFS then
            pcall(setclipboard, output)
          end
        end
        dumped = dumped + 1
        threads = threads - 1
        task.wait(Settings.delay)
        progressFill.Size = UDim2.fromScale(dumped / totalScripts, 1)
        status.Text = dumped .. "/" .. totalScripts
      end

      local function dumpAll(list, isNil)
        for _,v in next, list do
          while threads >= Settings.threads do
            task.wait(0.05)
          end
          if active then
            task.spawn(doDump, v, isNil)
          end
        end
      end

      task.spawn(function()
        if Settings.disable_render then
          RunService:Set3dRenderingEnabled(false)
        end

        dumpAll(scriptList, false)
        while threads > 0 do task.wait() end

        if Settings.include_nil then
          dumpAll(nilList, true)
          while threads > 0 do task.wait() end
        end

        if Settings.disable_render then
          RunService:Set3dRenderingEnabled(true)
        end

        active = false
        startBtn.Text = "Start Dumping"
        startBtn.BackgroundColor3 = colors.accent
        status.Text = "Done! Dumped " .. dumped .. "/" .. totalScripts .. " scripts"
        progressFill.Size = UDim2.fromScale(1, 1)
      end)
    end)
    startBtn.Parent = scroll
  end)

  -- Tab: Function Decompiler
  addContent("Function", function(scroll)
    makeLabel("Paste a function to decompile, or select an object from the hierarchy").Parent = scroll
    makeLabel("").Parent = scroll

    local methodLabel = makeLabel("Method: Decompile Function")
    methodLabel.TextColor3 = colors.accent
    methodLabel.Font = Enum.Font.GothamBold
    methodLabel.Parent = scroll

    local inputFrame, inputBox = makeTextbox("local f = function() ... end", true)
    inputFrame.Parent = scroll

    local optionsFrame = Instance.new("Frame")
    optionsFrame.Size = UDim2.fromScale(1, 0)
    optionsFrame.BackgroundTransparency = 1
    optionsFrame.AutomaticSize = Enum.AutomaticSize.Y
    optionsFrame.Parent = scroll

    makeToggle("Return Values", Settings.func_return_values, function(v) Settings.func_return_values = v end).Parent = optionsFrame
    makeSlider("Max Table Size", 1, 20, Settings.func_max_table_size, "", function(v) Settings.func_max_table_size = v end):Parent = optionsFrame
    makeToggle("Decode Bytes", Settings.func_decode_bytes, function(v) Settings.func_decode_bytes = v end).Parent = optionsFrame

    local outputBox
    local function runDecompiler()
      local code = inputBox.Text
      if code == "" then
        statusLabel.Text = "Enter a function first!"
        return
      end

      local f, err = loadstring(code)
      if not f then
        statusLabel.Text = "Error: " .. tostring(err)
        return
      end
      f = f()
      if type(f) ~= "function" then
        statusLabel.Text = "Expression did not return a function"
        return
      end

      statusLabel.Text = "Decompiling..."
      task.wait()

      local ok, result = pcall(function()
        local startTime = tick()

        local Metatable = {
          metamethods = {
            __index = function(self, key) return self[key] end,
            __newindex = function(self, key, value) self[key] = value end,
            __call = function(self, ...) return self(...) end,
            __concat = function(self, b) return self..b end,
            __add = function(self, b) return self + b end,
            __sub = function(self, b) return self - b end,
            __mul = function(self, b) return self * b end,
            __div = function(self, b) return self / b end,
            __idiv = function(self, b) return self // b end,
            __mod = function(self, b) return self % b end,
            __pow = function(self, b) return self ^ b end,
            __tostring = function(self) return tostring(self) end,
            __eq = function(self, b) return self == b end,
            __lt = function(self, b) return self < b end,
            __le = function(self, b) return self <= b end,
            __len = function(self) return #self end,
            __iter = function(self) return next, self end,
            __namecall = function(self, ...) return self:_(...) end,
          }
        }

        local function getFullName(inst)
          local p = inst
          local lo = {}
          while p ~= game and p.Parent do
            table.insert(lo, p)
            p = p.Parent
          end
          if #lo == 0 then return "nil" end
          local n = lo[#lo].ClassName ~= "Workspace" and 'game:GetService("' .. lo[#lo].ClassName .. '")' or "workspace"
          for i = #lo - 1, 1, -1 do
            n = n .. ':FindFirstChild("' .. lo[i].Name .. '")'
          end
          return n
        end

        local nonluaglobals = {}
        local libs = {
          coroutine = coroutine, math = math, buffer = buffer, table = table,
          string = string, os = os, utf8 = utf8, bit32 = bit32, debug = debug, task = task
        }
        for libname, libval in next, libs do
          for fn, _ in next, libval do
            nonluaglobals[fn] = libname .. "." .. fn
          end
        end

        local function rawlen(t)
          local c = 0
          for _,_ in next, t do c = c + 1 end
          return c
        end

        local SelectedNum = 2147483647 ^ 2
        local SelectedStuff = {}
        local constants = {}
        local protos = {}
        local stack = {}
        local params = {}

        local paramNum, isVararg = debug.info(f, "a")
        local function getLClosure(mm, obj)
          local hooked
          local mmemu = Metatable.metamethods[mm]
          xpcall(function() mmemu(obj) end, function() hooked = debug.info(2, "f") end)
          return hooked
        end

        local function wrap(parent)
          local hooks = {}
          local t = {}
          for mm in Metatable.metamethods do
            local sn = math.random(2^16, 2^24)
            hooks[mm] = function(_, ...)
              local self = {pc = (#stack + 1), children = {}, parent = parent, arguments = {...}, metamethod = mm}
              parent.children[self.pc] = self
              if mm == "__len" or mm == "__tostring" then return tostring(parent) end
              return wrap(self)
            end
          end
          table.insert(stack, t)
          return setmetatable(t, hooks)
        end

        local env = wrap(nil)
        local rootEnv = env

        local paramsList = {}
        for i = 1, paramNum do
          table.insert(paramsList, wrap(env))
        end
        if isVararg then
          table.insert(paramsList, wrap(env))
        end

        local ok2, rets = pcall(setfenv(f, env), unpack(paramsList))

        local function formatVal(value, tabs, exclude)
          tabs = tabs or 1
          local tp = typeof(value)
          if tp == "string" then
            local s = ""
            for _, char in {value:byte(1, -1)} do
              s = s .. (char > 126 or char < 32 and "\\" .. char or string.char(char))
            end
            return '"' .. s .. '"'
          elseif tp == "number" then
            return tostring(value)
          elseif tp == "boolean" then
            return tostring(value)
          elseif tp == "table" then
            local t = "{"
            local count = 0
            local total = rawlen(value)
            for k, v in next, value do
              count += 1
              local kStr = type(k) == "number" and "[" .. k .. "]" or '["' .. tostring(k) .. '"]'
              local vStr = formatVal(v, tabs + 1)
              t = t .. kStr .. " = " .. vStr
              if count < total then t = t .. ", " end
            end
            t = t .. "}"
            return t
          elseif tp == "Instance" then
            return getFullName(value)
          elseif tp == "function" then
            local fnName = debug.info(value, "n")
            if fnName == "" then return "function() end" end
            return fnName
          end
          return tostring(value)
        end

        local disasmLines = {}
        local pc = 0
        local function parseBranch(branch, parent)
          if not branch then return end
          local mm = branch.metamethod
          local args = branch.arguments or {}
          local a = args[1]
          local b = args[2]
          local pName = parent and "v" .. (parent.pc or 0) or "root"

          if mm == "__index" then
            local key = tostring(a)
            if key:match("^[%a_][%w_]*$") then
              table.insert(disasmLines, "local v" .. pc .. " = " .. pName .. "." .. key)
            else
              table.insert(disasmLines, "local v" .. pc .. " = " .. pName .. "[" .. formatVal(a) .. "]")
            end
          elseif mm == "__newindex" then
            table.insert(disasmLines, pName .. "[" .. formatVal(a) .. "] = " .. formatVal(b))
          elseif mm == "__call" then
            local tpl = ""
            for i = 1, #args do
              tpl = tpl .. formatVal(args[i])
              if i < #args then tpl = tpl .. ", " end
            end
            table.insert(disasmLines, "local v" .. pc .. " = " .. pName .. "(" .. tpl .. ")")
          elseif mm == "__add" then
            table.insert(disasmLines, "local v" .. pc .. " = " .. pName .. " + " .. formatVal(a))
          elseif mm == "__sub" then
            table.insert(disasmLines, "local v" .. pc .. " = " .. pName .. " - " .. formatVal(a))
          elseif mm == "__mul" then
            table.insert(disasmLines, "local v" .. pc .. " = " .. pName .. " * " .. formatVal(a))
          elseif mm == "__div" then
            table.insert(disasmLines, "local v" .. pc .. " = " .. pName .. " / " .. formatVal(a))
          elseif mm == "__concat" then
            table.insert(disasmLines, "local v" .. pc .. " = " .. pName .. " .. " .. formatVal(a))
          elseif mm == "__eq" then
            table.insert(disasmLines, "local v" .. pc .. " = " .. pName .. " == " .. formatVal(a))
          elseif mm == "__lt" then
            table.insert(disasmLines, "local v" .. pc .. " = " .. pName .. " < " .. formatVal(a))
          elseif mm == "__le" then
            table.insert(disasmLines, "local v" .. pc .. " = " .. pName .. " <= " .. formatVal(a))
          elseif mm == "__len" then
            table.insert(disasmLines, "local v" .. pc .. " = #" .. pName)
          elseif mm == "__tostring" then
            table.insert(disasmLines, "local v" .. pc .. " = tostring(" .. pName .. ")")
          else
            table.insert(disasmLines, "-- " .. mm .. " (not visualized)")
          end
          pc = c + 1
          for _, child in next, branch.children or {} do
            parseBranch(child, branch)
          end
        end

        for _, child in next, (rootEnv and rootEnv.children or {}) do
          parseBranch(child, rootEnv)
        end

        local paramStr = ""
        for i = 1, paramNum do
          paramStr = paramStr .. "_p" .. i
          if i < paramNum then paramStr = paramStr .. ", " end
        end
        if isVararg then
          if paramStr ~= "" then paramStr = paramStr .. ", " end
          paramStr = paramStr .. "..."
        end

        local fnName = debug.info(f, "n")
        fnName = fnName ~= "" and fnName or "__func"

        local output = "-- Decompiled with Universal Dumper\n"
        output = output .. "-- Time: " .. tostring(tick() - startTime) .. "s\n"
        output = output .. "function " .. fnName .. "(" .. paramStr .. ")\n"
        for _, line in next, disasmLines do
          output = output .. "  " .. line .. "\n"
        end
        output = output .. "end\n"

        return output
      end)

      if ok then
        outputBox.Text = result
        statusLabel.Text = "Decompiled successfully"
        pcall(setclipboard, result)
      else
        outputBox.Text = "-- Error: " .. tostring(result)
        statusLabel.Text = "Decompile failed"
      end
    end

    local runBtn = makeBtn("Decompile", runDecompiler)
    runBtn.Parent = scroll

    local statusLabel = makeLabel("Enter a function and press Decompile")
    statusLabel.Parent = scroll

    local outputFrame = Instance.new("Frame")
    outputFrame.Size = UDim2.fromScale(1, 0)
    outputFrame.BackgroundColor3 = colors.surface2
    outputFrame.BorderSizePixel = 0
    outputFrame.AutomaticSize = Enum.AutomaticSize.Y
    local oc = Instance.new("UICorner", outputFrame)
    oc.CornerRadius = UDim.new(0, 8)
    outputFrame.Parent = scroll

    outputBox = Instance.new("TextBox")
    outputBox.Size = UDim2.fromScale(1, 120)
    outputBox.BackgroundTransparency = 1
    outputBox.Text = ""
    outputBox.TextColor3 = colors.success
    outputBox.Font = Enum.Font.Code
    outputBox.TextSize = 11
    outputBox.TextXAlignment = Enum.TextXAlignment.Left
    outputBox.TextYAlignment = Enum.TextYAlignment.Top
    outputBox.MultiLine = true
    outputBox.ClearTextOnFocus = false
    outputBox.Parent = outputFrame

    makeLabel("Tip: Output is also copied to clipboard").Parent = scroll
  end)

  -- Tab: Output
  addContent("Output", function(scroll)
    local logBox = Instance.new("TextBox")
    logBox.Size = UDim2.fromScale(1, 300)
    logBox.BackgroundColor3 = colors.surface2
    logBox.BorderSizePixel = 0
    logBox.Text = ""
    logBox.TextColor3 = colors.text
    logBox.Font = Enum.Font.Code
    logBox.TextSize = 11
    logBox.TextXAlignment = Enum.TextXAlignment.Left
    logBox.TextYAlignment = Enum.TextYAlignment.Top
    logBox.MultiLine = true
    logBox.ClearTextOnFocus = false
    logBox.Parent = scroll
    local c = Instance.new("UICorner", logBox)
    c.CornerRadius = UDim.new(0, 8)

    local clearBtn = makeBtn("Clear Log", function()
      logBox.Text = ""
    end)
    clearBtn.Parent = scroll

    makeBtn("Copy All", function()
      pcall(setclipboard, logBox.Text)
    end).Parent = scroll

    -- Hook print
    local oldPrint = print
    _G.print = function(...)
      local args = {...}
      local str = ""
      for i, v in next, args do
        str = str .. tostring(v)
        if i < #args then str = str .. "  " end
      end
      logBox.Text = logBox.Text .. str .. "\n"
      logBox.CanvasPosition = Vector2.new(0, logBox.TextBounds.Y)
      oldPrint(...)
    end
  end)

  -- Tab switching
  for _, tabName in next, tabs do
    local btn = Instance.new("TextButton")
    btn.Size = UDim2.fromOffset(100, 22)
    btn.BackgroundColor3 = colors.surface2
    btn.Text = tabName
    btn.TextColor3 = colors.textDim
    btn.Font = Enum.Font.GothamSemibold
    btn.TextSize = 12
    btn.BorderSizePixel = 0
    local c = Instance.new("UICorner", btn)
    c.CornerRadius = UDim.new(0, 6)
    btn.Parent = tabBar
    tabBtns[tabName] = btn

    btn.MouseButton1Click:Connect(function()
      for _, v in next, tabFrames do v.Visible = false end
      for _, v in next, tabBtns do v.BackgroundColor3 = colors.surface2; v.TextColor3 = colors.textDim end
      tabFrames[tabName].Visible = true
      btn.BackgroundColor3 = colors.accent
      btn.TextColor3 = colors.text
    end)
  end

  -- Show first tab
  local firstTab = tabs[1]
  if tabFrames[firstTab] then
    tabFrames[firstTab].Visible = true
    if tabBtns[firstTab] then
      tabBtns[firstTab].BackgroundColor3 = colors.accent
      tabBtns[firstTab].TextColor3 = colors.text
    end
  end

  return screenGui
end

-- Run
warn("UD: About to call createUI()")
local success, err = pcall(createUI)
if not success then
  warn("UD Error: " .. tostring(err))
  pcall(function() writefile("_UD_ERROR.txt", "UD Error: " .. tostring(err)) end)
  -- Fallback: minimal UI
  local s = Instance.new("ScreenGui")
  s.Name = "UniversalDumper"
  s.ResetOnSpawn = false
  pcall(function() if syn and syn.protect_gui then syn.protect_gui(s) end end)
  s.Parent = plr:WaitForChild("PlayerGui")
  local t = Instance.new("TextButton")
  t.Size = UDim2.fromOffset(200, 50)
  t.Position = UDim2.fromScale(0.5, 0.5)
  t.AnchorPoint = Vector2.new(0.5, 0.5)
  t.Text = "Universal Dumper\n(Tap to Dump)"
  t.BackgroundColor3 = Color3.fromRGB(88, 101, 242)
  t.TextColor3 = Color3.fromRGB(255, 255, 255)
  t.Font = Enum.Font.GothamBold
  t.TextSize = 14
  t.Parent = s
  local c = Instance.new("UICorner", t)
  c.CornerRadius = UDim.new(0, 8)
  t.MouseButton1Click:Connect(function()
    t.Text = "Dumping..."
    task.spawn(function()
      local count = 0
      for _,v in next, game:GetDescendants() do
        if v:IsA("LocalScript") or v:IsA("ModuleScript") then
          pcall(function()
            local src = decompile(v)
            pcall(setclipboard, src)
            count += 1
          end)
          task.wait()
        end
      end
      t.Text = "Dumped " .. count .. " scripts!"
      task.wait(2)
      t.Text = "Universal Dumper\n(Tap to Dump)"
    end)
  end)
end

if success then
  warn("UD: UI created successfully")
end
warn("UD: Script finished loading")
