--[[
    hypershot.lua  --  Hypershot (root place 17516596118, universe 5995470825)

    Everything in one paged menu, built the same way as the Gunfight Arena one:
    a root page of submenus, each page a plain table of rows. Findings this is
    built on, all read out of the live client.

    ENTITIES. Hypershot does not use roblox characters -- Player.Character is
    nil and Teams is empty. Every player and bot is a Model under
    workspace.Entities carrying its whole state as ATTRIBUTES:

        EntityId, OwnerUserId, Bot, Team, Alive, Health, MaxHealth,
        Weapon, Weapon1..3, Level, BaseWS, Ability1..3

    so the enemy test is Team, the health bar is Health/MaxHealth, and a bot is
    the Bot attribute. No netvars and no hooks.

    HITBOXES are computed boxes, not parts (ReplicatedStorage.Entity.Hitboxes),
    built off the root with EntityConfig offsets. The head sits
    WAIST_Y + WAIST_TO_NECK + NECK_TO_HEAD = 1.757 above the root, which is the
    same number the engine keeps as HEAD_COLLIDE_Y, so head aim hits the real
    box rather than a guess.

    SHOT PATH. Gun.GExtra:Shoot calls ShotClient:AimDirection, which reads
    workspace.CurrentCamera and raycasts the hitboxes, then Prepare quantizes
    that direction into the packet. The direction is therefore whatever the
    camera says at the instant the shot leaves. Patching the module is no use --
    the executor require returns a separate copy (GetTick 0, IsRunning false),
    so the game's own module instance is out of reach -- but turning the camera
    for the one step the shot is sampled in is not, and that is Silent mode:
    camera set on Stepped, restored on Heartbeat, both after the frame has
    already been drawn, so nothing is visible.

    WEAPONS. LoadoutShared fires NetworkModule2:FireServer("EquipLoadout",
    loadoutIndex, typeIndex, weaponName, uuid, source), and NetworkModule2's
    FireServer is a plain pass-through with no signing, so the remote can be
    called directly. typeIndex comes from GlobalStuff.WEAPON_TYPE_TO_INDEX:
    1 primary (AR/SMG/Shotgun/Sniper/Misc), 2 secondary (Pistol/AutoPistol/
    Shotgun2/Misc2), 3 melee. Every weapon in the game is a module under
    ReplicatedStorage.Weapons.Modules whether or not it is owned, which is what
    makes the whole list reachable.

    Menu: INSERT or DELETE.  Arrows move, Enter selects, Backspace goes back.
]]

local Players          = game:GetService("Players")
local RunService       = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TweenService     = game:GetService("TweenService")
local HttpService      = game:GetService("HttpService")
local Lighting         = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ContextActionService = game:GetService("ContextActionService")

local LocalPlayer = Players.LocalPlayer
local Camera      = workspace.CurrentCamera
local GUI_HOST    = (gethui and gethui()) or game:GetService("CoreGui")

if _G.__HYPERSHOT then pcall(_G.__HYPERSHOT) end

local ENTITIES = workspace:WaitForChild("Entities")
local WEAPON_MODULES = ReplicatedStorage.Weapons:WaitForChild("Modules")
local REMOTES = ReplicatedStorage.Network:WaitForChild("Remotes")

--============================================================================
-- config
--============================================================================

local CONFIG_PATH = "hypershot_config.json"

local Config = {
    MinecraftUI  = false,
    -- aim
    AimEnabled = false,
    AimMode    = "Silent",      -- Silent (camera never moves) / Lock (camera turns)
    AimKey     = "MouseButton2",
    Engage     = "Always",      -- Always (no key, silent only turns while firing matters) / Hold
    Bone       = "Head",        -- Head / Torso / Root
    FOVDeg     = 60,
    Range      = 1000,
    Smooth     = 0.35,
    VisCheck   = true,
    Sticky     = true,

    -- targets
    TeamCheck  = true,
    HitBots    = true,
    HitPlayers = true,

    -- esp
    EspEnabled  = true,
    EspBox      = true,
    EspName     = true,
    EspHealth   = true,
    EspInfo     = true,
    EspTracer   = false,
    EspChams    = false,
    EspBots     = true,
    EspMaxDist  = 1200,
    EspTextSize = 12,


    -- misc
    Fullbright = false,
    NoFog      = false,
    CamFOV     = 70,
}

-- the head sits HEAD_COLLIDE_Y above the root, the torso halfway down it
local BONE_OFFSET = { Head = 1.757, Torso = 0.6, Root = 0 }

local conns = {}
local function track(c) table.insert(conns, c) return c end

--============================================================================
-- entities
--============================================================================

local lastTeam = nil
local statusText = "idle"

local function localEntity()
    for _, m in ipairs(ENTITIES:GetChildren()) do
        if m:GetAttribute("OwnerUserId") == LocalPlayer.UserId then return m end
    end
    return nil
end

-- the local entity leaves the folder while dead, so the team is remembered:
-- without it the team check quietly switches itself off for the whole respawn
local function myTeam()
    local me = localEntity()
    local team = me and me:GetAttribute("Team")
    if team then lastTeam = team end
    return team or lastTeam
end

local function aimPoint(model)
    local root = model:FindFirstChild("HumanoidRootPart")
    if not root then return nil end
    return root.Position + Vector3.new(0, BONE_OFFSET[Config.Bone] or 0, 0)
end

local function valid(model, forAim)
    if model:GetAttribute("Alive") == false then return false end
    if model:GetAttribute("OwnerUserId") == LocalPlayer.UserId then return false end

    local isBot = model:GetAttribute("Bot") == true
    if forAim then
        if isBot and not Config.HitBots then return false end
        if not isBot and not Config.HitPlayers then return false end
    else
        if isBot and not Config.EspBots then return false end
    end

    if Config.TeamCheck then
        local mine = myTeam()
        if mine and model:GetAttribute("Team") == mine then return false end
    end

    return model:FindFirstChild("HumanoidRootPart") ~= nil
end

local CAST = RaycastParams.new()
CAST.FilterType = Enum.RaycastFilterType.Exclude
CAST.IgnoreWater = true

-- The viewmodel arms live in workspace.IgnoreThese and sit right in front of
-- the camera, so a naive visibility ray hits MyArms.RootPart every single time
-- and reports that every enemy is behind cover. The game keeps its own ignore
-- folders for exactly this; both go in the filter.
local function visFilter(model)
    local list = { model, localEntity(), Camera }
    local ignore = workspace:FindFirstChild("IgnoreThese")
    if ignore then table.insert(list, ignore) end
    local rayIgnore = workspace:FindFirstChild("RayIgnore")
    if rayIgnore then table.insert(list, rayIgnore) end
    return list
end

local function visible(point, model)
    if not Config.VisCheck then return true end
    CAST.FilterDescendantsInstances = visFilter(model)
    local from = Camera.CFrame.Position
    return workspace:Raycast(from, point - from, CAST) == nil
end

--============================================================================
-- aim
--============================================================================

local currentTarget = nil

local function keyEnum()
    local name = Config.AimKey
    if name:find("Mouse") then return Enum.UserInputType[name], true end
    local ok, e = pcall(function() return Enum.KeyCode[name] end)
    return (ok and e) or Enum.KeyCode.E, false
end

-- Always is the sane default for Silent: right click is ADS in this game, so
-- requiring a held key meant the aim only ran while scoped, which is not when
-- most shots are taken.
local function keyDown()
    if Config.Engage == "Always" then return true end
    local e, isMouse = keyEnum()
    if isMouse then return UserInputService:IsMouseButtonPressed(e) end
    return UserInputService:IsKeyDown(e)
end

local function targetUsable(model)
    if not model or not model.Parent then return false end
    if not valid(model, true) then return false end
    local point = aimPoint(model)
    if not point then return false end
    local delta = point - Camera.CFrame.Position
    if delta.Magnitude > Config.Range then return false end
    local angle = math.deg(math.acos(math.clamp(delta.Unit:Dot(Camera.CFrame.LookVector), -1, 1)))
    if angle > Config.FOVDeg then return false end
    return visible(point, model)
end

local function pickTarget()
    -- sticky keeps the same body while it stays legal, so the aim does not
    -- jump between two enemies standing next to each other
    if Config.Sticky and targetUsable(currentTarget) then
        return currentTarget
    end

    local best, bestAngle
    local origin, look = Camera.CFrame.Position, Camera.CFrame.LookVector

    for _, model in ipairs(ENTITIES:GetChildren()) do
        if valid(model, true) then
            local point = aimPoint(model)
            if point then
                local delta = point - origin
                local dist = delta.Magnitude
                if dist <= Config.Range then
                    local angle = math.deg(math.acos(math.clamp(delta.Unit:Dot(look), -1, 1)))
                    if angle <= Config.FOVDeg and (not bestAngle or angle < bestAngle) then
                        if visible(point, model) then best, bestAngle = model, angle end
                    end
                end
            end
        end
    end

    currentTarget = best
    return best, bestAngle
end

-- SILENT. Gun.Auto and Gun both call :Shoot() out of a `task.wait()` loop, and
-- a task.wait resumes on the Heartbeat step. So the camera has to still be
-- aimed WHEN HEARTBEAT RUNS, which is after Stepped and after the frame has
-- already been drawn. It is put back at the very start of the next frame,
-- before the game's own camera module runs and long before anything renders,
-- so the view never shows the turn.
--
--   frame:  [restore] RenderStep -> draw -> Stepped [aim] -> Heartbeat [Shoot]
--
-- The first build restored on Heartbeat, which landed exactly on top of the
-- shot and is why it did nothing.
local silentSaved = nil

local function silentAim()
    if not Config.AimEnabled or Config.AimMode ~= "Silent" then return end
    if not keyDown() then statusText = "waiting for key" return end

    local target = pickTarget()
    if not target then statusText = "no target" return end

    local point = aimPoint(target)
    if not point then return end

    silentSaved = silentSaved or Camera.CFrame
    Camera.CFrame = CFrame.lookAt(Camera.CFrame.Position, point)

    statusText = string.format("[silent] %s%s  %.0fst",
        (target:GetAttribute("Bot") == true) and "[bot] " or "",
        target.Name:gsub("__Bot$", ""), (point - Camera.CFrame.Position).Magnitude)
end

local RESTORE_BIND = "hypershot_restore"

pcall(function() RunService:UnbindFromRenderStep(RESTORE_BIND) end)
RunService:BindToRenderStep(RESTORE_BIND, Enum.RenderPriority.First.Value - 1, function()
    if silentSaved then
        Camera.CFrame = silentSaved
        silentSaved = nil
    end
end)

track(RunService.Stepped:Connect(silentAim))

local AIM_BIND = "hypershot_aim"

local function lockStep()
    if not Config.AimEnabled or Config.AimMode ~= "Lock" then return end
    if not keyDown() then statusText = "waiting for key" return end

    local target = pickTarget()
    if not target then statusText = "no target" return end

    local point = aimPoint(target)
    if not point then return end

    local goal = CFrame.lookAt(Camera.CFrame.Position, point)
    local alpha = math.clamp(Config.Smooth, 0.02, 1)
    Camera.CFrame = (alpha >= 1) and goal or Camera.CFrame:Lerp(goal, alpha)

    statusText = string.format("[lock] %s%s  %.0fst",
        (target:GetAttribute("Bot") == true) and "[bot] " or "",
        target.Name:gsub("__Bot$", ""), (point - Camera.CFrame.Position).Magnitude)
end

pcall(function() RunService:UnbindFromRenderStep(AIM_BIND) end)
RunService:BindToRenderStep(AIM_BIND, Enum.RenderPriority.Camera.Value + 10, lockStep)

--============================================================================
-- esp
--============================================================================

local espGui = Instance.new("ScreenGui")
espGui.Name = "hypershot_esp"
espGui.IgnoreGuiInset = true
espGui.ResetOnSpawn = false
espGui.DisplayOrder = 400
espGui.Parent = GUI_HOST

local drawings = {}

local function makeLabel(size, bold)
    local l = Instance.new("TextLabel")
    l.BackgroundTransparency = 1
    l.Size = UDim2.fromOffset(220, 14)
    l.Font = bold and Enum.Font.GothamBold or Enum.Font.Gotham
    l.TextSize = size
    l.TextColor3 = Color3.new(1, 1, 1)
    l.TextStrokeTransparency = 0.4
    l.Visible = false
    l.Parent = espGui
    return l
end

local function drawingFor(model)
    local d = drawings[model]
    if d and d.box.Parent then return d end

    local box = Instance.new("Frame")
    box.BackgroundTransparency = 1
    box.BorderSizePixel = 0
    box.Visible = false
    box.Parent = espGui
    local stroke = Instance.new("UIStroke")
    stroke.Thickness = 1.4
    stroke.Color = Color3.fromRGB(235, 70, 70)
    stroke.Parent = box

    local hpBack = Instance.new("Frame")
    hpBack.BackgroundColor3 = Color3.fromRGB(18, 18, 22)
    hpBack.BorderSizePixel = 0
    hpBack.Visible = false
    hpBack.Parent = espGui
    local hp = Instance.new("Frame")
    hp.BorderSizePixel = 0
    hp.Parent = hpBack

    local tracer = Instance.new("Frame")
    tracer.BackgroundColor3 = Color3.fromRGB(235, 70, 70)
    tracer.BorderSizePixel = 0
    tracer.AnchorPoint = Vector2.new(0.5, 0)
    tracer.Visible = false
    tracer.Parent = espGui

    d = {
        box = box, stroke = stroke, hpBack = hpBack, hp = hp, tracer = tracer,
        name = makeLabel(Config.EspTextSize, true),
        info = makeLabel(Config.EspTextSize - 1, false),
    }
    drawings[model] = d
    return d
end

local function chamsFor(model, on)
    local hl = model:FindFirstChild("hypershot_chams")
    if not on then
        if hl then hl:Destroy() end
        return
    end
    if not hl then
        hl = Instance.new("Highlight")
        hl.Name = "hypershot_chams"
        hl.FillColor = Color3.fromRGB(235, 70, 70)
        hl.FillTransparency = 0.55
        hl.OutlineColor = Color3.new(1, 1, 1)
        hl.OutlineTransparency = 0.2
        hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
        hl.Parent = model
    end
end

local ESP_BIND = "hypershot_esp"

local function espStep()
    local seen = {}

    if Config.EspEnabled then
        local origin = Camera.CFrame.Position
        local vw = Camera.ViewportSize

        for _, model in ipairs(ENTITIES:GetChildren()) do
            if valid(model, false) then
                local root = model:FindFirstChild("HumanoidRootPart")
                local dist = (root.Position - origin).Magnitude

                if dist <= Config.EspMaxDist then
                    local top, onScreen = Camera:WorldToViewportPoint(root.Position + Vector3.new(0, 2.6, 0))
                    local bottom = Camera:WorldToViewportPoint(root.Position - Vector3.new(0, 3.0, 0))

                    if onScreen then
                        seen[model] = true
                        local d = drawingFor(model)

                        local height = math.abs(bottom.Y - top.Y)
                        local width = height * 0.52
                        local x, y = top.X - width / 2, top.Y

                        d.box.Visible = Config.EspBox
                        d.box.Position = UDim2.fromOffset(x, y)
                        d.box.Size = UDim2.fromOffset(width, height)

                        d.name.Visible = Config.EspName
                        d.name.TextSize = Config.EspTextSize
                        d.name.Position = UDim2.fromOffset(x + width / 2 - 110, y - Config.EspTextSize - 3)
                        d.name.Text = model.Name:gsub("__Bot$", "")

                        local hpNow = model:GetAttribute("Health") or 0
                        local hpMax = math.max(model:GetAttribute("MaxHealth") or 100, 1)
                        local frac = math.clamp(hpNow / hpMax, 0, 1)

                        d.info.Visible = Config.EspInfo
                        d.info.TextSize = Config.EspTextSize - 1
                        d.info.Position = UDim2.fromOffset(x + width / 2 - 110, y + height + 2)
                        d.info.Text = string.format("%.0fm  %s", dist,
                            tostring(model:GetAttribute("Weapon") or ""))

                        d.hpBack.Visible = Config.EspHealth
                        d.hpBack.Position = UDim2.fromOffset(x - 6, y)
                        d.hpBack.Size = UDim2.fromOffset(3, height)
                        d.hp.Size = UDim2.fromScale(1, frac)
                        d.hp.Position = UDim2.fromScale(0, 1 - frac)
                        d.hp.BackgroundColor3 =
                            Color3.fromRGB(240, 80, 80):Lerp(Color3.fromRGB(90, 220, 120), frac)

                        d.tracer.Visible = Config.EspTracer
                        if Config.EspTracer then
                            local sx, sy = vw.X / 2, vw.Y
                            local dx, dy = top.X - sx, (y + height) - sy
                            local len = math.sqrt(dx * dx + dy * dy)
                            d.tracer.Size = UDim2.fromOffset(1, len)
                            d.tracer.Position = UDim2.fromOffset(sx, sy)
                            d.tracer.Rotation = math.deg(math.atan2(dy, dx)) - 90
                            d.tracer.AnchorPoint = Vector2.new(0.5, 0)
                        end

                        chamsFor(model, Config.EspChams)
                    end
                end
            end
        end
    end

    for model, d in pairs(drawings) do
        if not seen[model] then
            chamsFor(model, false)
            if not model.Parent then
                for _, obj in pairs(d) do
                    if typeof(obj) == "Instance" then obj:Destroy() end
                end
                drawings[model] = nil
            else
                d.box.Visible, d.name.Visible, d.info.Visible = false, false, false
                d.hpBack.Visible, d.tracer.Visible = false, false
            end
        end
    end
end

pcall(function() RunService:UnbindFromRenderStep(ESP_BIND) end)
RunService:BindToRenderStep(ESP_BIND, Enum.RenderPriority.Last.Value, espStep)

--============================================================================
-- weapons
--============================================================================

--============================================================================
-- misc
--============================================================================

local savedLighting = {
    Brightness = Lighting.Brightness,
    ClockTime = Lighting.ClockTime,
    FogEnd = Lighting.FogEnd,
    GlobalShadows = Lighting.GlobalShadows,
    Ambient = Lighting.Ambient,
}

local function applyMisc()
    if Config.Fullbright then
        Lighting.Brightness = 3
        Lighting.ClockTime = 14
        Lighting.GlobalShadows = false
        Lighting.Ambient = Color3.fromRGB(170, 170, 170)
    else
        Lighting.Brightness = savedLighting.Brightness
        Lighting.ClockTime = savedLighting.ClockTime
        Lighting.GlobalShadows = savedLighting.GlobalShadows
        Lighting.Ambient = savedLighting.Ambient
    end

    Lighting.FogEnd = Config.NoFog and 100000 or savedLighting.FogEnd
    Camera.FieldOfView = Config.CamFOV
end

--============================================================================
-- config file
--============================================================================

local function saveConfig()
    if type(writefile) ~= "function" then return false, "no file access" end
    local ok, err = pcall(function()
        writefile(CONFIG_PATH, HttpService:JSONEncode(Config))
    end)
    return ok, err
end

local function loadConfig()
    if type(isfile) ~= "function" or not isfile(CONFIG_PATH) then return false end
    local ok, data = pcall(function() return HttpService:JSONDecode(readfile(CONFIG_PATH)) end)
    if not ok or type(data) ~= "table" then return false end
    for k, v in pairs(data) do
        if Config[k] ~= nil and type(Config[k]) == type(v) then Config[k] = v end
    end
    return true
end

loadConfig()
applyMisc()

--============================================================================
-- menu
--============================================================================

local function diskFace(file, family, fallback)
    if type(getcustomasset) ~= "function" or type(isfile) ~= "function" then return fallback end
    local path = "aurora_fonts/" .. file
    if not isfile(path) then return fallback end
    local ok, f = pcall(function()
        local asset = getcustomasset(path)
        local famPath = "aurora_fonts/" .. family .. ".json"
        writefile(famPath, HttpService:JSONEncode({
            name = family,
            faces = { { name = "Regular", weight = 400, style = "normal", assetId = asset } },
        }))
        return Font.new(getcustomasset(famPath), Enum.FontWeight.Regular, Enum.FontStyle.Normal)
    end)
    return ok and f or fallback
end

local F_TITLE = diskFace("Pricedown.otf", "Pricedown",
    Font.new("rbxasset://fonts/families/Oswald.json"))
local F_BODY  = diskFace("ChaletLondon.ttf", "ChaletLondon",
    Font.new("rbxasset://fonts/families/Arimo.json"))
local F_HEAD  = diskFace("ChaletComprime.ttf", "ChaletComprime", F_BODY)

local function new(class, props, parent)
    local i = Instance.new(class)
    for k, v in pairs(props) do i[k] = v end
    if parent then i.Parent = parent end
    return i
end

local PANEL_W  = 360
local BANNER_H = 80
local SUB_H    = 28
local ROW_H    = 30
local MAX_ROWS = 10
local DESC_H   = 26
local HELP_H   = 22
local PAD_X    = 12

local screen = new("ScreenGui", {
    Name = "hypershot_ui",
    IgnoreGuiInset = true,
    ResetOnSpawn = false,
    DisplayOrder = 420,
}, GUI_HOST)

local root = new("Frame", {
    Size = UDim2.fromOffset(PANEL_W, BANNER_H + SUB_H + ROW_H * MAX_ROWS + DESC_H + HELP_H),
    Position = UDim2.fromOffset(48, 120),
    BackgroundTransparency = 1,
    Visible = false,
}, screen)

local banner = new("Frame", {
    Size = UDim2.new(1, 0, 0, BANNER_H),
    BackgroundColor3 = Color3.new(1, 1, 1),
    BorderSizePixel = 0,
}, root)

new("UIGradient", {
    Color = ColorSequence.new({
        ColorSequenceKeypoint.new(0.00, Color3.fromRGB(4, 63, 136)),
        ColorSequenceKeypoint.new(0.30, Color3.fromRGB(4, 63, 136)),
        ColorSequenceKeypoint.new(0.85, Color3.fromRGB(46, 114, 212)),
        ColorSequenceKeypoint.new(1.00, Color3.fromRGB(46, 114, 212)),
    }),
}, banner)

local bannerText = new("TextLabel", {
    Size = UDim2.fromScale(1, 1),
    BackgroundTransparency = 1,
    FontFace = F_TITLE,
    TextSize = 50,
    TextColor3 = Color3.new(1, 1, 1),
    Text = "Hypershot",
}, banner)

local subBar = new("Frame", {
    Size = UDim2.new(1, 0, 0, SUB_H),
    Position = UDim2.fromOffset(0, BANNER_H),
    BackgroundColor3 = Color3.new(0, 0, 0),
    BackgroundTransparency = 0.05,
    BorderSizePixel = 0,
}, root)

local subTitle = new("TextLabel", {
    Size = UDim2.new(1, -90, 1, 0),
    Position = UDim2.fromOffset(PAD_X, 0),
    BackgroundTransparency = 1,
    FontFace = F_HEAD,
    TextSize = 16,
    TextColor3 = Color3.new(1, 1, 1),
    TextXAlignment = Enum.TextXAlignment.Left,
    Text = "HYPERSHOT",
}, subBar)

local subCount = new("TextLabel", {
    Size = UDim2.fromOffset(78, SUB_H),
    Position = UDim2.new(1, -78 - PAD_X, 0, 0),
    BackgroundTransparency = 1,
    FontFace = F_HEAD,
    TextSize = 16,
    TextColor3 = Color3.new(1, 1, 1),
    TextXAlignment = Enum.TextXAlignment.Right,
    Text = "1 / 1",
}, subBar)

local LIST_Y = BANNER_H + SUB_H

local listArea = new("Frame", {
    Size = UDim2.new(1, 0, 0, ROW_H * MAX_ROWS),
    Position = UDim2.fromOffset(0, LIST_Y),
    BackgroundColor3 = Color3.new(0, 0, 0),
    BackgroundTransparency = 0.45,
    BorderSizePixel = 0,
    ClipsDescendants = true,
}, root)

local highlight = new("Frame", {
    Size = UDim2.new(1, 0, 0, ROW_H),
    BackgroundColor3 = Color3.new(1, 1, 1),
    BackgroundTransparency = 0.06,
    BorderSizePixel = 0,
    ZIndex = 1,
}, listArea)

local rows = {}
for i = 1, MAX_ROWS do
    local holder = new("Frame", {
        Size = UDim2.new(1, 0, 0, ROW_H),
        Position = UDim2.fromOffset(0, (i - 1) * ROW_H),
        BackgroundTransparency = 1,
        ZIndex = 2,
    }, listArea)

    local label = new("TextLabel", {
        Size = UDim2.new(1, -150, 1, 0),
        Position = UDim2.fromOffset(PAD_X, 0),
        BackgroundTransparency = 1,
        FontFace = F_BODY,
        TextSize = 15,
        TextColor3 = Color3.new(1, 1, 1),
        TextXAlignment = Enum.TextXAlignment.Left,
        TextTruncate = Enum.TextTruncate.AtEnd,
        Text = "",
        ZIndex = 2,
    }, holder)

    local value = new("TextLabel", {
        Size = UDim2.fromOffset(140, ROW_H),
        Position = UDim2.new(1, -140 - PAD_X, 0, 0),
        BackgroundTransparency = 1,
        FontFace = F_BODY,
        TextSize = 15,
        TextColor3 = Color3.new(1, 1, 1),
        TextXAlignment = Enum.TextXAlignment.Right,
        TextTruncate = Enum.TextTruncate.AtEnd,
        Text = "",
        ZIndex = 2,
    }, holder)

    rows[i] = { holder = holder, label = label, value = value }
end

local upArrow = new("TextLabel", {
    Size = UDim2.fromOffset(16, 14),
    Position = UDim2.new(1, -19, 0, 1),
    BackgroundTransparency = 1,
    FontFace = F_BODY,
    TextSize = 11,
    TextColor3 = Color3.fromRGB(180, 180, 190),
    Text = "^",
    Visible = false,
    ZIndex = 3,
}, listArea)

local downArrow = new("TextLabel", {
    Size = UDim2.fromOffset(16, 14),
    Position = UDim2.new(1, -19, 1, -15),
    BackgroundTransparency = 1,
    FontFace = F_BODY,
    TextSize = 11,
    TextColor3 = Color3.fromRGB(180, 180, 190),
    Text = "v",
    Visible = false,
    ZIndex = 3,
}, listArea)

local descBar = new("Frame", {
    Size = UDim2.new(1, 0, 0, DESC_H),
    Position = UDim2.fromOffset(0, LIST_Y + ROW_H * MAX_ROWS),
    BackgroundColor3 = Color3.new(0, 0, 0),
    BackgroundTransparency = 0.05,
    BorderSizePixel = 0,
}, root)

local descText = new("TextLabel", {
    Size = UDim2.new(1, -PAD_X * 2, 1, 0),
    Position = UDim2.fromOffset(PAD_X, 0),
    BackgroundTransparency = 1,
    FontFace = F_BODY,
    TextSize = 12,
    TextColor3 = Color3.new(1, 1, 1),
    TextXAlignment = Enum.TextXAlignment.Left,
    TextTruncate = Enum.TextTruncate.AtEnd,
    Text = "",
}, descBar)

local helpBar = new("Frame", {
    Size = UDim2.new(1, 0, 0, HELP_H),
    Position = UDim2.fromOffset(0, LIST_Y + ROW_H * MAX_ROWS + DESC_H),
    BackgroundColor3 = Color3.new(0, 0, 0),
    BackgroundTransparency = 0.05,
    BorderSizePixel = 0,
}, root)

new("TextLabel", {
    Size = UDim2.new(1, -PAD_X * 2, 1, 0),
    Position = UDim2.fromOffset(PAD_X, 0),
    BackgroundTransparency = 1,
    FontFace = F_BODY,
    TextSize = 11,
    TextColor3 = Color3.fromRGB(225, 225, 232),
    TextXAlignment = Enum.TextXAlignment.Left,
    Text = "Enter Select   Backspace Back   \226\134\145\226\134\147 Move   \226\134\144\226\134\146 Adjust",
}, helpBar)

--------------------------------------------------------------------- items
local function Header(label)           return { kind = "header", label = label } end
local function Info(label, fn)         return { kind = "info", label = label, textFn = fn } end
local function Sub(label, pageFn, desc) return { kind = "sub", label = label, pageFn = pageFn, desc = desc } end
local function Toggle(label, key, desc, onChange)
    return { kind = "toggle", label = label, key = key, desc = desc, onChange = onChange }
end
local function Cycle(label, key, options, desc, onChange)
    return { kind = "cycle", label = label, key = key, options = options, desc = desc, onChange = onChange }
end
local function Slider(label, key, min, max, step, dec, desc, onChange)
    return { kind = "slider", label = label, key = key, min = min, max = max,
             step = step, dec = dec or 0, desc = desc, onChange = onChange }
end
local function Action(label, fn, desc) return { kind = "action", label = label, fn = fn, desc = desc } end

local function selectable(item) return item.kind ~= "header" and item.kind ~= "info" end

local stack = {}
local render

local function currentFrame() return stack[#stack] end

local function pushPage(page)
    local idx = 1
    for i, it in ipairs(page.items) do
        if selectable(it) then idx = i break end
    end
    table.insert(stack, { page = page, index = idx, offset = 0 })
    render()
end

local function popPage()
    if #stack > 1 then
        table.remove(stack)
        render()
    end
end

--------------------------------------------------------------------- pages
local function aimPage()
    return { title = "Aimbot", subtitle = "Aimbot", items = {
        Info("status", function() return statusText end),
        Header("Aim"),
        Toggle("Enabled", "AimEnabled", "Master switch for the aim system."),
        Cycle("Mode", "AimMode", { "Silent", "Lock" },
            "Silent turns the camera only for the step the shot is sampled in, so the view never moves. Lock turns it for real."),
        Cycle("Engage", "Engage", { "Always", "Hold" },
            "Always runs with no key. Hold waits for the key below -- right click is ADS in this game, so Hold only aims while scoped."),
        Cycle("Key", "AimKey", { "MouseButton2", "MouseButton1", "E", "Q", "C", "X", "LeftAlt" },
            "The key Hold waits for."),
        Cycle("Bone", "Bone", { "Head", "Torso", "Root" },
            "The head box sits 1.757 studs above the root, the engine's own number."),
        Header("Limits"),
        Slider("FOV", "FOVDeg", 1, 180, 1, 0, "Degrees off your crosshair a target may sit."),
        Slider("Range", "Range", 50, 2000, 50, 0, "Furthest target, in studs."),
        Slider("Smoothness", "Smooth", 0.02, 1, 0.02, 2, "How hard the camera snaps. Lock only."),
        Toggle("Visible Only", "VisCheck", "Skip anything behind geometry."),
        Toggle("Sticky Target", "Sticky", "Hold the same body while it stays legal."),
    } }
end

local function targetPage()
    return { title = "Targets", subtitle = "Targets", items = {
        Info("entities", function()
            local n, bots = 0, 0
            for _, m in ipairs(ENTITIES:GetChildren()) do
                n += 1
                if m:GetAttribute("Bot") == true then bots += 1 end
            end
            return string.format("%d entities, %d bots, my team %s", n, bots, tostring(myTeam()))
        end),
        Header("Filters"),
        Toggle("Team Check", "TeamCheck", "Read off the Team attribute on the entity."),
        Toggle("Hit Players", "HitPlayers", "Real players count as targets."),
        Toggle("Hit Bots", "HitBots", "Bots carry a Bot attribute."),
    } }
end

local function espPage()
    return { title = "ESP", subtitle = "ESP", items = {
        Header("Draw"),
        Toggle("Enabled", "EspEnabled", "Master switch."),
        Toggle("Box", "EspBox", "Outline around the hitbox stack."),
        Toggle("Name", "EspName", "Entity name above the box."),
        Toggle("Health", "EspHealth", "Bar down the left, off the Health attribute."),
        Toggle("Distance", "EspInfo", "Distance and held weapon under the box."),
        Toggle("Tracer", "EspTracer", "Line from the bottom of the screen."),
        Toggle("Chams", "EspChams", "Highlight through walls."),
        Toggle("Draw Bots", "EspBots", "Include bots."),
        Header("Limits"),
        Slider("Max Distance", "EspMaxDist", 100, 3000, 100, 0, "Stop drawing past this."),
        Slider("Text Size", "EspTextSize", 8, 24, 1, 0, "Name and info size."),
    } }
end

local function miscPage()
    return { title = "Misc", subtitle = "Misc", items = {
        Header("World"),
        Toggle("Fullbright", "Fullbright", "Flatten the lighting.", applyMisc),
        Toggle("No Fog", "NoFog", "Push the fog out past the map.", applyMisc),
        Slider("Camera FOV", "CamFOV", 40, 120, 1, 0, "Field of view.", applyMisc),
    } }
end

-- filled in below, once rootPage exists to be read
local setMinecraftSkin

local function configPage()
    return { title = "Config", subtitle = "Config", items = {
        Header("Skin"),
        Toggle("Minecraft UI", "MinecraftUI",
            "Swap this menu for the minecraft inventory. Right shift opens it, and the "
            .. "redstone block on its hotbar brings this one back.",
            function(on) if setMinecraftSkin then setMinecraftSkin(on) end end),
        Header("File"),
        Action("Save Config", function()
            local ok, err = saveConfig()
            if not ok then error(tostring(err)) end
        end, "Writes every setting to " .. CONFIG_PATH .. "."),
        Action("Load Config", function()
            loadConfig()
            applyMisc()
            render()
        end, "Re-reads the saved file."),
        Header("Maintenance"),
        Action("Reset Target", function() currentTarget = nil end, "Drop the sticky target."),
        Action("Unload", function()
            if _G.__HYPERSHOT then _G.__HYPERSHOT() end
        end, "Remove the menu, the drawings and every hook."),
    } }
end

local function rootPage()
    return { title = "Hypershot", subtitle = "Hypershot", items = {
        Sub("Aimbot",  aimPage,    "Silent aim, bone selection, FOV and range."),
        Sub("Targets", targetPage, "Who counts as an enemy."),
        Sub("ESP",     espPage,    "Boxes, names, health, chams and tracers."),
        Sub("Misc",    miscPage,   "Lighting and camera."),
        Sub("Config",  configPage, "Save, load, unload."),
    } }
end

--============================================================================
-- minecraft skin
--  The inventory is a second FACE on this menu, not a second menu. It is given
--  the pages this module already builds -- every Sub becomes a page, every row
--  becomes an item -- so a feature added anywhere above shows up in both skins
--  with nothing else to write.
--============================================================================

local MC_URL = "https://raw.githubusercontent.com/hahajaiisiu22/aurora-assets/main/mcui.lua"

-- a word in the label picks the item. First hit wins, so the specific words
-- sit above the loose ones.
local MC_ICONS = {
    { "silent",   "crossbow" },       { "trigger",  "crossbow" },
    { "aim",      "diamond_sword" },  { "knife",    "diamond_sword" },
    { "weapon",   "diamond_sword" },  { "aura",     "tnt" },
    { "kill",     "tnt" },            { "fov",      "spyglass" },
    { "range",    "spyglass" },       { "wheel",    "compass" },
    { "tracer",   "compass" },        { "radar",    "compass" },
    { "esp",      "ender_eye" },      { "box",      "ender_eye" },
    { "name",     "ender_eye" },      { "cham",     "water_bucket" },
    { "skeleton", "arrow" },          { "bone",     "arrow" },
    { "target",   "arrow" },          { "ammo",     "arrow" },
    { "health",   "golden_apple" },   { "god",      "golden_apple" },
    { "coin",     "golden_apple" },   { "bright",   "glowstone_dust" },
    { "light",    "glowstone_dust" }, { "fog",      "glass_pane" },
    { "speed",    "diamond_boots" },  { "walk",     "diamond_boots" },
    { "jump",     "rabbit_foot" },    { "fly",      "elytra" },
    { "noclip",   "ender_pearl" },    { "teleport", "ender_pearl" },
    { "void",     "ender_pearl" },    { "reload",   "clock" },
    { "rate",     "clock" },          { "delay",    "clock" },
    { "smooth",   "clock" },          { "lead",     "clock" },
    { "anti",     "shield" },         { "wall",     "shield" },
    { "save",     "chest" },          { "load",     "chest" },
    { "script",   "enchanted_book" }, { "admin",    "enchanted_book" },
    { "rejoin",   "oak_boat" },       { "server",   "oak_boat" },
    { "hop",      "oak_boat" },       { "unload",   "barrier" },
    { "player",   "totem_of_undying" },{ "bot",     "totem_of_undying" },
    { "gun",      "crossbow" },       { "theme",    "redstone_block" },
}

local function mcIcon(label)
    local low = string.lower(tostring(label or ""))
    for _, pair in ipairs(MC_ICONS) do
        if string.find(low, pair[1], 1, true) then return pair[2] end
    end
    return "redstone_block"
end

-- headers, info lines and sub rows have no place in a grid of items
local MC_KINDS = { toggle = true, slider = true, cycle = true, action = true, picker = true }

local function mcPages()
    local pages = {}
    local root  = rootPage()

    for _, row in ipairs(root.items or {}) do
        if row.kind == "sub" and row.pageFn then
            local ok, page = pcall(row.pageFn)
            if ok and type(page) == "table" then
                local items = {}
                for _, it in ipairs(page.items or {}) do
                    if MC_KINDS[it.kind] then
                        local list = it.options or it.list
                        if not list and it.listFn then
                            local built, out = pcall(it.listFn)
                            list = built and out or nil
                        end
                        items[#items + 1] = {
                            kind     = (it.kind == "picker") and "cycle" or it.kind,
                            label    = it.label, key = it.key, desc = it.desc,
                            min      = it.min, max = it.max, step = it.step, dec = it.dec,
                            onChange = it.onChange, run = it.fn, list = list,
                            icon     = mcIcon(it.label),
                        }
                    end
                end
                if #items > 0 then
                    pages[#pages + 1] = { name = row.label, items = items }
                end
            end
        end
    end

    return pages
end

local function gtaSkin()
    Config.MinecraftUI = false
    if _G.AuroraMC then pcall(_G.AuroraMC.unload) end
    screen.Enabled = true
    pcall(render)
end

local function mcSpec()
    return {
        title     = rootPage().title,
        config    = Config,
        pages     = mcPages(),
        utilities = {
            { kind = "action", label = "GTA Menu", icon = "redstone_block",
              desc = "Back to the Aurora menu.", run = gtaSkin },
            { kind = "action", label = "Save Config", icon = "chest",
              desc = "Write every setting to disk.", run = function() pcall(saveConfig) end },
            { kind = "action", label = "Console", icon = "command_block",
              desc = "The command bar. Not wired up yet.", run = function() end },
            { kind = "action", label = "Unload", icon = "barrier",
              desc = "Remove the menu and every hook.",
              run = function() if _G.__HYPERSHOT then _G.__HYPERSHOT() end end },
        },
    }
end

-- assigned, not declared: the forward local sits above configPage so the
-- toggle there can reach it
setMinecraftSkin = function(on)
    if not on then gtaSkin() return end

    screen.Enabled = false

    if _G.AuroraMC then
        _G.AuroraMC.mount(mcSpec())
        _G.AuroraMC.setOpen(true)
        return
    end

    -- HttpGet pauses mid call and an executor's script thread is not always
    -- allowed to, so the fetch gets a thread of its own. The stamp is there
    -- because a caching http layer will hand back an old copy forever.
    task.spawn(function()
        local got, src = pcall(function()
            return game:HttpGet(MC_URL .. "?t=" .. tostring(os.time()))
        end)
        if not got or type(src) ~= "string" or #src < 10000 then
            Config.MinecraftUI = false
            screen.Enabled = true
            return
        end

        _G.AURORA_MC_SPEC = mcSpec()
        local chunk = loadstring(src)
        if chunk then pcall(chunk) end
        _G.AURORA_MC_SPEC = nil

        if _G.AuroraMC then
            pcall(_G.AuroraMC.setOpen, true)
        else
            Config.MinecraftUI = false
            screen.Enabled = true
        end
    end)
end

--------------------------------------------------------------------- render
local function valueText(item)
    if item.kind == "sub" then return ">>>" end
    if item.kind == "toggle" then return Config[item.key] and "ON" or "OFF" end
    if item.kind == "cycle" then return tostring(Config[item.key]) end
    if item.kind == "slider" then return string.format("%." .. item.dec .. "f", Config[item.key]) end
    return ""
end

function render()
    local f = currentFrame()
    if not f then return end
    local page, items = f.page, f.page.items

    if f.index < f.offset + 1 then f.offset = f.index - 1 end
    if f.index > f.offset + MAX_ROWS then f.offset = f.index - MAX_ROWS end
    f.offset = math.clamp(f.offset, 0, math.max(0, #items - MAX_ROWS))

    local shown = math.clamp(#items, 1, MAX_ROWS)
    listArea.Size = UDim2.new(1, 0, 0, ROW_H * shown)
    descBar.Position = UDim2.fromOffset(0, LIST_Y + ROW_H * shown)
    helpBar.Position = UDim2.fromOffset(0, LIST_Y + ROW_H * shown + DESC_H)
    root.Size = UDim2.fromOffset(PANEL_W, LIST_Y + ROW_H * shown + DESC_H + HELP_H)

    bannerText.Text = page.title
    subTitle.Text = string.upper(page.subtitle or page.title)

    local total, seen = 0, 0
    for i, it in ipairs(items) do
        if selectable(it) then
            total += 1
            if i <= f.index then seen = total end
        end
    end
    subCount.Text = string.format("%d / %d", seen, total)

    upArrow.Visible = f.offset > 0
    downArrow.Visible = (f.offset + MAX_ROWS) < #items

    for r = 1, MAX_ROWS do
        local item = items[f.offset + r]
        local ui = rows[r]

        if not item then
            ui.holder.Visible = false
        else
            ui.holder.Visible = true
            local sel = (f.offset + r) == f.index

            if item.kind == "header" then
                ui.label.FontFace = F_HEAD
                ui.label.TextSize = 14
                ui.label.TextColor3 = Color3.fromRGB(100, 170, 255)
                ui.label.Text = string.upper(item.label)
                ui.value.Text = ""
            elseif item.kind == "info" then
                ui.label.FontFace = F_BODY
                ui.label.TextSize = 12
                ui.label.TextColor3 = Color3.fromRGB(170, 170, 182)
                ui.label.Text = item.textFn and item.textFn() or item.label
                ui.value.Text = ""
            else
                ui.label.FontFace = F_BODY
                ui.label.TextSize = 15
                ui.label.TextColor3 = sel and Color3.new(0, 0, 0) or Color3.new(1, 1, 1)
                ui.label.Text = item.label
                ui.value.TextColor3 = sel and Color3.new(0, 0, 0) or Color3.new(1, 1, 1)
                ui.value.Text = valueText(item)
            end
        end
    end

    local visRow = f.index - f.offset
    highlight.Visible = visRow >= 1 and visRow <= MAX_ROWS
    highlight.Position = UDim2.fromOffset(0, (visRow - 1) * ROW_H)

    local sel = items[f.index]
    descText.Text = (sel and sel.desc) or ""
end

--------------------------------------------------------------------- input
local function move(dir)
    local f = currentFrame()
    if not f then return end
    local items = f.page.items
    local i = f.index
    for _ = 1, #items do
        i += dir
        if i < 1 then i = #items elseif i > #items then i = 1 end
        if selectable(items[i]) then break end
    end
    f.index = i
    render()
end

local function adjust(dir)
    local f = currentFrame()
    if not f then return end
    local item = f.page.items[f.index]
    if not item then return end

    if item.kind == "toggle" then
        Config[item.key] = not Config[item.key]
    elseif item.kind == "cycle" then
        local cur, at = tostring(Config[item.key]), 1
        for i, o in ipairs(item.options) do if tostring(o) == cur then at = i break end end
        Config[item.key] = item.options[((at - 1 + dir) % #item.options) + 1]
    elseif item.kind == "slider" then
        Config[item.key] = math.clamp(Config[item.key] + item.step * dir, item.min, item.max)
    else
        return
    end

    if item.onChange then task.spawn(item.onChange, Config[item.key]) end
    render()
end

local function activate()
    local f = currentFrame()
    if not f then return end
    local item = f.page.items[f.index]
    if not item then return end

    if item.kind == "sub" then
        pushPage(item.pageFn())
    elseif item.kind == "toggle" or item.kind == "cycle" or item.kind == "slider" then
        adjust(1)
    elseif item.kind == "action" then
        local ok, err = pcall(item.fn)
        if not ok then descText.Text = "error: " .. tostring(err):sub(1, 70) end
    end
end

local function jumpTo(letter)
    local f = currentFrame()
    if not f then return end
    for i, it in ipairs(f.page.items) do
        if selectable(it) and it.label and string.lower(it.label:sub(1, 1)) == letter then
            f.index = i
            render()
            return
        end
    end
end

pushPage(rootPage())

-- The arrow keys drive the character through the engine's own CAS binding, and
-- UserInputService cannot stop that -- it only listens. So while the panel is
-- up the four keys are taken at a higher CAS priority and sunk; the menu still
-- reads them through InputBegan, the character never sees them. Unbound on
-- close, so movement comes straight back.
local NAV_SINK = "hypershot_nav_sink"
local NAV_SINK_KEYS = {
    Enum.KeyCode.Up, Enum.KeyCode.Down, Enum.KeyCode.Left, Enum.KeyCode.Right,
}

local function sinkNav()
    return Enum.ContextActionResult.Sink
end

local function bindNavSink()
    ContextActionService:BindActionAtPriority(
        NAV_SINK, sinkNav, false,
        Enum.ContextActionPriority.High.Value + 1000,
        table.unpack(NAV_SINK_KEYS))
end

local function unbindNavSink()
    pcall(function() ContextActionService:UnbindAction(NAV_SINK) end)
end

track(UserInputService.InputBegan:Connect(function(input, processed)
    if UserInputService:GetFocusedTextBox() then return end

    local k = input.KeyCode
    if k == Enum.KeyCode.Insert or k == Enum.KeyCode.Delete then
        root.Visible = not root.Visible
        if root.Visible then bindNavSink() render() else unbindNavSink() end
        return
    end

    if not root.Visible then return end

    if k == Enum.KeyCode.Up then move(-1)
    elseif k == Enum.KeyCode.Down then move(1)
    elseif k == Enum.KeyCode.Left then adjust(-1)
    elseif k == Enum.KeyCode.Right then adjust(1)
    elseif k == Enum.KeyCode.Return or k == Enum.KeyCode.KeypadEnter then activate()
    elseif k == Enum.KeyCode.Backspace then popPage()
    elseif #k.Name == 1 then jumpTo(string.lower(k.Name)) end
end))

-- the info rows are live, so the open page is repainted on a slow tick
track(RunService.Heartbeat:Connect(function()
    if not root.Visible then return end
    local f = currentFrame()
    if not f then return end
    for r = 1, MAX_ROWS do
        local item = f.page.items[f.offset + r]
        if item and item.kind == "info" and item.textFn then
            local ok, text = pcall(item.textFn)
            rows[r].label.Text = ok and tostring(text) or ""
        end
    end
end))

-- drag by the banner
do
    local dragging, startPos, startAt
    banner.InputBegan:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1 then
            dragging, startPos, startAt = true, i.Position, root.Position
        end
    end)
    banner.InputEnded:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1 then dragging = false end
    end)
    track(UserInputService.InputChanged:Connect(function(i)
        if dragging and i.UserInputType == Enum.UserInputType.MouseMovement then
            local d = i.Position - startPos
            root.Position = UDim2.fromOffset(startAt.X.Offset + d.X, startAt.Y.Offset + d.Y)
        end
    end))
end

--============================================================================
-- exports + teardown
--============================================================================

_G.Hypershot = {
    Config = Config,
    Status = function() return statusText end,
    Target = function() return currentTarget end,
    Local  = localEntity,
    Menu = { Open = function() root.Visible = true bindNavSink() render() end,
             Close = function() root.Visible = false unbindNavSink() end,
             Draw = function() render() end,
             Move = move, Adjust = adjust, Select = activate, Back = popPage,
             Page = function()
                 local f = currentFrame()
                 return f and f.page.title, f and f.index
             end },
}

_G.__HYPERSHOT = function()
    pcall(function() RunService:UnbindFromRenderStep(AIM_BIND) end)
    pcall(function() RunService:UnbindFromRenderStep(ESP_BIND) end)
    pcall(function() RunService:UnbindFromRenderStep(RESTORE_BIND) end)
    for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
    for model in pairs(drawings) do pcall(chamsFor, model, false) end
    pcall(unbindNavSink)
    pcall(function() espGui:Destroy() end)
    pcall(function() screen:Destroy() end)
    Config.Fullbright, Config.NoFog = false, false
    pcall(applyMisc)
    _G.Hypershot, _G.__HYPERSHOT = nil, nil
end

print("[hypershot] loaded -- INSERT or DELETE for the menu")
