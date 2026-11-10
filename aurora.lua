--[[
    aurora_full.lua  --  one script, every supported game

    Execute -> five second intro over a lightly blurred scene -> the module for
    whatever game this is. An unsupported place gets one card and an OK button,
    nothing else.

    Games are matched on GameId first: a universe can hold several places, and
    Hypershot moves you between them, so a PlaceId match alone would lose the
    script on every mode change.

    Fonts and the wheel art are cached in the executor workspace on first run.
    The fetch NEVER blocks the load -- game:HttpGet yields, and the thread an
    executor runs a script on is not always allowed to yield; doing it inline
    froze solara solid. It runs in a thread and the next launch picks the files
    up off disk.

    Built by build_aurora.py from aurora.lua and hypershot.lua -- edit those,
    not this.
]]

local TweenService = game:GetService("TweenService")
local HttpService  = game:GetService("HttpService")
local Lighting     = game:GetService("Lighting")

local GUI_HOST = (gethui and gethui()) or game:GetService("CoreGui")

if _G.__AURORA_FULL then pcall(_G.__AURORA_FULL) end

local HOST = "https://raw.githubusercontent.com/hahajaiisiu22/aurora-assets/main/"

local ASSETS = {
    { dir = "aurora_fonts", path = "aurora_fonts/Pricedown.otf",      url = "fonts/Pricedown.otf",      min = 40000 },
    { dir = "aurora_fonts", path = "aurora_fonts/ChaletLondon.ttf",   url = "fonts/ChaletLondon.ttf",   min = 60000 },
    { dir = "aurora_fonts", path = "aurora_fonts/ChaletComprime.ttf", url = "fonts/ChaletComprime.ttf", min = 60000 },
    { dir = "aurora_fonts", path = "aurora_fonts/Griffiths.otf",      url = "fonts/Griffiths.otf",      min = 15000 },
    { dir = "aurora_art",   path = "aurora_art/wedge.png",            url = "art/wedge.png",            min = 2000  },
    { dir = "aurora_art",   path = "aurora_art/arc.png",              url = "art/arc.png",              min = 1500  },
}

local canWrite = (type(writefile) == "function") and (type(isfile) == "function")
local assetState = "checking"

local function ensureAssets(onDone)
    if not canWrite then assetState = "no file access" onDone() return end

    local missing = {}
    for _, a in ipairs(ASSETS) do
        if not isfile(a.path) then missing[#missing + 1] = a end
    end

    if #missing == 0 then assetState = "assets ready" onDone() return end

    assetState = "fetching assets"
    task.spawn(function()
        local got = 0
        for _, a in ipairs(missing) do
            if type(makefolder) == "function" and type(isfolder) == "function" and not isfolder(a.dir) then
                pcall(makefolder, a.dir)
            end
            local ok, body = pcall(function() return game:HttpGet(HOST .. a.url, true) end)
            -- a short body is an error page, not an asset
            if ok and type(body) == "string" and #body >= a.min and pcall(writefile, a.path, body) then
                got += 1
            end
        end
        assetState = (got == #missing) and "assets ready" or ("assets " .. got .. "/" .. #missing)
        onDone()
    end)
end

local function diskFace(file, family, fallback)
    if type(getcustomasset) ~= "function" or not canWrite then return fallback end
    local path = "aurora_fonts/" .. file
    if not isfile(path) then return fallback end
    local ok, f = pcall(function()
        local asset = getcustomasset(path)
        local famPath = "aurora_fonts/" .. family .. ".json"
        writefile(famPath, HttpService:JSONEncode({
            name  = family,
            faces = { { name = "Regular", weight = 400, style = "normal", assetId = asset } },
        }))
        return Font.new(getcustomasset(famPath), Enum.FontWeight.Regular, Enum.FontStyle.Normal)
    end)
    return ok and f or fallback
end

local function new(class, props, parent)
    local i = Instance.new(class)
    for k, v in pairs(props) do i[k] = v end
    if parent then i.Parent = parent end
    return i
end

local function tween(inst, time, props)
    TweenService:Create(inst,
        TweenInfo.new(time, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), props):Play()
end

--============================================================================
-- module: Gunfight Arena
--============================================================================
local RUNGUNFIGHT_SRC = [=[
--[[
    aurora.lua  --  Gunfight Arena (PlaceId 15514727567)

    Everything in one menu: silent aim, esp, weapon and skin grants, fire rate,
    ammo. Findings this is built on, all read out of the live client:

    DAMAGE PATH. The server scores a shot only from
        INVK("Fire", gun, os.clock(), CFrame.new(Flame.p, Flame.p + Camera.LookVector), ...)
    at vortex.lua:5749. _G.MouseHitSpot and the third-person branch steer nothing
    but the local tracer sim in SecondThread, whose "Hit" reply just draws a
    hitmarker (vortex.lua:9502). So silent aim turns the CAMERA for the single
    frame the shot leaves -- set at RenderPriority.Camera - 1, read by
    WeaponRender at 200, restored at +10, before anything is drawn.

    CAMERA BLEND. WeaponRender does not take the camera as given: vortex.lua:6395
    writes lerp(its own goal, our camera, f) with
        f = GetSens() * (FieldOfView / (70 * Modifiers.FOV))
    so the turn lands short. The overshoot is 1/f, computed live from the real
    sensitivity every frame.

    BALLISTICS. Not hitscan. vortex.lua:5510 and :5660 send
        speed = BulletData[cartridge].BaseVelocity + 5 * GetBarrelLength()
    as the shot velocity, barrel measured off the live viewmodel the way
    vortex.lua:245 does it. GetHitables (vortex.lua:2953) only reports targets
    inside |x| + |y| < 8 studs of the fire direction, so lead is clamped to that
    cone -- past it the bullet flies true and nothing registers.

    TARGETS. Every character sits directly under workspace. The Players service
    holds a *Folder* for each bot, so the player test is :IsA("Player"), not
    FindFirstChild. Bot characters also carry a Vector3Value "LookDirection".

    INVENTORY. Vortex.Inventory holds one StringValue per carried weapon: name =
    weapon name, value = "<mag>:<reserve>", attributes Steadiness and Mobility, an
    optional child StringValue "Camo" for the skin (vortex.lua:8646-8657). Adding
    an entry grants the weapon, which is how deleted and locked guns are reached.

    FIRE RATE. Weapons.<gun>.Variables.FireRate is RPM. GatherWeaponData
    (vortex.lua:186) copies it into the module upvalue v19 at equip time and the
    shot loop reads 60/v19 per shot (vortex.lua:4270), so a write needs a re-equip:
    Swap1/Swap2 are One/Two and Swap is MouseWheel. The measured RPM readout on the
    STATS tab counts Vortex.Audio.Click plays, which fire once per Fire packet
    (vortex.lua:5751), so the number there is the real cadence, not the setting.

    AMMO. There is no ammo override and there cannot be one. The server keeps its
    own count of the rounds it issued you. Restock (vortex.lua:3730) computes
    v381 = ClipSize - mag, clamps it to the reserve and sends
        INVK("Action", "Reload", v381)
    so every reload is reported and checked against the server's own figures.
    Raising ClipSize asks for a 250-round reload on a 25-round rifle and is refused
    outright. Raising the RESERVE fails the same way one magazine later: the TT30
    carries 45 stock rounds against the M16A1's 125, so with both pinned to 300 the
    pistol ran its pool dry in five reloads and went unbacked while the rifle kept
    scoring through the same test. Past that point the client fires rounds the
    server never issued and hit credit stops for the round. The divergence is a
    tally, not a setting -- turning the toggle back off cannot clear it, only a
    rejoin can.
    So the file holds every ammo figure at stock, repairs any stomped value off
    Variables.Ammo (the twin of ClipSize nothing here writes), and makes reloading
    cheaper the legal way: FasterReloads, a LocalPlayer attribute read at equip
    (vortex.lua:8987), turns the attachment string into "Fast Mags" and RunAnimation
    plays the reload at 1.2x (vortex.lua:762). Animation only, no round invented.

    LEDGER. PlayerGui.HUD.Ammo.Mag is the engine's own round counter in three digit
    labels. Vortex.Audio.Click plays once per Fire packet, so packets against
    counter steps is a live read on whether the two sides still agree. The fire
    rate reverts itself to stock the moment packets outrun rounds, which catches
    the same failure before a match is spent instead of after.

    Menu: DELETE
]]

local Players           = game:GetService("Players")
local RunService        = game:GetService("RunService")
local UserInputService  = game:GetService("UserInputService")
local TweenService      = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService       = game:GetService("HttpService")
local ContextActionService = game:GetService("ContextActionService")

local LocalPlayer = Players.LocalPlayer

local BulletData = require(ReplicatedStorage.BulletData)
local Weapons    = ReplicatedStorage.Weapons
local Camos      = ReplicatedStorage.Camos

local VortexRoot = LocalPlayer.PlayerScripts:WaitForChild("Vortex")
local InventoryF = VortexRoot:WaitForChild("Inventory")
local Modifiers  = VortexRoot:WaitForChild("Modifiers")

local GUI_HOST = (gethui and gethui()) or game:GetService("CoreGui")

if _G.__AURORA then pcall(_G.__AURORA) end

--============================================================================
-- config
--============================================================================

local Config = {
    -- aim
    AimEnabled    = true,
    Method        = "Silent",       -- Silent (muzzle origin, camera never moves) / Lock (camera turns)
    Standoff      = 4,              -- studs the muzzle is parked short of the target
    Mode          = "Always",       -- Always / Hold / Toggle
    Key           = "MouseButton2",
    Bone          = "Auto",         -- Auto / Head / UpperTorso / HumanoidRootPart
    FOVDeg        = 40,
    Range         = 500,
    Smoothness    = 0.35,
    StickyTarget  = true,

    -- lead
    Predict       = true,
    LeadMul       = 1.0,
    LeadIters     = 3,
    ConeCap       = 7,
    DamageCone    = 8,

    -- targets
    TargetBots    = true,
    TargetPlayers = true,
    FFA           = "Auto",         -- Auto / On / Off
    WallCheck     = "Auto",         -- Auto / Strict / Off

    -- esp
    EspEnabled    = false,
    EspBox        = true,
    EspName       = true,
    EspHealth     = true,
    EspDistance   = true,
    EspSkeleton   = false,
    EspTracer     = false,
    EspChams      = false,
    EspRainbow    = false,
    EspBots       = true,
    EspPlayers    = true,
    EspMaxDist    = 1000,
    EspTextSize   = 12,

    -- weapons
    ForcePrimary   = "None",
    ForceSecondary = "None",
    ForceCamo      = "None",
    ApplyOnSpawn   = true,

    -- stats
    RateEnabled   = false,
    RateMul       = 1.5,
    RateCap       = 1200,
    FastReload    = false,          -- the engine's own Fast Mags perk, 1.2x reload animation
    OneShot       = 0,              -- damage a single trigger pull should land; 0 is off

    -- look
    Skin          = "Aurora",       -- Aurora / JJ / BlackFox / Firah -- whole panel look

    -- wheel
    WheelEnabled  = true,
    WheelKey      = "B",            -- held: wheel up. released: equips the hovered gun
    PanelX        = 48,
    PanelY        = 120,
    Theme         = "Galaxy",       -- Galaxy / Blue / Green / Red / Orange / Mono / Custom
    ThemeR        = 126,
    ThemeG        = 68,
    ThemeB        = 220,
}

local CONFIG_PATH = "aurora_gfa.json"

local function saveConfig()
    if not writefile then return false, "no writefile" end
    local ok, err = pcall(function()
        writefile(CONFIG_PATH, HttpService:JSONEncode(Config))
    end)
    return ok, err
end

local function loadConfig()
    if not (readfile and isfile and isfile(CONFIG_PATH)) then return false end
    local ok, data = pcall(function() return HttpService:JSONDecode(readfile(CONFIG_PATH)) end)
    if ok and type(data) == "table" then
        for k, v in pairs(data) do
            if Config[k] ~= nil and typeof(Config[k]) == typeof(v) then Config[k] = v end
        end
        return true
    end
    return false
end

pcall(loadConfig)

local conns = {}
local function track(c) table.insert(conns, c) return c end

--============================================================================
-- equipped weapon
--============================================================================

local equipped = nil

local function refreshInventoryHooks()
    local first
    for _, sv in ipairs(InventoryF:GetChildren()) do
        if sv:IsA("StringValue") then
            first = first or sv.Name
            track(sv.Changed:Connect(function() equipped = sv.Name end))
        end
    end
    if equipped == nil or not InventoryF:FindFirstChild(equipped) then equipped = first end
end

refreshInventoryHooks()
track(InventoryF.ChildAdded:Connect(refreshInventoryHooks))
track(InventoryF.ChildRemoved:Connect(refreshInventoryHooks))

local function activeWeaponName() return equipped end

local cartridgeCache = {}

-- mirrors GatherWeaponData (vortex.lua:197): explicit Variables.Cartridge, else
-- the BulletData key found in Desc. Longest match wins so "7.62x54mmR" beats "7.62x5".
local function cartridgeFor(name)
    if not name then return ".45 ACP" end
    if cartridgeCache[name] then return cartridgeCache[name] end

    local folder = Weapons:FindFirstChild(name)
    local result = ".45 ACP"
    if folder then
        local vars = folder:FindFirstChild("Variables")
        local explicit = vars and vars:FindFirstChild("Cartridge")
        if explicit then
            result = explicit.Value
        else
            local desc = folder:FindFirstChild("Desc")
            if desc then
                local best, bestLen = nil, 0
                for key in pairs(BulletData) do
                    if #key > bestLen and string.find(desc.Value, key, 1, true) then
                        best, bestLen = key, #key
                    end
                end
                result = best or ".45 ACP"
            end
        end
    end
    cartridgeCache[name] = result
    return result
end

-- vortex.lua:245, measured against the live viewmodel
local function barrelLength()
    local vm = workspace:FindFirstChild("ViewModel")
    local gun = vm and vm:FindFirstChild("Gun")
    if not gun then return 0.1 end

    local flame = gun:FindFirstChild("NewFlame") or gun:FindFirstChild("Flame")
    if not flame then return 0.1 end

    local eject = gun:FindFirstChild("EjectionPort")
    if eject then return (eject.CFrame.Position - flame.CFrame.Position).Magnitude * 10 end

    local shell = gun:FindFirstChild("Shell")
    if shell then return (shell.CFrame.Position - flame.CFrame.Position).Magnitude * 10 end

    if gun.PrimaryPart then
        return (gun.PrimaryPart.CFrame.Position - flame.CFrame.Position).Magnitude * 3
    end
    return 0.1
end

local function projectileSpeed()
    local cart = cartridgeFor(activeWeaponName())
    local entry = BulletData[cart]
    return ((entry and entry.BaseVelocity) or 500) + 5 * barrelLength(), cart
end

local function isExplosive(name)
    if not name then return false end
    local folder = Weapons:FindFirstChild(name)
    local class = folder and folder:FindFirstChild("Class")
    return class ~= nil and class.Value == "Launcher"
end

-- stock magazine / reserve. Variables.Ammo is the twin of ClipSize that nothing
-- here ever writes, so it survives as the honest stock figure even if ClipSize
-- was stomped by an older build of this script earlier in the session.
local stockCache = {}

local function stockAmmo(name)
    if not name then return nil end
    local hit = stockCache[name]
    if hit then return hit end

    local vars = Weapons:FindFirstChild(name)
    vars = vars and vars:FindFirstChild("Variables")
    if not vars then return nil end

    local twin  = vars:FindFirstChild("Ammo")
    local clip  = vars:FindFirstChild("ClipSize")
    local store = vars:FindFirstChild("StoredAmmo")

    hit = {
        clip    = (twin and twin.Value) or (clip and clip.Value) or 30,
        reserve = (store and store.Value) or 150,
    }
    stockCache[name] = hit
    return hit
end

-- "<mag>:<reserve>" with an optional trailing NR meaning nothing is chambered
-- (vortex.lua:126). Returns nil on anything that is not that shape.
local function parseAmmo(value)
    local colon = string.find(value, ":", 1, true)
    if not colon then return nil end

    local mag  = tonumber(string.sub(value, 1, colon - 1))
    local rest = string.sub(value, colon + 1)
    local nr   = false

    if string.sub(rest, -2) == "NR" then
        nr = true
        rest = string.sub(rest, 1, -3)
    end

    local reserve = tonumber(rest)
    if not (mag and reserve) then return nil end
    return mag, reserve, nr
end

local function writeAmmo(entry, mag, reserve, nr)
    entry.Value = mag .. ":" .. reserve .. (nr and "NR" or "")
end

--============================================================================
-- targets
--============================================================================

local function playerFor(name)
    local e = Players:FindFirstChild(name)
    if e and e:IsA("Player") then return e end
    return nil
end

local function isBot(model) return playerFor(model.Name) == nil end

local function ffaActive()
    if Config.FFA == "On"  then return true  end
    if Config.FFA == "Off" then return false end
    local mine = LocalPlayer.Team
    if mine == nil then return true end
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= LocalPlayer and p.Team ~= mine then return true end
    end
    return false
end

local function isEnemy(model, ffa, wantBots, wantPlayers)
    local plr = playerFor(model.Name)
    if plr then
        if not wantPlayers then return false end
        if ffa then return plr ~= LocalPlayer end
        return plr.Team ~= LocalPlayer.Team
    end
    return wantBots
end

local function allCharacters()
    local list = {}
    local me = LocalPlayer.Character
    for _, m in ipairs(workspace:GetChildren()) do
        if m ~= me and m:IsA("Model") then
            local hum = m:FindFirstChildOfClass("Humanoid")
            if hum and hum.Health > 0 and m.PrimaryPart then
                table.insert(list, m)
            end
        end
    end
    return list
end

local function candidates()
    local list = {}
    local ffa = ffaActive()
    for _, m in ipairs(allCharacters()) do
        local hum = m:FindFirstChildOfClass("Humanoid")
        if hum.Health > 1 and isEnemy(m, ffa, Config.TargetBots, Config.TargetPlayers) then
            table.insert(list, m)
        end
    end
    return list
end

--============================================================================
-- visibility
--  deliberately harsher than the game's own aim assist, which whitelists
--  {Terrain, Env, target} and so never sees the Walls folder at all
--============================================================================

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.IgnoreWater = true
rayParams.RespectCanCollide = true   -- bullets pass through the map's trigger volumes

local function wallCheckMode()
    if Config.WallCheck == "Off" then return "off" end
    if Config.WallCheck == "Strict" then return "strict" end
    return isExplosive(activeWeaponName()) and "off" or "strict"
end

local function hasLineOfSight(origin, part, model)
    local delta = part.Position - origin
    if delta.Magnitude < 1 then return true end

    rayParams.FilterDescendantsInstances = {
        model,
        LocalPlayer.Character,
        workspace:FindFirstChild("ViewModel"),
        workspace:FindFirstChild("Gibs"),
    }
    return workspace:Raycast(origin, delta, rayParams) == nil
end

local function visible(origin, part, model)
    if wallCheckMode() == "off" then return true end
    return hasLineOfSight(origin, part, model)
end

--============================================================================
-- bone pick / cone / lead
--============================================================================

local function pickBone(model, origin, camLook)
    if Config.Bone ~= "Auto" then
        return model:FindFirstChild(Config.Bone) or model.PrimaryPart
    end
    local torso = model:FindFirstChild("UpperTorso") or model.PrimaryPart
    local head  = model:FindFirstChild("Head")
    if not head then return torso end
    local dTorso = camLook:Dot(CFrame.new(origin, torso.Position).LookVector)
    local dHead  = camLook:Dot(CFrame.new(origin, head.Position).LookVector)
    return (dHead > dTorso) and head or torso
end

local function coneStuds(fireFrame, part)
    local o = fireFrame:PointToObjectSpace(part.Position)
    return math.abs(o.X) + math.abs(o.Y), o.Z
end

-- GetHitables runs at fire time against the target's CURRENT position and only
-- reports what sits inside |x| + |y| < 8 studs of the fire direction, so lead
-- past that cone makes the bullet fly true and register nothing.
local function leadPoint(part, origin, speed)
    local pos = part.Position
    if not Config.Predict or speed <= 0 then return pos, 0, 0 end

    local vel = part.AssemblyLinearVelocity
    if vel.Magnitude < 0.1 then return pos, 0, 0 end

    local t = 0
    for _ = 1, math.max(1, Config.LeadIters) do
        t = (origin - (pos + vel * t)).Magnitude / speed
    end

    local leadVec = vel * t * Config.LeadMul
    local wanted = leadVec.Magnitude

    local cap = Config.ConeCap
    if cap > 0 then
        for _ = 1, 2 do
            local f = CFrame.lookAt(origin, pos + leadVec)
            local o = f:PointToObjectSpace(pos)
            local flat = math.abs(o.X) + math.abs(o.Y)
            if flat <= cap then break end
            leadVec = leadVec * (cap / flat)
        end
    end

    return pos + leadVec, wanted, leadVec.Magnitude
end

--============================================================================
-- acquisition
--============================================================================

local currentTarget, currentPart

local function scoreOf(cam, model, part)
    local toTarget = part.Position - cam.CFrame.Position
    local dist = toTarget.Magnitude
    if dist < 1 or dist > Config.Range then return nil end

    local angle = math.deg(math.acos(math.clamp(cam.CFrame.LookVector:Dot(toTarget.Unit), -1, 1)))
    if angle > Config.FOVDeg then return nil end

    if not visible(cam.CFrame.Position, part, model) then return nil end
    return angle
end

local function stillValid(cam, model)
    if not (model and model.Parent and model.PrimaryPart) then return false end
    local hum = model:FindFirstChildOfClass("Humanoid")
    if not (hum and hum.Health > 1) then return false end
    if not isEnemy(model, ffaActive(), Config.TargetBots, Config.TargetPlayers) then return false end

    local part = pickBone(model, cam.CFrame.Position, cam.CFrame.LookVector)
    if not part or scoreOf(cam, model, part) == nil then return false end
    currentPart = part
    return true
end

local function acquire(cam)
    if Config.StickyTarget and currentTarget and stillValid(cam, currentTarget) then
        return currentTarget, currentPart
    end

    local bestModel, bestPart, bestScore = nil, nil, math.huge
    for _, m in ipairs(candidates()) do
        local part = pickBone(m, cam.CFrame.Position, cam.CFrame.LookVector)
        if part then
            local s = scoreOf(cam, m, part)
            if s and s < bestScore then bestModel, bestPart, bestScore = m, part, s end
        end
    end

    currentTarget, currentPart = bestModel, bestPart
    return bestModel, bestPart
end

--============================================================================
-- activation
--============================================================================

local toggleState = false

local function keyEnum()
    local name = Config.Key
    local ok, e = pcall(function() return Enum.UserInputType[name] end)
    if ok and e then return e, true end
    ok, e = pcall(function() return Enum.KeyCode[name] end)
    if ok and e then return e, false end
    return Enum.UserInputType.MouseButton2, true
end

local function keyDown()
    local e, isMouse = keyEnum()
    if isMouse then return UserInputService:IsMouseButtonPressed(e) end
    return UserInputService:IsKeyDown(e)
end

local function readyToLock()
    if not Config.AimEnabled then return false end

    local char = LocalPlayer.Character
    if not char then return false end
    local hum = char:FindFirstChildOfClass("Humanoid")
    if not (hum and hum.Health > 0) then return false end

    local vm = workspace:FindFirstChild("ViewModel")
    if not (vm and vm:FindFirstChild("Gun")) then return false end

    if Config.Mode == "Always" then return true end
    if Config.Mode == "Toggle" then return toggleState end
    return keyDown()
end

local AIM_RENDER = "aurora_aim"
local statusText = "idle"

--  SILENT. vortex.lua:5749 sends the server
--      INVK("Fire", gun, t, CFrame.new(Flame.p, Flame.p + Camera.LookVector), ...)
--  The direction is the camera, but the ORIGIN is workspace.ViewModel.Gun.Flame --
--  a client-side viewmodel part, anchored, no joints. Park it at
--  target - cameraLook * Standoff and the server's own trace starts beside the
--  body and walks into it, whatever the camera is pointed at.
--
--  Two timing facts make it work. WeaponRender(200) re-places the muzzle every
--  single frame, so writes must land after it. And Fire() yields on
--  GlobalAPI.RealWait, which is RunService.Stepped:wait(), so the shot is emitted
--  during Stepped -- before the render bindings -- meaning the write it reads is
--  the previous frame's Heartbeat one. All three phases are covered below.
--
--  Measured against the server's own LastDamager attribute: hits confirmed at up
--  to 53.7 degrees off the crosshair.

local function aimStep()
    local cam = workspace.CurrentCamera
    if not cam then return end

    if not readyToLock() then
        currentTarget, currentPart = nil, nil
        statusText = Config.AimEnabled and "idle" or "off"
        return
    end

    local model, part = acquire(cam)
    if not (model and part) then
        statusText = "no target"
        return
    end

    local origin = cam.CFrame.Position
    local speed, cart = projectileSpeed()
    local dist = (origin - part.Position).Magnitude
    local angle = math.deg(math.acos(math.clamp(
        cam.CFrame.LookVector:Dot((part.Position - origin).Unit), -1, 1)))

    if Config.Method == "Silent" then
        local vm = workspace:FindFirstChild("ViewModel")
        local gun = vm and vm:FindFirstChild("Gun")
        local flame = gun and gun:FindFirstChild("Flame")
        if not flame then
            statusText = "no muzzle"
            return
        end

        -- travel time is ~0 from a muzzle parked beside the body, so no lead
        local look = cam.CFrame.LookVector
        local at = part.Position - look * Config.Standoff
        flame.CFrame = CFrame.new(at, at + look)

        statusText = string.format("[silent] %s%s %s %.0fst  %.0f deg off aim  %s @%.0f",
            isBot(model) and "[bot] " or "", model.Name, part.Name, dist, angle, cart, speed)
        return
    end

    -- LOCK. A real camera turn, for when you want the view to follow.
    local aimAt, wantLead, usedLead = leadPoint(part, origin, speed)
    local flat = coneStuds(CFrame.lookAt(origin, aimAt), part)
    statusText = string.format("[lock] %s%s %s %.0fst cone %.1f%s lead %.1f/%.1f %s @%.0f",
        isBot(model) and "[bot] " or "", model.Name, part.Name, dist,
        flat, (flat < Config.DamageCone) and "*" or "!", usedLead, wantLead, cart, speed)

    local goal  = CFrame.lookAt(origin, aimAt)
    local alpha = math.clamp(Config.Smoothness, 0.01, 1)
    cam.CFrame = (alpha >= 1) and goal or cam.CFrame:Lerp(goal, alpha)
end

pcall(function() RunService:UnbindFromRenderStep(AIM_RENDER) end)
RunService:BindToRenderStep(AIM_RENDER, Enum.RenderPriority.Camera.Value + 20, aimStep)
track(RunService.Heartbeat:Connect(aimStep))
track(RunService.Stepped:Connect(aimStep))

--============================================================================
-- weapon + skin grants
--  Vortex.Inventory entry: StringValue named after the gun, value "<mag>:<reserve>",
--  attributes Steadiness / Mobility, optional child StringValue "Camo"
--  (vortex.lua:8646-8657).
--============================================================================

local applyRate = function() end     -- bound to applyFireRate once it is defined

local function setCamoOn(entry, camo)
    local existing = entry:FindFirstChild("Camo")
    if camo == "None" or camo == nil then
        if existing then existing:Destroy() end
        return
    end
    if not existing then
        existing = Instance.new("StringValue")
        existing.Name = "Camo"
        existing.Parent = entry
    end
    existing.Value = camo
end

-- Slot order is just child order -- the engine cycles with
-- script.Inventory:GetChildren()[n] (vortex.lua:9694). The old code wrote one
-- slot at a time, and because a new entry is appended at the END, granting the
-- primary first left the children as [old secondary, new primary]; the secondary
-- pass then destroyed index 2, which was the primary that had just been made.
-- Both dropdowns landed on the same slot and the order came out backwards. So
-- the folder is rebuilt in one pass instead, primary parented first.
local function makeEntry(gunName, camo)
    local stock = stockAmmo(gunName) or { clip = 30, reserve = 150 }

    local entry = Instance.new("StringValue")
    entry.Name = gunName
    entry:SetAttribute("Steadiness", 1)
    entry:SetAttribute("Mobility", 1)
    writeAmmo(entry, stock.clip, stock.clip, true)   -- "<clip>:<clip>NR", vortex.lua:8656

    if camo and camo ~= "None" then
        local c = Instance.new("StringValue")
        c.Name = "Camo"
        c.Value = camo
        c.Parent = entry
    end

    entry.Parent = InventoryF
    return entry
end

local function applyLoadout()
    local before, camoOf = {}, {}
    for _, e in ipairs(InventoryF:GetChildren()) do
        if e:IsA("StringValue") then
            local c = e:FindFirstChild("Camo")
            camoOf[e.Name] = c and c.Value or nil
            table.insert(before, e.Name)
        end
    end

    local wantCamo = (Config.ForceCamo ~= "None") and Config.ForceCamo or nil

    -- camo only: leave the guns where they are
    if Config.ForcePrimary == "None" and Config.ForceSecondary == "None" then
        if not wantCamo then return false, "nothing selected" end
        for _, e in ipairs(InventoryF:GetChildren()) do
            if e:IsA("StringValue") then setCamoOn(e, wantCamo) end
        end
        return true
    end

    local primary   = (Config.ForcePrimary   ~= "None") and Config.ForcePrimary   or before[1]
    local secondary = (Config.ForceSecondary ~= "None") and Config.ForceSecondary or before[2]

    if primary   and not Weapons:FindFirstChild(primary)   then return false, "unknown primary"   end
    if secondary and not Weapons:FindFirstChild(secondary) then return false, "unknown secondary" end

    for _, e in ipairs(InventoryF:GetChildren()) do
        if e:IsA("StringValue") then e:Destroy() end
    end

    if primary   then makeEntry(primary,   wantCamo or camoOf[primary])   end
    if secondary then makeEntry(secondary, wantCamo or camoOf[secondary]) end

    refreshInventoryHooks()
    applyRate()                 -- the new guns were not in the folder when it last ran
    return true
end

-- The engine rebuilds Vortex.Inventory from the server loadout at round start
-- and at every respawn, which wipes whatever was granted before. A single
-- apply on spawn loses that race whenever the rebuild lands after it, which is
-- why the loadout "didn't save" -- it was applied, then overwritten. So the
-- folder is watched instead: any time its children stop matching the forced
-- loadout, it is applied again. applying guards the churn our own rebuild makes.
local applying = false
local enforceQueued = false

local function loadoutMatches()
    local want = {}
    if Config.ForcePrimary   ~= "None" then want[#want + 1] = Config.ForcePrimary end
    if Config.ForceSecondary ~= "None" then want[#want + 1] = Config.ForceSecondary end
    if #want == 0 then return true end

    for _, name in ipairs(want) do
        local e = InventoryF:FindFirstChild(name)
        if not e or not e:IsA("StringValue") then return false end
        if Config.ForceCamo ~= "None" then
            local c = e:FindFirstChild("Camo")
            if not c or c.Value ~= Config.ForceCamo then return false end
        end
    end
    return true
end

-- coalesced: a rebuild fires a burst of ChildAdded, and one apply answers all of them
local function enforceLoadout()
    if applying or enforceQueued then return end
    if not Config.ApplyOnSpawn then return end

    enforceQueued = true
    task.delay(0.35, function()
        enforceQueued = false
        if applying or not Config.ApplyOnSpawn then return end
        if loadoutMatches() then return end

        applying = true
        pcall(applyLoadout)
        applying = false
    end)
end

track(InventoryF.ChildAdded:Connect(enforceLoadout))
track(InventoryF.ChildRemoved:Connect(enforceLoadout))

-- the rebuild can also land in silence, with the folder already holding the
-- right names but the wrong ammo, so spawn is swept for a few seconds too
track(LocalPlayer.CharacterAdded:Connect(function()
    if not Config.ApplyOnSpawn then return end
    task.wait(2.5)   -- let the engine build its own loadout first
    applying = true
    pcall(applyLoadout)
    applying = false

    for _ = 1, 8 do
        task.wait(1)
        if not Config.ApplyOnSpawn then return end
        enforceLoadout()
    end
end))

--============================================================================
-- fire rate + ammo
--  FireRate is RPM, shot delay is 60/FireRate, cached into v19 at equip time
--  (vortex.lua:186) and read per shot at vortex.lua:4270 -- so a write only takes
--  on the next equip. Swap1/Swap2 are One/Two, Swap is MouseWheel.
--
--  Ammo never writes ClipSize or StoredAmmo. Restock (vortex.lua:3730) reports the
--  loaded count to the server with INVK("Action", "Reload", v381) and the server
--  checks it against its own ClipSize, so a raised magazine makes every reload
--  illegal and kills damage until you rejoin. Only the reserve half of the
--  inventory StringValue moves, pinned every frame so each swap refills it.
--============================================================================

local originalRates = {}

--  ONE SHOT. There is no damage override and there cannot be one, for the same
--  reason there is no ammo override: the server scores a hit from ITS copy of
--  Weapons.<gun>.Variables.MaxDamage, and a client write to ReplicatedStorage
--  never reaches it. INVK("Fire", ...) carries no damage field either -- gun
--  name, clock, muzzle CFrame, nothing else (vortex.lua:5749) -- and the packet
--  cannot be forged, because Network signs every call and traps any thread that
--  requires it.
--
--  What can be done is land the damage in one pull instead of one round. The
--  gun's real MaxDamage is readable, so the rounds needed are just
--  ceil(want / MaxDamage), and the cadence that fits them inside a single tap is
--  rounds / TAP_SECONDS * 60. Every round is a real packet the game sends itself,
--  against ammunition the server already issued, so nothing is invented.
local TAP_SECONDS = 0.12     -- how long a tap holds the trigger, measured by ear
local ONE_SHOT_RPM_CAP = 3000

local function oneShotPlan(gunName)
    if (Config.OneShot or 0) <= 0 then return nil end

    local folder = gunName and Weapons:FindFirstChild(gunName)
    local vars   = folder and folder:FindFirstChild("Variables")
    local md     = vars and vars:FindFirstChild("MaxDamage")
    if not md or md.Value <= 0 then return nil end

    local rounds = math.ceil(Config.OneShot / md.Value)
    if rounds <= 1 then return nil end     -- one round already covers it

    local rpm = math.clamp(math.ceil(rounds / TAP_SECONDS * 60), 1, ONE_SHOT_RPM_CAP)
    local clip = vars:FindFirstChild("ClipSize")
    return rpm, rounds, md.Value, clip and clip.Value or nil
end

local function applyFireRate()
    for _, entry in ipairs(InventoryF:GetChildren()) do
        local folder = Weapons:FindFirstChild(entry.Name)
        local vars = folder and folder:FindFirstChild("Variables")
        local fr = vars and vars:FindFirstChild("FireRate")
        if fr then
            if originalRates[entry.Name] == nil then originalRates[entry.Name] = fr.Value end

            local osRPM = oneShotPlan(entry.Name)
            if osRPM then
                -- One Shot owns the cadence while it is set, Rate tab or not
                fr.Value = osRPM
            elseif Config.RateEnabled then
                fr.Value = math.floor(math.min(originalRates[entry.Name] * Config.RateMul, Config.RateCap))
            else
                fr.Value = originalRates[entry.Name]
            end
        end
    end
end

local function oneShotReadout()
    if (Config.OneShot or 0) <= 0 then return "off" end

    local gun = equipped
    if not gun then return "no weapon equipped" end

    local rpm, rounds, per, clip = oneShotPlan(gun)
    if not rpm then
        local folder = Weapons:FindFirstChild(gun)
        local vars = folder and folder:FindFirstChild("Variables")
        local md = vars and vars:FindFirstChild("MaxDamage")
        if md then
            return string.format("%s hits %d -- one round already covers %d", gun, md.Value, Config.OneShot)
        end
        return gun .. " has no damage value"
    end

    local warn = ""
    if clip and rounds > clip then warn = string.format("  !mag holds %d", clip) end
    return string.format("%s %ddmg x%d rounds @%d rpm%s", gun, per, rounds, rpm, warn)
end

applyRate = applyFireRate

--  No ammo override exists any more, and none can be added back.
--
--  The reserve is server-counted the same way the magazine is. Pinning it to 300
--  killed the TT30 first because its stock reserve is 45 against the M16A1's 125:
--  nine-round magazine, five reloads, and the server's pool was empty while the
--  client kept handing out more. From that point the client fires rounds the
--  server never issued and hit credit stops for the rest of the round, which is
--  why the rifle kept working through the same test and the pistol did not, and
--  why switching the toggle off changed nothing. The divergence is a tally, not a
--  setting -- only a rejoin clears it.
--
--  So the rule for this whole file: never hand the client a round the server did
--  not issue. The guard below holds every ammo figure at stock instead, and the
--  reload is made less painful through the engine's own perk rather than by
--  inventing ammunition.

--  FasterReloads is a LocalPlayer attribute read at equip (vortex.lua:8987). When
--  it is above zero the attachment string becomes "Fast Mags" and RunAnimation
--  plays every Reload / EmptyReload / Load / Charge frame set at 1.2x
--  (vortex.lua:762). Pure viewmodel animation -- no packet, no round, no tally.
local function applyFastReload()
    local want = Config.FastReload and 1 or 0
    if (LocalPlayer:GetAttribute("FasterReloads") or 0) ~= want then
        LocalPlayer:SetAttribute("FasterReloads", want)
    end
end

track(RunService.Heartbeat:Connect(applyFastReload))

-- Undo an older build of this script that wrote ClipSize / StoredAmmo straight
-- into ReplicatedStorage.Weapons. Those are what the server validates reloads
-- against, so a stomped value kills damage for the rest of the session.
-- Variables.Ammo is never written by this script, so it is the stock figure.
local function repairStompedAmmo()
    local fixed = {}
    for _, folder in ipairs(Weapons:GetChildren()) do
        local vars = folder:FindFirstChild("Variables")
        local twin = vars and vars:FindFirstChild("Ammo")
        local clip = vars and vars:FindFirstChild("ClipSize")
        if twin and clip and clip.Value ~= twin.Value then
            clip.Value = twin.Value
            table.insert(fixed, folder.Name)
        end
    end
    for _, entry in ipairs(InventoryF:GetChildren()) do
        if entry:IsA("StringValue") then
            local stock = stockAmmo(entry.Name)
            local mag, reserve, nr = parseAmmo(entry.Value)
            if stock and mag and mag > stock.clip then
                writeAmmo(entry, stock.clip, reserve, nr)
            end
        end
    end
    return fixed
end

local function restoreRates()
    for name, rpm in pairs(originalRates) do
        local folder = Weapons:FindFirstChild(name)
        local vars = folder and folder:FindFirstChild("Variables")
        local fr = vars and vars:FindFirstChild("FireRate")
        if fr then fr.Value = rpm end
    end
end

pcall(applyFireRate)                       -- seeds originalRates with the stock rpm
local stompRepaired = repairStompedAmmo()

--  Measured cadence. Vortex.Audio.Click:Play() runs once per shot on the line
--  straight after the Fire packet (vortex.lua:5751), so Sound.Played is an exact
--  per-shot tick. Keeps the last 24 and reports over the span they cover, which
--  makes a FireRate write either show up as a number or not at all.
local shotTimes = {}
local measuredRPM = 0
local lastShot = 0

local shotsFired, roundsSpent, lastHudMag = 0, 0, nil
local ledgerDrift, ledgerTripped = 0, false

-- Second, independent cadence: the HUD's own round counter. Sound.Played can be
-- dropped when Play() is called again while the clip is still running, so the
-- counter is the measure that cannot lie about how many rounds actually left.
local roundTimes = {}
local roundRPM = 0
local lastRound = 0

local function pushRound(n)
    local now = os.clock()
    lastRound = now
    for _ = 1, math.min(n, 4) do table.insert(roundTimes, now) end
    while #roundTimes > 24 do table.remove(roundTimes, 1) end
    while #roundTimes > 2 and (now - roundTimes[1]) > 1.25 do table.remove(roundTimes, 1) end

    local c = #roundTimes
    local span = roundTimes[c] - roundTimes[1]
    roundRPM = (c > 1 and span > 0) and ((c - 1) / span * 60) or 0
end

do
    local clickSound = VortexRoot:FindFirstChild("Audio")
    clickSound = clickSound and clickSound:FindFirstChild("Click")
    if clickSound then
        track(clickSound.Played:Connect(function()
            local now = os.clock()
            lastShot = now
            shotsFired += 1
            table.insert(shotTimes, now)
            if #shotTimes > 24 then table.remove(shotTimes, 1) end

            -- drop anything older than a second so bursts do not average with idle
            while #shotTimes > 2 and (now - shotTimes[1]) > 1.25 do
                table.remove(shotTimes, 1)
            end

            local n = #shotTimes
            local span = shotTimes[n] - shotTimes[1]
            measuredRPM = (n > 1 and span > 0) and ((n - 1) / span * 60) or 0
        end))
    end
end

--  LEDGER. The HUD's magazine counter is the engine's own round count, built
--  from three digit labels under PlayerGui.HUD.Ammo.Mag (1 = hundreds). Every
--  Click play is one Fire packet leaving; every step down in that counter is one
--  round actually spent. While those two move together the server's tally and
--  ours agree. The moment packets outrun rounds the server is being asked to
--  credit ammunition it never issued, which is the state that stops damage for
--  the rest of the round -- so the rate goes back to stock the instant it opens,
--  before a match is lost to it rather than after.
local LEDGER_SLACK = 3

local function hudMag()
    local gui = LocalPlayer:FindFirstChild("PlayerGui")
    local hud = gui and gui:FindFirstChild("HUD")
    local ammo = hud and hud:FindFirstChild("Ammo")
    local mag = ammo and ammo:FindFirstChild("Mag")
    if not mag then return nil end

    local n = 0
    for i = 1, 3 do
        local d = mag:FindFirstChild(tostring(i))
        local digit = d and tonumber(d.Text)
        if not digit then return nil end
        n = n * 10 + digit
    end
    return n
end

-- A swap from a 22-round rifle to a 9-round pistol drops the counter by 13 in one
-- frame, which the first version booked as thirteen rounds fired. Nothing fires
-- that fast: 1200 rpm is 20 rounds a second, a third of a round per frame, so any
-- single-frame fall past LEDGER_JUMP is the counter being replaced rather than
-- spent. A weapon change resets it for the same reason.
local LEDGER_JUMP = 3
local ledgerWeapon = nil

local lastRunShots, lastRunRounds = 0, 0

local function ledgerReset(now)
    -- keep the run that just ended, otherwise the auto-reload at the end of a
    -- magazine wipes the result the moment it finishes being interesting
    if shotsFired > 0 or roundsSpent > 0 then
        lastRunShots, lastRunRounds = shotsFired, roundsSpent
    end
    shotsFired, roundsSpent, ledgerDrift = 0, 0, 0
    lastHudMag = now
end

local function ledgerStep()
    local now = hudMag()
    if not now then return end

    local gun = activeWeaponName()
    if gun ~= ledgerWeapon then
        ledgerWeapon = gun
        ledgerReset(now)
        return
    end

    if lastHudMag == nil then lastHudMag = now; return end

    local drop = lastHudMag - now
    if drop > LEDGER_JUMP then
        ledgerReset(now)                -- counter swapped out, not fired down
        return
    elseif drop > 0 then
        roundsSpent += drop
        pushRound(drop)
    elseif drop < 0 then
        ledgerReset(now)                -- reloaded, both sides full again
        return
    end
    lastHudMag = now

    ledgerDrift = shotsFired - roundsSpent
    if ledgerDrift > LEDGER_SLACK and not ledgerTripped then
        ledgerTripped = true
        if Config.RateEnabled then
            Config.RateEnabled = false
            pcall(applyFireRate)
        end
    end
end

track(RunService.Heartbeat:Connect(ledgerStep))

local function rateReadout()
    local name = activeWeaponName()
    local folder = name and Weapons:FindFirstChild(name)
    local vars = folder and folder:FindFirstChild("Variables")
    local fr = vars and vars:FindFirstChild("FireRate")
    local set = fr and fr.Value or 0
    local stock = name and originalRates[name] or set

    if ledgerTripped then
        return string.format("REVERTED to stock -- %d packets ran past the rounds the server issued",
            ledgerDrift)
    end

    -- a semi-auto fires once per click, so holding the trigger gives one sample
    -- and a meaningless number. Say so instead of printing it.
    local auto = vars and vars:FindFirstChild("FullAuto")
    if auto and auto.Value ~= true then
        return string.format("set %d rpm (stock %d) -- %s is semi-auto, hold fire on a full-auto gun",
            set, stock, tostring(name))
    end

    local idle = math.min(os.clock() - lastShot, os.clock() - lastRound)
    if idle > 1.5 then
        measuredRPM, roundRPM = 0, 0
        return string.format("set %d rpm (stock %d) -- hold fire to measure  [last run: clicks %d / rounds %d]",
            set, stock, math.max(shotsFired, lastRunShots), math.max(roundsSpent, lastRunRounds))
    end

    -- both counts, always. clicks is the Fire packet, rounds is the magazine the
    -- engine actually spent. they disagreeing is itself the finding.
    return string.format("set %d rpm (stock %d)  clicks %d @%.0f  rounds %d @%.0f",
        set, stock, shotsFired, measuredRPM, roundsSpent, roundRPM)
end

--============================================================================
-- esp
--============================================================================

local ESP_BIND = "aurora_esp"

local espGui = Instance.new("ScreenGui")
espGui.Name = "aurora_esp"
espGui.ResetOnSpawn = false
espGui.IgnoreGuiInset = true
espGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
espGui.DisplayOrder = 98
espGui.Parent = GUI_HOST

local SKELETON = {
    { "Head", "UpperTorso" }, { "UpperTorso", "LowerTorso" },
    { "UpperTorso", "LeftUpperArm" }, { "LeftUpperArm", "LeftLowerArm" }, { "LeftLowerArm", "LeftHand" },
    { "UpperTorso", "RightUpperArm" }, { "RightUpperArm", "RightLowerArm" }, { "RightLowerArm", "RightHand" },
    { "LowerTorso", "LeftUpperLeg" }, { "LeftUpperLeg", "LeftLowerLeg" }, { "LeftLowerLeg", "LeftFoot" },
    { "LowerTorso", "RightUpperLeg" }, { "RightUpperLeg", "RightLowerLeg" }, { "RightLowerLeg", "RightFoot" },
}

local function rainbow(offset)
    return Color3.fromHSV(((tick() * 0.22) + (offset or 0)) % 1, 0.82, 1)
end

local espPool = {}

local function newLine(parent)
    local f = Instance.new("Frame")
    f.BorderSizePixel = 0
    f.AnchorPoint = Vector2.new(0.5, 0.5)
    f.BackgroundColor3 = Color3.new(1, 1, 1)
    f.Visible = false
    f.Parent = parent
    return f
end

local function buildEntry()
    local holder = Instance.new("Frame")
    holder.BackgroundTransparency = 1
    holder.Size = UDim2.fromScale(1, 1)
    holder.Visible = false
    holder.Parent = espGui

    local box = Instance.new("Frame")
    box.BackgroundTransparency = 1
    box.BorderSizePixel = 0
    box.Parent = holder
    local stroke = Instance.new("UIStroke")
    stroke.Thickness = 1.4
    stroke.Parent = box

    local healthBg = Instance.new("Frame")
    healthBg.BorderSizePixel = 0
    healthBg.BackgroundColor3 = Color3.fromRGB(8, 8, 12)
    healthBg.Visible = false
    healthBg.Parent = holder

    local healthFill = Instance.new("Frame")
    healthFill.BorderSizePixel = 0
    healthFill.AnchorPoint = Vector2.new(0, 1)
    healthFill.Position = UDim2.fromScale(0, 1)
    healthFill.Parent = healthBg

    local function label()
        local t = Instance.new("TextLabel")
        t.BackgroundTransparency = 1
        t.Font = Enum.Font.GothamBold
        t.TextStrokeTransparency = 0.3
        t.TextStrokeColor3 = Color3.new(0, 0, 0)
        t.Size = UDim2.fromOffset(260, 14)
        t.AnchorPoint = Vector2.new(0.5, 0.5)
        t.Visible = false
        t.Parent = holder
        return t
    end

    local bones = {}
    for i = 1, #SKELETON do bones[i] = newLine(holder) end

    return {
        holder = holder, box = box, stroke = stroke,
        healthBg = healthBg, healthFill = healthFill,
        name = label(), info = label(), bones = bones,
        tracer = newLine(holder), highlight = nil,
    }
end

local function entryFor(model)
    local e = espPool[model]
    if not e then e = buildEntry(); espPool[model] = e end
    return e
end

local function espStep()
    local cam = workspace.CurrentCamera
    if not cam then return end

    local live = {}

    if Config.EspEnabled then
        local ffa = ffaActive()
        local viewport = cam.ViewportSize

        for _, model in ipairs(allCharacters()) do
            if isEnemy(model, ffa, Config.EspBots, Config.EspPlayers) then
                local hum = model:FindFirstChildOfClass("Humanoid")
                local root = model.PrimaryPart
                local dist = (cam.CFrame.Position - root.Position).Magnitude

                if dist <= Config.EspMaxDist then
                    local cf, size = model:GetBoundingBox()
                    local minX, minY, maxX, maxY = math.huge, math.huge, -math.huge, -math.huge
                    local onScreen = false

                    for xs = -1, 1, 2 do for ys = -1, 1, 2 do for zs = -1, 1, 2 do
                        local world = (cf * CFrame.new(size.X / 2 * xs, size.Y / 2 * ys, size.Z / 2 * zs)).Position
                        local sp, vis = cam:WorldToViewportPoint(world)
                        if vis then onScreen = true end
                        if sp.Z > 0 then
                            minX = math.min(minX, sp.X); maxX = math.max(maxX, sp.X)
                            minY = math.min(minY, sp.Y); maxY = math.max(maxY, sp.Y)
                        end
                    end end end

                    if onScreen and minX < math.huge then
                        live[model] = true
                        local e = entryFor(model)
                        e.holder.Visible = true

                        local bot = isBot(model)
                        local col = Config.EspRainbow and rainbow(bot and 0.35 or 0)
                                    or (bot and Color3.fromRGB(255, 165, 60) or Color3.fromRGB(255, 70, 95))
                        local w, h = maxX - minX, maxY - minY

                        e.box.Visible = Config.EspBox
                        e.box.Position = UDim2.fromOffset(minX, minY)
                        e.box.Size = UDim2.fromOffset(w, h)
                        e.stroke.Color = col

                        e.healthBg.Visible = Config.EspHealth
                        e.healthBg.Position = UDim2.fromOffset(minX - 6, minY)
                        e.healthBg.Size = UDim2.fromOffset(3, h)
                        local frac = math.clamp(hum.Health / math.max(hum.MaxHealth, 1), 0, 1)
                        e.healthFill.Size = UDim2.new(1, 0, frac, 0)
                        e.healthFill.BackgroundColor3 = Color3.fromRGB(255, 60, 60):Lerp(Color3.fromRGB(70, 230, 125), frac)

                        e.name.Visible = Config.EspName
                        e.name.Text = model.Name
                        e.name.TextColor3 = col
                        e.name.TextSize = Config.EspTextSize
                        e.name.Position = UDim2.fromOffset(minX + w / 2, minY - 10)

                        e.info.Visible = Config.EspDistance
                        e.info.Text = string.format("%.0fm  %.0fhp", dist, hum.Health)
                        e.info.TextColor3 = col
                        e.info.TextSize = Config.EspTextSize - 1
                        e.info.Position = UDim2.fromOffset(minX + w / 2, maxY + 9)

                        for i, pair in ipairs(SKELETON) do
                            local line = e.bones[i]
                            local a, b = model:FindFirstChild(pair[1]), model:FindFirstChild(pair[2])
                            if Config.EspSkeleton and a and b then
                                local pa = cam:WorldToViewportPoint(a.Position)
                                local pb = cam:WorldToViewportPoint(b.Position)
                                if pa.Z > 0 and pb.Z > 0 then
                                    local d = Vector2.new(pb.X - pa.X, pb.Y - pa.Y)
                                    line.Visible = true
                                    line.BackgroundColor3 = col
                                    line.Position = UDim2.fromOffset((pa.X + pb.X) / 2, (pa.Y + pb.Y) / 2)
                                    line.Size = UDim2.fromOffset(d.Magnitude, 1)
                                    line.Rotation = math.deg(math.atan2(d.Y, d.X))
                                else
                                    line.Visible = false
                                end
                            else
                                line.Visible = false
                            end
                        end

                        if Config.EspTracer then
                            local pa = Vector2.new(viewport.X / 2, viewport.Y)
                            local pb = Vector2.new(minX + w / 2, maxY)
                            local d = pb - pa
                            e.tracer.Visible = true
                            e.tracer.BackgroundColor3 = col
                            e.tracer.Position = UDim2.fromOffset((pa.X + pb.X) / 2, (pa.Y + pb.Y) / 2)
                            e.tracer.Size = UDim2.fromOffset(d.Magnitude, 1)
                            e.tracer.Rotation = math.deg(math.atan2(d.Y, d.X))
                        else
                            e.tracer.Visible = false
                        end

                        if Config.EspChams then
                            if not e.highlight then
                                e.highlight = Instance.new("Highlight")
                                e.highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
                                e.highlight.FillTransparency = 0.55
                                e.highlight.Parent = espGui
                            end
                            e.highlight.Adornee = model
                            e.highlight.Enabled = true
                            e.highlight.FillColor = col
                            e.highlight.OutlineColor = col
                        elseif e.highlight then
                            e.highlight.Enabled = false
                        end
                    end
                end
            end
        end
    end

    for model, e in pairs(espPool) do
        if not live[model] then
            e.holder.Visible = false
            if e.highlight then e.highlight.Enabled = false end
            if not model.Parent then
                if e.highlight then e.highlight:Destroy() end
                e.holder:Destroy()
                espPool[model] = nil
            end
        end
    end
end

pcall(function() RunService:UnbindFromRenderStep(ESP_BIND) end)
RunService:BindToRenderStep(ESP_BIND, Enum.RenderPriority.Last.Value, espStep)

--============================================================================
-- ui  --  GTA mod menu (NativeUI shape)
--
--  Replicated from ui_ref/03_nativeui_player_options.webp and 04_..._weapon.webp:
--  accent banner, pure black subtitle bar with the page name in caps, rows on a
--  translucent black panel, the selected row a WHITE fill with BLACK text, ">>>"
--  for a submenu, a hollow square on the right for a toggle, a plain right
--  aligned value for everything else, then a description band carrying the text
--  for the HIGHLIGHTED row. The "<i> / <n>" counter and the accent section
--  headers come from 01/02 (Claude Menu), because a 186 entry weapon list needs
--  both and those shots have no equivalent.
--
--  Keyboard only: Up/Down move, Left/Right change a value, Enter selects,
--  Backspace goes back, a letter jumps in a long list. Arrows also drive this
--  game's StreakUp/StreakDown bindings, which is harmless while the streak
--  counts sit at 0.
--============================================================================

local PANEL_W   = 384
local BANNER_H  = 96
local SUB_H     = 34
local ROW_H     = 33
local DESC_H    = 29
local HELP_H    = 24
local MAX_ROWS  = 11
local PAD_X     = 12

local THEMES = {
    Galaxy = { Color3.fromRGB(44, 16, 104),  Color3.fromRGB(150, 86, 255) },
    Blue   = { Color3.fromRGB(4, 63, 136),   Color3.fromRGB(46, 114, 212) },   -- sampled off 03
    Green  = { Color3.fromRGB(26, 160, 90),  Color3.fromRGB(26, 160, 90)  },
    Red    = { Color3.fromRGB(190, 40, 48),  Color3.fromRGB(190, 40, 48)  },
    Orange = { Color3.fromRGB(214, 112, 24), Color3.fromRGB(214, 112, 24) },
    Mono   = { Color3.fromRGB(28, 28, 32),   Color3.fromRGB(28, 28, 32)   },
}
local THEME_ORDER = { "Galaxy", "Blue", "Green", "Red", "Orange", "Mono", "Custom" }

local function themeColors()
    if Config.Theme == "Custom" then
        local c = Color3.fromRGB(Config.ThemeR, Config.ThemeG, Config.ThemeB)
        return c, c
    end
    local t = THEMES[Config.Theme] or THEMES.Galaxy
    return t[1], t[2]
end

local FAST   = TweenInfo.new(0.10, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local SLIDE  = TweenInfo.new(0.13, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)

local function new(class, props, parent)
    local i = Instance.new(class)
    for k, v in pairs(props or {}) do i[k] = v end
    if parent then i.Parent = parent end
    return i
end

-- Chalet London Nineteen Sixty is the real gta UI face, and it is on disk now,
-- so the Arimo stand-in is only the fallback. The ttf carries one weight, so
-- bold stays on Arimo: headers and the subtitle need the weight step, and the
-- two faces are both Arial-metric grotesques, so they sit together cleanly.
-- Enum.Font.Arimo silently resolves to Gotham in this client, which is why the
-- family asset is named directly rather than through the enum.
local MONT = "rbxasset://fonts/families/Arimo.json"
local function face(weight)
    return Font.new(MONT, weight or Enum.FontWeight.Regular, Enum.FontStyle.Normal)
end
local F_BOLD, F_HEAVY = face(Enum.FontWeight.Bold), face(Enum.FontWeight.ExtraBold)
local F_CHALET = nil     -- filled in once loadDiskFace is defined, below
local F_COMP   = nil     -- Chalet Comprime, the condensed cut, same place
local F_REG, F_MED = face(), face(Enum.FontWeight.Medium)

local COND = "rbxasset://fonts/families/Oswald.json"

-- Pricedown is the GTA title face -- box art, mission cards, the WASTED screen.
-- Roblox ships nothing close, so it is loaded straight off disk: getcustomasset
-- hands the otf to the engine, and a one face family json points at it. Both
-- files have to sit under the executor workspace, getcustomasset refuses any
-- path outside it. Oswald stays as the fallback so a missing font file costs
-- the look and nothing else.
-- one loader, any face. Each call writes its own family json next to the font
-- file, so adding a skin's typeface is a line, not a second code path.
local FONT_DIR = "aurora_fonts/"

local function loadDiskFace(fileName, familyName)
    if type(getcustomasset) ~= "function" or type(writefile) ~= "function" then return nil end
    if type(isfile) ~= "function" then return nil end

    local path = FONT_DIR .. fileName
    if not isfile(path) then return nil end

    local ok, face = pcall(function()
        local asset = getcustomasset(path)
        local famPath = FONT_DIR .. familyName .. ".json"
        writefile(famPath, HttpService:JSONEncode({
            name  = familyName,
            faces = { { name = "Regular", weight = 400, style = "normal", assetId = asset } },
        }))
        return Font.new(getcustomasset(famPath), Enum.FontWeight.Regular, Enum.FontStyle.Normal)
    end)

    return ok and face or nil
end

-- Pricedown is the gta title face: box art, mission cards, the WASTED screen.
-- Griffiths is the script cut BlackFox hangs over its white cap. Neither ships
-- with roblox, both sit in aurora_fonts/ and load off disk. Oswald is the
-- fallback, so a missing file costs the look and nothing else.
--============================================================================
-- assets
--  Every face and the wheel art are FILES, not roblox uploads, so a machine
--  that has never run this has none of them. ensureAssets pulls whatever is
--  missing once and writes it into the exec workspace; after that it is six
--  isfile checks and nothing else. Nothing here is fatal: if http is blocked,
--  the host is down, or the executor has no writefile, the file simply stays
--  missing and each loader below falls back on its own (Oswald and Arimo for
--  the faces, no wedges for the wheel).
--============================================================================

local ASSET_HOST = "https://raw.githubusercontent.com/hahajaiisiu22/aurora-assets/main/"

local ASSETS = {
    { dir = "aurora_fonts", path = "aurora_fonts/Pricedown.otf",      url = "fonts/Pricedown.otf",      min = 40000 },
    { dir = "aurora_fonts", path = "aurora_fonts/ChaletLondon.ttf",   url = "fonts/ChaletLondon.ttf",   min = 60000 },
    { dir = "aurora_fonts", path = "aurora_fonts/ChaletComprime.ttf", url = "fonts/ChaletComprime.ttf", min = 60000 },
    { dir = "aurora_fonts", path = "aurora_fonts/Griffiths.otf",      url = "fonts/Griffiths.otf",      min = 15000 },
    { dir = "aurora_art",   path = "aurora_art/wedge.png",            url = "art/wedge.png",            min = 2000  },
    { dir = "aurora_art",   path = "aurora_art/arc.png",              url = "art/arc.png",              min = 1500  },
}

local assetReport = "assets: executor cannot write files"

-- The load NEVER waits on the network. game:HttpGet has to pause mid call while
-- the request flies, and the thread an executor runs a script on is not always
-- allowed to pause -- solara froze solid the first time this was done inline.
-- So the fetch runs in a thread of its own and the script carries on with
-- whatever is already on disk. Files that land are used on the next run, which
-- is what the printed line tells the user to do.
local function ensureAssets()
    if type(writefile) ~= "function" or type(isfile) ~= "function" then return end

    local missing = {}
    local have = 0
    for _, a in ipairs(ASSETS) do
        if isfile(a.path) then have += 1 else missing[#missing + 1] = a end
    end

    if #missing == 0 then
        assetReport = string.format("assets: all %d on disk", have)
        return
    end

    assetReport = string.format("assets: %d on disk, fetching %d in the background -- "
        .. "run the script again once it says done", have, #missing)

    task.spawn(function()
        local got, failed = 0, 0
        for _, a in ipairs(missing) do
            if type(makefolder) == "function" and type(isfolder) == "function" and not isfolder(a.dir) then
                pcall(makefolder, a.dir)
            end

            local ok, body = pcall(function() return game:HttpGet(ASSET_HOST .. a.url, true) end)
            -- a short body is an error page, not a font, so size is checked
            -- before anything is written
            if ok and type(body) == "string" and #body >= a.min and pcall(writefile, a.path, body) then
                got += 1
            else
                failed += 1
            end
        end

        print(string.format("[aurora] assets done: %d fetched, %d failed -- re-run the script", got, failed))
    end)
end

ensureAssets()

-- same door as the fonts: a png on disk becomes an rbxasset the engine cannot
-- tell from an uploaded one. The wheel's wedges are generated art, not uploads.
local function loadDiskImage(relPath)
    if type(getcustomasset) ~= "function" or type(isfile) ~= "function" then return nil end
    if not isfile(relPath) then return nil end
    local ok, id = pcall(getcustomasset, relPath)
    return ok and id or nil
end

-- Chalet London is the body face. Chalet Comprime Cologne Sixty is the
-- condensed cut rockstar puts on section headers and the wheel's hub label --
-- same family, narrower, which is what gives those two their own voice without
-- reaching for a second typeface.
F_CHALET = loadDiskFace("ChaletLondon.ttf", "ChaletLondon")
F_COMP   = loadDiskFace("ChaletComprime.ttf", "ChaletComprime")
if F_CHALET then
    F_REG, F_MED = F_CHALET, F_CHALET
end

local F_BANNER = loadDiskFace("Pricedown.otf", "Pricedown")
                 or Font.new(COND, Enum.FontWeight.Regular, Enum.FontStyle.Normal)
local F_SCRIPT = loadDiskFace("Griffiths.otf", "Griffiths") or F_BANNER
-- the subtitle strip under the banner is chalet in gta, not a condensed face
local F_SUB    = F_CHALET or Font.new(COND, Enum.FontWeight.Medium, Enum.FontStyle.Normal)

-- SKINS. Each one is a whole panel look lifted off a real gta 5 mod menu, not
-- a palette swap: banner fill, title cut, list ground, row ink, the chevron a
-- submenu draws. Theme still drives the Aurora banner ramp; every other skin
-- paints its own banner and ignores it.
--
--   bannerMode  "gradient" takes the theme ramp, "solid" uses bannerA
--   slant       degrees of rake, drawn band by band -- roblox has no skew
--   bandBg      the desc and help strips under the list
local SKINS = {
    -- the matched default: blue ramp, white pricedown, black list
    Aurora = {
        bannerMode = "gradient",
        titleColor = Color3.new(1, 1, 1), titleSize = 60, titleUpper = false,
        titleAlign = Enum.TextXAlignment.Center, slant = 0,
        subBg = Color3.new(0, 0, 0), subAlpha = 0.05, subText = Color3.new(1, 1, 1),
        listBg = Color3.new(0, 0, 0), listAlpha = 0.45,
        rowText = Color3.new(1, 1, 1), rowSize = 16,
        hlColor = Color3.new(1, 1, 1), hlAlpha = 0.06, rowTextSel = Color3.new(0, 0, 0),
        bandBg = Color3.new(0, 0, 0), bandAlpha = 0.05, bandText = Color3.new(1, 1, 1),
        headerFromTheme = true, danger = Color3.fromRGB(235, 86, 86), arrow = ">>>",
    },

    -- JJ Menu Trainer: red strip, white sheet, black ink, hairline rules
    JJ = {
        bannerMode = "solid", bannerA = Color3.fromRGB(226, 66, 24),
        titleColor = Color3.new(1, 1, 1), titleSize = 38, titleUpper = true,
        titleAlign = Enum.TextXAlignment.Left, slant = 0,
        subBg = Color3.fromRGB(28, 28, 30), subAlpha = 0.05, subText = Color3.new(1, 1, 1),
        listBg = Color3.fromRGB(248, 248, 248), listAlpha = 0.04,
        rowText = Color3.fromRGB(16, 16, 16), rowSize = 16,
        hlColor = Color3.fromRGB(226, 66, 24), hlAlpha = 0.12, rowTextSel = Color3.new(1, 1, 1),
        bandBg = Color3.fromRGB(238, 238, 238), bandAlpha = 0.04, bandText = Color3.fromRGB(20, 20, 20),
        headerFromTheme = false, headerColor = Color3.fromRGB(226, 66, 24),
        danger = Color3.fromRGB(198, 32, 32), arrow = ">",
    },

    -- BlackFox: white cap, violet script, hard black bar, smoked list. The list
    -- is not paper -- the reference shows the scene straight through it, so the
    -- ground is dark and thin, with the violet ink carrying the contrast.
    BlackFox = {
        bannerMode = "solid", bannerA = Color3.fromRGB(252, 252, 252),
        titleFace = "script",
        titleColor = Color3.fromRGB(150, 128, 232), titleSize = 50, titleUpper = false,
        titleAlign = Enum.TextXAlignment.Center, slant = 0,
        subBg = Color3.new(0, 0, 0), subAlpha = 0, subText = Color3.new(1, 1, 1),
        listBg = Color3.fromRGB(26, 20, 34), listAlpha = 0.42,
        rowText = Color3.fromRGB(176, 156, 244), rowSize = 17,
        hlColor = Color3.fromRGB(236, 236, 242), hlAlpha = 0.12, rowTextSel = Color3.fromRGB(38, 28, 86),
        bandBg = Color3.fromRGB(16, 12, 22), bandAlpha = 0.2, bandText = Color3.new(1, 1, 1),
        headerFromTheme = false, headerColor = Color3.new(1, 1, 1),
        danger = Color3.fromRGB(226, 62, 62), arrow = ">>>",
    },

    -- Firah: amber block, outlined caps, smoked list
    Firah = {
        bannerMode = "solid", bannerA = Color3.fromRGB(247, 166, 24),
        titleColor = Color3.new(1, 1, 1), titleSize = 44, titleUpper = true,
        titleAlign = Enum.TextXAlignment.Center, slant = 0,
        subBg = Color3.fromRGB(178, 178, 178), subAlpha = 0.1, subText = Color3.new(0, 0, 0),
        listBg = Color3.new(0, 0, 0), listAlpha = 0.38,
        rowText = Color3.new(1, 1, 1), rowSize = 18,
        hlColor = Color3.fromRGB(196, 196, 196), hlAlpha = 0.18, rowTextSel = Color3.new(0, 0, 0),
        bandBg = Color3.new(0, 0, 0), bandAlpha = 0.2, bandText = Color3.new(1, 1, 1),
        headerFromTheme = false, headerColor = Color3.fromRGB(247, 166, 24),
        danger = Color3.fromRGB(236, 90, 72), arrow = "",
    },
}
local SKIN_ORDER = { "Aurora", "JJ", "BlackFox", "Firah" }

local function skin() return SKINS[Config.Skin] or SKINS.Aurora end

-- a skin names its title cut, not a Font object, so the table stays data
local function titleFaceFor(sk) return (sk.titleFace == "script") and F_SCRIPT or F_BANNER end

local function tween(inst, info, props) TweenService:Create(inst, info, props):Play() end

local render   -- forward: the row widgets below call it from their own handlers

for _, old in ipairs(GUI_HOST:GetChildren()) do
    if old.Name == "aurora_ui" then old:Destroy() end
end

local screen = new("ScreenGui", {
    Name = "aurora_ui",
    ResetOnSpawn = false,
    IgnoreGuiInset = true,
    ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
    DisplayOrder = 99,
}, GUI_HOST)

local root = new("Frame", {
    Size = UDim2.fromOffset(PANEL_W, BANNER_H + SUB_H + ROW_H * MAX_ROWS + DESC_H + HELP_H),
    Position = UDim2.fromOffset(Config.PanelX, Config.PanelY),
    BackgroundTransparency = 1,
    Visible = false,
}, screen)

--------------------------------------------------------------------- banner
local banner = new("Frame", {
    Size = UDim2.new(1, 0, 0, BANNER_H),
    BackgroundColor3 = Color3.fromRGB(30, 99, 200),
    BorderSizePixel = 0,
}, root)

local bannerGrad = new("UIGradient", { Rotation = 0 }, banner)

-- drag by the banner, the way the old panel moved. The position is kept in the
-- config so it survives a reload instead of snapping back to the corner.
do
    local dragging, dragStart, startPos = false, nil, nil

    banner.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then
            dragging, dragStart, startPos = true, input.Position, root.Position
        end
    end)

    banner.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then
            dragging = false
            Config.PanelX = root.Position.X.Offset
            Config.PanelY = root.Position.Y.Offset
        end
    end)

    track(UserInputService.InputChanged:Connect(function(input)
        if not dragging then return end
        if input.UserInputType == Enum.UserInputType.MouseMovement
        or input.UserInputType == Enum.UserInputType.Touch then
            local d = input.Position - dragStart
            root.Position = UDim2.fromOffset(startPos.X.Offset + d.X, startPos.Y.Offset + d.Y)
        end
    end))
end

-- no shadow: the reference glyph edges are symmetric antialiasing, nothing under them
local bannerText = new("TextLabel", {
    Size = UDim2.new(1, -24, 1, -10),
    Position = UDim2.fromOffset(12, 5),
    BackgroundTransparency = 1,
    FontFace = F_BANNER,
    TextScaled = true,
    TextSize = 60,
    TextColor3 = Color3.new(1, 1, 1),
    Text = "Aurora Loader",
}, banner)

local bannerFit = new("UITextSizeConstraint", { MaxTextSize = 60, MinTextSize = 18 }, bannerText)

-- OBLIQUE. Roblox has no skew on a GuiObject and it does not synthesize an
-- italic either -- FontStyle.Italic on Oswald returns a byte identical width and
-- silently keeps the upright cut. So the slant is built: the title is drawn once
-- per 2px horizontal band, each band clipped to its own strip and shifted in x
-- by (pivot - bandCentre) * tan(angle). That is a real shear, any font, any
-- angle, and it is what lets Oswald reach the reference's 23.2 degrees.
local BAND_H = 2
local BAND_N = math.ceil(BANNER_H / BAND_H)

local obliqueHolder = new("Frame", {
    Size = UDim2.fromScale(1, 1),
    BackgroundTransparency = 1,
    Visible = false,
}, banner)

local bands = {}
for i = 1, BAND_N do
    local clip = new("Frame", {
        Size = UDim2.new(1, 0, 0, BAND_H),
        Position = UDim2.fromOffset(0, (i - 1) * BAND_H),
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        ClipsDescendants = true,
    }, obliqueHolder)

    bands[i] = new("TextLabel", {
        Size = UDim2.new(1, 0, 0, BANNER_H),
        Position = UDim2.fromOffset(0, -(i - 1) * BAND_H),
        BackgroundTransparency = 1,
        FontFace = F_BANNER,
        TextSize = 60,
        TextColor3 = Color3.new(1, 1, 1),
        Text = "Aurora Loader",
    }, clip)
end

--------------------------------------------------------------------- subtitle
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
    FontFace = F_SUB,
    TextSize = 17,
    TextColor3 = Color3.new(1, 1, 1),
    TextXAlignment = Enum.TextXAlignment.Left,
    TextTruncate = Enum.TextTruncate.AtEnd,
    Text = "AURORA",
}, subBar)

local subCount = new("TextLabel", {
    Size = UDim2.fromOffset(78, SUB_H),
    Position = UDim2.new(1, -78 - PAD_X, 0, 0),
    BackgroundTransparency = 1,
    FontFace = F_SUB,
    TextSize = 17,
    TextColor3 = Color3.new(1, 1, 1),
    TextXAlignment = Enum.TextXAlignment.Right,
    Text = "1 / 1",
}, subBar)

--------------------------------------------------------------------- rows
local LIST_Y = BANNER_H + SUB_H
local LIST_H = ROW_H * MAX_ROWS

local listArea = new("Frame", {
    Size = UDim2.new(1, 0, 0, LIST_H),
    Position = UDim2.fromOffset(0, LIST_Y),
    BackgroundColor3 = Color3.new(0, 0, 0),
    BackgroundTransparency = 0.45,
    BorderSizePixel = 0,
    ClipsDescendants = true,
}, root)

-- the white bar is one frame that slides, rather than a fill per row
local highlight = new("Frame", {
    Size = UDim2.new(1, 0, 0, ROW_H),
    Position = UDim2.fromOffset(0, 0),
    BackgroundColor3 = Color3.fromRGB(255, 255, 255),
    BackgroundTransparency = 0.06,
    BorderSizePixel = 0,
    Visible = false,
    ZIndex = 1,
}, listArea)

local rows = {}

for i = 1, MAX_ROWS do
    local holder = new("Frame", {
        Size = UDim2.new(1, 0, 0, ROW_H),
        Position = UDim2.fromOffset(0, (i - 1) * ROW_H),
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        ZIndex = 2,
    }, listArea)

    local label = new("TextLabel", {
        Size = UDim2.new(1, -140, 1, 0),
        Position = UDim2.fromOffset(PAD_X, 0),
        BackgroundTransparency = 1,
        FontFace = F_REG,
        TextSize = 16,
        TextColor3 = Color3.new(1, 1, 1),
        TextXAlignment = Enum.TextXAlignment.Left,
        TextTruncate = Enum.TextTruncate.AtEnd,
        Text = "",
        ZIndex = 2,
    }, holder)

    local value = new("TextLabel", {
        Size = UDim2.fromOffset(176, ROW_H),
        Position = UDim2.new(1, -176 - PAD_X, 0, 0),
        BackgroundTransparency = 1,
        FontFace = F_REG,
        TextSize = 16,
        TextColor3 = Color3.new(1, 1, 1),
        TextXAlignment = Enum.TextXAlignment.Right,
        TextTruncate = Enum.TextTruncate.AtEnd,
        Text = "",
        ZIndex = 2,
    }, holder)

    -- typed field, used by the entry rows. One per row, hidden until a row
    -- that wants it lands here -- rows are recycled, so nothing is created
    -- while the menu is open.
    local field = new("TextBox", {
        Size = UDim2.fromOffset(92, ROW_H - 10),
        Position = UDim2.new(1, -92 - PAD_X, 0, 5),
        BackgroundColor3 = Color3.new(0, 0, 0),
        BackgroundTransparency = 0.35,
        BorderSizePixel = 0,
        FontFace = F_REG,
        TextSize = 15,
        TextColor3 = Color3.new(1, 1, 1),
        TextXAlignment = Enum.TextXAlignment.Center,
        ClearTextOnFocus = false,
        Text = "",
        Visible = false,
        ZIndex = 3,
    }, holder)

    -- hollow square, exactly as the reference draws an unchecked toggle
    local box = new("Frame", {
        Size = UDim2.fromOffset(19, 19),
        Position = UDim2.new(1, -19 - PAD_X - 4, 0.5, -9),
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        Visible = false,
        ZIndex = 2,
    }, holder)
    local boxStroke = new("UIStroke", { Thickness = 1.6, Color = Color3.new(1, 1, 1) }, box)
    local boxFill = new("Frame", {
        Size = UDim2.fromScale(1, 1),
        BackgroundColor3 = Color3.new(1, 1, 1),
        BorderSizePixel = 0,
        Visible = false,
        ZIndex = 2,
    }, box)

    -- the thin rule a section header carries under it in 02
    local rule = new("Frame", {
        Size = UDim2.new(1, -PAD_X * 2, 0, 1),
        Position = UDim2.new(0, PAD_X, 1, -1),
        BackgroundColor3 = Color3.fromRGB(120, 120, 130),
        BackgroundTransparency = 0.45,
        BorderSizePixel = 0,
        Visible = false,
        ZIndex = 2,
    }, holder)

    rows[i] = {
        holder = holder, label = label, value = value, field = field,
        box = box, boxStroke = boxStroke, boxFill = boxFill, rule = rule,
    }

    -- commit on Enter, discard on click-away. The row the box belongs to is
    -- whatever render last put there, so the item is read at commit time.
    track(field.FocusLost:Connect(function(enterPressed)
        local ui = rows[i]
        local item = ui.item
        if not item or item.kind ~= "entry" then return end

        if enterPressed then
            local n = tonumber(field.Text)
            if n then
                n = math.clamp(n, item.min, item.max)
                Config[item.key] = n
                if item.onChange then task.spawn(item.onChange, n) end
            end
        end
        render()
    end))
end

-- "more above / more below" arrows, drawn over the first and last row
local upArrow = new("TextLabel", {
    Size = UDim2.fromOffset(16, 14),
    Position = UDim2.new(1, -16 - 3, 0, 1),
    BackgroundTransparency = 1,
    FontFace = F_BOLD,
    TextSize = 11,
    TextColor3 = Color3.fromRGB(180, 180, 190),
    Text = "^",
    Visible = false,
    ZIndex = 3,
}, listArea)

local downArrow = new("TextLabel", {
    Size = UDim2.fromOffset(16, 14),
    Position = UDim2.new(1, -16 - 3, 1, -15),
    BackgroundTransparency = 1,
    FontFace = F_BOLD,
    TextSize = 11,
    TextColor3 = Color3.fromRGB(180, 180, 190),
    Text = "v",
    Visible = false,
    ZIndex = 3,
}, listArea)

--------------------------------------------------------------------- bands
local descBar = new("Frame", {
    Size = UDim2.new(1, 0, 0, DESC_H),
    Position = UDim2.fromOffset(0, LIST_Y + LIST_H),
    BackgroundColor3 = Color3.new(0, 0, 0),
    BackgroundTransparency = 0.05,
    BorderSizePixel = 0,
}, root)

local descRule = new("Frame", {
    Size = UDim2.new(1, 0, 0, 1),
    BackgroundColor3 = Color3.fromRGB(210, 210, 216),
    BackgroundTransparency = 0.25,
    BorderSizePixel = 0,
}, descBar)

local descText = new("TextLabel", {
    Size = UDim2.new(1, -PAD_X * 2, 1, -2),
    Position = UDim2.fromOffset(PAD_X, 2),
    BackgroundTransparency = 1,
    FontFace = F_REG,
    TextSize = 13,
    TextColor3 = Color3.new(1, 1, 1),
    TextXAlignment = Enum.TextXAlignment.Left,
    TextTruncate = Enum.TextTruncate.AtEnd,
    Text = "",
}, descBar)

local helpBar = new("Frame", {
    Size = UDim2.new(1, 0, 0, HELP_H),
    Position = UDim2.fromOffset(0, LIST_Y + LIST_H + DESC_H),
    BackgroundColor3 = Color3.new(0, 0, 0),
    BackgroundTransparency = 0.05,
    BorderSizePixel = 0,
}, root)

local helpRule = new("Frame", {
    Size = UDim2.new(1, 0, 0, 1),
    BackgroundColor3 = Color3.fromRGB(210, 210, 216),
    BackgroundTransparency = 0.55,
    BorderSizePixel = 0,
}, helpBar)

local helpText = new("TextLabel", {
    Size = UDim2.new(1, -PAD_X * 2, 1, -2),
    Position = UDim2.fromOffset(PAD_X, 2),
    BackgroundTransparency = 1,
    FontFace = F_REG,
    TextSize = 11,
    TextColor3 = Color3.fromRGB(225, 225, 232),
    TextXAlignment = Enum.TextXAlignment.Left,
    TextTruncate = Enum.TextTruncate.AtEnd,
    Text = "Enter Select   Backspace Back   \226\134\145\226\134\147 Move   \226\134\144\226\134\146 Adjust",
}, helpBar)

-- The reference panel ends at its last row. Ours was always 11 rows tall, so a
-- 7 item page left four empty bands hanging under it.
local opening = false

local function panelHeight(n)
    return BANNER_H + SUB_H + ROW_H * n + DESC_H + HELP_H
end

local function relayout(n)
    local h = ROW_H * n
    listArea.Size   = UDim2.new(1, 0, 0, h)
    descBar.Position = UDim2.fromOffset(0, LIST_Y + h)
    helpBar.Position = UDim2.fromOffset(0, LIST_Y + h + DESC_H)
    if not opening then
        root.Size = UDim2.fromOffset(PANEL_W, panelHeight(n))
    end
end

-- one call paints the whole panel in the current skin. Every property it
-- touches is set every time, so switching skins never leaves a stripe of the
-- old one behind.
local function applySkin()
    local sk = skin()
    local slant = sk.slant or 0
    local on = slant > 0.5
    local leftPad = (sk.titleAlign == Enum.TextXAlignment.Left) and PAD_X or 0

    bannerText.Visible = not on
    obliqueHolder.Visible = on

    local titleFace = titleFaceFor(sk)

    bannerText.FontFace = titleFace
    bannerText.TextSize = sk.titleSize
    bannerFit.MaxTextSize = sk.titleSize
    bannerText.TextColor3 = sk.titleColor
    bannerText.TextXAlignment = sk.titleAlign
    bannerText.Size = UDim2.new(1, -leftPad, 1, 0)
    bannerText.Position = UDim2.fromOffset(leftPad, 0)

    local tangent = math.tan(math.rad(slant))
    local pivot = BANNER_H / 2
    for i = 1, BAND_N do
        local lbl = bands[i]
        lbl.FontFace = titleFace
        lbl.TextSize = sk.titleSize
        lbl.TextColor3 = sk.titleColor
        lbl.TextXAlignment = sk.titleAlign
        lbl.Size = UDim2.new(1, -leftPad, 0, BANNER_H)
        local centre = (i - 1) * BAND_H + BAND_H / 2
        local dx = on and math.floor((pivot - centre) * tangent + 0.5) or 0
        lbl.Position = UDim2.fromOffset(leftPad + dx, -(i - 1) * BAND_H)
    end

    subBar.BackgroundColor3 = sk.subBg
    subBar.BackgroundTransparency = sk.subAlpha
    subTitle.TextColor3 = sk.subText
    subCount.TextColor3 = sk.subText

    listArea.BackgroundColor3 = sk.listBg
    listArea.BackgroundTransparency = sk.listAlpha
    highlight.BackgroundColor3 = sk.hlColor
    highlight.BackgroundTransparency = sk.hlAlpha

    upArrow.TextColor3 = sk.rowText
    downArrow.TextColor3 = sk.rowText

    descBar.BackgroundColor3 = sk.bandBg
    descBar.BackgroundTransparency = sk.bandAlpha
    helpBar.BackgroundColor3 = sk.bandBg
    helpBar.BackgroundTransparency = sk.bandAlpha
    descText.TextColor3 = sk.bandText
    helpText.TextColor3 = sk.bandText
    descRule.BackgroundColor3 = sk.bandText
    helpRule.BackgroundColor3 = sk.bandText
end

local function paintTheme()
    applySkin()
    local sk = skin()

    if sk.bannerMode == "solid" then
        local c = sk.bannerA
        bannerGrad.Color = ColorSequence.new(c, c)
    else
        local a, b = themeColors()
        -- the reference ramp holds its dark end to 30% and reaches the bright end at 85%
        bannerGrad.Color = ColorSequence.new({
            ColorSequenceKeypoint.new(0.00, a),
            ColorSequenceKeypoint.new(0.30, a),
            ColorSequenceKeypoint.new(0.85, b),
            ColorSequenceKeypoint.new(1.00, b),
        })
    end
    banner.BackgroundColor3 = Color3.new(1, 1, 1)
end

--------------------------------------------------------------------- item kinds
local function Header(label)          return { kind = "header", label = label } end
local function Info(label, textFn)    return { kind = "info", label = label, textFn = textFn } end
-- danger marks a destructive row: it takes the skin's red instead of its ink,
-- the way the reference paints Close Menu against a list of violet
local function Action(label, fn, desc, danger)
    return { kind = "action", label = label, fn = fn, desc = desc, danger = danger }
end
local function Sub(label, pageFn, desc) return { kind = "sub", label = label, pageFn = pageFn, desc = desc } end

local function Toggle(label, key, desc, onChange)
    return { kind = "toggle", label = label, key = key, desc = desc, onChange = onChange }
end

local function Cycle(label, key, options, desc, onChange)
    return { kind = "cycle", label = label, key = key, options = options, desc = desc, onChange = onChange }
end

local function Slider(label, key, min, max, step, decimals, desc, onChange)
    return { kind = "slider", label = label, key = key, min = min, max = max,
             step = step, decimals = decimals or 0, desc = desc, onChange = onChange }
end

-- a typed number. The slider is faster for a coarse sweep, but a radius you
-- already know the value of is quicker to type than to nudge 1 step at a time.
local function Entry(label, key, min, max, desc, onChange)
    return { kind = "entry", label = label, key = key, min = min, max = max,
             desc = desc, onChange = onChange }
end

-- a long list gets a page of its own, which is what makes 186 weapons workable
local function Picker(label, key, listFn, desc, onChange)
    return { kind = "picker", label = label, key = key, listFn = listFn, desc = desc, onChange = onChange }
end

local function selectable(item)
    return item.kind ~= "header" and item.kind ~= "info"
end

--------------------------------------------------------------------- nav state
local stack = {}

local function currentFrame() return stack[#stack] end
local function currentPage() local f = currentFrame() return f and f.page end

local function firstSelectable(items, from, dir)
    local i = from
    while i >= 1 and i <= #items do
        if selectable(items[i]) then return i end
        i += dir
    end
    return nil
end


local function pushPage(page)
    local idx = firstSelectable(page.items, 1, 1) or 1
    table.insert(stack, { page = page, index = idx, offset = 0 })
    render()
end

local function popPage()
    if #stack > 1 then
        table.remove(stack)
        render()
    end
end

--------------------------------------------------------------------- render
local function valueTextFor(item)
    if item.kind == "sub" or item.kind == "picker" then
        if item.kind == "picker" then return tostring(Config[item.key]) end
        return ""
    elseif item.kind == "cycle" then
        return tostring(Config[item.key])
    elseif item.kind == "slider" then
        return string.format("%." .. item.decimals .. "f", Config[item.key])
    elseif item.kind == "entry" then
        return ""      -- the box carries the value
    end
    return ""
end

function render()
    local f = currentFrame()
    if not f then return end
    local page, items = f.page, f.page.items

    -- keep the selection inside the window
    if f.index < f.offset + 1 then f.offset = f.index - 1 end
    if f.index > f.offset + MAX_ROWS then f.offset = f.index - MAX_ROWS end
    f.offset = math.clamp(f.offset, 0, math.max(0, #items - MAX_ROWS))

    relayout(math.clamp(#items, 1, MAX_ROWS))
    paintTheme()

    local sk = skin()
    local title = sk.titleUpper and string.upper(page.title) or page.title
    bannerText.Text = title
    for i = 1, BAND_N do bands[i].Text = title end
    subTitle.Text   = string.upper(page.subtitle or page.title)

    -- the counter numbers selectable rows only, so headers do not inflate it
    local total, seen = 0, 0
    for i, it in ipairs(items) do
        if selectable(it) then
            total += 1
            if i <= f.index then seen = total end
        end
    end
    subCount.Text = string.format("%d / %d", seen, total)

    upArrow.Visible   = f.offset > 0
    downArrow.Visible = (f.offset + MAX_ROWS) < #items

    local accent = sk.headerFromTheme and select(1, themeColors()) or sk.headerColor

    for r = 1, MAX_ROWS do
        local item = items[f.offset + r]
        local ui = rows[r]

        if not item then
            ui.holder.Visible = false
        else
            ui.holder.Visible = true
            local isSel = (f.offset + r) == f.index
            local onWhite = isSel

            ui.label.Text = item.label
            ui.rule.Visible = (item.kind == "header")
            ui.box.Visible = (item.kind == "toggle")

            if item.kind == "header" then
                ui.label.FontFace = F_COMP or F_REG
                ui.label.TextSize = 14
                ui.label.TextColor3 = accent
                ui.value.Text = ""
            elseif item.kind == "info" then
                ui.label.FontFace = F_REG
                ui.label.TextSize = 13
                ui.label.TextColor3 = sk.rowText:Lerp(sk.listBg, 0.35)
                ui.value.Text = ""
                ui.label.Text = item.textFn and item.textFn() or item.label
            else
                ui.label.FontFace = F_REG
                ui.label.TextSize = sk.rowSize
                local ink = (item.danger and sk.danger) or sk.rowText
                ui.label.TextColor3 = onWhite and sk.rowTextSel or ink

                if item.kind == "sub" then
                    ui.value.Text = sk.arrow
                else
                    ui.value.Text = valueTextFor(item)
                end
                ui.value.TextSize = sk.rowSize
                ui.value.TextColor3 = onWhite and sk.rowTextSel or ink
            end

            ui.item = item

            if item.kind == "entry" then
                local fld = ui.field
                fld.Visible = true
                fld.BackgroundColor3 = sk.listBg
                fld.TextColor3 = onWhite and sk.rowTextSel or sk.rowText
                fld.BackgroundTransparency = onWhite and 0.6 or 0.35
                if not fld:IsFocused() then
                    fld.Text = tostring(Config[item.key])
                end
            else
                ui.field.Visible = false
            end

            if item.kind == "toggle" then
                local on = Config[item.key] == true
                -- on the highlight bar the square has to invert or it vanishes
                ui.boxStroke.Color = onWhite and sk.rowTextSel or sk.rowText
                ui.boxFill.BackgroundColor3 = onWhite and sk.rowTextSel or sk.rowText
                ui.boxFill.Size = UDim2.new(1, -6, 1, -6)
                ui.boxFill.Position = UDim2.fromOffset(3, 3)
                ui.boxFill.Visible = on
                ui.value.Text = ""
            end
        end
    end

    -- highlight slides to the selected row
    local visRow = f.index - f.offset
    if visRow >= 1 and visRow <= MAX_ROWS then
        highlight.Visible = true
        tween(highlight, SLIDE, { Position = UDim2.fromOffset(0, (visRow - 1) * ROW_H) })
    else
        highlight.Visible = false
    end

    local sel = items[f.index]
    descText.Text = (sel and sel.desc) or ""
end

--------------------------------------------------------------------- input acts
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

    if item.kind == "cycle" then
        local list = type(item.options) == "function" and item.options() or item.options
        if #list == 0 then return end
        local idx = table.find(list, Config[item.key]) or 1
        idx += dir
        if idx < 1 then idx = #list elseif idx > #list then idx = 1 end
        Config[item.key] = list[idx]
        if item.onChange then task.spawn(item.onChange, Config[item.key]) end
        render()

    elseif item.kind == "slider" then
        local v = Config[item.key] + item.step * dir
        v = math.clamp(v, item.min, item.max)
        if item.decimals == 0 then v = math.floor(v + 0.5)
        else
            local m = 10 ^ item.decimals
            v = math.floor(v * m + 0.5) / m
        end
        Config[item.key] = v
        if item.onChange then task.spawn(item.onChange, v) end
        render()

    elseif item.kind == "toggle" then
        Config[item.key] = not Config[item.key]
        if item.onChange then task.spawn(item.onChange, Config[item.key]) end
        render()
    end
end

local function buildPickerPage(item)
    local entries = item.listFn()
    local items = {}
    for _, name in ipairs(entries) do
        items[#items + 1] = {
            kind = "action",
            label = name,
            desc = item.desc,
            fn = function()
                Config[item.key] = name
                if item.onChange then task.spawn(item.onChange, name) end
                popPage()
            end,
        }
    end
    return { title = item.label, subtitle = item.label, items = items, picker = true }
end

local function activate()
    local f = currentFrame()
    if not f then return end
    local item = f.page.items[f.index]
    if not item then return end

    if item.kind == "sub" then
        pushPage(item.pageFn())
    elseif item.kind == "picker" then
        local page = buildPickerPage(item)
        pushPage(page)
        -- land on whatever is already selected
        local cur = tostring(Config[item.key])
        for i, it in ipairs(page.items) do
            if it.label == cur then currentFrame().index = i break end
        end
        render()
    elseif item.kind == "toggle" then
        Config[item.key] = not Config[item.key]
        if item.onChange then task.spawn(item.onChange, Config[item.key]) end
        render()
    elseif item.kind == "entry" then
        local visRow = f.index - f.offset
        local ui = rows[visRow]
        if ui then ui.field:CaptureFocus() end
    elseif item.kind == "action" then
        local ok, err = pcall(item.fn)
        if not ok then
            descText.Text = "error: " .. tostring(err):sub(1, 60)
        end
    end
end

-- press a letter to jump, which is how a console menu copes with 186 entries
local function jumpTo(ch)
    local f = currentFrame()
    if not (f and f.page.picker) then return end
    local items = f.page.items
    local start = f.index + 1

    for n = 0, #items - 1 do
        local i = ((start + n - 1) % #items) + 1
        if string.lower(string.sub(items[i].label, 1, 1)) == ch then
            f.index = i
            render()
            return
        end
    end
end

--============================================================================
-- weapon lists
--  Weapons.<gun>.Class, counted live off the folder: Assault Rifle 49, SMG 47,
--  Handgun 35, Carbine 25, Melee 23, Shotgun 21, Sniper Rifle 16, LMG 12,
--  Launcher 9, HMG 8, Marksman Rifle 4, Short 2, plus four Bonus* variants.
--  Melee is not a slot -- it rides on Inventory:GetAttribute("MeleeWeapon").
--============================================================================

local PRIMARY_CLASSES = {
    ["Assault Rifle"] = true, ["Marksman Rifle"] = true, ["Sniper Rifle"] = true,
    Carbine = true, BonusCarbine = true,
    SMG = true, BonusSMG = true,
    Shotgun = true, BonusShotgun = true,
    LMG = true, HMG = true,
}

local SECONDARY_CLASSES = {
    Handgun = true, BonusHandgun = true,
    Short = true,
    Launcher = true,
}

local function classOf(folder)
    local c = folder:FindFirstChild("Class")
    if not c then return nil end
    local ok, v = pcall(function() return tostring(c.Value) end)
    return ok and v or nil
end

local function weaponList(allowed)
    local t = { "None" }
    for _, w in ipairs(Weapons:GetChildren()) do
        local class = classOf(w)
        if class and allowed[class] then table.insert(t, w.Name) end
    end
    table.sort(t)
    return t
end

local function primaryList()   return weaponList(PRIMARY_CLASSES)   end
local function secondaryList() return weaponList(SECONDARY_CLASSES) end

local function camoList()
    local t = { "None" }
    for _, c in ipairs(Camos:GetChildren()) do table.insert(t, c.Name) end
    table.sort(t)
    return t
end

if Config.ForcePrimary ~= "None" and not table.find(primaryList(), Config.ForcePrimary) then
    Config.ForcePrimary = "None"
end
if Config.ForceSecondary ~= "None" and not table.find(secondaryList(), Config.ForceSecondary) then
    Config.ForceSecondary = "None"
end

--============================================================================
-- pages
--============================================================================

local function aimPage()
    local items = {
        Info("idle", function() return statusText end),
        Header("Lock"),
        Toggle("Enabled", "AimEnabled",
            "Master switch for the aim system."),
        Cycle("Method", "Method", { "Silent", "Lock" },
            "Silent parks the muzzle beside the target, the camera never moves. Lock turns the camera.",
            function()
                -- the radius row only exists under Silent, so the page is
                -- rebuilt in place rather than hidden row by row
                local f = currentFrame()
                if f then
                    f.page = aimPage()
                    f.index = math.min(f.index, #f.page.items)
                end
                render()
            end),
    }

    if Config.Method == "Silent" then
        items[#items + 1] = Entry("Silent Radius", "Standoff", 1, 20,
            "Studs the muzzle parks short of the body. Type a number and hit Enter. 1 is on the body, 20 is well off it.")
    end

    local rest = {
        Cycle("Engage", "Mode", { "Always", "Hold", "Toggle" },
            "Always on, held on a key, or toggled by a key."),
        Cycle("Hold Key", "Key", { "MouseButton2", "MouseButton1", "E", "Q", "C", "X", "V", "LeftAlt" },
            "The key used by Hold and Toggle."),
        Cycle("Bone", "Bone", { "Auto", "Head", "UpperTorso", "HumanoidRootPart" },
            "Auto takes the head when it sits closer to your aim than the chest."),
        Header("Limits"),
        Slider("FOV", "FOVDeg", 1, 180, 1, 0,
            "Degrees off your crosshair a target may sit and still be picked."),
        Slider("Range", "Range", 50, 1000, 10, 0,
            "Furthest target, in studs."),
        Slider("Lock Smoothness", "Smoothness", 0.02, 1, 0.02, 2,
            "How hard the camera snaps. Lock only."),
        Toggle("Sticky Target", "StickyTarget",
            "Hold the same target for as long as it stays valid."),
    }
    for _, it in ipairs(rest) do items[#items + 1] = it end

    return { title = "Aimbot", subtitle = "Aimbot", items = items }
end

local function targetPage()
    return { title = "Targets", subtitle = "Targets", items = {
        Header("Who"),
        Toggle("Bots", "TargetBots",
            "Bots are the Players entries that are Folders rather than Player objects."),
        Toggle("Players", "TargetPlayers",
            "Real players only."),
        Cycle("Free For All", "FFA", { "Auto", "On", "Off" },
            "Auto reads the teams and decides for you."),
        Header("Checks"),
        Cycle("Wall Check", "WallCheck", { "Auto", "Strict", "Off" },
            "Auto is strict line of sight, dropped for the 9 Launcher weapons whose splash does not need it."),
        Toggle("Predict", "Predict",
            "Lead the shot. Lock only, since a parked muzzle has no travel time."),
        Slider("Lead Trim", "LeadMul", 0, 2.5, 0.05, 2,
            "Scales the computed lead."),
        Slider("Cone Clamp", "ConeCap", 0, 20, 1, 0,
            "GetHitables only reports targets inside 8 studs of the fire line, so lead is clamped under it."),
    } }
end

local function espPage()
    return { title = "ESP", subtitle = "ESP", items = {
        Toggle("Enabled", "EspEnabled", "Master switch for the overlay."),
        Header("Draw"),
        Toggle("Box", "EspBox", "Bounding box."),
        Toggle("Name", "EspName", "Username above the box."),
        Toggle("Health Bar", "EspHealth", "Bar down the left of the box."),
        Toggle("Distance", "EspDistance", "Distance and health under the box."),
        Toggle("Skeleton", "EspSkeleton", "Bone lines."),
        Toggle("Chams", "EspChams", "Fill the model through walls."),
        Toggle("Tracers", "EspTracer", "Line from the bottom of the screen."),
        Toggle("Rainbow", "EspRainbow", "Cycle the colour."),
        Header("Who"),
        Toggle("Show Bots", "EspBots", "Draw bots."),
        Toggle("Show Players", "EspPlayers", "Draw real players."),
        Header("Limits"),
        Slider("Max Distance", "EspMaxDist", 100, 2000, 50, 0, "Stop drawing past this."),
        Slider("Text Size", "EspTextSize", 8, 20, 1, 0, "Label size."),
    } }
end

local function giveGun(slot, name)
    return function()
        Config[slot] = name
        local ok, err = applyLoadout()
        if not ok then error(tostring(err)) end
    end
end

local function weaponPage()
    return { title = "Weapons", subtitle = "Weapons", items = {
        Header("Loadout"),
        Picker("Primary", "ForcePrimary", primaryList,
            "Rifles, SMGs, shotguns, snipers, LMGs and HMGs."),
        Picker("Secondary", "ForceSecondary", secondaryList,
            "Handguns, sawn-offs and launchers."),
        Picker("Skin", "ForceCamo", camoList,
            "Camo applied to both guns."),
        Toggle("Apply On Respawn", "ApplyOnSpawn",
            "Re-apply the loadout every time you spawn."),
        Action("Apply Now", function()
            local ok, err = applyLoadout()
            if not ok then error(tostring(err)) end
        end, "Rebuilds the inventory, primary first. Respawn for it to take."),
        Header("One Shot"),
        Entry("Damage", "OneShot", 0, 2000,
            "Damage one trigger pull should land. Type a number, hit Enter, then swap weapon once so the engine re-reads the cadence. 0 turns it off.",
            function()
                applyFireRate()
            end),
        Info("plan", oneShotReadout),
        Header("Streak guns"),
        Action("Give Minigun", giveGun("ForcePrimary", "Minigun"),
            "LMG, 500 mag, 2000 rpm, 75 damage. A killstreak gun that needs no streak."),
        Action("Give Laser Minigun", giveGun("ForcePrimary", "Laser Minigun"),
            "LMG, 300 mag, 1500 rpm, 99 damage."),
        Action("Give Akimbo AA12", giveGun("ForcePrimary", "Akimbo AA12"),
            "Shotgun, 32 mag, 500 damage."),
        Action("Give MGL", giveGun("ForceSecondary", "MGL"),
            "Launcher, 6 mag, 500 damage."),
    } }
end

local function ammoLine()
    local name = activeWeaponName()
    local entry = name and InventoryF:FindFirstChild(name)
    local mag, reserve = entry and parseAmmo(entry.Value)
    if not mag then return "no inventory entry" end
    local stock = stockAmmo(name)
    return string.format("%s  mag %d/%d  reserve %d  drift %d",
        name, mag, stock and stock.clip or mag, reserve, ledgerDrift)
end

local function statPage()
    return { title = "Stats", subtitle = "Stats", items = {
        Info("", function() return rateReadout() end),
        Header("Fire rate"),
        Toggle("Fire Rate", "RateEnabled",
            "Cached at equip, so press One or Two after changing it.",
            function() pcall(applyFireRate) end),
        Slider("Multiplier", "RateMul", 1, 4, 0.05, 2,
            "Multiplies the weapon's stock rpm.",
            function() pcall(applyFireRate) end),
        Slider("Ceiling", "RateCap", 400, 2000, 50, 0,
            "Upper bound. Raise it above 2000 before running a Minigun or it cuts it down.",
            function() pcall(applyFireRate) end),
        Header("Ammo"),
        Info("", ammoLine),
        Toggle("Fast Reload", "FastReload",
            "The engine's own Fast Mags perk, 1.2x reload animation. No rounds invented.",
            function() pcall(applyFastReload) end),
        Action("Repair Ammo To Stock", function()
            local fixed = repairStompedAmmo()
            if #fixed == 0 then error("already stock") end
        end, "There is no ammo override: the server counts your rounds, so a raised mag or reserve kills damage until you rejoin."),
    } }
end

local function themePage()
    return { title = "Theme", subtitle = "Theme", items = {
        Cycle("Preset", "Theme", THEME_ORDER,
            "Galaxy is the default. Custom uses the three values below.",
            function() paintTheme() end),
        Header("Custom"),
        Slider("Red", "ThemeR", 0, 255, 5, 0, "Only used when Preset is Custom.",
            function() paintTheme() end),
        Slider("Green", "ThemeG", 0, 255, 5, 0, "Only used when Preset is Custom.",
            function() paintTheme() end),
        Slider("Blue", "ThemeB", 0, 255, 5, 0, "Only used when Preset is Custom.",
            function() paintTheme() end),
    } }
end

local function configPage()
    return { title = "Config", subtitle = "Config", items = {
        Header("Wheel"),
        Toggle("Weapon Wheel", "WheelEnabled",
            "Hold the wheel key for the gta wheel. Mouse picks the class, left and right page through its guns, release equips."),
        Cycle("Wheel Key", "WheelKey", { "B", "V", "X", "C", "G", "T", "LeftAlt", "Tab" },
            "The key the wheel is held on."),
        Header("Look"),
        Cycle("UI", "Skin", SKIN_ORDER,
            "Whole panel look, each one lifted off a real gta 5 mod menu. Aurora is the blue default.",
            function() paintTheme() render() end),
        Header("File"),
        Action("Save Config", function()
            local ok, err = saveConfig()
            if not ok then error(tostring(err)) end
        end, "Writes every setting, theme included, to " .. CONFIG_PATH .. "."),
        Action("Load Config", function()
            loadConfig()
            paintTheme()
            render()
        end, "Re-reads the saved file."),
        Header("Maintenance"),
        Action("Reset Target", function()
            currentTarget, currentPart = nil, nil
        end, "Drop the sticky target."),
        Action("Restore Fire Rates", function()
            restoreRates()
        end, "Put every weapon back to its stock rpm."),
        Action("Unload", function()
            if _G.__AURORA then _G.__AURORA() end
        end, "Remove the menu and every hook.", true),
    } }
end

local function rootPage()
    return { title = "Gunfight Arena", subtitle = "Aurora", items = {
        Sub("Aimbot",  aimPage,    "Silent aim, bone selection, FOV and range."),
        Sub("Targets", targetPage, "Who gets picked, and what has to be true first."),
        Sub("ESP",     espPage,    "Boxes, names, health, skeletons and chams."),
        Sub("Weapons", weaponPage, "Loadout, skins and the killstreak guns."),
        Sub("Stats",   statPage,   "Fire rate, reload speed and the ammo ledger."),
        Sub("Theme",   themePage,  "Accent colour. Saved with your config."),
        Sub("Config",  configPage, "Save, load and unload."),
    } }
end

paintTheme()
pushPage(rootPage())

--============================================================================
-- live repaint  --  info rows only, everything else repaints on input
--============================================================================

local UI_BIND = "aurora_ui_anim"

local function uiStep()
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
end

pcall(function() RunService:UnbindFromRenderStep(UI_BIND) end)
RunService:BindToRenderStep(UI_BIND, Enum.RenderPriority.Last.Value + 1, uiStep)

--============================================================================
-- weapon wheel  (built inside a function of its own: the main chunk is close
-- to Luau's 200 local register limit, and a function body gets a fresh one)
--============================================================================
local function buildWheel()
local WHEEL_D     = 420
local WHEEL_INNER = 0.26      -- matches the generator in aurora_art
local WHEEL_OUTER = 0.49
local ICON_RING   = (WHEEL_INNER + WHEEL_OUTER) / 2

local WHEEL_ART = {
    wedge = loadDiskImage("aurora_art/wedge.png"),
    arc   = loadDiskImage("aurora_art/arc.png"),
}

-- 16 classes, 8 slots: the wheel groups them the way gta does, by what the gun
-- is for rather than by what the engine files it under
local WHEEL_SLOT_DEFS = {
    { name = "Melee",    classes = { ["Melee"] = true, ["Short"] = true } },
    { name = "Handgun",  classes = { ["Handgun"] = true, ["BonusHandgun"] = true } },
    { name = "SMG",      classes = { ["SMG"] = true, ["BonusSMG"] = true } },
    { name = "Shotgun",  classes = { ["Shotgun"] = true, ["BonusShotgun"] = true } },
    { name = "Rifle",    classes = { ["Assault Rifle"] = true, ["Carbine"] = true, ["BonusCarbine"] = true } },
    { name = "Sniper",   classes = { ["Sniper Rifle"] = true, ["Marksman Rifle"] = true } },
    { name = "Heavy",    classes = { ["LMG"] = true, ["HMG"] = true } },
    { name = "Launcher", classes = { ["Launcher"] = true } },
}

local wheelSlots = {}
do
    local classToSlot = {}
    for i, def in ipairs(WHEEL_SLOT_DEFS) do
        wheelSlots[i] = { name = def.name, guns = {}, index = 1, shown = nil }
        for cls in pairs(def.classes) do classToSlot[cls] = i end
    end

    for _, g in ipairs(Weapons:GetChildren()) do
        local c = g:FindFirstChild("Class")
        local slot = c and classToSlot[c.Value]
        if slot then table.insert(wheelSlots[slot].guns, g.Name) end
    end

    for _, slot in ipairs(wheelSlots) do table.sort(slot.guns) end
end

--------------------------------------------------------------------- build
local wheelRoot = new("Frame", {
    Name = "wheel",
    Size = UDim2.fromOffset(WHEEL_D, WHEEL_D),
    AnchorPoint = Vector2.new(0.5, 0.5),
    Position = UDim2.fromScale(0.5, 0.5),
    BackgroundTransparency = 1,
    Visible = false,
    ZIndex = 5,
}, screen)

local wheelUI = {}

for i = 1, 8 do
    local wedge = new("ImageLabel", {
        Size = UDim2.fromScale(1, 1),
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.fromScale(0.5, 0.5),
        BackgroundTransparency = 1,
        Image = WHEEL_ART.wedge or "",
        ImageColor3 = Color3.fromRGB(34, 34, 38),
        ImageTransparency = 0.42,
        Rotation = (i - 1) * 45,
        ZIndex = 5,
    }, wheelRoot)

    local arc = new("ImageLabel", {
        Size = UDim2.fromScale(1, 1),
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.fromScale(0.5, 0.5),
        BackgroundTransparency = 1,
        Image = WHEEL_ART.arc or "",
        ImageColor3 = Color3.fromRGB(60, 140, 240),
        Rotation = (i - 1) * 45,
        Visible = false,
        ZIndex = 6,
    }, wheelRoot)

    local theta = math.rad((i - 1) * 45)
    local r = WHEEL_D * ICON_RING
    local holder = new("Frame", {
        Size = UDim2.fromOffset(96, 76),
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.new(0.5, math.sin(theta) * r, 0.5, -math.cos(theta) * r),
        BackgroundTransparency = 1,
        ZIndex = 7,
    }, wheelRoot)

    local icon = new("ImageLabel", {
        Size = UDim2.fromOffset(86, 42),
        Position = UDim2.fromOffset(5, 0),
        BackgroundTransparency = 1,
        ScaleType = Enum.ScaleType.Fit,
        ImageColor3 = Color3.new(1, 1, 1),
        ZIndex = 7,
    }, holder)

    -- only the four streak guns ship no icon, so the viewport is the fallback
    local viewport = new("ViewportFrame", {
        Size = UDim2.fromOffset(86, 42),
        Position = UDim2.fromOffset(5, 0),
        BackgroundTransparency = 1,
        Visible = false,
        ZIndex = 7,
    }, holder)

    local ammo = new("TextLabel", {
        Size = UDim2.new(1, 0, 0, 15),
        Position = UDim2.fromOffset(0, 43),
        BackgroundTransparency = 1,
        FontFace = F_REG,
        TextSize = 13,
        TextColor3 = Color3.new(1, 1, 1),
        Text = "",
        ZIndex = 7,
    }, holder)

    local gunName = new("TextLabel", {
        Size = UDim2.new(1, 0, 0, 13),
        Position = UDim2.fromOffset(0, 58),
        BackgroundTransparency = 1,
        FontFace = F_REG,
        TextSize = 11,
        TextColor3 = Color3.fromRGB(205, 205, 214),
        TextTruncate = Enum.TextTruncate.AtEnd,
        Text = "",
        ZIndex = 7,
    }, holder)

    wheelUI[i] = { wedge = wedge, arc = arc, icon = icon, viewport = viewport,
                   ammo = ammo, gunName = gunName }
end

--------------------------------------------------------------------- hub
local hubClass = new("TextLabel", {
    Size = UDim2.fromOffset(190, 22),
    AnchorPoint = Vector2.new(0.5, 0.5),
    Position = UDim2.new(0.5, 0, 0.5, -11),
    BackgroundTransparency = 1,
    FontFace = F_COMP or F_REG,
    TextSize = 19,
    TextColor3 = Color3.new(1, 1, 1),
    Text = "",
    ZIndex = 7,
}, wheelRoot)

local hubPager = new("TextLabel", {
    Size = UDim2.fromOffset(190, 18),
    AnchorPoint = Vector2.new(0.5, 0.5),
    Position = UDim2.new(0.5, 0, 0.5, 11),
    BackgroundTransparency = 1,
    FontFace = F_COMP or F_REG,
    TextSize = 16,
    TextColor3 = Color3.fromRGB(225, 225, 232),
    Text = "",
    ZIndex = 7,
}, wheelRoot)

-- where the stick is pointing, so the rake of the wheel is readable while moving
local hubDot = new("Frame", {
    Size = UDim2.fromOffset(8, 8),
    AnchorPoint = Vector2.new(0.5, 0.5),
    Position = UDim2.fromScale(0.5, 0.5),
    BackgroundColor3 = Color3.new(1, 1, 1),
    BorderSizePixel = 0,
    ZIndex = 8,
}, wheelRoot)
new("UICorner", { CornerRadius = UDim.new(1, 0) }, hubDot)

--------------------------------------------------------------------- stats
local STAT_W, STAT_ROW = 210, 22
-- the reference hangs this in the top right of the screen, not off the wheel,
-- so it is parented to the gui rather than to the wheel frame
local statPanel = new("Frame", {
    Size = UDim2.fromOffset(STAT_W, STAT_ROW * 4 + 14),
    AnchorPoint = Vector2.new(1, 0),
    Position = UDim2.new(1, -28, 0, 28),
    BackgroundColor3 = Color3.new(0, 0, 0),
    BackgroundTransparency = 0.35,
    BorderSizePixel = 0,
    Visible = false,
    ZIndex = 6,
}, screen)

-- Accuracy and Range are not fields in this game. Damage and Fire Rate come
-- straight off Variables, Mag is ClipSize, and Hold is MinDamage/MaxDamage --
-- how much of its damage the gun keeps at distance, which is the honest stand
-- in for the reference's Range bar rather than a number invented to fill it.
local STAT_DEFS = {
    { label = "Damage",    max = 200  },
    { label = "Fire Rate", max = 1200 },
    { label = "Mag",       max = 100  },
    { label = "Hold",      max = 1    },
}

local statBars = {}
for i, def in ipairs(STAT_DEFS) do
    local y = 7 + (i - 1) * STAT_ROW

    new("TextLabel", {
        Size = UDim2.fromOffset(74, STAT_ROW - 6),
        Position = UDim2.fromOffset(8, y),
        BackgroundTransparency = 1,
        FontFace = F_REG,
        TextSize = 12,
        TextColor3 = Color3.fromRGB(225, 225, 232),
        TextXAlignment = Enum.TextXAlignment.Left,
        Text = def.label,
        ZIndex = 7,
    }, statPanel)

    local groove = new("Frame", {
        Size = UDim2.fromOffset(112, 8),
        Position = UDim2.fromOffset(88, y + 4),
        BackgroundColor3 = Color3.fromRGB(60, 60, 68),
        BorderSizePixel = 0,
        ZIndex = 7,
    }, statPanel)

    statBars[i] = new("Frame", {
        Size = UDim2.fromScale(0, 1),
        BackgroundColor3 = Color3.new(1, 1, 1),
        BorderSizePixel = 0,
        ZIndex = 8,
    }, groove)
end

--------------------------------------------------------------------- scene
-- gta softens and greens the world behind the wheel. Both are Lighting effects
-- we own: created disabled, tweened on while the wheel is up, off on release.
-- Nothing of the game's own Lighting is touched, so there is nothing to restore
-- beyond destroying ours.
local Lighting = game:GetService("Lighting")

for _, old in ipairs(Lighting:GetChildren()) do
    if old.Name == "aurora_wheel_blur" or old.Name == "aurora_wheel_tint" then old:Destroy() end
end

local wheelBlur = new("BlurEffect", {
    Name = "aurora_wheel_blur",
    Size = 0,
    Enabled = false,
}, Lighting)

local wheelTint = new("ColorCorrectionEffect", {
    Name = "aurora_wheel_tint",
    TintColor = Color3.fromRGB(198, 232, 204),
    Saturation = -0.15,
    Brightness = -0.02,
    Contrast = 0.04,
    Enabled = false,
}, Lighting)

local SCENE_IN  = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local SCENE_OUT = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local function sceneOn()
    wheelBlur.Enabled, wheelTint.Enabled = true, true
    wheelBlur.Size = 0
    wheelTint.TintColor = Color3.new(1, 1, 1)
    tween(wheelBlur, SCENE_IN, { Size = 14 })
    tween(wheelTint, SCENE_IN, { TintColor = Color3.fromRGB(198, 232, 204) })
end

local function sceneOff()
    tween(wheelBlur, SCENE_OUT, { Size = 0 })
    tween(wheelTint, SCENE_OUT, { TintColor = Color3.new(1, 1, 1) })
    task.delay(0.14, function()
        if not wheelBlur.Parent then return end
        wheelBlur.Enabled, wheelTint.Enabled = false, false
    end)
end

--------------------------------------------------------------------- state
local wheelOpen = false
local wheelStick = Vector2.new(0, -1)     -- starts pointing at the top slot
local wheelHover = 1

local function wheelGun(i)
    local slot = wheelSlots[i]
    return slot.guns[slot.index]
end

local function statValue(vars, name)
    local v = vars and vars:FindFirstChild(name)
    return v and v.Value or nil
end

-- built once per gun, and only for the four that ship no icon
local function fillViewport(ui, gunFolder)
    ui.viewport:ClearAllChildren()

    local model = gunFolder:FindFirstChild("Gun")
    if not model then return false end

    local clone = model:Clone()
    for _, d in ipairs(clone:GetDescendants()) do
        if d:IsA("BasePart") then
            d.Anchored = true
            d.CanCollide = false
        end
    end
    clone.Parent = ui.viewport

    local cam = Instance.new("Camera")
    cam.Parent = ui.viewport
    ui.viewport.CurrentCamera = cam

    local centre, extent = Vector3.zero, Vector3.new(4, 1, 1)
    local ok, cf, size = pcall(function() return clone:GetBoundingBox() end)
    if ok and cf then centre, extent = cf.Position, size end

    local dist = math.max(extent.Magnitude, 2) * 1.05
    cam.CFrame = CFrame.lookAt(centre + Vector3.new(dist * 0.55, dist * 0.35, dist * 0.75), centre)
    return true
end

local function paintSlot(i, hovered)
    local ui   = wheelUI[i]
    local slot = wheelSlots[i]
    local name = wheelGun(i)

    ui.wedge.ImageColor3 = hovered and Color3.new(1, 1, 1) or Color3.fromRGB(34, 34, 38)
    ui.wedge.ImageTransparency = hovered and 0.04 or 0.42
    ui.arc.Visible = hovered

    if not name then
        ui.icon.Visible, ui.viewport.Visible = false, false
        ui.ammo.Text, ui.gunName.Text = "", ""
        return
    end

    local folder = Weapons:FindFirstChild(name)
    if not folder then return end

    -- the icon is only rebuilt when the slot's gun actually changes
    if slot.shown ~= name then
        slot.shown = name

        local wpn = folder:FindFirstChild("WPN")
        local id = (wpn and wpn:IsA("ImageLabel") and wpn.Image ~= "") and wpn.Image or nil

        if id then
            ui.icon.Image = id
            ui.icon.Visible = true
            ui.viewport.Visible = false
        else
            ui.icon.Visible = false
            ui.viewport.Visible = fillViewport(ui, folder)
        end

        local vars = folder:FindFirstChild("Variables")
        ui.ammo.Text = string.format("%d / %d",
            statValue(vars, "ClipSize") or 0, statValue(vars, "StoredAmmo") or 0)
        ui.gunName.Text = name
    end

    ui.ammo.TextColor3 = hovered and Color3.fromRGB(20, 20, 26) or Color3.new(1, 1, 1)
    ui.gunName.TextColor3 = hovered and Color3.fromRGB(50, 50, 60) or Color3.fromRGB(205, 205, 214)
    ui.icon.ImageColor3 = hovered and Color3.fromRGB(20, 20, 26) or Color3.new(1, 1, 1)
end

local function paintStats(name)
    local folder = name and Weapons:FindFirstChild(name)
    local vars = folder and folder:FindFirstChild("Variables")

    local maxD = statValue(vars, "MaxDamage") or 0
    local minD = statValue(vars, "MinDamage") or 0
    local vals = {
        maxD,
        statValue(vars, "FireRate") or 0,
        statValue(vars, "ClipSize") or 0,
        (maxD > 0) and (minD / maxD) or 0,
    }

    local accent = select(1, themeColors())
    for i, def in ipairs(STAT_DEFS) do
        statBars[i].Size = UDim2.fromScale(math.clamp(vals[i] / def.max, 0, 1), 1)
        statBars[i].BackgroundColor3 = accent
    end
end

local function paintWheel()
    for i = 1, 8 do paintSlot(i, i == wheelHover) end

    local slot = wheelSlots[wheelHover]
    hubClass.Text = slot.name
    hubPager.Text = (#slot.guns > 0)
        and string.format("\226\128\185 %d / %d \226\128\186", slot.index, #slot.guns)
        or "empty"

    hubDot.Position = UDim2.new(0.5, wheelStick.X * WHEEL_D * 0.17,
                                0.5, wheelStick.Y * WHEEL_D * 0.17)
    paintStats(wheelGun(wheelHover))
end

-- angle off straight up, clockwise, the order the wedges were stamped in
local function hoverFromStick()
    if wheelStick.Magnitude < 0.12 then return wheelHover end
    local deg = math.deg(math.atan2(wheelStick.X, -wheelStick.Y)) % 360
    return (math.floor((deg + 22.5) / 45) % 8) + 1
end

--------------------------------------------------------------------- input
local WHEEL_SINK = "aurora_wheel_sink"
local WHEEL_SINK_KEYS = { Enum.KeyCode.Left, Enum.KeyCode.Right }

local function openWheel()
    if wheelOpen then return end
    wheelOpen = true
    wheelStick = Vector2.new(0, -1)
    wheelHover = 1
    wheelRoot.Visible = true
    statPanel.Visible = true
    sceneOn()
    paintWheel()

    ContextActionService:BindActionAtPriority(WHEEL_SINK, function()
        return Enum.ContextActionResult.Sink
    end, false, Enum.ContextActionPriority.High.Value + 1000, table.unpack(WHEEL_SINK_KEYS))
end

local function closeWheel(equip)
    if not wheelOpen then return end
    wheelOpen = false
    wheelRoot.Visible = false
    statPanel.Visible = false
    sceneOff()
    pcall(function() ContextActionService:UnbindAction(WHEEL_SINK) end)

    if not equip then return end

    local name = wheelGun(wheelHover)
    local folder = name and Weapons:FindFirstChild(name)
    if not folder then return end

    -- the engine already marks which slot a gun belongs in
    if folder:GetAttribute("Secondary") == true then
        Config.ForceSecondary = name
    else
        Config.ForcePrimary = name
    end
    pcall(applyLoadout)
end

local function wheelPage(dir)
    local slot = wheelSlots[wheelHover]
    if #slot.guns == 0 then return end
    slot.index = ((slot.index - 1 + dir) % #slot.guns) + 1
    paintWheel()
end

local function wheelKeyEnum()
    local ok, e = pcall(function() return Enum.KeyCode[Config.WheelKey] end)
    return (ok and e) or Enum.KeyCode.B
end

track(UserInputService.InputBegan:Connect(function(input, processed)
    if not Config.WheelEnabled then return end
    if UserInputService:GetFocusedTextBox() then return end

    if wheelOpen then
        if input.KeyCode == Enum.KeyCode.Right then wheelPage(1) return end
        if input.KeyCode == Enum.KeyCode.Left  then wheelPage(-1) return end
    end

    if processed then return end
    if input.KeyCode == wheelKeyEnum() then openWheel() end
end))

track(UserInputService.InputEnded:Connect(function(input)
    if wheelOpen and input.KeyCode == wheelKeyEnum() then closeWheel(true) end
end))

-- handles for the console and for testing without touching the keyboard
_G.AuroraWheel = {
    Open  = openWheel,
    Close = closeWheel,
    Page  = wheelPage,
    Hover = function(i)
        wheelHover = math.clamp(i, 1, 8)
        wheelStick = Vector2.new(math.sin(math.rad((wheelHover - 1) * 45)),
                                -math.cos(math.rad((wheelHover - 1) * 45)))
        paintWheel()
    end,
    State = function()
        local slot = wheelSlots[wheelHover]
        return wheelOpen, slot.name, slot.index, #slot.guns, wheelGun(wheelHover)
    end,
    Slots = wheelSlots,
}

-- the mouse is locked to the centre, so only the delta carries anything
track(UserInputService.InputChanged:Connect(function(input)
    if not wheelOpen then return end

    if input.UserInputType == Enum.UserInputType.MouseMovement then
        wheelStick += Vector2.new(input.Delta.X, input.Delta.Y) * 0.045
        if wheelStick.Magnitude > 1.4 then wheelStick = wheelStick.Unit * 1.4 end
        wheelHover = hoverFromStick()
        paintWheel()

    elseif input.UserInputType == Enum.UserInputType.MouseWheel then
        wheelPage(input.Position.Z > 0 and 1 or -1)
    end
end))

end

buildWheel()

--============================================================================
-- input
--============================================================================

-- The arrow keys drive the character through the engine's own CAS binding.
-- UserInputService cannot stop that -- it only listens. So while the panel is
-- up we take the four keys at a higher CAS priority and sink them; the menu
-- still reads them through InputBegan, the character never sees them. Unbound
-- on close, so movement comes straight back.
local NAV_SINK = "aurora_nav_sink"
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

local function openMenu()
    opening = true
    bindNavSink()
    root.Visible = true
    root.Size = UDim2.fromOffset(PANEL_W, 0)
    render()

    local f = currentFrame()
    local n = f and math.clamp(#f.page.items, 1, MAX_ROWS) or MAX_ROWS
    tween(root, TweenInfo.new(0.16, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
        { Size = UDim2.fromOffset(PANEL_W, panelHeight(n)) })
    task.delay(0.18, function() opening = false end)
end

local function closeMenu()
    opening = true
    unbindNavSink()
    tween(root, FAST, { Size = UDim2.fromOffset(PANEL_W, 0) })
    task.delay(0.12, function() root.Visible = false opening = false end)
end

local NAV = {
    [Enum.KeyCode.Up]          = function() move(-1) end,
    [Enum.KeyCode.Down]        = function() move(1) end,
    [Enum.KeyCode.Left]        = function() adjust(-1) end,
    [Enum.KeyCode.Right]       = function() adjust(1) end,
    [Enum.KeyCode.Return]      = function() activate() end,
    [Enum.KeyCode.KeypadEnter] = function() activate() end,
    [Enum.KeyCode.Backspace]   = function() popPage() end,
    [Enum.KeyCode.KeypadEight] = function() move(-1) end,
    [Enum.KeyCode.KeypadTwo]   = function() move(1) end,
    [Enum.KeyCode.KeypadFour]  = function() adjust(-1) end,
    [Enum.KeyCode.KeypadSix]   = function() adjust(1) end,
    [Enum.KeyCode.KeypadFive]  = function() activate() end,
    [Enum.KeyCode.KeypadZero]  = function() popPage() end,
}

track(UserInputService.InputBegan:Connect(function(input, processed)
    -- a focused box owns the keyboard: no nav, no jump-to-letter, no Delete
    if UserInputService:GetFocusedTextBox() then return end

    if input.KeyCode == Enum.KeyCode.Delete then
        if root.Visible then closeMenu() else openMenu() end
        return
    end

    if root.Visible then
        local fn = NAV[input.KeyCode]
        if fn then fn() return end

        local name = input.KeyCode.Name
        if #name == 1 then jumpTo(string.lower(name)) return end
    end

    if processed then return end

    if Config.Mode == "Toggle" then
        local e, isMouse = keyEnum()
        if (isMouse and input.UserInputType == e) or (not isMouse and input.KeyCode == e) then
            toggleState = not toggleState
        end
    end
end))


_G.Aurora = {
    Config = Config,
    Status = function() return statusText end,
    Target = function() return currentTarget, currentPart end,
    Speed  = projectileSpeed,
    Apply  = applyLoadout,
    Rate   = applyFireRate,
    Reload = applyFastReload,
    Repair = repairStompedAmmo,
    RPM    = function() return measuredRPM, rateReadout() end,
    Ledger = function() return shotsFired, roundsSpent, ledgerDrift, ledgerTripped end,
    Menu   = {
        Open = openMenu, Close = closeMenu,
        Move = move, Adjust = adjust, Select = activate, Back = popPage,
        Draw = render,
        Page = function()
            local f = currentFrame()
            return f and f.page.title, f and f.index, f and f.offset
        end,
    },
}

_G.__AURORA = function()
    pcall(function() RunService:UnbindFromRenderStep(AIM_RENDER) end)
    pcall(function() RunService:UnbindFromRenderStep(ESP_BIND) end)
    pcall(function() RunService:UnbindFromRenderStep(UI_BIND) end)
    for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
    pcall(restoreRates)
    pcall(repairStompedAmmo)
    pcall(function() LocalPlayer:SetAttribute("FasterReloads", 0) end)
    pcall(unbindNavSink)
    pcall(function() ContextActionService:UnbindAction("aurora_wheel_sink") end)
    pcall(function()
        for _, fx in ipairs(game:GetService("Lighting"):GetChildren()) do
            if fx.Name == "aurora_wheel_blur" or fx.Name == "aurora_wheel_tint" then fx:Destroy() end
        end
    end)
    pcall(function() espGui:Destroy() end)
    pcall(function() screen:Destroy() end)
    _G.Aurora = nil
    _G.__AURORA = nil
end

if #stompRepaired > 0 then
    print("[aurora] restored stock ClipSize on " .. #stompRepaired .. " weapon(s): "
          .. table.concat(stompRepaired, ", ", 1, math.min(#stompRepaired, 6)))
end
print("[aurora] loaded -- DELETE for menu")
print("[aurora] " .. assetReport)

]=]

local function runGunfight()
    local fn, err = loadstring(RUNGUNFIGHT_SRC, "Gunfight Arena")
    if not fn then error(err, 0) end
    return fn()
end

--============================================================================
-- module: Hypershot
--============================================================================
local RUNHYPERSHOT_SRC = [=[
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

local function configPage()
    return { title = "Config", subtitle = "Config", items = {
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

]=]

local function runHypershot()
    local fn, err = loadstring(RUNHYPERSHOT_SRC, "Hypershot")
    if not fn then error(err, 0) end
    return fn()
end


--============================================================================
-- supported games
--============================================================================

local GAMES = {
    { name = "Gunfight Arena", run = runGunfight, gameIds = { 5012222382 }, placeIds = { 14518422161, 15514727567 } },
    { name = "Hypershot", run = runHypershot, gameIds = { 5995470825 }, placeIds = {  } },
}

local function moduleForHere()
    for _, g in ipairs(GAMES) do
        for _, id in ipairs(g.gameIds) do
            if id == game.GameId then return g end
        end
        for _, id in ipairs(g.placeIds) do
            if id == game.PlaceId then return g end
        end
    end
    return nil
end

--============================================================================
-- intro
--============================================================================

for _, old in ipairs(GUI_HOST:GetChildren()) do
    if old.Name == "aurora_full" then old:Destroy() end
end
for _, old in ipairs(Lighting:GetChildren()) do
    if old.Name == "aurora_full_blur" then old:Destroy() end
end

local screen = new("ScreenGui", {
    Name = "aurora_full",
    IgnoreGuiInset = true,
    ResetOnSpawn = false,
    DisplayOrder = 500,
}, GUI_HOST)

local blur = new("BlurEffect", { Name = "aurora_full_blur", Size = 0, Enabled = true }, Lighting)

local THEME = Color3.fromRGB(46, 114, 212)

local F_TITLE = diskFace("Pricedown.otf", "Pricedown",
    Font.new("rbxasset://fonts/families/Oswald.json"))
local F_BODY  = diskFace("ChaletLondon.ttf", "ChaletLondon",
    Font.new("rbxasset://fonts/families/Arimo.json"))
local F_HEAD  = diskFace("ChaletComprime.ttf", "ChaletComprime", F_BODY)

local INTRO_SECONDS = 5

local veil = new("Frame", {
    Size = UDim2.fromScale(1, 1),
    BackgroundColor3 = Color3.new(0, 0, 0),
    BackgroundTransparency = 1,
    BorderSizePixel = 0,
}, screen)

local title = new("TextLabel", {
    Size = UDim2.fromOffset(640, 120),
    AnchorPoint = Vector2.new(0.5, 0.5),
    Position = UDim2.fromScale(0.5, 0.46),
    BackgroundTransparency = 1,
    FontFace = F_TITLE,
    TextSize = 86,
    TextColor3 = Color3.new(1, 1, 1),
    TextTransparency = 1,
    Text = "AURORA",
    ZIndex = 3,
}, screen)
local titleScale = new("UIScale", { Scale = 0.88 }, title)

local sub = new("TextLabel", {
    Size = UDim2.fromOffset(640, 22),
    AnchorPoint = Vector2.new(0.5, 0.5),
    Position = UDim2.fromScale(0.5, 0.552),
    BackgroundTransparency = 1,
    FontFace = F_HEAD,
    TextSize = 16,
    TextColor3 = Color3.fromRGB(186, 196, 216),
    TextTransparency = 1,
    Text = "LOADER",
    ZIndex = 3,
}, screen)

local barBack = new("Frame", {
    Size = UDim2.fromOffset(320, 3),
    AnchorPoint = Vector2.new(0.5, 0.5),
    Position = UDim2.fromScale(0.5, 0.615),
    BackgroundColor3 = Color3.fromRGB(44, 44, 54),
    BackgroundTransparency = 1,
    BorderSizePixel = 0,
    ZIndex = 3,
}, screen)

local bar = new("Frame", {
    Size = UDim2.fromScale(0, 1),
    BackgroundColor3 = THEME,
    BackgroundTransparency = 1,
    BorderSizePixel = 0,
    ZIndex = 4,
}, barBack)

local status = new("TextLabel", {
    Size = UDim2.fromOffset(520, 18),
    AnchorPoint = Vector2.new(0.5, 0.5),
    Position = UDim2.fromScale(0.5, 0.658),
    BackgroundTransparency = 1,
    FontFace = F_BODY,
    TextSize = 13,
    TextColor3 = Color3.fromRGB(144, 152, 172),
    TextTransparency = 1,
    Text = "",
    ZIndex = 3,
}, screen)

local function fadeOut()
    tween(title, 0.35, { TextTransparency = 1 })
    tween(sub, 0.35, { TextTransparency = 1 })
    tween(barBack, 0.35, { BackgroundTransparency = 1 })
    tween(bar, 0.35, { BackgroundTransparency = 1 })
    tween(status, 0.35, { TextTransparency = 1 })
    tween(veil, 0.45, { BackgroundTransparency = 1 })
    tween(blur, 0.45, { Size = 0 })
    task.delay(0.55, function()
        pcall(function() screen:Destroy() end)
        pcall(function() blur:Destroy() end)
    end)
end

-- the unsupported card: one line, one button, gone when he clicks it
local function unsupported()
    tween(title, 0.25, { TextTransparency = 1 })
    tween(sub, 0.25, { TextTransparency = 1 })
    tween(barBack, 0.25, { BackgroundTransparency = 1 })
    tween(bar, 0.25, { BackgroundTransparency = 1 })
    tween(status, 0.25, { TextTransparency = 1 })

    local card = new("Frame", {
        Size = UDim2.fromOffset(420, 170),
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.fromScale(0.5, 0.5),
        BackgroundColor3 = Color3.fromRGB(16, 16, 20),
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        ZIndex = 6,
    }, screen)
    new("UICorner", { CornerRadius = UDim.new(0, 8) }, card)
    local stroke = new("UIStroke", { Color = Color3.fromRGB(70, 70, 84), Thickness = 1, Transparency = 1 }, card)

    local text = new("TextLabel", {
        Size = UDim2.new(1, -40, 0, 60),
        Position = UDim2.fromOffset(20, 34),
        BackgroundTransparency = 1,
        FontFace = F_BODY,
        TextSize = 17,
        TextColor3 = Color3.new(1, 1, 1),
        TextTransparency = 1,
        TextWrapped = true,
        Text = "You've joined an unsupported game! :(",
        ZIndex = 7,
    }, card)

    local button = new("TextButton", {
        Size = UDim2.fromOffset(150, 34),
        AnchorPoint = Vector2.new(0.5, 0),
        Position = UDim2.new(0.5, 0, 1, -50),
        BackgroundColor3 = Color3.fromRGB(58, 176, 94),
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        AutoButtonColor = false,
        FontFace = F_HEAD,
        TextSize = 16,
        TextColor3 = Color3.new(1, 1, 1),
        TextTransparency = 1,
        Text = "OK",
        ZIndex = 7,
    }, card)
    new("UICorner", { CornerRadius = UDim.new(0, 5) }, button)

    tween(card, 0.3, { BackgroundTransparency = 0.05 })
    tween(stroke, 0.3, { Transparency = 0 })
    tween(text, 0.35, { TextTransparency = 0 })
    tween(button, 0.35, { BackgroundTransparency = 0, TextTransparency = 0 })

    button.MouseEnter:Connect(function()
        tween(button, 0.12, { BackgroundColor3 = Color3.fromRGB(74, 198, 112) })
    end)
    button.MouseLeave:Connect(function()
        tween(button, 0.12, { BackgroundColor3 = Color3.fromRGB(58, 176, 94) })
    end)
    button.MouseButton1Click:Connect(function()
        tween(card, 0.2, { BackgroundTransparency = 1 })
        tween(stroke, 0.2, { Transparency = 1 })
        tween(text, 0.2, { TextTransparency = 1 })
        tween(button, 0.2, { BackgroundTransparency = 1, TextTransparency = 1 })
        fadeOut()
    end)
end

tween(veil, 0.4, { BackgroundTransparency = 0.35 })
tween(blur, 0.5, { Size = 12 })
tween(title, 0.55, { TextTransparency = 0 })
tween(titleScale, 0.65, { Scale = 1 })
tween(sub, 0.65, { TextTransparency = 0 })
tween(barBack, 0.45, { BackgroundTransparency = 0.25 })
tween(bar, 0.45, { BackgroundTransparency = 0 })
tween(status, 0.55, { TextTransparency = 0 })

task.spawn(function()
    local entry = moduleForHere()
    local assetsDone, moduleDone = false, false
    local moduleOk, moduleErr

    ensureAssets(function()
        assetsDone = true
        if not entry then moduleDone = true return end

        -- the module runs while the bar is still filling, so the five seconds
        -- are spent on the work rather than waiting it out
        task.spawn(function()
            assetState = "loading " .. entry.name
            moduleOk, moduleErr = pcall(entry.run)
            moduleDone = true
        end)
    end)

    local t0 = os.clock()
    while true do
        local elapsed = os.clock() - t0
        local p = math.clamp(elapsed / INTRO_SECONDS, 0, 1)
        -- the bar holds short of full until the work is actually done
        if not (assetsDone and moduleDone) then p = math.min(p, 0.94) end
        bar.Size = UDim2.fromScale(p, 1)
        status.Text = string.upper(assetState)
        if p >= 1 or elapsed > INTRO_SECONDS + 10 then break end
        task.wait(0.03)
    end

    bar.Size = UDim2.fromScale(1, 1)

    if not entry then
        task.wait(0.2)
        unsupported()
    elseif moduleOk then
        status.Text = string.upper(entry.name) .. " LOADED"
        task.wait(0.45)
        fadeOut()
    else
        status.Text = "FAILED: " .. string.upper(tostring(moduleErr):sub(1, 60))
        task.wait(2)
        fadeOut()
    end
end)

_G.__AURORA_FULL = function()
    pcall(function() screen:Destroy() end)
    pcall(function() blur:Destroy() end)
    if _G.__AURORA then pcall(_G.__AURORA) end
    if _G.__HYPERSHOT then pcall(_G.__HYPERSHOT) end
    _G.__AURORA_FULL = nil
end
