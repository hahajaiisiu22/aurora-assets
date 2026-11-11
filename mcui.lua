--============================================================================
-- Aurora :: Minecraft inventory skin
--
--  The GTA menu draws a list. This one draws the survival inventory: bevelled
--  grey panel, 27 main slots, 9 hotbar slots, 4 armour slots, the offhand, the
--  2x2 crafting grid, and the player preview whose head follows the cursor.
--
--  What the slots hold:
--    main grid   every feature on the current tab, one per slot. A toggle that
--                is on gets the enchant glint; a slider shows its value as the
--                stack count.
--    hotbar      the nine you drag down there. Number keys 1-9 fire them even
--                when the inventory is shut.
--    armour      the four always-on passives for the game.
--    offhand     unload.
--    crafting    four config presets; the result slot applies the one you put
--                in, so "crafting" a preset is how you load it.
--    tabs        one per page of the module, like creative mode.
--
--  Nothing here needs a texture pack. Icons are 16x16 pixel art written into
--  an EditableImage at runtime -- confirmed present in this client alongside
--  DrawRectangle and Content.fromObject -- so the whole skin is one file.
--  Minecraft's own font is loaded off disk if it is there (same trick as the
--  GTA faces), and PressStart2P stands in when it is not.
--============================================================================

local Players          = game:GetService("Players")
local RunService       = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TweenService     = game:GetService("TweenService")
local ContextActionService = game:GetService("ContextActionService")
local Lighting         = game:GetService("Lighting")
local AssetService     = game:GetService("AssetService")
local HttpService      = game:GetService("HttpService")

local LocalPlayer = Players.LocalPlayer
local Camera      = workspace.CurrentCamera

local MC = {}

--============================================================================
-- settings
--============================================================================

local Settings = {
    OpenKey   = Enum.KeyCode.E,
    Scale     = 0,          -- 0 = pick from the screen height
    Sounds    = true,
    Blur      = true,
    HeadTrack = true,
}

local FONT_DIR = "aurora_fonts/"

--============================================================================
-- font
--  Minecraft.ttf off disk when he drops it next to the GTA faces; the engine's
--  own PressStart2P otherwise, which is the only built in family that is
--  actually pixel art.
--============================================================================

local function loadDiskFace(fileName, familyName)
    if type(getcustomasset) ~= "function" or type(writefile) ~= "function" then return nil end
    if type(isfile) ~= "function" or not isfile(FONT_DIR .. fileName) then return nil end
    local ok, f = pcall(function()
        local asset   = getcustomasset(FONT_DIR .. fileName)
        local famPath = FONT_DIR .. familyName .. ".json"
        writefile(famPath, HttpService:JSONEncode({
            name  = familyName,
            faces = { { name = "Regular", weight = 400, style = "normal", assetId = asset } },
        }))
        return Font.new(getcustomasset(famPath), Enum.FontWeight.Regular, Enum.FontStyle.Normal)
    end)
    return ok and f or nil
end

local F_PIXEL = loadDiskFace("Minecraft.ttf", "Minecraft")
    or Font.new("rbxasset://fonts/families/PressStart2P.json",
                Enum.FontWeight.Regular, Enum.FontStyle.Normal)

--============================================================================
-- palette, straight off the vanilla widget sheet
--============================================================================

local C = {
    panel    = Color3.fromRGB(198, 198, 198),
    light    = Color3.fromRGB(255, 255, 255),
    shade    = Color3.fromRGB(85,  85,  85),
    edge     = Color3.fromRGB(0,   0,   0),
    slot     = Color3.fromRGB(139, 139, 139),
    slotDark = Color3.fromRGB(55,  55,  55),
    text     = Color3.fromRGB(63,  63,  63),
    white    = Color3.fromRGB(255, 255, 255),
    grey     = Color3.fromRGB(170, 170, 170),
    tipBg    = Color3.fromRGB(16,  0,   16),
    tipEdge  = Color3.fromRGB(80,  0,   255),
    glint    = Color3.fromRGB(190, 110, 255),
    lore     = Color3.fromRGB(170, 170, 170),
    aqua     = Color3.fromRGB(85,  255, 255),
}

--============================================================================
-- pixel canvas -> EditableImage
--  Every icon is a 16x16 grid filled by a draw function, then flushed once
--  into an EditableImage that every slot showing that item can share.
--============================================================================

local SIZE = 16

local Canvas = {}
Canvas.__index = Canvas

local function canvas()
    return setmetatable({ px = {} }, Canvas)
end

function Canvas:set(x, y, col)
    if x < 0 or y < 0 or x >= SIZE or y >= SIZE then return end
    self.px[y * SIZE + x] = col
end

function Canvas:rect(x, y, w, h, col)
    for iy = y, y + h - 1 do
        for ix = x, x + w - 1 do self:set(ix, iy, col) end
    end
end

-- "3,4 5,6" -> pixels. Short, and it reads like the sprite it is.
function Canvas:plot(list, col)
    for pair in string.gmatch(list, "[^%s]+") do
        local x, y = string.match(pair, "(%-?%d+),(%-?%d+)")
        if x then self:set(tonumber(x), tonumber(y), col) end
    end
end

function Canvas:diag(x, y, n, col, dx, dy)
    for i = 0, n - 1 do self:set(x + i * (dx or 1), y + i * (dy or -1), col) end
end

local imageSupport = nil
local function canEdit()
    if imageSupport ~= nil then return imageSupport end
    imageSupport = pcall(function()
        local img = AssetService:CreateEditableImage({ Size = Vector2.new(SIZE, SIZE) })
        img:DrawRectangle(Vector2.zero, Vector2.one, Color3.new(1, 1, 1), 0,
            Enum.ImageCombineType.Overwrite)
        local _ = Content.fromObject(img)
        img:Destroy()
    end)
    return imageSupport
end

function Canvas:flush()
    local img = AssetService:CreateEditableImage({ Size = Vector2.new(SIZE, SIZE) })
    img:DrawRectangle(Vector2.zero, Vector2.new(SIZE, SIZE), C.edge, 1,
        Enum.ImageCombineType.Overwrite)
    for key, col in pairs(self.px) do
        local y = math.floor(key / SIZE)
        img:DrawRectangle(Vector2.new(key - y * SIZE, y), Vector2.one, col, 0,
            Enum.ImageCombineType.Overwrite)
    end
    return img
end

--============================================================================
-- the icon set
--  Twelve items, each a function on a fresh canvas. Colours are the vanilla
--  ones where vanilla has an equivalent.
--============================================================================

local P = {
    iron     = Color3.fromRGB(220, 220, 220),
    ironD    = Color3.fromRGB(140, 140, 140),
    wood     = Color3.fromRGB(104, 78,  42),
    woodD    = Color3.fromRGB(70,  52,  28),
    strand   = Color3.fromRGB(230, 230, 230),
    eyeOut   = Color3.fromRGB(105, 137, 67),
    eyeMid   = Color3.fromRGB(44,  117, 112),
    eyeIn    = Color3.fromRGB(190, 240, 235),
    feather  = Color3.fromRGB(245, 245, 245),
    featherD = Color3.fromRGB(190, 190, 195),
    quill    = Color3.fromRGB(120, 120, 125),
    leather  = Color3.fromRGB(122, 74,  43),
    leatherD = Color3.fromRGB(86,  50,  28),
    glass    = Color3.fromRGB(205, 225, 240),
    brew     = Color3.fromRGB(220, 50,  160),
    tnt      = Color3.fromRGB(190, 48,  40),
    tntD     = Color3.fromRGB(130, 32,  28),
    band     = Color3.fromRGB(240, 240, 240),
    paper    = Color3.fromRGB(240, 235, 215),
    cover    = Color3.fromRGB(135, 48,  46),
    apple    = Color3.fromRGB(240, 190, 60),
    appleD   = Color3.fromRGB(190, 140, 35),
    leaf     = Color3.fromRGB(90,  150, 60),
    diamond  = Color3.fromRGB(95,  225, 215),
    diamondD = Color3.fromRGB(55,  165, 165),
    needle   = Color3.fromRGB(210, 60,  50),
    gold     = Color3.fromRGB(245, 205, 80),
}

local ICONS = {}

ICONS.sword = function(c)
    c:diag(4, 11, 9, P.iron)                 -- blade
    c:diag(5, 12, 8, P.ironD)                -- its shaded side
    c:plot("12,2 13,2 13,3", P.iron)         -- tip
    c:plot("2,10 3,11 4,12 5,13", P.ironD)   -- guard, across the base
    c:plot("1,14 2,13 1,13 2,14", P.wood)    -- grip
end

ICONS.bow = function(c)
    c:plot("9,1 10,2 11,3 12,4 12,5 12,6 12,9 12,10 12,11 11,12 10,13 9,14", P.wood)
    c:plot("8,1 9,2 10,3 11,4 11,11 10,12 9,13 8,14", P.woodD)
    c:plot("9,2 9,3 9,4 9,5 9,6 9,7 9,8 9,9 9,10 9,11 9,12 9,13", P.strand)
    c:diag(3, 11, 7, P.woodD)                -- the nocked arrow
    c:plot("2,13 2,12 3,13", P.feather)
end

ICONS.eye = function(c)
    c:rect(4, 3, 8, 10, P.eyeOut)
    c:rect(3, 4, 10, 8, P.eyeOut)
    c:rect(5, 5, 6, 6, P.eyeMid)
    c:rect(6, 6, 4, 4, P.eyeIn)
    c:rect(7, 7, 2, 2, P.eyeMid)
end

ICONS.feather = function(c)
    c:diag(4, 12, 9, P.quill)
    for i = 0, 6 do
        c:set(5 + i, 10 - i, P.feather)
        c:set(6 + i, 10 - i, P.feather)
        c:set(7 + i, 10 - i, P.featherD)
    end
    c:plot("11,2 12,2 12,3", P.feather)
end

ICONS.boots = function(c)
    c:rect(4, 4, 5, 6, P.leather)
    c:rect(4, 10, 9, 3, P.leather)
    c:rect(4, 13, 10, 1, P.leatherD)
    c:rect(5, 5, 3, 4, P.leatherD)
    c:plot("12,10 13,11 13,12", P.leather)
end

ICONS.potion = function(c)
    c:rect(6, 2, 4, 2, P.glass)
    c:rect(5, 4, 6, 2, P.glass)
    c:rect(4, 6, 8, 7, P.glass)
    c:rect(5, 8, 6, 4, P.brew)
    c:rect(6, 7, 4, 1, P.brew)
    c:rect(5, 12, 6, 1, P.glass)
end

ICONS.tnt = function(c)
    c:rect(2, 4, 12, 10, P.tnt)
    c:rect(2, 7, 12, 3, P.band)
    c:rect(2, 13, 12, 1, P.tntD)
    c:plot("5,8 6,8 7,8 9,8 10,8 11,8", P.tntD)
    c:plot("7,2 8,1 9,2 8,3", P.quill)
    c:rect(7, 3, 2, 1, P.quill)
end

ICONS.compass = function(c)
    c:rect(3, 4, 10, 8, P.ironD)
    c:rect(4, 3, 8, 10, P.ironD)
    c:rect(5, 5, 6, 6, P.iron)
    c:plot("8,5 8,6 7,7 8,7", P.needle)
    c:plot("7,8 7,9 8,9", P.white)
end

ICONS.book = function(c)
    c:rect(3, 2, 10, 12, P.cover)
    c:rect(4, 3, 8, 10, P.paper)
    c:rect(7, 2, 2, 12, P.cover)
    c:plot("5,5 6,5 9,5 10,5 5,8 6,8 9,8 10,8", P.ironD)
    c:rect(3, 2, 1, 12, P.quill)
end

ICONS.apple = function(c)
    c:rect(4, 4, 8, 9, P.apple)
    c:rect(3, 6, 10, 5, P.apple)
    c:rect(5, 5, 2, 3, P.gold)
    c:rect(4, 12, 8, 1, P.appleD)
    c:plot("8,2 8,3 9,2 10,1 10,2", P.leaf)
end

ICONS.diamond = function(c)
    for i = 0, 3 do c:rect(5 - i, 7 - i, 6 + i * 2, 1, P.diamond) end
    for i = 0, 3 do c:rect(5 - i, 8 + i, 6 + i * 2, 1, P.diamondD) end
    c:rect(6, 5, 2, 2, P.white)
end

ICONS.shield = function(c)
    c:rect(3, 2, 10, 8, P.ironD)
    c:rect(4, 10, 8, 2, P.ironD)
    c:rect(6, 12, 4, 1, P.ironD)
    c:rect(4, 3, 8, 6, P.wood)
    c:rect(4, 9, 8, 2, P.wood)
    c:rect(7, 3, 2, 9, P.ironD)
    c:rect(4, 6, 8, 1, P.ironD)
end

ICONS.clock = function(c)
    c:rect(3, 4, 10, 8, P.gold)
    c:rect(4, 3, 8, 10, P.gold)
    c:rect(5, 5, 6, 6, P.white)
    c:rect(5, 8, 6, 3, P.ironD)
    c:plot("8,6 8,7", P.edge)
end

local iconCache = {}
local function iconContent(name)
    if not name or not ICONS[name] then return nil end
    if iconCache[name] ~= nil then return iconCache[name] end
    if not canEdit() then iconCache[name] = false return false end
    local ok, content = pcall(function()
        local c = canvas()
        ICONS[name](c)
        return Content.fromObject(c:flush())
    end)
    iconCache[name] = ok and content or false
    return iconCache[name]
end

-- when the client will not give us an EditableImage, a slot still has to read
-- as something: a flat chip in the icon's dominant colour
local FLAT = {
    sword = P.iron, bow = P.wood, eye = P.eyeMid, feather = P.feather,
    boots = P.leather, potion = P.brew, tnt = P.tnt, compass = P.ironD,
    book = P.cover, apple = P.apple, diamond = P.diamond, shield = P.wood,
    clock = P.gold,
}

--============================================================================
-- geometry
--  Vanilla coordinates on the 176x166 inventory sheet, so everything lands
--  where the eye expects it. One scale factor turns them into pixels.
--============================================================================

local W, H = 176, 166
local S = 3

local function pickScale()
    if Settings.Scale > 0 then return Settings.Scale end
    local vp = (Camera and Camera.ViewportSize) or Vector2.new(1920, 1080)
    return math.clamp(math.floor(vp.Y / 300), 2, 5)
end

local function off(x, y) return UDim2.fromOffset(x * S, y * S) end
local function dim(w, h) return UDim2.fromOffset(w * S, h * S) end

local function new(class, props, parent)
    local i = Instance.new(class)
    for k, v in pairs(props or {}) do i[k] = v end
    if parent then i.Parent = parent end
    return i
end

local function solid(parent, x, y, w, h, col, z)
    return new("Frame", {
        Position = off(x, y), Size = dim(w, h),
        BackgroundColor3 = col, BorderSizePixel = 0, ZIndex = z or 1,
    }, parent)
end

-- the raised panel bevel: white top and left, grey bottom and right
local function bevel(parent, x, y, w, h, z)
    z = z or 1
    solid(parent, x, y, w, h, C.panel, z)
    solid(parent, x, y, w, 1, C.light, z + 1)
    solid(parent, x, y, 1, h, C.light, z + 1)
    solid(parent, x, y + h - 1, w, 1, C.shade, z + 1)
    solid(parent, x + w - 1, y, 1, h, C.shade, z + 1)
end

-- a slot is the inverse bevel: dark top and left, white bottom and right
local function slotBox(parent, x, y, size, z)
    local s = size or 18
    z = z or 3
    local holder = new("Frame", {
        Position = off(x, y), Size = dim(s, s),
        BackgroundColor3 = C.slot, BorderSizePixel = 0, ZIndex = z,
    }, parent)
    solid(holder, 0, 0, s, 1, C.slotDark, z + 1)
    solid(holder, 0, 0, 1, s, C.slotDark, z + 1)
    solid(holder, 0, s - 1, s, 1, C.light, z + 1)
    solid(holder, s - 1, 0, 1, s, C.light, z + 1)
    return holder
end

local function pixelText(parent, x, y, text, col, z, align)
    local size = 7 * S
    local shadow = new("TextLabel", {
        Position = off(x, y) + UDim2.fromOffset(math.max(1, S // 2), math.max(1, S // 2)),
        Size = UDim2.fromOffset(0, size), AutomaticSize = Enum.AutomaticSize.X,
        BackgroundTransparency = 1, FontFace = F_PIXEL, Text = text,
        TextSize = size, TextColor3 = (col or C.text):Lerp(C.edge, 0.72),
        TextXAlignment = align or Enum.TextXAlignment.Left,
        TextYAlignment = Enum.TextYAlignment.Center, ZIndex = (z or 8) - 1,
    }, parent)
    local main = new("TextLabel", {
        Position = off(x, y), Size = UDim2.fromOffset(0, size),
        AutomaticSize = Enum.AutomaticSize.X,
        BackgroundTransparency = 1, FontFace = F_PIXEL, Text = text,
        TextSize = size, TextColor3 = col or C.text,
        TextXAlignment = align or Enum.TextXAlignment.Left,
        TextYAlignment = Enum.TextYAlignment.Center, ZIndex = z or 8,
    }, parent)
    return main, shadow
end

--============================================================================
-- gui root
--============================================================================

local gui, panel, world
local blur
local tip, tipName, tipLore, tipBg
local dragIcon
local slots = {}          -- every live slot widget
local hotSlots = {}
local tabButtons = {}
local avatar = { parts = {} }

local openState = false
local currentTab = 1
local gridOffset = 0
local dragging = nil      -- { item = ..., from = "grid"/"hot", index = n }
local hovered = nil

local function host()
    if type(gethui) == "function" then
        local ok, h = pcall(gethui)
        if ok and h then return h end
    end
    local ok, core = pcall(function() return game:GetService("CoreGui") end)
    if ok and core then return core end
    return LocalPlayer:WaitForChild("PlayerGui")
end

--============================================================================
-- the spec
--  A module hands over tabs of items. An item is whatever the GTA menu already
--  produces -- toggle, slider, action, cycle -- plus an icon name.
--============================================================================

local spec = nil          -- { title, config, tabs = { {name, icon, items} }, armour, offhand, presets }

local function cfg() return (spec and spec.config) or {} end

local function itemState(item)
    if item.kind == "toggle" then
        return cfg()[item.key] and true or false
    end
    return false
end

-- the stack count in the corner of the slot: a slider shows its value, a cycle
-- shows nothing (its value goes in the tooltip), a toggle shows nothing
local function itemCount(item)
    if item.kind == "slider" then
        local v = cfg()[item.key]
        if type(v) ~= "number" then return "" end
        if v >= 1000 then return string.format("%.0fk", v / 1000) end
        return string.format("%." .. (item.dec or 0) .. "f", v)
    end
    return ""
end

local function fireItem(item, dir)
    if not item then return end
    local conf = cfg()
    if item.kind == "toggle" then
        conf[item.key] = not conf[item.key]
        if item.onChange then pcall(item.onChange, conf[item.key]) end
    elseif item.kind == "slider" then
        local step = item.step or 1
        local v = (conf[item.key] or item.min or 0) + step * (dir or 1)
        conf[item.key] = math.clamp(v, item.min or 0, item.max or 100)
        if item.onChange then pcall(item.onChange, conf[item.key]) end
    elseif item.kind == "cycle" then
        local list = item.list or {}
        local at = 1
        for i, v in ipairs(list) do if v == conf[item.key] then at = i break end end
        at = ((at - 1 + (dir or 1)) % math.max(1, #list)) + 1
        conf[item.key] = list[at]
        if item.onChange then pcall(item.onChange, conf[item.key]) end
    elseif item.kind == "action" and item.run then
        pcall(item.run)
    end
end

local function tabItems(index)
    local tab = spec and spec.tabs and spec.tabs[index]
    return (tab and tab.items) or {}
end

--============================================================================
-- hotbar binding
--  Drag an item onto a hotbar slot and the number key fires it, inventory open
--  or shut. Stored by label so it survives a config reload.
--============================================================================

local hotbar = {}         -- [1..9] = item

local function hotbarLabels()
    local out = {}
    for i = 1, 9 do out[i] = hotbar[i] and hotbar[i].label or "" end
    return out
end

local function restoreHotbar(labels)
    if type(labels) ~= "table" then return end
    local byLabel = {}
    for t = 1, #(spec.tabs or {}) do
        for _, item in ipairs(tabItems(t)) do
            if item.label then byLabel[item.label] = item end
        end
    end
    for i = 1, 9 do
        local want = labels[i]
        hotbar[i] = (want and want ~= "" and byLabel[want]) or nil
    end
end

--============================================================================
-- sound
--  rbxasset://sounds/volume_slider.ogg is in the client's own content folder,
--  so it needs no upload and no network. Three playback speeds stand in for
--  Minecraft's click, place and pick up.
--============================================================================

local clickSound = new("Sound", {
    SoundId = "rbxasset://sounds/volume_slider.ogg", Volume = 0.35,
}, game:GetService("SoundService"))

local function blip(speed, vol)
    if not Settings.Sounds then return end
    clickSound.PlaybackSpeed = speed or 1
    clickSound.Volume = vol or 0.35
    pcall(function() clickSound:Play() end)
end

--============================================================================
-- player preview
--  Vanilla rotates the whole model a little and the head a lot more, both
--  toward the cursor. A clone in a ViewportFrame has nothing animating it, so
--  every part is placed by hand off the root: body parts follow the root's
--  rotation, the head and whatever is strapped to it get the extra turn.
--============================================================================

local function headish(part)
    if part.Name == "Head" then return true end
    local acc = part:FindFirstAncestorWhichIsA("Accessory")
    if acc then
        local att = part:FindFirstChildWhichIsA("Attachment")
        local name = (att and att.Name) or acc.Name
        return string.find(name, "Hat") ~= nil or string.find(name, "Hair") ~= nil
            or string.find(name, "Face") ~= nil or string.find(name, "Head") ~= nil
    end
    return false
end

local function buildAvatar(parent, x, y, w, h)
    local vp = new("ViewportFrame", {
        Position = off(x, y), Size = dim(w, h),
        BackgroundTransparency = 1, ZIndex = 4,
        LightDirection = Vector3.new(-0.3, -0.6, -1),
        LightColor = Color3.fromRGB(255, 252, 240),
        Ambient = Color3.fromRGB(150, 150, 155),
    }, parent)

    avatar.vp = vp
    avatar.parts = {}
    avatar.model = nil

    local char = LocalPlayer.Character
    if not char then return vp end

    local wasArchivable = char.Archivable
    char.Archivable = true
    local ok, clone = pcall(function() return char:Clone() end)
    char.Archivable = wasArchivable
    if not ok or not clone then return vp end

    for _, d in ipairs(clone:GetDescendants()) do
        if d:IsA("Script") or d:IsA("LocalScript") or d:IsA("Sound")
            or d:IsA("ParticleEmitter") or d:IsA("Light") then
            d:Destroy()
        end
    end
    local hum = clone:FindFirstChildWhichIsA("Humanoid")
    if hum then hum.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None end

    local root = clone:FindFirstChild("HumanoidRootPart") or clone.PrimaryPart
        or clone:FindFirstChild("Torso") or clone:FindFirstChild("UpperTorso")
    if not root then clone:Destroy() return vp end

    local baseRoot = root.CFrame
    local headPart = clone:FindFirstChild("Head")
    local relHead  = headPart and (baseRoot:Inverse() * headPart.CFrame) or nil

    for _, d in ipairs(clone:GetDescendants()) do
        if d:IsA("BasePart") then
            local rel = baseRoot:Inverse() * d.CFrame
            avatar.parts[#avatar.parts + 1] = {
                part = d, rel = rel, head = headish(d),
                relToHead = relHead and (relHead:Inverse() * rel) or nil,
            }
            d.Anchored = true
            d.CanCollide = false
        end
    end

    clone.Parent = vp
    avatar.model   = clone
    avatar.base    = baseRoot
    avatar.relHead = relHead

    local cam = new("Camera", {}, vp)
    vp.CurrentCamera = cam
    cam.CFrame = CFrame.lookAt(
        baseRoot.Position + baseRoot.LookVector * -4.6 + Vector3.new(0, 0.35, 0),
        baseRoot.Position + Vector3.new(0, 0.1, 0))
    cam.FieldOfView = 36

    return vp
end

local function stepAvatar()
    if not avatar.model or not avatar.base then return end
    local base = avatar.base
    local yaw, pitch = 0, 0

    if Settings.HeadTrack and avatar.vp then
        local m    = UserInputService:GetMouseLocation()
        local abs  = avatar.vp.AbsolutePosition
        local size = avatar.vp.AbsoluteSize
        local cx   = abs.X + size.X * 0.5
        local cy   = abs.Y + size.Y * 0.5
        local vpSize = (Camera and Camera.ViewportSize) or Vector2.new(1920, 1080)
        yaw   = math.clamp((m.X - cx) / (vpSize.X * 0.35), -1, 1) * 0.8
        pitch = math.clamp((m.Y - cy) / (vpSize.Y * 0.35), -1, 1) * 0.5
    end

    local bodyCF = base * CFrame.Angles(0, yaw * 0.35, 0)
    local headCF = nil
    if avatar.relHead then
        headCF = bodyCF * avatar.relHead * CFrame.Angles(pitch, yaw * 0.65, 0)
    end

    for _, entry in ipairs(avatar.parts) do
        if entry.head and headCF and entry.relToHead then
            entry.part.CFrame = headCF * entry.relToHead
        else
            entry.part.CFrame = bodyCF * entry.rel
        end
    end
end

--============================================================================
-- tooltip
--  The vanilla item tooltip: near black box, two tone purple border, item name
--  in white, the lore under it in grey.
--============================================================================

local function buildTip(parent)
    tip = new("Frame", {
        BackgroundTransparency = 1, Visible = false, ZIndex = 60,
        Size = UDim2.fromOffset(10, 10),
    }, parent)
    tipBg = new("Frame", {
        BackgroundColor3 = C.tipBg, BorderSizePixel = 0,
        Size = UDim2.fromScale(1, 1), ZIndex = 60,
    }, tip)
    new("UIStroke", {
        Color = C.tipEdge, Thickness = math.max(1, S - 1),
        ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Transparency = 0.35,
    }, tipBg)
    tipName = new("TextLabel", {
        Position = UDim2.fromOffset(4 * S, 3 * S), Size = UDim2.fromOffset(0, 7 * S),
        AutomaticSize = Enum.AutomaticSize.X, BackgroundTransparency = 1,
        FontFace = F_PIXEL, TextSize = 7 * S, TextColor3 = C.white,
        TextXAlignment = Enum.TextXAlignment.Left, Text = "", ZIndex = 62,
    }, tip)
    tipLore = new("TextLabel", {
        Position = UDim2.fromOffset(4 * S, 12 * S), Size = UDim2.fromOffset(0, 7 * S),
        AutomaticSize = Enum.AutomaticSize.X, BackgroundTransparency = 1,
        FontFace = F_PIXEL, TextSize = 6 * S, TextColor3 = C.lore,
        TextXAlignment = Enum.TextXAlignment.Left, Text = "", ZIndex = 62,
    }, tip)
end

local function showTip(name, lore)
    if not tip then return end
    tipName.Text = name or ""
    tipLore.Text = lore or ""
    tipLore.Visible = (lore ~= nil and lore ~= "")
    local wide = math.max(tipName.AbsoluteSize.X, tipLore.Visible and tipLore.AbsoluteSize.X or 0)
    tip.Size = UDim2.fromOffset(wide + 8 * S, (tipLore.Visible and 22 or 13) * S)
    tip.Visible = true
end

local function hideTip()
    if tip then tip.Visible = false end
end

local function moveTip()
    if not tip or not tip.Visible then return end
    local m = UserInputService:GetMouseLocation()
    local vp = (Camera and Camera.ViewportSize) or Vector2.new(1920, 1080)
    local x = m.X + 4 * S
    local y = m.Y - 2 * S
    if x + tip.AbsoluteSize.X > vp.X then x = m.X - tip.AbsoluteSize.X - 4 * S end
    if y + tip.AbsoluteSize.Y > vp.Y then y = vp.Y - tip.AbsoluteSize.Y end
    tip.Position = UDim2.fromOffset(x, y)
end

--============================================================================
-- slots
--============================================================================

local SLOT = 18

local function makeSlot(parent, x, y, role, index)
    local holder = slotBox(parent, x, y, SLOT)

    local hover = new("Frame", {
        Position = off(1, 1), Size = dim(16, 16), BackgroundColor3 = C.white,
        BackgroundTransparency = 0.72, BorderSizePixel = 0, Visible = false, ZIndex = 5,
    }, holder)

    local icon = new("ImageLabel", {
        Position = off(1, 1), Size = dim(16, 16), BackgroundTransparency = 1,
        ScaleType = Enum.ScaleType.Stretch, ResampleMode = Enum.ResamplerMode.Pixelated,
        Image = "", Visible = false, ZIndex = 6,
    }, holder)

    local chip = new("Frame", {
        Position = off(4, 4), Size = dim(10, 10), BorderSizePixel = 0,
        BackgroundColor3 = C.slot, Visible = false, ZIndex = 6,
    }, holder)

    local glint = new("Frame", {
        Position = off(1, 1), Size = dim(16, 16), BackgroundColor3 = C.glint,
        BackgroundTransparency = 0.45, BorderSizePixel = 0, Visible = false, ZIndex = 7,
    }, holder)
    local grad = new("UIGradient", {
        Rotation = 35,
        Transparency = NumberSequence.new({
            NumberSequenceKeypoint.new(0, 1),
            NumberSequenceKeypoint.new(0.42, 1),
            NumberSequenceKeypoint.new(0.5, 0.25),
            NumberSequenceKeypoint.new(0.58, 1),
            NumberSequenceKeypoint.new(1, 1),
        }),
    }, glint)

    local count = new("TextLabel", {
        Position = off(0, 8), Size = dim(17, 9), BackgroundTransparency = 1,
        FontFace = F_PIXEL, TextSize = 6 * S, TextColor3 = C.white,
        TextXAlignment = Enum.TextXAlignment.Right,
        TextYAlignment = Enum.TextYAlignment.Bottom, Text = "", ZIndex = 9,
    }, holder)
    new("UIStroke", { Color = C.edge, Thickness = math.max(1, S - 2), Transparency = 0.2 }, count)

    local btn = new("TextButton", {
        Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Text = "",
        AutoButtonColor = false, ZIndex = 20,
    }, holder)

    local slot = {
        role = role, index = index, item = nil,
        holder = holder, icon = icon, chip = chip, glint = glint,
        grad = grad, count = count, hover = hover, btn = btn,
    }

    function slot.setItem(item)
        slot.item = item
        if not item then
            icon.Visible, chip.Visible, glint.Visible = false, false, false
            count.Text = ""
            return
        end
        local content = iconContent(item.icon)
        if content then
            icon.ImageContent = content
            icon.Visible, chip.Visible = true, false
        else
            chip.BackgroundColor3 = FLAT[item.icon] or C.grey
            chip.Visible, icon.Visible = true, false
        end
        count.Text = itemCount(item)
        glint.Visible = itemState(item)
    end

    slots[#slots + 1] = slot
    return slot
end

local function slotTipText(slot)
    local item = slot.item
    if not item then
        if slot.role == "hot" then return "Empty slot", "drag a feature here for key " .. slot.index end
        return nil
    end
    local name = item.label or "?"
    local lore = item.desc
    if item.kind == "toggle" then
        name = name .. (itemState(item) and "  [on]" or "  [off]")
    elseif item.kind == "slider" or item.kind == "cycle" then
        name = name .. "  " .. tostring(cfg()[item.key])
    end
    if slot.role == "grid" then
        lore = (lore or "") .. (lore and "   " or "") .. "shift-click to hotbar"
    end
    return name, lore
end

--============================================================================
-- panel
--  Vanilla sheet coordinates, shifted down by the tab strip.
--============================================================================

local TOP      = 16
local gridSlots, armourSlots, craftSlots = {}, {}, {}
local resultSlot, offhandSlot
local titleLabel, pageLabel

local function buildTabs(parent)
    for i, tab in ipairs(spec.tabs or {}) do
        local x = (i - 1) * 28
        local holder = new("Frame", {
            Position = off(x, 0), Size = dim(27, TOP + 1),
            BackgroundColor3 = C.panel, BorderSizePixel = 0, ZIndex = 2,
        }, parent)
        solid(holder, 0, 0, 27, 1, C.light, 3)
        solid(holder, 0, 0, 1, TOP, C.light, 3)
        solid(holder, 26, 0, 1, TOP, C.shade, 3)

        local icon = new("ImageLabel", {
            Position = off(6, 1), Size = dim(16, 16), BackgroundTransparency = 1,
            ResampleMode = Enum.ResamplerMode.Pixelated, ZIndex = 5, Visible = false,
        }, holder)
        local content = iconContent(tab.icon)
        if content then icon.ImageContent = content icon.Visible = true end

        local btn = new("TextButton", {
            Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Text = "",
            AutoButtonColor = false, ZIndex = 20,
        }, holder)

        tabButtons[i] = { holder = holder, btn = btn, icon = icon, name = tab.name }
    end
end

local function buildPanel()
    S = pickScale()

    gui = new("ScreenGui", {
        Name = "AuroraInventory", IgnoreGuiInset = true, DisplayOrder = 9999,
        ResetOnSpawn = false, ZIndexBehavior = Enum.ZIndexBehavior.Global,
        Enabled = true,
    })
    gui.Parent = host()

    world = new("Frame", {
        Size = UDim2.fromScale(1, 1), BackgroundColor3 = C.edge,
        BackgroundTransparency = 0.72, BorderSizePixel = 0, Visible = false, ZIndex = 1,
    }, gui)

    panel = new("Frame", {
        AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5),
        Size = dim(W, H + TOP), BackgroundTransparency = 1, Visible = false, ZIndex = 2,
    }, gui)

    buildTabs(panel)
    bevel(panel, 0, TOP, W, H, 2)

    titleLabel = pixelText(panel, 8, TOP + 5, spec.title or "Inventory", C.text, 9)
    pageLabel  = pixelText(panel, 8, TOP + 74, "", C.text, 9)

    -- armour column, then the preview, then the offhand: the vanilla left half
    for i = 1, 4 do
        armourSlots[i] = makeSlot(panel, 7, TOP + 7 + (i - 1) * SLOT, "armour", i)
    end
    offhandSlot = makeSlot(panel, 77, TOP + 61, "offhand", 1)
    buildAvatar(panel, 26, TOP + 8, 50, 68)

    -- crafting 2x2 and its result
    local cpos = { { 98, 17 }, { 116, 17 }, { 98, 35 }, { 116, 35 } }
    for i, p in ipairs(cpos) do
        craftSlots[i] = makeSlot(panel, p[1], TOP + p[2], "craft", i)
    end
    resultSlot = makeSlot(panel, 153, TOP + 27, "result", 1)
    pixelText(panel, 98, TOP + 8, "PRESETS", C.text, 9)

    -- the 27
    for row = 0, 2 do
        for col = 0, 8 do
            local n = row * 9 + col + 1
            gridSlots[n] = makeSlot(panel, 7 + col * SLOT, TOP + 83 + row * SLOT, "grid", n)
        end
    end

    -- the 9
    for col = 0, 8 do
        hotSlots[col + 1] = makeSlot(panel, 7 + col * SLOT, TOP + 141, "hot", col + 1)
        pixelText(panel, 11 + col * SLOT, TOP + 137, tostring(col + 1), C.text, 25)
    end

    dragIcon = new("ImageLabel", {
        Size = dim(16, 16), BackgroundTransparency = 1, Visible = false, ZIndex = 80,
        ResampleMode = Enum.ResamplerMode.Pixelated,
    }, gui)
    new("Frame", {
        Size = UDim2.fromScale(1, 1), BackgroundColor3 = C.grey,
        BackgroundTransparency = 0.5, BorderSizePixel = 0, ZIndex = 79,
    }, dragIcon)

    buildTip(gui)

    if Settings.Blur then
        blur = new("BlurEffect", { Size = 0, Enabled = false }, Lighting)
    end
end

--============================================================================
-- refresh
--============================================================================

local function refresh()
    local items = tabItems(currentTab)
    local total = #items

    gridOffset = math.clamp(gridOffset, 0, math.max(0, math.ceil((total - 27) / 9)) * 9)

    for n = 1, 27 do
        gridSlots[n].setItem(items[n + gridOffset])
    end
    for i = 1, 9 do
        hotSlots[i].setItem(hotbar[i])
    end
    for i = 1, 4 do
        armourSlots[i].setItem((spec.armour or {})[i])
        craftSlots[i].setItem((spec.presets or {})[i])
    end
    offhandSlot.setItem(spec.offhand)
    resultSlot.setItem(spec.result)

    for i, tb in ipairs(tabButtons) do
        local on = (i == currentTab)
        tb.holder.Position = off((i - 1) * 28, on and 0 or 2)
        tb.holder.BackgroundColor3 = on and C.panel or C.panel:Lerp(C.shade, 0.35)
    end

    if titleLabel then
        local tab = spec.tabs and spec.tabs[currentTab]
        titleLabel.Text = string.upper((tab and tab.name) or spec.title or "INVENTORY")
    end
    if pageLabel then
        pageLabel.Text = (total > 27)
            and string.format("%d-%d of %d   scroll", gridOffset + 1,
                math.min(total, gridOffset + 27), total)
            or ""
    end
end

MC.refresh = refresh

--============================================================================
-- open / close
--============================================================================

local STEP_BIND = "aurora_mc_step"
local SINK_BIND = "aurora_mc_sink"

local SINK_KEYS = {
    Enum.KeyCode.Up, Enum.KeyCode.Down, Enum.KeyCode.Left, Enum.KeyCode.Right,
    Enum.KeyCode.W, Enum.KeyCode.A, Enum.KeyCode.S, Enum.KeyCode.D,
    Enum.KeyCode.Space,
}

local function bindSink()
    ContextActionService:BindActionAtPriority(SINK_BIND, function()
        return Enum.ContextActionResult.Sink
    end, false, Enum.ContextActionPriority.High.Value + 1000, table.unpack(SINK_KEYS))
end

local function unbindSink()
    pcall(function() ContextActionService:UnbindAction(SINK_BIND) end)
end

local function setOpen(on)
    if openState == on then return end
    openState = on

    panel.Visible = on
    world.Visible = on
    if not on then hideTip() end

    if blur then
        blur.Enabled = true
        TweenService:Create(blur, TweenInfo.new(0.18), { Size = on and 8 or 0 }):Play()
        if not on then
            task.delay(0.22, function()
                if blur and not openState then blur.Enabled = false end
            end)
        end
    end

    if on then
        bindSink()
        refresh()
        blip(1.1, 0.3)
    else
        unbindSink()
        dragging = nil
        if dragIcon then dragIcon.Visible = false end
        blip(0.85, 0.25)
    end
end

MC.setOpen = setOpen
function MC.toggle() setOpen(not openState) end
function MC.isOpen() return openState end

--============================================================================
-- slot interaction
--  left click fires, right click steps the other way, shift-click sends a
--  feature to the first free hotbar slot, and a drag drops it on the key you
--  want. Scrolling a slider slot nudges it, like scrolling the hotbar.
--============================================================================

local function firstFreeHot()
    for i = 1, 9 do if not hotbar[i] then return i end end
    return 9
end

local function bindHot(index, item)
    for i = 1, 9 do if hotbar[i] == item then hotbar[i] = nil end end
    hotbar[index] = item
    if spec.onHotbar then pcall(spec.onHotbar, hotbarLabels()) end
    blip(1.5, 0.3)
    refresh()
end

local function wireSlot(slot)
    slot.btn.MouseEnter:Connect(function()
        hovered = slot
        slot.hover.Visible = true
        local name, lore = slotTipText(slot)
        if name then showTip(name, lore) else hideTip() end
    end)

    slot.btn.MouseLeave:Connect(function()
        slot.hover.Visible = false
        if hovered == slot then hovered = nil hideTip() end
    end)

    slot.btn.MouseButton1Down:Connect(function()
        if not slot.item then return end
        if slot.role == "grid" or slot.role == "hot" then
            dragging = { item = slot.item, from = slot }
            local content = iconContent(slot.item.icon)
            if content then
                dragIcon.ImageContent = content
                dragIcon.Visible = true
            end
        end
    end)

    slot.btn.MouseButton1Click:Connect(function()
        -- a drag that ended somewhere else is handled on release, not here
        if dragging and dragging.from ~= slot then return end

        local shift = UserInputService:IsKeyDown(Enum.KeyCode.LeftShift)
            or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)

        if slot.role == "grid" and slot.item and shift then
            bindHot(firstFreeHot(), slot.item)
            return
        end

        if slot.role == "craft" then
            if shift then
                if spec.savePreset then pcall(spec.savePreset, slot.index) end
            elseif spec.loadPreset then
                pcall(spec.loadPreset, slot.index)
            end
            blip(1.3, 0.3)
            refresh()
            return
        end

        if slot.item then
            fireItem(slot.item, 1)
            blip(itemState(slot.item) and 1.45 or 1.0, 0.32)
            refresh()
            local name, lore = slotTipText(slot)
            if name then showTip(name, lore) end
        end
    end)

    slot.btn.MouseButton2Click:Connect(function()
        if slot.role == "hot" then
            hotbar[slot.index] = nil
            if spec.onHotbar then pcall(spec.onHotbar, hotbarLabels()) end
            blip(0.8, 0.25)
            refresh()
            return
        end
        if slot.item then
            fireItem(slot.item, -1)
            blip(0.9, 0.3)
            refresh()
        end
    end)

    slot.btn.InputChanged:Connect(function(input)
        if input.UserInputType ~= Enum.UserInputType.MouseWheel then return end
        local dir = input.Position.Z > 0 and 1 or -1
        if slot.item and (slot.item.kind == "slider" or slot.item.kind == "cycle") then
            fireItem(slot.item, dir)
            refresh()
            local name, lore = slotTipText(slot)
            if name then showTip(name, lore) end
        elseif slot.role == "grid" then
            gridOffset = gridOffset - dir * 9
            refresh()
        end
    end)
end

local function wireTabs()
    for i, tb in ipairs(tabButtons) do
        tb.btn.MouseButton1Click:Connect(function()
            currentTab = i
            gridOffset = 0
            blip(1.2, 0.3)
            refresh()
        end)
        tb.btn.MouseEnter:Connect(function() showTip(tb.name, nil) end)
        tb.btn.MouseLeave:Connect(hideTip)
    end
end

--============================================================================
-- input
--============================================================================

local conns = {}

local function wireInput()
    conns[#conns + 1] = UserInputService.InputBegan:Connect(function(input, processed)
        if input.UserInputType ~= Enum.UserInputType.Keyboard then return end
        if UserInputService:GetFocusedTextBox() then return end

        if input.KeyCode == Settings.OpenKey then
            MC.toggle()
            return
        end

        if openState and input.KeyCode == Enum.KeyCode.Escape then
            setOpen(false)
            return
        end

        if processed and not openState then return end

        local n = tonumber(string.match(tostring(input.KeyCode), "KeyCode%.(%d)$"))
        if n and n >= 1 and n <= 9 then
            local item = hotbar[n]
            if item then
                fireItem(item, 1)
                blip(itemState(item) and 1.45 or 1.0, 0.32)
                if openState then refresh() end
            end
        end
    end)

    conns[#conns + 1] = UserInputService.InputEnded:Connect(function(input)
        if input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end
        if not dragging then return end
        local drop = hovered
        if drop and drop.role == "hot" and dragging.item then
            bindHot(drop.index, dragging.item)
        elseif drop and drop.role == "grid" and dragging.from.role == "hot" then
            hotbar[dragging.from.index] = nil
            if spec.onHotbar then pcall(spec.onHotbar, hotbarLabels()) end
            refresh()
        end
        dragging = nil
        if dragIcon then dragIcon.Visible = false end
    end)
end

local function stepLoop()
    local t = os.clock()
    if openState then
        stepAvatar()
        moveTip()
        for _, slot in ipairs(slots) do
            if slot.item then
                local on = itemState(slot.item)
                slot.glint.Visible = on
                if on then
                    slot.grad.Offset = Vector2.new(((t * 0.55) % 2) - 1, 0)
                end
                local c = itemCount(slot.item)
                if slot.count.Text ~= c then slot.count.Text = c end
            end
        end
        if dragging and dragIcon.Visible then
            local m = UserInputService:GetMouseLocation()
            dragIcon.Position = UDim2.fromOffset(m.X - 8 * S, m.Y - 8 * S)
        end
    end
end

--============================================================================
-- mount
--============================================================================

function MC.mount(s)
    assert(type(s) == "table", "mount needs a spec")
    assert(type(s.tabs) == "table" and #s.tabs > 0, "spec needs at least one tab")

    if MC.unload then pcall(MC.unload) end

    spec = s
    Settings.OpenKey = s.openKey or Settings.OpenKey
    slots, hotSlots, tabButtons = {}, {}, {}
    gridSlots, armourSlots, craftSlots = {}, {}, {}
    currentTab, gridOffset, openState = 1, 0, false

    buildPanel()
    for _, slot in ipairs(slots) do wireSlot(slot) end
    wireTabs()
    wireInput()
    restoreHotbar(s.hotbar)
    refresh()

    RunService:BindToRenderStep(STEP_BIND, Enum.RenderPriority.Last.Value, stepLoop)

    return MC
end

function MC.unload()
    pcall(function() RunService:UnbindFromRenderStep(STEP_BIND) end)
    unbindSink()
    for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
    conns = {}
    if blur then pcall(function() blur:Destroy() end) blur = nil end
    if gui then pcall(function() gui:Destroy() end) gui = nil end
    openState = false
    slots, hotSlots, tabButtons = {}, {}, {}
end

MC.Settings = Settings
MC.icons    = ICONS

_G.AuroraMC = MC

--============================================================================
-- demo spec
--  Runs on its own in any game so the skin can be looked at. A module replaces
--  this by calling MC.mount with its own tabs; the item shape is the one the
--  GTA menu already uses, with an icon name added.
--============================================================================

if _G.AURORA_MC_SPEC then
    return MC.mount(_G.AURORA_MC_SPEC)
end

local Config = {
    Fullbright = false, NoFog = false, WalkSpeed = 16, JumpPower = 50,
    InfJump = false, Aimbot = false, Silent = false, FovSize = 120,
    Esp = false, Tracers = false, Chams = false, KillAura = false,
    AntiFling = false, AntiVoid = false, GodMode = false, AntiRagdoll = false,
}

local function applyChar()
    local char = LocalPlayer.Character
    local hum = char and char:FindFirstChildWhichIsA("Humanoid")
    if not hum then return end
    hum.WalkSpeed  = Config.WalkSpeed
    hum.JumpPower  = Config.JumpPower
    hum.UseJumpPower = true
end

local function applyLight()
    Lighting.Brightness   = Config.Fullbright and 3 or 2
    Lighting.ClockTime    = Config.Fullbright and 14 or Lighting.ClockTime
    Lighting.Ambient      = Config.Fullbright and Color3.fromRGB(178, 178, 178)
        or Color3.fromRGB(70, 70, 70)
    Lighting.FogEnd       = Config.NoFog and 1e6 or 100000
end

UserInputService.JumpRequest:Connect(function()
    if not Config.InfJump then return end
    local char = LocalPlayer.Character
    local hum = char and char:FindFirstChildWhichIsA("Humanoid")
    if hum then hum:ChangeState(Enum.HumanoidStateType.Jumping) end
end)

local function Toggle(label, key, icon, desc, onChange)
    return { kind = "toggle", label = label, key = key, icon = icon,
             desc = desc, onChange = onChange }
end
local function Slider(label, key, icon, min, max, step, desc, onChange)
    return { kind = "slider", label = label, key = key, icon = icon, min = min,
             max = max, step = step, dec = 0, desc = desc, onChange = onChange }
end
local function Action(label, icon, run, desc)
    return { kind = "action", label = label, icon = icon, run = run, desc = desc }
end

local demoSpec = {
    title   = "Aurora",
    config  = Config,
    openKey = Enum.KeyCode.E,

    tabs = {
        { name = "Combat", icon = "sword", items = {
            Toggle("Aimbot",      "Aimbot",   "sword",   "Pull onto the closest head."),
            Toggle("Silent Aim",  "Silent",   "bow",     "Bend the shot instead of the camera."),
            Slider("FOV",         "FovSize",  "compass", 20, 500, 10, "Pixels of search radius."),
            Toggle("Kill Aura",   "KillAura", "tnt",     "Hit anything that comes close."),
        } },
        { name = "Visuals", icon = "eye", items = {
            Toggle("Player ESP",  "Esp",      "eye",     "Boxes and names through walls."),
            Toggle("Tracers",     "Tracers",  "compass", "Line from the bottom of the screen."),
            Toggle("Chams",       "Chams",    "potion",  "Fill bodies with colour."),
            Toggle("Fullbright",  "Fullbright","apple",  "Flatten the lighting.", applyLight),
            Toggle("No Fog",      "NoFog",    "diamond", "Push the fog to the horizon.", applyLight),
        } },
        { name = "Movement", icon = "feather", items = {
            Slider("Walk Speed",  "WalkSpeed","boots",   16, 200, 2, "Default is 16.", applyChar),
            Slider("Jump Power",  "JumpPower","feather", 50, 300, 5, "Default is 50.", applyChar),
            Toggle("Infinite Jump","InfJump", "feather",  "Jump again in mid air."),
            Action("Apply Now",   "clock", applyChar, "Push speed and jump onto your character."),
        } },
        { name = "Misc", icon = "book", items = {
            Action("Rejoin", "book", function()
                game:GetService("TeleportService"):Teleport(game.PlaceId, LocalPlayer)
            end, "Same place, fresh server."),
            Action("Rejoin Later", "clock", function() end, "Placeholder."),
        } },
    },

    armour = {
        Toggle("Anti Fling",   "AntiFling",   "shield", "Clamp silly velocities."),
        Toggle("Anti Void",    "AntiVoid",    "shield", "Catch a fall out of the map."),
        Toggle("God Mode",     "GodMode",     "apple",  "Whatever the game allows."),
        Toggle("Anti Ragdoll", "AntiRagdoll", "shield", "Stand back up."),
    },

    offhand = { kind = "action", label = "Unload", icon = "book",
        desc = "Remove the menu and every hook.", run = function() MC.unload() end },

    presets = {
        { kind = "action", label = "Preset 1", icon = "diamond", desc = "click load, shift-click save" },
        { kind = "action", label = "Preset 2", icon = "diamond", desc = "click load, shift-click save" },
        { kind = "action", label = "Preset 3", icon = "diamond", desc = "click load, shift-click save" },
        { kind = "action", label = "Preset 4", icon = "diamond", desc = "click load, shift-click save" },
    },

    result = { kind = "action", label = "Save To Disk", icon = "book",
        desc = "Write the current settings out." },

    hotbar = { "Aimbot", "Silent Aim", "Player ESP", "Fullbright", "Walk Speed",
               "Infinite Jump", "Kill Aura", "", "" },
}

MC.mount(demoSpec)
applyLight()

return MC
