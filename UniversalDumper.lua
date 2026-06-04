-- Universal Dumper v2 — No-UI (headless)
-- Gathers & decompiles all LocalScripts/ModuleScripts

local decompile = decompile or disassemble
local getnilinstances = getnilinstances or get_nil_instances
local getscripthash = getscripthash or get_script_hash
local format = string.format

local settings = {
  threads = 5,
  delay = 0.05,
  timeout = 5,
  include_nil = false,
  ignore_empty = true,
}

local threads = 0
local count = 0
local total = 0
local hasFS = pcall(function()
  writefile("_ud_test", "ok")
  local r = readfile("_ud_test")
  writefile("_ud_test", "")
  return r == "ok"
end)
local decompilecache = {}

local function isIgnored(v)
  if v:FindFirstAncestor("CoreGui") then return true end
  if v:FindFirstAncestor("CorePackages") then return true end
  if v:FindFirstAncestor("Chat") then return true end
  return false
end

local function doDump(v)
  threads = threads + 1
  local hash = getscripthash and getscripthash(v) or v:GetDebugId()
  local src = decompilecache[hash]
  if not src then
    local time = os.clock()
    local ok, result
    repeat
      ok, result = pcall(decompile, v)
      if ok then break end
      if os.clock() - time > settings.timeout then
        result = "-- Decompilation timed out"
        break
      end
      task.wait(0.25)
    until false
    src = result or "-- No source"
    decompilecache[hash] = src
  end

  if settings.ignore_empty and #src < 200 then
    local hasCode = false
    for _, line in next, string.split(src, "\n") do
      if line:sub(1, 2) ~= "--" and line:gsub("%s", "") ~= "" then
        hasCode = true
        break
      end
    end
    if not hasCode then
      count = count + 1
      threads = threads - 1
      return
    end
  end

  local header = format("-- Name: %s\n-- Class: %s\n-- Path: %s\n--\n\n", v.Name, v.ClassName, v:GetFullName())
  local output = header .. src

  if hasFS then
    local fname = v.Name .. "_" .. v:GetDebugId() .. ".lua"
    pcall(writefile, "UD_" .. fname, output)
  end

  count = count + 1
  threads = threads - 1
  print("Dumped " .. count .. "/" .. total .. " - " .. v:GetFullName())
end

-- Gather
local scripts = {}
for _, v in next, game:GetDescendants() do
  if (v:IsA("LocalScript") or v:IsA("ModuleScript")) and not isIgnored(v) then
    table.insert(scripts, v)
  end
end

if settings.include_nil then
  for _, v in next, getnilinstances() do
    if (v:IsA("LocalScript") or v:IsA("ModuleScript")) and not isIgnored(v) then
      table.insert(scripts, v)
    end
  end
end

total = #scripts
print("Universal Dumper: Found " .. total .. " scripts")

-- Dump with threading
for _, v in next, scripts do
  while threads >= settings.threads do
    task.wait(settings.delay)
  end
  task.spawn(doDump, v)
end

-- Wait for all to finish
while threads > 0 do
  task.wait(0.1)
end

print("Universal Dumper: Done! Dumped " .. count .. "/" .. total .. " scripts")
if hasFS then
  print("Files saved: Delta/Workspace/UD_*.lua")
end
