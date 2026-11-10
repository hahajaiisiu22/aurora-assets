--[[
    mm2.lua  --  Murder Mystery 2

    The features come from his own 13,600 line MM2 build (@vxmpingz_, v2.0);
    this is that script's working knowledge rebuilt on the Aurora menu, with
    the dead weight left out. What was kept and why is in the comments below.

    ROLE. There is no role attribute in MM2. The murderer is whoever holds a
    tool named "Knife" and the sheriff whoever holds one named "Gun" -- check
    the character for the equipped tool and the backpack for the stowed one.
    An innocent is simply neither.

    SHOOTING. The gun fires Shoot:FireServer(originCFrame, hitCFrame), with the
    remote living inside the Gun tool itself. The knife throws the same shape
    through Knife.Events.KnifeThrown. Because both carry the aim point as an
    argument, silent aim is a rewrite of those two arguments rather than a
    camera trick: the shot goes where we say and the view never moves.

    THE SERVER RE-RAYCASTS from origin to hit, which is why leading a moving
    target makes it MISS -- the server ray reaches an empty spot. So the hit
    point is the target's live root with zero lead, and lead is left as an
    option for the rare server that does not re-cast.

    KILL AURA is hitbox work, not a remote: every other player's root is grown
    to 100 studs and the local character is made non-colliding, so a swing
    anywhere lands. Every part's original size and collision is remembered per
    part -- R15 and custom rigs are not 2,2,1, and a hardcoded restore mangles
    them permanently.

    Menu: INSERT or DELETE.  Arrows move, Enter selects, Backspace goes back.
]]

local Players          = game:GetService("Players")
local RunService       = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TweenService     = game:GetService("TweenService")
local HttpService      = game:GetService("HttpService")
local Lighting         = game:GetService("Lighting")
local TeleportService  = game:GetService("TeleportService")
local ContextActionService = game:GetService("ContextActionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LocalPlayer = Players.LocalPlayer
local Camera      = workspace.CurrentCamera
local GUI_HOST    = (gethui and gethui()) or game:GetService("CoreGui")

if _G.__MM2 then pcall(_G.__MM2) end

-- workspace.CurrentCamera can be REPLACED at runtime, by a respawn or by an
-- admin script's fling. A cached reference then points at a discarded camera
-- and every write silently does nothing, which reads as "it broke forever".
local conns = {}
local function track(c) table.insert(conns, c) return c end

track(workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
    if workspace.CurrentCamera then Camera = workspace.CurrentCamera end
end))

--============================================================================
-- config
--============================================================================

local CONFIG_PATH = "mm2_config.json"

local Config = {
    -- murderer
    KillAura     = false,
    AuraRadius   = 30,
    SilentKnife  = false,
    KnifeWalls   = false,

    -- sheriff
    AimLock      = false,
    SilentAim    = false,
    AimWalls     = false,
    AutoShoot    = false,
    UseLead      = false,
    LeadMs       = 120,
    AimKey       = "MouseButton2",
    AimEngage    = "Always",

    -- innocent
    GunEsp       = true,
    CoinEsp      = false,

    -- visuals
    RoleEsp      = true,
    EspBox       = true,
    EspName      = true,
    EspRole      = true,
    EspDistance  = true,
    EspTracer    = false,
    EspChams     = false,
    EspMaxDist   = 2000,
    Fullbright   = false,
    XRay         = false,

    -- godlies
    GodlyKnife   = "None",
    GodlyGun     = "None",

    -- movement
    FlySpeed     = 60,
    WalkSpeed    = 16,
    JumpPower    = 50,
    InfJump      = false,
    Noclip       = false,
}

local statusText = "idle"

--============================================================================
-- roles
--============================================================================

local function hasTool(plr, name)
    local char = plr.Character
    if char and char:FindFirstChild(name) then return true end
    local bp = plr:FindFirstChild("Backpack")
    if bp and bp:FindFirstChild(name) then return true end
    return false
end

local function roleOf(plr)
    if hasTool(plr, "Knife") then return "Murderer" end
    if hasTool(plr, "Gun") then return "Sheriff" end
    return "Innocent"
end

local ROLE_COLOR = {
    Murderer = Color3.fromRGB(255, 60, 60),
    Sheriff  = Color3.fromRGB(60, 150, 255),
    Innocent = Color3.fromRGB(90, 220, 120),
}

local function myRole() return roleOf(LocalPlayer) end

local function aliveRoot(plr)
    local char = plr.Character
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    if not hum or hum.Health <= 0 then return nil end
    return char:FindFirstChild("HumanoidRootPart"), char, hum
end

local function findMurderer()
    for _, plr in ipairs(Players:GetPlayers()) do
        if plr ~= LocalPlayer and hasTool(plr, "Knife") then
            local root = aliveRoot(plr)
            if root then return plr, root end
        end
    end
    return nil
end

local function myRoot()
    local char = LocalPlayer.Character
    return char and char:FindFirstChild("HumanoidRootPart"), char
end

--============================================================================
-- the aim snapshot
--============================================================================

-- Heartbeat keeps this fresh so the namecall rewrite does arithmetic only --
-- an error raised inside a hook surfaces in the GAME's script and kills the
-- shot, so the hook must never do real work.
local snap = nil

local function refreshSnap()
    local plr, root = findMurderer()
    if not plr or not root then snap = nil return end

    local prev = snap
    local vel = root.AssemblyLinearVelocity
    snap = {
        char = root.Parent,
        name = plr.Name,
        pos = root.Position,
        vel = vel,
        stamp = os.clock(),
        lead = Config.LeadMs / 1000,
    }
    if prev and prev.char ~= snap.char then statusText = "target " .. plr.Name end
end

local function leadPoint(s)
    if not s then return nil end
    local t = s.lead + (os.clock() - s.stamp)
    return s.pos + Vector3.new(s.vel.X, 0, s.vel.Z) * t
end

-- the live root is a frame fresher than the snapshot, and with the server
-- re-raycasting it is also the only point that actually connects
local function hitPoint(s)
    if not s then return nil end
    if Config.UseLead then return leadPoint(s) end
    local root = s.char and s.char:FindFirstChild("HumanoidRootPart")
    return (root and root.Position) or leadPoint(s)
end

--============================================================================
-- silent aim: rewrite the two CFrames the game already sends
--============================================================================

local hookInstalled = false
local hookError = nil

local function installHook()
    if hookInstalled then return true end
    if type(getrawmetatable) ~= "function" or type(setreadonly) ~= "function"
        or type(getnamecallmethod) ~= "function" then
        hookError = "executor has no metatable access"
        return false
    end

    local ok, err = pcall(function()
        local mt = getrawmetatable(game)
        setreadonly(mt, false)
        local original = mt.__namecall

        mt.__namecall = function(self, ...)
            -- everything inside is wrapped: a raised error here would be
            -- raised in the gun's script and eat the shot
            if (Config.SilentAim or Config.SilentKnife) and getnamecallmethod() == "FireServer" then
                local good, newOrigin, newHit = pcall(function(origin, hit)
                    if typeof(origin) ~= "CFrame" or typeof(hit) ~= "CFrame" then return nil end
                    if type(checkcaller) == "function" and checkcaller() then return nil end

                    local lowered = string.lower(tostring(self))
                    local walls
                    if Config.SilentAim and string.find(lowered, "shoot", 1, true) then
                        walls = Config.AimWalls
                    elseif Config.SilentKnife and string.find(lowered, "throw", 1, true) then
                        walls = Config.KnifeWalls
                    else
                        return nil
                    end

                    -- a snapshot older than half a second means its Heartbeat
                    -- stopped: never spoof to a stale position
                    if not snap or os.clock() - snap.stamp > 0.5 then return nil end

                    local target = hitPoint(snap)
                    if not target then return nil end

                    -- the origin stays at the real muzzle: moving it trips
                    -- MM2's own origin check and locks the gun. Only the
                    -- through-walls option moves it, and only point blank.
                    local from = origin.Position
                    if walls then
                        local away = from - target
                        from = target + (away.Magnitude > 0.01 and away.Unit or Vector3.new(0, 0, 1)) * 2
                    end

                    return CFrame.lookAt(from, target), CFrame.new(target)
                end, ...)

                if good and newOrigin then
                    return original(self, newOrigin, newHit, select(3, ...))
                end
            end

            return original(self, ...)
        end

        setreadonly(mt, true)
        hookInstalled = true
        _G.__MM2_UNHOOK = function()
            local m = getrawmetatable(game)
            setreadonly(m, false)
            m.__namecall = original
            setreadonly(m, true)
        end
    end)

    if not ok then hookError = tostring(err) end
    return hookInstalled
end

--============================================================================
-- sheriff
--============================================================================

local function gunTool()
    local char = LocalPlayer.Character
    local bp = LocalPlayer:FindFirstChild("Backpack")
    return (char and char:FindFirstChild("Gun")) or (bp and bp:FindFirstChild("Gun"))
end

local function shootRemote()
    local gun = gunTool()
    if not gun then return nil end
    for _, d in ipairs(gun:GetDescendants()) do
        if d:IsA("RemoteEvent") and d.Name:lower():find("shoot", 1, true) then return d end
    end
    return nil
end

local autoShootNext = 0

local function autoShootTick()
    if not Config.AutoShoot then return end
    if os.clock() < autoShootNext then return end
    if not snap then return end

    local remote = shootRemote()
    local root = myRoot()
    if not remote or not root then return end

    local target = hitPoint(snap)
    if not target then return end

    -- our own call, not a rewrite, so it needs no hook at all
    local away = root.Position - target
    local origin = target + (away.Magnitude > 0.01 and away.Unit or Vector3.new(0, 0, 1)) * 2

    pcall(function()
        remote:FireServer(CFrame.lookAt(origin, target), CFrame.new(target))
    end)

    autoShootNext = os.clock() + 1.1
    statusText = "shot at " .. tostring(snap.name)
end

local function aimKeyDown()
    if Config.AimEngage == "Always" then return true end
    local name = Config.AimKey
    if name:find("Mouse") then
        return UserInputService:IsMouseButtonPressed(Enum.UserInputType[name])
    end
    local ok, e = pcall(function() return Enum.KeyCode[name] end)
    return ok and UserInputService:IsKeyDown(e) or false
end

local AIM_BIND = "mm2_aim"

local function aimLockStep()
    if not Config.AimLock or not aimKeyDown() then return end
    if not snap then return end
    local target = hitPoint(snap)
    if not target then return end
    Camera.CFrame = CFrame.lookAt(Camera.CFrame.Position, target)
end

pcall(function() RunService:UnbindFromRenderStep(AIM_BIND) end)
RunService:BindToRenderStep(AIM_BIND, Enum.RenderPriority.Camera.Value + 10, aimLockStep)

--============================================================================
-- murderer: kill aura
--============================================================================

-- restore state is captured PER PART, never assumed: stock R6 roots are 2,2,1
-- but R15 and custom rigs are not, and a hardcoded restore mangles them
local auraSizes, auraCollide = {}, {}
local auraArmed = false

local clickOnce = (function()
    local cached
    return function()
        if cached then return cached() end
        local env = (type(getgenv) == "function" and getgenv()) or _G
        local single = rawget(env, "mouse1click")
        if type(single) == "function" then cached = single return cached() end

        local down, up = rawget(env, "mouse1press"), rawget(env, "mouse1release")
        if type(down) == "function" and type(up) == "function" then
            cached = function() down() task.wait(0.01) up() end
            return cached()
        end

        local vim = game:GetService("VirtualInputManager")
        cached = function()
            vim:SendMouseButtonEvent(0, 0, 0, true, game, 0)
            vim:SendMouseButtonEvent(0, 0, 0, false, game, 0)
        end
        return cached()
    end
end)()

local function armAura()
    if auraArmed then return end
    auraArmed = true

    local char = LocalPlayer.Character
    table.clear(auraCollide)
    if char then
        local bp = LocalPlayer:FindFirstChild("Backpack")
        local knife = char:FindFirstChild("Knife") or (bp and bp:FindFirstChild("Knife"))
        if knife and knife.Parent ~= char then knife.Parent = char end
        for _, part in ipairs(char:GetDescendants()) do
            if part:IsA("BasePart") then
                auraCollide[part] = part.CanCollide
                part.CanCollide = false
            end
        end
    end

    table.clear(auraSizes)
    for _, plr in ipairs(Players:GetPlayers()) do
        if plr ~= LocalPlayer and plr.Character then
            local root = plr.Character:FindFirstChild("HumanoidRootPart")
            if root then
                auraSizes[root] = { size = root.Size, transparency = root.Transparency }
                root.Size = Vector3.new(100, 100, 100)
                root.Transparency = 0.9
            end
        end
    end

    statusText = "kill aura armed"
end

local function disarmAura()
    if not auraArmed then return end
    auraArmed = false

    for part, was in pairs(auraCollide) do
        if part and part.Parent then part.CanCollide = was end
    end
    table.clear(auraCollide)

    for root, saved in pairs(auraSizes) do
        if root and root.Parent then
            root.Size = saved.size
            root.Transparency = saved.transparency
        end
    end
    table.clear(auraSizes)

    statusText = "kill aura off"
end

local auraNext = 0

local function auraTick()
    if not Config.KillAura then
        if auraArmed then disarmAura() end
        return
    end

    -- it only arms while the knife is actually in hand, so an innocent round
    -- never leaves every hitbox in the server blown up
    if not hasTool(LocalPlayer, "Knife") then
        if auraArmed then disarmAura() end
        return
    end

    if not auraArmed then armAura() end

    local root = myRoot()
    if not root or os.clock() < auraNext then return end

    for _, plr in ipairs(Players:GetPlayers()) do
        if plr ~= LocalPlayer then
            local theirRoot = aliveRoot(plr)
            if theirRoot and (theirRoot.Position - root.Position).Magnitude <= Config.AuraRadius then
                pcall(clickOnce)
                auraNext = os.clock() + 0.12
                break
            end
        end
    end
end

--============================================================================
-- innocent: gun drops
--============================================================================

local dropSet = {}

local function watchDrops()
    local function consider(obj)
        if obj.Name == "GunDrop" then dropSet[obj] = true end
    end
    for _, obj in ipairs(workspace:GetDescendants()) do consider(obj) end
    track(workspace.DescendantAdded:Connect(consider))
end
watchDrops()

local function gunDrops()
    local out = {}
    for obj in pairs(dropSet) do
        if obj.Parent and obj:IsDescendantOf(workspace) then
            local part = (obj:IsA("BasePart") and obj)
                or (obj:IsA("Model") and (obj.PrimaryPart or obj:FindFirstChildWhichIsA("BasePart", true)))
                or (obj:IsA("Tool") and obj:FindFirstChild("Handle"))
            if part then table.insert(out, part) end
        else
            dropSet[obj] = nil
        end
    end
    return out
end

-- go, wait for the pickup, come back. Standing on the drop is what picks it
-- up, so the return trip only happens once the tool is actually in hand.
local function teleportToGun()
    local drops = gunDrops()
    if #drops == 0 then return false, "no gun drops" end

    local root = myRoot()
    if not root then return false, "no character" end

    local saved = root.Position
    local nearest, best = nil, math.huge
    for _, d in ipairs(drops) do
        local dist = (d.Position - saved).Magnitude
        if dist < best then nearest, best = d, dist end
    end
    if not nearest then return false, "no drop" end

    root.CFrame = CFrame.new(nearest.Position + Vector3.new(0, 3, 0))

    task.spawn(function()
        local t0 = tick()
        while tick() - t0 < 5 do
            if hasTool(LocalPlayer, "Gun") then break end
            if not nearest.Parent then break end
            task.wait(0.2)
        end
        local r = myRoot()
        if r then r.CFrame = CFrame.new(saved) end
    end)

    return true
end

local function coinParts()
    local out = {}
    for _, obj in ipairs(workspace:GetDescendants()) do
        if obj:IsA("BasePart") and obj.Name == "Coin_Server" then table.insert(out, obj) end
    end
    return out
end

--============================================================================
-- esp
--============================================================================

local espGui = Instance.new("ScreenGui")
espGui.Name = "mm2_esp"
espGui.IgnoreGuiInset = true
espGui.ResetOnSpawn = false
espGui.DisplayOrder = 400
espGui.Parent = GUI_HOST

local drawings = {}

local function makeLabel(size, bold)
    local l = Instance.new("TextLabel")
    l.BackgroundTransparency = 1
    l.Size = UDim2.fromOffset(240, 14)
    l.Font = bold and Enum.Font.GothamBold or Enum.Font.Gotham
    l.TextSize = size
    l.TextColor3 = Color3.new(1, 1, 1)
    l.TextStrokeTransparency = 0.4
    l.Visible = false
    l.Parent = espGui
    return l
end

local function drawingFor(key)
    local d = drawings[key]
    if d and d.box.Parent then return d end

    local box = Instance.new("Frame")
    box.BackgroundTransparency = 1
    box.BorderSizePixel = 0
    box.Visible = false
    box.Parent = espGui
    local stroke = Instance.new("UIStroke")
    stroke.Thickness = 1.4
    stroke.Parent = box

    local tracer = Instance.new("Frame")
    tracer.BorderSizePixel = 0
    tracer.AnchorPoint = Vector2.new(0.5, 0)
    tracer.Visible = false
    tracer.Parent = espGui

    d = { box = box, stroke = stroke, tracer = tracer,
          name = makeLabel(13, true), info = makeLabel(12, false) }
    drawings[key] = d
    return d
end

local function hide(d)
    d.box.Visible, d.name.Visible, d.info.Visible, d.tracer.Visible = false, false, false, false
end

local function chams(char, colour)
    local hl = char:FindFirstChild("mm2_chams")
    if not colour then
        if hl then hl:Destroy() end
        return
    end
    if not hl then
        hl = Instance.new("Highlight")
        hl.Name = "mm2_chams"
        hl.FillTransparency = 0.6
        hl.OutlineTransparency = 0.1
        hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
        hl.Parent = char
    end
    hl.FillColor = colour
    hl.OutlineColor = colour
end

local ESP_BIND = "mm2_esp"

local function espStep()
    local seen = {}
    local origin = Camera.CFrame.Position
    local vw = Camera.ViewportSize

    if Config.RoleEsp then
        for _, plr in ipairs(Players:GetPlayers()) do
            if plr ~= LocalPlayer then
                local root, char = aliveRoot(plr)
                if root then
                    local dist = (root.Position - origin).Magnitude
                    if dist <= Config.EspMaxDist then
                        local top, onScreen = Camera:WorldToViewportPoint(root.Position + Vector3.new(0, 3, 0))
                        local bottom = Camera:WorldToViewportPoint(root.Position - Vector3.new(0, 3.2, 0))

                        if onScreen then
                            seen[plr] = true
                            local d = drawingFor(plr)
                            local role = roleOf(plr)
                            local colour = ROLE_COLOR[role]

                            local height = math.abs(bottom.Y - top.Y)
                            local width = height * 0.5
                            local x, y = top.X - width / 2, top.Y

                            d.box.Visible = Config.EspBox
                            d.box.Position = UDim2.fromOffset(x, y)
                            d.box.Size = UDim2.fromOffset(width, height)
                            d.stroke.Color = colour

                            d.name.Visible = Config.EspName
                            d.name.Position = UDim2.fromOffset(x + width / 2 - 120, y - 16)
                            d.name.Text = plr.Name
                            d.name.TextColor3 = colour

                            d.info.Visible = Config.EspRole or Config.EspDistance
                            d.info.Position = UDim2.fromOffset(x + width / 2 - 120, y + height + 2)
                            d.info.TextColor3 = colour
                            d.info.Text = (Config.EspRole and role or "")
                                .. ((Config.EspRole and Config.EspDistance) and "  " or "")
                                .. (Config.EspDistance and string.format("%.0fm", dist) or "")

                            d.tracer.Visible = Config.EspTracer
                            if Config.EspTracer then
                                local sx, sy = vw.X / 2, vw.Y
                                local dx, dy = top.X - sx, (y + height) - sy
                                local len = math.sqrt(dx * dx + dy * dy)
                                d.tracer.BackgroundColor3 = colour
                                d.tracer.Size = UDim2.fromOffset(1, len)
                                d.tracer.Position = UDim2.fromOffset(sx, sy)
                                d.tracer.Rotation = math.deg(math.atan2(dy, dx)) - 90
                            end

                            chams(char, Config.EspChams and colour or nil)
                        end
                    end
                end
            end
        end
    end

    if Config.GunEsp then
        for _, part in ipairs(gunDrops()) do
            local pos, onScreen = Camera:WorldToViewportPoint(part.Position)
            if onScreen then
                seen[part] = true
                local d = drawingFor(part)
                d.name.Visible = true
                d.name.Position = UDim2.fromOffset(pos.X - 120, pos.Y)
                d.name.Text = "GUN"
                d.name.TextColor3 = Color3.fromRGB(255, 215, 80)
                d.info.Visible = true
                d.info.Position = UDim2.fromOffset(pos.X - 120, pos.Y + 14)
                d.info.Text = string.format("%.0fm", (part.Position - origin).Magnitude)
                d.info.TextColor3 = Color3.fromRGB(255, 215, 80)
            end
        end
    end

    if Config.CoinEsp then
        for _, part in ipairs(coinParts()) do
            local pos, onScreen = Camera:WorldToViewportPoint(part.Position)
            if onScreen and (part.Position - origin).Magnitude <= 400 then
                seen[part] = true
                local d = drawingFor(part)
                d.name.Visible = true
                d.name.Position = UDim2.fromOffset(pos.X - 120, pos.Y)
                d.name.Text = "$"
                d.name.TextColor3 = Color3.fromRGB(255, 230, 120)
            end
        end
    end

    for key, d in pairs(drawings) do
        if not seen[key] then
            if typeof(key) == "Instance" and key:IsA("Player") and key.Character then
                chams(key.Character, nil)
            end
            local gone = (typeof(key) == "Instance") and not key.Parent
            if gone then
                for _, obj in pairs(d) do
                    if typeof(obj) == "Instance" then obj:Destroy() end
                end
                drawings[key] = nil
            else
                hide(d)
            end
        end
    end
end

pcall(function() RunService:UnbindFromRenderStep(ESP_BIND) end)
RunService:BindToRenderStep(ESP_BIND, Enum.RenderPriority.Last.Value, espStep)

--============================================================================
-- world + movement
--============================================================================

local savedLighting = {
    Brightness = Lighting.Brightness,
    ClockTime = Lighting.ClockTime,
    FogEnd = Lighting.FogEnd,
    GlobalShadows = Lighting.GlobalShadows,
    Ambient = Lighting.Ambient,
}

local xrayTouched = {}

local function applyWorld()
    if Config.Fullbright then
        Lighting.Brightness = 3
        Lighting.ClockTime = 14
        Lighting.GlobalShadows = false
        Lighting.FogEnd = 100000
        Lighting.Ambient = Color3.fromRGB(170, 170, 170)
    else
        Lighting.Brightness = savedLighting.Brightness
        Lighting.ClockTime = savedLighting.ClockTime
        Lighting.GlobalShadows = savedLighting.GlobalShadows
        Lighting.FogEnd = savedLighting.FogEnd
        Lighting.Ambient = savedLighting.Ambient
    end

    if Config.XRay then
        for _, part in ipairs(workspace:GetDescendants()) do
            if part:IsA("BasePart") and part.Transparency < 1
                and not part:IsDescendantOf(LocalPlayer.Character or workspace)
                and not Players:GetPlayerFromCharacter(part.Parent) then
                if xrayTouched[part] == nil then xrayTouched[part] = part.Transparency end
                part.Transparency = 0.75
            end
        end
    else
        for part, was in pairs(xrayTouched) do
            if part and part.Parent then part.Transparency = was end
        end
        table.clear(xrayTouched)
    end
end

local function applyChar()
    local _, char = myRoot()
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    if not hum then return end
    hum.WalkSpeed = Config.WalkSpeed
    hum.JumpPower = Config.JumpPower
    hum.UseJumpPower = true
end

track(LocalPlayer.CharacterAdded:Connect(function()
    task.wait(1)
    pcall(applyChar)
end))

-- noclip has to be re-applied every step: the engine turns collision back on
-- for parts it re-streams, and a one-shot pass drops through only once
track(RunService.Stepped:Connect(function()
    if not Config.Noclip then return end
    local _, char = myRoot()
    if not char then return end
    for _, part in ipairs(char:GetDescendants()) do
        if part:IsA("BasePart") and part.CanCollide then part.CanCollide = false end
    end
end))

track(UserInputService.JumpRequest:Connect(function()
    if not Config.InfJump then return end
    local _, char = myRoot()
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    if hum then hum:ChangeState(Enum.HumanoidStateType.Jumping) end
end))

-- fly
local flying, flyVel, flyGyro = false, nil, nil

local function stopFly()
    flying = false
    if flyVel then flyVel:Destroy() flyVel = nil end
    if flyGyro then flyGyro:Destroy() flyGyro = nil end
end

local function startFly()
    local root = myRoot()
    if not root or flying then return end
    flying = true

    flyVel = Instance.new("BodyVelocity")
    flyVel.MaxForce = Vector3.new(1, 1, 1) * 9e9
    flyVel.Velocity = Vector3.zero
    flyVel.Parent = root

    flyGyro = Instance.new("BodyGyro")
    flyGyro.MaxTorque = Vector3.new(1, 1, 1) * 9e9
    flyGyro.P = 9e4
    flyGyro.CFrame = Camera.CFrame
    flyGyro.Parent = root
end

track(RunService.RenderStepped:Connect(function()
    if not flying or not flyVel then return end
    local dir = Vector3.zero
    local cf = Camera.CFrame
    if UserInputService:IsKeyDown(Enum.KeyCode.W) then dir += cf.LookVector end
    if UserInputService:IsKeyDown(Enum.KeyCode.S) then dir -= cf.LookVector end
    if UserInputService:IsKeyDown(Enum.KeyCode.A) then dir -= cf.RightVector end
    if UserInputService:IsKeyDown(Enum.KeyCode.D) then dir += cf.RightVector end
    if UserInputService:IsKeyDown(Enum.KeyCode.Space) then dir += Vector3.yAxis end
    if UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) then dir -= Vector3.yAxis end

    flyVel.Velocity = (dir.Magnitude > 0 and dir.Unit or Vector3.zero) * Config.FlySpeed
    flyGyro.CFrame = cf
end))

--============================================================================
-- the per-frame driver
--============================================================================

track(RunService.Heartbeat:Connect(function()
    pcall(refreshSnap)
    pcall(auraTick)
    pcall(autoShootTick)
end))

-- anti afk: the idle kick listens for this signal, so firing it is enough
pcall(function()
    local vu = game:GetService("VirtualUser")
    track(LocalPlayer.Idled:Connect(function()
        vu:Button2Down(Vector2.new(0, 0), Camera.CFrame)
        task.wait(1)
        vu:Button2Up(Vector2.new(0, 0), Camera.CFrame)
    end))
end)

--============================================================================
-- godlies
--  Every weapon MM2 has ever shipped is in ReplicatedStorage.Database.Sync --
--  1004 entries, 172 of them Godly (107 knives, 65 guns). Each carries
--  ItemName, ItemType, Rarity and an ItemID.
--
--  What works and what does not, tested in his own private server:
--
--    Remotes.Inventory.Equip:FireServer(id, "Weapons") with a godly he OWNS
--    is accepted -- the server's own GetProfileData came back with the new
--    gun. The same call with one he does not own is ignored: the reply still
--    read the old weapon. So the server checks ownership on equip.
--
--    There is no local fallback for the model. MM2 keeps every weapon model
--    server side: nothing in ReplicatedStorage holds one, the inventory draws
--    flat images rather than ViewportFrames, and the ItemID in the database is
--    an image asset, not a model -- game:GetObjects returns 0 objects for it
--    while happily returning a public model like the LinkedSword. A skin the
--    server never sends cannot be worn, even just for yourself.
--
--  So this page equips anything owned, lists everything for reference, and can
--  push the whole catalogue into the client's inventory table for the look.
--============================================================================

local Sync = nil
local godlyCache = nil

local function syncDb()
    if Sync then return Sync end
    local db = ReplicatedStorage:FindFirstChild("Database")
    local mod = db and db:FindFirstChild("Sync")
    if not mod then return nil end
    local ok, loaded = pcall(require, mod)
    Sync = ok and loaded or nil
    return Sync
end

local function profileData()
    local mods = ReplicatedStorage:FindFirstChild("Modules")
    local mod = mods and mods:FindFirstChild("ProfileData")
    if not mod then return nil end
    local ok, pd = pcall(require, mod)
    return ok and pd or nil
end

local function ownsItem(id)
    local pd = profileData()
    local owned = pd and pd.Weapons and pd.Weapons.Owned
    return type(owned) == "table" and owned[id] ~= nil
end

local function godlies()
    if godlyCache then return godlyCache end
    godlyCache = { Knife = {}, Gun = {} }

    local db = syncDb()
    if not db or type(db.Weapons) ~= "table" then return godlyCache end

    for id, info in pairs(db.Weapons) do
        if type(info) == "table" and info.Rarity == "Godly" then
            local slot = info.ItemType
            if slot == "Knife" or slot == "Gun" then
                table.insert(godlyCache[slot], { id = id, name = tostring(info.ItemName or id) })
            end
        end
    end

    for _, list in pairs(godlyCache) do
        table.sort(list, function(a, b) return a.name < b.name end)
    end
    return godlyCache
end

-- the list the picker shows: owned ones are marked, because those are the only
-- ones the server will actually hand over
local function godlyNames(slot)
    local out = {}
    for _, entry in ipairs(godlies()[slot] or {}) do
        out[#out + 1] = entry.name .. (ownsItem(entry.id) and "  *" or "")
    end
    return out
end

local function godlyIdFor(slot, label)
    local clean = label:gsub("%s*%*$", ""):gsub("%s+$", "")
    for _, entry in ipairs(godlies()[slot] or {}) do
        if entry.name == clean then return entry.id end
    end
    return nil
end

local function equipGodly(slot)
    local label = (slot == "Knife") and Config.GodlyKnife or Config.GodlyGun
    if label == "None" then return false, "nothing picked" end

    local id = godlyIdFor(slot, label)
    if not id then return false, "unknown item" end

    local remotes = ReplicatedStorage:FindFirstChild("Remotes")
    local inv = remotes and remotes:FindFirstChild("Inventory")
    local equip = inv and inv:FindFirstChild("Equip")
    if not equip then return false, "Equip remote missing" end

    -- the client's own copy first, so the inventory ui follows along, then the
    -- server -- which is the half that decides whether you really hold it
    local pd = profileData()
    if pd and pd.Weapons and pd.Weapons.Equipped then
        pd.Weapons.Equipped[slot] = id
    end

    pcall(function() equip:FireServer(id, "Weapons") end)

    if not ownsItem(id) then
        statusText = label .. ": not owned, server will refuse"
        return true, "sent, but you do not own it"
    end

    statusText = "equipped " .. label
    return true
end

-- Writes every godly into the client's owned table. The inventory then shows
-- them all; the server still refuses to equip the ones that are not really
-- yours, so this is for the look and nothing more.
local function fillInventory()
    local pd = profileData()
    local owned = pd and pd.Weapons and pd.Weapons.Owned
    if type(owned) ~= "table" then return false, "no profile data" end

    local added = 0
    for _, slot in ipairs({ "Knife", "Gun" }) do
        for _, entry in ipairs(godlies()[slot] or {}) do
            if owned[entry.id] == nil then
                owned[entry.id] = 1
                added += 1
            end
        end
    end

    statusText = "added " .. added .. " godlies to the inventory view"
    return true, added
end

--============================================================================
-- config file
--============================================================================

local function saveConfig()
    if type(writefile) ~= "function" then return false, "no file access" end
    return pcall(function() writefile(CONFIG_PATH, HttpService:JSONEncode(Config)) end)
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
applyWorld()

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

local PANEL_W, BANNER_H, SUB_H = 360, 80, 28
local ROW_H, MAX_ROWS, DESC_H, HELP_H, PAD_X = 30, 10, 26, 22, 12

local screen = new("ScreenGui", {
    Name = "mm2_ui",
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
    Size = UDim2.new(1, -24, 1, -10),
    Position = UDim2.fromOffset(12, 5),
    BackgroundTransparency = 1,
    FontFace = F_TITLE,
    TextScaled = true,
    TextColor3 = Color3.new(1, 1, 1),
    Text = "Murder Mystery 2",
}, banner)
new("UITextSizeConstraint", { MaxTextSize = 50, MinTextSize = 16 }, bannerText)

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
    Text = "AURORA",
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

    rows[i] = {
        holder = holder,
        label = new("TextLabel", {
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
        }, holder),
        value = new("TextLabel", {
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
        }, holder),
    }
end

local upArrow = new("TextLabel", {
    Size = UDim2.fromOffset(16, 14), Position = UDim2.new(1, -19, 0, 1),
    BackgroundTransparency = 1, FontFace = F_BODY, TextSize = 11,
    TextColor3 = Color3.fromRGB(180, 180, 190), Text = "^", Visible = false, ZIndex = 3,
}, listArea)

local downArrow = new("TextLabel", {
    Size = UDim2.fromOffset(16, 14), Position = UDim2.new(1, -19, 1, -15),
    BackgroundTransparency = 1, FontFace = F_BODY, TextSize = 11,
    TextColor3 = Color3.fromRGB(180, 180, 190), Text = "v", Visible = false, ZIndex = 3,
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
local function Header(label)   return { kind = "header", label = label } end
local function Info(label, fn) return { kind = "info", label = label, textFn = fn } end
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
-- a long list gets a page of its own, which is what makes 107 knives workable
local function Picker(label, key, listFn, desc, onChange)
    return { kind = "picker", label = label, key = key, listFn = listFn, desc = desc, onChange = onChange }
end

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
    if #stack > 1 then table.remove(stack) render() end
end

local function buildPickerPage(item)
    local items = { Header(item.label) }

    table.insert(items, Action("None", function()
        Config[item.key] = "None"
        popPage()
    end, "Clear this slot."))

    for _, name in ipairs(item.listFn()) do
        table.insert(items, Action(name, function()
            Config[item.key] = name
            if item.onChange then item.onChange(name) end
            popPage()
        end, name))
    end

    return { title = item.label, subtitle = item.label, items = items }
end

local function runScript(url, name)
    return function()
        statusText = "loading " .. name
        task.spawn(function()
            local ok = pcall(function() loadstring(game:HttpGet(url))() end)
            statusText = ok and (name .. " loaded") or (name .. " failed")
        end)
    end
end

--------------------------------------------------------------------- pages
local function murdererPage()
    return { title = "Murderer", subtitle = "Murderer", items = {
        Info("role", function()
            return "you are " .. myRole() .. (auraArmed and "  [aura armed]" or "")
        end),
        Header("Aura"),
        Toggle("Kill Aura", "KillAura",
            "Grows every other root to 100 studs and swings for you. Only arms while the knife is actually in your hand."),
        Slider("Aura Radius", "AuraRadius", 5, 120, 5, 0,
            "How close someone has to be before it swings."),
        Header("Knife"),
        Toggle("Silent Knife", "SilentKnife",
            "Rewrites the throw's aim argument, so the knife flies at the target and your view never moves.",
            function(v) if v then installHook() end end),
        Toggle("Knife Through Walls", "KnifeWalls",
            "Moves the throw's origin point blank to the target so geometry cannot stop it."),
        Header("Hook"),
        Info("hook", function()
            if hookInstalled then return "namecall hook installed" end
            return hookError and ("hook failed: " .. hookError:sub(1, 46)) or "hook not installed yet"
        end),
    } }
end

local function sheriffPage()
    return { title = "Sheriff", subtitle = "Sheriff", items = {
        Info("status", function() return statusText end),
        Header("Aim"),
        Toggle("Aim Lock", "AimLock", "Turns the camera onto the murderer. Visible, unlike Silent."),
        Toggle("Silent Aim", "SilentAim",
            "Rewrites the shot's aim argument. The shot lands on the murderer wherever you are looking.",
            function(v) if v then installHook() end end),
        Toggle("Through Walls", "AimWalls",
            "Moves the shot's origin point blank to the target. The server ray is then 2 studs long and cannot clip."),
        Toggle("Auto Shoot", "AutoShoot",
            "Fires the gun's own remote at the murderer on its cooldown. Needs no hook."),
        Cycle("Engage", "AimEngage", { "Always", "Hold" }, "Always, or only while the key below is held."),
        Cycle("Key", "AimKey", { "MouseButton2", "MouseButton1", "E", "Q", "C", "LeftAlt" }, "The key Hold waits for."),
        Header("Lead"),
        Toggle("Use Lead", "UseLead",
            "Off by default: MM2's server re-raycasts to the hit point, so a led point hits nothing. Only turn this on if shots whiff on a still target."),
        Slider("Lead", "LeadMs", 0, 500, 10, 0, "Milliseconds of lead, when Use Lead is on."),
        Header("Target"),
        Info("target", function()
            if not snap then return "no murderer found" end
            local root = myRoot()
            local d = root and (snap.pos - root.Position).Magnitude or 0
            return string.format("%s  %.0fm", tostring(snap.name), d)
        end),
    } }
end

local function innocentPage()
    return { title = "Innocent", subtitle = "Innocent", items = {
        Info("drops", function()
            return string.format("%d gun drop(s) on the map", #gunDrops())
        end),
        Header("Gun"),
        Action("Teleport To Gun", function()
            local ok, err = teleportToGun()
            if not ok then error(tostring(err)) end
        end, "Jumps to the nearest drop, waits for the pickup, then puts you back."),
        Toggle("Gun ESP", "GunEsp", "Marks dropped guns."),
        Header("Coins"),
        Toggle("Coin ESP", "CoinEsp", "Marks coins within 400 studs."),
    } }
end

local function visualPage()
    return { title = "Visuals", subtitle = "Visuals", items = {
        Header("Players"),
        Toggle("Role ESP", "RoleEsp", "Red murderer, blue sheriff, green innocent."),
        Toggle("Box", "EspBox", "Outline around the body."),
        Toggle("Name", "EspName", "Username above the box."),
        Toggle("Role", "EspRole", "Role under the box."),
        Toggle("Distance", "EspDistance", "Distance under the box."),
        Toggle("Tracer", "EspTracer", "Line from the bottom of the screen."),
        Toggle("Chams", "EspChams", "Highlight through walls."),
        Slider("Max Distance", "EspMaxDist", 100, 5000, 100, 0, "Stop drawing past this."),
        Header("World"),
        Toggle("Fullbright", "Fullbright", "Flatten the lighting and push the fog out.", applyWorld),
        Toggle("X-Ray", "XRay", "Makes the map see-through. Heavy on big maps.", applyWorld),
    } }
end

local function movementPage()
    return { title = "Movement", subtitle = "Movement", items = {
        Header("Fly"),
        Action("Toggle Fly", function()
            if flying then stopFly() else startFly() end
            statusText = flying and "flying" or "landed"
        end, "WASD to move, Space up, Shift down."),
        Slider("Fly Speed", "FlySpeed", 10, 300, 10, 0, "Studs a second."),
        Header("Character"),
        Toggle("Noclip", "Noclip", "Walk through the map. Re-applied every step, since the engine turns collision back on."),
        Toggle("Infinite Jump", "InfJump", "Jump again in mid air."),
        Slider("Walk Speed", "WalkSpeed", 16, 200, 2, 0, "Default is 16.", applyChar),
        Slider("Jump Power", "JumpPower", 50, 300, 5, 0, "Default is 50.", applyChar),
        Action("Apply To Character", applyChar, "Push speed and jump onto your humanoid now."),
    } }
end

local function scriptPage()
    return { title = "Scripts", subtitle = "Scripts", items = {
        Header("Admin"),
        Action("Infinite Yield", runScript(
            "https://raw.githubusercontent.com/EdgeIY/infiniteyield/master/source", "Infinite Yield"),
            "The usual admin command suite."),
        Header("Server"),
        Action("Rejoin", function()
            TeleportService:Teleport(game.PlaceId, LocalPlayer)
        end, "Same place, fresh server."),
        Action("Server Hop", function()
            statusText = "finding a server"
            task.spawn(function()
                local ok, body = pcall(function()
                    return game:HttpGet(string.format(
                        "https://games.roblox.com/v1/games/%d/servers/Public?sortOrder=Asc&limit=100",
                        game.PlaceId))
                end)
                if not ok then statusText = "server list failed" return end
                local list = HttpService:JSONDecode(body)
                for _, s in ipairs(list.data or {}) do
                    if s.playing and s.maxPlayers and s.playing < s.maxPlayers and s.id ~= game.JobId then
                        TeleportService:TeleportToPlaceInstance(game.PlaceId, s.id, LocalPlayer)
                        return
                    end
                end
                statusText = "no other server with room"
            end)
        end, "Jumps to another public server with room."),
    } }
end

local function godlyPage()
    return { title = "Godlies", subtitle = "Godlies", items = {
        Info("equipped", function()
            local pd = profileData()
            local eq = pd and pd.Weapons and pd.Weapons.Equipped
            if not eq then return "no profile data" end
            return string.format("knife %s   gun %s", tostring(eq.Knife), tostring(eq.Gun))
        end),
        Header("Pick"),
        Picker("Knife", "GodlyKnife", function() return godlyNames("Knife") end,
            "Every godly knife in the game. A star means you own it -- those are the ones the server will actually give you."),
        Picker("Gun", "GodlyGun", function() return godlyNames("Gun") end,
            "Every godly gun. A star means you own it."),
        Header("Apply"),
        Action("Equip Knife", function()
            local ok, err = equipGodly("Knife")
            if not ok then error(tostring(err)) end
        end, "Sets it on the client and fires the game's own equip remote."),
        Action("Equip Gun", function()
            local ok, err = equipGodly("Gun")
            if not ok then error(tostring(err)) end
        end, "Sets it on the client and fires the game's own equip remote."),
        Action("Equip Both", function()
            equipGodly("Knife")
            equipGodly("Gun")
        end, "Both slots at once."),
        Header("Inventory"),
        Action("Show All In Inventory", function()
            local ok, err = fillInventory()
            if not ok then error(tostring(err)) end
        end, "Writes all 172 godlies into the client's owned list so the inventory shows them. Look only -- the server still checks ownership on equip."),
        Info("counts", function()
            local g = godlies()
            local ownK, ownG = 0, 0
            for _, e in ipairs(g.Knife) do if ownsItem(e.id) then ownK += 1 end end
            for _, e in ipairs(g.Gun) do if ownsItem(e.id) then ownG += 1 end end
            return string.format("%d knives (%d yours), %d guns (%d yours)",
                #g.Knife, ownK, #g.Gun, ownG)
        end),
    } }
end

local function configPage()
    return { title = "Config", subtitle = "Config", items = {
        Header("File"),
        Action("Save Config", function()
            local ok, err = saveConfig()
            if not ok then error(tostring(err)) end
        end, "Writes every setting to " .. CONFIG_PATH .. "."),
        Action("Load Config", function()
            loadConfig() applyWorld() render()
        end, "Re-reads the saved file."),
        Header("Maintenance"),
        Action("Disarm Kill Aura", function()
            Config.KillAura = false
            disarmAura()
        end, "Puts every hitbox and your own collision back."),
        Action("Unload", function()
            if _G.__MM2 then _G.__MM2() end
        end, "Remove the menu, the drawings and every hook."),
    } }
end

local function rootPage()
    return { title = "Murder Mystery 2", subtitle = "Aurora", items = {
        Sub("Murderer", murdererPage, "Kill aura and the silent knife."),
        Sub("Sheriff",  sheriffPage,  "Silent aim, aim lock, auto shoot."),
        Sub("Innocent", innocentPage, "Gun drops and coins."),
        Sub("Godlies",  godlyPage,    "Equip any godly you own, and list every one that exists."),
        Sub("Visuals",  visualPage,   "Role ESP, chams, tracers, lighting."),
        Sub("Movement", movementPage, "Fly, noclip, speed, jump."),
        Sub("Scripts",  scriptPage,   "Admin and server tools."),
        Sub("Config",   configPage,   "Save, load, unload."),
    } }
end

--------------------------------------------------------------------- render
local function valueText(item)
    if item.kind == "sub" then return ">>>" end
    if item.kind == "toggle" then return Config[item.key] and "ON" or "OFF" end
    if item.kind == "cycle" or item.kind == "picker" then return tostring(Config[item.key]) end
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
    elseif item.kind == "picker" then
        pushPage(buildPickerPage(item))
    elseif item.kind == "toggle" or item.kind == "cycle" or item.kind == "slider" then
        adjust(1)
    elseif item.kind == "action" then
        local ok, err = pcall(item.fn)
        if not ok then descText.Text = "error: " .. tostring(err):sub(1, 70) end
    end
end

-- The arrow keys drive the character through the engine's own CAS binding, and
-- UserInputService cannot stop that -- it only listens. So while the panel is
-- up the four keys are taken at a higher priority and sunk; the menu still
-- reads them, the character never does. Unbound on close.
local NAV_SINK = "mm2_nav_sink"
local NAV_KEYS = { Enum.KeyCode.Up, Enum.KeyCode.Down, Enum.KeyCode.Left, Enum.KeyCode.Right }

local function bindNavSink()
    ContextActionService:BindActionAtPriority(NAV_SINK, function()
        return Enum.ContextActionResult.Sink
    end, false, Enum.ContextActionPriority.High.Value + 1000, table.unpack(NAV_KEYS))
end

local function unbindNavSink()
    pcall(function() ContextActionService:UnbindAction(NAV_SINK) end)
end

pushPage(rootPage())

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
    end
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

_G.MM2 = {
    Config = Config,
    Status = function() return statusText end,
    Role   = myRole,
    Target = function() return snap end,
    Hook   = function() return hookInstalled, hookError end,
    Install = installHook,
    Drops  = gunDrops,
    Godly  = {
        Equip = equipGodly,
        Names = godlyNames,
        Fill  = fillInventory,
        Owns  = ownsItem,
    },
    Menu = {
        Open = function() root.Visible = true bindNavSink() render() end,
        Close = function() root.Visible = false unbindNavSink() end,
        Draw = function() render() end,
        Move = move, Adjust = adjust, Select = activate, Back = popPage,
        Page = function()
            local f = currentFrame()
            return f and f.page.title, f and f.index
        end,
    },
}

_G.__MM2 = function()
    pcall(function() RunService:UnbindFromRenderStep(AIM_BIND) end)
    pcall(function() RunService:UnbindFromRenderStep(ESP_BIND) end)
    for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
    pcall(disarmAura)
    pcall(stopFly)
    pcall(unbindNavSink)
    Config.XRay, Config.Fullbright = false, false
    pcall(applyWorld)
    for _, plr in ipairs(Players:GetPlayers()) do
        if plr.Character then pcall(chams, plr.Character, nil) end
    end
    pcall(function() espGui:Destroy() end)
    pcall(function() screen:Destroy() end)
    if _G.__MM2_UNHOOK then pcall(_G.__MM2_UNHOOK) _G.__MM2_UNHOOK = nil end
    _G.MM2, _G.__MM2 = nil, nil
end

print("[mm2] loaded -- INSERT or DELETE for the menu")
