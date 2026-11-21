-- OlympusRecruit - random recruitment ads to /1 General and /2 Trade.
--
--   /om                 post one random ad to /1 and /2
--   /om ui              open the window (type your own ad in the box there)
--   /om list            show the pool, numbered
--   /om pick <n>        post ad n
--   /om add <text>      add your own ad (saved)
--   /om del <n>         delete one of your own ads
--   /om test            show the next ad and where it would go, send nothing
--   /om invite <name>   invite that player to the guild now (or /om invite for
--                       whether the right-click line is in the game's menus)
--   /om why             what the client last blocked
--   /om minimap         minimap button on/off
--   /om profile         which character the settings belong to
--   /om reset           this character back to defaults (custom ads too)
--
-- RIGHT CLICK A PLAYER and there is "Invite to <guild>": on their portrait (target,
-- party, raid) and on their name in chat, the Who list and the friends list. Added
-- through Blizzard's own Menu.ModifyMenu, so the game's own lines are untouched.
--
-- POSTS GO TO /1 AND /2, ALWAYS. Two sends, slot 1 then slot 2, in the same pass.
-- There is no channel detection, no join, no leave and no slot reshuffling
-- anywhere in this addon: it never reads or writes the channel list, and it
-- never touches /3 or anything above it.
--
-- Both sends have to happen inside the player's own action. This client only
-- accepts a channel message inside a real key press or mouse click; a timer is
-- not one, and neither is macro text run from a timer, so both are refused
-- (ADDON_ACTION_BLOCKED). Post with the window button, the minimap right click,
-- the keybind, or /om. There is no auto-post for the same reason.
--
-- NO GUILD-NOTE DATES AND NO ROSTER READS. A guild note can only be written from
-- a real click or key press on this client, so an automatic join date could not
-- be written from a roster event - and the queued-then-written design was more
-- moving parts than it was worth. The whole feature is gone, commands included.
--
-- SETTINGS ARE PER CHARACTER. This client only saves per account, so the minimap
-- button and its angle live in OlympusRecruitDB.chars["<realm>-<name>"]. A
-- character that has never been seen inherits the account settings.
local PREFIX = "|cffca9455Olympus|r: "
local ECHO_WAIT = 4    -- how long the client gets to echo our own post back
-- The two channels, as the client numbers them. Nothing resolves these at run
-- time: no lookup, no fallback, no alternative. If General and Trade ever sit on
-- other slots, the chat settings are where that gets fixed, not this addon.
local SLOT_GENERAL = 1   -- /1
local SLOT_TRADE = 2     -- /2
local ADS = {
	"<Olympus Mytikas> Everyone's recruiting gods. We're recruiting people who can be on time. Raids, PVP, Dungeons. Community built at the top. Whisper me for an invite.",
	"<Olympus Mytikas> We're not hardcore. We're consistent. Raids, PVP, Dungeons. Community built at the top. Whisper me for an invite.",
	"<Olympus Mytikas> We're not selling a dream. We're selling a raid slot. Raids, PVP, Dungeons. Community built at the top. Whisper me for an invite.",
	"<Olympus Mytikas> Our recruitment pitch: we log in. Raids, PVP, Dungeons. Community built at the top. Whisper me for an invite.",
	"<Olympus Mytikas> Less \"elite\", more \"on time\". Raids, PVP, Dungeons. Community built at the top. Whisper me for an invite.",
	"<Olympus Mytikas> We're not Mythic. We're mythic-adjacent. Raids, PVP, Dungeons. Community built at the top. Whisper me for an invite.",
	"<Olympus Mytikas> Olympus is a mountain, not a personality test. Climb it with us. Raids, PVP, Dungeons. Community built at the top. Whisper me for an invite.",
	"<Olympus Mytikas> Altitude high, attitude reasonable. Raids, PVP, Dungeons. Community built at the top. Whisper me for an invite.",
	"<Olympus Mytikas> Summit views, dungeon queues, zero loot drama. Raids, PVP, Dungeons. Community built at the top. Whisper me for an invite.",
	"<Olympus Mytikas> Your last guild had a great name too. Raids, PVP, Dungeons. Community built at the top. Whisper me for an invite.",
	"<Olympus Mytikas> We've seen your pug logs. We're not scared. Raids, PVP, Dungeons. Community built at the top. Whisper me for an invite.",
	"<Olympus Mytikas> You've been carried by worse. Raids, PVP, Dungeons. Community built at the top. Whisper me for an invite.",
	"<Olympus Mytikas> No interview, no entrance fee. Just don't be the reason we wipe. Raids, PVP, Dungeons. Community built at the top. Whisper me for an invite.",
	"<Olympus Mytikas> Wanted: people who read the tactic before the pull. Raids, PVP, Dungeons. Community built at the top. Whisper me for an invite.",
	"<Olympus Mytikas> We don't recruit numbers. We recruit people who don't stand in fire. Raids, PVP, Dungeons. Community built at the top. Whisper me for an invite.",
	"<Olympus Mytikas> Gear is replaceable. The person who reads chat is not. Raids, PVP, Dungeons. Community built at the top. Whisper me for an invite.",
	"<Olympus Mytikas> Bring flasks, bring opinions. Only one of those is welcome. Raids, PVP, Dungeons. Community built at the top. Whisper me for an invite.",
	"<Olympus Mytikas> If your last guild died, we know. We're the ones still here. Raids, PVP, Dungeons. Community built at the top. Whisper me for an invite.",
	"<Olympus Mytikas> We don't promise server firsts. We promise nobody raids alone. Raids, PVP, Dungeons. Community built at the top. Whisper me for an invite.",
	"<Olympus Mytikas> We're not gods. We're the ones the gods ask for advice. Raids, PVP, Dungeons. Community built at the top. Whisper me for an invite.",
	"<Olympus Mytikas> Great view, mid-tier egos. Raids, PVP, Dungeons. Community built at the top. Whisper me for an invite.",
	"<Olympus Mytikas> We're not the biggest guild on the peak. Just the one that doesn't fall off. Raids, PVP, Dungeons. Community built at the top. Whisper me for an invite.",
	"<Olympus Mytikas> No gods, no carries, no drama on the climb. Raids, PVP, Dungeons. Community built at the top. Whisper me for an invite.",
	"<Olympus Mytikas> Bring a working mic and a working character. That's the entry exam. Raids, PVP, Dungeons. Community built at the top. Whisper me for an invite.",
	"<Olympus Mytikas> We down it, we split it, we log off. Raids, PVP, Dungeons. Community built at the top. Whisper me for an invite.",
	"<Olympus Mytikas> You bring the effort, we bring the repairs. Raids, PVP, Dungeons. Community built at the top. Whisper me for an invite.",
	"<Olympus Mytikas> We're the guild you join when the last one stopped logging in. Raids, PVP, Dungeons. Community built at the top. Whisper me for an invite.",
	"<Olympus Mytikas> Consistency beats talent. The peak knows the difference. Raids, PVP, Dungeons. Community built at the top. Whisper me for an invite.",
	"<Olympus Mytikas> We raid like people with jobs, not like gods with worshippers. Raids, PVP, Dungeons. Community built at the top. Whisper me for an invite.",
	"<Olympus Mytikas> The mountain doesn't make gods. It makes regulars. Raids, PVP, Dungeons. Community built at the top. Whisper me for an invite.",
	"<Olympus Mytikas> Highest peak on Olympus. We need climbers, not tourists. Raids, PVP, Dungeons. Community built at the top. Whisper me for an invite.",
	"<Olympus Mytikas> THE SUMMIT IS CLAIMED IN BLOOD! Join our ranks, crush our enemies, and carve your legend into Azeroth. Steel in our hands. Thunder in our hearts. No mercy. No surrender. Raids, PVP, Dungeons. Community built at the top. Whisper me for an invite.",
	"<Olympus Mytikas> Is Recruiting! This is Peak Olympus! Join for the events, the banter, and the shared disdain for the Red Menace. Other guilds discriminate based on Race and Class, but here you are an Equal. Here: You're an Olympian. Raids, PVP, Dungeons. Community built at the top. Whisper me for an invite.",
	"<Olympus Mytikas> They say we want everyone on this server in the guild. They are right and you are behind schedule. Raids, PVP, Dungeons. Community built at the top. Whisper me for an invite.",
	"<Olympus Mytikas> They call it mass recruitment spam. We call it a queue. Read the ad, join the queue. Raids, PVP, Dungeons. Community built at the top. Whisper me for an invite.",
	"<Olympus Mytikas> They built an addon to mute us. Install it. We will still be raiding. Raids, PVP, Dungeons. Community built at the top. Whisper me for an invite.",
	"<Olympus Mytikas> They say we lag the server. Six hundred of us in one zone. Bring a friend, we will crash yours too. Raids, PVP, Dungeons. Community built at the top. Whisper me for an invite.",
	"<Olympus Mytikas> They say we are a cult. Cults keep their members. Your guild loses theirs. Pick one. Raids, PVP, Dungeons. Community built at the top. Whisper me for an invite.",
	"<Olympus Mytikas> They say we are Twitch chat with a tabard. Twitch chat outnumbers your raid team. Raids, PVP, Dungeons. Community built at the top. Whisper me for an invite.",
	"<Olympus Mytikas> They say we are taking over the server. We are still taking applications. Raids, PVP, Dungeons. Community built at the top. Whisper me for an invite.",
	"<Olympus Mytikas> They want us permabanned. Your guild cannot fill a raid. Those are the two facts. Raids, PVP, Dungeons. Community built at the top. Whisper me for an invite.",
	"<Olympus Mytikas> They say our recruitment is a plague. Plagues spread. Consider yourself exposed. Raids, PVP, Dungeons. Community built at the top. Whisper me for an invite.",
	"<Olympus Mytikas> They say we ruined trade chat. Trade chat was ruined before we logged in. Raids, PVP, Dungeons. Community built at the top. Whisper me for an invite.",
	"<Olympus Mytikas> They say the tag is a blacklist. Every blacklist makes the roster tighter. Get in. Raids, PVP, Dungeons. Community built at the top. Whisper me for an invite.",
	"<Olympus Mytikas> They say we ruin Alliance. Alliance was already ruined. We are just louder about it. Raids, PVP, Dungeons. Community built at the top. Whisper me for an invite.",
	"<Olympus Mytikas> They say we break the player limit. Limits exist to be broken. Come help. Raids, PVP, Dungeons. Community built at the top. Whisper me for an invite.",
	"<Olympus Mytikas> They are renaming us to dodge the addon filters. The roster is not being renamed. Raids, PVP, Dungeons. Community built at the top. Whisper me for an invite.",
	"<Olympus Mytikas> They say we are brainrot. We are just Right. And we take your raiders. Raids, PVP, Dungeons. Community built at the top. Whisper me for an invite.",
	"<Olympus Mytikas> There is a thread about us on the subreddit. It has more comments than your guild has members. Raids, PVP, Dungeons. Community built at the top. Whisper me for an invite.",
	"<Olympus Mytikas> They wrote three paragraphs about why we should be banned. Nobody in their guild has cleared the raid. Raids, PVP, Dungeons. Community built at the top. Whisper me for an invite.",
	"<Olympus Mytikas> They are petitioning the developers to remove us. The developers have a queue. So do we. Raids, PVP, Dungeons. Community built at the top. Whisper me for an invite.",
	"<Olympus Mytikas> They report every ad we post. We post another one. That is the entire relationship. Raids, PVP, Dungeons. Community built at the top. Whisper me for an invite.",
	"<Olympus Mytikas> The people who want us banned have never beaten a boss we have not beaten twice. Raids, PVP, Dungeons. Community built at the top. Whisper me for an invite.",
	"<Olympus Mytikas> They call it harassment. We call it trade chat with a personality. Raids, PVP, Dungeons. Community built at the top. Whisper me for an invite.",
	"<Olympus Mytikas> The complaint thread has four hundred upvotes and eleven of them play on this server. Raids, PVP, Dungeons. Community built at the top. Whisper me for an invite.",
	"<Olympus Mytikas> You can report an ad. You cannot report a clear time. Raids, PVP, Dungeons. Community built at the top. Whisper me for an invite.",
	"<Olympus Mytikas> They quote the rules at us. We quote the logs at them. Only one of these matters. Raids, PVP, Dungeons. Community built at the top. Whisper me for an invite.",
	"<Olympus Mytikas> Every complaint about us is written by someone who has never organised anything bigger than a dungeon group. Raids, PVP, Dungeons. Community built at the top. Whisper me for an invite.",
	"<Olympus Mytikas> Half the posts about us are from people who quit this server before we were formed. Raids, PVP, Dungeons. Community built at the top. Whisper me for an invite.",
	"<Olympus Mytikas> We are recruiting. You are complaining. Only one of us is doing something. Raids, PVP, Dungeons. Community built at the top. Whisper me for an invite.",
	"<Olympus Mytikas> Nobody in the game says your guild's name. They say ours. Raids, PVP, Dungeons. Community built at the top. Whisper me for an invite.",
}
local DEFAULTS = { custom = {}, lastPick = 0, minimap = true, minimapAngle = 200 }
local frame = CreateFrame("Frame")
--============================== per-character settings ========================
-- SavedVariables on this client are per ACCOUNT, so every setting used to be
-- shared with every alt. The ones that belong to a single character are kept in
-- OlympusRecruitDB.chars["<realm>-<name>"] instead, and EnsureDB() hands out a
-- view of the database that reads and writes those keys there. The rest of the
-- addon keeps saying db.minimap / db.minimapAngle and never has to care.
--
-- Nothing here can touch a chat channel: the post always goes to /1 and /2.
local PERCHAR = {
	minimap = true, minimapAngle = true,
}

-- a brand-new character inherits the account-wide settings
local INHERIT = {
	minimap = true, minimapAngle = true,
}
local function SafeText(fn, ...)
	if type(fn) ~= "function" then return nil end
	local ok, v = pcall(fn, ...)
	if ok and type(v) == "string" and v ~= "" then return v end
	return nil
end

-- the player's name is not available on the very first frames of a login, and
-- UnitName can hand back a secret value on this client, so it is read through a
-- pcall and the account-wide table is used until there is a name to key on
local function CharKey()
	local name = SafeText(UnitName, "player")
	if not name then return nil end
	local realm = SafeText(GetRealmName)
	if not realm then return name end
	-- a secret value throws on any operation, concatenation included
	local ok, key = pcall(function() return realm .. "-" .. name end)
	if ok and type(key) == "string" and key ~= "" then return key end
	return nil
end
local dbCache

local function EnsureDB()
	OlympusRecruitDB = OlympusRecruitDB or {}
	local g = OlympusRecruitDB
	for k, v in pairs(DEFAULTS) do
		if g[k] == nil then
			if type(v) == "table" then
				local t = {}
				for i = 1, #v do t[i] = v[i] end
				g[k] = t
			else
				g[k] = v
			end
		end
	end

	local key = CharKey()
	local c = dbCache
	if c and c.g == g and c.key == key then return c.proxy end

	local p
	if key then
		g.chars = g.chars or {}
		p = g.chars[key]
		if not p then
			-- first time this character is seen since the update: keep whatever it
			-- was using, so nothing changes under the player
			p = {}
			for k in pairs(INHERIT) do
				if g[k] ~= nil then p[k] = g[k] end
			end
			g.chars[key] = p
		end
	end

	local proxy = setmetatable({}, {
		__index = function(_, k)
			if p and PERCHAR[k] then
				local v = p[k]
				if v ~= nil then return v end
			end
			return g[k]
		end,
		__newindex = function(_, k, v)
			if p and PERCHAR[k] then p[k] = v else g[k] = v end
		end,
	})

	dbCache = { g = g, key = key, p = p, proxy = proxy }
	return proxy
end
local uiSink   -- set while the window exists: every Say() also lands in its footer

local function Say(msg)
	local f = DEFAULT_CHAT_FRAME
	if f then f:AddMessage(PREFIX .. tostring(msg)) end
	if uiSink then pcall(uiSink, tostring(msg)) end
end

-- pool = shipped ads + anything the user added
local function Pool()
	local pool = {}
	for i = 1, #ADS do pool[#pool + 1] = ADS[i] end
	local db = EnsureDB()
	if db and db.custom then
		for i = 1, #db.custom do pool[#pool + 1] = db.custom[i] end
	end
	return pool
end

-- One place where a saved ad is validated, shared by the window's text box and
-- /om add, so both behave identically and both survive a relog (/om reset keeps
-- the profile; db.custom is SavedVariables).
local TAG = "<Olympus Mytikas>"
local AD_LIMIT = 255   -- the client refuses a channel message longer than this

local function AddAd(text)
	text = tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")
	text = text:gsub("%s+", " ")
	if text == "" then return nil, "nothing typed" end
	-- every ad has to name the guild. The player's own wording is kept as typed;
	-- only a missing tag is filled in.
	local tagged = false
	if text:sub(1, #TAG) ~= TAG then
		text = TAG .. " " .. text
		tagged = true
	end
	if #text > AD_LIMIT then
		return nil, "too long: " .. #text .. " characters, the limit is " .. AD_LIMIT
	end
	local db = EnsureDB()
	db.custom = db.custom or {}
	for i = 1, #db.custom do
		if db.custom[i] == text then
			return nil, "that ad is already in the list (number " .. (#ADS + i) .. ")"
		end
	end
	db.custom[#db.custom + 1] = text
	return #ADS + #db.custom, tagged
end

local function DelAd(n)
	local db = EnsureDB()
	db.custom = db.custom or {}
	local first = #ADS + 1
	if not n then return false, "no ad selected" end
	if n < first or n > #ADS + #db.custom then
		return false, "only your own ads (number " .. first .. " and up) can be deleted"
	end
	table.remove(db.custom, n - #ADS)
	return true
end

-- returns index, text. Never returns the same index twice in a row.
local function Pick(force)	local pool = Pool()
	if #pool == 0 then return nil end
	if force and pool[force] then return force, pool[force] end
	local db = EnsureDB()
	local i = math.random(#pool)
	if #pool > 1 and db and i == db.lastPick then
		i = i % #pool + 1
	end
	if db then db.lastPick = i end
	return i, pool[i]
end
--============================== the post ====================================
-- Two sends, /1 then /2, in the same pass, and that is the whole of this addon's
-- channel behaviour. No slot is scanned, joined, left or moved.
--
-- Both sends must be inside the player's action. This client refuses a channel
-- message that does not come from a real key press or mouse click: the message is
-- dropped and the UI prints "Interface action failed because of an addon". A
-- timer is not a hardware event, which is why there is no auto-post and why the
-- two sends are never separated by one.

local pending   -- the post we are waiting to see echo back into chat
local lastBlock -- the last action the client blocked, e.g. "a send (OlympusRecruit)"
local blockSaid = {}   -- per addon name, so one culprit cannot silence another

local function PostAll(forceIndex, quiet)
	local idx, msg = Pick(forceIndex)
	if not msg then
		Say("the ad pool is empty")
		return
	end

	local p = { texts = { [msg] = true }, sent = 0, seen = 0 }
	pending = p

	-- THE POST: both channels, one pass, nothing between them
	if pcall(SendChatMessage, msg, "CHANNEL", nil, SLOT_GENERAL) then p.sent = p.sent + 1 end
	if pcall(SendChatMessage, msg, "CHANNEL", nil, SLOT_TRADE) then p.sent = p.sent + 1 end

	if not quiet then
		Say("posted ad " .. idx .. "/" .. #Pool() .. " to /1 General + /2 Trade")
	end

	-- The client echoes our own post back through CHAT_MSG_CHANNEL, and that echo
	-- is the only proof it landed. Reading events is not restricted, so this can
	-- wait; sending from here would be, which is what the old code got wrong.
	C_Timer.After(ECHO_WAIT + 1, function()
		if pending ~= p or quiet then return end
		if p.sent < 2 then
			Say("the client refused " .. (2 - p.sent) .. " of the two sends - a post needs a click or a key press")
		end
		if p.seen == 0 then
			Say("no echo came back from /1 or /2 - nothing appeared in either channel")
			if lastBlock then
				Say("the client blocked " .. lastBlock .. " - that send needs a click or a key press")
			else
				Say("check that General is on /1 and Trade is on /2 in your chat settings")
			end
		elseif p.seen == 1 then
			Say("only one echo came back - one of /1 or /2 did not take it")
			Say("check that General is on /1 and Trade is on /2 in your chat settings")
		end
	end)
	return idx
end
--============================== window ======================================
-- A window instead of typing. The ads, the channels they post to and your own
-- ad box are all on screen, and everything /om can do is a button here.
--
-- Drawing rules, learned the hard way on this client: the whole window is ONE
-- flat 512x512 texture (Media\panel.tga) laid over the frame with SetAllPoints,
-- because sliced nine-patch art tore down the middle. Every other widget is a
-- SetColorTexture fill or a font string, so there is no template and no ElvUI
-- dependency to break. Frame is 480x480 = the texture's own 1:1 aspect, so the
-- art can only ever scale evenly.

local WIN_W, WIN_H = 480, 480
local MEDIA = "Interface\\AddOns\\OlympusMytikas\\Media\\"
local GOLD  = { 0.95, 0.89, 0.62 }
local AMBER = { 0.79, 0.58, 0.33 }
local DIM   = { 0.70, 0.63, 0.54 }
local INK   = { 0.055, 0.032, 0.026 }

local win, uiStatus, uiAdHead, uiAdText, uiFooter
local uiInput, uiInputHint
local uiPage = 1
local uiTick = 0

-- a flat colour rectangle; no file, so it can never fail to load
local function Fill(parent, layer, sub, r, g, b, a)
	local t = parent:CreateTexture(nil, layer or "BACKGROUND", nil, sub or 0)
	t:SetColorTexture(r, g, b, a)
	return t
end

-- A recessed box in the same Forever bronze as the kill board, so both tabs
-- of the merged window are cut from the same art.
local function Inset(parent, w, h)
	local f = CreateFrame("Frame", nil, parent)
	f:SetSize(w, h)
	local fill = f:CreateTexture(nil, "BACKGROUND", nil, 2)
	local ok = false
	if type(C_Texture) == "table" and type(C_Texture.GetAtlasInfo) == "function" then
		ok = pcall(function()
			return C_Texture.GetAtlasInfo("heavybronze-frame-background") ~= nil
		end) and pcall(fill.SetAtlas, fill, "heavybronze-frame-background")
	end
	if not ok then fill:SetColorTexture(0.20, 0.13, 0.07, 0.95) end
	fill:SetAllPoints(f)
	f.fill = fill
	return f
end

-- The client's own button, the same one the kill board uses. No drawn fake.
local function Button(parent, text, w, h)
	local ok, b = pcall(CreateFrame, "Button", nil, parent, "UIPanelButtonTemplate")
	if not (ok and b) then b = CreateFrame("Button", nil, parent) end
	b:SetSize(w, h)
	b:SetText(text)
	return b
end

local function Line(parent, template, x, y, w, justify, col)
	local fs = parent:CreateFontString(nil, "OVERLAY")
	fs:SetFontObject(template)
	fs:SetJustifyH(justify or "LEFT")
	fs:SetSize(w, 14)
	fs:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
	if col then fs:SetTextColor(col[1], col[2], col[3]) end
	return fs
end
local UIStatus   -- forward: buttons refresh the numbers straight away

local function BuildUI()
	local f = CreateFrame("Frame", "OlympusRecruitWindow", UIParent)
	f:SetSize(WIN_W, WIN_H)
	f:SetPoint("CENTER", UIParent, "CENTER", 0, 60)
	f:SetFrameStrata("DIALOG")
	f:EnableMouse(true)
	f:SetMovable(true)
	f:SetClampedToScreen(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", f.StartMoving)
	f:SetScript("OnDragStop", f.StopMovingOrSizing)

	local art = f:CreateTexture(nil, "BACKGROUND")
	art:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
	art:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 0, 0)
	art:SetTexture(MEDIA .. "panel")
	f.art = art

	local glow = f:CreateTexture(nil, "ARTWORK")
	glow:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
	glow:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 0, 0)
	glow:SetTexture(MEDIA .. "glow")
	glow:SetBlendMode("ADD")
	glow:SetAlpha(0.08)
	f.glow = glow

	local title = f:CreateFontString(nil, "OVERLAY")
	title:SetFontObject("GameFontNormalLarge")
	title:SetPoint("TOP", f, "TOP", 0, -24)
	title:SetTextColor(GOLD[1], GOLD[2], GOLD[3])
	title:SetText("Olympus Recruit")
	f.titleText = title   -- the shell hides this: it has its own title

	local sub = f:CreateFontString(nil, "OVERLAY")
	sub:SetFontObject("GameFontHighlightSmall")
	sub:SetPoint("TOP", f, "TOP", 0, -47)
	sub:SetTextColor(DIM[1], DIM[2], DIM[3])
	sub:SetText("recruitment ads  -  /1 General  +  /2 Trade")

	uiStatus = Line(f, "GameFontHighlightSmall", 40, -80, 400, "CENTER", GOLD)
	Line(f, "GameFontHighlightSmall", 44, -100, 392, "LEFT", AMBER)
		:SetText("/1 General      +      /2 Trade      (always both)")

	local box = Inset(f, 400, 104)
	box:SetPoint("TOPLEFT", f, "TOPLEFT", 40, -128)
	uiAdHead = Line(box, "GameFontNormalSmall", 10, -7, 200, "LEFT", AMBER)
	uiAdText = box:CreateFontString(nil, "OVERLAY")
	uiAdText:SetFontObject("GameFontHighlightSmall")
	uiAdText:SetJustifyH("LEFT")
	uiAdText:SetJustifyV("TOP")
	uiAdText:SetSize(380, 74)
	uiAdText:SetPoint("TOPLEFT", box, "TOPLEFT", 10, -24)
	uiAdText:SetTextColor(0.92, 0.88, 0.80)

	local prev = Button(f, "<", 74, 22)
	prev:SetPoint("TOPLEFT", f, "TOPLEFT", 68, -242)
	prev:SetScript("OnClick", function()
		uiPage = uiPage - 1
		UIStatus()
	end)

	local this = Button(f, "Post this ad", 180, 22)
	this:SetPoint("TOPLEFT", f, "TOPLEFT", 150, -242)
	this:SetScript("OnClick", function()
		PostAll(uiPage)
	end)

	local nxt = Button(f, ">", 74, 22)
	nxt:SetPoint("TOPLEFT", f, "TOPLEFT", 338, -242)
	nxt:SetScript("OnClick", function()
		uiPage = uiPage + 1
		UIStatus()
	end)

	local post = Button(f, "Post a random ad", 344, 24)
	post:SetPoint("TOPLEFT", f, "TOPLEFT", 68, -268)
	post:SetScript("OnClick", function()
		local idx = PostAll()
		if idx then uiPage = idx end
		UIStatus()
	end)

	-- no auto-post: this client refuses a channel send from a timer (and from
	-- macro text run by one), so offer the reason instead of a dead button
	Line(f, "GameFontHighlightSmall", 84, -303, 330, "LEFT", DIM)
		:SetText("no auto-post - this client only posts on a click or key press")

	-- nothing else to configure: the post goes to /1 and /2, every time

	-- your own ad: type it here, Enter (or "Add ad") saves it to the pool for
	-- good. The box is a plain EditBox inside the same drawn inset used for the
	-- ad preview, so no template and no client art is involved.
	local inputBox = Inset(f, 258, 22)
	inputBox:SetPoint("TOPLEFT", f, "TOPLEFT", 40, -348)
	local eb = CreateFrame("EditBox", "OlympusRecruitInput", inputBox)
	eb:SetSize(242, 18)
	eb:SetPoint("TOPLEFT", inputBox, "TOPLEFT", 8, -3)
	eb:SetAutoFocus(false)
	eb:SetMaxLetters(AD_LIMIT)
	pcall(function() eb:SetTextInsets(0, 0, 0, 0) end)
	if not pcall(eb.SetFontObject, eb, "ChatFontNormal") then
		pcall(eb.SetFontObject, eb, "GameFontHighlightSmall")
	end
	pcall(function() eb:SetTextColor(0.96, 0.93, 0.86) end)
	uiInput = eb

	uiInputHint = inputBox:CreateFontString(nil, "OVERLAY")
	uiInputHint:SetFontObject("GameFontHighlightSmall")
	uiInputHint:SetPoint("LEFT", inputBox, "LEFT", 9, 0)
	uiInputHint:SetTextColor(DIM[1], DIM[2], DIM[3])

	local function Hint()
		local typed = eb:GetText() or ""
		if typed == "" then
			uiInputHint:SetText("type your own ad here, then Enter")
			uiInputHint:Show()
		else
			uiInputHint:Hide()
		end
	end

	local function SaveTyped()
		local typed = eb:GetText() or ""
		local n, tagged = AddAd(typed)
		if not n then
			Say("not added: " .. tostring(tagged))
			-- a box holding nothing but spaces looks empty, so make it empty
			if typed:match("^%s*$") then eb:SetText("") end
			Hint()
			return
		end
		Say("saved as ad " .. n .. " (" .. #Pool() .. " in pool)"
			.. (tagged and " - it now starts with <Olympus Mytikas>" or ""))
		eb:SetText("")
		uiPage = n
		Hint()
		UIStatus()
	end

	eb:SetScript("OnTextChanged", Hint)
	eb:SetScript("OnEnterPressed", function(self)
		SaveTyped()
		self:ClearFocus()
	end)
	eb:SetScript("OnEscapePressed", function(self)
		self:SetText("")
		self:ClearFocus()
		Hint()
	end)
	Hint()

	local addBtn = Button(f, "Add ad", 62, 22)
	addBtn:SetPoint("TOPLEFT", f, "TOPLEFT", 306, -348)
	addBtn:SetScript("OnClick", SaveTyped)

	local delBtn = Button(f, "Del", 64, 22)
	delBtn:SetPoint("TOPLEFT", f, "TOPLEFT", 376, -348)
	delBtn:SetScript("OnClick", function()
		local ok, why = DelAd(uiPage)
		if not ok then
			Say(why)
			return
		end
		Say("deleted ad " .. uiPage .. " (" .. #Pool() .. " in pool)")
		if uiPage > #Pool() then uiPage = #Pool() end
		UIStatus()
	end)

	local foot = Inset(f, 400, 30)
	foot:SetPoint("TOPLEFT", f, "TOPLEFT", 40, -376)
	uiFooter = foot:CreateFontString(nil, "OVERLAY")
	uiFooter:SetFontObject("GameFontHighlightSmall")
	uiFooter:SetJustifyH("LEFT")
	uiFooter:SetJustifyV("TOP")
	uiFooter:SetSize(380, 22)
	uiFooter:SetPoint("TOPLEFT", foot, "TOPLEFT", 10, -4)
	uiFooter:SetTextColor(DIM[1], DIM[2], DIM[3])
	uiFooter:SetText("ready")

	local close = Button(f, "Close", 100, 22)
	close:SetPoint("TOP", f, "TOP", 0, -412)
	close:SetScript("OnClick", function() f:Hide() end)
	f.closeBox = close

	f:SetScript("OnShow", function() pcall(UIStatus) end)
	f:SetScript("OnUpdate", function(self, dt)
		uiTick = uiTick + dt
		local t = GetTime()
		self.glow:SetAlpha(0.05 + 0.05 * math.abs(math.sin(t * 1.6)))
		if uiTick >= 0.5 then
			uiTick = 0
			pcall(UIStatus)
		end
	end)

	-- ESC closes it, like every other window
	pcall(function() table.insert(UISpecialFrames, "OlympusRecruitWindow") end)
	return f
end

UIStatus = function()
	local pool = Pool()
	local n = #pool
	if n < 1 then n = 1 end
	if uiPage < 1 then uiPage = 1 end
	if uiPage > n then uiPage = n end

	uiStatus:SetText(#pool .. " ads      click to post")
	uiAdHead:SetText("ad " .. uiPage .. " of " .. #pool .. (uiPage > #ADS and "   (yours)" or "")
		.. "      /1 General + /2 Trade in one post")
	uiAdText:SetText(pool[uiPage] or "")
end

--============================== no auto-post =================================
-- There is no auto-post. This client only accepts a channel post inside a real
-- key press or mouse click: an OnUpdate tick is not one, and C_Macro.RunMacroText
-- from that tick is not one either (live test: ADDON_ACTION_BLOCKED, UNKNOWN()).
-- Both attempts are gone rather than left in to fail quietly every few minutes.
-- Post with the window, the minimap right click, the keybind, or /om - a click
-- or a chat command is a real input event and goes out.

-- The shell calls this to get the panel without opening a second window.
function OlympusRecruit_BuildUI()
	if win then return win end
	local ok, err = pcall(function() win = BuildUI() end)
	if not ok or not win then
		win = nil
		Say("the window could not be built: " .. tostring(err))
		return nil
	end
	uiSink = function(msg)
		if uiFooter then uiFooter:SetText(msg) end
	end
	return win
end

local function ToggleUI()
	if OlympusMytikasLoaded then
		local w = OlympusRecruit_BuildUI()
		if w then OlympusMytikas_Show("recruit", w) end
		return
	end
	if win and win:IsShown() then
		win:Hide()
		return
	end
	local w = OlympusRecruit_BuildUI()
	if not w then return end
	w:Show()
	UIStatus()
end

-- /om post from a keybind
function OlympusRecruit_Post()
	PostAll()
end

-- open the window from a keybind
function OlympusRecruit_UI()
	ToggleUI()
end
--============================== minimap button ================================
-- A small round button on the minimap ring: click opens the window, right click
-- posts, drag slides it round the ring, and the angle is saved. No library and
-- no template - 32 px with our own texture, drawn from the same art family.

local mapBtn
local mapDragging = false

local function PlaceMapButton(b)
	local db = EnsureDB()
	local a = math.rad(tonumber(db.minimapAngle) or 200)
	local r = 80
	b:SetPoint("CENTER", Minimap, "CENTER", math.cos(a) * r, math.sin(a) * r)
end

local function BuildMapButton()
	local b = CreateFrame("Button", "OlympusRecruitMinimapButton", Minimap)
	b:SetSize(32, 32)
	b:SetFrameStrata("MEDIUM")
	b:SetFrameLevel(8)
	b:RegisterForDrag("LeftButton")

	local icon = b:CreateTexture(nil, "BACKGROUND")
	icon:SetPoint("TOPLEFT", b, "TOPLEFT", 0, 0)
	icon:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", 0, 0)
	icon:SetTexture(MEDIA .. "recruit-minimap")
	b.icon = icon

	b:SetScript("OnEnter", function(self)
		if self.icon then self.icon:SetVertexColor(1, 0.93, 0.72) end
		if type(GameTooltip) == "table" then
			pcall(function()
				GameTooltip:SetOwner(self, "ANCHOR_LEFT")
				GameTooltip:AddLine("Olympus Recruit", GOLD[1], GOLD[2], GOLD[3])
				GameTooltip:AddLine(#Pool() .. " ads ready", 1, 1, 1)
				GameTooltip:AddLine("/1 General + /2 Trade in one post", DIM[1], DIM[2], DIM[3])
				GameTooltip:AddLine("Click: open the window", DIM[1], DIM[2], DIM[3])
				GameTooltip:AddLine("Right click: post a random ad", DIM[1], DIM[2], DIM[3])
				GameTooltip:AddLine("Drag: move me round the ring", DIM[1], DIM[2], DIM[3])
				GameTooltip:Show()
			end)
		end
	end)
	b:SetScript("OnLeave", function(self)
		if self.icon then self.icon:SetVertexColor(1, 1, 1) end
		if type(GameTooltip) == "table" then pcall(function() GameTooltip:Hide() end) end
	end)
	b:SetScript("OnClick", function(_, button)
		if button == "RightButton" then
			PostAll()
		else
			ToggleUI()
		end
	end)
	b:SetScript("OnDragStart", function() mapDragging = true end)
	b:SetScript("OnDragStop", function() mapDragging = false end)
	b:SetScript("OnUpdate", function(self, dt)
		dt = tonumber(dt) or 0
		if mapDragging then
			local mx, my = Minimap:GetCenter()
			if mx and my then
				local cx, cy = GetCursorPosition()
				if cx and cy then
					local scale = Minimap:GetEffectiveScale() or 1
					if scale ~= 0 then cx, cy = cx / scale, cy / scale end
					EnsureDB().minimapAngle = math.deg(math.atan2(cy - my, cx - mx))
					PlaceMapButton(self)
				end
			end
		end
	end)
	PlaceMapButton(b)
	return b
end

local function ShowMapButton(on)
	local db = EnsureDB()
	db.minimap = on and true or false
	if on then
		if not mapBtn then
			local ok, res = pcall(BuildMapButton)
			if not ok or not res then
				mapBtn = nil
				Say("minimap button could not be built: " .. tostring(res))
				return false
			end
			mapBtn = res
		end
		mapBtn:Show()
	elseif mapBtn then
		mapBtn:Hide()
	end
	return true
end
--============================== guild invite =================================
-- Right-click a player and there is "Invite to <your guild>": on their portrait
-- (target, party, raid) and on their name in chat, the Who list and the friends
-- list. /om invite <name> does the same from the keyboard.
--
-- Blizzard's own menu API is the only supported way for an addon to add a line
-- there: Menu.ModifyMenu("MENU_UNIT_" .. which, fn) hands over the menu the game
-- has just built, inside securecallfunction, so nothing of the game's is
-- replaced, hooked or tainted. The old dropdown menus do taint the rest of the
-- menu, so they are not used, not even as a fallback.
--
-- The guild roster menus (GUILD and COMMUNITIES_GUILD_MEMBER) are deliberately
-- NOT hooked: those hold the game's own officer actions (kick, promote, rank,
-- remove), which this client refuses from addon code.
--
-- WHY THE LINE DOES NOT INVITE BY ITSELF. Blizzard's notes for the WoW Forever
-- 1.60.1 launch build (4 Nov 2026): "C_GuildInfo.Invite is now forbidden for
-- addons and macros. Outgoing guild invites are now throttled to 10 per
-- minute." Three guild addons that shipped that week (Ultimate Guild Invite,
-- LibGuildRoster, Guild Control) all say the same thing from their own testing:
-- every route an addon drives is refused - the API call, a secure /ginvite
-- button, macro text, and even /ginvite put into the chat box by an addon. The
-- refusal shows up as "Interface action failed because of an addon" on every
-- attempt, so this addon makes none.
--
-- What is left is the player's own key press, which the client does accept: the
-- line copies "/ginvite First Surname" into a box with the text already
-- selected, and the player presses Ctrl+C, Enter, Ctrl+V, Enter. Nothing here
-- sends chat or calls the invite.

local INVITE_MENUS = { "PLAYER", "PARTY", "RAID_PLAYER", "RAID",
	"FRIEND", "CHAT_ROSTER", "COMMUNITIES_WOW_MEMBER", "RECENT_ALLY" }

local inviteHooked = false

-- A value the client hides from addons (a secret value): any test or comparison of
-- one errors, so nothing is read once one turns up.
local function Secret(...)
	if type(issecretvalue) ~= "function" then return false end
	for i = 1, select("#", ...) do
		if issecretvalue((select(i, ...))) then return true end
	end
	return false
end

-- The guild this character is in, or nil.
local function OwnGuild()
	if type(GetGuildInfo) ~= "function" then return nil end
	local ok, guild = pcall(GetGuildInfo, "player")
	if not ok or Secret(guild) then return nil end
	if type(guild) ~= "string" or guild == "" then return nil end
	return guild
end

-- THE NAME AN INVITE TAKES ON THIS CLIENT. WoW Forever's names are a first name
-- and a surname ("Faladoriel Skylance"), and its unit functions hand the surname
-- back where a realm would go: UnitFullName("player") gives "Faladoriel",
-- "Skylance". The server takes "First Surname" and refuses "Name-Realm"
-- ("No player named 'X-CAMWOWUS2Realm7PvE' is currently playing", measured on
-- Olympus launch night), so on a client that splits names the realm is never
-- appended and a "First-Surname" is read back as "First Surname".
local splitNames -- nil: not decided yet; false: names are "Name-Realm"
local function SplitNames()
	if splitNames ~= nil then return splitNames end
	splitNames = false
	local first, second
	if type(UnitFullName) == "function" then
		local ok
		ok, first, second = pcall(UnitFullName, "player")
		if not ok then first, second = nil, nil end
	end
	if Secret(first, second) then return false end
	if type(second) == "string" and second ~= "" then
		local home
		if type(GetRealmName) == "function" then
			local ok, r = pcall(GetRealmName)
			if ok then home = r end
		end
		-- the surname the client reports is not the realm: this client splits names
		if second ~= home then splitNames = true end
	end
	return splitNames
end

local function CleanName(name)
	if type(name) ~= "string" then return nil end
	name = name:gsub("^%s+", ""):gsub("%s+$", "")
	if name == "" then return nil end
	if SplitNames() then
		local first, surname = name:match("^(%S+)%-(%S+)$")
		if first then name = first .. " " .. surname end
	end
	return name
end

-- "First" + the client's second part ("Surname" on Forever, "Realm" elsewhere).
local function JoinName(first, second)
	if type(first) ~= "string" or first == "" then return nil end
	if type(second) ~= "string" or second == "" or first:find("-", 1, true) then
		return CleanName(first)
	end
	if SplitNames() and not first:find(" ", 1, true) then
		return CleanName(first .. " " .. second)
	end
	return CleanName(first .. "-" .. second)
end

-- Whether this character's rank is allowed to invite, as the client reports it.
local function CanInvite()
	if type(CanGuildInvite) == "function" then
		local ok, yes = pcall(CanGuildInvite)
		if ok then return yes and true or false end
	end
	return OwnGuild() ~= nil
end

--============================== the copy box ==================================
-- Since 1.60.1 no addon may invite, so the box does the one thing that is still
-- allowed and still useful: puts "/ginvite First Surname" on screen, already
-- selected, one Ctrl+C away. It sends no chat and calls no invite. Enter closes
-- the box and opens the game's own chat box (empty - an addon may not fill it),
-- the player pastes and presses Enter, and the client takes that key press.
local BOX_W, BOX_H = 340, 340   -- square: the art is a 512x512 picture, never squashed

local boxFrame, boxEdit, boxWho

local function BuildInviteBox()
	local f = CreateFrame("Frame", "OlympusRecruitInvite", UIParent)
	f:SetSize(BOX_W, BOX_H)
	f:SetPoint("CENTER", UIParent, "CENTER", 0, 40)
	f:SetFrameStrata("DIALOG")
	f:EnableMouse(true)
	f:SetMovable(true)
	f:SetClampedToScreen(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", f.StartMoving)
	f:SetScript("OnDragStop", f.StopMovingOrSizing)

	-- ONE flat picture, stretched by SetAllPoints only: no slicing on this client
	local art = f:CreateTexture(nil, "BACKGROUND")
	art:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
	art:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 0, 0)
	art:SetTexture(MEDIA .. "panel")
	f.art = art

	local glow = f:CreateTexture(nil, "ARTWORK")
	glow:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
	glow:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 0, 0)
	glow:SetTexture(MEDIA .. "glow")
	glow:SetBlendMode("ADD")
	glow:SetAlpha(0.08)
	f.glow = glow

	local title = f:CreateFontString(nil, "OVERLAY")
	title:SetFontObject("GameFontNormalLarge")
	title:SetPoint("TOP", f, "TOP", 0, -20)
	title:SetTextColor(GOLD[1], GOLD[2], GOLD[3])
	title:SetText("Guild invite")

	boxWho = f:CreateFontString(nil, "OVERLAY")
	boxWho:SetFontObject("GameFontHighlightSmall")
	boxWho:SetPoint("TOP", f, "TOP", 0, -42)
	boxWho:SetTextColor(DIM[1], DIM[2], DIM[3])
	boxWho:SetText("to your guild")

	local body = f:CreateFontString(nil, "OVERLAY")
	body:SetFontObject("GameFontHighlightSmall")
	body:SetPoint("TOP", f, "TOP", 0, -66)
	body:SetWidth(280)
	body:SetJustifyH("CENTER")
	body:SetTextColor(0.92, 0.88, 0.80)
	body:SetText("This client does not let an addon invite. The command is below, already "
		.. "selected - copy it and press it yourself.")

	local slot = Inset(f, 280, 28)
	slot:SetPoint("TOP", f, "TOP", 0, -128)

	local eb = CreateFrame("EditBox", "OlympusRecruitInviteCmd", slot)
	eb:SetSize(262, 22)
	eb:SetPoint("TOPLEFT", slot, "TOPLEFT", 9, -3)
	eb:SetAutoFocus(false)
	eb:SetMaxLetters(200)
	pcall(function() eb:SetTextInsets(0, 0, 0, 0) end)
	if not pcall(eb.SetFontObject, eb, "ChatFontNormal") then
		pcall(eb.SetFontObject, eb, "GameFontHighlightSmall")
	end
	pcall(function() eb:SetTextColor(GOLD[1], GOLD[2], GOLD[3]) end)
	boxEdit = eb

	Line(f, "GameFontHighlightSmall", 30, -166, 280, "CENTER", AMBER)
		:SetText("Ctrl+C        Enter        Ctrl+V        Enter")

	local note = f:CreateFontString(nil, "OVERLAY")
	note:SetFontObject("GameFontHighlightSmall")
	note:SetPoint("TOP", f, "TOP", 0, -186)
	note:SetWidth(280)
	note:SetJustifyH("CENTER")
	note:SetTextColor(DIM[1], DIM[2], DIM[3])
	note:SetText("Enter closes this and opens your chat box, unchanged and empty - "
		.. "the invite goes out from your own key press.")

	local again = Button(f, "Select the command", 150, 22)
	again:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 26, 30)
	again:SetScript("OnClick", function()
		if not boxEdit then return end
		pcall(boxEdit.HighlightText, boxEdit)
		pcall(boxEdit.SetFocus, boxEdit)
	end)

	local close = Button(f, "Close", 90, 22)
	close:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -26, 30)
	close:SetScript("OnClick", function() f:Hide() end)
	f.closeBox = close

	local hint = f:CreateFontString(nil, "OVERLAY")
	hint:SetFontObject("GameFontHighlightSmall")
	hint:SetPoint("BOTTOM", f, "BOTTOM", 0, 74)
	hint:SetJustifyH("CENTER")
	hint:SetTextColor(DIM[1], DIM[2], DIM[3])
	hint:SetText("the client also throttles guild invites to 10 a minute")

	eb:SetScript("OnEscapePressed", function(self)
		self:ClearFocus()
		f:Hide()
	end)
	eb:SetScript("OnEnterPressed", function(self)
		self:ClearFocus()
		f:Hide()
		-- opening the chat box is not a send and not a prefilled line; the player
		-- pastes into it, and that paste plus Enter is a real key press
		local opened = false
		if type(ChatFrame_OpenChat) == "function" then
			opened = pcall(ChatFrame_OpenChat, "")
		end
		if not opened then
			Say("now press Enter, then Ctrl+V, then Enter")
		end
	end)

	f:SetScript("OnShow", function()
		if boxEdit then
			pcall(boxEdit.HighlightText, boxEdit)
			pcall(boxEdit.SetFocus, boxEdit)
		end
	end)
	f:SetScript("OnUpdate", function(self)
		local t = GetTime()
		self.glow:SetAlpha(0.05 + 0.05 * math.abs(math.sin(t * 1.6)))
	end)
	pcall(function() table.insert(UISpecialFrames, "OlympusRecruitInvite") end)

	boxFrame = f
	return f
end

-- The one entry point: the right-click line and /om invite both come here.
local function InviteName(name)
	name = CleanName(name)
	if not name then
		Say("who?  /om invite <name>   -   or right-click the player")
		return false
	end
	local cmd = "/ginvite " .. name
	local f = boxFrame
	if not f then
		local ok = pcall(BuildInviteBox)
		f = ok and boxFrame or nil
	end
	if not f or not boxEdit then
		-- no editable box on this client: the command in chat is the whole help
		Say("invite " .. name .. ":   /ginvite " .. name)
		return false
	end
	boxWho:SetText("to " .. tostring(OwnGuild() or "your guild"))
	boxEdit:SetText(cmd)
	boxEdit:HighlightText()
	f:Show()
	pcall(boxEdit.SetFocus, boxEdit)
	Say("invite " .. name .. ": the command is in the box - Ctrl+C, Enter, Ctrl+V, Enter")
	return true
end

-- The player a menu is for, or nil when it is not one to invite: ourselves, an
-- offline name, a Battle.net friend (an account, not a character), anything the
-- client hides, or a unit that is not a player.
local function MenuTarget(ctx)
	if type(ctx) ~= "table" then return nil end
	if Secret(ctx.name, ctx.surname, ctx.server, ctx.unit,
		ctx.isSelf, ctx.isOffline, ctx.bnetIDAccount, ctx.isMobile) then return nil end
	if ctx.isSelf or ctx.isOffline or ctx.bnetIDAccount or ctx.isMobile then return nil end

	local name
	if type(ctx.unit) == "string" and ctx.unit ~= "" then
		local unit = ctx.unit
		local isPlayer = (type(UnitIsPlayer) ~= "function") or UnitIsPlayer(unit)
		local isMe = type(UnitIsUnit) == "function" and UnitIsUnit(unit, "player")
		local here = (type(UnitIsConnected) ~= "function") or UnitIsConnected(unit)
		if Secret(isPlayer, isMe, here) then return nil end
		if not isPlayer or isMe or not here then return nil end
		local first, second
		if type(UnitFullName) == "function" then first, second = UnitFullName(unit) end
		if (type(first) ~= "string" or first == "") and type(UnitName) == "function" then
			first = UnitName(unit)
		end
		if type(first) ~= "string" or first == "" then return nil end
		-- Forever hands the surname back where a realm would go: JoinName reads it
		-- as "First Surname", never "First-Surname" or "Name-Realm"
		name = JoinName(first, second)
	else
		local raw = ctx.name
		if type(raw) ~= "string" or raw == "" then return nil end
		-- a chat name arrives as "Name" plus the rest apart; a name already whole
		-- ("First Surname", "Name-Realm") comes back as JoinName left it
		name = JoinName(raw, ctx.server or ctx.surname)
	end
	if type(name) ~= "string" or name == "" then return nil end
	return name
end

-- One line, on the menu the game has just built. No guild, no permission or no
-- player means no line at all - never a dead entry.
local function MenuBuild(root, ctx)
	local guild = OwnGuild()
	if not guild or not CanInvite() then return end
	if not root or type(root.CreateButton) ~= "function" then return end
	local name = MenuTarget(ctx)
	if not name then return end
	pcall(root.CreateDivider, root)
	local d = root:CreateButton("Invite to " .. guild, function()
		InviteName(name)
	end)
	if type(d) == "table" or type(d) == "userdata" then
		if type(d.SetTooltip) == "function" then
			pcall(d.SetTooltip, d, function(tooltip)
				if not (tooltip and tooltip.AddLine) then return end
				tooltip:AddLine("Guild invite", 1, 0.82, 0)
				tooltip:AddLine("Shows /ginvite " .. name .. " ready to copy: this client takes no invite from an addon.",
					1, 1, 1, true)
			end)
		end
	end
end

-- The gamepad player menu runs protected interact-target state while it is being
-- built, so nothing is registered in that input mode; switching back to mouse and
-- keyboard registers it then.
local function GamepadUI()
	local current = C_InputInterfaceStyle and C_InputInterfaceStyle.GetCurrentStyle
	local gamepad = Enum and Enum.InputDeviceInterfaceType and Enum.InputDeviceInterfaceType.Gamepad
	if not current or gamepad == nil then return false end
	local ok, style = pcall(current)
	return ok and style == gamepad
end

local function HookGuildMenus(quiet)
	if inviteHooked then return true end
	if not (Menu and type(Menu.ModifyMenu) == "function") then
		if not quiet then
			Say("this client has no Menu.ModifyMenu, so no right-click line - /om invite <name> still works")
		end
		return false
	end
	if GamepadUI() then
		if not quiet then
			Say("the gamepad UI is on - the right-click line waits until you switch back to mouse and keyboard")
		end
		return false
	end
	for i = 1, #INVITE_MENUS do
		local which = INVITE_MENUS[i]
		local ok, err = pcall(Menu.ModifyMenu, "MENU_UNIT_" .. which, function(_, root, ctx)
			pcall(MenuBuild, root, ctx)
		end)
		if not ok and not quiet then
			Say("menu " .. which .. " not hooked: " .. tostring(err))
		end
	end
	inviteHooked = true
	return true
end

frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("CHAT_MSG_CHANNEL")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
-- the right-click invite line: the player menus exist once the game is up, so the
-- hook waits for PLAYER_LOGIN, and for a switch back from the gamepad UI.
pcall(function()
	frame:RegisterEvent("PLAYER_LOGIN")
	frame:RegisterEvent("INPUT_DEVICE_INTERFACE_TRANSITION")
end)
-- the client's own complaint about us ("Interface action failed because of an
-- addon", i.e. a blocked action). Captured so it can be named, not guessed.
pcall(function()
	frame:RegisterEvent("ADDON_ACTION_BLOCKED")
	frame:RegisterEvent("ADDON_ACTION_FORBIDDEN")
end)
frame:SetScript("OnEvent", function(_, event, ...)
	if event == "ADDON_ACTION_BLOCKED" or event == "ADDON_ACTION_FORBIDDEN" then
		local addon, fn = ...
		lastBlock = tostring(fn or "?") .. " (" .. tostring(addon or "?") .. ")"
		local who = tostring(addon or "?")
		if not blockSaid[who] then
			blockSaid[who] = true
			if addon == "OlympusRecruit" or addon == "OlympusMytikas" then
				Say("the client blocked " .. lastBlock .. " - that is the 'Interface action failed' line")
				Say("this client only allows a channel post inside a real click or key press")
			else
				Say("the client blocked " .. lastBlock .. " - that is NOT this addon")
				Say("something else is doing it")
			end
		end
		return
	end
	if event == "CHAT_MSG_CHANNEL" then
		-- our own post comes back through here; that is the only proof it landed
		local text = ...
		if pending and pending.texts[text] then
			pending.seen = pending.seen + 1
		end
		return
	end
	if event == "PLAYER_LOGIN" or event == "INPUT_DEVICE_INTERFACE_TRANSITION" then
		-- the right-click "Invite to <guild>" line in the game's player menus
		pcall(HookGuildMenus, true)
		return
	end
	if event == "PLAYER_ENTERING_WORLD" then
		-- NOTHING HERE TOUCHES THE CHANNELS. Not one join, not one leave, not one
		-- slot read. This client only allows a channel action inside a real key
		-- press or click, so the joins that used to run from this event were
		-- refused - and joining a channel the client was still restoring is what
		-- looked like the addon leaving and rejoining /1 and /2 on every login.
		return
	end
	if event ~= "ADDON_LOADED" then return end
	local addon = ...
	if addon ~= "OlympusRecruit" and addon ~= "OlympusMytikas" then return end
	local db = EnsureDB()
	-- the minimap button, unless the player switched it off with /om minimap
	if db.minimap ~= false and not OlympusMytikasLoaded then pcall(ShowMapButton, true) end
	Say("loaded - " .. #Pool() .. " ads ready for /1 and /2. /om to post, /om ui for the window.")
end)
local function Help()
	Say("/om ui - open the window; type your own ad in the box there")
	Say("/om - post a random ad to /1 General and /2 Trade")
	Say("/om list | pick <n> | test")
	Say("/om add <text> | del <n> | reset")
	Say("/om invite <name> - the guild invite command, ready to copy")
	Say("/om why - what the client last blocked")
	Say("/om minimap - minimap button on/off")
	Say("/om profile - which character the settings belong to")
	Say("right-click a player's portrait or a name in chat: Invite to <guild>")
	Say("1.60.1 forbids addon guild invites: that line copies /ginvite for you to press")
	Say("posts always go to /1 and /2 - no channel is joined, left or moved")
	Say("no auto-post: this client only posts on a click or key press")
end
local function Handle(msg)
	msg = tostring(msg or ""):gsub("^%s+", ""):gsub("%s+$", "")
	local cmd, rest = msg:match("^(%S*)%s*(.-)$")
	cmd = string.lower(cmd or "")
	local db = EnsureDB()

	if cmd == "" or cmd == "post" then
		PostAll()

	elseif cmd == "list" then
		local pool = Pool()
		Say(#pool .. " ads in the pool:")
		for i = 1, #pool do
			Say("  " .. i .. ". " .. pool[i])
		end

	elseif cmd == "pick" or cmd == "next" then
		local n = tonumber(rest)
		if not n then
			Say("usage: /om pick <number>")
		elseif not Pool()[n] then
			Say("there is no ad " .. n .. " (pool has " .. #Pool() .. ")")
		else
			PostAll(n)
		end

	elseif cmd == "test" then
		local idx, ad = Pick()
		Say("next ad " .. tostring(idx) .. ": " .. tostring(ad))
		Say("it would go to /1 General and /2 Trade in one pass - nothing sent")

	elseif cmd == "auto" or cmd == "on" or cmd == "off" or cmd == "interval" then
		-- the loop is gone on purpose: no timer send works on this client. Drop the
		-- old saved keys so an existing profile stops carrying them.
		db.auto, db.interval = nil, nil
		Say("there is no auto-post any more: this client refuses a channel send from a timer")
		Say("post from the window, the minimap right click, your keybind, or /om")

	elseif cmd == "ui" or cmd == "window" then
		ToggleUI()

	elseif cmd == "minimap" then
		local on
		if OlympusMytikasLoaded then
			on = not OlympusMytikasDB.minimap
			if type(OlympusMytikas_Minimap) == "function" then OlympusMytikas_Minimap(on) end
		else
			on = (db.minimap == false)   -- toggle: off -> on
			ShowMapButton(on)
		end
		db.minimap = on
		Say("minimap button: " .. (on and "ON" or "OFF"))

	elseif cmd == "invite" or cmd == "ginvite" then
		if rest == "" then
			local hooked = HookGuildMenus(false)
			local guild = OwnGuild()
			Say("right-click a player's portrait or a name in chat: \"Invite to "
				.. tostring(guild or "your guild") .. "\"")
			Say("  menus hooked: " .. (hooked and "yes" or "no")
				.. "   can invite: " .. (CanInvite() and "yes" or "no - this rank cannot invite"))
			Say("  1.60.1 takes no invite from an addon: the line shows /ginvite, you press it")
			Say("  /om invite <name> shows the command for that name now")
		else
			InviteName(rest)
		end

	elseif cmd == "why" or cmd == "diag" then
		Say("posts go to /1 General and /2 Trade, both in one pass")
		Say("auto-post: removed - this client only posts inside a click or a key press")
		Say("right-click invite line: " .. (inviteHooked and "hooked" or "not hooked")
			.. "   guild: " .. tostring(OwnGuild() or "none"))
		Say("last blocked action: " .. (lastBlock or "none this session"))

	elseif cmd == "add" then
		if rest == "" then
			Say("usage: /om add <ad text>  - or type it in the box in /om ui")
		else
			local n, tagged = AddAd(rest)
			if not n then
				Say("not added: " .. tostring(tagged))
			else
				Say("added as ad " .. n .. " (" .. #Pool() .. " in pool)"
					.. (tagged and " - it now starts with <Olympus Mytikas>" or ""))
			end
		end

	elseif cmd == "del" or cmd == "delete" then
		local n = tonumber(rest)
		if not n then
			Say("usage: /om del <number from /om list>")
		else
			local ok, why = DelAd(n)
			if ok then
				Say("deleted. " .. #Pool() .. " left in pool.")
			else
				Say(why)
			end
		end

	elseif cmd == "reset" then
		-- per character: this character goes back to defaults. Every other
		-- character keeps its own settings.
		local d = EnsureDB()
		d.custom = {}
		d.lastPick = 0
		d.minimap = true
		d.minimapAngle = DEFAULTS.minimapAngle
		Say("wiped - this character is back to defaults, custom ads gone")
		Say("posts still go to /1 General and /2 Trade")

	elseif cmd == "profile" or cmd == "char" then
		local d = EnsureDB()
		local key = CharKey()
		Say("character: " .. tostring(key or "no name yet")
			.. (key and "" or " - using the account settings until the name is known"))
		Say("  minimap " .. tostring(d.minimap ~= false) .. "   ads are shared by the account ("
			.. #Pool() .. " in the pool)")
		Say("  posts go to /1 General and /2 Trade - nothing joins, leaves or moves a channel")
		Say("  blocked this session: " .. tostring(lastBlock or "nothing"))

	else
		Help()
	end
end
SlashCmdList["OLYMPUSRECRUIT"] = Handle
SLASH_OLYMPUSRECRUIT1 = "/om"
SLASH_OLYMPUSRECRUIT2 = "/olympus"

-- keybind labels
_G["BINDING_HEADER_OLYMPUSRECRUIT"] = "Olympus Recruit"
_G["BINDING_NAME_OLYMPUSRECRUIT_POST"] = "Post a recruitment ad"
_G["BINDING_NAME_OLYMPUSRECRUIT_UI"] = "Open the Olympus Recruit window"
