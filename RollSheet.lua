-- RollSheet.lua  v1.8.0
-- RP dice roller + character sheet  ·  World of Warcraft: Midnight
-- /rs  or  /rollsheet
--
-- /rs            → toggle the toolbar
-- /rs sheet      → toggle the character sheet
-- /rs minimap    → toggle the minimap button
-- /rs view [n]   → view a player's sheet (your target if no name given)
--                  Same faction only, same or connected realm.
-- /rs share      → push your sheet to your party / raid
-- /rs d20+3 [label] → roll any die with a modifier (macro-friendly)
-- /rs rolls      → cycle roll display: rewrite / echo / off
-- /rs debug      → print addon traffic to chat (for testing sync)
-- /rs ping       → whisper yourself a test message (use with /rs debug)
-- /rs reset      → wipe SavedVariables and rebuild (troubleshooting)
local addonName, ns = ...

-- ================================================================
--  Constants
-- ================================================================

local ADDON_VERSION = "1.8.0"
local ADDON_PREFIX = "RSHEET2"   -- new prefix: v1.4 is not wire-compatible with 1.3.x

local RES_TYPES = {
    "Mana","Energy","Rage","Runic Power","Focus",
    "Combo Points","Chi","Holy Power","Insanity",
    "Fury","Pain","Essence","Astral Power","Anguish","Custom",
}

local RES_COL = {
    Mana             = {0.00, 0.10, 0.90},
    Energy           = {1.00, 0.82, 0.00},
    Rage             = {0.80, 0.10, 0.10},
    ["Runic Power"]  = {0.00, 0.82, 1.00},
    Focus            = {1.00, 0.50, 0.00},
    ["Combo Points"] = {1.00, 0.96, 0.41},
    Chi              = {0.60, 0.95, 0.85},
    ["Holy Power"]   = {0.95, 0.90, 0.40},
    Insanity         = {0.40, 0.00, 0.80},
    Fury             = {0.50, 0.05, 0.70},
    Pain             = {1.00, 0.61, 0.00},
    Essence          = {0.40, 0.80, 0.94},
    ["Astral Power"] = {0.22, 0.47, 0.85},
    Anguish          = {0.55, 0.08, 0.08},
    Custom           = {0.75, 0.75, 0.75},
}

local RES_LBL_COL = {
    Mana             = {0.40, 0.60, 1.00},
    Energy           = {1.00, 0.90, 0.40},
    Rage             = {1.00, 0.40, 0.40},
    ["Runic Power"]  = {0.40, 0.90, 1.00},
    Focus            = {1.00, 0.65, 0.30},
    ["Combo Points"] = {1.00, 0.96, 0.55},
    Chi              = {0.70, 1.00, 0.90},
    ["Holy Power"]   = {1.00, 0.95, 0.55},
    Insanity         = {0.75, 0.40, 1.00},
    Fury             = {0.80, 0.40, 1.00},
    Pain             = {1.00, 0.70, 0.20},
    Essence          = {0.55, 0.90, 1.00},
    ["Astral Power"] = {0.55, 0.70, 1.00},
    Anguish          = {0.80, 0.25, 0.25},
    Custom           = {0.90, 0.90, 0.90},
}

-- ── Armour types & default AC values (were missing in v4.1) ────
local ARM_ORDER  = { "Light", "Medium", "Heavy" }
local ARM_AC_DEF = { Light = 13, Medium = 14, Heavy = 15 }

-- ================================================================
--  SavedVariables / defaults
-- ================================================================

local function InitDB()
    RollSheetDB = RollSheetDB or {}
    local db    = RollSheetDB
    if db.sheetOpen == nil then db.sheetOpen = false end
    if not db.hp then
        db.hp = { current = 20, max = 20 }
    end
    if not db.armour then
        db.armour = { typeIdx = 1, ac = 13 }
    end
    -- Sanitise armour typeIdx (may be corrupt from an older version)
    if type(db.armour.typeIdx) ~= "number"
       or db.armour.typeIdx < 1
       or db.armour.typeIdx > #ARM_ORDER then
        db.armour.typeIdx = 1
    end
    if not db.resources then
        db.resources = {
            { rtype="Mana", custom="", current=100, max=100, color={0.00,0.10,0.90} },
        }
    end
    if not db.attacks then
        db.attacks = {
            { name="Primary Attack",   bonus=3, sides=20 },
            { name="Secondary Attack", bonus=1, sides=20 },
        }
    end
    for _, a in ipairs(db.attacks) do          -- 1.4 → 1.5: rolls can use any die
        if type(a.sides) ~= "number" then a.sides = 20 end
    end
    -- 1.6: stable ids so pins survive rolls being added or removed
    db.nextRollId = db.nextRollId or 1
    for _, a in ipairs(db.attacks) do
        if not a.id then a.id = db.nextRollId; db.nextRollId = db.nextRollId + 1 end
    end
    if not db.custom then db.custom = { sides = 6, mod = 0, label = "" } end
    if not db.pins then
        db.pins = {
            db.attacks[1] and db.attacks[1].id or nil,
            db.attacks[2] and db.attacks[2].id or nil,
        }
    end
    if type(db.parchment) ~= "string" or db.parchment == "quest" then db.parchment = "rollsheet" end   -- quest scroll removed in 1.7.3
    if db.rollStyle ~= "rewrite" and db.rollStyle ~= "echo" and db.rollStyle ~= "off" then
        db.rollStyle = "rewrite"
    end
    if not db.minimap then
        db.minimap = { hide = false, minimapPos = 215 }   -- LibDBIcon settings
    end
end

-- ================================================================
--  Identity helpers
-- ================================================================
-- Every player is identified by "Name-Realm" (realm normalised, no
-- spaces or hyphens) and stored under a lowercase key.  The old
-- version stripped the realm, which made whispers to anyone from a
-- connected realm go to the wrong (usually non-existent) player.

local function IsSecret(v)
    return issecretvalue ~= nil and issecretvalue(v) or false
end

local myRealm
local function MyRealm()
    if not myRealm or myRealm == "" then
        myRealm = (GetNormalizedRealmName and GetNormalizedRealmName())
               or (GetRealmName() or ""):gsub("[%s%-]", "")
    end
    return myRealm
end

-- FullName("Renarian")              → "Renarian-ArgentDawn"
-- FullName("Renarian", "Argent Dawn") → "Renarian-ArgentDawn"
-- FullName("Renarian-ArgentDawn")   → "Renarian-ArgentDawn"
-- Returns nil for missing, UNKNOWN or Midnight "secret" names.
local function FullName(name, realm)
    if name == nil or IsSecret(name) or IsSecret(realm) then return nil end
    local ok, out = pcall(function()
        if name == "" or name == UNKNOWN then return nil end
        local n, r = name:match("^([^%-]+)%-(.+)$")
        if n then name, realm = n, r end
        if not realm or realm == "" then realm = MyRealm() end
        realm = realm:gsub("[%s%-]", "")
        return name .. "-" .. realm
    end)
    if ok and type(out) == "string" then return out end
    return nil
end

local function UnitFull(unit)
    local ok, n, r = pcall(UnitName, unit)
    if not ok then return nil end
    return FullName(n, r)
end

local myFull, myKey
local function Me()
    if not myFull then
        myFull = UnitFull("player")
        myKey  = myFull and myFull:lower()
    end
    return myFull, myKey
end

local function Short(full)
    local ok, s = pcall(Ambiguate, full, "none")
    return (ok and s) or full
end

-- ================================================================
--  Serialization
-- ================================================================
-- Wire format v2:  records separated by ";", fields by ":".
-- No size cap here; the networking layer splits long sheets into
-- chunks instead of truncating them (v1.3.2 cut everything past
-- 250 characters, silently corrupting larger sheets).

local function San(s)
    return ((s or ""):gsub("[;:%^|]", "_"))
end

-- Strip UI escape codes from text received from other players.
local function Clean(s)
    return ((s or ""):gsub("|", ""):sub(1, 40))
end

local function Serialize()
    local db = RollSheetDB
    local t  = { "V:2" }
    t[#t+1] = "H:" .. db.hp.current .. ":" .. db.hp.max
    local at = ARM_ORDER[db.armour.typeIdx] or "Light"
    t[#t+1] = "A:" .. db.armour.ac .. ":" .. San(at)
    for _, r in ipairs(db.resources) do
        if r.rtype == "Custom" then
            local rc = r.color or {0.75, 0.75, 0.75}
            local hex = string.format("%02x%02x%02x",
                math.floor(rc[1]*255+0.5),
                math.floor(rc[2]*255+0.5),
                math.floor(rc[3]*255+0.5))
            t[#t+1] = "X:" .. San(r.custom) .. ":" .. r.current .. ":" .. r.max .. ":" .. hex
        else
            t[#t+1] = "R:" .. San(r.rtype) .. ":" .. r.current .. ":" .. r.max
        end
    end
    for _, a in ipairs(db.attacks) do
        t[#t+1] = "K:" .. San(a.name) .. ":" .. a.bonus .. ":" .. (a.sides or 20)
    end
    return table.concat(t, ";")
end

local function Deserialize(data)
    local s = { hp={current=20,max=20}, ac=0, armType="Light", resources={}, attacks={} }
    for chunk in data:gmatch("[^;]+") do
        local tag  = chunk:sub(1, 1)
        local rest = chunk:sub(3)
        if tag == "H" then
            local c, m = rest:match("(%d+):(%d+)")
            if c then s.hp = { current=tonumber(c), max=tonumber(m) } end
        elseif tag == "A" then
            local ac, at = rest:match("(%d+):(.*)")
            if ac then s.ac = tonumber(ac); s.armType = Clean(at) end
        elseif tag == "R" then
            local nm, c, m = rest:match("([^:]+):(%d+):(%d+)")
            if nm then
                nm = Clean(nm)
                local col = RES_COL[nm] or {0.75, 0.75, 0.75}
                table.insert(s.resources, { name=nm, current=tonumber(c), max=tonumber(m), color=col })
            end
        elseif tag == "X" then
            local nm, c, m, hex = rest:match("([^:]+):(%d+):(%d+):(%x%x%x%x%x%x)")
            if nm then
                local col = {
                    tonumber(hex:sub(1,2), 16) / 255,
                    tonumber(hex:sub(3,4), 16) / 255,
                    tonumber(hex:sub(5,6), 16) / 255,
                }
                table.insert(s.resources, { name=Clean(nm), current=tonumber(c), max=tonumber(m), color=col })
            end
        elseif tag == "K" then
            local nm, b, sd = rest:match("([^:]+):(-?%d+):?(%d*)")
            if nm then
                table.insert(s.attacks, { name=Clean(nm), bonus=tonumber(b), sides=tonumber(sd) or 20 })
            end
        end
    end
    return s
end

-- ================================================================
--  Roll records
-- ================================================================
-- How a roll is encoded so it stays honest in the native /roll line:
--
--   d20 + 3  →  RandomRoll(4, 23)
--
-- Everyone sees "Name rolls 18 (4-23)", a real, verifiable roll
-- whose range shows the +3.  RollSheet users see it rewritten as
-- "Name · Primary Attack: 15 + 3 = 18 (d20)".
--
-- /roll can't go below 0, so negative modifiers roll the plain die
-- (1-20) and only RollSheet users see the modifier applied.
--
-- Each roll is announced over addon comms just before it happens
-- (die, modifier, label).  Receivers keep the last few per player
-- and match them to the roll line by its range.

local MAX_SIDES, MAX_MOD = 1000, 100

local function RangeFor(sides, mod)
    if mod >= 0 then return 1 + mod, sides + mod end
    return 1, sides
end

local rollLog = {}   -- [key] = { {lo=,hi=,sides=,mod=,label=,t=}, ... } newest first

local function LogRoll(key, sides, mod, label)
    local lo, hi = RangeFor(sides, mod)
    local list = rollLog[key] or {}
    table.insert(list, 1, { lo=lo, hi=hi, sides=sides, mod=mod, label=label, t=GetTime() })
    while #list > 5 do table.remove(list) end
    rollLog[key] = list
end

local function FindRoll(key, lo, hi)
    local list = rollLog[key]
    if not list then return nil end
    local now = GetTime()
    for _, r in ipairs(list) do
        if r.lo == lo and r.hi == hi and now - r.t < 15 then return r end
    end
    return nil
end

-- ================================================================
--  Visual helpers
-- ================================================================

-- Border-only backdrop; parchment is a manual texture via SetAtlas so
-- the atlas UV coordinates map correctly and stretch to the full frame.
-- (SetTexture with the old file path loads the atlas sheet at native
--  sub-coords, which is why it never filled the frame.)
local BD_BORDER = {
    edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
    edgeSize = 14,
    insets   = {left=4, right=4, top=4, bottom=4},
}

-- ── Sheet backgrounds ────────────────────────────────────────────
-- Our own crest-free parchment ships with the addon and is always
-- available.  The Blizzard ones are only offered if this client
-- actually has them (names can change between patches).
local PARCHMENTS = {
    { key = "rollsheet",   label = "RollSheet parchment",   file  = "Interface\\AddOns\\RollSheet\\Media\\Parchment", always = true },
    { key = "achievement", label = "Achievement parchment", file  = "Interface\\AchievementFrame\\UI-Achievement-Parchment-Horizontal" },
    { key = "letter",      label = "Letter paper",          file  = "Interface\\Stationery\\StationeryTest1" },
    { key = "faction",     label = "Faction quest scroll (with crest)", faction = true },
}

local function ParchmentAvailable(p)
    if p.always then return true end
    local ok, found = pcall(function()
        if p.faction then
            local f = UnitFactionGroup("player") == "Horde" and "QuestBG-Horde" or "QuestBG-Alliance"
            return C_Texture.GetAtlasInfo(f) ~= nil
        end
        return GetFileIDFromPath and GetFileIDFromPath(p.file) ~= nil
    end)
    return ok and found
end

local function CurrentParchment()
    local key = RollSheetDB and RollSheetDB.parchment or "rollsheet"
    for _, p in ipairs(PARCHMENTS) do
        if p.key == key and ParchmentAvailable(p) then return p end
    end
    return PARCHMENTS[1]
end

local bgFrames = {}   -- every frame wearing a parchment, so a change applies live

local function PaintParchment(f)
    local p, tex = CurrentParchment(), f._rsParchment
    tex:SetTexCoord(0, 1, 0, 1)
    if p.faction then
        local atlas = (UnitFactionGroup("player") == "Horde") and "QuestBG-Horde" or "QuestBG-Alliance"
        tex:SetAtlas(atlas, false)   -- false = stretch to frame, not native size
    else
        tex:SetTexture(p.file)
    end
end

local function ApplyBG(f)
    -- Solid dark fill safety net behind the parchment
    if not f._rsBgFill then
        f._rsBgFill = f:CreateTexture(nil, "BACKGROUND", nil, -8)
        f._rsBgFill:SetAllPoints()
        f._rsBgFill:SetColorTexture(0.25, 0.18, 0.10, 0.97)
    end
    if not f._rsParchment then
        f._rsParchment = f:CreateTexture(nil, "BACKGROUND", nil, -7)
        f._rsParchment:SetAllPoints()
        bgFrames[#bgFrames + 1] = f
    end
    PaintParchment(f)
    -- Gold border
    f:SetBackdrop(BD_BORDER)
    f:SetBackdropBorderColor(0.65, 0.47, 0.14, 1.00)
end

local function RefreshParchments()
    for _, f in ipairs(bgFrames) do
        if f._rsParchment then PaintParchment(f) end
    end
end

local function Section(parent, label, y)
    local lbl = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    lbl:SetText(label:upper())
    lbl:SetTextColor(0.30, 0.16, 0.04)
    lbl:SetPoint("TOPLEFT", parent, "TOPLEFT", 14, y)
    local rule = parent:CreateTexture(nil, "ARTWORK")
    rule:SetHeight(1)
    rule:SetColorTexture(0.42, 0.26, 0.08, 0.50)
    rule:SetPoint("LEFT",  lbl,    "RIGHT",  6,  0)
    rule:SetPoint("TOP",   lbl,    "CENTER", 0,  0)
    rule:SetPoint("RIGHT", parent, "RIGHT", -14, 0)
end

local function Lbl(p, txt, font, r, g, b, a)
    local t = p:CreateFontString(nil, "OVERLAY", font or "GameFontNormalSmall")
    t:SetText(txt or "")
    if r then t:SetTextColor(r, g, b, a or 1) end
    return t
end

local function Btn(p, w, h, txt)
    local b = CreateFrame("Button", nil, p, "UIPanelButtonTemplate")
    b:SetSize(w, h)
    b:SetText(txt)
    local fs = b:GetFontString()
    if fs then fs:SetTextColor(0.93, 0.82, 0.48) end
    return b
end

local function EB(p, name, w, h, maxlen)
    local e = CreateFrame("EditBox", name, p, "InputBoxTemplate")
    e:SetSize(w, h); e:SetAutoFocus(false); e:SetMaxLetters(maxlen or 32)
    e:SetScript("OnEnterPressed", function(s) s:ClearFocus() end)
    e:SetScript("OnEscapePressed", function(s) s:ClearFocus() end)
    return e
end

local function Bar(p, w, h, r, g, b, cur, max)
    local bar = CreateFrame("StatusBar", nil, p)
    bar:SetSize(w, h)
    bar:SetStatusBarTexture("Interface/TargetingFrame/UI-StatusBar")
    bar:SetStatusBarColor(r, g, b)
    bar:SetMinMaxValues(0, max); bar:SetValue(cur)
    local bg = bar:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetTexture("Interface/Buttons/WHITE8X8")
    bg:SetVertexColor(0.18, 0.11, 0.04, 0.80)
    return bar
end

-- ================================================================
--  Frame references
-- ================================================================

local mainFrame, sheetFrame, viewFrame

-- ================================================================
--  Remote sheet viewer
-- ================================================================

local function ShowRemoteSheet(playerName, sheet)
    if viewFrame then viewFrame:Hide(); viewFrame = nil end
    local VW = 240

    viewFrame = CreateFrame("Frame", "RollSheetViewer", UIParent, "BackdropTemplate")
    viewFrame:SetWidth(VW)
    viewFrame:SetPoint("CENTER", UIParent, "CENTER", 200, 40)
    viewFrame:SetMovable(true); viewFrame:EnableMouse(true)
    viewFrame:RegisterForDrag("LeftButton")
    viewFrame:SetScript("OnDragStart", viewFrame.StartMoving)
    viewFrame:SetScript("OnDragStop",  viewFrame.StopMovingOrSizing)
    viewFrame:SetFrameStrata("DIALOG")
    ApplyBG(viewFrame)

    local y = -12

    local cl = Btn(viewFrame, 18, 18, "X")
    cl:SetPoint("TOPRIGHT", viewFrame, "TOPRIGHT", -8, -8)
    cl:SetScript("OnClick", function() viewFrame:Hide(); viewFrame = nil end)

    Lbl(viewFrame, playerName, "GameFontNormal", 0.55, 0.30, 0.05)
        :SetPoint("TOP", viewFrame, "TOP", 0, y)
    y = y - 20

    Section(viewFrame, "Health", y); y = y - 20

    local hpBar = Bar(viewFrame, VW-24, 20, 0.76, 0.12, 0.12, sheet.hp.current, sheet.hp.max)
    hpBar:SetPoint("TOPLEFT", viewFrame, "TOPLEFT", 12, y)
    local ht = hpBar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    ht:SetPoint("CENTER"); ht:SetTextColor(1, 1, 1, 0.9)
    ht:SetText(sheet.hp.current .. " / " .. sheet.hp.max)
    y = y - 26

    Lbl(viewFrame, "AC  " .. sheet.ac .. "   \194\183   " .. sheet.armType,
        nil, 0.12, 0.08, 0.04)
        :SetPoint("TOPLEFT", viewFrame, "TOPLEFT", 12, y)
    y = y - 22; y = y - 8

    if #sheet.resources > 0 then
        Section(viewFrame, "Resources", y); y = y - 20
        for _, res in ipairs(sheet.resources) do
            local c = res.color
            Lbl(viewFrame, res.name, "GameFontHighlightSmall", 0.28, 0.15, 0.04)
                :SetPoint("TOPLEFT", viewFrame, "TOPLEFT", 12, y)
            y = y - 16
            local rb = Bar(viewFrame, VW-24, 18, c[1], c[2], c[3], res.current, res.max)
            rb:SetPoint("TOPLEFT", viewFrame, "TOPLEFT", 12, y)
            local rt = rb:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            rt:SetPoint("CENTER"); rt:SetTextColor(1, 1, 1, 0.9)
            rt:SetText(res.current .. " / " .. res.max)
            y = y - 24
        end
        y = y - 4
    end

    if #sheet.attacks > 0 then
        Section(viewFrame, "Attacks", y); y = y - 20
        for _, atk in ipairs(sheet.attacks) do
            local sign = atk.bonus >= 0 and "+" or ""
            Lbl(viewFrame, "d" .. (atk.sides or 20) .. sign .. atk.bonus .. "   " .. atk.name,
                nil, 0.12, 0.08, 0.04)
                :SetPoint("TOPLEFT", viewFrame, "TOPLEFT", 12, y)
            y = y - 18
        end
        y = y - 4
    end

    y = y - 10
    viewFrame:SetHeight(math.abs(y) + 12)
    viewFrame:Show()
end

-- ================================================================
--  Networking
-- ================================================================
-- RollSheet shares sheets within your own faction only.
--
--   • GROUP   (PARTY / RAID / INSTANCE_CHAT)
--       Passive broadcasts whenever your stats change.  Reaches every
--       group member regardless of realm.
--   • WHISPER
--       Targeted requests (hover / /rs view) and replies.  Blizzard
--       only delivers addon whispers to players of your own faction on
--       your own or a connected realm.  Players you meet through
--       sharding from unconnected realms can only be reached by
--       grouping with them.
--
-- All traffic goes through one throttle-aware queue that reads the
-- result code from SendAddonMessage and retries when the server says
-- "slow down" or Midnight's encounter lockdown is active, instead of
-- dropping the message silently like v1.3.2 did.
--
-- Messages use SendAddonMessageLogged: sheets carry text the user
-- typed (attack and resource names), and Blizzard asks addons to log
-- user-written content so it can be reported if abused.

local sheetCache  = {}   -- [key] = sheet  (sheet.who = "Name-Realm", sheet.t = GetTime())
local pendingReq  = {}   -- [key] = true   /rs view requests waiting for a reply
local hoverPings  = {}   -- [key] = true   tooltip requests in flight
local noAddon     = {}   -- [key] = expiry players who didn't answer; don't re-ask for a while
local watchers    = {}   -- [key] = { full=, exp= } players who asked for our sheet recently

local NOADDON_TIME  = 300   -- seconds before re-asking someone who didn't answer
local REFRESH_AFTER = 60    -- seconds before a hover re-requests a cached sheet
local WATCH_TIME    = 300   -- seconds we keep pushing updates to someone who asked
local MAX_WATCHERS  = 10    -- cap on whispered updates per stat change
local CHUNK_SIZE    = 220   -- payload bytes per message (limit is 255 incl. header)

local debugComms = false
local function Dbg(...)
    if debugComms then print("|cff888888[RS]|r", ...) end
end

-- ── Send queue ────────────────────────────────────────────────────
local SEND = C_ChatInfo.SendAddonMessageLogged or C_ChatInfo.SendAddonMessage

-- Enum.SendAddonMessageResult values (warcraft.wiki.gg)
local RES_OK, RES_THROTTLE, RES_CHAN_THROTTLE = 0, 3, 8
local RES_LOCKDOWN, RES_OFFLINE, RES_ERROR    = 11, 12, 9

local queue, pumping = {}, false

local function TrySend(msg)
    if C_ChatInfo.InChatMessagingLockdown and C_ChatInfo.InChatMessagingLockdown() then
        return RES_LOCKDOWN
    end
    local r = { pcall(SEND, ADDON_PREFIX, msg.text, msg.chan, msg.target) }
    if not r[1] then return RES_ERROR end
    local code = r[#r]                -- result is always the last return value
    if code == nil or code == true then return RES_OK end
    if code == false then return RES_ERROR end
    return code
end

local function Pump()
    local now = GetTime()
    while #queue > 0 do
        local msg = queue[1]
        if now - msg.t > 60 then
            table.remove(queue, 1)    -- too old to matter any more
        else
            local code = TrySend(msg)
            if code == RES_THROTTLE or code == RES_CHAN_THROTTLE then
                Dbg("throttled, retrying in 1s")
                C_Timer.After(1, Pump); return
            elseif code == RES_LOCKDOWN then
                Dbg("chat lockdown active, retrying in 5s")
                C_Timer.After(5, Pump); return
            end
            table.remove(queue, 1)
            Dbg("sent", msg.chan, msg.target or "", msg.text:sub(1, 24), "→ code", code)
            if code == RES_OFFLINE and msg.target then
                local k = msg.target:lower()
                noAddon[k] = GetTime() + NOADDON_TIME
                watchers[k] = nil
            end
        end
    end
    pumping = false
end

local function Enqueue(text, chan, target)
    queue[#queue+1] = { text=text, chan=chan, target=target, t=GetTime() }
    if not pumping then pumping = true; Pump() end
end

-- ── Chunking ──────────────────────────────────────────────────────
-- Split without cutting a multi-byte UTF-8 character in half, so
-- names with accents survive and logged messages aren't rejected.
local function SplitUTF8(s, size)
    local parts, i, len = {}, 1, #s
    while i <= len do
        local j = math.min(i + size - 1, len)
        while j < len and j > i do
            local b = s:byte(j + 1)
            if b >= 0x80 and b < 0xC0 then j = j - 1 else break end
        end
        parts[#parts+1] = s:sub(i, j)
        i = j + 1
    end
    if #parts == 0 then parts[1] = "" end
    return parts
end

-- kind "S" = sheet for the cache, "P" = reply to /rs view (opens viewer)
-- Message: kind^id^part^total^data
local msgId = 0
local function SendSheet(kind, chan, target)
    local ok, data = pcall(Serialize)
    if not ok or not data then
        Dbg("serialize failed:", tostring(data)); return
    end
    msgId = (msgId % 99) + 1
    local parts = SplitUTF8(data, CHUNK_SIZE)
    for i, part in ipairs(parts) do
        Enqueue(kind .. "^" .. msgId .. "^" .. i .. "^" .. #parts .. "^" .. part, chan, target)
    end
end

-- Reassembly buffers, one per sender
local inbox = {}
local function Receive(key, kind, id, i, n, part)
    local now = GetTime()
    for k, b in pairs(inbox) do
        if now - b.t > 15 then inbox[k] = nil end
    end
    local box = inbox[key]
    if not box or box.id ~= id or box.kind ~= kind then
        box = { id=id, kind=kind, n=n, parts={}, got=0 }
        inbox[key] = box
    end
    box.t = now
    if not box.parts[i] then
        box.parts[i] = part
        box.got = box.got + 1
    end
    if box.got < box.n then return nil end
    inbox[key] = nil
    return table.concat(box.parts, "", 1, box.n)
end

-- ── Who can we reach? ─────────────────────────────────────────────
local function GetGroupChannel()
    if IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then
        return "INSTANCE_CHAT"
    elseif IsInRaid() then
        return "RAID"
    elseif IsInGroup() then
        return "PARTY"
    end
    return nil
end

local function InMyGroup(full)
    local ok, r = pcall(function()
        local s = Short(full)
        return UnitInParty(s) or UnitInRaid(s) ~= nil
    end)
    return ok and r
end

-- A unit we can whisper: a player of our faction on our own or a
-- connected realm.  Anyone else would just produce "player not
-- found" errors, so we don't try.
local function CanWhisperUnit(unit)
    local ok, r = pcall(function()
        if not UnitIsPlayer(unit) or UnitIsUnit(unit, "player") then return false end
        if UnitFactionGroup(unit) ~= UnitFactionGroup("player") then return false end
        if UnitIsSameServer and not UnitIsSameServer(unit) then return false end
        return true
    end)
    return ok and r
end

-- ── Broadcasting ──────────────────────────────────────────────────
-- Sends to the group, plus a whisper to anyone outside the group who
-- asked for our sheet in the last few minutes, so their tooltip and
-- viewer stay current without them having to ask again.
local function BroadcastSheet()
    if GetGroupChannel() then SendSheet("S", GetGroupChannel()) end
    local now, sent = GetTime(), 0
    for key, w in pairs(watchers) do
        if w.exp < now then
            watchers[key] = nil
        elseif sent < MAX_WATCHERS and not InMyGroup(w.full) then
            SendSheet("S", "WHISPER", w.full)
            sent = sent + 1
        end
    end
end

-- Debounced: many changes within 1.5s collapse into one broadcast.
local broadcastPending = false
local function ScheduleBroadcast()
    if broadcastPending then return end
    broadcastPending = true
    C_Timer.After(1.5, function()
        broadcastPending = false
        BroadcastSheet()
    end)
end

-- ── Incoming ──────────────────────────────────────────────────────
local function OnAddonMessage(prefix, text, channel, sender)
    if prefix ~= ADDON_PREFIX then return end
    local from = FullName(sender)
    if not from then return end
    local key = from:lower()
    local _, me = Me()
    Dbg("recv", channel, from, text:sub(1, 24))
    if key == me then return end            -- our own echo (or a loopback test)
    noAddon[key] = nil                       -- they clearly have the addon

    local kind = text:sub(1, 1)

    if kind == "R" then
        -- Roll announcement: "R^sides^mod^label"
        local sd, md, lbl = text:match("^R%^(%d+)%^(%-?%d+)%^(.*)$")
        sd, md = tonumber(sd), tonumber(md)
        if sd and md and sd >= 2 and sd <= MAX_SIDES and md >= -MAX_MOD and md <= MAX_MOD then
            LogRoll(key, sd, md, lbl ~= "" and Clean(lbl) or nil)
        end

    elseif kind == "Q" then
        -- Request: "Q^V" (from /rs view) or "Q^H" (tooltip hover)
        local mode = text:sub(3, 3)
        watchers[key] = { full = from, exp = GetTime() + WATCH_TIME }
        SendSheet(mode == "V" and "P" or "S", "WHISPER", from)

    elseif kind == "S" or kind == "P" then
        local id, i, n, part = text:match("^%a%^(%d+)%^(%d+)%^(%d+)%^(.*)$")
        id, i, n = tonumber(id), tonumber(i), tonumber(n)
        if not (id and i and n) or n < 1 or n > 20 or i < 1 or i > n then return end

        local data = Receive(key, kind, id, i, n, part)
        if not data then return end          -- waiting for more parts

        local ok, sheet = pcall(Deserialize, data)
        if not ok or not sheet then return end
        local isNew = sheetCache[key] == nil
        sheet.who, sheet.t = from, GetTime()
        sheetCache[key] = sheet

        if kind == "P" and pendingReq[key] then
            pendingReq[key] = nil
            ShowRemoteSheet(Short(from), sheet)
        end

        -- First contact by whisper: send ours back so they can see us
        -- too.  Skipped if they asked us first (they already got ours).
        if isNew and channel == "WHISPER" and not watchers[key] then
            SendSheet("S", "WHISPER", from)
        end
    end
end

local msgFrame = CreateFrame("Frame")
msgFrame:RegisterEvent("CHAT_MSG_ADDON")
msgFrame:RegisterEvent("CHAT_MSG_ADDON_LOGGED")
msgFrame:SetScript("OnEvent", function(_, _, ...)
    local ok, err = pcall(OnAddonMessage, ...)
    if not ok then Dbg("handler error:", tostring(err)) end
end)

-- ── Requests ──────────────────────────────────────────────────────
-- Called from tooltip hooks.  Asks a unit for its sheet if we don't
-- have a recent copy and they're someone we can actually reach.
local function EnsureData(unit)
    local full = UnitFull(unit)
    if not full then return end
    local key = full:lower()
    local _, me = Me()
    if key == me then return end

    local now = GetTime()
    local cached = sheetCache[key]
    if cached and now - cached.t < REFRESH_AFTER then return end
    if hoverPings[key] then return end
    if noAddon[key] and noAddon[key] > now then return end
    if not CanWhisperUnit(unit) then return end

    hoverPings[key] = true
    Enqueue("Q^H", "WHISPER", full)
    C_Timer.After(5, function()
        hoverPings[key] = nil
        if not sheetCache[key] then noAddon[key] = GetTime() + NOADDON_TIME end
    end)
end

local function RequestSheet(input)
    local full
    if input and input ~= "" then
        full = FullName(input)
    elseif UnitExists("target") and UnitIsPlayer("target") then
        if not CanWhisperUnit("target") then
            print("|cffaa8844RollSheet|r You can only view sheets of your own faction, on your own or a connected realm.")
            return
        end
        full = UnitFull("target")
    end
    if not full then
        print("|cffaa8844RollSheet|r Usage:  /rs view PlayerName  (or target someone and type /rs view)")
        return
    end

    local key = full:lower()

    -- Viewing yourself: no network needed.  Round-trip through the
    -- wire format so this shows exactly what other players receive.
    local _, me = Me()
    if key == me then
        local ok, sheet = pcall(function() return Deserialize(Serialize()) end)
        if ok and sheet then ShowRemoteSheet(Short(full), sheet) end
        return
    end

    noAddon[key] = nil
    if sheetCache[key] then ShowRemoteSheet(Short(full), sheetCache[key]) end

    pendingReq[key] = true
    Enqueue("Q^V", "WHISPER", full)
    print("|cffaa8844RollSheet|r Requested " .. Short(full) .. "'s sheet...")
    C_Timer.After(10, function()
        if pendingReq[key] then
            pendingReq[key] = nil
            print("|cffaa8844RollSheet|r No response from " .. Short(full)
                .. ". They may not have RollSheet, be offline, be from the other faction, or be on a realm that isn't connected to yours.")
        end
    end)
end

local function ShareSheet()
    local ch = GetGroupChannel()
    if ch then
        SendSheet("S", ch)
        print("|cffaa8844RollSheet|r Sheet shared with your group.")
    else
        print("|cffaa8844RollSheet|r Not in a group. Use /rs view <name> to request a specific player.")
    end
end

-- ================================================================
--  Roll engine
-- ================================================================

-- Announce to everyone who could see the roll and has RollSheet:
-- the group, plus anyone outside it who looked at our sheet recently.
local function AnnounceRoll(sides, mod, label)
    local text = "R^" .. sides .. "^" .. mod .. "^" .. San(label or ""):sub(1, 40)
    local ch = GetGroupChannel()
    if ch then Enqueue(text, ch) end
    local now, sent = GetTime(), 0
    for _, w in pairs(watchers) do
        if w.exp > now and sent < MAX_WATCHERS and not InMyGroup(w.full) then
            Enqueue(text, "WHISPER", w.full)
            sent = sent + 1
        end
    end
end

-- The one function every roll button goes through.
local function RollDie(sides, mod, label)
    sides = math.floor(tonumber(sides) or 20)
    mod   = math.floor(tonumber(mod) or 0)
    if sides < 2 or sides > MAX_SIDES then
        print("|cffaa8844RollSheet|r Dice need between 2 and " .. MAX_SIDES .. " sides.")
        return
    end
    if mod < -MAX_MOD or mod > MAX_MOD then
        print("|cffaa8844RollSheet|r Modifiers must be between -" .. MAX_MOD .. " and +" .. MAX_MOD .. ".")
        return
    end
    if label == "" then label = nil end

    local _, me = Me()
    if me then LogRoll(me, sides, mod, label) end
    AnnounceRoll(sides, mod, label)

    local lo, hi = RangeFor(sides, mod)
    RandomRoll(lo, hi)
end

-- ── Reading roll lines ───────────────────────────────────────────
-- Built from the game's own localised string, so it works on any
-- client language.  English: "%s rolls %d (%d-%d)"
local rollPattern
local function GetRollPattern()
    if rollPattern then return rollPattern end
    local fmt = RANDOM_ROLL_RESULT or "%s rolls %d (%d-%d)"
    fmt = fmt:gsub("%%%d%$([sd])", "%%%1")          -- "%1$s" → "%s"
    fmt = fmt:gsub("%%s", "\001"):gsub("%%d", "\002")
    fmt = fmt:gsub("([%%%(%)%.%+%-%*%?%[%]%^%$])", "%%%1")
    fmt = fmt:gsub("\001", "(.+)"):gsub("\002", "(%%d+)")
    rollPattern = "^" .. fmt .. "$"
    return rollPattern
end

local DOT = " \194\183 "   -- " · "

-- Returns the rewritten line, or nil to leave the original alone.
-- Must not change any state: chat filters run several times per line.
local function DecodeRollLine(msg)
    if type(msg) ~= "string" or IsSecret(msg) then return nil end
    local name, result, lo, hi = msg:match(GetRollPattern())
    if not name then return nil end
    result, lo, hi = tonumber(result), tonumber(lo), tonumber(hi)
    local full = FullName(name)
    if not (full and result and lo and hi) then return nil end
    local key = full:lower()

    local rec = FindRoll(key, lo, hi)
    local sides, mod, label
    if rec then
        sides, mod, label = rec.sides, rec.mod, rec.label
    else
        -- No announcement arrived.  Only decode from the range for
        -- players we know use RollSheet, so a stranger's
        -- "/roll 50-100" isn't misread as a d51+49.
        local _, me = Me()
        if lo <= 1 or not (sheetCache[key] or key == me) then return nil end
        mod, sides = lo - 1, hi - lo + 1
    end

    -- A plain roll with no label gains nothing from rewriting; keep
    -- the game's own line (and its language) untouched.
    if mod == 0 and not label then return nil end

    local nat, total
    if mod >= 0 then nat, total = result - mod, result
    else nat, total = result, result + mod end

    local die = "d" .. sides .. (mod > 0 and ("+" .. mod) or (mod < 0 and tostring(mod) or ""))
    local who = Short(full)
    local body
    if mod == 0 then
        body = tostring(nat)
    else
        body = nat .. (mod > 0 and " + " or " - ") .. math.abs(mod) .. " = " .. total
    end
    local out
    if label then
        out = who .. DOT .. Clean(label) .. ": " .. body .. "  (d" .. sides .. ")"
    else
        out = who .. DOT .. die .. ": " .. body        -- no words, so no language issues
    end

    if sides == 20 and nat == 20 then
        out = out .. "  |cff40ff40Natural 20!|r"
    elseif sides == 20 and nat == 1 then
        out = out .. "  |cffff4040Natural 1|r"
    end
    if mod ~= 0 then
        out = out .. "  |cff888888[" .. lo .. "-" .. hi .. "]|r"   -- the raw roll, for transparency
    end
    return out
end

-- rewrite: replace the system line   echo: add our line under it   off: untouched
local ROLL_STYLES = { "rewrite", "echo", "off" }

local function RollChatFilter(_, _, msg, ...)
    if not RollSheetDB or RollSheetDB.rollStyle ~= "rewrite" then return false end
    local ok, out = pcall(DecodeRollLine, msg)
    if ok and out then return false, out, ... end
    return false
end

local rollEcho = CreateFrame("Frame")
rollEcho:RegisterEvent("CHAT_MSG_SYSTEM")
rollEcho:SetScript("OnEvent", function(_, _, msg)
    if not RollSheetDB or RollSheetDB.rollStyle ~= "echo" then return end
    local ok, out = pcall(DecodeRollLine, msg)
    if ok and out and DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage(out, 1.0, 1.0, 0.0)
    end
end)

local function InstallRollFilter()
    local add = (ChatFrameUtil and ChatFrameUtil.AddMessageEventFilter)
             or ChatFrame_AddMessageEventFilter
    if add then
        local ok = pcall(add, "CHAT_MSG_SYSTEM", RollChatFilter)
        if ok then return true end
    end
    -- No filter API available: fall back to adding our own line.
    if RollSheetDB.rollStyle == "rewrite" then RollSheetDB.rollStyle = "echo" end
    return false
end

-- ================================================================
--  Bar artwork
-- ================================================================
-- The whole bar is one texture: Media/ButtonBar.tga.  Tiles, logo,
-- gear and chevron are painted into it; the addon lays invisible
-- buttons over them and draws only live text and pin icons on top.
--
-- All rectangles are in pixels of the 2048 x 512 master artwork
-- {x, y, width, height}.  The in-game file is a 1024 x 256 copy;
-- coordinates don't change because texture coords are proportional.
-- To use new artwork with the same layout, replace the TGA.  If the
-- layout changes, re-measure these rectangles.

local ART = {
    file     = "Interface\\AddOns\\RollSheet\\Media\\ButtonBar",
    master   = { 2048, 512 },
    scale    = 0.25,                      -- master px → UI units (bar art = 512 x 128)

    body     = {  295, 112, 1525, 288 },  -- the bar itself; ornaments overhang it
    tile     = {
        d20    = {  543, 174, 178, 166 },
        d100   = {  762, 174, 178, 166 },
        custom = {  983, 174, 178, 166 },
        pin1   = { 1204, 174, 178, 166 },
        pin2   = { 1428, 174, 178, 166 },
    },
    gear     = { 1686, 174,  82,  84 },
    chevron  = { 1686, 270,  80,  72 },
    logo     = {  295, 155, 132, 205 },   -- RS monogram: click to close the bar

    -- Inside of each pin tile's gold frame: the roll's icon fills this
    pinInner = {
        pin1 = { 1220, 190, 147, 136 },
        pin2 = { 1446, 190, 143, 136 },
    },

    -- The sheet hangs between the two lowest spike tips of the frame
    sheetLeft  = 327,
    sheetRight = 1752,
    sheetTop   = 396,                     -- tucked just under the bottom rail

    pinIcon  = {
        pin1 = "Interface/Icons/INV_Sword_04",
        pin2 = "Interface/Icons/Spell_Nature_Regeneration",
    },
    highlight = "Interface/Buttons/ButtonHilight-Square",
}

local FW = (ART.sheetRight - ART.sheetLeft) * ART.scale   -- sheet width

-- Size and position a frame over a master-artwork rectangle.
local function PlaceOnArt(frame, parent, r)
    local k = ART.scale
    frame:SetSize(r[3] * k, r[4] * k)
    frame:SetPoint("TOPLEFT", parent, "TOPLEFT", (r[1] - ART.body[1]) * k, -(r[2] - ART.body[2]) * k)
end

-- Texture coordinates of a master-artwork rectangle (for cropping).
local function ArtCoords(r)
    local W, H = ART.master[1], ART.master[2]
    return r[1] / W, (r[1] + r[3]) / W, r[2] / H, (r[2] + r[4]) / H
end

local function GetRollById(id)
    if not id then return nil end
    for _, a in ipairs(RollSheetDB.attacks) do
        if a.id == id then return a end
    end
    return nil
end

local function PinLabel(id)
    local p = RollSheetDB.pins
    if p[1] == id then return "1" elseif p[2] == id then return "2" end
    return "-"
end

local function ModText(mod)
    mod = mod or 0
    if mod > 0 then return "+" .. mod elseif mod < 0 then return tostring(mod) end
    return ""
end

-- "d6+2 Fireball" → 6, 2, "Fireball"     "d20" → 20, 0, nil
local function ParseRollSpec(text)
    text = strtrim(text or "")
    local sd, md, label = text:match("^[dD](%d+)%s*([%+%-]?%s*%d*)%s*(.*)$")
    if not sd then return nil end
    md = (md or ""):gsub("%s", "")
    if md == "+" or md == "-" then md = "" end
    return tonumber(sd), tonumber(md) or 0, (label ~= "" and label or nil)
end

local RefreshBar = function() end   -- replaced in BuildMain

-- ================================================================
--  BuildSheet
-- ================================================================

local function BuildSheet()
    if sheetFrame then sheetFrame:Hide(); sheetFrame = nil end

    local db  = RollSheetDB
    local y   = -14
    local barW = FW - 68

    sheetFrame = CreateFrame("Frame", "RollSheetPanel", mainFrame, "BackdropTemplate")
    sheetFrame:SetWidth(FW)
    sheetFrame:SetPoint("TOPLEFT", mainFrame, "TOPLEFT",
        (ART.sheetLeft - ART.body[1]) * ART.scale, -(ART.sheetTop - ART.body[2]) * ART.scale)
    ApplyBG(sheetFrame)
    sheetFrame:SetScript("OnShow", function() RefreshBar() end)
    sheetFrame:SetScript("OnHide", function() RefreshBar() end)

    -- ── HEALTH ─────────────────────────────────────────────────────
    Section(sheetFrame, "Health", y); y = y - 20

    local hpBar = Bar(sheetFrame, barW, 22, 0.76, 0.12, 0.12, db.hp.current, db.hp.max)
    hpBar:SetPoint("TOPLEFT", sheetFrame, "TOPLEFT", 32, y)

    local hpTxt = hpBar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hpTxt:SetPoint("CENTER"); hpTxt:SetTextColor(1, 1, 1, 0.9)
    hpTxt:SetText(db.hp.current .. " / " .. db.hp.max)

    local function RefHP()
        hpBar:SetMinMaxValues(0, db.hp.max)
        hpBar:SetValue(db.hp.current)
        hpTxt:SetText(db.hp.current .. " / " .. db.hp.max)
        ScheduleBroadcast()
    end

    local hpM = Btn(sheetFrame, 22, 24, "-")
    hpM:SetPoint("TOPLEFT", sheetFrame, "TOPLEFT", 10, y)
    hpM:SetScript("OnClick", function()
        db.hp.current = math.max(0, db.hp.current - 1); RefHP()
    end)

    local hpP = Btn(sheetFrame, 22, 24, "+")
    hpP:SetPoint("LEFT", hpBar, "RIGHT", 2, 0)
    hpP:SetScript("OnClick", function()
        db.hp.current = math.min(db.hp.max, db.hp.current + 1); RefHP()
    end)

    y = y - 28

    local mhEB = EB(sheetFrame, "RSMaxHP", 44, 18, 4)
    mhEB:SetPoint("TOPLEFT", sheetFrame, "TOPLEFT", 70, y)
    mhEB:SetText(tostring(db.hp.max))
    local mhLbl = Lbl(sheetFrame, "Max HP", nil, 0.28, 0.15, 0.04)
    mhLbl:SetPoint("RIGHT", mhEB, "LEFT", -8, 0)
    mhEB:SetScript("OnEditFocusLost", function(s)
        local v = tonumber(s:GetText())
        if v and v > 0 then
            db.hp.max = v; db.hp.current = math.min(db.hp.current, v); RefHP()
        else s:SetText(tostring(db.hp.max)) end
    end)

    y = y - 24; y = y - 10

    -- ── ARMOUR ─────────────────────────────────────────────────────
    Section(sheetFrame, "Armour", y); y = y - 20

    local acEB

    local atBtn = Btn(sheetFrame, 80, 22, ARM_ORDER[db.armour.typeIdx] or "Light")
    atBtn:SetPoint("TOPLEFT", sheetFrame, "TOPLEFT", 12, y)
    atBtn:SetScript("OnClick", function()
        db.armour.typeIdx = (db.armour.typeIdx % #ARM_ORDER) + 1
        local nt = ARM_ORDER[db.armour.typeIdx]
        atBtn:SetText(nt)
        db.armour.ac = ARM_AC_DEF[nt]
        acEB:SetText(tostring(db.armour.ac))
        ScheduleBroadcast()
    end)

    acEB = EB(sheetFrame, "RSAC", 40, 18, 3)
    acEB:SetPoint("TOPLEFT", sheetFrame, "TOPLEFT", 126, y)
    acEB:SetText(tostring(db.armour.ac))
    local acLbl = Lbl(sheetFrame, "AC", nil, 0.28, 0.15, 0.04)
    acLbl:SetPoint("RIGHT", acEB, "LEFT", -8, 0)
    acEB:SetScript("OnEditFocusLost", function(s)
        local v = tonumber(s:GetText())
        if v then db.armour.ac = v; ScheduleBroadcast()
        else s:SetText(tostring(db.armour.ac)) end
    end)

    y = y - 28; y = y - 10

    -- ── RESOURCES ──────────────────────────────────────────────────
    Section(sheetFrame, "Resources", y); y = y - 20

    for i, res in ipairs(db.resources) do
        local c = res.color
        local rBar   -- forward-declared so the color picker can update it

        if res.rtype == "Custom" then
            -- Clickable colour swatch for custom resources
            local swatch = CreateFrame("Button", nil, sheetFrame, "BackdropTemplate")
            swatch:SetSize(14, 14)
            swatch:SetPoint("TOPLEFT", sheetFrame, "TOPLEFT", 12, y - 1)

            local swTex = swatch:CreateTexture(nil, "ARTWORK")
            swTex:SetAllPoints()
            swTex:SetTexture("Interface/Buttons/WHITE8X8")
            swTex:SetVertexColor(c[1], c[2], c[3], 1)

            local swBorder = swatch:CreateTexture(nil, "OVERLAY")
            swBorder:SetPoint("TOPLEFT", -1, 1)
            swBorder:SetPoint("BOTTOMRIGHT", 1, -1)
            swBorder:SetTexture("Interface/Buttons/WHITE8X8")
            swBorder:SetVertexColor(0.25, 0.18, 0.10, 1)
            swBorder:SetDrawLayer("OVERLAY", -1)

            do
                local idx = i
                swatch:SetScript("OnClick", function()
                    local cur = db.resources[idx].color
                    local info = {
                        r = cur[1], g = cur[2], b = cur[3],
                        swatchFunc = function()
                            local r, g, b = ColorPickerFrame:GetColorRGB()
                            db.resources[idx].color = {r, g, b}
                            swTex:SetVertexColor(r, g, b, 1)
                            if rBar then rBar:SetStatusBarColor(r, g, b) end
                            ScheduleBroadcast()
                        end,
                        cancelFunc = function(prev)
                            db.resources[idx].color = {prev.r, prev.g, prev.b}
                            swTex:SetVertexColor(prev.r, prev.g, prev.b, 1)
                            if rBar then rBar:SetStatusBarColor(prev.r, prev.g, prev.b) end
                        end,
                    }
                    ColorPickerFrame:SetupColorPickerAndShow(info)
                end)
                swatch:SetScript("OnEnter", function(self)
                    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                    GameTooltip:AddLine("Click to pick a colour")
                    GameTooltip:Show()
                end)
                swatch:SetScript("OnLeave", GameTooltip_Hide)
            end

            local cnEB = EB(sheetFrame, "RSCRes" .. i, 96, 16, 28)
            cnEB:SetPoint("LEFT", swatch, "RIGHT", 5, 0)
            cnEB:SetText(res.custom)
            cnEB:SetScript("OnEditFocusLost", function(s)
                db.resources[i].custom = s:GetText()
                ScheduleBroadcast()
            end)
        else
            local pip = sheetFrame:CreateTexture(nil, "ARTWORK")
            pip:SetSize(7, 7)
            pip:SetTexture("Interface/Buttons/WHITE8X8")
            pip:SetVertexColor(c[1], c[2], c[3], 0.9)
            pip:SetPoint("TOPLEFT", sheetFrame, "TOPLEFT", 12, y - 5)

            local rl = Lbl(sheetFrame, res.rtype, "GameFontHighlightSmall", 0.28, 0.15, 0.04)
            rl:SetPoint("LEFT", pip, "RIGHT", 5, 0)
            rl:SetWidth(105)
            rl:SetJustifyH("LEFT")
        end

        local xBtn = Btn(sheetFrame, 18, 18, "X")
        xBtn:SetPoint("TOPRIGHT", sheetFrame, "TOPRIGHT", -12, y)
        do
            local idx = i
            xBtn:SetScript("OnClick", function()
                table.remove(db.resources, idx)
                local shown = sheetFrame:IsShown()
                BuildSheet(); if shown then sheetFrame:Show() end
            end)
        end

        local rmxEB = EB(sheetFrame, "RSResMax" .. i, 36, 16, 5)
        rmxEB:SetPoint("RIGHT", xBtn, "LEFT", -8, 0)
        rmxEB:SetText(tostring(res.max))
        local maxLbl = Lbl(sheetFrame, "Max", nil, 0.28, 0.15, 0.04)
        maxLbl:SetPoint("RIGHT", rmxEB, "LEFT", -8, 0)

        y = y - 18

        rBar = Bar(sheetFrame, barW, 20, c[1], c[2], c[3], res.current, res.max)
        rBar:SetPoint("TOPLEFT", sheetFrame, "TOPLEFT", 32, y)

        local rTxt = rBar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        rTxt:SetPoint("CENTER"); rTxt:SetTextColor(1, 1, 1, 0.9)
        rTxt:SetText(res.current .. " / " .. res.max)

        do
            local idx = i

            local function RefRes()
                rBar:SetMinMaxValues(0, db.resources[idx].max)
                rBar:SetValue(db.resources[idx].current)
                rTxt:SetText(db.resources[idx].current .. " / " .. db.resources[idx].max)
                ScheduleBroadcast()
            end

            rmxEB:SetScript("OnEditFocusLost", function(s)
                local v = tonumber(s:GetText())
                if v and v > 0 then
                    db.resources[idx].max = v
                    db.resources[idx].current = math.min(db.resources[idx].current, v)
                    RefRes()
                else s:SetText(tostring(db.resources[idx].max)) end
            end)

            local rM = Btn(sheetFrame, 22, 22, "-")
            rM:SetPoint("TOPLEFT", sheetFrame, "TOPLEFT", 10, y)
            rM:SetScript("OnClick", function()
                db.resources[idx].current = math.max(0, db.resources[idx].current - 1)
                RefRes()
            end)

            local rP = Btn(sheetFrame, 22, 22, "+")
            rP:SetPoint("LEFT", rBar, "RIGHT", 2, 0)
            rP:SetScript("OnClick", function()
                db.resources[idx].current = math.min(
                    db.resources[idx].max, db.resources[idx].current + 1)
                RefRes()
            end)
        end

        y = y - 26
    end

    local rTypeIdx = 1
    local rTypBtn  = Btn(sheetFrame, 92, 20, RES_TYPES[rTypeIdx])
    rTypBtn:SetPoint("TOPLEFT", sheetFrame, "TOPLEFT", 12, y)
    rTypBtn:SetScript("OnClick", function()
        rTypeIdx = (rTypeIdx % #RES_TYPES) + 1
        rTypBtn:SetText(RES_TYPES[rTypeIdx])
    end)

    local rAdd = Btn(sheetFrame, 46, 20, "+ Add")
    rAdd:SetPoint("LEFT", rTypBtn, "RIGHT", 4, 0)
    rAdd:SetScript("OnClick", function()
        local rt  = RES_TYPES[rTypeIdx]
        local col = RES_COL[rt] or {0.75, 0.75, 0.75}
        table.insert(db.resources, {
            rtype=rt, custom="", current=100, max=100,
            color={ col[1], col[2], col[3] }
        })
        local shown = sheetFrame:IsShown()
        BuildSheet(); if shown then sheetFrame:Show() end
    end)

    y = y - 26; y = y - 10

    -- ── ROLLS ──────────────────────────────────────────────────────
    -- Each row: [pin] d[sides] [+mod] [name] [Roll] [X]
    -- The pin button cycles: not pinned → bar slot 1 → slot 2 → off.
    Section(sheetFrame, "Rolls", y); y = y - 18

    -- Fixed columns.  InputBoxTemplate draws its border ~6px outside
    -- the frame on each side, so boxes need a 12px+ gap between them.
    local COL_PIN, COL_D, COL_SIDES, COL_MOD, COL_NAME = 10, 42, 58, 104, 150
    local hdr = { {"Pin", COL_PIN + 2}, {"Die", COL_SIDES - 2}, {"Mod", COL_MOD - 2}, {"Name", COL_NAME - 2} }
    for _, h in ipairs(hdr) do
        Lbl(sheetFrame, h[1], "GameFontDisableSmall", 0.28, 0.15, 0.04)
            :SetPoint("TOPLEFT", sheetFrame, "TOPLEFT", h[2], y)
    end
    y = y - 14

    local function Rebuild()
        local shown = sheetFrame:IsShown()
        BuildSheet(); if shown then sheetFrame:Show() end
        RefreshBar(); ScheduleBroadcast()
    end

    for i, atk in ipairs(db.attacks) do
        local idx = i

        -- Pin toggle
        local pinBtn = Btn(sheetFrame, 24, 22, PinLabel(atk.id))
        pinBtn:SetPoint("TOPLEFT", sheetFrame, "TOPLEFT", COL_PIN, y)
        pinBtn:SetScript("OnClick", function(self)
            if not db.attacks[idx] then return end
            local id = db.attacks[idx].id
            local cur = (db.pins[1] == id and 1) or (db.pins[2] == id and 2) or 0
            if cur > 0 then db.pins[cur] = nil end
            local nxt = (cur + 1) % 3                       -- 0 → 1 → 2 → 0
            if nxt > 0 then db.pins[nxt] = id end
            Rebuild()
        end)
        pinBtn:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_LEFT")
            GameTooltip:AddLine("Pin to bar")
            GameTooltip:AddLine("Click to cycle: slot 1, slot 2, not pinned.", 1, 1, 1, true)
            GameTooltip:Show()
        end)
        pinBtn:SetScript("OnLeave", GameTooltip_Hide)

        -- Die size
        local dLbl = Lbl(sheetFrame, "d", "GameFontNormal", 0.28, 0.15, 0.04)
        dLbl:SetPoint("TOPLEFT", sheetFrame, "TOPLEFT", COL_D, y - 4)
        local sideEB = EB(sheetFrame, "RSRollSides" .. i, 34, 22, 4)
        sideEB:SetPoint("TOPLEFT", sheetFrame, "TOPLEFT", COL_SIDES, y)
        sideEB:SetNumeric(true)
        sideEB:SetText(tostring(atk.sides or 20))
        sideEB:SetScript("OnEditFocusLost", function(s)
            if not db.attacks[idx] then return end
            local v = tonumber(s:GetText())
            if v and v >= 2 and v <= MAX_SIDES then
                db.attacks[idx].sides = v; RefreshBar(); ScheduleBroadcast()
            else s:SetText(tostring(db.attacks[idx].sides or 20)) end
        end)

        -- Modifier
        local bonusEB = EB(sheetFrame, "RSAtkBonus" .. i, 34, 22, 4)
        bonusEB:SetPoint("TOPLEFT", sheetFrame, "TOPLEFT", COL_MOD, y)
        bonusEB:SetText(tostring(atk.bonus))
        bonusEB:SetScript("OnEditFocusLost", function(s)
            if not db.attacks[idx] then return end
            local v = tonumber(s:GetText())
            if v and v >= -MAX_MOD and v <= MAX_MOD then
                db.attacks[idx].bonus = v; RefreshBar(); ScheduleBroadcast()
            else s:SetText(tostring(db.attacks[idx].bonus)) end
        end)

        -- Remove
        local xBtn = Btn(sheetFrame, 18, 18, "X")
        xBtn:SetPoint("TOPRIGHT", sheetFrame, "TOPRIGHT", -10, y - 2)
        xBtn:SetScript("OnClick", function()
            if not db.attacks[idx] then return end
            local id = db.attacks[idx].id
            if db.pins[1] == id then db.pins[1] = nil end
            if db.pins[2] == id then db.pins[2] = nil end
            table.remove(db.attacks, idx)
            Rebuild()
        end)

        -- Roll
        local arBtn = Btn(sheetFrame, 46, 22, "Roll")
        arBtn:SetPoint("RIGHT", xBtn, "LEFT", -4, 0)
        arBtn:SetScript("OnClick", function()
            local a = db.attacks[idx]
            if not a then return end
            a.bonus = tonumber(bonusEB:GetText()) or a.bonus
            a.sides = tonumber(sideEB:GetText()) or a.sides
            RollDie(a.sides or 20, a.bonus, a.name)
        end)

        -- Name (fills the space between modifier and Roll)
        local anEB = EB(sheetFrame, "RSAtkName" .. i, 10, 22, 40)
        anEB:SetPoint("TOPLEFT", sheetFrame, "TOPLEFT", COL_NAME, y)
        anEB:SetPoint("RIGHT", arBtn, "LEFT", -10, 0)
        anEB:SetText(atk.name)
        anEB:SetScript("OnEditFocusLost", function(s)
            if not db.attacks[idx] then return end
            db.attacks[idx].name = s:GetText()
            RefreshBar(); ScheduleBroadcast()
        end)

        y = y - 26
    end

    if #db.attacks < 12 then
        local addBtn = Btn(sheetFrame, 90, 22, "+ Add Roll")
        addBtn:SetPoint("TOPLEFT", sheetFrame, "TOPLEFT", 10, y)
        addBtn:SetScript("OnClick", function()
            table.insert(db.attacks, { id = db.nextRollId, name = "New Roll", bonus = 0, sides = 20 })
            db.nextRollId = db.nextRollId + 1
            Rebuild()
        end)
        y = y - 26
    end

    y = y - 10
    sheetFrame:SetHeight(math.abs(y) + 12)
    sheetFrame:Hide()   -- never auto-open on login; user opens via toolbar
end

-- ================================================================
--  Main frame  (the bar)
-- ================================================================
--  [ RollSheet ][ d20 ][ d100 ][ Custom ][ Pin 1 ][ Pin 2 ][⚙/v]
--
--  Left-click any slot rolls it.  Right-click Custom to change the
--  die, right-click a pinned slot to choose which roll lives there.

local function ShowMenu(owner, build)
    if MenuUtil and MenuUtil.CreateContextMenu then
        local ok = pcall(MenuUtil.CreateContextMenu, owner, build)
        if ok then return end
    end
    print("|cffaa8844RollSheet|r Menus aren't available on this client. Use the sheet to change rolls.")
end

-- One slot: an invisible button over a painted tile, carrying the
-- live text (label, modifier) and, for pin slots, the roll's icon.
local function RollSlot(parent, key)
    local b = CreateFrame("Button", nil, parent)
    PlaceOnArt(b, parent, ART.tile[key])
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    local w, h = b:GetSize()

    -- Tiles are icon-sized, so like an action bar they carry only an
    -- icon and corner numbers; names live in the tooltip.
    b.icon = b:CreateTexture(nil, "ARTWORK")
    local inner = ART.pinInner[key]
    if inner then
        -- Fill the tile's inside edge to edge; crop the square icon to
        -- the tile's proportions instead of stretching it.
        local k, t = ART.scale, ART.tile[key]
        b.icon:SetPoint("TOPLEFT", (inner[1] - t[1]) * k, -(inner[2] - t[2]) * k)
        b.icon:SetSize(inner[3] * k, inner[4] * k)
        local span = 0.86 * inner[4] / inner[3]          -- visible height for this width
        local pad  = (1 - span) / 2
        b.icon:SetTexCoord(0.07, 0.93, pad, 1 - pad)
    end
    b.icon:Hide()

    b.die = b:CreateFontString(nil, "OVERLAY", "NumberFontNormal")      -- bottom-left: "d6"
    b.die:SetPoint("BOTTOMLEFT", w * 0.12, h * 0.12)

    b.mod = b:CreateFontString(nil, "OVERLAY", "NumberFontNormal")      -- top-right: "+3"
    b.mod:SetPoint("TOPRIGHT", -w * 0.12, -h * 0.12)

    b.empty = b:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")  -- empty pin slot
    b.empty:SetPoint("CENTER")
    b.empty:SetText("+")
    b.empty:SetTextColor(0.75, 0.62, 0.35, 0.6)
    b.empty:Hide()

    -- warm glow on hover, darken while pressed
    b:SetHighlightTexture(ART.highlight, "ADD")
    local hl = b:GetHighlightTexture()
    hl:ClearAllPoints()
    hl:SetPoint("TOPLEFT", w * 0.08, -h * 0.08); hl:SetPoint("BOTTOMRIGHT", -w * 0.08, h * 0.08)
    hl:SetVertexColor(1.0, 0.75, 0.35, 0.55)

    b.press = b:CreateTexture(nil, "OVERLAY", nil, 7)
    b.press:SetPoint("TOPLEFT", w * 0.08, -h * 0.08); b.press:SetPoint("BOTTOMRIGHT", -w * 0.08, h * 0.08)
    b.press:SetColorTexture(0, 0, 0, 0.35)
    b.press:Hide()
    b:SetScript("OnMouseDown", function(self) self.press:Show() end)
    b:SetScript("OnMouseUp",   function(self) self.press:Hide() end)
    b:SetScript("OnHide",      function(self) self.press:Hide() end)
    b:SetScript("OnLeave", GameTooltip_Hide)
    return b
end

-- Gear and chevron: invisible buttons over the painted ones.
local function SmallButton(parent, rect)
    local b = CreateFrame("Button", nil, parent)
    PlaceOnArt(b, parent, rect)
    b:SetHighlightTexture(ART.highlight, "ADD")
    b:GetHighlightTexture():SetVertexColor(1.0, 0.75, 0.35, 0.55)
    b:SetScript("OnLeave", GameTooltip_Hide)
    return b
end

local function ToggleSheet()
    if not sheetFrame then
        local ok, err = pcall(BuildSheet)
        if not ok then
            print("|cffff4444RollSheet|r BuildSheet error: " .. tostring(err))
            return
        end
    end
    if sheetFrame:IsShown() then
        sheetFrame:Hide(); RollSheetDB.sheetOpen = false
    else
        sheetFrame:Show(); RollSheetDB.sheetOpen = true
    end
    if RefreshBar then RefreshBar() end
end

-- Custom die: a one-line prompt that understands "d6+2 Fireball"
local function ApplyCustomSpec(text)
    local sd, md, label = ParseRollSpec(text)
    if not sd or sd < 2 or sd > MAX_SIDES or md < -MAX_MOD or md > MAX_MOD then
        print("|cffaa8844RollSheet|r Couldn't read that. Try something like d6, d12+2 or d8-1 Dagger strike.")
        return
    end
    RollSheetDB.custom = { sides = sd, mod = md, label = label or "" }
    RefreshBar()
end

StaticPopupDialogs["ROLLSHEET_CUSTOM_DIE"] = {
    text = "Custom die\n\nType a die, an optional modifier and an optional name:\n|cffaaaaaad6     d12+2     d8-1 Dagger strike|r",
    button1 = ACCEPT or "Accept",
    button2 = CANCEL or "Cancel",
    hasEditBox = true,
    maxLetters = 40,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    OnShow = function(self)
        local eb = (self.GetEditBox and self:GetEditBox()) or self.EditBox or self.editBox
        local c = RollSheetDB.custom
        if eb then
            eb:SetText("d" .. c.sides .. ModText(c.mod) .. ((c.label ~= "" and (" " .. c.label)) or ""))
            eb:HighlightText()
        end
    end,
    OnAccept = function(self)
        local eb = (self.GetEditBox and self:GetEditBox()) or self.EditBox or self.editBox
        if eb then ApplyCustomSpec(eb:GetText()) end
    end,
    EditBoxOnEnterPressed = function(self)
        ApplyCustomSpec(self:GetText())
        StaticPopup_Hide("ROLLSHEET_CUSTOM_DIE")
    end,
    EditBoxOnEscapePressed = function() StaticPopup_Hide("ROLLSHEET_CUSTOM_DIE") end,
}

local slots = {}

-- ── Pin icons ─────────────────────────────────────────────────────
-- Icons belong to the roll, so they follow it to whichever slot it's
-- pinned in.  Stored as an icon file ID (number) or a texture path.

local iconTargetId   -- roll waiting for a typed icon

-- Icon of whatever is on the cursor: spell, item, macro or mount.
local function CursorIcon()
    local ok, icon = pcall(function()
        local kind, a, b, c = GetCursorInfo()
        if kind == "spell" then
            local id = c or a
            if C_Spell and C_Spell.GetSpellTexture then return (C_Spell.GetSpellTexture(id)) end
            return GetSpellTexture and GetSpellTexture(id)
        elseif kind == "item" then
            if C_Item and C_Item.GetItemIconByID then return C_Item.GetItemIconByID(a) end
            return GetItemIcon and GetItemIcon(a)
        elseif kind == "macro" then
            local _, tex = GetMacroInfo(a)
            return tex
        elseif kind == "mount" then
            local _, _, tex = C_MountJournal.GetMountInfoByID(a)
            return tex
        end
    end)
    return ok and icon or nil
end

-- Picking something up from an action bar empties that slot.  We
-- remember which slot it came from so we can put it back after
-- borrowing its icon, instead of throwing the spell away.
local pickedFromSlot
local slotWatch = CreateFrame("Frame")
slotWatch:RegisterEvent("ACTIONBAR_SLOT_CHANGED")
slotWatch:RegisterEvent("CURSOR_CHANGED")
slotWatch:SetScript("OnEvent", function(_, event, slot)
    if event == "ACTIONBAR_SLOT_CHANGED" then
        if type(slot) == "number" and GetCursorInfo() and not HasAction(slot) then
            pickedFromSlot = slot
        end
    elseif not GetCursorInfo() then
        pickedFromSlot = nil                 -- cursor emptied: nothing to give back
    end
end)

-- Returns whatever is on the cursor to where it came from.
local function ReturnCursor()
    local slot = pickedFromSlot
    pickedFromSlot = nil
    if slot and not HasAction(slot) then
        if InCombatLockdown() then
            print("|cffaa8844RollSheet|r Icon set. You're in combat, so drop the spell back on your bar yourself.")
            return                            -- leave it on the cursor
        end
        local ok = pcall(PlaceAction, slot)
        if ok and not GetCursorInfo() then return end
    end
    ClearCursor()                             -- spellbook, bags, macros: nothing is lost
end

local function DropIconOnSlot(n)
    if not GetCursorInfo() then return end
    local roll = GetRollById(RollSheetDB.pins[n])
    if not roll then
        print("|cffaa8844RollSheet|r Pin a roll to this slot first, then drop an icon on it.")
        ReturnCursor(); return
    end
    local icon = CursorIcon()
    ReturnCursor()
    if icon then
        roll.icon = icon
        RefreshBar()
    else
        print("|cffaa8844RollSheet|r That can't be used as an icon. Try a spell, item, macro or mount.")
    end
end

local PickerRefresh   -- defined with the icon picker below

-- Typed icon: a name like "inv_sword_04" or a numeric icon ID
local function ApplyTypedIcon(text)
    local roll = GetRollById(iconTargetId)
    text = strtrim(text or "")
    if not roll or text == "" then return end
    local id = tonumber(text)
    if not id then
        local name = text:gsub("^[Ii]nterface[/\\][Ii]cons[/\\]", ""):gsub("%.%a+$", "")
        local path = "Interface\\Icons\\" .. name
        if not GetFileIDFromPath then           -- can't verify on this client: trust the name
            roll.icon = path; RefreshBar(); PickerRefresh(); return
        end
        local ok, fid = pcall(GetFileIDFromPath, path)
        if not ok or not fid then
            print("|cffaa8844RollSheet|r Couldn't find an icon called \"" .. name .. "\".")
            return
        end
        id = fid
    end
    roll.icon = id
    RefreshBar(); PickerRefresh()
end

-- ── Icon picker ───────────────────────────────────────────────────
-- A scrollable grid of icons.  "Your spells" shows what's on your
-- action bars and in your spellbook; "All icons" shows every icon the
-- game offers for macros.  Clicking an icon applies it immediately.

local picker
local P_COLS, P_ROWS, P_CELL = 10, 7, 38
local allIcons

local function IconPath(v)
    if type(v) == "string" and not v:find("[/\\]") then return "Interface\\Icons\\" .. v end
    return v
end

local function AllIcons()
    if allIcons then return allIcons end
    local raw, seen, out = {}, {}, {}
    for _, fn in ipairs({ "GetLooseMacroIcons", "GetLooseMacroItemIcons", "GetMacroIcons", "GetMacroItemIcons" }) do
        if _G[fn] then pcall(_G[fn], raw) end
    end
    for _, v in ipairs(raw) do
        if v and not seen[v] then seen[v] = true; out[#out + 1] = v end
    end
    allIcons = out
    return out
end

local function YourIcons()
    local seen, out = {}, {}
    local function add(tex) if tex and not seen[tex] then seen[tex] = true; out[#out + 1] = tex end end
    for slot = 1, 180 do
        local ok, tex = pcall(GetActionTexture, slot)
        if ok then add(tex) end
    end
    pcall(function()                         -- spellbook (11.0+ API)
        local bank = Enum.SpellBookSpellBank.Player
        for line = 1, C_SpellBook.GetNumSpellBookSkillLines() do
            local info = C_SpellBook.GetSpellBookSkillLineInfo(line)
            for i = info.itemIndexOffset + 1, info.itemIndexOffset + info.numSpellBookItems do
                add(C_SpellBook.GetSpellBookItemTexture(i, bank))
            end
        end
    end)
    return out
end

-- ── Icon search ───────────────────────────────────────────────────
-- WoW only gives addons icon numbers, not names, so the names come
-- from a separate load-on-demand module (RollSheet_IconNames) built
-- from the community listfile.  It's loaded the first time someone
-- searches, so players who never search never pay the memory cost.

local iconNames        -- { ids = {...}, names = {...}, byId = {...} }
local iconNamesFailed

local function LoadIconNames()
    if iconNames then return iconNames end
    if iconNamesFailed then return nil end
    if not RollSheet_IconNameData then
        local load = (C_AddOns and C_AddOns.LoadAddOn) or LoadAddOn
        if load then pcall(load, "RollSheet_IconNames") end
    end
    local raw = RollSheet_IconNameData
    if type(raw) ~= "string" then iconNamesFailed = true; return nil end
    local ids, names, byId = {}, {}, {}
    for id, name in raw:gmatch("(%d+) ([^\n]+)") do
        id = tonumber(id)
        ids[#ids + 1], names[#names + 1], byId[id] = id, name, name
    end
    RollSheet_IconNameData = nil             -- parsed: free the big string
    iconNames = { ids = ids, names = names, byId = byId }
    return iconNames
end

-- Every word must match.  Short words (3 letters or less) must start
-- a word in the name, so "red" finds "..._red" and "redflower" but
-- not "sacred".  Longer words may also match inside a word, so
-- "bolt" finds "shadowbolt".  Exact word matches rank first.
local validIconSet
local function SearchIcons(query)
    local data = LoadIconNames()
    if not data then return nil end
    local words = {}
    for w in query:lower():gmatch("%w+") do words[#words + 1] = w end
    if #words == 0 then return nil end

    -- Only offer icons this client can actually show (the listfile
    -- also names icons for unreleased content).
    if not validIconSet then
        local all = AllIcons()
        if #all >= 1000 then
            validIconSet = {}
            for _, v in ipairs(all) do validIconSet[v] = true end
        else
            validIconSet = false
        end
    end

    -- Prepare once: keep only showable icons, pre-pad names for word matching
    if not data.padded then
        local ids, names, padded = {}, {}, {}
        for i, name in ipairs(data.names) do
            local id = data.ids[i]
            if not validIconSet or validIconSet[id] then
                ids[#ids + 1], names[#names + 1], padded[#padded + 1] = id, name, "_" .. name .. "_"
            end
        end
        data.ids, data.names, data.padded = ids, names, padded
    end

    local hits = {}
    local padded, names, ids = data.padded, data.names, data.ids
    for i = 1, #padded do
        local u, name, id = padded[i], names[i], ids[i]
        do
            local score, ok = 0, true
            for _, w in ipairs(words) do
                if u:find("_" .. w .. "_", 1, true) then
                    -- exact word: best
                elseif u:find("_" .. w, 1, true) or u:find("%d" .. w) then
                    score = score + 1                     -- start of a word
                elseif #w >= 4 and name:find(w, 1, true) then
                    score = score + 2                     -- inside a word
                else
                    ok = false; break
                end
            end
            if ok then hits[#hits + 1] = { id = id, name = name, score = score } end
        end
    end
    table.sort(hits, function(a, b)
        if a.score ~= b.score then return a.score < b.score end
        return a.name < b.name
    end)
    local out = {}
    for i, h in ipairs(hits) do out[i] = h.id end
    return out
end

PickerRefresh = function()
    if not picker then return end
    local list = picker.list
    local rows = math.ceil(#list / P_COLS)
    local maxOff = math.max(0, rows - P_ROWS)
    picker.offset = math.min(math.max(picker.offset, 0), maxOff)
    picker.maxOff = maxOff
    local roll = GetRollById(iconTargetId)
    for i, cell in ipairs(picker.cells) do
        local icon = list[picker.offset * P_COLS + i]
        cell.icon = icon
        if icon then
            cell.tex:SetTexture(IconPath(icon))
            cell.sel:SetShown(roll ~= nil and roll.icon == icon)
            cell:Show()
        else
            cell:Hide()
        end
    end
    local track = picker.track
    local th = track:GetHeight()
    local thumbH = (maxOff > 0) and math.max(24, th * P_ROWS / rows) or th
    picker.thumb:SetHeight(thumbH)
    local y = (maxOff > 0) and (th - thumbH) * picker.offset / maxOff or 0
    picker.thumb:ClearAllPoints()
    picker.thumb:SetPoint("TOP", track, "TOP", 0, -y)
    if picker.tab == "search" then
        picker.count:SetText(#list == 1 and "1 match" or (#list .. " matches"))
    else
        picker.count:SetText(#list .. " icons")
    end
    if roll then picker.title:SetText("Icon for: " .. roll.name) end
    picker.tabYours:SetAlpha(picker.tab == "yours" and 1 or 0.6)
    picker.tabAll:SetAlpha(picker.tab == "all" and 1 or 0.6)
end

local function PickerSetTab(tab)
    if picker.search and picker.search:GetText() ~= "" then
        picker.searching = true; picker.search:SetText(""); picker.searching = false
    end
    picker.tab = tab
    picker.list = (tab == "all") and AllIcons() or YourIcons()
    picker.offset = 0
    PickerRefresh()
end

local function BuildPicker()
    local W = P_COLS * P_CELL + 52
    local H = P_ROWS * P_CELL + 118
    picker = CreateFrame("Frame", "RollSheetIconPicker", UIParent, "BackdropTemplate")
    picker:SetSize(W, H)
    picker:SetPoint("CENTER")
    picker:SetFrameStrata("DIALOG")
    picker:SetMovable(true); picker:EnableMouse(true); picker:SetClampedToScreen(true)
    picker:RegisterForDrag("LeftButton")
    picker:SetScript("OnDragStart", picker.StartMoving)
    picker:SetScript("OnDragStop", picker.StopMovingOrSizing)
    ApplyBG(picker)
    table.insert(UISpecialFrames, "RollSheetIconPicker")   -- Escape closes it

    picker.title = Lbl(picker, "Icon", "GameFontNormalLarge", 0.28, 0.15, 0.04)
    picker.title:SetPoint("TOPLEFT", 16, -14)
    picker.title:SetWidth(W - 150); picker.title:SetJustifyH("LEFT"); picker.title:SetWordWrap(false)

    local close = Btn(picker, 22, 22, "X")
    close:SetPoint("TOPRIGHT", -10, -10)
    close:SetScript("OnClick", function() picker:Hide() end)

    picker.tabYours = Btn(picker, 110, 22, "Your spells")
    picker.tabYours:SetPoint("TOPLEFT", 14, -40)
    picker.tabYours:SetScript("OnClick", function() PickerSetTab("yours") end)
    picker.tabAll = Btn(picker, 90, 22, "All icons")
    picker.tabAll:SetPoint("LEFT", picker.tabYours, "RIGHT", 6, 0)
    picker.tabAll:SetScript("OnClick", function() PickerSetTab("all") end)
    picker.count = Lbl(picker, "", "GameFontDisableSmall", 0.28, 0.15, 0.04)
    picker.count:SetPoint("RIGHT", close, "LEFT", -8, 0)

    -- Search box: words like "red", "sword", "shadow bolt"
    local search = EB(picker, "RollSheetIconSearch", 150, 22, 40)
    search:SetPoint("TOPRIGHT", -16, -40)
    picker.search = search
    local hint = search:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    hint:SetPoint("LEFT", 2, 0)
    hint:SetText("Search: red, sword...")
    local pending
    local function RunSearch()
        pending = nil
        local q = strtrim(search:GetText() or "")
        if q == "" then PickerSetTab("yours"); return end
        local found = SearchIcons(q)
        if not found then
            print("|cffaa8844RollSheet|r Icon search needs the \"RollSheet Icon Names\" module. Make sure it's enabled in your AddOns list.")
            return
        end
        picker.tab, picker.list, picker.offset = "search", found, 0
        PickerRefresh()
    end
    search:SetScript("OnTextChanged", function(self)
        hint:SetShown(self:GetText() == "")
        if picker.searching then return end
        if pending then pending:Cancel() end
        pending = C_Timer.NewTimer(0.25, RunSearch)          -- wait until typing pauses
    end)
    search:SetScript("OnEscapePressed", function(self)
        if self:GetText() ~= "" then self:SetText("") else self:ClearFocus() end
    end)

    -- Grid of icon cells (re-used while scrolling)
    local grid = CreateFrame("Frame", nil, picker)
    grid:SetPoint("TOPLEFT", 16, -70)
    grid:SetSize(P_COLS * P_CELL, P_ROWS * P_CELL)
    picker.cells = {}
    for r = 0, P_ROWS - 1 do
        for c = 0, P_COLS - 1 do
            local cell = CreateFrame("Button", nil, grid)
            cell:SetSize(P_CELL - 4, P_CELL - 4)
            cell:SetPoint("TOPLEFT", c * P_CELL, -r * P_CELL)
            cell.tex = cell:CreateTexture(nil, "ARTWORK")
            cell.tex:SetAllPoints()
            cell.tex:SetTexCoord(0.07, 0.93, 0.07, 0.93)
            cell.sel = cell:CreateTexture(nil, "OVERLAY")
            cell.sel:SetPoint("TOPLEFT", -3, 3); cell.sel:SetPoint("BOTTOMRIGHT", 3, -3)
            cell.sel:SetTexture("Interface/Buttons/CheckButtonHilight")
            cell.sel:SetBlendMode("ADD")
            cell.sel:Hide()
            cell:SetHighlightTexture(ART.highlight, "ADD")
            cell:SetScript("OnEnter", function(self)
                if not self.icon then return end
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                local nm = iconNames and iconNames.byId[self.icon]
                GameTooltip:AddLine(nm or ("Icon " .. tostring(self.icon)), 1, 1, 1)
                GameTooltip:Show()
            end)
            cell:SetScript("OnLeave", GameTooltip_Hide)
            cell:SetScript("OnClick", function(self)
                local roll = GetRollById(iconTargetId)
                if roll and self.icon then
                    roll.icon = self.icon
                    RefreshBar(); PickerRefresh()
                end
            end)
            picker.cells[#picker.cells + 1] = cell
        end
    end

    -- Scrollbar: click or drag anywhere on the track
    local track = CreateFrame("Frame", nil, picker)
    track:SetPoint("TOPLEFT", grid, "TOPRIGHT", 8, 0)
    track:SetSize(10, P_ROWS * P_CELL - 4)
    local tbg = track:CreateTexture(nil, "BACKGROUND")
    tbg:SetAllPoints(); tbg:SetColorTexture(0.20, 0.13, 0.06, 0.55)
    picker.thumb = track:CreateTexture(nil, "ARTWORK")
    picker.thumb:SetWidth(10)
    picker.thumb:SetColorTexture(0.80, 0.62, 0.25, 0.95)
    picker.track = track
    track:EnableMouse(true)
    track:SetScript("OnMouseDown", function(self) self.dragging = true end)
    track:SetScript("OnMouseUp", function(self) self.dragging = false end)
    track:SetScript("OnUpdate", function(self)
        if not self.dragging or (picker.maxOff or 0) == 0 then return end
        if not IsMouseButtonDown("LeftButton") then self.dragging = false; return end
        local _, cy = GetCursorPosition()
        cy = cy / self:GetEffectiveScale()
        local frac = (self:GetTop() - cy) / self:GetHeight()
        local off = math.floor(math.min(math.max(frac, 0), 1) * picker.maxOff + 0.5)
        if off ~= picker.offset then picker.offset = off; PickerRefresh() end
    end)

    picker:EnableMouseWheel(true)
    picker:SetScript("OnMouseWheel", function(_, delta)
        picker.offset = picker.offset - delta * 2
        PickerRefresh()
    end)

    -- Footer
    local typed = Btn(picker, 130, 22, "Type name or ID")
    typed:SetPoint("BOTTOMLEFT", 14, 12)
    typed:SetScript("OnClick", function() StaticPopup_Show("ROLLSHEET_ICON") end)
    local reset = Btn(picker, 100, 22, "Default icon")
    reset:SetPoint("LEFT", typed, "RIGHT", 6, 0)
    reset:SetScript("OnClick", function()
        local roll = GetRollById(iconTargetId)
        if roll then roll.icon = nil; RefreshBar(); PickerRefresh() end
    end)
    local done = Btn(picker, 70, 22, "Done")
    done:SetPoint("BOTTOMRIGHT", -14, 12)
    done:SetScript("OnClick", function() picker:Hide() end)

    picker.offset, picker.list, picker.tab = 0, {}, "yours"
    picker:Hide()
end

local function OpenIconPicker(rollId)
    if not picker then BuildPicker() end
    iconTargetId = rollId
    picker:Show()
    PickerSetTab("yours")
    picker.search:SetFocus()
    if #picker.list == 0 then PickerSetTab("all") end
end

StaticPopupDialogs["ROLLSHEET_ICON"] = {
    text = "Type an icon name or ID\n|cffaaaaaae.g. inv_sword_04 (Wowhead shows these names)|r",
    button1 = ACCEPT or "Accept",
    button2 = CANCEL or "Cancel",
    hasEditBox = true,
    maxLetters = 80,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    OnAccept = function(self)
        local eb = (self.GetEditBox and self:GetEditBox()) or self.EditBox or self.editBox
        if eb then ApplyTypedIcon(eb:GetText()) end
    end,
    EditBoxOnEnterPressed = function(self)
        ApplyTypedIcon(self:GetText())
        StaticPopup_Hide("ROLLSHEET_ICON")
    end,
    EditBoxOnEscapePressed = function() StaticPopup_Hide("ROLLSHEET_ICON") end,
}

-- Position is stored in screen pixels from the screen centre, so the
-- bar stays put when its size changes.
local function SaveBarPosition()
    if not mainFrame then return end
    local x, y = mainFrame:GetCenter()
    if not x then return end
    local e = mainFrame:GetEffectiveScale()
    local ux, uy = UIParent:GetCenter()
    local u = UIParent:GetEffectiveScale()
    RollSheetDB.pos = { x = x * e - ux * u, y = y * e - uy * u }
end

local BAR_SIZES = { { 0.8, "Small" }, { 1.0, "Normal" }, { 1.2, "Large" }, { 1.4, "Extra large" } }

local function ApplyBarScale()
    if not mainFrame then return end
    local db = RollSheetDB
    mainFrame:SetScale(db.barScale or 1.0)
    mainFrame:ClearAllPoints()
    if db.pos then
        local e = mainFrame:GetEffectiveScale()
        mainFrame:SetPoint("CENTER", UIParent, "CENTER", db.pos.x / e, db.pos.y / e)
    else
        mainFrame:SetPoint("CENTER")
    end
end

local function BuildMain()
    local db = RollSheetDB
    mainFrame = CreateFrame("Frame", "RollSheetMain", UIParent, "BackdropTemplate")
    mainFrame:SetSize(ART.body[3] * ART.scale, ART.body[4] * ART.scale)
    mainFrame:SetPoint("CENTER")
    mainFrame:SetMovable(true); mainFrame:EnableMouse(true)
    mainFrame:SetClampedToScreen(true)
    mainFrame:RegisterForDrag("LeftButton")
    mainFrame:SetScript("OnDragStart", mainFrame.StartMoving)
    mainFrame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        SaveBarPosition()
    end)
    mainFrame:SetFrameStrata("MEDIUM")

    -- The artwork lives on its own layer above the sheet, so the
    -- bottom ornaments overlap the sheet's top edge instead of
    -- disappearing behind it.  The sheet is created later at the
    -- default level (mainFrame + 1); this layer sits well above it.
    local art = CreateFrame("Frame", nil, mainFrame)
    art:SetAllPoints()
    art:SetFrameLevel(mainFrame:GetFrameLevel() + 10)
    local k = ART.scale
    local barTex = art:CreateTexture(nil, "BACKGROUND")
    barTex:SetTexture(ART.file)
    barTex:SetSize(ART.master[1] * k, ART.master[2] * k)
    barTex:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", -ART.body[1] * k, ART.body[2] * k)

    -- Five roll slots over the painted tiles
    for _, key in ipairs({ "d20", "d100", "custom", "pin1", "pin2" }) do
        slots[key] = RollSlot(art, key)
    end
    slots.d20.die:SetText("d20")
    slots.d100.die:SetText("d100")

    -- RS monogram: click to close the bar, drag to move it
    local logo = CreateFrame("Button", nil, art)
    PlaceOnArt(logo, art, ART.logo)
    logo:SetHighlightTexture(ART.highlight, "ADD")
    do
        local hl = logo:GetHighlightTexture()
        local lw, lh = logo:GetSize()
        hl:ClearAllPoints()
        hl:SetPoint("TOPLEFT", lw * 0.12, -lh * 0.12); hl:SetPoint("BOTTOMRIGHT", -lw * 0.12, lh * 0.12)
        hl:SetVertexColor(1.0, 0.75, 0.35, 0.45)
    end
    logo:RegisterForDrag("LeftButton")
    logo:SetScript("OnMouseDown", function(self) self.dragged = false end)
    logo:SetScript("OnDragStart", function(self) self.dragged = true; mainFrame:StartMoving() end)
    logo:SetScript("OnDragStop", function()
        mainFrame:StopMovingOrSizing(); SaveBarPosition()
    end)
    logo:SetScript("OnClick", function(self)
        if self.dragged then self.dragged = false; return end
        GameTooltip:Hide()
        if sheetFrame then sheetFrame:Hide() end
        mainFrame:Hide()
        print("|cffaa8844RollSheet|r Hidden. Type /rs or use the minimap button to bring it back.")
    end)
    logo:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine("RollSheet")
        GameTooltip:AddLine("Click to close", 1, 1, 1)
        GameTooltip:AddLine("Drag to move. /rs or the minimap button reopens it.", 0.6, 0.6, 0.6, true)
        GameTooltip:Show()
    end)
    logo:SetScript("OnLeave", GameTooltip_Hide)


    slots.d20:SetScript("OnClick",  function() RollDie(20, 0) end)
    slots.d100:SetScript("OnClick", function() RollDie(100, 0) end)

    slots.custom:SetScript("OnClick", function(_, button)
        if button == "RightButton" then
            StaticPopup_Show("ROLLSHEET_CUSTOM_DIE")
        else
            local c = RollSheetDB.custom
            RollDie(c.sides, c.mod, c.label ~= "" and c.label or nil)
        end
    end)

    for n = 1, 2 do
        local b = slots["pin" .. n]
        b:SetScript("OnReceiveDrag", function() DropIconOnSlot(n) end)
        b:SetScript("OnClick", function(self, button)
            if GetCursorInfo() then DropIconOnSlot(n); return end   -- placing something held
            local roll = GetRollById(RollSheetDB.pins[n])
            if button == "LeftButton" and roll then
                RollDie(roll.sides or 20, roll.bonus, roll.name)
                return
            end
            -- Right-click (or left-click on an empty slot): choose a roll
            ShowMenu(self, function(_, root)
                root:CreateTitle("Bar slot " .. n)
                if #RollSheetDB.attacks == 0 then
                    root:CreateButton("No rolls yet: add one in the sheet", ToggleSheet)
                end
                for _, a in ipairs(RollSheetDB.attacks) do
                    local id = a.id
                    root:CreateRadio(
                        a.name .. "  (d" .. (a.sides or 20) .. ModText(a.bonus) .. ")",
                        function() return RollSheetDB.pins[n] == id end,
                        function()
                            local other = (n == 1) and 2 or 1
                            if RollSheetDB.pins[other] == id then RollSheetDB.pins[other] = nil end
                            RollSheetDB.pins[n] = id
                            RefreshBar()
                            if sheetFrame and sheetFrame:IsShown() then BuildSheet(); sheetFrame:Show() end
                        end)
                end
                root:CreateDivider()
                if roll then
                    root:CreateButton("Change icon...", function() OpenIconPicker(roll.id) end)
                    if roll.icon then
                        root:CreateButton("Reset icon", function()
                            roll.icon = nil; RefreshBar()
                        end)
                    end
                end
                root:CreateButton("Empty this slot", function()
                    RollSheetDB.pins[n] = nil
                    RefreshBar()
                    if sheetFrame and sheetFrame:IsShown() then BuildSheet(); sheetFrame:Show() end
                end)
            end)
        end)
    end

    -- Tooltips say exactly what each slot will roll
    local function SlotTooltip(self, title, line, hint)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine(title)
        if line then GameTooltip:AddLine(line, 1, 1, 1) end
        if hint then GameTooltip:AddLine(hint, 0.6, 0.6, 0.6, true) end
        GameTooltip:Show()
    end
    slots.d20:SetScript("OnEnter",  function(self) SlotTooltip(self, "d20",  "Roll 1-20") end)
    slots.d100:SetScript("OnEnter", function(self) SlotTooltip(self, "d100", "Roll 1-100") end)
    slots.custom:SetScript("OnEnter", function(self)
        local c = RollSheetDB.custom
        SlotTooltip(self, (c.label ~= "" and c.label) or "Custom die",
            "d" .. c.sides .. ModText(c.mod), "Right-click to change the die.")
    end)
    for n = 1, 2 do
        slots["pin" .. n]:SetScript("OnEnter", function(self)
            local roll = GetRollById(RollSheetDB.pins[n])
            if roll then
                SlotTooltip(self, roll.name, "d" .. (roll.sides or 20) .. ModText(roll.bonus),
                    "Right-click to change the roll or its icon. Drag a spell, item or macro here to use its icon.")
            else
                SlotTooltip(self, "Empty slot", nil, "Click to pin one of your sheet's rolls here.")
            end
        end)
    end

    -- Gear: settings menu
    local gear = SmallButton(art, ART.gear)
    gear:SetScript("OnClick", function(self)
        ShowMenu(self, function(_, root)
            root:CreateTitle("RollSheet")
            local roll = root:CreateButton("Roll display")
            local styles = {
                { "rewrite", "Rewrite roll lines (15 + 3 = 18)" },
                { "echo",    "Keep original, add breakdown" },
                { "off",     "Leave roll lines alone" },
            }
            for _, s in ipairs(styles) do
                local val = s[1]
                roll:CreateRadio(s[2],
                    function() return RollSheetDB.rollStyle == val end,
                    function() RollSheetDB.rollStyle = val end)
            end
            local bgMenu = root:CreateButton("Sheet background")
            for _, p in ipairs(PARCHMENTS) do
                if ParchmentAvailable(p) then
                    local key = p.key
                    bgMenu:CreateRadio(p.label,
                        function() return CurrentParchment().key == key end,
                        function() RollSheetDB.parchment = key; RefreshParchments() end)
                end
            end
            local size = root:CreateButton("Bar size")
            for _, sz in ipairs(BAR_SIZES) do
                local val = sz[1]
                size:CreateRadio(sz[2],
                    function() return (RollSheetDB.barScale or 1.0) == val end,
                    function() RollSheetDB.barScale = val; ApplyBarScale() end)
            end
            root:CreateCheckbox("Minimap button",
                function() return not RollSheetDB.minimap.hide end,
                function() SlashCmdList["ROLLSHEET"]("minimap") end)
            root:CreateDivider()
            root:CreateButton("Hide RollSheet  (/rs to bring it back)", function()
                mainFrame:Hide(); if sheetFrame then sheetFrame:Hide() end
            end)
        end)
    end)
    gear:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP"); GameTooltip:AddLine("Settings"); GameTooltip:Show()
    end)

    -- Chevron: open / close the sheet
    -- The chevron is a crop of the same artwork laid over the painted
    -- one, flipped vertically while the sheet is open.
    local chev = SmallButton(art, ART.chevron)
    chev.tex = chev:CreateTexture(nil, "ARTWORK")
    chev.tex:SetAllPoints()
    chev.tex:SetTexture(ART.file)
    chev:SetScript("OnClick", ToggleSheet)
    chev:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP"); GameTooltip:AddLine("Character sheet"); GameTooltip:Show()
    end)
    slots.chev = chev

    -- Keeps every slot in sync with the saved data
    RefreshBar = function()
        local c = RollSheetDB.custom
        slots.custom.die:SetText("d" .. c.sides)
        slots.custom.mod:SetText(ModText(c.mod))

        for n = 1, 2 do
            local b = slots["pin" .. n]
            local roll = GetRollById(RollSheetDB.pins[n])
            if roll then
                b.icon:SetTexture(roll.icon or ART.pinIcon["pin" .. n])
                b.icon:Show(); b.empty:Hide()
                b.die:SetText("d" .. (roll.sides or 20))
                b.mod:SetText(ModText(roll.bonus))
            else
                b.icon:Hide(); b.empty:Show()
                b.die:SetText(""); b.mod:SetText("")
            end
        end

        local open = sheetFrame and sheetFrame:IsShown()
        local l, r, t, btm = ArtCoords(ART.chevron)
        if open then chev.tex:SetTexCoord(l, r, btm, t)     -- flipped: points up
        else chev.tex:SetTexCoord(l, r, t, btm) end
    end
    RefreshBar()

    -- 1.6 stored the position in UI units at scale 1; convert once.
    if db.position and not db.pos then
        local u = UIParent:GetEffectiveScale()
        db.pos = { x = db.position.x * u, y = db.position.y * u }
    end
    ApplyBarScale()

    mainFrame:Hide()   -- nothing on screen until the user runs /rs
end

-- ================================================================
--  Slash commands
-- ================================================================

SLASH_ROLLSHEET1 = "/rs"
SLASH_ROLLSHEET2 = "/rollsheet"
SlashCmdList["ROLLSHEET"] = function(msg)
    msg = strtrim(msg)
    local cmd = msg:lower():match("^(%S*)") or ""
    local arg = msg:match("^%S+%s+(.+)$")

    if cmd == "reset" then
        RollSheetDB = nil; InitDB()
        if sheetFrame then sheetFrame:Hide(); sheetFrame = nil end
        if mainFrame  then mainFrame:Hide();  mainFrame  = nil end
        local ok1, e1 = pcall(BuildMain)
        if not ok1 then print("|cffff4444RollSheet|r Reset error (main): " .. tostring(e1)); return end
        local ok2, e2 = pcall(BuildSheet)
        if not ok2 then print("|cffff4444RollSheet|r Reset error (sheet): " .. tostring(e2)); return end
        mainFrame:Show()
        print("|cffaa8844RollSheet|r Reset complete. All data cleared.")
        return
    end

    if not mainFrame then
        print("|cffff4444RollSheet|r Addon failed to initialise. Try |cffffff00/rs reset|r")
        return
    end

    if cmd == "" or cmd == "toggle" then
        if mainFrame:IsShown() then
            mainFrame:Hide(); if sheetFrame then sheetFrame:Hide() end
        else
            mainFrame:Show()
        end
    elseif cmd == "show" then
        mainFrame:Show()
    elseif cmd == "hide" then
        mainFrame:Hide(); if sheetFrame then sheetFrame:Hide() end
    elseif cmd == "sheet" then
        ToggleSheet()
    elseif cmd == "view" then
        RequestSheet(arg)
    elseif cmd == "share" then
        ShareSheet()
    elseif cmd == "debug" then
        debugComms = not debugComms
        print("|cffaa8844RollSheet|r Comms debug " .. (debugComms and "ON" or "OFF") .. ".")
        if debugComms then
            local reg = C_ChatInfo.IsAddonMessagePrefixRegistered
                and C_ChatInfo.IsAddonMessagePrefixRegistered(ADDON_PREFIX)
            print("|cff888888[RS]|r version " .. ADDON_VERSION .. ", prefix " .. ADDON_PREFIX
                .. (reg and " registered" or " NOT registered") .. ", you are " .. tostring((Me())))
        end
    elseif cmd == "ping" then
        -- Loopback test: whisper ourselves.  With /rs debug on, a
        -- "recv" line proves sending AND receiving work on this client.
        local full = Me()
        if full then Enqueue("Q^T", "WHISPER", full) end
        print("|cffaa8844RollSheet|r Ping sent to yourself. With /rs debug on you should see a 'recv' line.")
    elseif cmd == "minimap" then
        local LDBIcon = LibStub and LibStub("LibDBIcon-1.0", true)
        if not LDBIcon then
            print("|cffaa8844RollSheet|r Minimap library not loaded.")
            return
        end
        RollSheetDB.minimap.hide = not RollSheetDB.minimap.hide
        if RollSheetDB.minimap.hide then
            LDBIcon:Hide("RollSheet")
            print("|cffaa8844RollSheet|r Minimap button hidden.  /rs minimap to show.")
        else
            LDBIcon:Show("RollSheet")
            print("|cffaa8844RollSheet|r Minimap button shown.")
        end
    elseif cmd:match("^d%d+[%+%-]?%d*$") then
        -- /rs d20   /rs d20+3   /rs d8-1 Dagger strike
        local sd, md = cmd:match("^d(%d+)([%+%-]?%d*)$")
        RollDie(tonumber(sd), tonumber(md) or 0, arg)
    elseif cmd == "rolls" then
        local nextStyle = { rewrite = "echo", echo = "off", off = "rewrite" }
        RollSheetDB.rollStyle = nextStyle[RollSheetDB.rollStyle] or "rewrite"
        local desc = {
            rewrite = "roll lines are rewritten (15 + 3 = 18).",
            echo    = "the original roll line is kept, with a breakdown underneath.",
            off     = "roll lines are left untouched.",
        }
        print("|cffaa8844RollSheet|r Roll display: " .. desc[RollSheetDB.rollStyle])
    else
        print("|cffaa8844RollSheet|r  /rs [show | hide | toggle | sheet | minimap | reset | view [name] | share | rolls | debug | d<N>[+M] [label]]")
    end
end

-- ================================================================
--  Initialization
-- ================================================================

local loader = CreateFrame("Frame")
loader:RegisterEvent("ADDON_LOADED")
loader:SetScript("OnEvent", function(self, event, addon)
    if addon ~= addonName then return end
    self:UnregisterEvent("ADDON_LOADED")

    C_ChatInfo.RegisterAddonMessagePrefix(ADDON_PREFIX)
    InitDB()
    pcall(InstallRollFilter)

    -- ── BUILD CORE FRAMES FIRST ──────────────────────────────────
    -- These must succeed before anything else.

    local ok1, err1 = pcall(BuildMain)
    if not ok1 then
        print("|cffff4444RollSheet ERROR (BuildMain):|r " .. tostring(err1))
    end

    local ok2, err2 = pcall(BuildSheet)
    if not ok2 then
        print("|cffff4444RollSheet ERROR (BuildSheet):|r " .. tostring(err2))
    end

    if ok1 and ok2 then
        print("|cffaa8844RollSheet|r loaded.  /rs to open")
    else
        print("|cffaa8844RollSheet|r loaded with errors. Try |cffffff00/rs reset|r")
    end

    -- ── MINIMAP BUTTON (LibDataBroker + LibDBIcon) ───────────────
    --
    -- Uses the standard LDB/LDBIcon libraries so the button is:
    --   • drag-to-reposition around the minimap (Shift+drag)
    --   • automatically picked up by collector addons
    --     (Titan Panel, ChocolateBar, MBB, MinimapButtonFrame,
    --      SexyMap, ElvUI's minimap-button collector, etc.)
    --   • toggleable via /rs minimap (or hidden entirely)
    --
    -- Wrapped in pcall so the addon still loads cleanly on
    -- installs that don't ship the libraries.
    pcall(function()
        local LDB     = LibStub and LibStub("LibDataBroker-1.1", true)
        local LDBIcon = LibStub and LibStub("LibDBIcon-1.0",      true)
        if not LDB then return end

        local ldbObj = LDB:NewDataObject("RollSheet", {
            type  = "launcher",
            text  = "RollSheet",
            icon  = "Interface/Icons/INV_Misc_Dice_02",
            OnClick = function(_, button)
                if button == "RightButton" then
                    -- Right-click: open toolbar AND character sheet together;
                    -- if the sheet is already shown, close both.
                    if not mainFrame then return end
                    if not sheetFrame then pcall(BuildSheet) end
                    if sheetFrame and sheetFrame:IsShown() then
                        sheetFrame:Hide()
                        mainFrame:Hide()
                    else
                        mainFrame:Show()
                        if sheetFrame then sheetFrame:Show() end
                    end
                else
                    -- Left-click: toggle the toolbar
                    if not mainFrame then return end
                    if mainFrame:IsShown() then
                        mainFrame:Hide()
                        if sheetFrame then sheetFrame:Hide() end
                    else
                        mainFrame:Show()
                    end
                end
            end,
            OnTooltipShow = function(tt)
                tt:AddLine("RollSheet")
                tt:AddLine("|cffaaaaaaLeft-click:|r toggle toolbar", 1, 1, 1)
                tt:AddLine("|cffaaaaaaRight-click:|r toggle toolbar + sheet", 1, 1, 1)
                tt:AddLine("|cffaaaaaaShift+drag:|r move button", 1, 1, 1)
            end,
        })

        if LDBIcon then
            LDBIcon:Register("RollSheet", ldbObj, RollSheetDB.minimap)
        end
    end)

    -- ── AUTO-BROADCAST ON GROUP / WORLD CHANGES ──────────────────
    -- Whenever we change zone, log in, or join a new group, we
    -- announce ourselves so everyone in the group has fresh data
    -- in their cache without anyone needing to manually request.
    -- BroadcastSheet is a no-op when we're solo, so PLAYER_ENTERING_WORLD
    -- and ZONE_CHANGED_NEW_AREA cost nothing outside groups.
    local autoSharePending = false
    local function QueueAutoBroadcast(delay)
        if autoSharePending then return end
        autoSharePending = true
        C_Timer.After(delay or 5, function()
            autoSharePending = false
            BroadcastSheet()
        end)
    end

    local zoneListener = CreateFrame("Frame")
    zoneListener:RegisterEvent("PLAYER_ENTERING_WORLD")
    zoneListener:RegisterEvent("ZONE_CHANGED_NEW_AREA")
    zoneListener:RegisterEvent("GROUP_ROSTER_UPDATE")
    zoneListener:SetScript("OnEvent", function() QueueAutoBroadcast(5) end)

    -- ── TOOLTIP INTEGRATION ──────────────────────────────────────
    --
    -- Designed for compatibility with TRP3, MRP, XRP, ElvUI, and
    -- any addon that modifies the unit tooltip.  All hooks are
    -- wrapped in pcall so Midnight 12.0 API changes cannot break
    -- the core addon.
    --
    -- Strategy:
    --   1. TooltipDataProcessor.AddTooltipPostCall  (Dragonflight+)
    --   2. GameTooltip:HookScript("OnTooltipSetUnit") (legacy)
    --   3. TRP3_MainTooltip hook  (TRP3 custom frame)
    --   4. UPDATE_MOUSEOVER_UNIT  (pre-fetch for all methods)
    --
    -- We NEVER use EnumerateFrames (restricted in modern WoW).
    -- Injection is idempotent per tooltip-show cycle via a flag
    -- that resets on OnHide / OnTooltipCleared.

    pcall(function()

        -- ── Build a snapshot of the local player's data ─────────
        local function BuildSelfData()
            local db  = RollSheetDB
            local res = {}
            for _, r in ipairs(db.resources) do
                local rname = (r.rtype == "Custom" and r.custom ~= "")
                    and r.custom or r.rtype
                table.insert(res, {
                    name    = rname,
                    current = r.current,
                    max     = r.max,
                    color   = r.color,
                })
            end
            return {
                hp        = db.hp,
                ac        = db.armour.ac,
                armType   = ARM_ORDER[db.armour.typeIdx] or "Light",
                resources = res,
            }
        end

        -- ── Inject RollSheet lines into a tooltip ───────────────
        -- Idempotent: the __rsInjected flag prevents double-adding
        -- within the same tooltip display cycle.
        local function InjectRS(tip, data)
            if not tip or not tip.AddLine then return end
            if tip.__rsInjected then return end
            tip.__rsInjected = true

            tip:AddLine(" ")
            tip:AddLine("RollSheet", 1, 1, 1)
            -- Make the title line bold by swapping its font object
            pcall(function()
                local n = tip:NumLines()
                local fs = _G[tip:GetName() .. "TextLeft" .. n]
                if fs and fs.SetFontObject then
                    fs:SetFontObject(GameTooltipHeaderText)
                    fs:SetTextColor(1, 1, 1)
                end
            end)

            local hpPct = data.hp.max > 0
                and math.floor(data.hp.current / data.hp.max * 100) or 0
            tip:AddDoubleLine(
                "HP",
                data.hp.current .. " / " .. data.hp.max .. "  (" .. hpPct .. "%)",
                1, 1, 1,  0.9, 0.7, 0.3)
            tip:AddDoubleLine(
                "AC",
                data.ac .. "  \194\183  " .. (data.armType or ""),
                1, 1, 1,  0.9, 0.7, 0.3)
            for _, res in ipairs(data.resources) do
                local pct = res.max > 0
                    and math.floor(res.current / res.max * 100) or 0
                tip:AddDoubleLine(
                    res.name,
                    res.current .. " / " .. res.max .. "  (" .. pct .. "%)",
                    1, 1, 1,  0.9, 0.7, 0.3)
            end

            tip:Show()   -- recalculate tooltip height with new lines
        end

        -- ── Hook OnHide / OnTooltipCleared to reset the flag ────
        -- Called once per tooltip frame to install the cleanup hook.
        local function EnsureClearHook(tip)
            if not tip or tip.__rsClearHooked then return end
            tip.__rsClearHooked = true
            pcall(function()
                if tip.HookScript then
                    tip:HookScript("OnTooltipCleared", function(self)
                        self.__rsInjected = nil
                    end)
                    tip:HookScript("OnHide", function(self)
                        self.__rsInjected = nil
                    end)
                end
            end)
        end

        -- ── Look up data for a unit (ourselves or the cache) ────
        local function GetDataForKey(key)
            local _, me = Me()
            if key == me then return BuildSelfData() end
            return sheetCache[key]
        end

        -- ── Core handler: resolve unit → data → inject ──────────
        -- EnsureData (networking section) decides whether to ask the
        -- unit for a sheet: same faction, reachable realm, not asked
        -- recently, and our copy is missing or more than a minute old.
        local function OnUnitTooltip(tip, unit)
            if not unit then
                pcall(function()
                    local _, u = tip:GetUnit()
                    unit = u
                end)
            end
            if not unit or not UnitIsPlayer(unit) then return end
            local full = UnitFull(unit)
            if not full then return end
            local name = full:lower()

            EnsureData(unit)
            local data = GetDataForKey(name)

            if data then
                EnsureClearHook(tip)
                InjectRS(tip, data)
            elseif hoverPings[name] then
                -- Data requested but not yet received — show a subtle hint
                if tip.__rsInjected then return end
                EnsureClearHook(tip)
                tip.__rsInjected = true
                tip:AddLine(" ")
                tip:AddLine("RollSheet", 1, 1, 1)
                pcall(function()
                    local n = tip:NumLines()
                    local fs = _G[tip:GetName() .. "TextLeft" .. n]
                    if fs and fs.SetFontObject then
                        fs:SetFontObject(GameTooltipHeaderText)
                        fs:SetTextColor(1, 1, 1)
                    end
                end)
                tip:AddLine("Requesting sheet...", 0.6, 0.6, 0.6)
                tip:Show()
            end
        end

        -- ── METHOD 1: TooltipDataProcessor (Dragonflight+) ──────
        -- This is the primary hook and fires for GameTooltip and
        -- any tooltip that goes through Blizzard's data pipeline,
        -- including unit-frame portrait hovers.  TRP3, MRP, and
        -- ElvUI all add their lines through this same pipeline, so
        -- our data appears naturally below theirs.
        if TooltipDataProcessor and Enum and Enum.TooltipDataType then
            pcall(TooltipDataProcessor.AddTooltipPostCall,
                  Enum.TooltipDataType.Unit,
                  function(tip)
                      pcall(OnUnitTooltip, tip, nil)
                  end)
        end

        -- ── METHOD 2: GameTooltip OnTooltipSetUnit (legacy) ─────
        -- Fallback for older clients or if TooltipDataProcessor is
        -- unavailable.  Safe to double-hook; __rsInjected prevents
        -- duplicate lines.
        pcall(function()
            GameTooltip:HookScript("OnTooltipSetUnit", function(self)
                pcall(OnUnitTooltip, self, nil)
            end)
        end)

        -- ── METHOD 3: TRP3 custom tooltip ───────────────────────
        -- TRP3 can display its own extended tooltip frame
        -- (TRP3_MainTooltip / TRP3_CharacterTooltip).  When active
        -- it re-fires OnShow each time the player mouses over a
        -- new unit.  We inject at the end of that cycle.
        local function HookTRP3Tooltip()
            -- TRP3 exposes one or more named tooltip frames
            local trpNames = {
                "TRP3_MainTooltip",
                "TRP3_CharacterTooltip",
            }
            for _, fname in ipairs(trpNames) do
                local trpTip = _G[fname]
                if trpTip and trpTip.AddLine and not trpTip.__rsClearHooked then
                    EnsureClearHook(trpTip)
                    trpTip:HookScript("OnShow", function(self)
                        -- Delay one frame so TRP3 finishes its own lines
                        C_Timer.After(0, function()
                            pcall(function()
                                if not self:IsShown() then return end
                                -- TRP3 tooltip doesn't support GetUnit(),
                                -- so we read the unit from GameTooltip or
                                -- fall back to the mouseover unit.
                                local unit = "mouseover"
                                pcall(function()
                                    local _, u = GameTooltip:GetUnit()
                                    if u then unit = u end
                                end)
                                if UnitExists(unit) and UnitIsPlayer(unit) then
                                    OnUnitTooltip(self, unit)
                                end
                            end)
                        end)
                    end)
                end
            end
        end

        -- Attempt the TRP3 hook now (if TRP3 loaded before us) and
        -- also listen for it to load later.
        C_Timer.After(3, function() pcall(HookTRP3Tooltip) end)

        local trpWatcher = CreateFrame("Frame")
        trpWatcher:RegisterEvent("ADDON_LOADED")
        trpWatcher:SetScript("OnEvent", function(_, _, loadedAddon)
            if loadedAddon == "totalRP3" or loadedAddon == "MyRolePlay"
               or loadedAddon == "XRP" then
                -- Give the addon a moment to create its tooltip frame
                C_Timer.After(2, function() pcall(HookTRP3Tooltip) end)
            end
        end)

        -- ── PRE-FETCH: UPDATE_MOUSEOVER_UNIT ────────────────────
        -- Fires when the player mouses over a unit in the 3D world
        -- or a unit-frame portrait.  We use it to pre-request data
        -- so it's ready for the tooltip hooks above.
        local hoverListener = CreateFrame("Frame")
        hoverListener:RegisterEvent("UPDATE_MOUSEOVER_UNIT")
        hoverListener:SetScript("OnEvent", function()
            if not UnitExists("mouseover") or not UnitIsPlayer("mouseover") then
                return
            end
            EnsureData("mouseover")
        end)

    end)  -- end tooltip pcall
end)
