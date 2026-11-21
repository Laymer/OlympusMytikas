-- Olympus Mytikas - one window, two guild tools.
--
-- This file is only the shell. It builds a single window with two tabs and one
-- minimap button, then hands each tab its addon's existing window as a child.
-- It never changes either addon's rules, commands, guild protocol or data:
--   Recruit      = OlympusRecruit 1.6.5  (global OlympusRecruit_BuildUI)
--   Kill on Sight = KillOnSight 1.5.4     (global KillOnSight_BuildUI)
-- Both addon files still work on their own: every shell call is guarded, so
-- running either one without this file behaves exactly as it always did.

local ADDON = ...
OlympusMytikasLoaded = true

OlympusMytikasDB = OlympusMytikasDB or {}
if type(OlympusMytikasDB.minimap) ~= "boolean" then OlympusMytikasDB.minimap = true end
if type(OlympusMytikasDB.minimapAngle) ~= "number" then OlympusMytikasDB.minimapAngle = 200 end
if OlympusMytikasDB.lastTab ~= "recruit" and OlympusMytikasDB.lastTab ~= "kos" then
	OlympusMytikasDB.lastTab = "recruit"
end

local GOLD  = { 0.95, 0.89, 0.62 }
local AMBER = { 0.79, 0.58, 0.33 }
local DIM   = { 0.70, 0.63, 0.54 }
local INK   = { 0.055, 0.032, 0.026 }

local WIN_W, WIN_H = 560, 850
local CONTENT_W, CONTENT_H = 540, 760

-- The one skin for BOTH tabs: the game art the kill board already used.
-- Recruit's own TGA backdrop and hand-drawn buttons are gone in the merged
-- addon, so nothing in either panel paints a competing window background.
local PAGE_ART = "Professions-QualityWindow-Background"
local INSET_ART = "heavybronze-frame-background"
local PORTRAIT  = "Interface\\AddOns\\OlympusMytikas\\Media\\olympus-logo"

local function HasAtlas(name)
	if type(C_Texture) ~= "table" or type(C_Texture.GetAtlasInfo) ~= "function" then return false end
	local ok, info = pcall(C_Texture.GetAtlasInfo, name)
	return ok and info ~= nil
end

local function ApplyPageArt(f)
	if not HasAtlas(PAGE_ART) then return end
	local anchor = type(f.Bg) == "table" and f.Bg or f
	if not f.koPage then f.koPage = f:CreateTexture(nil, "BACKGROUND", nil, 1) end
	f.koPage:SetAllPoints(anchor)
	if pcall(f.koPage.SetAtlas, f.koPage, PAGE_ART) then
		if type(f.Bg) == "table" then
			if not f.koFill then
				f.koFill = f:CreateTexture(nil, "BACKGROUND", nil, 0)
				f.koFill:SetAllPoints(f.Bg)
				f.koFill:SetColorTexture(0.082, 0.086, 0.059)
			end
			f.Bg:Hide()
		end
		if f.TopTileStreaks then pcall(function() f.TopTileStreaks:Hide() end) end
	end
end

local shell, content, tabRecruit, tabKos, mapBtn, dragging
local panels = {}
local active = nil

local function Say(msg)
	if DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then
		pcall(DEFAULT_CHAT_FRAME.AddMessage, DEFAULT_CHAT_FRAME, "|cffca9455Olympus|r: " .. tostring(msg))
	end
end

-- The game's own portrait frame, like the kill board uses, so the merged window
-- reads as part of Forever. Fallbacks keep it working on any interface version.
local function BuildShell()
	if shell then return shell end
	local f
	if pcall(function() f = CreateFrame("Frame", "OlympusMytikasFrame", UIParent, "PortraitFrameTemplate") end)
		and f and f.CloseButton then
		-- the template gave us chrome
	elseif pcall(function() f = CreateFrame("Frame", "OlympusMytikasFrame", UIParent, "BasicFrameTemplateWithInset") end)
		and f then
		-- a simpler game frame
	else
		f = CreateFrame("Frame", "OlympusMytikasFrame", UIParent)
	end
	f:SetSize(WIN_W, WIN_H)
	f:SetPoint("CENTER", UIParent, "CENTER", 0, 30)
	f:SetFrameStrata("DIALOG")
	if f.SetToplevel then pcall(f.SetToplevel, f, true) end
	f:SetClampedToScreen(true)
	f:SetMovable(true)
	f:EnableMouse(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", function(self) self:StartMoving() end)
	f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)

	if f.SetTitle then
		pcall(f.SetTitle, f, "Olympus Mytikas")
	elseif f.TitleText then
		f.TitleText:SetText("Olympus Mytikas")
	end
	if f.CloseButton then
		f.CloseButton:SetScript("OnClick", function() f:Hide() end)
	elseif f.closeBox then
		f.closeBox:SetScript("OnClick", function() f:Hide() end)
	end

	-- The one portrait: Olympus' white mountain on navy, not the kill-board emblem.
	if f.SetPortraitToAsset then pcall(f.SetPortraitToAsset, f, PORTRAIT) end

	-- This is the only window art in the addon: both tabs sit on top of it.
	ApplyPageArt(f)

	-- A plain backing for the no-template case; one flat fill, no sliced art.
	if not f.Bg and not f.koPage then
		local edge = f:CreateTexture(nil, "BORDER")
		edge:SetColorTexture(0.62, 0.42, 0.24, 0.90)
		edge:SetAllPoints(f)
		local bg = f:CreateTexture(nil, "BACKGROUND")
		bg:SetColorTexture(INK[1], INK[2], INK[3], 0.96)
		bg:SetPoint("TOPLEFT", f, "TOPLEFT", 3, -3)
		bg:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -3, 3)
	end

	local bar = CreateFrame("Frame", nil, f)
	bar:SetSize(CONTENT_W, 28)
	bar:SetPoint("TOPLEFT", f, "TOPLEFT", 10, -44)

	local function MakeTab(label, x, key)
		local b = CreateFrame("Button", nil, bar, "UIPanelButtonTemplate")
		b:SetSize(140, 24)
		b:SetPoint("TOPLEFT", bar, "TOPLEFT", x, 0)
		b:SetText(label)
		b:SetScript("OnClick", function() OlympusMytikas_Show(key) end)
		return b
	end
	tabRecruit = MakeTab("Recruit", 0, "recruit")
	tabKos = MakeTab("Kill on Sight", 150, "kos")

	local metadata = C_AddOns and C_AddOns.GetAddOnMetadata or GetAddOnMetadata
	local version = bar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	version:SetPoint("LEFT", tabKos, "RIGHT", 8, 0)
	version:SetText("v" .. (metadata(ADDON, "Version") or "?"))
	local url = CreateFrame("EditBox", nil, bar, "InputBoxTemplate")
	url:SetPoint("LEFT", version, "RIGHT", 10, 0)
	url:SetPoint("RIGHT", bar, "RIGHT", -4, 0)
	url:SetHeight(22)
	url:SetAutoFocus(false)
	local memberHome = "https://app.mytikas.monster/account.html"
	url:SetText(memberHome)
	url:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)
	url:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
	url:SetScript("OnEditFocusLost", function(self) self:SetText(memberHome) end)

	content = CreateFrame("Frame", nil, f)
	content:SetSize(CONTENT_W, CONTENT_H)
	content:SetPoint("TOPLEFT", f, "TOPLEFT", 10, -76)

	if type(UISpecialFrames) == "table" then
		local exists = false
		for i = 1, #UISpecialFrames do
			if UISpecialFrames[i] == "OlympusMytikasFrame" then exists = true end
		end
		if not exists then UISpecialFrames[#UISpecialFrames + 1] = "OlympusMytikasFrame" end
	end

	shell = f
	return f
end

-- Neither panel is allowed to bring its own window: the shell above is the
-- only frame with art, a title or a close button.
local function HideChrome(child)
	if not child then return end
	if child.CloseButton then child.CloseButton:Hide() end
	if child.closeBox then child.closeBox:Hide() end
	if child.TitleText then child.TitleText:Hide() end
	if child.titleText then child.titleText:Hide() end
	if child.koPage then child.koPage:Hide() end
	if child.koFill then child.koFill:Hide() end
	if child.art then child.art:Hide() end
	if child.glow then child.glow:Hide() end
	if child.Portrait then child.Portrait:Hide() end
	if child.GetPortrait then
		local ok, portrait = pcall(child.GetPortrait, child)
		if ok and portrait then portrait:Hide() end
	end
end

-- Take an addon's already-built window and make it a page of our window.
local function Embed(key, child)
	if not child or panels[key] == child then return end
	HideChrome(child)
	child:SetParent(content)
	child:ClearAllPoints()
	if key == "recruit" then
		child:SetPoint("TOPLEFT", content, "TOPLEFT", 30, -8)
		if child.closeBox then child.closeBox:Hide() end
	else
		child:SetPoint("TOPLEFT", content, "TOPLEFT", 0, 0)
		if child.CloseButton then child.CloseButton:Hide() end
		if child.closeBox then child.closeBox:Hide() end
	end
	-- Tabs and the shell's own close button own the window now.
	child:SetMovable(false)
	if child.RegisterForDrag then pcall(child.RegisterForDrag, child) end
	if type(UISpecialFrames) == "table" then
		local name = child.GetName and child:GetName() or nil
		for i = #UISpecialFrames, 1, -1 do
			if name and UISpecialFrames[i] == name then table.remove(UISpecialFrames, i) end
		end
	end
	panels[key] = child
end

local function EnsurePanel(key)
	if panels[key] then return panels[key] end
	local builder = key == "recruit" and OlympusRecruit_BuildUI or KillOnSight_BuildUI
	if type(builder) ~= "function" then return nil end
	local ok, child = pcall(builder)
	if not ok or not child then return nil end
	Embed(key, child)
	return child
end

-- Open the merged window, optionally on a named tab. Addon windows are passed
-- in by their own toggle functions so they are only built when first needed.
OlympusMytikas_Show = function(tab, child)
	if tab ~= "recruit" and tab ~= "kos" then tab = OlympusMytikasDB.lastTab end
	if tab ~= "recruit" and tab ~= "kos" then tab = "recruit" end
	local f = BuildShell()
	if child then Embed(tab, child) end
	EnsurePanel(tab)
	OlympusMytikasDB.lastTab = tab
	active = tab
	for key, panel in pairs(panels) do panel:SetShown(key == tab) end
	tabRecruit:SetAlpha(tab == "recruit" and 1 or 0.55)
	tabKos:SetAlpha(tab == "kos" and 1 or 0.55)
	f:Show()
	if panels[tab] then panels[tab]:Show() end
	return f
end

-- One button for both addons. The addons skip building their own while the
-- shell is loaded; this removes any that are already there from an old reload.
local function HideAddonButtons()
	for _, name in ipairs({ "OlympusRecruitMinimapButton", "KillOnSightMinimap" }) do
		local b = _G[name]
		if b and b.Hide then pcall(b.Hide, b) end
	end
end

local function PlaceMapButton()
	if not mapBtn then return end
	local a = math.rad(tonumber(OlympusMytikasDB.minimapAngle) or 200)
	mapBtn:SetPoint("CENTER", Minimap, "CENTER", math.cos(a) * 80, math.sin(a) * 80)
end

local function BuildMapButton()
	if mapBtn or type(Minimap) ~= "table" then return mapBtn end
	local b = CreateFrame("Button", "OlympusMytikasMinimap", Minimap)
	b:SetSize(32, 32)
	b:SetFrameStrata("MEDIUM")
	b:SetFrameLevel(8)
	b:SetClampedToScreen(true)
	b:RegisterForDrag("LeftButton")
	-- Without this the client never delivers "RightButton" to OnClick.
	b:RegisterForClicks("LeftButtonUp", "RightButtonUp")

	local icon = b:CreateTexture(nil, "BACKGROUND")
	icon:SetTexture("Interface\\AddOns\\OlympusMytikas\\Media\\minimap")
	icon:SetAllPoints(b)
	b.icon = icon

	b:SetScript("OnEnter", function(self)
		if self.icon then self.icon:SetVertexColor(1, 0.93, 0.72) end
		if type(GameTooltip) ~= "table" then return end
		pcall(function()
			GameTooltip:SetOwner(self, "ANCHOR_LEFT")
			GameTooltip:AddLine("Olympus Mytikas", GOLD[1], GOLD[2], GOLD[3])
			GameTooltip:AddLine("Recruit + Kill on Sight in one window", 1, 1, 1)
			GameTooltip:AddLine("Click: open the window", DIM[1], DIM[2], DIM[3])
			GameTooltip:AddLine("Right click: post a random ad to /1 and /2", DIM[1], DIM[2], DIM[3])
			GameTooltip:AddLine("Drag: move me round the ring", DIM[1], DIM[2], DIM[3])
			GameTooltip:Show()
		end)
	end)
	b:SetScript("OnLeave", function(self)
		if self.icon then self.icon:SetVertexColor(1, 1, 1) end
		if type(GameTooltip) == "table" then pcall(function() GameTooltip:Hide() end) end
	end)
	b:SetScript("OnClick", function(_, button)
		if button == "RightButton" then
			-- Exactly the old Recruit right click: one ad to /1 and /2.
			if type(SlashCmdList) == "table" and type(SlashCmdList.OLYMPUSRECRUIT) == "function" then
				pcall(SlashCmdList.OLYMPUSRECRUIT, "")
			elseif type(OlympusRecruit_Post) == "function" then
				pcall(OlympusRecruit_Post)
			end
		else
			OlympusMytikas_Show(OlympusMytikasDB.lastTab)
		end
	end)
	b:SetScript("OnDragStart", function() dragging = true end)
	b:SetScript("OnDragStop", function() dragging = false end)
	b:SetScript("OnUpdate", function(self, dt)
		if not dragging then return end
		local mx, my = Minimap:GetCenter()
		local cx, cy = GetCursorPosition()
		if not (mx and my and cx and cy) then return end
		local scale = Minimap:GetEffectiveScale() or 1
		if scale ~= 0 then cx, cy = cx / scale, cy / scale end
		OlympusMytikasDB.minimapAngle = math.deg(math.atan2(cy - my, cx - mx))
		PlaceMapButton()
	end)
	PlaceMapButton()
	mapBtn = b
	return b
end

local function ShowMapButton(on)
	OlympusMytikasDB.minimap = on and true or false
	if on then
		if not mapBtn then BuildMapButton() end
		if mapBtn and mapBtn.Show then pcall(mapBtn.Show, mapBtn) end
	elseif mapBtn and mapBtn.Hide then
		pcall(mapBtn.Hide, mapBtn)
	end
	return true
end

-- /om minimap and /kos minimap both drive this one button in the merged addon.
OlympusMytikas_Minimap = ShowMapButton

-- /mytikas is a shortcut; /om ui and /kos still do what they always did.
SLASH_OLYMPUSMYTIKAS1 = "/mytikas"
SLASH_OLYMPUSMYTIKAS2 = "/omg"
SlashCmdList["OLYMPUSMYTIKAS"] = function(msg)
	msg = tostring(msg or ""):lower():match("^%s*(%S*)")
	if msg == "recruit" or msg == "om" then
		OlympusMytikas_Show("recruit")
	elseif msg == "kos" or msg == "board" then
		OlympusMytikas_Show("kos")
	else
		OlympusMytikas_Show(OlympusMytikasDB.lastTab)
	end
end

local ev = CreateFrame("Frame")
OlympusMytikasEventFrame = ev   -- exposed for the harness; the game never needs it
ev:RegisterEvent("PLAYER_LOGIN")
ev:RegisterEvent("PLAYER_ENTERING_WORLD")
ev:SetScript("OnEvent", function(_, event)
	if event == "PLAYER_LOGIN" and OlympusMytikasDB.minimap ~= false then
		BuildMapButton()
	end
	HideAddonButtons()
end)

-- A reload can leave the old buttons alive for a moment; put them away quietly.
if type(C_Timer) == "table" and type(C_Timer.After) == "function" then
	for _, delay in ipairs({ 1, 3, 8 }) do
		pcall(C_Timer.After, delay, HideAddonButtons)
	end
end

Say("loaded - /om ui and /kos open the same window; /mytikas opens it directly.")
