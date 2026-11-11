--============================================================================
-- Aurora :: Minecraft inventory skin
--
--  The panel is the real thing now: his concept sheet, 780x744, fetched off
--  the asset repo and handed to the engine with getcustomasset, exactly like
--  the GTA fonts. Nothing about the frame is drawn by this script, so it
--  cannot look "nearly right" -- it is the picture.
--
--  Every interactive part sits on top of it at measured sheet coordinates:
--
--    slot pitch   72.78 px      slot box     64 px
--    main grid    10 x 4 at x0=32, rows y = 339, 412, 485, 558
--    hotbar       10 at y = 647, keys 1-9 and 0
--    armour       x=32,  y = 32, 105, 177, 250
--    side pair    x=323, y = 177, 250
--    crafting     (468,105) (541,105) (468,177) (541,177), result (686,145)
--    book         (686,250)
--    avatar box   100,28  222 x 286
--
--  Those were read off the png, not guessed: the slot interiors are #898989
--  against a #C6C6C6 panel, so a scan for that colour gives every rectangle.
--
--  What the slots hold:
--    main grid   every feature on the page, one per slot. A toggle that is on
--                gets the enchant glint; a slider shows its value as a count.
--    hotbar      the ten you drag down. Number keys fire them with the
--                inventory shut.
--    armour      the always-on passives.
--    side pair   unload, and the game's own panic toggle.
--    crafting    four config presets, result saves to disk.
--    book        flips to the next page, like the recipe book.
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

local Settings = {
    OpenKey   = Enum.KeyCode.RightShift,
    Height    = 0.60,       -- share of the screen the panel takes
    Sounds    = false,
    Blur      = true,
    HeadTrack = true,
}

--============================================================================
-- assets
--  Same door the GTA faces came through: pull the file once into the exec
--  workspace, then getcustomasset turns it into an rbxasset the engine cannot
--  tell from an upload. The fetch runs in its own thread -- HttpGet has to
--  pause mid call, and an executor's script thread is not always allowed to.
--============================================================================

local ASSET_HOST = "https://raw.githubusercontent.com/hahajaiisiu22/aurora-assets/main/"

local ASSETS = {
    { dir = "aurora_art",   path = "aurora_art/mc_inventory.png", url = "art/mc_inventory.png", min = 20000 },
    { dir = "aurora_art",   path = "aurora_art/mc_items.png",     url = "art/mc_items.png",     min = 2000  },
    { dir = "aurora_fonts", path = "aurora_fonts/Minecraft.ttf",  url = "fonts/Minecraft.ttf",  min = 10000 },
}

local assetNote = ""

local function ensureAssets()
    if type(writefile) ~= "function" or type(isfile) ~= "function" then return end

    local missing = {}
    local artMissing = false
    for _, a in ipairs(ASSETS) do
        if not isfile(a.path) then
            missing[#missing + 1] = a
            if a.dir == "aurora_art" then artMissing = true end
        end
    end
    if #missing == 0 then return end

    if artMissing then
        assetNote = "fetching the panel art -- run the script again in a moment"
    end

    task.spawn(function()
        local got, failed = 0, 0
        for _, a in ipairs(missing) do
            if type(makefolder) == "function" and type(isfolder) == "function"
                and not isfolder(a.dir) then
                pcall(makefolder, a.dir)
            end
            local ok, body = pcall(function() return game:HttpGet(ASSET_HOST .. a.url, true) end)
            -- a short body is an error page, not a png
            if ok and type(body) == "string" and #body >= a.min and pcall(writefile, a.path, body) then
                got += 1
            else
                failed += 1
            end
        end
        print(string.format("[aurora] inventory art: %d fetched, %d failed -- re-run", got, failed))
    end)
end

ensureAssets()

local function diskAsset(relPath)
    if type(getcustomasset) ~= "function" or type(isfile) ~= "function" then return nil end
    if not isfile(relPath) then return nil end
    local ok, id = pcall(getcustomasset, relPath)
    return ok and id or nil
end

local function loadDiskFace(fileName, familyName)
    if type(getcustomasset) ~= "function" or type(writefile) ~= "function" then return nil end
    if type(isfile) ~= "function" or not isfile("aurora_fonts/" .. fileName) then return nil end
    local ok, f = pcall(function()
        local asset   = getcustomasset("aurora_fonts/" .. fileName)
        local famPath = "aurora_fonts/" .. familyName .. ".json"
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

local PANEL_IMAGE = diskAsset("aurora_art/mc_inventory.png")
local ITEM_ATLAS  = diskAsset("aurora_art/mc_items.png")

--============================================================================
-- item sheet
--  25 vanilla item textures packed into one 640x640 png, five across, at the
--  size they arrived. Nineteen of them are 16x16 textures blown up 8x; the
--  other six -- chest, tnt, command block, redstone, shield, enchanted book --
--  are 3D block RENDERS with real shading in every pixel. Squashing those to
--  16x16 is what turned the tnt to mush, so nothing is resized any more: each
--  cell is the original file, and only the flat textures get pixel sampling.
--============================================================================

local ATLAS_COLS = 5
local ATLAS_CELL = 128
local ATLAS = {
    ["arrow"] = 0,
    ["barrier"] = 1,
    ["bow"] = 2,
    ["chest"] = 3,
    ["clock"] = 4,
    ["command_block"] = 5,
    ["compass"] = 6,
    ["crossbow"] = 7,
    ["diamond_boots"] = 8,
    ["diamond_sword"] = 9,
    ["elytra"] = 10,
    ["enchanted_book"] = 11,
    ["ender_eye"] = 12,
    ["ender_pearl"] = 13,
    ["glass_pane"] = 14,
    ["glowstone_dust"] = 15,
    ["golden_apple"] = 16,
    ["oak_boat"] = 17,
    ["rabbit_foot"] = 18,
    ["redstone_block"] = 19,
    ["shield"] = 20,
    ["spyglass"] = 21,
    ["tnt"] = 22,
    ["totem_of_undying"] = 23,
    ["water_bucket"] = 24,
}

-- six of them are not flat textures at all: chest, tnt, the command block,
-- redstone, the shield and the enchanted book ship as 128px 3D renders, so
-- they get smooth sampling. Everything else is a true 16x16 texture and
-- stays pixelated.
local SMOOTH = {
    ["chest"] = true,
    ["command_block"] = true,
    ["enchanted_book"] = true,
    ["redstone_block"] = true,
    ["shield"] = true,
    ["tnt"] = true,
}

-- the old hand drawn names still work, so a module written against them does
-- not have to be touched
local ALIAS = {
    sword = "diamond_sword", eye = "ender_eye", boots = "diamond_boots",
    book = "enchanted_book", potion = "water_bucket", apple = "golden_apple",
    diamond = "redstone_block", feather = "elytra", pearl = "ender_pearl",
    glass = "glass_pane", light = "glowstone_dust", boat = "oak_boat",
    totem = "totem_of_undying", jump = "rabbit_foot", command = "command_block",
}

--============================================================================
-- palette, taken off the sheet itself
--============================================================================

local C = {
    panel    = Color3.fromRGB(198, 198, 198),
    light    = Color3.fromRGB(255, 255, 255),
    shade    = Color3.fromRGB(85,  85,  85),
    edge     = Color3.fromRGB(0,   0,   0),
    slot     = Color3.fromRGB(137, 137, 139),
    text     = Color3.fromRGB(63,  63,  63),
    white    = Color3.fromRGB(255, 255, 255),
    grey     = Color3.fromRGB(170, 170, 170),
    tipBg    = Color3.fromRGB(16,  0,   16),
    tipEdge  = Color3.fromRGB(80,  0,   255),
    glint    = Color3.fromRGB(190, 110, 255),
    lore     = Color3.fromRGB(170, 170, 170),
}

--============================================================================
-- pixel canvas -> EditableImage
--  Item icons are 16x16 sprites painted at runtime. CreateEditableImage,
--  DrawRectangle and Content.fromObject are all in this client, so the icons
--  need no uploads either.
--============================================================================

local SIZE = 16

local Canvas = {}
Canvas.__index = Canvas

local function canvas() return setmetatable({ px = {} }, Canvas) end

function Canvas:set(x, y, col)
    if x < 0 or y < 0 or x >= SIZE or y >= SIZE then return end
    self.px[y * SIZE + x] = col
end

function Canvas:rect(x, y, w, h, col)
    for iy = y, y + h - 1 do
        for ix = x, x + w - 1 do self:set(ix, iy, col) end
    end
end

function Canvas:plot(list, col)
    for pair in string.gmatch(list, "[^%s]+") do
        local x, y = string.match(pair, "(%-?%d+),(%-?%d+)")
        if x then self:set(tonumber(x), tonumber(y), col) end
    end
end

function Canvas:diag(x, y, n, col)
    for i = 0, n - 1 do self:set(x + i, y - i, col) end
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
    white    = Color3.fromRGB(255, 255, 255),
}

local ICONS = {}

ICONS.sword = function(c)
    c:diag(4, 11, 9, P.iron)
    c:diag(5, 12, 8, P.ironD)
    c:plot("12,2 13,2 13,3", P.iron)
    c:plot("2,10 3,11 4,12 5,13", P.ironD)
    c:plot("1,14 2,13 1,13 2,14", P.wood)
end

ICONS.bow = function(c)
    c:plot("9,1 10,2 11,3 12,4 12,5 12,6 12,9 12,10 12,11 11,12 10,13 9,14", P.wood)
    c:plot("8,1 9,2 10,3 11,4 11,11 10,12 9,13 8,14", P.woodD)
    c:plot("9,2 9,3 9,4 9,5 9,6 9,7 9,8 9,9 9,10 9,11 9,12 9,13", P.strand)
    c:diag(3, 11, 7, P.woodD)
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
    if iconCache[name] ~= nil then return iconCache[name] or nil end
    if not canEdit() then iconCache[name] = false return nil end
    local ok, content = pcall(function()
        local c = canvas()
        ICONS[name](c)
        return Content.fromObject(c:flush())
    end)
    iconCache[name] = ok and content or false
    return iconCache[name] or nil
end

local FLAT

local function applyIcon(img, chip, name)
    local key = ALIAS[name or ""] or name
    local idx = key and ATLAS[key] or nil

    if ITEM_ATLAS and idx then
        img.Image = ITEM_ATLAS
        pcall(function() img.ImageContent = Content.fromUri(ITEM_ATLAS) end)
        img.ImageRectOffset = Vector2.new((idx % ATLAS_COLS) * ATLAS_CELL,
            math.floor(idx / ATLAS_COLS) * ATLAS_CELL)
        img.ImageRectSize = Vector2.new(ATLAS_CELL, ATLAS_CELL)
        img.ResampleMode = SMOOTH[key] and Enum.ResamplerMode.Default
            or Enum.ResamplerMode.Pixelated
        img.Visible = true
        if chip then chip.Visible = false end
        return true
    end

    -- no sheet on disk yet: the painted sprite, then a plain chip
    local content = iconContent(name)
    if content then
        img.ImageRectSize = Vector2.zero
        img.ImageContent = content
        img.Visible = true
        if chip then chip.Visible = false end
        return true
    end

    img.Visible = false
    if chip then
        chip.BackgroundColor3 = FLAT[name] or C.grey
        chip.Visible = true
    end
    return false
end

FLAT = {
    sword = P.iron, bow = P.wood, eye = P.eyeMid, feather = P.feather,
    boots = P.leather, potion = P.brew, tnt = P.tnt, compass = P.ironD,
    book = P.cover, apple = P.apple, diamond = P.diamond, shield = P.wood,
    clock = P.gold,
}

--============================================================================
-- sheet coordinates
--  Everything below is in png pixels on the 780x744 sheet and converted to
--  scale, so the overlay lands on the art at any size.
--============================================================================

local IMG_W, IMG_H = 780, 744
local SLOT         = 64
local PITCH        = 72.78

local COLX = {}
for i = 0, 9 do COLX[i + 1] = 32 + i * PITCH end

local ROWY   = { 339, 412, 485, 558 }
local HOTY   = 647
local ARMOUR = { 32, 105, 177, 250 }
local SIDEX, SIDEY = 323, { 177, 250 }
local CRAFT  = { { 468, 105 }, { 541, 105 }, { 468, 177 }, { 541, 177 } }
local RESULT = { 686, 145 }
local BOOK   = { 686, 250 }
local AVATAR = { 100, 28, 222, 286 }

local function new(class, props, parent)
    local i = Instance.new(class)
    for k, v in pairs(props or {}) do i[k] = v end
    if parent then i.Parent = parent end
    return i
end

local function sheetPos(x, y) return UDim2.fromScale(x / IMG_W, y / IMG_H) end
local function sheetSize(w, h) return UDim2.fromScale(w / IMG_W, h / IMG_H) end

--============================================================================
-- state
--============================================================================

local gui, panel, art, world, blur
local tip, tipName, tipLore
local dragIcon, headerLabel, noteLabel
local slots, gridSlots, hotSlots, armourSlots, craftSlots = {}, {}, {}, {}, {}
local resultSlot, sideSlots, bookSlot
local avatar = { parts = {} }

local spec        = nil
local openState   = false
local currentPage = 1
local gridOffset  = 0
local dragging    = nil
local hovered     = nil
local hotbar      = {}

local GRID_SLOTS = 40
local HOT_SLOTS  = 10
-- the last four slots of the bottom row are the utility corner: unload, the
-- console, presets and save. They never scroll away with the page.
local UTIL_FIRST = GRID_SLOTS - 3
local PAGE_SLOTS = UTIL_FIRST - 1

local function cfg() return (spec and spec.config) or {} end

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
-- sound
--  rbxasset://sounds/volume_slider.ogg ships inside the client, so the clicks
--  cost no upload and no network.
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
-- items
--============================================================================

local function itemState(item)
    return item.kind == "toggle" and cfg()[item.key] == true
end

-- Nothing is ever stamped on an item. A stack number on a spyglass reads as
-- "120 spyglasses", which is nonsense -- the value lives in the tooltip.
local function itemCount(_item)
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
        for i, v in ipairs(list) do
            if v == conf[item.key] then at = i break end
        end
        at = ((at - 1 + (dir or 1)) % math.max(1, #list)) + 1
        conf[item.key] = list[at]
        if item.onChange then pcall(item.onChange, conf[item.key]) end
    elseif item.kind == "action" and item.run then
        pcall(item.run)
    end
end

local function pageItems(index)
    local page = spec and spec.pages and spec.pages[index]
    return (page and page.items) or {}
end

local function hotbarLabels()
    local out = {}
    for i = 1, HOT_SLOTS do out[i] = hotbar[i] and hotbar[i].label or "" end
    return out
end

local function restoreHotbar(labels)
    if type(labels) ~= "table" then return end
    local byLabel = {}
    for p = 1, #((spec and spec.pages) or {}) do
        for _, item in ipairs(pageItems(p)) do
            if item.label then byLabel[item.label] = item end
        end
    end
    for i = 1, HOT_SLOTS do
        local want = labels[i]
        hotbar[i] = (want and want ~= "" and byLabel[want]) or nil
    end
end

--============================================================================
-- player preview
--  Vanilla turns the body a little and the head more, both toward the cursor.
--  A clone in a ViewportFrame has nothing animating it, so each part is placed
--  by hand off the root every frame; the head and anything strapped to it get
--  the extra turn.
--============================================================================

local function headish(part)
    if part.Name == "Head" then return true end
    local acc = part:FindFirstAncestorWhichIsA("Accessory")
    if not acc then return false end
    local att = part:FindFirstChildWhichIsA("Attachment")
    local name = (att and att.Name) or acc.Name
    return string.find(name, "Hat") ~= nil or string.find(name, "Hair") ~= nil
        or string.find(name, "Face") ~= nil or string.find(name, "Head") ~= nil
end

local function buildAvatar(parent)
    local vp = new("ViewportFrame", {
        Position = sheetPos(AVATAR[1], AVATAR[2]),
        Size = sheetSize(AVATAR[3], AVATAR[4]),
        BackgroundTransparency = 1, ZIndex = 4,
        LightDirection = Vector3.new(-0.3, -0.7, -1),
        LightColor = Color3.fromRGB(255, 252, 240),
        Ambient = Color3.fromRGB(160, 160, 165),
    }, parent)

    avatar.vp, avatar.parts, avatar.model = vp, {}, nil

    local char = LocalPlayer.Character
    if not char then return vp end

    local was = char.Archivable
    char.Archivable = true
    local ok, clone = pcall(function() return char:Clone() end)
    char.Archivable = was
    if not ok or not clone then return vp end

    for _, d in ipairs(clone:GetDescendants()) do
        if d:IsA("Script") or d:IsA("LocalScript") or d:IsA("Sound")
            or d:IsA("ParticleEmitter") or d:IsA("Light") then
            d:Destroy()
        end
    end

    local root = clone:FindFirstChild("HumanoidRootPart") or clone.PrimaryPart
        or clone:FindFirstChild("UpperTorso") or clone:FindFirstChild("Torso")
    if not root then clone:Destroy() return vp end

    local base    = root.CFrame
    local head    = clone:FindFirstChild("Head")
    local relHead = head and (base:Inverse() * head.CFrame) or nil

    for _, d in ipairs(clone:GetDescendants()) do
        if d:IsA("BasePart") then
            local rel = base:Inverse() * d.CFrame
            avatar.parts[#avatar.parts + 1] = {
                part = d, rel = rel, head = headish(d),
                relToHead = relHead and (relHead:Inverse() * rel) or nil,
            }
            d.Anchored, d.CanCollide = true, false
        end
    end

    clone.Parent  = vp
    avatar.model  = clone
    avatar.base   = base
    avatar.relHead = relHead

    local cam = new("Camera", {}, vp)
    vp.CurrentCamera = cam
    -- in FRONT of him: LookVector is the way he faces, so the camera stands out
    -- along it and looks back down it. The distance is not a guess -- it is the
    -- one that makes his real height fill the box: half his height divided by
    -- the tangent of half the field of view, plus a margin so nothing clips.
    local fov    = 30
    local extent = clone:GetExtentsSize()
    local height = math.max(extent.Y, 4)
    local dist   = (height * 0.5) / math.tan(math.rad(fov * 0.5)) * 1.18
    local mid    = clone:GetPivot().Position + Vector3.new(0, extent.Y * 0.08, 0)

    cam.FieldOfView = fov
    cam.CFrame = CFrame.lookAt(mid + base.LookVector * dist, mid)

    return vp
end

local function stepAvatar()
    if not avatar.model or not avatar.base then return end
    local yaw, pitch = 0, 0

    if Settings.HeadTrack and avatar.vp then
        local m    = UserInputService:GetMouseLocation()
        local abs  = avatar.vp.AbsolutePosition
        local size = avatar.vp.AbsoluteSize
        local vp   = (Camera and Camera.ViewportSize) or Vector2.new(1920, 1080)
        yaw   = math.clamp((m.X - (abs.X + size.X * 0.5)) / (vp.X * 0.32), -1, 1) * 0.85
        -- facing the camera flips up and down with it, same as left and right
        pitch = math.clamp((m.Y - (abs.Y + size.Y * 0.5)) / (vp.Y * 0.32), -1, 1) * -0.5
    end

    local bodyCF = avatar.base * CFrame.Angles(0, yaw * 0.35, 0)
    local headCF = avatar.relHead
        and (bodyCF * avatar.relHead * CFrame.Angles(pitch, yaw * 0.65, 0)) or nil

    for _, e in ipairs(avatar.parts) do
        if e.head and headCF and e.relToHead then
            e.part.CFrame = headCF * e.relToHead
        else
            e.part.CFrame = bodyCF * e.rel
        end
    end
end

--============================================================================
-- tooltip
--============================================================================

local function buildTip(parent)
    tip = new("Frame", {
        BackgroundColor3 = C.tipBg, BorderSizePixel = 0, Visible = false,
        ZIndex = 60, Size = UDim2.fromOffset(10, 10),
    }, parent)
    new("UIStroke", {
        Color = C.tipEdge, Thickness = 2, Transparency = 0.3,
        ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
    }, tip)
    tipName = new("TextLabel", {
        Position = UDim2.fromOffset(10, 7), Size = UDim2.fromOffset(0, 18),
        AutomaticSize = Enum.AutomaticSize.X, BackgroundTransparency = 1,
        FontFace = F_PIXEL, TextSize = 15, TextColor3 = C.white, Text = "",
        TextXAlignment = Enum.TextXAlignment.Left, ZIndex = 62,
    }, tip)
    tipLore = new("TextLabel", {
        Position = UDim2.fromOffset(10, 28), Size = UDim2.fromOffset(0, 16),
        AutomaticSize = Enum.AutomaticSize.X, BackgroundTransparency = 1,
        FontFace = F_PIXEL, TextSize = 12, TextColor3 = C.lore, Text = "",
        TextXAlignment = Enum.TextXAlignment.Left, ZIndex = 62,
    }, tip)
end

local function showTip(name, lore)
    if not tip then return end
    tipName.Text = name or ""
    tipLore.Text = lore or ""
    tipLore.Visible = (lore ~= nil and lore ~= "")
    local wide = math.max(tipName.AbsoluteSize.X, tipLore.Visible and tipLore.AbsoluteSize.X or 0)
    tip.Size = UDim2.fromOffset(wide + 20, tipLore.Visible and 52 or 32)
    tip.Visible = true
end

local function hideTip() if tip then tip.Visible = false end end

local function moveTip()
    if not tip or not tip.Visible then return end
    local m  = UserInputService:GetMouseLocation()
    local vp = (Camera and Camera.ViewportSize) or Vector2.new(1920, 1080)
    local x, y = m.X + 16, m.Y - 6
    if x + tip.AbsoluteSize.X > vp.X then x = m.X - tip.AbsoluteSize.X - 16 end
    if y + tip.AbsoluteSize.Y > vp.Y then y = vp.Y - tip.AbsoluteSize.Y end
    tip.Position = UDim2.fromOffset(x, y)
end

--============================================================================
-- slots, laid over the art
--============================================================================

local function makeSlot(parent, x, y, role, index)
    local holder = new("Frame", {
        Position = sheetPos(x, y), Size = sheetSize(SLOT, SLOT),
        BackgroundTransparency = 1, ZIndex = 5,
    }, parent)

    local hover = new("Frame", {
        Position = UDim2.fromScale(0.03, 0.03), Size = UDim2.fromScale(0.94, 0.94),
        BackgroundColor3 = C.white, BackgroundTransparency = 0.72,
        BorderSizePixel = 0, Visible = false, ZIndex = 6,
    }, holder)

    local icon = new("ImageLabel", {
        Position = UDim2.fromScale(0.125, 0.125), Size = UDim2.fromScale(0.75, 0.75),
        BackgroundTransparency = 1, Image = "", Visible = false, ZIndex = 8,
        ResampleMode = Enum.ResamplerMode.Pixelated,
    }, holder)

    local chip = new("Frame", {
        Position = UDim2.fromScale(0.22, 0.22), Size = UDim2.fromScale(0.56, 0.56),
        BackgroundColor3 = C.grey, BorderSizePixel = 0, Visible = false, ZIndex = 8,
    }, holder)

    local glint = new("Frame", {
        Position = UDim2.fromScale(0.08, 0.08), Size = UDim2.fromScale(0.84, 0.84),
        BackgroundColor3 = C.glint, BackgroundTransparency = 0.5,
        BorderSizePixel = 0, Visible = false, ZIndex = 9,
    }, holder)
    local grad = new("UIGradient", {
        Rotation = 35,
        Transparency = NumberSequence.new({
            NumberSequenceKeypoint.new(0, 1),
            NumberSequenceKeypoint.new(0.42, 1),
            NumberSequenceKeypoint.new(0.5, 0.2),
            NumberSequenceKeypoint.new(0.58, 1),
            NumberSequenceKeypoint.new(1, 1),
        }),
    }, glint)

    local count = new("TextLabel", {
        Position = UDim2.fromScale(0, 0.45), Size = UDim2.fromScale(0.92, 0.5),
        BackgroundTransparency = 1, FontFace = F_PIXEL, TextScaled = true,
        TextColor3 = C.white, Text = "", ZIndex = 10,
        TextXAlignment = Enum.TextXAlignment.Right,
        TextYAlignment = Enum.TextYAlignment.Bottom,
    }, holder)
    new("UIStroke", { Color = C.edge, Thickness = 2, Transparency = 0.15 }, count)
    new("UITextSizeConstraint", { MaxTextSize = 16 }, count)

    local btn = new("TextButton", {
        Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Text = "",
        AutoButtonColor = false, ZIndex = 20,
    }, holder)

    local slot = {
        role = role, index = index, item = nil, holder = holder, icon = icon,
        chip = chip, glint = glint, grad = grad, count = count,
        hover = hover, btn = btn,
    }

    function slot.setItem(item)
        slot.item = item
        if not item then
            icon.Visible, chip.Visible, glint.Visible = false, false, false
            count.Text = ""
            return
        end
        applyIcon(icon, chip, item.icon)
        count.Text  = itemCount(item)
        glint.Visible = itemState(item)
    end

    slots[#slots + 1] = slot
    return slot
end

local function slotTip(slot)
    local item = slot.item
    if not item then
        if slot.role == "hot" then
            return "Empty slot", "drag a feature here for key " .. (slot.index % 10)
        end
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
        lore = (lore and (lore .. "   ") or "") .. "shift-click to hotbar"
    end
    return name, lore
end

--============================================================================
-- panel
--============================================================================

local function panelSize()
    local vp = (Camera and Camera.ViewportSize) or Vector2.new(1920, 1080)
    local h  = math.floor(vp.Y * Settings.Height)
    local w  = math.floor(h * IMG_W / IMG_H)
    if w > vp.X * 0.95 then
        w = math.floor(vp.X * 0.95)
        h = math.floor(w * IMG_H / IMG_W)
    end
    return UDim2.fromOffset(w, h)
end

local function buildPanel()
    gui = new("ScreenGui", {
        Name = "AuroraInventory", IgnoreGuiInset = true, DisplayOrder = 9999,
        ResetOnSpawn = false, ZIndexBehavior = Enum.ZIndexBehavior.Global,
    })
    gui.Parent = host()

    world = new("Frame", {
        Size = UDim2.fromScale(1, 1), BackgroundColor3 = C.edge,
        BackgroundTransparency = 0.6, BorderSizePixel = 0, Visible = false, ZIndex = 1,
    }, gui)

    panel = new("Frame", {
        AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5),
        Size = panelSize(), BackgroundTransparency = 1, Visible = false, ZIndex = 2,
    }, gui)

    art = new("ImageLabel", {
        Size = UDim2.fromScale(1, 1), BackgroundTransparency = PANEL_IMAGE and 1 or 0,
        BackgroundColor3 = C.panel, BorderSizePixel = 0, ZIndex = 2,
        Image = PANEL_IMAGE or "", ResampleMode = Enum.ResamplerMode.Pixelated,
    }, panel)

    headerLabel = new("TextLabel", {
        Position = UDim2.fromScale(0, -0.055), Size = UDim2.fromScale(1, 0.045),
        BackgroundTransparency = 1, FontFace = F_PIXEL, TextScaled = true,
        TextColor3 = C.white, Text = "", ZIndex = 30,
        TextXAlignment = Enum.TextXAlignment.Left,
    }, panel)
    new("UIStroke", { Color = C.edge, Thickness = 2, Transparency = 0.2 }, headerLabel)
    new("UITextSizeConstraint", { MaxTextSize = 22 }, headerLabel)

    noteLabel = new("TextLabel", {
        Position = UDim2.fromScale(0, 1.01), Size = UDim2.fromScale(1, 0.04),
        BackgroundTransparency = 1, FontFace = F_PIXEL, TextScaled = true,
        TextColor3 = C.white, Text = assetNote, ZIndex = 30,
        TextXAlignment = Enum.TextXAlignment.Left,
    }, panel)
    new("UIStroke", { Color = C.edge, Thickness = 2, Transparency = 0.2 }, noteLabel)
    new("UITextSizeConstraint", { MaxTextSize = 16 }, noteLabel)

    buildAvatar(panel)

    for i = 1, 4 do
        armourSlots[i] = makeSlot(panel, 32, ARMOUR[i], "armour", i)
    end
    sideSlots = {
        makeSlot(panel, SIDEX, SIDEY[1], "side", 1),
        makeSlot(panel, SIDEX, SIDEY[2], "side", 2),
    }
    for i, p in ipairs(CRAFT) do
        craftSlots[i] = makeSlot(panel, p[1], p[2], "craft", i)
    end
    resultSlot = makeSlot(panel, RESULT[1], RESULT[2], "result", 1)
    bookSlot   = makeSlot(panel, BOOK[1], BOOK[2], "book", 1)

    for row = 1, 4 do
        for col = 1, 10 do
            local n = (row - 1) * 10 + col
            gridSlots[n] = makeSlot(panel, COLX[col], ROWY[row], "grid", n)
        end
    end
    for col = 1, 10 do
        hotSlots[col] = makeSlot(panel, COLX[col], HOTY, "hot", col)
    end

    dragIcon = new("ImageLabel", {
        Size = UDim2.fromOffset(42, 42), BackgroundTransparency = 1, Visible = false,
        ZIndex = 80, ResampleMode = Enum.ResamplerMode.Pixelated,
    }, gui)

    buildTip(gui)

    if Settings.Blur then
        blur = new("BlurEffect", { Size = 0, Enabled = false }, Lighting)
    end
end

--============================================================================
-- refresh
--============================================================================

local function refresh()
    local items = pageItems(currentPage)
    local total = #items
    local maxOff = math.max(0, math.ceil((total - PAGE_SLOTS) / 10) * 10)
    gridOffset = math.clamp(gridOffset, 0, maxOff)

    for n = 1, PAGE_SLOTS do gridSlots[n].setItem(items[n + gridOffset]) end
    for i = 1, 4 do
        gridSlots[UTIL_FIRST + i - 1].setItem((spec.utilities or {})[i])
    end
    for i = 1, HOT_SLOTS do hotSlots[i].setItem(hotbar[i]) end
    for i = 1, 4 do
        armourSlots[i].setItem((spec.armour or {})[i])
        craftSlots[i].setItem(nil)
    end
    sideSlots[1].setItem((spec.side or {})[1])
    sideSlots[2].setItem((spec.side or {})[2])
    resultSlot.setItem(spec.result)
    bookSlot.setItem(spec.bookItem or { kind = "action", label = "Pages", icon = "book" })

    local page = spec.pages[currentPage]
    headerLabel.Text = string.format("%s  --  %s  (%d/%d)",
        string.upper(spec.title or "AURORA"),
        string.upper((page and page.name) or "?"),
        currentPage, #spec.pages)

    noteLabel.Text = (total > PAGE_SLOTS)
        and string.format("%d-%d of %d   scroll the grid for more",
            gridOffset + 1, math.min(total, gridOffset + PAGE_SLOTS), total)
        or assetNote
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
    if openState == on or not panel then return end
    openState = on

    panel.Size   = panelSize()
    panel.Visible = on
    world.Visible = on
    if not on then hideTip() end

    if blur then
        blur.Enabled = true
        TweenService:Create(blur, TweenInfo.new(0.18), { Size = on and 10 or 0 }):Play()
        if not on then
            task.delay(0.24, function()
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

local function flipPage(dir)
    local n = #((spec and spec.pages) or {})
    if n == 0 then return end
    currentPage = ((currentPage - 1 + (dir or 1)) % n) + 1
    gridOffset = 0
    blip(1.2, 0.3)
    refresh()
end

--============================================================================
-- interaction
--============================================================================

local function firstFreeHot()
    for i = 1, HOT_SLOTS do if not hotbar[i] then return i end end
    return 1
end

local function bindHot(index, item)
    for i = 1, HOT_SLOTS do if hotbar[i] == item then hotbar[i] = nil end end
    hotbar[index] = item
    if spec.onHotbar then pcall(spec.onHotbar, hotbarLabels()) end
    blip(1.5, 0.3)
    refresh()
end

local function wireSlot(slot)
    slot.btn.MouseEnter:Connect(function()
        hovered = slot
        slot.hover.Visible = true
        if slot.role == "book" then
            local page = spec.pages[currentPage]
            showTip("Pages", string.format("%s  (%d/%d) -- click for the next one",
                (page and page.name) or "", currentPage, #spec.pages))
            return
        end
        local name, lore = slotTip(slot)
        if name then showTip(name, lore) else hideTip() end
    end)

    slot.btn.MouseLeave:Connect(function()
        slot.hover.Visible = false
        if hovered == slot then hovered = nil hideTip() end
    end)

    slot.btn.MouseButton1Down:Connect(function()
        if not slot.item then return end
        if slot.role ~= "grid" and slot.role ~= "hot" then return end
        if slot.role == "grid" and slot.index >= UTIL_FIRST then return end
        dragging = { item = slot.item, from = slot }
        if applyIcon(dragIcon, nil, slot.item.icon) then dragIcon.Visible = true end
    end)

    slot.btn.MouseButton1Click:Connect(function()
        if dragging and dragging.from ~= slot then return end

        if slot.role == "book" then flipPage(1) return end

        local shift = UserInputService:IsKeyDown(Enum.KeyCode.LeftShift)
            or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)

        if slot.role == "grid" and slot.item and shift then
            bindHot(firstFreeHot(), slot.item)
            return
        end

        if slot.item then
            fireItem(slot.item, 1)
            blip(itemState(slot.item) and 1.45 or 1.0, 0.32)
            refresh()
            local name, lore = slotTip(slot)
            if name then showTip(name, lore) end
        end
    end)

    slot.btn.MouseButton2Click:Connect(function()
        if slot.role == "book" then flipPage(-1) return end
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
        local item = slot.item
        if item and (item.kind == "slider" or item.kind == "cycle") then
            fireItem(item, dir)
            refresh()
            local name, lore = slotTip(slot)
            if name then showTip(name, lore) end
        elseif slot.role == "grid" then
            gridOffset = gridOffset - dir * 10
            refresh()
        end
    end)
end

--============================================================================
-- input
--============================================================================

local conns = {}

local function wireInput()
    conns[#conns + 1] = UserInputService.InputBegan:Connect(function(input, processed)
        if input.UserInputType ~= Enum.UserInputType.Keyboard then return end
        if UserInputService:GetFocusedTextBox() then return end

        if input.KeyCode == Settings.OpenKey then MC.toggle() return end
        if openState and input.KeyCode == Enum.KeyCode.Escape then setOpen(false) return end
        if openState and input.KeyCode == Enum.KeyCode.Right then flipPage(1) return end
        if openState and input.KeyCode == Enum.KeyCode.Left then flipPage(-1) return end
        if processed and not openState then return end

        local n = tonumber(string.match(tostring(input.KeyCode), "KeyCode%.(%d)$"))
        if n then
            local item = hotbar[n == 0 and 10 or n]
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

    if Camera then
        conns[#conns + 1] = Camera:GetPropertyChangedSignal("ViewportSize"):Connect(function()
            if panel then panel.Size = panelSize() end
        end)
    end
end

local function stepLoop()
    if not openState then return end
    local t = os.clock()
    stepAvatar()
    moveTip()
    for _, slot in ipairs(slots) do
        if slot.item then
            local on = itemState(slot.item)
            slot.glint.Visible = on
            if on then slot.grad.Offset = Vector2.new(((t * 0.55) % 2) - 1, 0) end
            local c = itemCount(slot.item)
            if slot.count.Text ~= c then slot.count.Text = c end
        end
    end
    if dragging and dragIcon.Visible then
        local m = UserInputService:GetMouseLocation()
        dragIcon.Position = UDim2.fromOffset(m.X - 21, m.Y - 21)
    end
end

--============================================================================
-- mount
--============================================================================

function MC.mount(s)
    assert(type(s) == "table", "mount needs a spec")
    assert(type(s.pages) == "table" and #s.pages > 0, "spec needs at least one page")

    pcall(function() if _G.__AURORA_MC then _G.__AURORA_MC() end end)

    spec = s
    Settings.OpenKey = s.openKey or Settings.OpenKey
    slots, gridSlots, hotSlots, armourSlots, craftSlots = {}, {}, {}, {}, {}
    hotbar = {}
    currentPage, gridOffset, openState = 1, 0, false

    buildPanel()
    for _, slot in ipairs(slots) do wireSlot(slot) end
    wireInput()
    restoreHotbar(s.hotbar)
    refresh()

    RunService:BindToRenderStep(STEP_BIND, Enum.RenderPriority.Last.Value, stepLoop)
    _G.__AURORA_MC = MC.unload
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
    slots, hotSlots = {}, {}
    _G.__AURORA_MC = nil
end

MC.Settings = Settings
MC.icons    = ICONS
_G.AuroraMC = MC

--============================================================================
-- demo spec
--  Runs standalone so the skin can be looked at in any game. A module hands
--  MC.mount its own pages instead; the item shape is the one the GTA menu
--  already produces, with an icon name added.
--============================================================================

if _G.AURORA_MC_SPEC then return MC.mount(_G.AURORA_MC_SPEC) end

local Config = {
    Fullbright = false, NoFog = false, WalkSpeed = 16, JumpPower = 50,
    InfJump = false, Aimbot = false, Silent = false, FovSize = 120,
    Esp = false, Tracers = false, Chams = false, KillAura = false,
    AntiFling = false, AntiVoid = false, GodMode = false, AntiRagdoll = false,
    Bone = "Head", Smooth = 3,
}

local function applyChar()
    local char = LocalPlayer.Character
    local hum  = char and char:FindFirstChildWhichIsA("Humanoid")
    if not hum then return end
    hum.UseJumpPower = true
    hum.WalkSpeed    = Config.WalkSpeed
    hum.JumpPower    = Config.JumpPower
end

local function applyLight()
    Lighting.Brightness = Config.Fullbright and 3 or 2
    Lighting.Ambient    = Config.Fullbright and Color3.fromRGB(178, 178, 178)
        or Color3.fromRGB(70, 70, 70)
    Lighting.FogEnd     = Config.NoFog and 1e6 or 100000
end

UserInputService.JumpRequest:Connect(function()
    if not Config.InfJump then return end
    local char = LocalPlayer.Character
    local hum  = char and char:FindFirstChildWhichIsA("Humanoid")
    if hum then hum:ChangeState(Enum.HumanoidStateType.Jumping) end
end)

local function Toggle(label, key, icon, desc, onChange)
    return { kind = "toggle", label = label, key = key, icon = icon, desc = desc, onChange = onChange }
end
local function Slider(label, key, icon, min, max, step, desc, onChange)
    return { kind = "slider", label = label, key = key, icon = icon, min = min, max = max,
             step = step, dec = 0, desc = desc, onChange = onChange }
end
local function Cycle(label, key, icon, list, desc)
    return { kind = "cycle", label = label, key = key, icon = icon, list = list, desc = desc }
end
local function Action(label, icon, run, desc)
    return { kind = "action", label = label, icon = icon, run = run, desc = desc }
end

local demoSpec = {
    title   = "Aurora",
    config  = Config,
    openKey = Enum.KeyCode.RightShift,

    pages = {
        { name = "Combat", items = {
            Toggle("Aimbot",       "Aimbot",    "diamond_sword",   "Pull onto the closest head."),
            Toggle("Silent Aim",   "Silent",    "crossbow",     "Bend the shot, not the camera."),
            Slider("FOV",          "FovSize",   "spyglass", 20, 500, 10, "Search radius in pixels."),
            Slider("Smoothing",    "Smooth",    "clock",   1, 20, 1,    "Higher is slower and softer."),
            Cycle ("Bone",         "Bone",      "arrow",     { "Head", "Torso", "Nearest" }, "Where the aim lands."),
            Toggle("Kill Aura",    "KillAura",  "tnt",     "Hit anything that comes close."),
        } },
        { name = "Visuals", items = {
            Toggle("Player ESP",   "Esp",       "ender_eye",     "Boxes and names through walls."),
            Toggle("Tracers",      "Tracers",   "compass", "Line from the bottom of the screen."),
            Toggle("Chams",        "Chams",     "water_bucket",  "Fill bodies with colour."),
            Toggle("Fullbright",   "Fullbright","glowstone_dust",   "Flatten the lighting.", applyLight),
            Toggle("No Fog",       "NoFog",     "glass_pane", "Push the fog to the horizon.", applyLight),
        } },
        { name = "Movement", items = {
            Slider("Walk Speed",   "WalkSpeed", "diamond_boots",   16, 200, 2, "Default is 16.", applyChar),
            Slider("Jump Power",   "JumpPower", "rabbit_foot", 50, 300, 5, "Default is 50.", applyChar),
            Toggle("Infinite Jump","InfJump",   "elytra", "Jump again in mid air."),
            Action("Apply Now",    "redstone_block", applyChar, "Push speed and jump onto your character."),
        } },
        { name = "Misc", items = {
            Toggle("Anti Fling",   "AntiFling",   "shield",           "Clamp silly velocities."),
            Toggle("Anti Void",    "AntiVoid",    "ender_pearl",      "Catch a fall out of the map."),
            Toggle("God Mode",     "GodMode",     "golden_apple",     "Whatever the game allows."),
            Toggle("Anti Ragdoll", "AntiRagdoll", "totem_of_undying", "Stand back up."),
            Action("Rejoin", "oak_boat", function()
                game:GetService("TeleportService"):Teleport(game.PlaceId, LocalPlayer)
            end, "Same place, fresh server."),
        } },
    },

    -- the armour column, the pair beside the preview and the result slot stay
    -- empty: they are armour and a crafting output, not a home for features.
    -- The 2x2 is the utility block instead.
    utilities = {
        Action("Unload",  "barrier",       function() MC.unload() end,
            "Remove the menu, the hooks and this panel."),
        Action("Console", "command_block", function() end,
            "The command bar. Not wired up yet."),
        Action("Presets", "chest",         function() end,
            "Saved loadouts live here."),
        Action("Save",    "redstone_block",function() end,
            "Write the current settings to disk."),
    },

    hotbar = { "Aimbot", "Silent Aim", "Player ESP", "Fullbright", "Walk Speed",
               "Infinite Jump", "Kill Aura", "Chams", "No Fog", "Apply Now" },
}

MC.mount(demoSpec)
applyLight()

return MC
