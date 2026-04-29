-- RollSheet.lua  v1.3.2
-- RP dice roller + character sheet  ·  World of Warcraft: Midnight
-- /rs  or  /rollsheet
--
-- /rs            → toggle the toolbar
-- /rs sheet      → toggle the character sheet
-- /rs minimap    → toggle the minimap button
-- /rs view <n>   → request that player's sheet (cross-faction, ~300yd range)
-- /rs share      → broadcast your sheet to nearby players
-- /rs reset      → wipe SavedVariables and rebuild (troubleshooting)

local addonName, ns = ...

-- ================================================================
--  Constants
-- ================================================================

local FW           = 280
local ADDON_PREFIX = "ROLLSHEET"

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
            { name="Primary Attack",   bonus=3 },
            { name="Secondary Attack", bonus=1 },
        }
    end
    if not db.minimap then
        db.minimap = { hide = false, minimapPos = 215 }   -- LibDBIcon settings
    end
end

-- ================================================================
--  Serialization
-- ================================================================

local function San(s)
    return (s or ""):gsub("[|:]", "_")
end

-- Safely extract the short name (no realm suffix) from a unit name.
-- Returns nil if the input is missing, UNKNOWN, or a "secret string"
-- (introduced in WoW Midnight 12.0 for cross-realm contexts like
-- Timewalking, where addons are forbidden from inspecting names).
-- Wrapping in pcall lets us silently skip these units instead of
-- erroring — we couldn't have identified them anyway.
local function SafeShortName(name)
    if not name or name == UNKNOWN then return nil end
    local ok, short = pcall(function()
        return name:match("^([^%-]+)") or name
    end)
    if ok and type(short) == "string" then return short end
    return nil
end

local function Serialize()
    local db = RollSheetDB
    local t  = {}
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
        t[#t+1] = "K:" .. San(a.name) .. ":" .. a.bonus
    end
    local out = table.concat(t, "|")
    return out:sub(1, 250)
end

local function Deserialize(data)
    local s = { hp={current=20,max=20}, ac=0, armType="Light", resources={}, attacks={} }
    for chunk in data:gmatch("[^|]+") do
        local tag  = chunk:sub(1, 1)
        local rest = chunk:sub(3)
        if tag == "H" then
            local c, m = rest:match("(%d+):(%d+)")
            if c then s.hp = { current=tonumber(c), max=tonumber(m) } end
        elseif tag == "A" then
            local ac, at = rest:match("(%d+):(.*)")
            if ac then s.ac = tonumber(ac); s.armType = at end
        elseif tag == "R" then
            local nm, c, m = rest:match("([^:]+):(%d+):(%d+)")
            if nm then
                local col = RES_COL[nm] or {0.75, 0.75, 0.75}
                table.insert(s.resources, { name=nm, current=tonumber(c), max=tonumber(m), color=col })
            end
        elseif tag == "X" then
            local nm, c, m, hex = rest:match("([^:]+):(%d+):(%d+):(%x%x%x%x%x%x)")
            if not nm then
                nm, c, m = rest:match("([^:]+):(%d+):(%d+)")  -- old format
            end
            if nm then
                local col = {0.75, 0.75, 0.75}
                if hex then
                    col = {
                        tonumber(hex:sub(1,2), 16) / 255,
                        tonumber(hex:sub(3,4), 16) / 255,
                        tonumber(hex:sub(5,6), 16) / 255,
                    }
                end
                table.insert(s.resources, { name=nm, current=tonumber(c), max=tonumber(m), color=col })
            end
        elseif tag == "K" then
            local nm, b = rest:match("([^:]+):(-?%d+)")
            if nm then table.insert(s.attacks, { name=nm, bonus=tonumber(b) }) end
        end
    end
    return s
end

-- ================================================================
--  Roll
-- ================================================================

local function QuickRoll(sides)
    RandomRoll(1, sides)
end

local function ModRoll(sides, mod)
    RandomRoll(1, math.max(1, sides + mod))
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

local function ApplyBG(f)
    -- Solid dark fill safety net behind the parchment
    if not f._rsBgFill then
        f._rsBgFill = f:CreateTexture(nil, "BACKGROUND", nil, -8)
        f._rsBgFill:SetAllPoints()
        f._rsBgFill:SetColorTexture(0.25, 0.18, 0.10, 0.97)
    end
    -- Parchment via atlas — stretches to the full frame
    if not f._rsParchment then
        f._rsParchment = f:CreateTexture(nil, "BACKGROUND", nil, -7)
        f._rsParchment:SetAllPoints()
        local faction = UnitFactionGroup and UnitFactionGroup("player")
        local atlas   = (faction == "Horde") and "QuestBG-Horde" or "QuestBG-Alliance"
        f._rsParchment:SetAtlas(atlas, false)   -- false = stretch to frame, not native size
    end
    -- Gold border
    f:SetBackdrop(BD_BORDER)
    f:SetBackdropBorderColor(0.65, 0.47, 0.14, 1.00)
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
            Lbl(viewFrame, sign .. atk.bonus .. "   " .. atk.name,
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
--  Addon message handling
-- ================================================================

local sheetCache = {}
local pendingReq = {}    -- tracks /rs view requests (opens viewer on RSP)

-- ================================================================
--  Send a broadcast or request via YELL (silent, cross-faction).
--  Falls back gracefully if YELL is unavailable (e.g. instances).
-- ================================================================
local function SendYell(payload)
    -- C_ChatInfo.SendAddonMessage returns false if the channel
    -- can't carry the message (e.g. restricted zones). We swallow
    -- the failure rather than spamming the user.
    pcall(C_ChatInfo.SendAddonMessage, ADDON_PREFIX, payload, "YELL")
end

-- Broadcast our sheet to everyone in YELL range (~300 yards).
local function BroadcastSheet()
    local ok, payload = pcall(Serialize)
    if ok then SendYell("SHR|" .. payload) end
end

-- Debounced broadcaster: multiple calls within 1.5s collapse to one
-- send. Used for stat-change updates AND for reciprocation, so a
-- crowd of incoming SHRs only triggers a single outgoing broadcast.
local broadcastTimer = nil
local function ScheduleBroadcast()
    if broadcastTimer then return end
    broadcastTimer = C_Timer.After(1.5, function()
        broadcastTimer = nil
        BroadcastSheet()
    end)
end

local msgFrame = CreateFrame("Frame")
msgFrame:RegisterEvent("CHAT_MSG_ADDON")
msgFrame:SetScript("OnEvent", function(self, event, prefix, text, channel, sender)
    if prefix ~= ADDON_PREFIX then return end
    local short = SafeShortName(sender)
    if not short then return end
    if short == UnitName("player") then return end   -- ignore our own yells

    -- ── Targeted request: REQ:TargetName|Mode ───────────────────
    -- Mode "V" = explicit /rs view (responder sends RSP, opens viewer
    -- on the requester's side). Mode "H" or anything else = passive
    -- ping (responder sends SHR, just caches).
    if text:sub(1, 4) == "REQ:" then
        local target, mode = text:match("^REQ:([^|]+)|?(.?)")
        if target == UnitName("player") then
            local ok, payload = pcall(Serialize)
            if ok then
                if mode == "V" then
                    SendYell("RSP|" .. payload)
                else
                    SendYell("SHR|" .. payload)
                end
            end
        end

    elseif text:sub(1, 3) == "RSP" then
        local isNew = sheetCache[short] == nil
        local sheet = Deserialize(text:sub(5))
        sheetCache[short] = sheet
        if pendingReq[short] then
            pendingReq[short] = nil
            ShowRemoteSheet(short, sheet)
        end
        -- Reciprocate (debounced) so the sender gets our sheet too.
        if isNew then ScheduleBroadcast() end

    elseif text:sub(1, 3) == "SHR" then
        local isNew = sheetCache[short] == nil
        local sheet = Deserialize(text:sub(5))
        sheetCache[short] = sheet
        -- Reciprocate (debounced) when first hearing from someone.
        -- Closes the cache gap where we zoned in after them.
        if isNew then ScheduleBroadcast() end
    end
end)

local function RequestSheet(playerName)
    pendingReq[playerName] = true
    SendYell("REQ:" .. playerName .. "|V")
    print("|cffaa8844RollSheet|r Requested " .. playerName .. "'s sheet...")
    -- Auto-clear pending flag after 10s if no response
    C_Timer.After(10, function()
        if pendingReq[playerName] then
            pendingReq[playerName] = nil
            print("|cffaa8844RollSheet|r No response from " .. playerName .. ".")
        end
    end)
end

local function ShareSheet()
    local ok, payload = pcall(Serialize)
    if ok then
        SendYell("SHR|" .. payload)
        print("|cffaa8844RollSheet|r Sheet broadcast to nearby players.")
    else
        print("|cffaa8844RollSheet|r Share failed: " .. tostring(payload))
    end
end

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
    sheetFrame:SetPoint("TOP", mainFrame, "BOTTOM", 0, -2)
    ApplyBG(sheetFrame)

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

    -- ── ATTACKS ────────────────────────────────────────────────────
    Section(sheetFrame, "Attacks", y); y = y - 20

    local stdBtn = Btn(sheetFrame, FW-24, 24, "Standard Attack  --  d20")
    stdBtn:SetPoint("TOPLEFT", sheetFrame, "TOPLEFT", 12, y)
    stdBtn:SetScript("OnClick", function() QuickRoll(20) end)
    y = y - 30

    for i, atk in ipairs(db.attacks) do
        local bonusEB = EB(sheetFrame, "RSAtkBonus" .. i, 36, 22, 4)
        bonusEB:SetPoint("TOPLEFT", sheetFrame, "TOPLEFT", 12, y)
        bonusEB:SetText(tostring(atk.bonus))
        bonusEB:SetScript("OnEditFocusLost", function(s)
            local v = tonumber(s:GetText())
            if v then db.attacks[i].bonus = v
            else s:SetText(tostring(db.attacks[i].bonus)) end
        end)

        local anEB = EB(sheetFrame, "RSAtkName" .. i, 138, 22, 40)
        anEB:SetPoint("LEFT", bonusEB, "RIGHT", 6, 0)
        anEB:SetText(atk.name)
        anEB:SetScript("OnEditFocusLost", function(s)
            db.attacks[i].name = s:GetText()
        end)

        local arBtn = Btn(sheetFrame, 70, 22, "Roll d20")
        arBtn:SetPoint("TOPRIGHT", sheetFrame, "TOPRIGHT", -12, y)
        arBtn:SetScript("OnClick", function()
            local mod = tonumber(bonusEB:GetText()) or 0
            db.attacks[i].bonus = mod
            ModRoll(20, mod)
        end)

        y = y - 26
    end

    y = y - 10
    sheetFrame:SetHeight(math.abs(y) + 12)
    sheetFrame:Hide()   -- never auto-open on login; user opens via toolbar
end

-- ================================================================
--  Main frame  (slim toolbar)
-- ================================================================

local function BuildMain()
    mainFrame = CreateFrame("Frame", "RollSheetMain", UIParent, "BackdropTemplate")
    mainFrame:SetSize(FW, 58)
    mainFrame:SetPoint("CENTER")
    mainFrame:SetMovable(true); mainFrame:EnableMouse(true)
    mainFrame:RegisterForDrag("LeftButton")
    mainFrame:SetScript("OnDragStart", mainFrame.StartMoving)
    mainFrame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local x, y = self:GetCenter()
        local ux, uy = UIParent:GetCenter()
        RollSheetDB.position = { x = x-ux, y = y-uy }
    end)
    mainFrame:SetFrameStrata("MEDIUM")
    ApplyBG(mainFrame)

    Lbl(mainFrame, "RollSheet", "GameFontNormal", 0.20, 0.10, 0.02)
        :SetPoint("TOP", mainFrame, "TOP", 0, -6)

    local rule = mainFrame:CreateTexture(nil, "ARTWORK")
    rule:SetHeight(1)
    rule:SetColorTexture(0.42, 0.26, 0.08, 0.55)
    rule:SetPoint("TOPLEFT",  mainFrame, "TOPLEFT",  10, -20)
    rule:SetPoint("TOPRIGHT", mainFrame, "TOPRIGHT", -10, -20)

    local d20 = Btn(mainFrame, 46, 26, "d20")
    d20:SetPoint("BOTTOMLEFT", mainFrame, "BOTTOMLEFT", 14, 6)
    d20:SetScript("OnClick", function() QuickRoll(20) end)

    local d100 = Btn(mainFrame, 50, 26, "d100")
    d100:SetPoint("LEFT", d20, "RIGHT", 6, 0)
    d100:SetScript("OnClick", function() QuickRoll(100) end)

    local shBtn = Btn(mainFrame, 108, 26, "Sheet  v")
    shBtn:SetPoint("LEFT", d100, "RIGHT", 6, 0)
    shBtn:SetScript("OnClick", function()
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
    end)

    local clBtn = Btn(mainFrame, 32, 26, "X")
    clBtn:SetPoint("LEFT", shBtn, "RIGHT", 6, 0)
    clBtn:SetScript("OnClick", function()
        mainFrame:Hide(); if sheetFrame then sheetFrame:Hide() end
    end)

    if RollSheetDB.position then
        mainFrame:ClearAllPoints()
        mainFrame:SetPoint("CENTER", UIParent, "CENTER",
            RollSheetDB.position.x, RollSheetDB.position.y)
    end

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
    elseif cmd == "view" then
        if arg then RequestSheet(arg)
        else print("|cffaa8844RollSheet|r Usage:  /rs view PlayerName") end
    elseif cmd == "share" then
        ShareSheet()
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
    elseif cmd:match("^d%d+$") then
        local s = tonumber(cmd:match("^d(%d+)$"))
        if s and s >= 2 then QuickRoll(s) end
    else
        print("|cffaa8844RollSheet|r  /rs [show | hide | toggle | sheet | minimap | reset | view <n> | share | d<N>]")
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

    -- ── AUTO-BROADCAST ON ZONE / WORLD CHANGES ───────────────────
    -- YELL is range-limited (~300 yards), so we re-announce
    -- ourselves whenever the player enters a new zone or world.
    -- This populates everyone's caches passively, eliminating the
    -- need for per-hover requests in almost all cases.
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

        -- ── Look up cached data for a character name ────────────
        local function GetDataForName(name)
            if name == UnitName("player") then
                return BuildSelfData()
            end
            return sheetCache[name]
        end

        -- ── Request data if we don't have it yet (non-blocking) ─
        -- Uses a separate `hoverPings` table from `pendingReq` so a
        -- passive hover never opens the viewer window. Pings expire
        -- after 5s; if no SHR arrived by then, the tooltip simply
        -- omits the RollSheet section on next hover (= no addon).
        local hoverPings = {}
        local function EnsureData(name)
            if not name or name == UNKNOWN then return end
            if name == UnitName("player") then return end
            if sheetCache[name] or hoverPings[name] then return end
            hoverPings[name] = true
            SendYell("REQ:" .. name .. "|H")
            C_Timer.After(5, function() hoverPings[name] = nil end)
        end

        -- ── Core handler: resolve unit → data → inject ──────────
        local function OnUnitTooltip(tip, unit)
            if not unit then
                pcall(function()
                    local _, u = tip:GetUnit()
                    unit = u
                end)
            end
            if not unit or not UnitIsPlayer(unit) then return end
            local name = SafeShortName(UnitName(unit))
            if not name then return end

            EnsureData(name)
            local data = GetDataForName(name)

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
            local name = SafeShortName(UnitName("mouseover"))
            if not name then return end
            EnsureData(name)
        end)

    end)  -- end tooltip pcall
end)
