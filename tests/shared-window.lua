-- Run from the repository root with lua5.1 tests/shared-window.lua.
local directory = "OlympusMytikas/"
local manifest = assert(io.open(directory .. "OlympusMytikas.toc"))
local toc = manifest:read("*a")
manifest:close()
local installed = assert(toc:match("## Version: ([^\r\n]+)"))
local memberHome = "https://app.mytikas.monster/account.html"

local Widget = {}
Widget.__index = Widget

-- Geometry, decoration and event registration are handled by the game client.
for _, method in ipairs({
    "SetSize", "SetPoint", "ClearAllPoints", "SetHeight", "SetFrameStrata",
    "SetClampedToScreen", "SetMovable", "EnableMouse", "RegisterForDrag", "RegisterEvent"
}) do
    Widget[method] = function() end
end

function Widget:SetParent(parent) self.parent = parent end
function Widget:SetText(text) self.text = text end
function Widget:SetScript(name, handler) self.scripts[name] = handler end
function Widget:Show() self.shown = true end
function Widget:Hide() self.shown = false end
function Widget:SetShown(value) self.shown = value end
function Widget:SetAlpha(alpha) self.alpha = alpha end
function Widget:SetAutoFocus(value) self.autoFocus = value end
function Widget:HighlightText() self.selection = self.text end
function Widget:ClearFocus()
    self.focused = false
    self.scripts.OnEditFocusLost(self)
end

local function exercise(metadataAPI, version, previousTab)
    local widgets = {}
    local function create(kind, name, parent, template)
        local widget = setmetatable({ kind = kind, name = name, parent = parent, scripts = {} }, Widget)
        widgets[#widgets + 1] = widget
        function widget:CreateFontString()
            return create("FontString", nil, self)
        end
        if template == "PortraitFrameTemplate" then
            widget.CloseButton = create("Button", nil, widget)
            widget.Bg = {}
        end
        return widget
    end
    local function find(kind, text)
        for _, widget in ipairs(widgets) do
            if widget.kind == kind and widget.text == text then return widget end
        end
        error("Missing " .. kind .. " containing " .. text)
    end

    -- Only the two tool panels are doubles. The real shell owns their visibility,
    -- the shared URL field, the version label, the tab buttons and /mytikas.
    local recruit = create("Frame", "Recruit")
    local kos = create("Frame", "KillOnSight")
    local recruitDB, kosDB = { custom = {"saved ad"} }, { board = {"saved entry"} }
    local env = setmetatable({
        CreateFrame = create, UIParent = {}, UISpecialFrames = {}, SlashCmdList = {},
        OlympusMytikasDB = { lastTab = previousTab },
        OlympusRecruitDB = recruitDB, KillOnSightDB = kosDB,
        OlympusRecruit_BuildUI = function() return recruit end,
        KillOnSight_BuildUI = function() return kos end
    }, { __index = _G })
    env._G = env
    local function metadata(addon, key)
        assert(addon == "OlympusMytikas" and key == "Version")
        return version
    end
    if metadataAPI == "modern" then
        env.C_AddOns = { GetAddOnMetadata = metadata }
    else
        env.GetAddOnMetadata = metadata
    end

    local chunk = assert(loadfile(directory .. "OlympusMytikas.lua"))
    setfenv(chunk, env)("OlympusMytikas")
    assert(env.SLASH_OLYMPUSMYTIKAS1 == "/mytikas")
    env.SlashCmdList.OLYMPUSMYTIKAS("")
    local shell = env.OlympusMytikas_Show()
    assert(shell.shown)
    if previousTab == "kos" then assert(kos.shown) else assert(recruit.shown) end

    local recruitTab = find("Button", "Recruit")
    local kosTab = find("Button", "Kill on Sight")
    local url = find("EditBox", memberHome)
    local label = find("FontString", "v" .. version)
    assert(url.parent == kosTab.parent and label.parent == url.parent)
    assert(url.autoFocus == false)
    url.focused = true
    url.scripts.OnEditFocusGained(url)
    assert(url.selection == memberHome, "Focusing the field should select the complete URL")
    url:SetText("edited")
    url.scripts.OnEscapePressed(url)
    assert(not url.focused and url.text == memberHome, "Escape should restore the address")

    kosTab.scripts.OnClick(kosTab)
    assert(kos.shown and not recruit.shown and env.OlympusMytikasDB.lastTab == "kos")
    recruitTab.scripts.OnClick(recruitTab)
    assert(recruit.shown and not kos.shown and env.OlympusMytikasDB.lastTab == "recruit")
    assert(recruit.parent == kos.parent and recruit.parent.parent == shell)
    shell.CloseButton.scripts.OnClick(shell.CloseButton)
    assert(not shell.shown)
    env.SlashCmdList.OLYMPUSMYTIKAS("board")
    assert(shell.shown and kos.shown and not recruit.shown)
    local toggle = find("Button", "KoS ON")
    local enabled
    env.KillOnSight_SetEnabled = function(on) enabled = on end
    toggle.scripts.OnClick(toggle)
    assert(enabled == false and env.OlympusMytikasDB.kosEnabled == false and toggle.text == "KoS OFF")
    assert(not kosTab.shown and not kos.shown and recruit.shown)
    env.SlashCmdList.OLYMPUSMYTIKAS("board")
    assert(not kos.shown and recruit.shown)
    toggle.scripts.OnClick(toggle)
    assert(enabled and env.OlympusMytikasDB.kosEnabled and kosTab.shown)
    assert(env.OlympusMytikas_Show("recruit", recruit) == shell)
    assert(env.OlympusMytikas_Show("kos", kos) == shell)
    assert(url == find("EditBox", memberHome) and label == find("FontString", "v" .. version))
    assert(env.OlympusRecruitDB == recruitDB and recruitDB.custom[1] == "saved ad")
    assert(env.KillOnSightDB == kosDB and kosDB.board[1] == "saved entry")
end

exercise("modern", installed, "kos")
-- A distinct version catches accidental hardcoding and covers the older metadata API.
exercise("legacy", "9.8.7", nil)
print("Shared addon window, version metadata, URL selection and tab switching passed.")
