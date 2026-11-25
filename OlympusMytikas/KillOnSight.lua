-- Kill on Sight (KoS) - a guild kill list with bounties owed on trust.
--
-- THE RULE THIS ADDON ENFORCES
--   A bounty is LIVE the moment a member asks for it - no waiting for a bank run. Every bounty is 1g.
--   The requester owes that 1g to the guild bank; the addon keeps the log of who owes what and a
--   manager clears it with /kos paidup <name>. On the kill the bank keeps 30% (30s) and the hunter's
--   70% (70s) joins ONE prize pool for the month; the top hunter wins the whole pool. A human still
--   pays the prize - the addon never moves gold.
--
-- WHAT IT DOES
--   * An enemy player who kills you is added to the guild board automatically (name, class, level,
--     layer, moment) and the death is shared with the guild.
--   * The board is shared live with every guildmate running the addon over the guild addon channel.
--   * Anyone who kills a live target gets the claim recorded; the 70% share joins the month's pool.
--   * Right-click a name (or /kos fund <name>) makes the bounty live at once. /kos owed shows both
--     what members owe the bank and what the bank owes; /kos paidup clears a member's debt.
--
-- WHAT THIS CLIENT ALLOWS (verified against Forever 1.60.1, interface 16001)
--   * The combat-log event is RESTRICTED here: registering it throws "Interface action
--     failed because of an addon" at every login (Olympus\Wanted.lua:6842-6846 has the taint line).
--     It is never registered.
--   * A death is read from the client's own death recap: PLAYER_DEAD, then
--     C_DeathRecap.HasRecapEvents() / GetRecapEvents(), the rows the game's Death Recap shows; the
--     killing blow is the first row with overkill >= 0. The recap can land after PLAYER_DEAD, so it
--     is retried at 0.3/1/2/4/8 s for that death only, and a 2 s watch asks the same question in
--     case this build raises no PLAYER_DEAD at all. /kos recap dumps exactly what the client gave.
--   * Your own killing blow is the native PARTY_KILL event: (attackerGUID, targetGUID).
--   * Only the victim's own client can prove his death, so every member's client shares its own
--     deaths and the board is the union everyone admitted.
--   * SendChatMessage is BLOCKED outside a real key press or click here (ADDON_ACTION_BLOCKED;
--     Olympus\ChatHall.lua:61-74 quotes the dev's 2026-11-06 log, GitHub #79/#85). So no silent
--     auto-post to guild chat: the line goes out on your click or typed command, and if the client
--     still refuses it the chat box opens with the line ready for one Enter.
--   * Addon messages ARE allowed from timers: C_ChatInfo.SendAddonMessage(PREFIX, msg, "GUILD"),
--     255 bytes a part, sender at arg 4 of CHAT_MSG_ADDON. That carries the board.
--   * The guild bank is readable, but a bounty no longer waits for a deposit: bounties run on trust
--     and the addon only records who owes what. An addon can never MOVE gold - a deposit or a
--     withdrawal needs the bank frame and a real click - so a human still moves the money.
--   * There is no layer API. Like LayerSwap, the layer is read from a nearby creature's GUID
--     (Creature-0-<server>-<map>-...); the numeric <server> part identifies the layer on Forever.
--
-- Identity: a listed player is his GUID ("Player-<server>-<hex>"); the name is only a label. A kill
-- counts only when the killing blow is a real hostile player: the event ends in _DAMAGE, sourceFlags
-- carries 0x400 (hostile) and 0x40 (player), and the GUID is a Player- one. A pet, an NPC, the
-- environment, a battleground or an arena never count (instances ignored by default).
-- Everything the client does not always give - a float timestamp, a missing event or flag mask, a
-- GUID shape this addon cannot parse - is tolerated: not knowing a detail is never proof that no
-- player killed you. Only a detail that is present AND says otherwise refuses the death.

local ADDON, ns = ...
ns.PREFIX = "KOS"
ns.VERSION = "1.5.4"

-- Kill/death notices are kept here instead of sprayed into chat. /kos chat replays them.
ns.chatLog = {}
ns.CHAT_LOG_MAX = 50

-- The merged Olympus Mytikas window owns the on/off switch. Running this addon on its
-- own always leaves it enabled. One function is used by every event, ticker and command.
ns.Enabled = function()
	if OlympusMytikasLoaded then return OlympusMytikasDB.kosEnabled ~= false end
	return true
end

local PREFIX = ns.PREFIX
local DEATH_WINDOW = 5
local MSG_MAX = 250
local CHUNK = 210
local SEND_INTERVAL = 1.2
local RETRY_WAIT = { 2, 4, 8, 15, 30 }
local HELLO_EVERY = 600
local MAX_ENTRIES = 120
local MAX_TOMBSTONES = 200
local MAX_VICTIMS = 6
local MAX_CLAIMS = 6
local MAX_QUEUE = 300
local MAX_NAME = 40
local MAX_REASON = 70
local DEFAULT_REWARD = 10000        -- copper: 1g, what every bounty asks for
local DEFAULT_CUT = 30              -- percent the bank keeps from a bounty (the other 70% is pooled)
local REFUND_DAYS = 7               -- an unclaimed bounty goes back to its payer after this long
local OFFICER_REMIND = 900          -- seconds between "the bank still owes" reminders in chat
local OFFICER_LIST = 3              -- payments named in one officer-chat line before "+N more"
local SPOT_GRID = 1000              -- a last-known map point is shared in tenths of a percent
local PIN_TTL = 1800                -- map pins retire 30 minutes after the last sighting
local LAYER_TTL = 3600              -- a layer reading is only true for this long; then it is unknown

-- One table holds the map helpers and the map-pin state. Lua 5.1 gives the main chunk only 200
-- local slots; separate locals for every helper pushed this file past that ceiling.
local MapLib = {}
MapLib.pinDirty = true
MapLib.pinPool = {}
MapLib.active = {}
MapLib.pinArt = "Interface\\AddOns\\OlympusMytikas\\Media\\bounty"
MapLib.showFlag = (type(HBD_PINS_WORLDMAP_SHOW_CONTINENT) == "number"
	and HBD_PINS_WORLDMAP_SHOW_CONTINENT) or 2
MapLib.pinCount = 0
MapLib.worldCount = 0

-- One table holds the monthly-board helpers: Lua 5.1 gives the main chunk only 200 local slots.
local Board = {}
MapLib.miniCount = 0

-- ============================================================================ small helpers

local function Secret(...)
	if type(issecretvalue) ~= "function" then return false end
	for i = 1, select("#", ...) do
		local ok, yes = pcall(issecretvalue, (select(i, ...)))
		if not ok or yes then return true end
	end
	return false
end

local function Ask(fn, ...)
	if type(fn) ~= "function" then return nil end
	local ok, v = pcall(fn, ...)
	if not ok or Secret(v) then return nil end
	return v
end

local function Num(v, lo, hi)
	if v == nil or Secret(v) then return nil end
	local ok, n = pcall(tonumber, v)
	if not ok or type(n) ~= "number" or n ~= n then return nil end
	if n ~= math.floor(n) or n < lo or n > hi then return nil end
	return n
end

local function Plain(s)
	if type(s) ~= "string" then return nil end
	return (s:gsub("[|%c]", ""))
end

local function Clean(s, max)
	s = Plain(tostring(s or ""))
	if not s then return "" end
	s = s:gsub("[~,;@]", " ")
	s = s:gsub("%s+", " ")
	s = s:match("^%s*(.-)%s*$") or ""
	if max and #s > max then s = s:sub(1, max) end
	return s
end

local function HasBit(v, b)
	if type(v) ~= "number" then return false end
	return math.floor(v / b) % 2 == 1
end

local function Clock()
	return math.floor(tonumber(Ask(GetServerTime) or Ask(time)) or 0)
end

-- The leaderboard month comes from server time in UTC, so every guildmate agrees where a month
-- ends even when a PC clock is wrong. A guarded fallback keeps an odd client from breaking onboard.
function Board.BoardMonth(at)
	at = math.floor(tonumber(at) or 0)
	if at > 0 and type(os) == "table" and type(os.date) == "function" then
		local ok, value = pcall(os.date, "!%Y-%m", at)
		if ok and type(value) == "string" and value:match("^%d%d%d%d%-%d%d$") then return value end
	end
	return "unknown"
end

local function Mono() return (Ask(GetTime) or 0) end

local function Money(copper)
	copper = math.floor(tonumber(copper) or 0)
	if copper <= 0 then return "0g" end
	local g = math.floor(copper / 10000)
	local s = math.floor((copper % 10000) / 100)
	local c = copper % 100
	if g > 0 and s > 0 then return ("%dg %ds"):format(g, s) end
	if g > 0 then return ("%dg"):format(g) end
	if s > 0 then return ("%ds"):format(s) end
	return ("%dc"):format(c)
end

local function Left(seconds)
	seconds = math.max(0, math.floor(tonumber(seconds) or 0))
	local d = math.floor(seconds / 86400)
	local h = math.floor((seconds % 86400) / 3600)
	local m = math.floor((seconds % 3600) / 60)
	if d > 0 then return ("%dd %dh"):format(d, h) end
	if h > 0 then return ("%dh %dm"):format(h, m) end
	return ("%dm"):format(math.max(1, m))
end

local COLORS = {
	WARRIOR = "c79c6e", PALADIN = "f58cba", HUNTER = "abd473", ROGUE = "fff569",
	PRIEST = "ffffff", DEATHKNIGHT = "c41f3b", SHAMAN = "0070de", MAGE = "69ccf0",
	WARLOCK = "9482c9", MONK = "00ff96", DRUID = "ff7d0a", DEMONHUNTER = "a330c9",
	EVOKER = "33937f",
}

local function ClassCode(name)
	if type(name) ~= "string" then return "" end
	local code = name:upper():gsub("[^A-Z]", "")
	if COLORS[code] then return code end
	return ""
end

local function ClassColor(entry)
	local hex = COLORS[entry and entry.class or ""] or "ffd100"
	return "|cff" .. hex
end

local function RawSay(text)
	if type(DEFAULT_CHAT_FRAME) == "table" and DEFAULT_CHAT_FRAME.AddMessage then
		DEFAULT_CHAT_FRAME:AddMessage("|cffbe5720[KoS]|r " .. text)
	end
end

local function Say(fmt, ...)
	local text = select("#", ...) > 0 and fmt:format(...) or fmt
	RawSay(text)
end

-- A death or bounty notice is history, not a command reply: store it and stay quiet.
local function Notice(fmt, ...)
	local text = select("#", ...) > 0 and fmt:format(...) or fmt
	ns.chatLog[#ns.chatLog + 1] = text
	if #ns.chatLog > ns.CHAT_LOG_MAX then table.remove(ns.chatLog, 1) end
end

local function Realm()
	local r = Ask(GetNormalizedRealmName) or Ask(GetRealmName) or "?"
	if type(r) ~= "string" or r == "" then return "?" end
	return (r:gsub("[%s%-]", ""))
end

local function GroupOf(realm)
	local rules = type(realm) == "string" and realm:match("^CAMWOW%u%u%d+Realm%d+(%a+)$")
	if rules then return "CAMWOW" .. rules end
	return realm or "?"
end

local function Faction()
	local f = Ask(UnitFactionGroup, "player")
	if f == "Horde" or f == "Alliance" then return f end
	return "?"
end

local function Scope()
	return GroupOf(Realm()) .. "|" .. Faction()
end

local function Guid(guid)
	if Secret(guid) then return nil end
	if type(guid) ~= "string" or #guid > 64 then return nil end
	local server, id = guid:match("^Player%-(%d+)%-(%x+)$")
	-- (no upper bound on the id: this server's ids are not guaranteed to be 16 hex digits, and a
	-- longer one is still the same player.)
	if not server or #id < 8 then return nil end
	return "Player-" .. server .. "-" .. id:upper()
end

local function NameFromGUID(guid)
	local ok, _, _, _, _, _, name, realm = pcall(GetPlayerInfoByGUID, guid)
	if not ok or type(name) ~= "string" or name == "" then return nil end
	if Secret(name, realm) then return nil end
	name = Clean(name, MAX_NAME)
	if type(realm) == "string" and realm ~= "" and realm:find("%a")
		and not realm:match("^CAMWOW") and realm:lower() ~= (Ask(GetRealmName) or ""):lower() then
		name = Clean(name .. " " .. realm, MAX_NAME)
	end
	return name ~= "" and name or nil
end

local function ClassFromGUID(guid)
	local ok, _, english = pcall(GetPlayerInfoByGUID, guid)
	if not ok or type(english) ~= "string" or Secret(english) then return nil end
	local code = ClassCode(english)
	return code ~= "" and code or nil
end

local function SameName(a, b)
	a, b = Plain(a), Plain(b)
	if type(a) ~= "string" or type(b) ~= "string" then return false end
	a, b = a:lower():gsub("%-", " "), b:lower():gsub("%-", " ")
	a, b = a:gsub("%s+", " "), b:gsub("%s+", " ")
	return a == b or a:match("^(%S+)") == b:match("^(%S+)")
end

local function Units()
	local list = { "player", "target", "focus", "mouseover", "party1", "party2", "party3", "party4" }
	for i = 1, 40 do list[#list + 1] = "nameplate" .. i end
	return list
end

local function GuidForName(name)
	for _, unit in ipairs(Units()) do
		if Ask(UnitIsPlayer, unit) then
			local shown = Ask(UnitFullName, unit) or Ask(UnitName, unit)
			if SameName(shown, name) then
				local guid = Guid(Ask(UnitGUID, unit))
				if guid then return guid end
			end
		end
	end
	return nil
end

local function MyName()
	local name = Ask(UnitFullName, "player") or Ask(UnitName, "player")
	if type(name) == "string" and name ~= "" then return Clean(name, MAX_NAME) end
	return "someone"
end

-- Only the guild master and the Valar rank may remove rows or clear what the bank owes. Everybody
-- else can still add a name, fund a bounty, announce it and read the board. These live on Board
-- rather than as more top-level locals (Lua 5.1's main chunk is at its 200-local ceiling).
Board.MANAGER_RANK = "Valar"
Board.DENIED = "only the guild master or " .. Board.MANAGER_RANK ..
	" can remove entries or clear what the bank owes"

Board.RankOf = function(name)
	if type(name) ~= "string" or name == "" then return nil end
	if type(GetNumGuildMembers) ~= "function" or type(GetGuildRosterInfo) ~= "function" then return nil end
	local ok, count = pcall(GetNumGuildMembers)
	if not ok or Secret(count) then return nil end
	count = tonumber(count)
	if not count or count < 1 or count > 5000 then return nil end
	for i = 1, count do
		local good, member, rankName, rankIndex = pcall(GetGuildRosterInfo, i)
		if good and not Secret(member, rankName, rankIndex) and SameName(member, name) then
			return rankName, tonumber(rankIndex)
		end
	end
	return nil
end

-- With no name this checks this character; with a sender name it checks that sender's guild rank.
-- Anything unreadable fails closed.
Board.CanManage = function(name)
	if name and name ~= "" and not SameName(name, MyName()) then
		local rankName, rankIndex = Board.RankOf(name)
		if not rankName and not rankIndex then return false end
		if rankIndex == 0 then return true end
		return type(rankName) == "string" and rankName:lower() == Board.MANAGER_RANK:lower()
	end
	if type(GetGuildInfo) ~= "function" then return false end
	local ok, _, rankName, rankIndex = pcall(GetGuildInfo, "player")
	if not ok or Secret(rankName, rankIndex) then return false end
	rankIndex = tonumber(rankIndex)
	if rankIndex == 0 then return true end
	return type(rankName) == "string" and rankName:lower() == Board.MANAGER_RANK:lower()
end

-- ============================================================================ saved data

local db
local clock = 0

local DEFAULTS = {
	defaultReward = DEFAULT_REWARD,
	cutPercent = DEFAULT_CUT,
	refundDays = REFUND_DAYS,
	officerMode = "auto",
	ignoreInstances = true,
	share = true,
	notices = true,
	warnNearby = true,
	minimap = true,
	minimapAngle = 210,
}

local function Init()
	if type(KillOnSightDB) ~= "table" then KillOnSightDB = {} end
	db = KillOnSightDB
	for k, v in pairs(DEFAULTS) do
		if db[k] == nil then db[k] = v end
	end
	-- The old saved toggle is gone. The guild master and Valar are the only board authorities;
	-- keeping a stale flag would only make an old profile look like it still does something.
	db.master = nil
	-- One-time move to the new terms: a 30% bank cut and a 3g ask. Deliberately custom values
	-- (anything other than the old defaults) are left alone. The v147 flag puts back a profile
	-- that briefly saw the discarded 40% cut.
	if not db.v140Migrated then
		if tonumber(db.cutPercent) == 10 then db.cutPercent = 30 end
		if tonumber(db.defaultReward) == 50000 then db.defaultReward = 30000 end
		db.v140Migrated = true
	end
	if not db.v147Migrated then
		if tonumber(db.cutPercent) == 40 then db.cutPercent = 30 end
		db.v147Migrated = true
	end
	if type(db.scopes) ~= "table" then db.scopes = {} end
	if type(db.bank) ~= "table" then db.bank = {} end
	-- 1.2.0: flat 1g bounties, live on request. Old 3g asks move to 1g; a previously pending job
	-- keeps its name on the board but is no longer a half-state, and any live bounty now records a
	-- debt owed by the requester until a manager marks it paid.
	if not db.v120Migrated then
		if tonumber(db.defaultReward) == 30000 then db.defaultReward = 10000 end
		for _, scope in pairs(db.scopes) do
			for _, e in pairs(type(scope) == "table" and scope.entries or {}) do
				e.job = nil
				if not e.paid and not e.refunded then
					e.want = DEFAULT_REWARD
					if (tonumber(e.funded) or 0) > 0 then
						e.funded = DEFAULT_REWARD
						e.paidUp = false
					end
				end
			end
		end
		db.v120Migrated = true
	end
	-- One-time move to a flat ask: every bounty is 3g, with no +5g for further kills.
	if not db.v146Migrated then
		db.killBonus = 0 -- left in old profiles only; never read again
		local ask = tonumber(db.defaultReward) or DEFAULT_REWARD
		for _, scope in pairs(db.scopes) do
			for _, e in pairs(type(scope) == "table" and scope.entries or {}) do
				if (tonumber(e.kills) or 0) > 1 and not e.paid and not e.refunded then
					e.want = math.max(ask, tonumber(e.funded) or 0)
				end
			end
		end
		db.v146Migrated = true
	end
	-- An old guildmate can replay a row with a 3g ask long after the one-time migration has run.
	-- Keep the flat 1g rule on EVERY load, so a stale synced row can never put the old price back.
	for _, scope in pairs(db.scopes) do
		for _, e in pairs(type(scope) == "table" and scope.entries or {}) do
			if (tonumber(e.want) or 0) > DEFAULT_REWARD then e.want = DEFAULT_REWARD end
			if (tonumber(e.funded) or 0) > DEFAULT_REWARD and not e.paid and not e.refunded then
				e.funded = DEFAULT_REWARD
			end
		end
	end
	clock = tonumber(db.clock) or 0
	return db
end

local function DB()
	if not db then Init() end
	return db
end

-- Defined here, after DB and MapLib exist, so the shell's button can stop every
-- part of KoS without the addon throwing on a not-yet-declared helper.
ns.SetEnabled = function(on)
	on = on and true or false
	if OlympusMytikasLoaded then
		OlympusMytikasDB.kosEnabled = on
	else
		DB().kosEnabled = on
	end
	ns.warned = {}
	MapLib.pinDirty = true
	if not on then pcall(MapLib.Release, nil) end
	return on
end

local function Store()
	local d = DB()
	local scope = Scope()
	local s = d.scopes[scope]
	if type(s) ~= "table" then
		s = { entries = {}, removed = {}, ver = 1 }
		d.scopes[scope] = s
	end
	if type(s.entries) ~= "table" then s.entries = {} end
	if type(s.removed) ~= "table" then s.removed = {} end
	if type(s.deaths) ~= "table" then s.deaths = {} end
	if type(s.audit) ~= "table" then s.audit = {} end
	if type(s.bank) ~= "table" then
		s.bank = { escrowed = 0, paid = 0, cut = 0, pool = 0, refunded = 0, float = 0, at = 0 }
	end
	if type(s.bank.pool) ~= "number" then s.bank.pool = 0 end
	if type(s.board) ~= "table" then s.board = {} end
	if type(s.board.ledger) ~= "table" then s.board.ledger = {} end
	if type(s.board.history) ~= "table" then s.board.history = {} end
	if type(s.board.award) ~= "table" then s.board.award = {} end
	s.board.month = type(s.board.month) == "string" and s.board.month or ""
	return s
end

local function Bump(entry)
	clock = clock + 1
	entry.stamp = clock
	DB().clock = clock
	MapLib.pinDirty = true
	-- A funding, removal or sync can change "is this nearby player wanted?" without any
	-- nameplate event firing. Reconcile now instead of waiting up to half a second.
	if ns.RefreshMarks then pcall(ns.RefreshMarks) end
end

local function Observe(stamp)
	stamp = tonumber(stamp)
	if stamp and stamp > clock then
		clock = math.floor(stamp)
		DB().clock = clock
	end
end

local function Entry(guid)
	if not guid then return nil end
	local e = Store().entries[guid]
	if type(e) == "table" and e.guid then return e end
	return nil
end

local function AddUnique(list, value, max)
	if type(list) ~= "table" or type(value) ~= "string" or value == "" then return end
	for i = 1, #list do if list[i] == value then return end end
	list[#list + 1] = value
	while #list > (max or 8) do table.remove(list, 1) end
end

local function AddClaim(entry, name, at)
	name = Clean(name, MAX_NAME)
	if name == "" then return false end
	for i = 1, #entry.claims do
		if entry.claims[i].name == name then
			entry.claims[i].at = at
			return false
		end
	end
	entry.claims[#entry.claims + 1] = { name = name, at = at }
	while #entry.claims > MAX_CLAIMS do table.remove(entry.claims, 1) end
	return true
end

local function Trim()
	local s = Store()
	local count, oldest, oldestAt = 0, nil, nil
	for guid, e in pairs(s.entries) do
		count = count + 1
		if not e.paid and (tonumber(e.funded) or 0) == 0 then
			local at = tonumber(e.at) or 0
			if not oldestAt or at < oldestAt then oldest, oldestAt = guid, at end
		end
	end
	if count > MAX_ENTRIES and oldest then
		-- Keep the prune tombstone ahead of the row's own birth stamp, or an old copy could
		-- walk straight back onto the board.
		clock = clock + 1
		DB().clock = clock
		s.removed[oldest] = clock
		s.entries[oldest] = nil
	end
	local removed, seen = {}, 0
	for guid in pairs(s.removed) do seen = seen + 1 removed[#removed + 1] = guid end
	if seen > MAX_TOMBSTONES then
		table.sort(removed)
		for i = 1, seen - MAX_TOMBSTONES do s.removed[removed[i]] = nil end
	end
end

-- ============================================================================ bounty arithmetic

local function CutOf(funded)
	local pct = math.max(0, math.min(50, tonumber(DB().cutPercent) or 0))
	return math.floor((tonumber(funded) or 0) * pct / 100)
end

-- The hunter's 70% is not paid when the kill happens: it joins this month's one prize pool.
-- The name is kept so old profiles and diagnostics still read the same way.
local function PayoutOf(funded)
	funded = math.floor(tonumber(funded) or 0)
	return funded - CutOf(funded)
end

-- When an unclaimed bounty has to go back. A claim stops the clock: the money is owed to the killer
-- from then on, and only a human paying him (or /kos refund) settles it. Once the refund is decided
-- it has no clock left: it waits for a human, not for a date.
local function RefundDue(e)
	if not e or e.paid or e.refunded or e.refundDue then return nil end
	if (tonumber(e.funded) or 0) <= 0 then return nil end
	if e.claims and #e.claims > 0 then return nil end
	local days = tonumber(e.refundDays) or tonumber(DB().refundDays) or 0
	if days <= 0 then return nil end
	local at = tonumber(e.fundedAt) or 0
	local now = Clock()
	if at <= 0 or now <= 0 then return nil end
	if at > now + 120 then return nil end -- a clock that disagrees with the server proves nothing
	return at + days * 86400
end

-- live / claimed / paid / refund due / refunded / unfunded. There is no pending half-state any
-- more: a request makes the bounty live at once, and a plain death with no request stays unfunded.
local function StateOf(e)
	if not e then return "unfunded" end
	if e.paid then return "paid" end
	if e.refunded then return "refunded" end
	if e.refundDue then return "refunddue" end
	local funded = tonumber(e.funded) or 0
	if funded <= 0 then return "unfunded" end
	if e.claims and #e.claims > 0 then return "claimed" end
	return "live"
end

local function StateText(e)
	local state = StateOf(e)
	if state == "paid" then return "in prize pool" end
	if state == "refunded" then return "handed back" end
	if state == "refunddue" then return "refund due" end
	if state == "claimed" then return "claimed" end
	if state == "live" then return "bounty" end
	return "no bounty"
end

-- ============================================================================ wire format

-- E rows carry the money and the trust state as they are: funded > 0 means a member asked for a live
-- bounty, and field 23 says whether a manager has cleared that member's debt. A plain name (funded =
-- 0) reaches every client as a name only, so nobody can see a payable bounty that was not requested.
local function RowFor(e, quiet)
	local victims, claims = {}, {}
	for i = 1, #e.victims do victims[i] = Clean(e.victims[i], 24) end
	for i = 1, #e.claims do
		local c = e.claims[i]
		claims[i] = Clean(c.name, 24) .. "@" .. tostring(math.floor(tonumber(c.at) or 0))
	end
	return table.concat({
		"E", e.guid, tostring(math.floor(tonumber(e.stamp) or 0)),
		tostring(math.floor(tonumber(e.want) or 0)),
		tostring(math.floor(tonumber(e.funded) or 0)),
		tostring(math.floor(tonumber(e.kills) or 0)),
		e.paid and "1" or (e.refunded and "2" or (e.refundDue and "3" or "0")), e.class or "", Clean(e.name, MAX_NAME),
		Clean(e.reason, MAX_REASON), Clean(e.by, 24),
		table.concat(victims, ","), table.concat(claims, ","), quiet and "1" or "0",
		tostring(math.floor(tonumber(e.cutPct) or (DB().cutPercent or 0))),
		Clean(e.fundedBy, 24) or "", tostring(math.floor(tonumber(e.fundedAt) or 0)),
		Clean(e.paidTo, 24) or "", tostring(math.floor(tonumber(e.paidAt) or 0)),
		Clean(e.refundedTo, 24) or "", tostring(math.floor(tonumber(e.refundedAt) or 0)),
		tostring(math.floor(tonumber(e.refundDays) or (DB().refundDays or 0))),
		e.paidUp and "1" or "0",
		-- last known spot: map, tenths of a percent x/y, when, exact or nearby
		e.spot and tostring(math.floor(tonumber(e.spot.map) or 0)) or "0",
		e.spot and tostring(math.floor(tonumber(e.spot.x) or 0)) or "0",
		e.spot and tostring(math.floor(tonumber(e.spot.y) or 0)) or "0",
		e.spot and tostring(math.floor(tonumber(e.spot.at) or 0)) or "0",
		e.spot and e.spot.kind == "nearby" and "n" or (e.spot and "e" or "0"),
		-- 1.1.1: level and LayerSwap's letter for the layer, read at the death
		tostring(math.floor(tonumber(e.klevel) or 0)),
		-- An expired layer is not sent at all: old clients have no TTL and would show it forever.
		ns.LayerFresh(e) and ns.LayerWire(e.klayer) or "",
		-- 1.2.2: when and by whom a member's debt was marked paid up, for the ledger history
		tostring(math.floor(tonumber(e.clearedAt) or 0)),
		Clean(e.clearedBy, 24) or "",
		-- 1.2.2: a fresh add carries its own birth stamp. A deletion outranks every old copy of
		-- a row, so only this mark can bring a deleted name back.
		tostring(math.floor(tonumber(e.reborn) or 0)),
		-- field 34: when the layer letter was read. After an hour it is no longer shown.
		tostring(math.floor(tonumber(e.klayerAt) or 0)),
		-- field 35: only a kill captured at death gets a layer. Old kills never carry one.
		e.layerNew and "1" or "0",
		-- field 36: the time of the last kill. The board sorts by this, not by when a sync arrived.
		tostring(math.floor(tonumber(e.killAt) or tonumber(e.at) or 0)),
	}, "~")
end

local function Fields(row)
	local out = {}
	local text = tostring(row or "") .. "~"
	for field in text:gmatch("([^~]*)~") do out[#out + 1] = field end
	return out
end

local function ParseEntry(row)
	local f = Fields(row)
	if f[1] ~= "E" then return nil end
	local guid = Guid(f[2])
	if not guid then return nil end
	local stamp = Num(f[3], 0, 4294967295)
	if not stamp then return nil end
	local e = {
		guid = guid,
		stamp = stamp,
		-- Field 4 is kept on the wire for older clients, but this build asks a flat 1g: never let a
		-- replayed 3g row set the price, and never let an old 3g deposit show as a 3g live bounty.
		want = DEFAULT_REWARD,
		funded = math.min(Num(f[5], 0, 100000000) or 0, DEFAULT_REWARD),
		kills = Num(f[6], 0, 9999) or 0,
		paid = f[7] == "1",
		refunded = f[7] == "2",
		refundDue = f[7] == "3",
		class = ClassCode(f[8]),
		name = Clean(f[9], MAX_NAME),
		reason = Clean(f[10], MAX_REASON),
		by = Clean(f[11], 24),
		victims = {},
		claims = {},
		quiet = f[14] == "1",
		cutPct = Num(f[15], 0, 50) or 0,
		fundedBy = Clean(f[16], 24),
		fundedAt = Num(f[17], 0, 4294967295) or 0,
		paidTo = Clean(f[18], 24),
		paidAt = Num(f[19], 0, 4294967295) or 0,
		refundedTo = Clean(f[20], 24),
		refundedAt = Num(f[21], 0, 4294967295) or 0,
		refundDays = Num(f[22], 0, 365) or 0,
		paidUp = f[23] == "1",
		clearedAt = Num(f[31], 0, 4294967295) or 0,
		clearedBy = Clean(f[32], 24) or "",
		reborn = Num(f[33], 0, 4294967295) or 0,
		-- Old rows have no stamp; their add time is the best expiry clue we have.
		klayerAt = Num(f[34], 0, 4294967295) or 0,
		-- An old client sends no field 35, so its saved kills stay layerless here too.
		layerNew = f[35] == "1",
		klevel = Num(f[29], 1, 100) or 0,
		klayer = ns.LayerValue(f[30]),
		killAt = Num(f[36], 0, 4294967295) or 0,
		at = 0,
		auto = false,
	}
	local smap, sx, sy = Num(f[24], 1, 9999999), Num(f[25], 0, SPOT_GRID), Num(f[26], 0, SPOT_GRID)
	local sat, skind = Num(f[27], 1, 4294967295), f[28]
	if smap and sx and sy and sat and (skind == "e" or skind == "n") then
		e.spot = { map = smap, x = sx, y = sy, at = sat,
			kind = skind == "n" and "nearby" or "exact" }
	end
	e.at = e.killAt
	if e.name == "" then e.name = NameFromGUID(guid) or "Unknown" end
	for victim in (f[12] or ""):gmatch("[^,]+") do
		local v = Clean(victim, 24)
		if v ~= "" then AddUnique(e.victims, v, MAX_VICTIMS) end
	end
	for claim in (f[13] or ""):gmatch("[^,]+") do
		local name, at = claim:match("^(.-)@(%d+)$")
		if name and name ~= "" then
			e.claims[#e.claims + 1] = { name = Clean(name, 24), at = tonumber(at) or 0 }
		end
	end
	return e
end

-- ============================================================================ sending

local queue = {}
local stats = { sent = 0, refused = 0, failed = 0, recv = 0, applied = 0 }
local backoff, backoffAt, warned = 0, 0, false
local chunkID = 0
local pendingAnnounce
local pendingOfficer
-- Declared here, built with the window further down: every board change redraws it, and a call
-- that resolves to a global would fail silently on the client.
local RefreshIfShown

local function SendFn()
	if type(C_ChatInfo) == "table" and type(C_ChatInfo.SendAddonMessage) == "function" then
		return C_ChatInfo.SendAddonMessage
	end
	if type(SendAddonMessage) == "function" then return SendAddonMessage end
	return nil
end

local function CanSend()
	if DB().share == false then return false end
	if not SendFn() then return false end
	return Ask(IsInGuild) == true
end

local function QueueParts(payload, urgent)
	-- One payload is one chunk set: every part must carry the SAME id or the receiver files each part
	-- under its own set and never assembles any of them.
	local cid
	if #payload > MSG_MAX then
		chunkID = (chunkID + 1) % 1000
		cid = chunkID
	end
	for i = 1, #payload, CHUNK do
		local body = payload:sub(i, i + CHUNK - 1)
		if not cid then
			queue[#queue + 1] = body
		else
			local count = math.ceil(#payload / CHUNK)
			local index = math.floor(i / CHUNK) + 1
			queue[#queue + 1] = ("C%d:%d:%d:%s"):format(cid, index, count, body)
		end
	end
	while #queue > MAX_QUEUE do table.remove(queue, 1) end
	if urgent then backoff, backoffAt = 0, 0 end
end

local function Pump()
	local now = Mono()
	if now < backoffAt then return end
	local part = table.remove(queue, 1)
	if not part then return end
	if not CanSend() then queue[#queue + 1] = part return end
	local ok, res = pcall(SendFn(), PREFIX, part, "GUILD")
	if ok and (res == nil or res == true or res == 0) then
		stats.sent = stats.sent + 1
		backoff = 0
		return
	end
	local retryable = (not ok) or res == 3 or res == 8 or res == 9 or res == 11
	if retryable then
		backoff = math.min(backoff + 1, #RETRY_WAIT)
		backoffAt = now + RETRY_WAIT[backoff]
		queue[#queue + 1] = part
		stats.failed = stats.failed + 1
		if backoff >= #RETRY_WAIT and not warned then
			warned = true
			Say("the server keeps refusing addon messages (result %s) - the board is not sharing.", tostring(res))
		end
	else
		stats.refused = stats.refused + 1
	end
end

local function Broadcast(entry, quiet)
	if not CanSend() then return false end
	QueueParts(RowFor(entry, quiet), false)
	return true
end

local function BroadcastRemoval(guid)
	if not CanSend() then return false end
	QueueParts("R~" .. guid .. "~" .. tostring(clock), false)
	return true
end

-- ============================================================================ audit trail
-- Removals and settlement decisions are recorded with actor, action, target and time, so "who
-- cleared that refund" is answerable. L rows go out only from GM/Valar and are accepted only from
-- GM/Valar, so a plain member cannot write or forge shared history.
Board.AUDIT_MAX = 200
Board.AUDIT_DIGEST = 20
Board.AUDIT_LABELS = { R = "removed", F = "refund decided", H = "handed back", P = "prize paid" }

function Board.AuditRow(rec)
	if type(rec) ~= "table" then return nil end
	return ("L~%d~%s~%s~%s~%s"):format(math.floor(tonumber(rec.at) or 0),
		Clean(rec.who, 24), Clean(rec.action, 2), Clean(rec.target, MAX_NAME), Clean(rec.detail, 80))
end

function Board.ParseAudit(row)
	local f = Fields(row)
	if f[1] ~= "L" then return nil end
	local at = Num(f[2], 0, 4294967295)
	local who, action = Clean(f[3], 24), Clean(f[4], 2)
	local target, detail = Clean(f[5], MAX_NAME), Clean(f[6], 80)
	if not at or who == "" or target == "" or not Board.AUDIT_LABELS[action] then return nil end
	return { at = at, who = who, action = action, target = target, detail = detail }
end

function Board.RecordAudit(rec)
	if type(rec) ~= "table" then return false end
	local key = ("%d|%s|%s|%s"):format(rec.at, rec.who, rec.action, rec.target)
	local audit = Store().audit
	for i = 1, #audit do
		local a = audit[i]
		if ("%d|%s|%s|%s"):format(a.at, a.who, a.action, a.target) == key then return false end
	end
	audit[#audit + 1] = rec
	table.sort(audit, function(a, b) return (tonumber(a.at) or 0) > (tonumber(b.at) or 0) end)
	while #audit > Board.AUDIT_MAX do table.remove(audit) end
	return true
end

function Board.ApplyAudit(rec, sender)
	if not Board.CanManage(sender) then return false end
	return Board.RecordAudit(rec)
end

function Board.Audit(action, who, target, detail)
	if not Board.AUDIT_LABELS[action] then return nil end
	local rec = { at = Clock(), who = Clean(who or MyName(), 24), action = action,
		target = Clean(target or "", MAX_NAME), detail = Clean(detail, 80) }
	if rec.who == "" or rec.target == "" then return nil end
	Board.RecordAudit(rec)
	if Board.CanManage() and CanSend() then QueueParts(Board.AuditRow(rec), false) end
	return rec
end

function Board.LogPrint()
	local audit = Store().audit or {}
	if #audit == 0 then
		Say("no log entries yet - removals, refunds and prize hand-overs are recorded here.")
		return
	end
	Say("|cffffd100audit log|r - newest first (shared with GM and " .. Board.MANAGER_RANK .. " only):")
	for i = 1, math.min(#audit, 15) do
		local r = audit[i]
		local ok, when = pcall(os.date, "!%Y-%m-%d %H:%M", tonumber(r.at) or 0)
		if not ok then when = tostring(r.at) end
		Say("%s  %s %s %s%s", tostring(when), r.who, Board.AUDIT_LABELS[r.action] or r.action,
			r.target, r.detail ~= "" and (" - " .. r.detail) or "")
	end
	if #audit > 15 then Say("+%d more entries", #audit - 15) end
end

-- ============================================================================ who killed whom

-- The guild's death feed: every hostile player kill of a guild member, shared the same way the
-- board is. It is a record, never a decision - a D row cannot create a board entry, so one member's
-- history can never resurrect a killer another member deleted. Clicking a name in the window is
-- what puts him back on the board; that click is also where the bounty flow starts.
local MAX_DEATHS = 100
local DIGEST_DEATHS = 50

local function DeathKey(d)
	return ("%d|%s|%s"):format(math.floor(tonumber(d.at) or 0), d.kguid or "", d.vname or "")
end

-- D~at~kguid~kclass~kname~vname~vguid~map~x~y~at~kind~klevel~klayer: the death, the spot where it
-- happened and what could be read of the killer. A shared death must carry its own location and
-- killer details: a guildmate may never receive the board row (the killer was deleted, or an older
-- row won), and the feed must still say where that member died. Every field is re-checked on the way
-- in by ParseDeath, so no field is trusted from the wire. Old rows with fewer fields still parse.
local function DeathRow(d)
	local s = d and d.spot
	local map = s and Num(s.map, 1, 9999999) or 0
	local x = s and Num(s.x, 0, SPOT_GRID) or 0
	local y = s and Num(s.y, 0, SPOT_GRID) or 0
	local sat = s and Num(s.at, 1, 4294967295) or 0
	local kind = s and ((s.kind == "nearby" and "n") or (s.kind == "exact" and "e") or "0") or "0"
	if map == 0 or (x == 0 and y == 0) or sat == 0 or kind == "0" then
		map, x, y, sat, kind = 0, 0, 0, 0, "0"
	end
	return ("D~%d~%s~%s~%s~%s~%s~%d~%d~%d~%d~%s~%d~%s~%d~%s"):format(
		math.floor(tonumber(d.at) or 0), d.kguid or "",
		Clean(d.kclass or "", 16), Clean(d.kname or "", MAX_NAME),
		Clean(d.vname or "", MAX_NAME), d.vguid or "",
		map, x, y, sat, kind,
		math.floor(tonumber(d.klevel) or 0),
		ns.LayerFresh(d) and ns.LayerWire(d.klayer) or "",
		ns.LayerFresh(d) and math.floor(tonumber(d.klayerAt) or (tonumber(d.at) or 0)) or 0,
		d.layerNew and "1" or "0")
end

local function ParseDeath(row)
	local f = Fields(row)
	if f[1] ~= "D" then return nil end
	local at = Num(f[2], 0, 4294967295)
	local kguid = Guid(f[3])
	local kname = Clean(f[5], MAX_NAME)
	if not at or not kguid or kname == "" then return nil end
	local spot
	local smap, sx, sy = Num(f[8], 1, 9999999), Num(f[9], 0, SPOT_GRID), Num(f[10], 0, SPOT_GRID)
	local sat, skind = Num(f[11], 1, 4294967295), f[12]
	if smap and sx and sy and sat and not (sx == 0 and sy == 0)
		and (skind == "e" or skind == "n") then
		spot = { map = smap, x = sx, y = sy, at = sat,
			kind = skind == "n" and "nearby" or "exact" }
	end
	return {
		at = at, kguid = kguid, kclass = ClassCode(Clean(f[4], 16)),
		kname = kname, vname = Clean(f[6], MAX_NAME), vguid = Guid(f[7]) or "",
		spot = spot,
		klevel = Num(f[13], 1, 100) or 0,
		klayer = ns.LayerValue(f[14]),
		-- Old rows fall back to the death time, so they retire an hour after the death.
		klayerAt = Num(f[15], 0, 4294967295) or 0,
		layerNew = f[16] == "1",
	}
end

local function Deaths()
	local s = Store()
	if type(s.deaths) ~= "table" then s.deaths = {} end
	return s.deaths
end

-- One row, newest first, deduped by when + who + victim. Returns the row it stored, or nil when
-- this client already knew that death (a shared row that comes back around must not double).
local function StoreDeath(d)
	if type(d) ~= "table" or not d.kguid or not d.at then return nil end
	local key = DeathKey(d)
	local list = Deaths()
	for i = 1, #list do
		if DeathKey(list[i]) == key then return nil end
	end
	list[#list + 1] = d
	table.sort(list, function(a, b)
		local x, y = tonumber(a.at) or 0, tonumber(b.at) or 0
		if x ~= y then return x > y end
		if (a.kname or "") ~= (b.kname or "") then return (a.kname or "") < (b.kname or "") end
		return (a.kguid or "") < (b.kguid or "")
	end)
	while #list > MAX_DEATHS do table.remove(list) end
	return d
end

-- Recorded on the victim's own client, because that is the only place a death is visible, then
-- shared like a board row. The time is server seconds, so "2h ago" reads the same everywhere.
-- The spot from CaptureSpot travels with it; only its five wire fields are kept (no unit token).
local function RecordDeath(kguid, kname, kclass, vname, vguid, spot, klevel, klayer)
	local s = spot and {
		map = Num(spot.map, 1, 9999999), x = Num(spot.x, 0, SPOT_GRID),
		y = Num(spot.y, 0, SPOT_GRID), at = Num(spot.at, 1, 4294967295),
		kind = spot.kind == "nearby" and "nearby" or (spot.kind == "exact" and "exact" or nil),
	}
	if s and (not s.map or not s.x or not s.y or not s.at or not s.kind
		or (s.x == 0 and s.y == 0)) then s = nil end
	local d = {
		at = Clock(),
		kguid = Guid(kguid),
		kclass = ClassCode(kclass or ""),
		kname = Clean(kname or "", MAX_NAME),
		vname = Clean(vname or "", MAX_NAME),
		vguid = Guid(vguid) or "",
		spot = s,
		klevel = Num(klevel, 1, 100) or 0,
		klayer = ns.LayerValue(klayer),
		klayerAt = ns.LayerPart(klayer) and Clock() or 0,
		-- Every death captured by this build is a new kill, even when no layer could be read yet.
		layerNew = true,
	}
	if not d.kguid or d.kname == "" or d.at <= 0 then return nil end
	ns.RememberKillerInfo(d.kguid, d.klevel, d.klayer, d.klayerAt, d.layerNew)
	if not StoreDeath(d) then return nil end
	if CanSend() then QueueParts(DeathRow(d), false) end
	RefreshIfShown()
	return d
end

local function ApplyDeath(d)
	if not d then return false end
	if not StoreDeath(d) then return false end
	RefreshIfShown()
	return true
end

local function SortedDeaths(mineOnly)
	local list = Deaths()
	local out = {}
	local me = MyName()
	for i = 1, #list do
		if not mineOnly or SameName(list[i].vname, me) then out[#out + 1] = list[i] end
	end
	return out
end

local function Ago(at)
	local d = Clock() - (tonumber(at) or 0)
	if d < 5 then return "just now" end
	if d < 60 then return ("%ds ago"):format(d) end
	if d < 3600 then return ("%dm ago"):format(math.floor(d / 60)) end
	if d < 86400 then return ("%dh ago"):format(math.floor(d / 3600)) end
	return ("%dd ago"):format(math.floor(d / 86400))
end

-- ============================================================================ monthly hunter board
--
-- Only a kill of a LIVE funded bounty counts, and only for the hunter who landed it. A name on the
-- board, a pending job, a part-paid row or an ordinary PvP kill earns nothing. The credit is made
-- in ClaimKill (our own PARTY_KILL), carried to the guild as a B row, and kept in a small ledger so
-- a later refund, deletion or /kos reset cannot erase the month. The 70% share of every credited
-- bounty goes into ONE pool for that month; the hunter with the most kills wins the whole pool.
-- The addon never moves gold, so a human hands it over and records it with a B~P~ row.

function Board.BoardRow(rec)
	if rec.kind == "P" then
		-- The month rides along: a prize is often handed over after the rollover has cleared the
		-- current ledger. Older rows without it still parse and use the timestamp's month.
		return ("B~P~%s~%s~%s~%d"):format(Clean(rec.who or "", MAX_NAME),
			Clean(rec.by or "", MAX_NAME), Clean(rec.month or "", 7),
			math.floor(tonumber(rec.at) or 0))
	end
	return ("B~C~%s~%s~%s~%d~%d"):format(Clean(rec.who or "", MAX_NAME),
		Clean(rec.target or "", 64), Clean(rec.tname or "", MAX_NAME),
		math.floor(tonumber(rec.amount) or 0), math.floor(tonumber(rec.at) or 0))
end

function Board.ParseBoardRow(row)
	local f = Fields(row)
	if f[1] ~= "B" then return nil end
	local at = Num(f[#f], 0, 4294967295)
	if not at then return nil end
	if f[2] == "P" then
		local who = Clean(f[3], MAX_NAME)
		if who == "" then return nil end
		local month = #f >= 6 and Clean(f[5], 7) or nil
		if month ~= "" and month and not month:match("^%d%d%d%d%-%d%d$") then month = nil end
		return { kind = "P", who = who, by = Clean(f[4], MAX_NAME), month = month, at = at }
	end
	if f[2] ~= "C" then return nil end
	local who = Clean(f[3], MAX_NAME)
	local target = Guid(f[4])
	local amount = Num(f[6], 1, 100000000)
	if who == "" or not target or not amount then return nil end
	return { kind = "C", who = who, target = target, tname = Clean(f[5], MAX_NAME),
		amount = amount, at = at }
end

function Board.ApplyBoardCredit(rec)
	if type(rec) ~= "table" then return false end
	local who = Clean(rec.who or "", MAX_NAME)
	local target = Guid(rec.target)
	local amount = math.floor(tonumber(rec.amount) or 0)
	local at = math.floor(tonumber(rec.at) or 0)
	if who == "" or not target or amount <= 0 or at <= 0 then return false end
	local month = Board.BoardMonth(at)
	local b = Store().board
	-- a row for a month already closed cannot change a settled result
	if b.month:match("^%d%d%d%d%-%d%d$") and month < b.month then return false end
	local key = month .. "|" .. who:lower() .. "|" .. target
	local seenTarget = false
	for i = 1, #b.ledger do
		local old = b.ledger[i]
		if old.key == key then return false end
		if old.month == month and old.target == target then seenTarget = true end
	end
	b.ledger[#b.ledger + 1] = { key = key, month = month, who = who, target = target,
		tname = Clean(rec.tname or "", MAX_NAME), amount = amount, at = at }
	-- One bounty contributes once, even if two hunters somehow claim the same funded target.
	-- The bank's cut stays with the guild; the hunter's share joins this month's single pool.
	if not seenTarget then
		local s = Store()
		s.bank.cut = (tonumber(s.bank.cut) or 0) + CutOf(amount)
		s.bank.pool = (tonumber(s.bank.pool) or 0) + PayoutOf(amount)
		s.bank.at = Clock()
	end
	RefreshIfShown()
	return true
end

-- A locally earned credit: record it and tell the guild so everybody ranks the same month the same
-- way. The ledger key makes a repeated or replayed row harmless.
function Board.BoardCredit(rec)
	if not Board.ApplyBoardCredit(rec) then return false end
	if CanSend() then QueueParts(Board.BoardRow(rec), false) end
	return true
end

-- The month's single prize pool: the 70% share of every DIFFERENT funded bounty killed that
-- month, not one share per claim. Derived from the shared ledger, so every guildmate agrees and a
-- replayed row cannot add the same bounty twice.
function Board.FundForMonth(month)
	local total, seen = 0, {}
	local b = Store().board
	for i = 1, #b.ledger do
		local rec = b.ledger[i]
		if rec.month == month and not seen[rec.target] then
			seen[rec.target] = true
			total = total + PayoutOf(rec.amount)
		end
	end
	return total
end

function Board.BoardScores(month)
	local b = Store().board
	month = month or b.month
	local out = {}
	for i = 1, #b.ledger do
		local rec = b.ledger[i]
		if rec.month == month then
			local row = out[rec.who]
			if not row then
				row = { who = rec.who, name = rec.tname or rec.who,
					count = 0, amount = 0, reachAt = 0, firstAt = rec.at }
				out[rec.who] = row
			end
			row.count = row.count + 1
			row.amount = row.amount + rec.amount
			if rec.at > row.reachAt then row.reachAt = rec.at end
			if rec.at < row.firstAt then row.firstAt = rec.at end
		end
	end
	return out
end

-- Most unique victims first; then whoever reached that score earliest; then the name, so a tie
-- cannot depend on which member's client happened to report first.
function Board.BoardCompare(a, b)
	if a.count ~= b.count then return a.count > b.count end
	if a.reachAt ~= b.reachAt then return a.reachAt < b.reachAt end
	return a.who < b.who
end

function Board.BoardRanks(month)
	local list = {}
	for _, r in pairs(Board.BoardScores(month)) do list[#list + 1] = r end
	table.sort(list, Board.BoardCompare)
	return list
end

function Board.BoardWinner(month)
	return Board.BoardRanks(month)[1]
end

function Board.BoardRollover(now)
	local b = Store().board
	local month = Board.BoardMonth(now)
	if b.month == month then return false end
	if b.month ~= "" and b.month ~= "unknown" then
		local winner = Board.BoardWinner(b.month)
		if winner then
			local h = { month = b.month, who = winner.who, count = winner.count,
				amount = winner.amount, prize = Board.FundForMonth(b.month),
				paid = false, by = "", at = math.floor(tonumber(now) or 0) }
			local a = b.award
			if a.month == b.month and SameName(a.who, winner.who) then
				h.paid, h.by = true, a.by
			end
			b.history[#b.history + 1] = h
			while #b.history > 12 do table.remove(b.history, 1) end
		end
	end
	b.month = month
	local keep = {}
	for i = 1, #b.ledger do
		if b.ledger[i].month == month then keep[#keep + 1] = b.ledger[i] end
	end
	b.ledger = keep
	RefreshIfShown()
	return true
end

-- The last finished month whose winner has not had the pool recorded as handed over yet. The addon
-- never moves the gold, so this debt stays on the officers' list until /kos boardpaid is used.
function Board.PastPrize()
	local h = Store().board.history
	for i = #h, 1, -1 do
		if h[i] and (tonumber(h[i].prize) or 0) > 0 and not h[i].paid then return h[i] end
	end
	return nil
end

function Board.ApplyBoardPaid(rec, sender)
	if not Board.CanManage(sender) then return false, Board.DENIED end
	if type(rec) ~= "table" then return false end
	local who = Clean(rec.who or "", MAX_NAME)
	local at = math.floor(tonumber(rec.at) or 0)
	if who == "" or at <= 0 then return false end
	local b = Store().board
	local month = rec.month or Board.BoardMonth(at)
	if type(month) ~= "string" or not month:match("^%d%d%d%d%-%d%d$") then return false end
	local amount, found = 0, nil
	if month == b.month then amount = Board.FundForMonth(month) end
	if amount <= 0 then
		-- A month-end payment is usually recorded AFTER the rollover has archived the result.
		-- Older rows without a month land here too: find that winner's unpaid archived prize.
		for i = #b.history, 1, -1 do
			local h = b.history[i]
			if h and (tonumber(h.prize) or 0) > 0 and not h.paid and SameName(h.who, who)
				and (not rec.month or rec.month == h.month) then
				amount, found, month = h.prize, h, h.month
				break
			end
		end
	end
	if amount <= 0 then return false end
	local a = b.award
	if a.month and a.month > month then return false end
	if a.month == month and SameName(a.who, who) then return false end
	if found then
		found.paid, found.by, found.at = true, Clean(rec.by or "", MAX_NAME), at
	end
	b.award = { month = month, who = who, by = Clean(rec.by or "", MAX_NAME),
		at = at, amount = amount }
	local s = Store()
	s.bank.paid = (tonumber(s.bank.paid) or 0) + amount
	s.bank.at = Clock()
	RefreshIfShown()
	return true
end

-- A human handed the winner that month's prize at the bank. Records it; never moves gold.
function Board.BoardPaid(who, by)
	if not Board.CanManage() then return false, Board.DENIED end
	Board.BoardRollover(Clock())
	local b = Store().board
	local target, amount, month = Board.BoardWinner(b.month), 0, b.month
	if target then amount = Board.FundForMonth(month) end
	if not target or amount <= 0 then
		-- Month-end is the normal time to hand it over, and by then the new month has started.
		local h = Board.PastPrize()
		if h then
			target, amount, month = { who = h.who, count = h.count }, h.prize, h.month
		end
	end
	if not target or amount <= 0 then
		return false, "nobody has a kill on the board with gold in the bank yet"
	end
	who = Clean(who or "", MAX_NAME)
	if who ~= "" and not SameName(who, target.who) then
		return false, ("the winner is %s, not %s"):format(target.who, who)
	end
	local a = b.award
	if a.month == month and SameName(a.who, target.who) then
		return false, "that month's prize is already recorded as paid"
	end
	local rec = { kind = "P", who = target.who, by = Clean(by or MyName(), MAX_NAME),
		month = month, at = Clock() }
	if not Board.ApplyBoardPaid(rec, MyName()) then return false, "that prize was already recorded as paid" end
	Board.Audit("P", rec.by, target.who, Money(amount) .. " for " .. month)
	if CanSend() then QueueParts(Board.BoardRow(rec), false) end
	Say("%s handed %s the %s prize pool for %d kill%s.",
		rec.by, target.who, Money(amount), target.count,
		target.count == 1 and "" or "s")
	RefreshIfShown()
	return true
end

function Board.BoardPrint()
	Board.BoardRollover(Clock())
	local b = Store().board
	local ranks = Board.BoardRanks(b.month)
	Say("|cffffd100monthly hunter board - %s|r - who killed the most bounties this month", b.month)
	if #ranks == 0 then
		Say("no bounties killed this month yet. The hunter with the most kills wins the pool.")
	else
		for i = 1, math.min(#ranks, 10) do
			local r = ranks[i]
			Say("  %d. %s - %d kill%s - %s in the pool", i, r.who, r.count,
				r.count == 1 and "" or "s", Money(r.amount))
		end
		local winner = ranks[1]
		Say("top hunter: %s - %d kill%s - wins the whole %s prize pool.",
			winner.who, winner.count, winner.count == 1 and "" or "s",
			Money(Board.FundForMonth(b.month)))
	end
	if #b.history > 0 then
		local h = b.history[#b.history]
		Say("last month (%s): %s with %d kill%s - %s pool%s", h.month, h.who, h.count,
			h.count == 1 and "" or "s", Money(tonumber(h.prize) or 0),
			h.paid and (" handed to " .. (h.by ~= "" and h.by or "an officer")) or "")
	end
end

-- ============================================================================ last known spot
-- WoW has no API for "where is player X right now". A unit only has a readable position while this
-- client can actually see him: as the target, the mouseover or one of the nameplate tokens. The
-- recap lands after the death, so we look at those units at once and keep the point we find. If he
-- is already gone, the honest record is where the observer died, labelled "nearby" - never a made
-- up exact point. The point rides on the guild row with the bounty.

function MapLib.Grid(v)
	if Secret(v) then return nil end
	v = tonumber(v)
	if not v or v ~= v or v < 0 or v > 1 then return nil end
	local n = math.floor(v * SPOT_GRID + 0.5)
	return n >= 0 and n <= SPOT_GRID and n or nil
end

function MapLib.XY(pos)
	if type(pos) ~= "table" or type(pos.GetXY) ~= "function" then return nil end
	local ok, x, y = pcall(pos.GetXY, pos)
	if not ok then return nil end
	local gx, gy = MapLib.Grid(x), MapLib.Grid(y)
	if not gx or not gy or (gx == 0 and gy == 0) then return nil end
	return gx, gy
end

-- Olympus's PlayerSightings.lua is the reference for this client: read a visible unit through C_Map
-- first; if that fails, HereBeDragons can turn the unit's world position into the observer's current
-- zone/micro map. Only an open zone is accepted and out-of-bounds conversion is refused, so a
-- different instance or an unreadable unit fails closed instead of becoming an invented point.
function MapLib.OpenMap(map)
	map = Num(map, 1, 9999999)
	if not map or type(C_Map) ~= "table" or type(C_Map.GetMapInfo) ~= "function" then return false end
	local ok, info = pcall(C_Map.GetMapInfo, map)
	if not ok or type(info) ~= "table" or Secret(info.mapType) then return false end
	local T = type(Enum) == "table" and type(Enum.UIMapType) == "table" and Enum.UIMapType or {}
	return info.mapType == (T.Zone or 3) or info.mapType == (T.Micro or 5)
end

function MapLib.ValidPoint(x, y)
	if Secret(x, y) then return false end
	x, y = tonumber(x), tonumber(y)
	if type(x) ~= "number" or type(y) ~= "number" or x ~= x or y ~= y then return false end
	if x <= -math.huge or x >= math.huge or y <= -math.huge or y >= math.huge then return false end
	return x >= 0 and x <= 1 and y >= 0 and y <= 1 and not (x == 0 and y == 0)
end

function MapLib.WorldMapSpot(unit)
	if LibStub == nil or type(C_Map) ~= "table" or type(C_Map.GetBestMapForUnit) ~= "function" then return nil end
	local map = Ask(C_Map.GetBestMapForUnit, "player")
	if not MapLib.OpenMap(map) then return nil end
	local okLib, hbd = pcall(function() return LibStub("HereBeDragons-2.0", true) end)
	if not okLib or type(hbd) ~= "table" or type(hbd.GetUnitWorldPosition) ~= "function"
		or type(hbd.GetZoneCoordinatesFromWorldInstance) ~= "function" then return nil end
	local okWorld, wx, wy, instance = pcall(hbd.GetUnitWorldPosition, hbd, unit)
	if not okWorld or Secret(wx, wy, instance) or type(wx) ~= "number" or type(wy) ~= "number"
		or type(instance) ~= "number" then return nil end
	local okMap, x, y = pcall(hbd.GetZoneCoordinatesFromWorldInstance, hbd, wx, wy, instance, map, false)
	if not okMap or not MapLib.ValidPoint(x, y) then return nil end
	local gx, gy = MapLib.Grid(x), MapLib.Grid(y)
	if gx and gy and not (gx == 0 and gy == 0) then return map, gx, gy end
	return nil
end

function MapLib.MapSpot(unit)
	if type(C_Map) == "table" and type(C_Map.GetBestMapForUnit) == "function"
		and type(C_Map.GetPlayerMapPosition) == "function" then
		local map = Ask(C_Map.GetBestMapForUnit, unit)
		if MapLib.OpenMap(map) then
			local pos = Ask(C_Map.GetPlayerMapPosition, map, unit)
			local gx, gy = MapLib.XY(pos)
			if gx then return map, gx, gy end
		end
	end
	return MapLib.WorldMapSpot(unit)
end

function MapLib.ZoneName(map)
	if not map or type(C_Map) ~= "table" or type(C_Map.GetMapInfo) ~= "function" then return nil end
	local ok, info = pcall(C_Map.GetMapInfo, map)
	if not ok or type(info) ~= "table" then return nil end
	local name = Plain(info.name)
	return (name ~= "" and name) or nil
end

-- guid/name say who we are looking for; allowNearby is only true at the death itself. A later
-- right-click can improve an exact spot if the killer happens to be on screen, but it must never
-- substitute the reader's current position for a dead member's old death.
local function CaptureSpot(guid, name, allowNearby)
	local tokens = { "target", "mouseover" }
	for i = 1, 40 do tokens[#tokens + 1] = "nameplate" .. i end
	for i = 1, #tokens do
		local unit = tokens[i]
		if Ask(UnitExists, unit) == true and Ask(UnitIsPlayer, unit) ~= false
			and Ask(UnitIsVisible, unit) ~= false then
			local uguid = Guid(Ask(UnitGUID, unit))
			local uname = Plain(Ask(UnitName, unit) or Ask(UnitFullName, unit))
			local match = (uguid and guid and uguid == guid)
				or (not uguid and name ~= "" and uname and SameName(uname, name))
			if match then
				local map, gx, gy = MapLib.MapSpot(unit)
				if map then
					return { map = map, x = gx, y = gy, at = Clock(), kind = "exact", unit = unit }
				end
			end
		end
	end
	if allowNearby then
		local map, gx, gy = MapLib.MapSpot("player")
		if map then
			return { map = map, x = gx, y = gy, at = Clock(), kind = "nearby" }
		end
	end
	return nil
end

-- A later sighting wins; at the same second an actually seen point beats a "nearby" hint. That
-- matters because the death and the right-click can land inside one server second.
local function SpotBetter(a, b)
	if not a then return false end
	if not b then return true end
	if a.kind == "exact" and b.kind ~= "exact" then return true end
	if a.kind ~= "exact" and b.kind == "exact" then return false end
	return (tonumber(a.at) or 0) >= (tonumber(b.at) or 0)
end

-- The bare place and time, with no lead-in. Used wherever the line already says "last known
-- location", so the same place is not named twice in one sentence.
ns.SpotPlace = function(e)
	local s = e and e.spot
	if not s or not s.map then return nil end
	local zone = MapLib.ZoneName(s.map)
	local at = ("%.1f, %.1f"):format((tonumber(s.x) or 0) / 10, (tonumber(s.y) or 0) / 10)
	local where = zone and (zone .. " " .. at) or ("map " .. tostring(s.map) .. " " .. at)
	return where .. " (" .. Ago(s.at) .. ")", s.kind == "nearby"
end

local function SpotLine(e)
	local place, near = ns.SpotPlace(e)
	if not place then return nil end
	if near then return "last seen near where I died: " .. place end
	return "last seen at " .. place
end

-- One "last known location" only. A nearby point keeps the word "near" but not a second lead-in.
ns.KnownSpot = function(e, missing)
	local place, near = ns.SpotPlace(e)
	if not place then return "last known location unavailable" .. (missing or "") end
	return "last known location: " .. (near and "near " or "") .. place
end

-- LayerSwap keeps a letter for every layer it has stood on: LayerSwapDB.layers[full id].letter,
-- and every "layer" log row carries that same letter in b. What matters to a player is the letter
-- (Q, P, ...), not the raw server part of the creature GUID. The numeric key is only used to find
-- the letter; Layer.key() in LayerSwap.lua is the same "^(%d+)-" rule used here.
ns.LayerLetter = function(value)
	if value == nil or Secret(value) then return nil end
	local s = tostring(value)
	if s == "" then return nil end
	if s:match("^%w+$") and not s:match("^%d+$") then return s:upper() end
	local key = s:match("^(%d+)%-") or s:match("^(%d+)$")
	if not key then return nil end
	local db = rawget(_G, "LayerSwapDB")
	local layers = type(db) == "table" and db.layers or nil
	if type(layers) ~= "table" then return nil end
	local best, bestLast
	for id, l in pairs(layers) do
		if type(l) == "table" and type(l.letter) == "string" and l.letter ~= "" and not Secret(l.letter) then
			local idtext = tostring(id)
			if idtext == key or idtext:match("^(%d+)%-") == key then
				local last = tonumber(l.last) or 0
				if not bestLast or last > bestLast then best, bestLast = l.letter:upper(), last end
			end
		end
	end
	return best
end

-- One canonical layer for display, wire and storage. A letter is kept as-is; a number from an old
-- row is used only when LayerSwap can name it. An unmapped number is UNKNOWN, not a raw number and
-- not this player's current layer - using our own layer here put every unread killer on one layer.
ns.LayerPart = function(value)
	if value == nil or Secret(value) then return nil end
	if type(value) == "number" and value <= 0 then return nil end
	local s = tostring(value)
	if s == "" or s == "0" then return nil end
	-- LayerSwap runs out of letters: layers 27, 28 ... are stored as numeric labels. They are real
	-- layer names, not raw server numbers, so keep them when the table says that label is in use.
	local db = rawget(_G, "LayerSwapDB")
	local layers = type(db) == "table" and db.layers or nil
	if s:match("^%d+$") and type(layers) == "table" then
		for _, l in pairs(layers) do
			if type(l) == "table" and tostring(l.letter) == s then return s end
		end
	end
	if s:match("^%w+$") and not s:match("^%d+$") then return s:upper() end
	local n = Num(s, 1, 9999999)
	if not n then return nil end
	return ns.LayerLetter(n)
end

-- Empty string on the wire means "unknown"; everywhere else an unknown layer is the number 0 so
-- saved profiles keep the old shape and the merge code never compares a string with a number.
ns.LayerWire = function(value)
	return ns.LayerPart(value) or ""
end

ns.LayerValue = function(value)
	return ns.LayerPart(value) or 0
end

-- LayerSwap reads our own layer from nearby creature GUIDs and keeps the last reading in its log.
-- A hostile player who killed us stands on the same layer, so that reading is also the killer's
-- layer. It is used only when no creature in view gave a direct vote; nil still means unknown.
ns.MyLayer = function()
	local db = rawget(_G, "LayerSwapDB")
	local log = type(db) == "table" and db.log or nil
	if type(log) ~= "table" then return nil end
	for i = #log, 1, -1 do
		local row = log[i]
		if type(row) == "table" and row.kind == "layer" then
			if type(row.b) == "string" and row.b ~= "" and not Secret(row.b) then
				return ns.LayerPart(row.b)
			end
			if type(row.a) == "string" then
				local letter = ns.LayerLetter(row.a:match("^(%d+)%-") or row.a)
				if letter then return letter end
			end
		end
	end
	return nil
end

-- Canonical letter for a wire/storage value. An old client's raw number with no LayerSwap entry
-- stays unknown - it must never be shown as another player's current layer.
ns.LayerDisplay = function(value)
	return ns.LayerPart(value)
end

-- A layer is a live, changing thing: a reading older than an hour is not a layer at all, it is a
-- stale clue. No chat line, board row, tooltip or fallback may use it after LAYER_TTL. Old rows
-- without their own stamp fall back to the death/add time, so they expire too.
ns.LayerFresh = function(src)
	if not src or src.layerNew ~= true then return nil end
	local layer = ns.LayerPart(src.klayer)
	if not layer then return nil end
	local at = tonumber(src.klayerAt) or 0
	if at <= 0 then at = tonumber(src.at) or 0 end
	if at <= 0 or Clock() - at >= LAYER_TTL then return nil end
	return layer
end

-- Every unit that can still name a player on this client. Olympus reads the game's GUID token first,
-- then target/focus/mouseover, party and the nameplates; a death screen hides most of them, so the
-- wider list matters more than it looks.
ns.InfoUnits = function()
	local list = Units()
	for i = 1, 40 do list[#list + 1] = "raid" .. i end
	return list
end

-- UnitLevel is the first source. Some Forever tooltips give a plain level even where UnitLevel is
-- hidden behind a secret value, so read the tooltip lines too. Both paths fail closed.
ns.ReadLevel = function(unit)
	local lv = Num(Ask(UnitLevel, unit), 1, 100)
	if lv then return lv end
	if type(C_TooltipInfo) ~= "table" or type(C_TooltipInfo.GetUnit) ~= "function" then return nil end
	local ok, data = pcall(C_TooltipInfo.GetUnit, unit)
	if not ok or type(data) ~= "table" or type(data.lines) ~= "table" then return nil end
	for _, line in ipairs(data.lines) do
		local text = type(line) == "table" and line.leftText or nil
		if type(text) == "string" and not Secret(text) then
			local n = text:match("Level%s+(%d+)") or text:match("^(%d+)")
			local got = Num(n, 1, 100)
			if got then return got end
		end
	end
	return nil
end

-- Full-name key for the guild roster. Deliberately stricter than SameName(): a shared first name
-- must never turn another player's level into this killer's level.
ns.NameKey = function(value)
	local plain = Plain(value)
	if not plain then return nil end
	-- A death recap can carry Name-Realm while the roster carries Name; drop only that suffix,
	-- never a surname, and keep the whole remaining name so a shared first name cannot match.
	plain = plain:lower():gsub("%-.*$", ""):gsub("%s+", " ")
	return plain ~= "" and plain or nil
end

-- Read-only guild roster lookup. It never writes a note and never moves gold; it only turns a name
-- the client already knows into the level the server publishes for that same name.
ns.GuildLevel = function(name)
	local want = ns.NameKey(name)
	if not want or type(GetNumGuildMembers) ~= "function" or type(GetGuildRosterInfo) ~= "function" then return nil end
	local ok, total = pcall(GetNumGuildMembers)
	if not ok or type(total) ~= "number" then return nil end
	for i = 1, math.min(total, 500) do
		-- pcall adds its own ok value; GetGuildRosterInfo returns name, rank, rankIndex, level, ...
		local good, member, _, _, level = pcall(GetGuildRosterInfo, i)
		if not good then break end
		if not Secret(member, level) and ns.NameKey(member) == want then
			local lv = Num(level, 1, 100)
			if lv then return lv end
		end
	end
	return nil
end

-- Olympus already records the level of the player who killed us: its evidence rows carry hl (the
-- Horde player's level as this client saw it), killerGuid and killerName. Reading that saved, read-
-- only record is the strongest fallback when the death screen hides the killer's unit. A floor
-- level (hf, the game's "??") is deliberately skipped, and the newest matching row wins.
ns.OlympusLevel = function(guid, name)
	local db = rawget(_G, "OlympusDB")
	local realms = type(db) == "table" and db.realms or nil
	if type(realms) ~= "table" then return nil end
	local want = name and ns.NameKey(name) or nil
	local best, bestAt
	for _, store in pairs(realms) do
		local wanted = type(store) == "table" and store.wanted or nil
		local evidence = type(wanted) == "table" and wanted.evidence or nil
		if type(evidence) == "table" then
			for _, e in pairs(evidence) do
				if type(e) == "table" and not Secret(e.void) and e.void ~= true
					and not Secret(e.hf) and e.hf ~= true then
					local lv = Num(e.hl, 1, 100)
					if lv then
						local match = false
						if guid and not Secret(e.killerGuid) and type(e.killerGuid) == "string"
							and e.killerGuid == guid then
							match = true
						elseif want and not Secret(e.killerName) and type(e.killerName) == "string"
							and ns.NameKey(e.killerName) == want then
							match = true
						end
						if match then
							local at = Ask(tonumber, e.at) or 0
							if not bestAt or at >= bestAt then best, bestAt = lv, at end
						end
					end
				end
			end
		end
	end
	return best
end

-- A short sighting cache. On this client the killer's plate is usually gone by the time PLAYER_DEAD
-- runs, so a level read earlier from a nameplate (or target/focus/mouseover) is kept for two minutes.
-- Olympus keeps the same kind of cache for the same reason. A level is only stored with a GUID the
-- client actually gave us; a name match never creates an entry.
ns.seenLevels = {}
ns.RememberLevel = function(unit)
	local guid = Ask(UnitGUID, unit)
	if type(guid) ~= "string" or guid:sub(1, 7) ~= "Player-" then return nil end
	local lv = ns.ReadLevel(unit)
	if not lv then return nil end
	local now = Clock()
	ns.seenLevels[guid] = { level = lv, at = now }
	for g, row in pairs(ns.seenLevels) do
		if now - (tonumber(row.at) or 0) > 120 then ns.seenLevels[g] = nil end
	end
	return lv
end

-- Session-only proof of what THIS client read for a killer. Guild sync is allowed to move money,
-- spots, claims and removals, but no older client's row can replace a level or layer we proved.
-- It dies at logout and is never sent as an extra field. Delete authority comes only from the
-- guild master or Valar rank; there is no per-player master switch.
ns.localProof = {}
ns.RememberKillerInfo = function(guid, level, layer, layerAt, layerNew)
	if type(guid) ~= "string" or guid == "" then return end
	local lv = Num(level, 1, 100)
	local ly = ns.LayerPart(layer)
	if not lv and not ly then return end
	local p = ns.localProof[guid]
	if not p then p = {} ns.localProof[guid] = p end
	if lv then p.klevel = lv end
	if ly then
		p.klayer = ns.LayerValue(ly)
		p.klayerAt = tonumber(layerAt) or Clock()
		p.layerNew = layerNew == true
	end
end

-- Level and layer of the killer, read while the death is still on screen and shared on both the
-- board row and the death row. The layer is LayerSwap's letter (P, Q, ...), never the raw server
-- number; nil means "the client gave us nothing readable", never a guess.
ns.KillerLine = function(src)
	if not src then return nil end
	local level = Num(src.klevel, 1, 100)
	local layer = ns.LayerFresh(src)
	if not level and not layer then return nil end
	if level and layer then return ("level %d, layer %s"):format(level, layer) end
	if level then return ("level %d"):format(level) end
	return ("layer %s"):format(layer)
end

-- Short form for the board row: the long KillerLine would not fit the state column.
ns.KillerTag = function(src)
	local level = Num(src and src.klevel, 1, 100)
	local layer = ns.LayerFresh(src)
	if not level and not layer then return nil end
	if level and layer then return ("lvl%d layer %s"):format(level, layer) end
	if level then return ("lvl%d"):format(level) end
	return ("layer %s"):format(layer)
end

-- --------------------------------------------------------------------- swap to the killer's layer
-- LayerSwap 1.14.40 does not set a layer directly: a host already standing on that layer sends a
-- group invite, and accepting it moves you across. On live Forever an addon may not post the
-- "inv layer" chat line, so the line goes into the chat box for the player's own Enter (LayerSwap's
-- Send.box). The hidden "zone"/"want" notes go out on the click: addon messages are allowed here,
-- and they are all a LayerSwap host needs to answer that line.
-- The map id LayerSwap files a layer under: walk up from the current map to the first Zone map.
-- Everything here lives on ns or inside the functions: this file is at Lua 5.1's 200-local cap.
ns.PlayerLayerZone = function()
	local LAYER_ZONE_MAP = (Enum and Enum.UIMapType and Enum.UIMapType.Zone) or 3
	if type(C_Map) ~= "table" or type(C_Map.GetBestMapForUnit) ~= "function"
		or type(C_Map.GetMapInfo) ~= "function" then return nil end
	local ok, id = pcall(C_Map.GetBestMapForUnit, "player")
	if not ok or Secret(id) or type(id) ~= "number" or id <= 0 then return nil end
	local zone = id
	for _ = 1, 6 do
		local good, info = pcall(C_Map.GetMapInfo, zone)
		if not good or type(info) ~= "table" or Secret(info.mapType)
			or type(info.mapType) ~= "number" then break end
		if info.mapType == LAYER_ZONE_MAP then return zone end
		local up = info.parentMapID
		if info.mapType < LAYER_ZONE_MAP or Secret(up) or type(up) ~= "number" or up <= 0 then break end
		zone = up
	end
	return id
end

-- LayerSwap keeps letter -> full id (LayerSwapDB.layers[id].letter). Its own "/ls swap X" scans
-- that table filtered to the current zone; this is the same read, newest sighting wins.
-- LayerSwap files layers under the ZONE NAME (Layer.zone()), not the map id. The hidden "zone"
-- note and the ask line use the numeric map id; the DB reader must compare the name or it never
-- finds a host on live Forever.
ns.PlayerLayerZoneName = function(zone)
	if not zone then return nil end
	if type(C_Map) == "table" and type(C_Map.GetMapInfo) == "function" then
		local ok, info = pcall(C_Map.GetMapInfo, zone)
		if ok and type(info) == "table" and type(info.name) == "string" and info.name ~= "" then
			return info.name
		end
	end
	if type(GetRealZoneText) == "function" then
		local ok, text = pcall(GetRealZoneText)
		if ok and type(text) == "string" and text ~= "" then return text end
	end
	return nil
end

-- Hidden LayerSwap notes for a swap request. The whisper target can invite by hand; if that
-- member also hosts LayerSwap, these notes give it the exact zone and layer without putting any
-- technical tags in the message the player sends.
ns.SendSwapNotes = function(who, zone, id)
	local send = SendFn()
	if not send then return false end
	pcall(send, "LayerSwap", "zone " .. tostring(zone), "WHISPER", who)
	pcall(send, "LayerSwap", "want " .. tostring(id), "WHISPER", who)
	return true
end

ns.LayerIdFor = function(letter, zone, zoneName)
	local ly = ns.LayerPart(letter)
	if not ly then return nil end
	local db = rawget(_G, "LayerSwapDB")
	local layers = type(db) == "table" and db.layers or nil
	if type(layers) ~= "table" then return nil end
	local best, bestLast
	for id, l in pairs(layers) do
		if type(l) == "table" and type(l.letter) == "string" and l.letter:upper() == ly
			and (not zoneName or l.zone == zoneName or l.zone == zone) then
			local last = tonumber(l.last) or 0
			if not bestLast or last >= bestLast then best, bestLast = tostring(id), last end
		end
	end
	return best
end

-- Ask the guild for an invite to the selected killer's layer. True when a request was set up.
ns.SwapToLayer = function(entry)
	local e = entry
	if not e then
		Say("select a killer on the board first, then press swap to layer.")
		return false
	end
	local letter = ns.LayerFresh(e)
	if not letter then
		Say("that killer's layer is unknown or older than an hour - there is nothing to swap to.")
		return false
	end
	local zone = ns.PlayerLayerZone()
	if not zone then
		Say("cannot read your zone - target an NPC or move a little, then try again.")
		return false
	end
	local zoneName = ns.PlayerLayerZoneName(zone)
	local id = ns.LayerIdFor(letter, zone, zoneName)
	if not id then
		Say("layer %s has not been seen in this zone by LayerSwap - no host here can invite you.", letter)
		return false
	end
	-- The bounty's victim is the one who knows the layer he died on. Whisper that member with a
	-- plain request; a human can invite us, and a LayerSwap host reads the hidden notes as well.
	local who = e.fundedBy ~= "" and e.fundedBy or nil
	if not who and type(e.victims) == "table" and #e.victims > 0 then who = e.victims[#e.victims] end
	if not who or who == "" then who = e.by end
	who = Clean(who, 24)
	if who == "" then
		Say("this bounty has no victim recorded - set it again from the death, then ask for the swap.")
		return false
	end
	if SameName(who, MyName()) then
		Say("you set this bounty - ask another hunter to swap, or whisper the victim yourself.")
		return false
	end
	ns.SendSwapNotes(who, zone, id)
	ns.pendingSwap = { target = who, zone = zone, id = id }
	local line = ("A bounty on %s waits in layer %s - can you invite me to claim it?"):format(
		e.name ~= "" and e.name or "that killer", letter)
	local text = (SLASH_WHISPER1 or "/w") .. " " .. who .. " " .. line
	local open = (type(ChatFrameUtil) == "table" and ChatFrameUtil.OpenChat) or ChatFrame_OpenChat
	if type(open) == "function" then
		pcall(open, text)
		ns.pendingSwap.text = text
		Say("press Enter to whisper %s for layer %s, then accept the invite.", who, letter)
	else
		Say("whisper %s: %s", who, line)
	end
	return true
end

-- Read the killer's level from the unit that killed us, and the layer from the creatures standing
-- around us. There is no layer API on this client: LayerSwap reads Creature-0-<server>-<map>-... GUIDs
-- and compares the <server> number, and one creature is enough while nothing else is known. A
-- player's own pet carries the layer where it was summoned, so player-controlled creatures are
-- skipped. Every read is guarded; a secret or absent answer is simply left unknown.
-- atDeath: the one moment when our own LayerSwap layer is valid for the killer. He killed us on
-- the layer we are standing on, so if no nearby creature gave a letter we may use ours. The same
-- fallback is never allowed for a later sighting or a synced row: that is what merged everyone.
ns.KillerInfo = function(guid, name, atDeath)
	local level, layer
	local seen, votes = {}, {}
	local function read(unit)
		local raw = Ask(UnitGUID, unit)
		if Secret(raw) or type(raw) ~= "string" or #raw > 64 then return end
		if raw:sub(1, 7) == "Player-" then ns.RememberLevel(unit) end
		if guid and raw == guid and Ask(UnitExists, unit) ~= false then
			local lv = ns.ReadLevel(unit)
			if lv then level = lv end
		end
		-- Creature-0-<server>-<map>-<zoneUID>-<npc>-<spawn>, exactly the fields LayerSwap checks.
		-- Lua patterns have no alternation, so try the two accepted GUID kinds separately.
		local zero, server, zone
		if raw:sub(1, 9) == "Creature-" then
			zero, server, zone = raw:match("^Creature%-(%d+)%-(%d+)%-(%d+)%-")
		elseif raw:sub(1, 8) == "Vehicle-" then
			zero, server, zone = raw:match("^Vehicle%-(%d+)%-(%d+)%-(%d+)%-")
		end
		if not zero or zero ~= "0" or not server or not zone then return end
		if Ask(UnitPlayerControlled, unit) == true then return end
		if seen[raw] then return end
		seen[raw] = true
		local n = Num(server, 1, 9999999)
		if not n then return end
		-- LayerSwap compares the numeric key but shows the letter. An unmapped number proves
		-- nothing about the layer letter, so it is not a vote at all.
		local part = ns.LayerLetter(n)
		if part then
			votes[part] = (votes[part] or 0) + 1
			layer = part
		end
	end
	-- The game can still hand out a token for the killer's GUID on the death screen; Olympus puts
	-- that token first for exactly this reason, then falls back to every visible unit.
	if guid and type(UnitTokenFromGUID) == "function" then
		local ok, token = pcall(UnitTokenFromGUID, guid)
		if ok and type(token) == "string" and not Secret(token) then read(token) end
	end
	for _, unit in ipairs(ns.InfoUnits()) do read(unit) end
	-- Some builds hand out plate frames but no nameplateN token. Read the tokens off the plates
	-- themselves as well, before giving up on the level.
	if type(C_NamePlate) == "table" and type(C_NamePlate.GetNamePlates) == "function" then
		local ok, plates = pcall(C_NamePlate.GetNamePlates)
		if ok and type(plates) == "table" then
			for _, plate in ipairs(plates) do
				if type(plate) == "table" then
					local unit = plate.namePlateUnitToken or plate.unit
					if unit then read(unit) end
				end
			end
		end
	end
	-- Prefer a layer more than one creature agrees on if several letters turned up. Never fall back
	-- to our own LayerSwap layer: that marked every killer with an unread layer as the same layer.
	local best, bestN = nil, 0
	for n, count in pairs(votes) do
		if count > bestN or (count == bestN and n < (best or n)) then best, bestN = n, count end
	end
	if not level and guid then
		local row = ns.seenLevels[guid]
		if row and Clock() - (tonumber(row.at) or 0) <= 120 then level = row.level end
	end
	-- Last resorts: the guild roster by full name, then Olympus's own saved evidence for this exact
	-- killer. Both are real client readings, never a guess from a title or a shared first name.
	if not level and name then level = ns.GuildLevel(name) end
	if not level then level = ns.OlympusLevel(guid, name) end
	if level and guid and not ns.seenLevels[guid] then
		ns.seenLevels[guid] = { level = level, at = Clock() }
	end
	local resultLayer = best or layer
	if not resultLayer and atDeath then resultLayer = ns.MyLayer() end
	-- A read made outside the death window only proves a level; it must not put a layer on an
	-- old kill. The death's own AddKill call stores the layer with layerNew set instead.
	ns.RememberKillerInfo(guid, level, resultLayer, resultLayer and Clock() or nil, false)
	return level, resultLayer
end

-- Death rows and this client's own proof can still hold a level the board row lost (an older
-- guildmate can sync a letter without the number). Read those before saying "unknown" in chat.
-- Both sources must name this exact GUID, and their layer must still be inside LAYER_TTL.
ns.ExtraKillerInfo = function(e)
	if not e then return nil, nil, 0 end
	local level, layer, layerAt
	local proof = type(ns.localProof) == "table" and ns.localProof[e.guid] or nil
	if proof then
		level = Num(proof.klevel, 1, 100)
		if ns.LayerFresh(proof) then
			layer = ns.LayerPart(proof.klayer)
			layerAt = tonumber(proof.klayerAt) or 0
		end
	end
	local s = Store()
	if type(s.deaths) == "table" then
		for _, d in ipairs(s.deaths) do
			if d.kguid == e.guid then
				if not level then level = Num(d.klevel, 1, 100) end
				if not layer and ns.LayerFresh(d) then
					layer = ns.LayerPart(d.klayer)
					layerAt = tonumber(d.klayerAt) or tonumber(d.at) or 0
				end
				if level and layer then break end
			end
		end
	end
	return level, layer, layerAt or 0
end

-- A row rescued from an older profile (or from a death where nothing was readable) can still be
-- filled in later, but only from a unit we can actually see now. Never invent a number or a layer.
ns.FillKillerInfo = function(e)
	if not e then return false end
	local level, layer = ns.KillerInfo(e.guid, e.name)
	local layerAt = layer and Clock() or 0
	local extraLevel, extraLayer, extraAt = ns.ExtraKillerInfo(e)
	level = level or extraLevel
	if not layer then layer, layerAt = extraLayer, extraAt end
	local changed = false
	if level and not Num(e.klevel, 1, 100) then e.klevel = level changed = true end
	-- Only a kill captured at death may ever gain a layer. A saved kill seen later keeps its level
	-- but stays layerless, however clearly the unit is standing in front of us now.
	if layer and e.layerNew == true then
		e.klayer = ns.LayerValue(layer)
		e.klayerAt = layerAt > 0 and layerAt or Clock()
		changed = true
	end
	if changed then
		ns.RememberKillerInfo(e.guid, e.klevel, e.klayer, e.klayerAt, e.layerNew)
		Bump(e)
		Broadcast(e, false)
	end
	return changed
end

-- Existing profiles were saved with klevel/klayer at 0 (or with a raw numeric layer). On login,
-- repair every row from evidence this client already has, without sending addon traffic: a fresh
-- death still uses FillKillerInfo and broadcasts normally. Nothing here invents a value.
ns.BackfillSavedInfo = function()
	local s = Store()
	local fixed = 0
	for _, e in pairs(s.entries) do
		if type(e) == "table" then
			local changed = false
			local mapped = ns.LayerPart(e.klayer)
			if mapped and mapped ~= tostring(e.klayer) then
				e.klayer = mapped
				e.klayerAt = tonumber(e.klayerAt) or tonumber(e.at) or 0
				changed = true
			end
			if not Num(e.klevel, 1, 100) or not ns.LayerFresh(e) then
				local level, layer = ns.KillerInfo(e.guid, e.name)
				local layerAt = layer and Clock() or 0
				local extraLevel, extraLayer, extraAt = ns.ExtraKillerInfo(e)
				level = level or extraLevel
				if not layer then layer, layerAt = extraLayer, extraAt end
				if level and not Num(e.klevel, 1, 100) then e.klevel = level changed = true end
				if layer and e.layerNew == true then
					e.klayer = ns.LayerValue(layer)
					e.klayerAt = layerAt > 0 and layerAt or Clock()
					changed = true
				end
			end
			if changed then
				fixed = fixed + 1
				ns.RememberKillerInfo(e.guid, e.klevel, e.klayer, e.klayerAt, e.layerNew)
				Bump(e)
			end
		end
	end
	return fixed
end

-- Map pins: HereBeDragons-Pins draws these for us from the same 0..1 coordinates used by the board.
-- They are visible only to people running this addon (there is no addon API for a shared world
-- marker), and a "nearby" point is drawn in rust and says so in the tooltip - never as an exact pin.
function MapLib.GamepadUI()
	local current = C_InputInterfaceStyle and C_InputInterfaceStyle.GetCurrentStyle
	local gamepad = Enum and Enum.InputDeviceInterfaceType and Enum.InputDeviceInterfaceType.Gamepad
	if not current or gamepad == nil then return false end
	local ok, style = pcall(current)
	return ok and style == gamepad
end

function MapLib.Pins()
	if LibStub == nil then return nil end
	local ok, pins = pcall(function() return LibStub("HereBeDragons-Pins-2.0", true) end)
	if not ok or type(pins) ~= "table" then return nil end
	if type(pins.AddWorldMapIconMap) ~= "function" or type(pins.AddMinimapIconMap) ~= "function"
		or type(pins.RemoveAllWorldMapIcons) ~= "function"
		or type(pins.RemoveAllMinimapIcons) ~= "function" then return nil end
	return pins
end

function MapLib.PinAge(spot)
	local at = tonumber(spot and spot.at)
	if not at then return PIN_TTL + 1 end
	return Clock() - at
end

function MapLib.PinExpired(spot)
	return MapLib.PinAge(spot) >= PIN_TTL
end

-- Only active pins can become due. Checking them (instead of every stored spot) means a row that
-- loaded from an old saved game does not make the 1 s ticker refresh forever.
function MapLib.HasExpired()
	for i = 1, #MapLib.active do
		if MapLib.active[i].spot and MapLib.PinExpired(MapLib.active[i].spot) then return true end
	end
	return false
end

function MapLib.MakePin()
	local pair = {}
	local function one(kind, size)
		local p = CreateFrame("Frame", nil, UIParent)
		p:SetSize(size, size)
		p:EnableMouse(true)
		p.pinKind = kind
		local icon = p:CreateTexture(nil, "OVERLAY")
		icon:SetAllPoints(p)
		icon:SetTexture(MapLib.pinArt)
		p.icon = icon
		p:SetScript("OnEnter", function(self)
			local e = self.entry
			if not e then return end
			if not GameTooltip then return end
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:AddLine(Plain(e.name or "unknown") .. " - last known location", 1, 0.82, 0)
			GameTooltip:AddLine(SpotLine(e) or "last known location unavailable", 1, 1, 1, true)
			if e.spot and e.spot.kind == "nearby" then
				GameTooltip:AddLine("nearby, not an exact killer pin", 0.95, 0.55, 0.3)
			end
			GameTooltip:Show()
		end)
		p:SetScript("OnLeave", function()
			if GameTooltip then GameTooltip:Hide() end
		end)
		return p
	end
	pair.world = one("world", 24)
	pair.mini = one("minimap", 18)
	return pair
end

function MapLib.Release(pins)
	pins = pins or MapLib.Pins()
	if pins then
		pcall(pins.RemoveAllWorldMapIcons, pins, MapLib)
		pcall(pins.RemoveAllMinimapIcons, pins, MapLib)
	end
	for i = #MapLib.active, 1, -1 do
		local a = MapLib.active[i]
		a.world:Hide()
		a.mini:Hide()
		a.world.entry, a.mini.entry, a.entry, a.spot = nil, nil, nil, nil
		MapLib.pinPool[#MapLib.pinPool + 1] = a
		MapLib.active[i] = nil
	end
	MapLib.pinCount, MapLib.worldCount, MapLib.miniCount = 0, 0, 0
end

function MapLib.Refresh()
	MapLib.pinDirty = false
	if not ns.Enabled() then
		MapLib.Release(nil)
		return 0
	end
	local pins = MapLib.Pins()
	if not pins then
		MapLib.Release(nil)
		return 0
	end
	MapLib.Release(pins)
	local gamepad = MapLib.GamepadUI()
	local s = Store()
	for _, e in pairs(s.entries) do
		local spot = e and e.spot
		if spot and spot.map and spot.x and spot.y and not MapLib.PinExpired(spot) then
			local map = tonumber(spot.map)
			local x, y = tonumber(spot.x) / SPOT_GRID, tonumber(spot.y) / SPOT_GRID
			if map and MapLib.ValidPoint(x, y) then
				local a = table.remove(MapLib.pinPool) or MapLib.MakePin()
				local near = (spot.kind == "nearby")
				a.entry, a.spot = e, spot
				a.world.entry, a.mini.entry = e, e
				a.world:SetSize(24, 24)
				a.mini:SetSize(18, 18)
				if near then
					a.world.icon:SetVertexColor(0.95, 0.45, 0.2, 1)
					a.mini.icon:SetVertexColor(0.95, 0.45, 0.2, 1)
				else
					a.world.icon:SetVertexColor(1, 0.82, 0, 1)
					a.mini.icon:SetVertexColor(1, 0.82, 0, 1)
				end
				a.world:Show()
				a.mini:Show()
				local wok, wadded = false, false
				if not gamepad then
					wok, wadded = pcall(pins.AddWorldMapIconMap, pins, MapLib, a.world, map,
						x, y, MapLib.showFlag)
					wok, wadded = (wok and wadded ~= false), nil
				end
				local mok, madded = pcall(pins.AddMinimapIconMap, pins, MapLib, a.mini, map,
					x, y, false, true)
				mok = (mok and madded ~= false)
				if not wok then a.world:Hide() end
				if not mok then a.mini:Hide() end
				if wok or mok then
					MapLib.active[#MapLib.active + 1] = a
					MapLib.pinCount = MapLib.pinCount + 1
					if wok then MapLib.worldCount = MapLib.worldCount + 1 end
					if mok then MapLib.miniCount = MapLib.miniCount + 1 end
				else
					a.world.entry, a.mini.entry, a.entry, a.spot = nil, nil, nil, nil
					MapLib.pinPool[#MapLib.pinPool + 1] = a
				end
			end
		end
	end
	return MapLib.pinCount
end

-- What the client will actually let this addon read. It is printed by /kos where and whenever a
-- death has no spot, so "nothing showed up" is never a silent mystery.
local function MapProbeLine()
	local parts = {}
	for _, unit in ipairs({ "player", "target", "mouseover" }) do
		local map = Ask(C_Map and C_Map.GetBestMapForUnit, unit)
		local pos = map and Ask(C_Map and C_Map.GetPlayerMapPosition, map, unit)
		local gx, gy = MapLib.XY(pos)
		parts[#parts + 1] = ("%s: map %s %s"):format(unit, tostring(map or "none"),
			gx and (("%.1f, %.1f"):format(gx / 10, gy / 10)) or "no point")
	end
	return table.concat(parts, " | ")
end

local function SpotStatus(e)
	return ns.KnownSpot(e, " - the client gave no readable map point (" .. MapProbeLine() .. ")")
end

local function DeathColor(d)
	local hex = COLORS[d and d.kclass or ""] or "ffd100"
	return "|cff" .. hex
end

local function SendDigest(urgent)
	if not CanSend() then return false end
	local s = Store()
	local rows = {}
	for _, e in pairs(s.entries) do rows[#rows + 1] = RowFor(e, true) end
	for guid, stamp in pairs(s.removed) do rows[#rows + 1] = "R~" .. guid .. "~" .. tostring(stamp) end
	-- history too, newest first, so a member who just installed the addon still sees who has been
	-- killing the guild (a sane cap: the whole feed would not fit in one chunk set)
	local deaths = s.deaths or {}
	for i = 1, math.min(#deaths, DIGEST_DEATHS) do rows[#rows + 1] = DeathRow(deaths[i]) end
	-- the monthly credits and the payment travel too, so a member who installs mid-month sees the
	-- same ranking, the same prize pool and the same settlement
	local board = s.board or {}
	for i = 1, math.min(#(board.ledger or {}), DIGEST_DEATHS) do
		local rec = board.ledger[i]
		rows[#rows + 1] = Board.BoardRow({ kind = "C", who = rec.who, target = rec.target,
			tname = rec.tname, amount = rec.amount, at = rec.at })
	end
	if board.award and board.award.who and board.award.who ~= "" then
		rows[#rows + 1] = Board.BoardRow({ kind = "P", who = board.award.who,
			by = board.award.by, month = board.award.month, at = board.award.at })
	end
	-- The audit travels to managers only, so a late-joining officer sees who did what too.
	if Board.CanManage() then
		local audit = s.audit or {}
		for i = 1, math.min(#audit, Board.AUDIT_DIGEST) do
			rows[#rows + 1] = Board.AuditRow(audit[i])
		end
	end
	if #rows == 0 then return false end
	QueueParts(table.concat(rows, ";"), urgent)
	return true
end

-- ============================================================================ the guild bank

local function BankMoney()
	local v = Ask(GetGuildBankMoney)
	if type(v) ~= "number" or v < 0 then return nil end
	return math.floor(v)
end

local function BankWithdraw()
	local v = Ask(GetGuildBankWithdrawMoney)
	if type(v) ~= "number" or v < 0 then return nil end
	return math.floor(v)
end

-- A bounty is LIVE the moment a member asks for it. Nobody waits for a bank run and the addon never
-- reads a balance to decide whether a bounty exists. The requester owes the 1g to the guild bank;
-- that debt is recorded on the entry and cleared by a manager with /kos paidup <name>.
local function Fund(entry)
	if not entry then return false, "no entry" end
	local e = entry
	if e.paid or e.refunded or e.refundDue then
		return false, "that bounty is settled - start a new one from the name"
	end
	-- Flat 1g, regardless of any old 3g value still sitting in a saved or synced row.
	local amount = DEFAULT_REWARD
	if (tonumber(e.funded) or 0) >= amount then
		return false, ("%s already has a live bounty"):format(e.name)
	end
	e.want = amount
	e.funded = amount
	e.fundedBy = MyName()
	e.fundedAt = Clock()
	e.cutPct = tonumber(DB().cutPercent) or 0
	e.paidUp = false
	Bump(e)
	Broadcast(e, false)
	RefreshIfShown()
	return true, amount, amount
end

-- Ask for a bounty from a name or a right-click. It is live at once and shared on the next message,
-- so every guildmate sees the same funded row without anybody opening the bank.
local function StartJob(entry, speak)
	if not entry then return false, "no entry" end
	local e = entry
	local ok, amount, why = Fund(e)
	if not ok and not why then why = amount end  -- Fund's refusal is its second return
	-- If he is on screen now, improve the death spot. Never use the reader's own position here.
	local fresh = CaptureSpot(e.guid, e.name, false)
	if SpotBetter(fresh, e.spot) then
		e.spot = fresh
		Bump(e)
		Broadcast(e, false)
	end
	RefreshIfShown()
	if speak ~= false and DB().notices ~= false then
		local where = SpotLine(e)
		local suffix = where and (" " .. where) or ""
		if ok then
			Say("%s%s|r: |cffffd100live %s bounty|r - %s owes the bank that gold until a manager marks it paid (/kos paidup). On the kill, %s joins the prize pool and the bank keeps %s.%s",
				ClassColor(e), e.name, Money(amount), e.fundedBy ~= "" and e.fundedBy or MyName(),
				Money(PayoutOf(amount)), Money(CutOf(amount)), suffix)
		else
			Say("%s%s|r: %s%s", ClassColor(e), e.name, tostring(why), suffix)
		end
	end
	return ok, e, why
end

-- ============================================================================ applying rows

local function Notify(entry, fresh)
	if DB().notices == false then return end
	local who = ClassColor(entry) .. (entry.name ~= "" and entry.name or "?") .. "|r"
	local why = entry.kills > 1 and ("%d guild members"):format(entry.kills) or "a guild member"
	local state = StateOf(entry)
	local suffix = " " .. ns.KnownSpot(entry, " - the client gave no readable map point.")
	local info = ns.KillerLine(entry)
	local detail = info and (" killer: " .. info .. ".") or ""
	if state == "unfunded" then
		Notice("%s killed %s - on the board, nobody has asked for a bounty yet. |cffca9455/kos fund %s|r makes a %s bounty live at once.%s%s",
			who, why, entry.name, Money(DEFAULT_REWARD), suffix, detail)
		return
	end
	if fresh then
		Notice("%s killed %s - %s bounty, %s joins this month's prize pool.%s%s",
			who, why, Money(entry.funded), Money(PayoutOf(entry.funded)), suffix, detail)
	else
		Notice("%s is on the board - %s bounty, %s.%s%s", who, Money(entry.funded), StateText(entry), suffix, detail)
	end
end

local function MergeRows(mine, theirs)
	local merged = mine
	merged.kills = math.max(mine.kills or 0, theirs.kills or 0)
	if (tonumber(theirs.killAt) or 0) > (tonumber(mine.killAt) or 0) then
		merged.killAt, merged.at = theirs.killAt, theirs.killAt
	end
	merged.want = DEFAULT_REWARD
	merged.funded = math.min(math.max(mine.funded or 0, theirs.funded or 0), DEFAULT_REWARD)
	merged.paid = mine.paid or theirs.paid
	merged.refunded = mine.refunded or theirs.refunded
	merged.refundDue = mine.refundDue or theirs.refundDue
	-- once a manager has cleared a member's debt, no older row can put it back
	merged.paidUp = mine.paidUp or theirs.paidUp
	if (theirs.clearedAt or 0) > (mine.clearedAt or 0) then
		merged.clearedAt, merged.clearedBy = theirs.clearedAt, theirs.clearedBy
	end
	if (theirs.reborn or 0) > (mine.reborn or 0) then merged.reborn = theirs.reborn end
	if (theirs.klevel or 0) > (mine.klevel or 0) then merged.klevel = theirs.klevel end
	-- A layer is only a letter while it is inside its hour. Never copy an expired one, and never
	-- let an old client's row put a stale letter back over a newer reading we already have.
	local mineLayer, theirsLayer = ns.LayerFresh(mine), ns.LayerFresh(theirs)
	local mineLayerAt = tonumber(mine.klayerAt) or tonumber(mine.at) or 0
	local theirsLayerAt = tonumber(theirs.klayerAt) or tonumber(theirs.at) or 0
	if theirsLayer and (not mineLayer or theirsLayerAt > mineLayerAt) then
		merged.klayer = ns.LayerValue(theirsLayer)
		merged.klayerAt = theirsLayerAt
		merged.layerNew = true
	end
	-- keep the freshest sighting, so a later live sighting wins over an old "near where I died"
	if SpotBetter(theirs.spot, mine.spot) then merged.spot = theirs.spot end
	if (theirs.name or "") ~= "" then merged.name = theirs.name end
	if (theirs.class or "") ~= "" and (mine.class or "") == "" then merged.class = theirs.class end
	if (theirs.fundedBy or "") ~= "" then merged.fundedBy = theirs.fundedBy end
	if (theirs.paidTo or "") ~= "" then merged.paidTo = theirs.paidTo end
	if (theirs.refundedTo or "") ~= "" then merged.refundedTo = theirs.refundedTo end
	if not merged.fundedAt or merged.fundedAt == 0 then merged.fundedAt = theirs.fundedAt end
	for i = 1, #theirs.victims do AddUnique(merged.victims, theirs.victims[i], MAX_VICTIMS) end
	for i = 1, #theirs.claims do
		local c = theirs.claims[i]
		local known = false
		for j = 1, #merged.claims do if merged.claims[j].name == c.name then known = true end end
		if not known then merged.claims[#merged.claims + 1] = c end
	end
	return merged
end

-- A level or layer this client proved is never lost to a guild row. Money, spots, claims and
-- removals still sync normally; only these two fields are pinned for the rest of the session.
local function KeepLocalProof(e)
	local p = type(ns.localProof) == "table" and ns.localProof[e.guid] or nil
	if not p then return end
	if Num(p.klevel, 1, 100) then e.klevel = p.klevel end
	local proofLayer = ns.LayerFresh(p)
	if proofLayer then
		e.klayer = ns.LayerValue(proofLayer)
		e.klayerAt = tonumber(p.klayerAt) or 0
		e.layerNew = true
	end
end

local function ApplyEntry(remote)
	local s = Store()
	-- A manager's delete is final. An ordinary copy of the row never brings a deleted name back,
	-- however new its stamp looks on another clock. Only a fresh add (reborn > the delete) can.
	local tomb = tonumber(s.removed[remote.guid]) or 0
	if tomb > 0 and (tonumber(remote.reborn) or 0) <= tomb then return false end
	local mine = s.entries[remote.guid]
	local fresh = mine == nil
	if mine then
		if remote.stamp < mine.stamp then return false end
		if remote.stamp == mine.stamp then
			local merged = MergeRows(mine, remote)
			KeepLocalProof(merged)
			Bump(merged)
			s.entries[remote.guid] = merged
			Broadcast(merged, true)
			RefreshIfShown()
			return false
		end
	end
	Observe(remote.stamp)
	-- The shared kill time decides the board order. A sync arriving late must not move a name to
	-- the top; only an actual new kill does that. An old client has no killAt field at all - keep
	-- the at time it sent instead of stamping Clock(), which made an old row look freshly killed.
	local kt = tonumber(remote.killAt) or 0
	if kt > 0 then remote.at = kt else remote.at = tonumber(remote.at) or Clock() end
	remote.auto = false
	remote.src = "shared"
	KeepLocalProof(remote)
	s.entries[remote.guid] = remote
	-- A newly shared row can carry a last-known spot. Without this the pin ticker sees nothing
	-- dirty and a guildmate's map stays empty until he reloads or runs /kos pins by hand.
	if remote.spot then MapLib.pinDirty = true end
	-- A row arriving already funded must put its skull up on this client straight away.
	if ns.RefreshMarks then pcall(ns.RefreshMarks) end
	if tomb > 0 then s.removed[remote.guid] = nil end
	stats.applied = stats.applied + 1
	if not remote.quiet then Notify(remote, fresh) end
	Trim()
	RefreshIfShown()
	return true
end

local function ApplyRemoval(row, sender)
	if not Board.CanManage(sender) then return false end
	local f = Fields(row)
	local guid = Guid(f[2])
	local stamp = Num(f[3], 0, 4294967295)
	if not guid or not stamp then return false end
	local s = Store()
	Observe(stamp)
	local mine = s.entries[guid]
	-- A delete from a manager wins over every older copy of the row. Only a genuine fresh add on
	-- this client (reborn newer than the delete) outranks it, so an old R row cannot erase it.
	if mine and (tonumber(mine.reborn) or 0) > stamp then return false end
	s.entries[guid] = nil
	if stamp > (tonumber(s.removed[guid]) or -1) then s.removed[guid] = stamp end
	MapLib.pinDirty = true
	if ns.RefreshMarks then pcall(ns.RefreshMarks) end
	RefreshIfShown()
	return true
end

local parts = {}

local function Handle(payload, sender)
	stats.recv = stats.recv + 1
	if type(payload) ~= "string" or payload == "" then return end
	if sender and SameName(sender, MyName()) then return end
	for row in payload:gmatch("[^;]+") do
		local kind = row:sub(1, 1)
		if kind == "E" then
			local entry = ParseEntry(row)
			if entry then
				-- A plain member's bounties, deposits and deaths still sync; only a hand-over flag
				-- from a member is ignored, so one cannot settle a refund on everybody's board.
				if not Board.CanManage(sender) then
					entry.refunded, entry.refundedBy = nil, nil
					entry.refundedTo, entry.refundedAt = nil, nil
				end
				ApplyEntry(entry)
			end
		elseif kind == "R" then
			ApplyRemoval(row, sender)
		elseif kind == "D" then
			local d = ParseDeath(row)
			if d then ApplyDeath(d) end
		elseif kind == "B" then
			local rec = Board.ParseBoardRow(row)
			if rec then
				if rec.kind == "P" then Board.ApplyBoardPaid(rec, sender)
				else Board.ApplyBoardCredit(rec) end
			end
		elseif kind == "L" then
			-- Audit rows are manager-only: no entry at all on a plain member's client.
			if Board.CanManage() then
				local rec = Board.ParseAudit(row)
				if rec then Board.ApplyAudit(rec, sender) end
			end
		elseif kind == "Q" or kind == "H" then
			if Mono() - (ns.lastDigest or 0) > 25 then
				ns.lastDigest = Mono()
				SendDigest(false)
			end
		end
	end
end

local function OnAddonMessage(prefix, text, dist, sender)
	if prefix ~= PREFIX then return end
	if Secret(prefix, text, dist, sender) then return end
	if type(text) ~= "string" or text == "" then return end
	if dist ~= "GUILD" then return end
	if Ask(IsInGuild) ~= true then return end
	text = Plain(text)
	if not text or text == "" then return end
	local id, index, count = text:match("^C(%d+):(%d+):(%d+):")
	if id then
		id, index, count = tonumber(id), tonumber(index), tonumber(count)
		if not id or not index or not count or count < 1 or count > 40 or index < 1 or index > count then return end
		local body = text:match("^C%d+:%d+:%d+:(.*)$") or ""
		local slot = parts[id]
		if not slot or slot.count ~= count or Mono() - slot.at > 30 then
			slot = { count = count, got = {}, seen = 0, at = Mono() }
			parts[id] = slot
		end
		if not slot.got[index] then
			slot.got[index] = body
			slot.seen = slot.seen + 1
		end
		if slot.seen == count then
			local whole = {}
			for i = 1, count do whole[i] = slot.got[i] or "" end
			parts[id] = nil
			Handle(table.concat(whole), sender)
		end
		return
	end
	Handle(text, sender)
end

-- ============================================================================ the board

local function AddKill(guid, name, class, src, reason, spot, klevel, klayer)
	guid = Guid(guid)
	if not guid then return nil, "no guid" end
	local s = Store()
	local me = MyName()
	name = Clean(name or "", MAX_NAME)
	if name == "" then name = NameFromGUID(guid) or "Unknown" end
	class = ClassCode(class or "")
	if class == "" then class = ClassFromGUID(guid) or "" end

	local looseKey = "n:" .. name:lower()
	local loose = s.entries[looseKey]
	if loose then
		s.entries[looseKey] = nil
		if not s.entries[guid] then s.entries[guid] = loose end
		if s.entries[guid] == loose then
			loose.guid = guid
			BroadcastRemoval(looseKey)
		end
	end

	local e = s.entries[guid]
	local now = Clock()
	if not e then
		e = {
			guid = guid, name = name, class = class, kills = 0,
			want = 0, funded = 0, auto = true, at = now, killAt = now, by = me, src = src or "death",
			reason = "", victims = {}, claims = {}, paid = false,
			klevel = 0, klayer = 0, klayerAt = 0, layerNew = false, paidUp = false,
		}
		s.entries[guid] = e
	elseif e.refundDue then
		-- that refund is still owed back to its payer, so this kill waits for a fresh request
		e.paidTo, e.paidAt = nil, nil
		e.claims = {}
		e.paidUp = false
	elseif e.paid or e.refunded then
		-- a settled bounty does not pay twice: his next kill needs a fresh request
		e.paid = false
		e.refunded = nil
		e.refundDue = nil
		e.funded = 0
		e.paidUp = false
		e.fundedBy, e.fundedAt, e.paidTo, e.paidAt = nil, nil, nil, nil
		e.refundedTo, e.refundedAt = nil, nil
		e.clearedAt, e.clearedBy = nil, nil
		e.claims = {}
	end
	e.kills = (tonumber(e.kills) or 0) + 1
	e.at, e.killAt = now, now
	if spot then e.spot = spot end
	if name ~= "" then e.name = name end
	if class ~= "" then e.class = class end
	if Num(klevel, 1, 100) then e.klevel = klevel end
	-- Only the death that puts him on the board is a new kill. A row restored from shared history
	-- carries the old letter too, but it must never be shown again. Marking the kill new even when
	-- no layer was readable lets the delayed sighting fill one in inside that first hour.
	if src == "death" then
		e.layerNew = true
		if ns.LayerPart(klayer) then
			e.klayer = ns.LayerValue(klayer)
			e.klayerAt = now
		end
	end
	ns.RememberKillerInfo(guid, e.klevel, e.klayer, e.klayerAt, e.layerNew)
	e.want = math.max(tonumber(DB().defaultReward) or 0, tonumber(e.funded) or 0)
	e.cutPct = tonumber(e.cutPct) or tonumber(DB().cutPercent) or 0
	e.reason = Clean(reason or (src == "manual" and ("added by " .. me) or ("killed " .. me)), MAX_REASON)
	AddUnique(e.victims, me, MAX_VICTIMS)
	Bump(e)
	-- A name added again is a new life for this guid. The birth stamp travels on the row so every
	-- client can clear its delete marker; an old copy without it stays deleted.
	e.reborn = e.stamp
	if s.removed[guid] then s.removed[guid] = nil end
	Trim()
	Notify(e, e.kills == 1)
	Broadcast(e, false)
	RefreshIfShown()
	return e
end

local PoolKill

local function ClaimKill(guid, who)
	local e = Entry(guid)
	if not e or e.paid then return false, "paid" end
	who = Clean(who or MyName(), MAX_NAME)
	if (tonumber(e.funded) or 0) <= 0 then
		Notice("%s killed %s, but no bounty is funded - nothing joins the prize pool.", who, e.name)
		return false, "unfunded"
	end
	AddClaim(e, who, Clock())
	Bump(e)
	Broadcast(e, false)
	RefreshIfShown()
	-- The monthly board counts only this exact kind of kill: a live, fully funded, unsettled bounty
	-- that somebody else paid for. A name, a pending job, a part-paid row or self-funding earns none.
	-- Its 70% share is booked into the month's single prize pool, not paid to this hunter now.
	local funded, want = tonumber(e.funded) or 0, tonumber(e.want) or 0
	if want > 0 and funded >= want and not e.refundDue and not e.refunded
		and not SameName(e.fundedBy, who) then
		local amount = math.min(funded, want)
		if Board.BoardCredit({ kind = "C", who = who, target = e.guid, tname = e.name,
			amount = amount, at = Clock() }) then
			PoolKill(e.guid, who)
		end
	end
	return true
end

-- A credited kill is settled: its 70% is now part of this month's single prize pool. "paid" here
-- means the bounty is closed (the bank keeps its 30%, the hunter's share is pooled), NOT that a
-- hunter was handed gold. The pool is paid once, to the board leader, with /kos boardpaid.
PoolKill = function(guid, by)
	local e = Entry(guid)
	if not e then return false, "no entry" end
	if (tonumber(e.funded) or 0) <= 0 then return false, "no money was ever funded" end
	if e.paid then return false, "already in the prize pool" end
	e.paid = true
	e.paidTo = Clean(by or (e.claims and e.claims[1] and e.claims[1].name) or "?", MAX_NAME)
	e.paidAt = Clock()
	e.paidBy = Clean(by or MyName(), MAX_NAME)
	e.refunded, e.refundDue = nil, nil
	e.refundedTo, e.refundedAt = nil, nil
	Bump(e)
	Broadcast(e, false)
	RefreshIfShown()
	Say("|cffffd100%s|r killed %s - %s goes into this month's prize pool; the bank keeps %s.",
		e.paidTo, ClassColor(e) .. e.name, Money(PayoutOf(e.funded)), Money(CutOf(e.funded)))
	return true
end

-- The refund is decided here, not done here. The gold is still in the bank and only a human can take
-- it out, so the board keeps it (funded stays) and it goes on the officers' list until somebody says
-- they actually handed it over.
local function Expire(guid, why)
	local e = Entry(guid)
	if not e then return false, "no entry" end
	if e.paid then return false, "already paid" end
	if e.refunded then return false, "already handed back" end
	if e.refundDue then return false, "already waiting to be handed back" end
	local funded = tonumber(e.funded) or 0
	if funded <= 0 then return false, "nothing was funded" end
	if e.claims and #e.claims > 0 then
		return false, "somebody has claimed him - his 70% is in this month's prize pool"
	end
	e.refundDue = true
	e.refundedTo = Clean(e.fundedBy ~= "" and e.fundedBy or MyName(), MAX_NAME)
	e.refundedAt = Clock()
	e.want = math.max(tonumber(e.want) or 0, funded)
	Board.Audit("F", why == "expired" and "addon" or MyName(), e.name, Money(funded))
	Bump(e)
	Broadcast(e, false)
	RefreshIfShown()
	if why == "expired" then
		Say("|cffffd100%s|r expired unclaimed after %d days - %s goes back to %s.",
			e.name, tonumber(e.refundDays) or tonumber(DB().refundDays) or 0, Money(funded), e.refundedTo)
	else
		Say("|cffffd100%s|r is being refunded - %s goes back to %s.", e.name, Money(funded), e.refundedTo)
	end
	Say("the addon cannot take gold out of the bank: this stays on the officers' list until somebody hands it over. /kos officers")
	return true
end

local function Refund(guid)
	if not Board.CanManage() then return false, Board.DENIED end
	return Expire(guid, "manual")
end

-- Somebody took the gold out of the bank and gave it back: this is the only way a refund finishes.
local function ConfirmRefund(guid, by)
	if not Board.CanManage() then return false, Board.DENIED end
	local e = Entry(guid)
	if not e then return false, "no entry" end
	if not e.refundDue then return false, "no refund is waiting on him" end
	local amount = tonumber(e.funded) or 0
	e.refundDue = nil
	e.refunded = true
	e.refundedTo = Clean(e.refundedTo ~= "" and e.refundedTo or e.fundedBy or "?", MAX_NAME)
	e.refundedAt = Clock()
	e.refundedBy = Clean(by or MyName(), MAX_NAME)
	e.funded = 0
	e.want = 0
	e.claims = {}
	local s = Store()
	s.bank.refunded = (tonumber(s.bank.refunded) or 0) + amount
	s.bank.at = Clock()
	Board.Audit("H", by or MyName(), e.name, Money(amount))
	Bump(e)
	Broadcast(e, false)
	RefreshIfShown()
	Say("%s handed %s back to %s - off the officers' list.", e.refundedBy, Money(amount), e.refundedTo)
	return true, amount
end

-- The only per-bounty hand-over left is a refund. The hunter's 70% is never paid here: it waits in
-- this month's prize pool and goes to the board leader with /kos boardpaid.
local function HandOver(guid, by)
	local e = Entry(guid)
	if not e then return false, "no entry" end
	if e.refundDue then return (ConfirmRefund(guid, by)) end
	if e.paid then return false, "his 70% is already in this month's prize pool" end
	return false, "nothing to hand over on him - the board leader is paid at month end"
end

-- Anyone's client may sweep; the first broadcast wins because every row carries its revision.
local function Sweep()
	local now = Clock()
	if now <= 0 then return end
	Board.BoardRollover(now)
	local s = Store()
	for _, e in pairs(s.entries) do
		local due = RefundDue(e)
		if due and now >= due then Expire(e.guid, "expired") end
	end
end

-- ============================================================================ who owes what

-- A live bounty is on trust: the member who asked for it owes 1g to the bank until a manager marks
-- him paid up. This list is derived from the shared entries, so every client agrees on it and no
-- extra wire message is needed - field 23 of an E row carries the cleared flag.
local function Ious()
	local out = {}
	for _, e in pairs(Store().entries) do
		local amount = tonumber(e.funded) or 0
		if amount > 0 and not e.paidUp and not e.refunded and not e.refundDue then
			out[#out + 1] = {
				kind = "iou", name = e.fundedBy ~= "" and e.fundedBy or "the requester",
				amount = amount, target = e.name, entry = e,
			}
		end
	end
	table.sort(out, function(a, b)
		if (a.name or "") ~= (b.name or "") then return (a.name or "") < (b.name or "") end
		return (a.target or "") < (b.target or "")
	end)
	return out
end

-- GM or Valar clears one member's whole unpaid list. It is a bookkeeping flag on the shared rows;
-- the addon never takes or gives a copper.
local function PaidUp(name, by)
	if not Board.CanManage() then return false, Board.DENIED end
	name = Clean(name or "", MAX_NAME)
	if name == "" then return false, "usage: /kos paidup <name>" end
	local n = 0
	for _, e in pairs(Store().entries) do
		if (tonumber(e.funded) or 0) > 0 and not e.paidUp
			and not e.refunded and not e.refundDue and SameName(e.fundedBy, name) then
			e.paidUp = true
			-- Kept on the shared row so the ledger can show the date and the person who cleared it
			-- on every client, not just the one that pressed the button.
			e.clearedAt, e.clearedBy = Clock(), Clean(by or MyName(), 24)
			Board.Audit("U", by or MyName(), e.name, "debt cleared for " .. name)
			Bump(e)
			Broadcast(e, false)
			n = n + 1
		end
	end
	RefreshIfShown()
	if n == 0 then return false, ("no unpaid bounty is owed by %s"):format(name) end
	Say("%s is marked paid up - %d bounty debt%s cleared.", name, n, n == 1 and "" or "s")
	return true, n
end

-- Declared here so the ledger's frozen-order helpers below capture this ui table, not a global.
local rowHeight, ui = 18, {}

-- The debts ledger. Every bounty paid on trust stays here after it is cleared, so the window shows
-- both what is owed now and what was paid up before. It is derived from the shared rows, so a
-- guildmate's /kos paidup reaches everybody; fields 31/32 carry the cleared date and cleanser.
ns.DebtLedger = function()
	local out = {}
	for _, e in pairs(Store().entries) do
		local amount = tonumber(e.funded) or 0
		local who = Clean(e.fundedBy, 24)
		if amount > 0 and who ~= "" then
			local status, when, by, rank
			if e.refunded then
				status, when, by, rank = "refunded", e.refundedAt, e.refundedTo, 3
			elseif e.refundDue then
				status, when, by, rank = "refund due", e.fundedAt, "", 1
			elseif e.paidUp then
				status, when, by, rank = "paid up", e.clearedAt, e.clearedBy, 2
			else
				status, when, by, rank = "owes bank", e.fundedAt, "", 0
			end
			out[#out + 1] = {
				guid = e.guid, who = who, amount = amount,
				target = Clean(e.name, MAX_NAME) or "?", status = status,
				when = tonumber(when) or 0, by = by or "", rank = rank,
			}
		end
	end
	table.sort(out, function(a, b)
		if a.rank ~= b.rank then return a.rank < b.rank end
		if a.when ~= b.when then return a.when > b.when end
		return (a.who or "") < (b.who or "")
	end)
	return out
end

-- Same rule as the enemy board: the visible order is frozen while the tab is open. A sync that
-- clears a debt must not reshuffle the names already on screen.
ns.FreezeLedgerOrder = function()
	ui.ledgerOrder, ui.ledgerFresh = {}, true
	for i, row in ipairs(ns.DebtLedger()) do ui.ledgerOrder[i] = row.guid end
end

local function LedgerRows()
	 local all = ns.DebtLedger()
	 if type(ui.ledgerOrder) ~= "table" then ns.FreezeLedgerOrder() end
	 local byGuid, list, seen = {}, {}, {}
	 for i = 1, #all do byGuid[all[i].guid] = all[i] end
	 for i = 1, #ui.ledgerOrder do
		 local row = byGuid[ui.ledgerOrder[i]]
		 if row then list[#list + 1] = row seen[row.guid] = true end
	 end
	 for i = 1, #all do
		 if not seen[all[i].guid] then
			 list[#list + 1] = all[i]
			 ui.ledgerOrder[#ui.ledgerOrder + 1] = all[i].guid
		 end
	 end
	 return list
end

-- Every payment the bank still has to make, derived from the board itself so it travels with it:
--   monthly this month's single prize pool (all the 70% shares), owed to the board leader;
--           after a rollover, last month's pool stays here until a human records the hand-over.
--   refund  an unclaimed deposit goes back to whoever paid it in
-- Hunters are NOT paid per kill any more. The addon never moves gold, so these stay on the
-- officers' list until a human records the hand-over.
local function Debts()
	local out = {}
	local board = Store().board
	if board.month ~= "" then
		local winner = Board.BoardWinner(board.month)
		local fund = Board.FundForMonth(board.month)
		local a = board.award
		if winner and fund > 0
			and not (a.month == board.month and SameName(a.who, winner.who)) then
			out[#out + 1] = {
				kind = "monthly", name = winner.who, amount = fund, to = winner.who,
				hunter = winner,
			}
		end
	end
	local past = Board.PastPrize()
	if past then
		out[#out + 1] = {
			kind = "monthly", name = past.who, amount = past.prize, to = past.who,
			history = past,
		}
	end
	for _, e in pairs(Store().entries) do
		local funded = tonumber(e.funded) or 0
		if e.refundDue and not e.refunded and not e.paid then
			out[#out + 1] = {
				kind = "refund", name = e.name, amount = funded, entry = e,
				to = e.refundedTo ~= "" and e.refundedTo or (e.fundedBy ~= "" and e.fundedBy or "the payer"),
			}
		end
	end
	local rank = { monthly = 0, refund = 1 }
	table.sort(out, function(a, b)
		if (a.kind or "") ~= (b.kind or "") then return (rank[a.kind] or 9) < (rank[b.kind] or 9) end
		if (a.amount or 0) ~= (b.amount or 0) then return (a.amount or 0) > (b.amount or 0) end
		return (a.name or "") < (b.name or "")
	end)
	return out
end

local function OwedTotal(list)
	local total = 0
	for i = 1, #list do total = total + (tonumber(list[i].amount) or 0) end
	return total
end

-- The line that goes to the officers. Short enough for one chat message: members who still owe
-- the bank for a live bounty first, then the payments the bank has not handed over yet.
local function OwedLine(limit)
	local bank, ious = Debts(), Ious()
	if #bank == 0 and #ious == 0 then return nil end
	limit = limit or OFFICER_LIST
	local bits = {}
	if #ious > 0 then
		local names, total = {}, 0
		for i = 1, #ious do
			total = total + (tonumber(ious[i].amount) or 0)
			AddUnique(names, ious[i].name, 4)
		end
		if #names < #ious then names[#names + 1] = ("+%d more"):format(#ious - #names) end
		bits[#bits + 1] = ("members owe bank %s (%s)"):format(Money(total), table.concat(names, ", "))
	end
	if #bank > 0 then
		local paid = {}
		for i = 1, math.min(#bank, limit) do
			local d = bank[i]
			paid[#paid + 1] = ("%s %s %s"):format(
				Money(d.amount), d.kind == "refund" and "back to"
					or (d.kind == "monthly" and "prize pool to" or "to"), d.to)
		end
		if #bank > limit then paid[#paid + 1] = ("+%d more"):format(#bank - limit) end
		bits[#bits + 1] = ("bank owes %s: %s"):format(Money(OwedTotal(bank)), table.concat(paid, ", "))
	end
	return ("[KoS] %s - /kos owed"):format(table.concat(bits, "; "))
end

-- Officer chat only exists for the guild master and the first rank under him; "auto" uses what the
-- game says about this character's rank rather than guessing.
local function OfficerChannel()
	local mode = DB().officerMode or "auto"
	if mode == "guild" then return "GUILD" end
	if mode == "officer" then return "OFFICER" end
	-- Ask() only returns one value, and the rank is the third: read it directly so the guild master
	-- is not mistaken for a plain member.
	local rank
	if type(GetGuildInfo) == "function" then
		local ok, _, _, got = pcall(GetGuildInfo, "player")
		if ok and not Secret(got) then rank = got end
	end
	if type(rank) == "number" and rank <= 1 then return "OFFICER" end
	return "GUILD"
end

-- Chat needs a real key press or click on this client, so this is only ever called from a click or a
-- typed command. If the client refuses, the line lands in the chat box for one Enter.
local function PostOwed(channel)
	local list, ious = Debts(), Ious()
	if #list == 0 and #ious == 0 then Say("nothing is owed right now - the bank is square.") return false, "nothing" end
	local text = OwedLine()
	if #text > MSG_MAX then text = text:sub(1, MSG_MAX - 3) .. "..." end
	local ch = channel or OfficerChannel()
	local where = ch == "OFFICER" and "officer chat" or "guild chat"
	local ok = pcall(function() SendChatMessage(text, ch) end)
	if not ok then
		if pcall(function() ChatFrame_OpenChat(text) end) then
			Say("this client refused the %s line (it needs a key press) - it is in your chat box, press Enter.", where)
			return false, "opened"
		end
		Say("this client refused the %s line and the chat box could not be opened.", where)
		return false, "refused"
	end
	pendingOfficer = { text = text, at = Mono() }
	Say("said in %s: %s", where, text)
	return true
end

-- The reminder that keeps reminding. It cannot be posted for you (see above), so it says it here
-- every OFFICER_REMIND seconds for as long as one payment is open.
local function Remind()
	if DB().notices == false then return end
	local list, ious = Debts(), Ious()
	if #list == 0 and #ious == 0 then return end
	if #ious > 0 then
		local total = 0
		for i = 1, #ious do total = total + (tonumber(ious[i].amount) or 0) end
		Say("|cffffd100members still owe the bank %s|r (%d live bounty debt%s - /kos paidup <name>).",
			Money(total), #ious, #ious == 1 and "" or "s")
	end
	if #list > 0 then
		Say("|cffffd100the guild bank still owes %s|r (%d payment%s not handed over yet).",
			Money(OwedTotal(list)), #list, #list == 1 and "" or "s")
		for i = 1, math.min(#list, 4) do
			local d = list[i]
			Say("  %s: %s %s", d.name, Money(d.amount),
				d.kind == "refund" and ("back to " .. d.to)
				or (d.kind == "monthly" and ("prize pool to " .. d.to)) or ("to " .. d.to))
		end
		if #list > 4 then Say("  and %d more - /kos owed", #list - 4) end
	end
	Say("  click |cffffd100Officers|r in the window or type |cffffd100/kos officers|r to say it in %s.",
		OfficerChannel() == "OFFICER" and "officer chat" or "guild chat")
end

local function Remove(guid, force)
	if not Board.CanManage() then return false, Board.DENIED end
	local s = Store()
	local e = s.entries[guid]
	if not e then return false, "no entry" end
	if not force then
		if e.refundDue then
			return false, "the bank still has to hand that deposit back - /kos handed " .. (e.name or "")
		end
	end
	s.entries[guid] = nil
	Bump(e)
	-- A delete by the guild master or Valar is final. Use server time and the row's own birth stamp
	-- as the floor so an old client with a higher local counter cannot bring a stale copy back.
	-- This is the manager's own action, not a saved mode or a standing sync ticker.
	local born = tonumber(e.reborn) or 0
	local base = math.max(clock + 1, Clock(), born + 1, 1)
	if base > 4294967290 then base = clock + 1 end
	clock = base
	DB().clock = clock
	s.removed[guid] = base
	Board.Audit("R", MyName(), e.name, StateText(e) .. ", funded " .. Money(e.funded))
	MapLib.pinDirty = true
	BroadcastRemoval(guid)
	RefreshIfShown()
	return true
end

-- ============================================================================ deaths

local deathSerial, lastDeathKey, lastWhy = 0, nil, "no death seen yet"
local lastRecap, lastDeathAt = nil, nil
local lastNoticeKey = nil

-- How many rows a recap table holds: normally an array, but the count is taken from the integer
-- keys the client actually left rather than trusting #, so an unsequenced table is still read.
local function RecapRows(events)
	local n = 0
	if type(events) ~= "table" then return 0 end
	for k in pairs(events) do
		if type(k) == "number" and k == math.floor(k) and k > n then n = k end
	end
	return n
end

-- A number the row gives (a float included), or nil (nil, secret and unreadable all mean "the
-- client did not say", never "no").
local function RowNumber(v)
	if v == nil or Secret(v) then return nil end
	local ok, n = pcall(tonumber, v)
	if not ok or type(n) ~= "number" or n ~= n then return nil end
	return n
end

-- The killing blow, read the way the client's own Death Recap reads it (Blizzard_DeathRecap.lua:
-- the rows newest first, the first with overkill 0 or more is the one that killed). Deliberately
-- tolerant, because this client does not always fill every field: a float timestamp is floored, a
-- sourceGUID of a shape this addon cannot parse still leaves the killer's name, and a missing event
-- or flag mask is not a refusal. { row, index, stamp, at, guid, flags, event, name } or nil, why.
local function ReadRecapRow(row, i)
	local over = RowNumber(row.overkill)
	local stamp = RowNumber(row.timestamp)
	if stamp and (stamp < 0 or stamp > 4294967295) then stamp = nil end
	local flags = RowNumber(row.sourceFlags)
	return {
		row = row, index = i, over = over,
		stamp = stamp, at = stamp and math.floor(stamp) or nil,
		guid = Guid(row.sourceGUID),
		flags = flags and math.floor(flags) or nil,
		event = Plain(row.event),
		name = Clean(row.sourceName or "", MAX_NAME),
	}
end

local function KillingBlowRecap(events)
	local first, sawOver = nil, false
	for i = 1, RecapRows(events) do
		local row = events[i]
		if type(row) == "table" then
			local kb = ReadRecapRow(row, i)
			if not first then first = kb end
			if kb.over ~= nil and kb.over == math.floor(kb.over) then
				sawOver = true
				if kb.over >= 0 and kb.over <= 2147483647 then return kb end
			end
		end
	end
	-- (If not one row gave an overkill at all, this build leaves the field out entirely. The game's
	-- own window still treats the first row as the one that killed (causedDeath = i == 1), so that
	-- row is used rather than throwing the death away.)
	if not sawOver and first then return first end
	return nil, "no killing blow in the recap"
end

-- Whether the killing blow is a hostile player's damage. Only what the row actually says is used:
-- a row with no event is not refused for that, and a row with no flag mask is not refused either.
local function KillerIsHostile(kb)
	local event = kb.event
	if type(event) == "string" and event ~= "" and not event:match("_DAMAGE$") then
		return false, ("the killing blow was not damage (%s)"):format(event)
	end
	if kb.flags ~= nil and not (HasBit(kb.flags, 0x400) and HasBit(kb.flags, 0x40)) then
		return false, "the killer is not a hostile player"
	end
	return true
end

-- Whether a recap is this player's own death (a death counts only from the victim's own client). A
-- row that names its victim, in a shape this addon can parse, must name this player. A row that
-- names nobody - which is what the client's own last-death recap does - never vetoes, and a
-- destGUID this addon cannot parse is "unknown", not "somebody else".
local function VictimIsMe(events, myGuid)
	for i = 1, RecapRows(events) do
		local row = events[i]
		local dest = type(row) == "table" and row.destGUID or nil
		if not Secret(dest) and type(dest) == "string" and dest ~= "" then
			local d = Guid(dest)
			if d and myGuid and d ~= myGuid then return false end
		end
	end
	return true
end

-- Whether the player is in an instance, as the client answers it: true / false, or nil when the
-- client does not answer (nil is not "inside" - a death must not be thrown away because a single
-- API returned nothing).
local function InstanceState()
	local ok, inside = pcall(function() return IsInInstance and IsInInstance() end)
	if not ok or Secret(inside) then return nil end
	if inside == true or inside == 1 then return true end
	return false
end

local function CaptureDeath(serial)
	if serial ~= nil and serial ~= deathSerial then return false end
	local recap = C_DeathRecap
	if type(recap) ~= "table" or type(recap.HasRecapEvents) ~= "function"
		or type(recap.GetRecapEvents) ~= "function" then
		lastWhy = "this client has no death recap (C_DeathRecap)"
		return false
	end
	local okHas, has = pcall(recap.HasRecapEvents)
	if not okHas or Secret(has) or has ~= true then
		lastWhy = "the death recap is not ready"
		return false
	end
	local okRead, events = pcall(recap.GetRecapEvents)
	if not okRead or type(events) ~= "table" or RecapRows(events) == 0 then
		lastWhy = "the death recap is empty or unreadable"
		return false
	end
	lastRecap, lastDeathAt = events, Clock()
	if Ask(UnitIsDeadOrGhost, "player") == false then
		lastWhy = "the player is not dead"
		return false
	end
	local kb, why = KillingBlowRecap(events)
	if not kb then lastWhy = why or "no killing blow in the recap" return false end
	-- (From here the row says a player was involved, so a refusal is worth keeping: it is the
	-- only visible sign that a death happened and nothing came of it. It goes to the hidden
	-- notice buffer, not chat. Once per death, because the watch keeps asking while dead.)
	local playerLike = kb.flags ~= nil and HasBit(kb.flags, 0x40)
	local noticeKey = tostring(kb.stamp or ("d" .. tostring(serial or deathSerial)))
	local function Refuse(reason)
		lastWhy = reason
		if playerLike and DB().notices ~= false and noticeKey ~= lastNoticeKey then
			lastNoticeKey = noticeKey
			Notice("died to %s, but nothing was recorded: %s.", kb.name ~= "" and kb.name or "a player", reason)
		end
		return false
	end
	local now = Clock()
	if kb.stamp and (kb.stamp < now - DEATH_WINDOW or kb.stamp > now + 1) then
		return Refuse("that recap is from an earlier death")
	end
	local myGuid = Guid(Ask(UnitGUID, "player"))
	if not VictimIsMe(events, myGuid) then
		return Refuse("that recap is not yours")
	end
	if DB().ignoreInstances ~= false and InstanceState() == true then
		return Refuse("died in an instance (battlegrounds and arenas are ignored)")
	end
	local hostile, badWhy = KillerIsHostile(kb)
	if not hostile then return Refuse(badWhy or "the killer is not a hostile player") end
	-- (Identity is the GUID. The recap's own is used when it parses; otherwise the name it gives is
	-- looked up among the units this client can see. The board never invents one.)
	local guid = kb.guid or GuidForName(kb.name)
	if not guid then
		return Refuse(("the killer's GUID is unreadable (%s)")
			:format(kb.name ~= "" and kb.name or "no name given"))
	end
	local key = guid .. "@" .. (kb.stamp and tostring(kb.stamp) or ("d" .. tostring(serial or deathSerial)))
	if key == lastDeathKey then return true end
	lastDeathKey = key
	local name = kb.name
	if name == "" or not name:find(" ") then
		local known = NameFromGUID(guid)
		if known then name = known end
	end
	if name == "" then name = "Unknown" end
	-- Look for him while the client can still see him. This has to happen before the board row is
	-- built because the spot is part of the row we share with the guild.
	local spot = CaptureSpot(guid, name, true)
	-- Read level and layer now, before the client drops the killer's plate after the death.
	local level, layer = ns.KillerInfo(guid, name, true)
	local e = AddKill(guid, name, ClassFromGUID(guid) or "", "death", nil, spot, level, layer)
	-- The guild's death feed: who killed whom, so every member sees the same history and can click
	-- the killer's name to ask for a bounty (the click is where the money rule begins, not here).
	RecordDeath(guid, name, (e and e.class) or ClassFromGUID(guid) or "", MyName(), myGuid, spot, level, layer)
	-- The death screen often hides the killer's plate. Try again while he may still be on screen;
	-- only a real reading is kept - an unread layer stays unknown, never this player's layer.
	if e and type(C_Timer) == "table" and type(C_Timer.After) == "function" then
		for _, delay in ipairs({ 1, 4 }) do
			C_Timer.After(delay, function()
				if Entry(e.guid) == e then pcall(ns.FillKillerInfo, e) end
			end)
		end
	end
	lastWhy = e and ("counted: " .. e.name .. (ns.KillerLine(e) and (" (" .. ns.KillerLine(e) .. ")") or ""))
		or "the board refused the kill"
	if DB().notices ~= false then
		if e then
			local where = SpotLine(e)
			local info = ns.KillerLine(e)
			Notice("%s killed you - added to the kill on sight list (a bounty asks for %s, live as soon as you request it).%s Where you were killed: %s",
				e.name, Money(tonumber(e.want) or 0),
				info and (" Killer: " .. info .. ".") or "",
				where or "no readable map point - /kos where shows what the client exposed")
		elseif playerLike then
			Notice("died to %s, but nothing was recorded: %s.", name, tostring(lastWhy))
		end
	end
	return e ~= nil
end

local function OnPlayerDead()
	deathSerial = deathSerial + 1
	local serial = deathSerial
	if CaptureDeath(serial) then return end
	if type(C_Timer) == "table" and type(C_Timer.After) == "function" then
		for _, delay in ipairs({ 0.3, 1, 2, 4, 8 }) do
			C_Timer.After(delay, function()
				if serial == deathSerial then pcall(CaptureDeath, serial) end
			end)
		end
	end
end

-- PLAYER_DEAD is not raised by every build of this client, and the recap can land after it. This
-- asks the same question twice a second while the player is dead, with the same dedupe
-- (killer@stamp), so whichever path gets there first records the death and the other is a no-op.
local function WatchDeath()
	if Ask(UnitIsDeadOrGhost, "player") ~= true then return end
	pcall(CaptureDeath)
end

local function OnPartyKill(attackerGUID, targetGUID)
	if Secret(attackerGUID, targetGUID) then return end
	local victim = Guid(targetGUID)
	local attacker = Guid(attackerGUID)
	local mine = Guid(Ask(UnitGUID, "player"))
	if not victim or not attacker or not mine or attacker ~= mine then return end
	if DB().ignoreInstances ~= false and InstanceState() == true then return end
	if Entry(victim) then ClaimKill(victim, MyName()) end
end

-- ============================================================================ announcing

local function AnnounceText(e)
	if not e then return nil end
	local suffix = " " .. ns.KnownSpot(e, ".")
	local state = StateOf(e)
	local info = ns.KillerLine(e)
	-- Put the killer line before the location: chat truncates at 250 characters, and the location
	-- is the longest part. Losing the level/layer to the cut is what made them look unimplemented.
	local lead = info and (" Killer: " .. info .. ".") or ""
	if state == "unfunded" then
		return ("[KoS] %s%s is kill on sight - no bounty requested yet (%s).%s"):format(
			e.name, lead, Money(DEFAULT_REWARD), suffix)
	end
	return ("[KoS] %s%s is kill on sight - %s live bounty, %s joins the prize pool on the kill, the bank keeps %s.%s"):format(
		e.name, lead, Money(e.funded), Money(PayoutOf(e.funded)), Money(CutOf(e.funded)), suffix)
end

local function Announce(entry)
	if not entry then return false, "no entry" end
	local text = AnnounceText(entry)
	if not text then return false, "nothing to say" end
	if #text > 250 then text = text:sub(1, 250) end
	local ok = pcall(function() SendChatMessage(text, "GUILD") end)
	if not ok then
		local opened = pcall(function() ChatFrame_OpenChat(text) end)
		if opened then
			Say("this client refused the guild message (it needs a key press) - the line is in your chat box, press Enter.")
			return false, "opened"
		end
		Say("this client refused the guild message and the chat box could not be opened.")
		return false, "refused"
	end
	pendingAnnounce = { text = text, at = Mono() }
	return true
end

local function OnGuildChat(text, sender)
	if pendingAnnounce and SameName(sender, MyName()) then pendingAnnounce = nil end
end

-- ============================================================================ window

local ROWS = 10
local DEATH_ROWS = 5
-- 18 px rows leave a real footer in each list. At 20 px the last row touched
-- the constantly-changing spot and hint lines, which then wrapped over it.
local MEDIA = "Interface\\AddOns\\OlympusMytikas\\Media\\"

-- Forever's own window art, the same pieces the installed Happy Camper addon uses, so the board
-- reads as part of the game instead of as a box of ours: the Professions window picture fitted
-- over the frame's tiled stone, and Forever's bronze behind every inset.
local PAGE_ART = "Professions-QualityWindow-Background"
local INSET_ART = "heavybronze-frame-background"
local PAGE_FILL = { 0.082, 0.086, 0.059 }
local INSET_FILL = { 0.20, 0.13, 0.07, 0.95 }

local function HasAtlas(name)
	if type(C_Texture) ~= "table" or type(C_Texture.GetAtlasInfo) ~= "function" then return false end
	local ok, info = pcall(C_Texture.GetAtlasInfo, name)
	return ok and info ~= nil
end

-- One picture over the whole window. It is never sliced and never cropped (a texcoord on this
-- client tears art apart), so it can only scale, which is exactly what this needs.
local function PageArt(f)
	if not HasAtlas(PAGE_ART) then return end -- keep the template's own stone, not a flat colour
	local anchor = type(f.Bg) == "table" and f.Bg or f
	if not f.koPage then
		f.koPage = f:CreateTexture(nil, "BACKGROUND", nil, 1)
	end
	f.koPage:SetAllPoints(anchor)
	if pcall(f.koPage.SetAtlas, f.koPage, PAGE_ART) then
		if type(f.Bg) == "table" then
			if not f.koFill then
				f.koFill = f:CreateTexture(nil, "BACKGROUND", nil, 0)
				f.koFill:SetAllPoints(f.Bg)
				f.koFill:SetColorTexture(PAGE_FILL[1], PAGE_FILL[2], PAGE_FILL[3])
			end
			f.Bg:Hide() -- it tiles; a fitted picture under a tiled one shows nothing
		end
		if f.TopTileStreaks then pcall(function() f.TopTileStreaks:Hide() end) end
	end
end

-- The client's own dialog art, only for the case where the game's templates are missing.
local function DialogPanel(f)
	if type(BackdropTemplateMixin) == "table" or type(BackdropTemplate) == "function" then
		pcall(function() Mixin(f, BackdropTemplateMixin) end)
	end
	if f.SetBackdrop then
		local ok = pcall(f.SetBackdrop, f, {
			bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
			edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
			tile = true, tileSize = 32, edgeSize = 32,
			insets = { left = 11, right = 12, top = 12, bottom = 11 },
		})
		if ok then
			f:SetBackdropColor(0.10, 0.08, 0.07, 0.96)
			f:SetBackdropBorderColor(0.79, 0.55, 0.29)
		end
	end
end

-- The window is the game's portrait frame - what the Character and Professions windows use - with the
-- game's inset panels inside it, so the board belongs to Forever's UI instead of being a box of ours.
local function MakeWindow(name, width, height, strata)
	local ok, f = pcall(CreateFrame, "Frame", name, UIParent, "PortraitFrameTemplate")
	if not (ok and f and f.CloseButton) then
		if ok and f then pcall(function() f:Hide() end) end
		ok, f = pcall(CreateFrame, "Frame", name, UIParent, "BasicFrameTemplateWithInset")
	end
	if not (ok and f) then f = CreateFrame("Frame", name, UIParent) end
	f:SetSize(width, height)
	f:SetPoint("CENTER", 0, 30)
	f:SetFrameStrata(strata or "DIALOG")
	if f.SetToplevel then f:SetToplevel(true) end
	f:SetClampedToScreen(true)
	f:SetMovable(true)
	f:EnableMouse(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", function(self) self:StartMoving() end)
	f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
	f:Hide()
	if f.CloseButton then f.CloseButton:SetScript("OnClick", function() f:Hide() end) end
	PageArt(f)
	if type(UISpecialFrames) == "table" then UISpecialFrames[#UISpecialFrames + 1] = name end
	return f
end

local function Dress(f, title, portrait)
	if f.SetTitle then
		pcall(f.SetTitle, f, title)
	elseif f.TitleText then
		f.TitleText:SetText(title)
	end
	if portrait and f.SetPortraitToAsset then
		pcall(f.SetPortraitToAsset, f, portrait)
	elseif f.SetPortraitTexture then
		pcall(f.SetPortraitTexture, f, "player")
	end
	if not f.CloseButton then
		local ok, x = pcall(CreateFrame, "Button", nil, f, "UIPanelCloseButton")
		if ok and x then
			x:SetPoint("TOPRIGHT", f, "TOPRIGHT", -4, -4)
			x:SetScript("OnClick", function() f:Hide() end)
			f.closeBox = x
		end
	end
end

local function Inset(parent, left, top, right, bottom)
	local ok, box = pcall(CreateFrame, "Frame", nil, parent, "InsetFrameTemplate")
	if not (ok and box) then
		box = CreateFrame("Frame", nil, parent)
		DialogPanel(box)
	end
	box:SetPoint("TOPLEFT", left, top)
	box:SetPoint("BOTTOMRIGHT", right, bottom)
	-- Forever's bronze in the panel, over the template's own black (Happy Camper's panels).
	local fill = box:CreateTexture(nil, "BACKGROUND", nil, 2)
	if type(box.Bg) == "table" then fill:SetAllPoints(box.Bg) else fill:SetAllPoints(box) end
	if not (HasAtlas(INSET_ART) and pcall(fill.SetAtlas, fill, INSET_ART)) then
		fill:SetColorTexture(INSET_FILL[1], INSET_FILL[2], INSET_FILL[3], INSET_FILL[4])
	end
	box.fill = fill
	return box
end

-- First-run notice. It is shown once per account, on install/login, and cannot be closed with the
-- X or Escape: the only way past it is the acknowledgement button, which the reader has to tick.
-- The frame lives on ns, not in a new main-chunk local: Lua 5.1 allows only 200 of those here.
-- force is only used by /kos notice: replay the page for somebody who already
-- ticked it, without changing their acknowledgement.
local function ShowWelcome(force)
	if DB().welcomeAck and not force then return end
	local welcome = ns.welcome
	if not welcome then
		local name = "KillOnSightWelcome"
		welcome = MakeWindow(name, 560, 920, "DIALOG")
		ns.welcome = welcome
		Dress(welcome, "Kill on Sight - read this once", MEDIA .. "emblem")
		if welcome.CloseButton then welcome.CloseButton:Hide() end
		if type(UISpecialFrames) == "table" then
			for i = #UISpecialFrames, 1, -1 do
				if UISpecialFrames[i] == name then table.remove(UISpecialFrames, i) end
			end
		end

		local box = Inset(welcome, 22, -72, -22, 92)
		-- They were ticking without reading, so the warning gets its own measured band at
		-- the top. The three wrapped lines used to grow down over the rules below them.
		local warn = box:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
		warn:SetPoint("TOPLEFT", 18, -20)
		warn:SetWidth(480)
		warn:SetHeight(76)
		warn:SetJustifyH("CENTER")
		warn:SetJustifyV("TOP")
		warn:SetWordWrap(true)
		warn:SetTextColor(0.25, 1, 0.25)
		pcall(function() warn:SetFont("Fonts\\2002B.TTF", 20, "OUTLINE") end)
		warn:SetText("HEY DICK HEAD. DONT YOU DARE TICK THAT BOX WITHOUT READING THIS FIRST. DONT BE A MORON")
		welcome.warning = warn
		local body = box:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
		body:SetPoint("TOPLEFT", 18, -108)
		body:SetPoint("BOTTOMRIGHT", -18, 20)
		body:SetJustifyH("LEFT")
		body:SetJustifyV("TOP")
		body:SetWordWrap(true)
		body:SetText("KILL ON SIGHT - HOW IT WORKS\n\n" ..
			"1. BOARD (/kos): an enemy who kills a member is added, with level\n" ..
			"   and layer (layer S) on NEW kills only, for one hour. A name\n" ..
			"   is NOT a bounty. Rows stay still.\n" ..
			"   Only the guild master or Valar can delete.\n\n" ..
			"2. START: right-click his name (or /kos fund <name>). One 1g\n" ..
			"   bounty is LIVE at once - no bank deposit, no waiting.\n\n" ..
			"3. OWED: the requester owes the 1g to the guild bank. /kos owed,\n" ..
			"   the Ledger tab and Officers button show it. /kos paidup <name>\n" ..
			"   clears the debt; Officers posts the owed line to chat.\n\n" ..
			"4. KILL: the bank keeps 30% (30s). The hunter's 70% (70s) joins\n" ..
			"   one prize pool - it is not paid at the kill. swap to layer\n" ..
			"   whispers the victim for an invite.\n\n" ..
			"5. PRIZE: at month end the top hunter (most completed bounties)\n" ..
			"   wins the pool. An officer pays by hand; the addon never moves gold.\n\n" ..
			"6. REFUND: after 7 days unclaimed, 1g goes back to the requester.\n\n" ..
			"7. DELETES: a delete is final. Add the name again by hand to\n" ..
			"   bring it back. No sync can undo it.\n\n" ..
			"/kos opens the board. Prev/Next page. Pins last 30 minutes.")
		welcome.body = body

		local check = CreateFrame("CheckButton", nil, welcome, "UICheckButtonTemplate")
		check:SetSize(24, 24)
		check:SetPoint("BOTTOMLEFT", 28, 52)
		local label = welcome:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
		label:SetPoint("LEFT", check, "RIGHT", 6, 0)
		label:SetText("I have read and understand this")

		local ack = CreateFrame("Button", nil, welcome, "UIPanelButtonTemplate")
		ack:SetSize(220, 26)
		ack:SetPoint("BOTTOMRIGHT", -28, 48)
		ack:SetText("I have read this - continue")
		ack:Disable()
		check:SetScript("OnClick", function()
			if check:GetChecked() then ack:Enable() else ack:Disable() end
		end)
		ack:SetScript("OnClick", function()
			DB().welcomeAck = true
			if type(time) == "function" then DB().welcomeAckAt = time() end
			welcome:Hide()
		end)
		welcome.check, welcome.ack = check, ack
		check:SetChecked(false)
	end
	if force and welcome.check then
		-- A preview must look like the first run, even on an account that ticked it.
		welcome.check:SetChecked(false)
		welcome.ack:Disable()
	end
	welcome:Show()
end

local function Toggle(button, on)
	if not button then return end
	if on then
		button:Enable()
		button:SetAlpha(1)
	else
		button:Disable()
		button:SetAlpha(0.45)
	end
end

local refresh

-- Kept on ns rather than a new main-chunk local: this file is at Lua 5.1's 200-local ceiling.
-- Old rows saved before killAt existed carry killAt = 0. Zero is truthy in Lua, so the old
-- "killAt or at" fallback never ran and those rows sorted alphabetically instead of by kill time.
ns.KillTime = function(e)
	local t = tonumber(e and e.killAt) or 0
	if t <= 0 then t = tonumber(e and e.at) or 0 end
	return t
end

ns.EntryCompare = function(a, b)
	-- The board reads newest kill first, on every page: first page newest, last page oldest.
	-- Bounty state no longer outranks time, and a sync arriving late does not move a name up.
	local aa, bb = ns.KillTime(a), ns.KillTime(b)
	if aa ~= bb then return aa > bb end
	return (a.name or "") < (b.name or "")
end

local function SortedEntries()
	local list = {}
	for _, e in pairs(Store().entries) do list[#list + 1] = e end
	table.sort(list, ns.EntryCompare)
	return list
end

-- The board's row order is frozen while the window is open: a sync changing money or state must
-- not make names jump. A REAL new kill is different - it belongs at the top, newest first. Track
-- the kill time each row had when the order was frozen; if it changed, that row is re-inserted at
-- the front in kill-time order. Rows whose kill time did not change keep their exact old position.
ns.FreezeBoardOrder = function()
	ui.order, ui.orderFresh, ui.orderKill = {}, true, {}
	for i, e in ipairs(SortedEntries()) do
		ui.order[i] = e.guid
		ui.orderKill[e.guid] = ns.KillTime(e)
	end
end

local function BoardList()
	local entries = Store().entries
	if type(ui.order) ~= "table" then ns.FreezeBoardOrder() end
	if type(ui.orderKill) ~= "table" then ui.orderKill = {} end
	local fresh = {}
	for _, e in pairs(entries) do
		if ui.orderKill[e.guid] ~= ns.KillTime(e) then fresh[#fresh + 1] = e end
	end
	if #fresh > 0 then
		table.sort(fresh, ns.EntryCompare)
		local at = 1
		for i = 1, #fresh do
			local guid = fresh[i].guid
			for j = 1, #ui.order do
				if ui.order[j] == guid then table.remove(ui.order, j) break end
			end
			table.insert(ui.order, at, guid)
			at = at + 1
		end
		ui.offset = 0 -- the new kill must be on screen, not hidden on another page
	end
	local list, seen = {}, {}
	for i = 1, #ui.order do
		local e = entries[ui.order[i]]
		if e then
			list[#list + 1] = e
			seen[e.guid] = true
			ui.orderKill[e.guid] = ns.KillTime(e)
		end
	end
	local extras = {}
	for _, e in pairs(entries) do if not seen[e.guid] then extras[#extras + 1] = e end end
	if #extras > 0 then
		table.sort(extras, ns.EntryCompare)
		for i = 1, #extras do
			list[#list + 1] = extras[i]
			ui.order[#ui.order + 1] = extras[i].guid
			ui.orderKill[extras[i].guid] = ns.KillTime(extras[i])
		end
	end
	return list
end

local function ClassRGB(code)
	local hex = COLORS[code or ""] or "ffd100"
	return tonumber(hex:sub(1, 2), 16) / 255, tonumber(hex:sub(3, 4), 16) / 255, tonumber(hex:sub(5, 6), 16) / 255
end

-- The death feed under the board: killer (class colour) - victim ("you" in gold) - when - bounty
-- state. Every row is clickable; the click is what starts a bounty (SelectKiller).
local function RefreshDeaths()
	if not ui.deaths then return end
	local list = SortedDeaths(ui.mineOnly)
	local maxOff = math.max(0, #list - DEATH_ROWS)
	if ui.feedOffset > maxOff then ui.feedOffset = maxOff end
	for i = 1, DEATH_ROWS do
		local row = ui.deaths[i]
		local d = list[ui.feedOffset + i]
		if d then
			row.death = d
			row.killer:SetText(d.kname ~= "" and d.kname or "Unknown")
			row.killer:SetTextColor(ClassRGB(d.kclass))
			local mine = SameName(d.vname, MyName())
			row.victim:SetText(mine and "you" or (d.vname ~= "" and d.vname or "?"))
			if mine then
				row.victim:SetTextColor(1, 0.82, 0.20)
			else
				row.victim:SetTextColor(0.78, 0.72, 0.62)
			end
			row.when:SetText(Ago(d.at))
			local e = Entry(d.kguid)
			if not e then
				row.bounty:SetText("no bounty")
				row.bounty:SetTextColor(0.50, 0.46, 0.40)
			elseif (tonumber(e.funded) or 0) > 0 then
				row.bounty:SetText(Money(e.funded))
				row.bounty:SetTextColor(0.95, 0.80, 0.30)
			else
				row.bounty:SetText(StateText(e))
				row.bounty:SetTextColor(0.62, 0.50, 0.36)
			end
			row:Show()
		else
			row.death = nil
			row:Hide()
		end
	end
	if #list == 0 then
		ui.feedTitle:SetText("no guild deaths recorded yet - an enemy who kills a guild member appears here")
	else
		ui.feedTitle:SetText(("%s (%d)"):format(
			ui.mineOnly and "WHO KILLED YOU IN THE GUILD" or "WHO KILLED WHO IN THE GUILD", #list))
	end
	ui.mine:SetText(ui.mineOnly and "All" or "Mine")
end

refresh = function()
	if not ui.frame or not ui.frame:IsShown() then return end
	-- The window has two tabs. Only one set of widgets is drawn at a time; the chat commands still
	-- work in either tab, this just decides which view is on screen.
	if ui.tab == "leader" then
		if ui.refreshBoard then ui.refreshBoard() end
		return
	end
	if ui.tab == "ledger" then
		if ui.refreshLedger then ui.refreshLedger() end
		return
	end
	local list = BoardList()
	if not ui.selected or not ui.selected.guid or not Entry(ui.selected.guid) then ui.selected = list[1] end
	-- Only a fresh freeze may correct the page. A sync must leave the visible row and page alone.
	if ui.orderFresh then
		if ui.offset > math.max(0, #list - ROWS) then ui.offset = math.max(0, #list - ROWS) end
		ui.orderFresh = nil
	end
	local funded, want, live = 0, 0, 0
	for _, e in pairs(Store().entries) do
		if not e.paid and not e.refunded then
			funded = funded + (tonumber(e.funded) or 0)
			want = want + (tonumber(e.want) or 0)
			if StateOf(e) == "live" or StateOf(e) == "claimed" then live = live + 1 end
		end
	end
	ui.subtitle:SetText(("%d names  -  %s live  -  %d live"):format(#list, Money(funded), live))
	local s = Store()
	ui.ledger:SetText(("bank keeps %s   -   prize paid out %s   -   prize pool %s   -   refunded %s"):format(
		Money(s.bank.cut), Money(s.bank.paid), Money(s.bank.pool), Money(s.bank.refunded)))
	local debts, ious = Debts(), Ious()
	local parts = {}
	if #ious > 0 then
		-- Name the people, not just a total. This is the "who owes what" ledger in the window.
		local names = {}
		for i = 1, #ious do
			if #names < 4 then
				names[#names + 1] = ("%s %s"):format(ious[i].name or "?", Money(ious[i].amount))
			end
		end
		if #ious > #names then names[#names + 1] = ("+%d more"):format(#ious - #names) end
		parts[#parts + 1] = ("|cffffd100members owe: %s|r"):format(table.concat(names, ", "))
	end
	if #debts > 0 then
		local names = {}
		for i = 1, math.min(#debts, 3) do
			local d = debts[i]
			names[#names + 1] = ("%s to %s"):format(Money(d.amount), d.to or "?")
		end
		if #debts > #names then names[#names + 1] = ("+%d more"):format(#debts - #names) end
		parts[#parts + 1] = ("bank owes: %s"):format(table.concat(names, ", "))
	end
	if #parts > 0 then
		ui.owed:SetText(table.concat(parts, "   -   ") .. "   -   /kos owed")
	else
		ui.owed:SetText("|cff7f7f7fnobody owes anything: every bounty is either open or settled|r")
	end
	ui.owed:Show()
	Toggle(ui.officers, #debts > 0 or #ious > 0)
	for i = 1, ROWS do
		local row = ui.rows[i]
		local e = list[ui.offset + i]
		if e then
			row.entry = e
			row.name:SetText(e.name ~= "" and e.name or "Unknown")
			row.name:SetTextColor(ClassRGB(e.class))
			row.reward:SetText((tonumber(e.funded) or 0) > 0 and Money(e.funded) or "-")
			row.reward:SetTextColor((tonumber(e.funded) or 0) > 0 and 0.95 or 0.45,
				(tonumber(e.funded) or 0) > 0 and 0.80 or 0.38, 0.30)
			row.kills:SetText(tostring(tonumber(e.kills) or 0))
			local state = StateOf(e)
			local tag = ns.KillerTag(e)
			row.state:SetText(StateText(e) .. (tag and ("  " .. tag) or ""))
			if state == "live" then row.state:SetTextColor(0.95, 0.80, 0.30)
			elseif state == "claimed" then row.state:SetTextColor(0.88, 0.62, 0.24)
			elseif state == "refunddue" then row.state:SetTextColor(0.90, 0.45, 0.30)
			elseif state == "paid" or state == "refunded" then row.state:SetTextColor(0.50, 0.52, 0.48)
			else row.state:SetTextColor(0.62, 0.50, 0.36) end
			row:Show()
		else
			row.entry = nil
			row:Hide()
		end
	end
	local e = ui.selected
	local place, near = ns.SpotPlace(e)
	ui.spot:SetText(("LAST KNOWN LOCATION: %s"):format(
		place and ((near and "near " or "") .. place)
			or (e and "unavailable - no readable map point; /kos where shows what the client gave"
				or "select an enemy above")))
	if e then
		local state = StateOf(e)
		local cash = tonumber(e.funded) or 0
		local money
		if state == "refunddue" then
			money = ("%s is going back to %s - it is still in the bank"):format(Money(cash), e.refundedTo)
		elseif cash > 0 then
			money = ("%s live, asked for by %s (%s) - %s joins the prize pool, bank keeps %s"):format(
				Money(cash), e.fundedBy ~= "" and e.fundedBy or "?",
				e.paidUp and "paid up" or "OWES THE BANK",
				Money(PayoutOf(cash)), Money(CutOf(cash)))
		else
			money = ("no bounty requested - /kos fund puts up a live %s bounty"):format(
				Money(DEFAULT_REWARD))
		end
		local who
		if e.paid then who = ("70%% pooled for %s"):format(e.paidTo ~= "" and e.paidTo or "?")
		elseif e.refunded then who = ("handed back to %s"):format(
			e.refundedTo ~= "" and e.refundedTo or (e.fundedBy ~= "" and e.fundedBy or "the payer"))
		elseif e.refundDue then who = ("owed back to %s - nobody has taken it out yet"):format(
			e.refundedTo ~= "" and e.refundedTo or (e.fundedBy ~= "" and e.fundedBy or "the payer"))
		elseif e.claims and #e.claims > 0 then who = ("claimed by %s - %s joins the prize pool"):format(
			e.claims[1].name, Money(PayoutOf(cash)))
		else who = "nobody has claimed him" end
		local victims = ""
		if e.victims and #e.victims > 0 then
			victims = "killed " .. table.concat(e.victims, ", ")
			if #e.victims >= MAX_VICTIMS then victims = victims .. " ..." end
		end
		local due = RefundDue(e)
		local expiry = ""
		if due then
			local left = due - Clock()
			expiry = left > 0
				and ("  -  back to %s in %s"):format(e.fundedBy ~= "" and e.fundedBy or "the payer", Left(left))
				or "  -  refund is due"
		end
		local knownLine = ns.KnownSpot(e)
		local info = ns.KillerLine(e)
		-- Killer info goes first. The last-known location can wrap for two lines; when it came
		-- after everything else it pushed this line out of the 9-line detail panel.
		local lines = {}
		if info then lines[#lines + 1] = "killer: " .. info end
		lines[#lines + 1] = Clean(e.reason or "", MAX_REASON)
		if victims ~= "" then lines[#lines + 1] = victims end
		lines[#lines + 1] = money .. who .. expiry
		if e.spot then lines[#lines + 1] = knownLine end
		ui.detail:SetText(table.concat(lines, "\n"))
		Toggle(ui.swapLayer, ns.LayerFresh(e) ~= nil)
		local claimed = e.claims and #e.claims > 0
		local manage = Board.CanManage()
		Toggle(ui.fund, not e.paid and not e.refundDue and not claimed)
		Toggle(ui.paid, cash > 0 and not e.paid and not e.refundDue and claimed)
		ui.refund:SetText(e.refundDue and "Handed back" or "Refund")
		Toggle(ui.refund, manage and (e.refundDue or (cash > 0 and not e.paid and not e.refunded and not claimed)))
		Toggle(ui.announce, not e.paid and not e.refunded)
		Toggle(ui.delete, manage)
		Toggle(ui.paidup, manage and #ious > 0)
	else
		ui.detail:SetText("nobody on the board yet.\nthe next enemy who kills a guild member appears here.")
		ui.refund:SetText("Refund")
		for _, b in ipairs({ ui.fund, ui.paid, ui.refund, ui.announce, ui.delete, ui.paidup }) do Toggle(b, false) end
	end
	ui.offsetText:SetText(#list == 0 and "" or ("%d-%d of %d"):format(
		ui.offset + 1, math.min(#list, ui.offset + ROWS), #list))
	RefreshDeaths()
end

-- A settled bounty does not pay twice. Reopening it clears the old payout/refund so the same name
-- can be requested again; the bank ledger keeps the money that was already handled.
local function ReopenEntry(e)
	if not e or not (e.paid or e.refunded) then return false end
	e.paid, e.refunded, e.refundDue = false, nil, nil
	e.funded, e.fundedBy, e.fundedAt = 0, nil, nil
	e.paidUp = false
	e.paidTo, e.paidAt, e.refundedTo, e.refundedAt = nil, nil, nil, nil
	e.claims = {}
	e.want = math.max(tonumber(e.want) or 0, tonumber(DB().defaultReward) or 0)
	Bump(e)
	Broadcast(e, false)
	return true
end

local function FocusEntry(e)
	-- Selecting a name must never move the list. Only the Prev/Next buttons change ui.offset.
	ui.selected = e
	if not ui.frame then return end
	refresh()
end

-- The death row's killer is brought onto the board only by a click. A shared history row on its
-- own never puts anybody back: another member may have deliberately deleted him.
local function PrepareDeathKiller(d)
	local guid = Guid(d and d.kguid)
	if not guid then return nil, "no guid" end
	local e = Entry(guid)
	if not e then
		e = AddKill(guid, d.kname, d.kclass, "history",
			("killed %s"):format(d.vname ~= "" and d.vname or "a guild member"),
			d.spot, d.klevel, d.klayer)
		if not e then return nil, "the board refused him" end
		-- AddKill records the clicker as the victim; the death row knows who it really was.
		e.victims = {}
		if d.vname ~= "" then AddUnique(e.victims, d.vname, MAX_VICTIMS) end
		Bump(e)
		Broadcast(e, false)
	end
	local reopened = ReopenEntry(e)
	FocusEntry(e)
	return e, reopened
end

-- Left-click a killer: select him. Right-click: same selection plus a live 1g bounty.
function ns.SelectKiller(d, speak)
	local e, reopened = PrepareDeathKiller(d)
	if not e then return false, reopened end
	ns.FillKillerInfo(e)
	if speak ~= false and DB().notices ~= false then
		local line
		if reopened then
			line = "the old bounty is settled - this starts a new one"
		elseif (tonumber(e.funded) or 0) > 0 then
			line = ("already has a live %s bounty"):format(Money(e.funded))
		else
			line = ("no bounty yet - one asks for %s"):format(
				Money(math.max(0, (tonumber(e.want) or 0) - (tonumber(e.funded) or 0))))
		end
		local info = ns.KillerLine(e) or ns.KillerLine(d)
		Say("%s%s|r selected - %s%s. |cffffd100Right-click|r him to put up a live bounty; the gold is owed to the bank and a manager clears it with /kos paidup.",
			ClassColor(e), e.name, line, info and (" (" .. info .. ")") or "")
	end
	return true, e
end

-- Right-click a name on either list (or /kos bounty <name>): the bounty is live at once, shared with
-- the guild, and the requester owes 1g until a manager marks him paid up.
function ns.StartBounty(entry, speak)
	if not entry then return false, "no entry" end
	ns.FillKillerInfo(entry)
	local reopened = ReopenEntry(entry)
	FocusEntry(entry)
	local ok, why, need = StartJob(entry, speak)
	if ok and reopened and speak ~= false and DB().notices ~= false then
		Say("the old bounty is settled - this is a new live bounty.")
	end
	return ok, why, need
end

function ns.StartBountyFromDeath(d, speak)
	local e, why = PrepareDeathKiller(d)
	if not e then return false, why end
	return ns.StartBounty(e, speak)
end

local function BuildWindow()
	if ui.frame then return ui.frame end
	local f = MakeWindow("KillOnSightFrame", 540, 760, "DIALOG")
	Dress(f, "Kill on Sight", MEDIA .. "emblem")
	ui.frame = f
	f:SetScript("OnShow", function() ui.order, ui.offset = nil, 0 refresh() end)
	-- The wheel belongs to the board list only. On the whole window a stray wheel move over the
	-- ledger, buttons or detail panel scrolled the board by itself.

	-- The rule of the whole addon, in the window where everybody can read it, every time it opens.
	ui.blurb = f:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	ui.blurb:SetPoint("TOPLEFT", 66, -30)
	ui.blurb:SetWidth(452)
	ui.blurb:SetHeight(30)
	ui.blurb:SetJustifyH("LEFT")
	ui.blurb:SetJustifyV("TOP")
	ui.blurb:SetWordWrap(true)
	ui.blurb:SetText("An enemy who kills a guild member is added here.\n" ..
		"|cffffd100Right-click puts up a live 1g bounty; the requester owes it until /kos paidup.|r")

	ui.subtitle = f:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	-- Sits to the right of the tab strip, so neither has to move the board panels down.
	ui.subtitle:SetPoint("TOPLEFT", 288, -64)
	ui.subtitle:SetWidth(232)
	ui.subtitle:SetJustifyH("LEFT")
	ui.subtitle:SetWordWrap(false)
	ui.subtitle:SetTextColor(0.79, 0.58, 0.34)

	-- Three tabs along the top of the window. The board is the default; "Hunter Board" swaps in the
	-- monthly leaderboard, "Ledger" swaps in the who-owes-what list. SetTab is filled in once every
	-- widget exists.
	local SetTab
	ui.tab = "board"
	local tabBoard = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	tabBoard:SetSize(72, 20)
	tabBoard:SetPoint("TOPLEFT", 18, -60)
	tabBoard:SetText("Board")
	tabBoard:SetScript("OnClick", function() SetTab("board") end)
	local tabHunters = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	tabHunters:SetSize(106, 20)
	tabHunters:SetPoint("TOPLEFT", 94, -60)
	tabHunters:SetText("Hunter Board")
	tabHunters:SetScript("OnClick", function() SetTab("leader") end)
	local tabLedger = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	tabLedger:SetSize(76, 20)
	tabLedger:SetPoint("TOPLEFT", 204, -60)
	tabLedger:SetText("Ledger")
	tabLedger:SetScript("OnClick", function() SetTab("ledger") end)
	ui.tabBoard, ui.tabHunters, ui.tabLedger = tabBoard, tabHunters, tabLedger

	local listBox = Inset(f, 18, -80, -18, 428)
	ui.listBox = listBox
	-- No mouse-wheel handler at all: a stray wheel move anywhere in the window used to scroll the
	-- board. Use the Prev/Next buttons at the foot of the list instead.
	for _, h in ipairs({ { 0, "ENEMY" }, { 176, "BOUNTY" }, { 252, "KILLS" }, { 306, "STATE" } }) do
		local fs = listBox:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
		fs:SetPoint("TOPLEFT", 12 + h[1], -8)
		fs:SetText(h[2])
		fs:SetTextColor(0.79, 0.55, 0.29)
	end
	-- The enemy list is the first thing people look at. Its last-known-location
	-- line gets its own two-line strip below a separator, clear of the rows that
	-- change as the board scrolls and clear of the pager controls below that.
	ui.spotRule = listBox:CreateTexture(nil, "OVERLAY")
	ui.spotRule:SetPoint("TOPLEFT", 10, -206)
	ui.spotRule:SetSize(468, 1)
	ui.spotRule:SetColorTexture(0.45, 0.30, 0.16, 0.65)
	ui.spot = listBox:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	ui.spot:SetPoint("BOTTOMLEFT", 12, 22)
	ui.spot:SetWidth(448)
	ui.spot:SetHeight(22)
	ui.spot:SetJustifyH("LEFT")
	ui.spot:SetJustifyV("TOP")
	ui.spot:SetWordWrap(true)
	ui.spot:SetMaxLines(2)
	ui.spot:SetTextColor(1, 0.82, 0.25)
	ui.spot:SetText("LAST KNOWN LOCATION: select an enemy above")

	ui.rows, ui.offset, ui.selected = {}, 0, nil
	for i = 1, ROWS do
		local row = CreateFrame("Button", nil, listBox)
		-- A client only sends left-clicks to OnClick by default. Without this the right-click job
		-- handler below is never called in game (the mock used to fake it and hid the bug).
		row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
		row:SetSize(468, rowHeight)
		row:SetPoint("TOPLEFT", 10, -24 - (i - 1) * rowHeight)
		local hl = row:CreateTexture(nil, "HIGHLIGHT")
		hl:SetAllPoints(row)
		hl:SetColorTexture(1, 0.82, 0, 0.12)
		row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
		row.name:SetPoint("LEFT", 2, 0)
		row.name:SetWidth(150)
		row.name:SetJustifyH("LEFT")
		row.reward = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
		row.reward:SetPoint("LEFT", 158, 0)
		row.reward:SetWidth(60)
		row.reward:SetJustifyH("LEFT")
		row.kills = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
		row.kills:SetPoint("LEFT", 224, 0)
		row.kills:SetWidth(40)
		row.kills:SetJustifyH("LEFT")
		row.state = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
		row.state:SetPoint("LEFT", 270, 0)
		row.state:SetWidth(196)
		row.state:SetJustifyH("LEFT")
		row:SetScript("OnClick", function(self, button)
			if not self.entry then return end
			if button == "RightButton" then
				ns.StartBounty(self.entry, true)
			else
				ui.selected = self.entry
				refresh()
			end
		end)
		ui.rows[i] = row
	end

	local pager = CreateFrame("Button", nil, listBox, "UIPanelButtonTemplate")
	pager:SetSize(22, 16)
	pager:SetPoint("BOTTOMLEFT", 6, 4)
	pager:SetText("<")
	pager:SetScript("OnClick", function() ui.offset = math.max(0, ui.offset - ROWS) refresh() end)
	local pager2 = CreateFrame("Button", nil, listBox, "UIPanelButtonTemplate")
	pager2:SetSize(22, 16)
	pager2:SetPoint("BOTTOMRIGHT", -6, 4)
	pager2:SetText(">")
	pager2:SetScript("OnClick", function() ui.offset = ui.offset + ROWS refresh() end)
	ui.pagePrev, ui.pageNext = pager, pager2
	ui.offsetText = listBox:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	ui.offsetText:SetPoint("BOTTOM", 0, 5)
	ui.offsetText:SetTextColor(0.55, 0.47, 0.36)

	-- The guild death feed: who killed whom, when, and what the board says about the killer. Every
	-- name in it is a way into the bounty flow: left-click selects, right-click starts the job.
	-- 148 tall: five 18 px rows, a separator, then a measured two-line hint strip. The old
	-- 20 px rows let the wrapped hint sit on top of the last row.
	local deathBox = Inset(f, 18, -340, -18, 272)
	ui.deathBox = deathBox
	ui.feedTitle = deathBox:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	ui.feedTitle:SetPoint("TOPLEFT", 12, -7)
	ui.feedTitle:SetWidth(300)
	ui.feedTitle:SetJustifyH("LEFT")
	ui.feedTitle:SetWordWrap(false)
	ui.feedTitle:SetTextColor(0.79, 0.55, 0.29)
	ui.mine = CreateFrame("Button", nil, deathBox, "UIPanelButtonTemplate")
	ui.mine:SetSize(50, 16)
	ui.mine:SetPoint("TOPRIGHT", -6, -4)
	ui.mine:SetText("Mine")
	ui.mine:SetScript("OnClick", function()
		ui.mineOnly = not ui.mineOnly
		ui.feedOffset = 0
		refresh()
	end)
	local feedPrev = CreateFrame("Button", nil, deathBox, "UIPanelButtonTemplate")
	feedPrev:SetSize(16, 16)
	feedPrev:SetPoint("TOPRIGHT", -82, -4)
	feedPrev:SetText("<")
	feedPrev:SetScript("OnClick", function()
		ui.feedOffset = math.max(0, ui.feedOffset - DEATH_ROWS)
		refresh()
	end)
	local feedNext = CreateFrame("Button", nil, deathBox, "UIPanelButtonTemplate")
	feedNext:SetSize(16, 16)
	feedNext:SetPoint("TOPRIGHT", -62, -4)
	feedNext:SetText(">")
	feedNext:SetScript("OnClick", function()
		ui.feedOffset = ui.feedOffset + DEATH_ROWS
		refresh()
	end)

	ui.deaths, ui.feedOffset, ui.mineOnly = {}, 0, false
	for i = 1, DEATH_ROWS do
		local row = CreateFrame("Button", nil, deathBox)
		-- Same as the board rows: register the right button or the client never fires OnClick for it.
		row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
		row:SetSize(468, rowHeight)
		row:SetPoint("TOPLEFT", 10, -20 - (i - 1) * rowHeight)
		local hl = row:CreateTexture(nil, "HIGHLIGHT")
		hl:SetAllPoints(row)
		hl:SetColorTexture(1, 0.82, 0, 0.12)
		row.killer = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
		row.killer:SetPoint("LEFT", 2, 0)
		row.killer:SetWidth(146)
		row.killer:SetJustifyH("LEFT")
		row.victim = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
		row.victim:SetPoint("LEFT", 150, 0)
		row.victim:SetWidth(126)
		row.victim:SetJustifyH("LEFT")
		row.when = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
		row.when:SetPoint("LEFT", 280, 0)
		row.when:SetWidth(72)
		row.when:SetJustifyH("LEFT")
		row.bounty = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
		row.bounty:SetPoint("LEFT", 356, 0)
		row.bounty:SetWidth(108)
		row.bounty:SetJustifyH("LEFT")
		row:SetScript("OnClick", function(self, button)
			if not self.death then return end
			if button == "RightButton" then
				ns.StartBountyFromDeath(self.death, true)
			else
				ns.SelectKiller(self.death, true)
			end
		end)
		-- The feed has no spare column for a location, but the shared death row now carries one:
		-- hover a name to see where that guild member died, on every client.
		row:SetScript("OnEnter", function(self)
			local d = self.death
			if not d or not GameTooltip then return end
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:AddLine(Clean(d.kname, MAX_NAME) .. " killed " ..
				(Clean(d.vname, MAX_NAME) ~= "" and Clean(d.vname, MAX_NAME) or "?"), 1, 0.82, 0)
			local info = ns.KillerLine(d)
			if info then GameTooltip:AddLine("killer: " .. info, 1, 0.82, 0.4) end
			GameTooltip:AddLine(SpotLine(d) or "last known location unavailable", 1, 1, 1, true)
			GameTooltip:Show()
		end)
		row:SetScript("OnLeave", function()
			if GameTooltip then GameTooltip:Hide() end
		end)
		ui.deaths[i] = row
	end
	ui.feedRule = deathBox:CreateTexture(nil, "OVERLAY")
	ui.feedRule:SetPoint("TOPLEFT", 10, -114)
	ui.feedRule:SetSize(468, 1)
	ui.feedRule:SetColorTexture(0.45, 0.30, 0.16, 0.65)
	ui.feedHint = deathBox:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	ui.feedHint:SetPoint("BOTTOMLEFT", 10, 4)
	ui.feedHint:SetWidth(448)
	ui.feedHint:SetHeight(26)
	ui.feedHint:SetJustifyH("LEFT")
	ui.feedHint:SetJustifyV("TOP")
	ui.feedHint:SetWordWrap(true)
	ui.feedHint:SetMaxLines(2)
	ui.feedHint:SetTextColor(0.55, 0.47, 0.36)
	ui.feedHint:SetText("left-click selects  -  right-click puts up a live 1g bounty (the requester owes it until /kos paidup)")

	ui.ledger = f:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	ui.ledger:SetPoint("BOTTOM", 0, 108)
	ui.ledger:SetTextColor(0.55, 0.47, 0.36)

	-- Moved down with the death feed: still 136 tall, and 8 px clear of the ledger.
	local detailBox = Inset(f, 18, -496, -18, 128)
	ui.detailBox = detailBox
	ui.detail = detailBox:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	ui.detail:SetPoint("TOPLEFT", 12, -10)
	ui.detail:SetWidth(336)
	ui.detail:SetHeight(124)
	ui.detail:SetJustifyH("LEFT")
	ui.detail:SetJustifyV("TOP")
	ui.detail:SetWordWrap(true)
	ui.detail:SetMaxLines(9)
	ui.detail:SetTextColor(0.94, 0.90, 0.84)

	-- Sits on the killer line, right after the level and layer. Enabled only while that layer is
	-- still fresh, so an old kill never offers a swap the addon itself refuses to make.
	ui.swapLayer = CreateFrame("Button", nil, detailBox, "UIPanelButtonTemplate")
	ui.swapLayer:SetSize(108, 22)
	ui.swapLayer:SetPoint("TOPRIGHT", -10, -7)
	ui.swapLayer:SetText("swap to layer")
	ui.swapLayer:SetScript("OnClick", function()
		local e = ui.selected
		if e then ns.SwapToLayer(e) end
	end)

	ui.owed = f:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	ui.owed:SetPoint("BOTTOM", 0, 80)
	ui.owed:SetJustifyH("CENTER")

	local function button(text, x, w, y, fn)
		local b = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
		b:SetSize(w, 22)
		b:SetPoint("BOTTOMLEFT", x, y)
		b:SetText(text)
		b:SetScript("OnClick", fn)
		return b
	end
	ui.add = button("Add", 18, 74, 46, function() ns.ShowAdd() end)
	ui.fund = button("Fund", 98, 74, 46, function()
		local e = ui.selected
		if not e then return end
		local ok, _, why = StartJob(e, true)
		if not ok then Say("%s", tostring(why)) end
	end)
	ui.paid = button("Pool", 178, 74, 46, function()
		Say("each hunter's 70%% goes into this month's single prize pool. " ..
			"The board leader gets the whole pool at month end - /kos boardpaid records it.")
	end)
	ui.refund = button("Refund", 258, 74, 46, function()
		local e = ui.selected
		if not e then return end
		local ok, why = HandOver(e.guid, MyName())
		if ok then return end
		-- HandOver only covers money that is already owed; this marks an open bounty as going back
		ok, why = Refund(e.guid)
		if not ok then Say("%s", tostring(why)) end
	end)
	ui.announce = button("Announce", 338, 96, 46, function()
		local e = ui.selected
		if e then
			ns.FillKillerInfo(e) -- read a visible level/layer now, just like /kos announce does
			Announce(e)
		end
	end)
	ui.officers = button("Officers", 440, 82, 46, function() PostOwed() end)
	ui.paidup = button("Mark paid", 294, 78, 18, function()
		local e = ui.selected
		local who = e and e.fundedBy or ""
		if who == "" then
			Say("select a bounty with a requester first - Mark paid means the requester already handed the bank the 1g; GM/Valar only.")
			return
		end
		local ok, why = PaidUp(who, MyName())
		if not ok then Say("%s", tostring(why)) end
	end)
	ui.paidup:SetScript("OnEnter", function(self)
		if not GameTooltip then return end
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:AddLine("Mark paid up", 1, 0.82, 0.4)
		GameTooltip:AddLine("Use only after the requester has handed the 1g to the guild bank.", 1, 1, 1, true)
		GameTooltip:AddLine("This clears their debt in the Ledger. The addon does not read or move gold.", 0.94, 0.90, 0.84, true)
		GameTooltip:AddLine("GM or Valar only. /kos paidup <name> does the same.", 0.79, 0.58, 0.33, true)
		GameTooltip:Show()
	end)
	ui.paidup:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
	ui.sync = button("Sync", 378, 64, 18, function()
		SendDigest(true)
		QueueParts("Q", true)
		Say("asked the guild for its board and sent ours.")
	end)
	ui.delete = button("Delete", 448, 74, 18, function()
		local e = ui.selected
		if not e then return end
		local ok, why = Remove(e.guid)
		if not ok then Say("%s", tostring(why)) return end
		ui.selected = nil
		Say("%s removed from the board.", e.name)
		refresh()
	end)

	-- The Hunter Board tab. A plain frame with the same bronze fill as the insets (deliberately NOT
	-- an InsetFrameTemplate, so the board tab keeps its three real inset panels) fills the space
	-- from the tab strip down to the buttons.
	local leaderBox = CreateFrame("Frame", nil, f)
	leaderBox:SetPoint("TOPLEFT", 18, -80)
	leaderBox:SetPoint("BOTTOMRIGHT", -18, 40)
	local lf = leaderBox:CreateTexture(nil, "BACKGROUND", nil, 2)
	lf:SetAllPoints(leaderBox)
	if not (HasAtlas(INSET_ART) and pcall(lf.SetAtlas, lf, INSET_ART)) then
		lf:SetColorTexture(INSET_FILL[1], INSET_FILL[2], INSET_FILL[3], INSET_FILL[4])
	end
	ui.leaderBox = leaderBox

	ui.leaderTitle = leaderBox:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	ui.leaderTitle:SetPoint("TOPLEFT", 12, -10)
	ui.leaderTitle:SetWidth(470)
	ui.leaderTitle:SetJustifyH("LEFT")
	ui.leaderTitle:SetTextColor(1, 0.82, 0.25)

	ui.leaderSub = leaderBox:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	ui.leaderSub:SetPoint("TOPLEFT", 12, -32)
	ui.leaderSub:SetWidth(470)
	ui.leaderSub:SetJustifyH("LEFT")
	ui.leaderSub:SetTextColor(0.79, 0.55, 0.29)
	ui.leaderSub:SetText("who killed the most bounties this month - the winner takes the pool")

	for _, h in ipairs({ { 0, "RANK" }, { 54, "HUNTER" }, { 280, "KILLS" }, { 340, "GOLD IN POOL" } }) do
		local fs = leaderBox:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
		fs:SetPoint("TOPLEFT", 12 + h[1], -54)
		fs:SetText(h[2])
		fs:SetTextColor(0.79, 0.55, 0.29)
	end

	local LEADER_ROWS = 10
	ui.leaderRows = {}
	for i = 1, LEADER_ROWS do
		local row = CreateFrame("Frame", nil, leaderBox)
		row:SetSize(468, 20)
		row:SetPoint("TOPLEFT", 10, -72 - (i - 1) * 22)
		row.rank = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		row.rank:SetPoint("LEFT", 2, 0)
		row.rank:SetWidth(46)
		row.rank:SetJustifyH("LEFT")
		row.who = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
		row.who:SetPoint("LEFT", 54, 0)
		row.who:SetWidth(210)
		row.who:SetJustifyH("LEFT")
		row.count = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
		row.count:SetPoint("LEFT", 278, 0)
		row.count:SetWidth(50)
		row.count:SetJustifyH("LEFT")
		row.credit = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
		row.credit:SetPoint("LEFT", 338, 0)
		row.credit:SetWidth(120)
		row.credit:SetJustifyH("LEFT")
		row.credit:SetTextColor(1, 0.82, 0.25)
		ui.leaderRows[i] = row
	end

	ui.leaderWinner = leaderBox:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	ui.leaderWinner:SetPoint("BOTTOMLEFT", 12, 62)
	ui.leaderWinner:SetWidth(470)
	ui.leaderWinner:SetWordWrap(true)
	ui.leaderWinner:SetTextColor(0.94, 0.90, 0.84)
	ui.leaderPast = leaderBox:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	ui.leaderPast:SetPoint("BOTTOMLEFT", 12, 40)
	ui.leaderPast:SetWidth(470)
	ui.leaderPast:SetTextColor(0.55, 0.47, 0.36)

	local leaderPaid = CreateFrame("Button", nil, leaderBox, "UIPanelButtonTemplate")
	leaderPaid:SetSize(120, 22)
	leaderPaid:SetPoint("BOTTOMLEFT", 12, 10)
	leaderPaid:SetText("Record paid")
	leaderPaid:SetScript("OnClick", function()
		local ok, why = Board.BoardPaid(nil, MyName())
		if not ok then Say("%s", tostring(why)) end
	end)
	local leaderSync = CreateFrame("Button", nil, leaderBox, "UIPanelButtonTemplate")
	leaderSync:SetSize(90, 22)
	leaderSync:SetPoint("BOTTOMLEFT", 140, 10)
	leaderSync:SetText("Sync")
	leaderSync:SetScript("OnClick", function()
		SendDigest(true)
		QueueParts("Q", true)
		Say("asked the guild for its board and sent ours.")
	end)
	ui.leaderPaid, ui.leaderSync = leaderPaid, leaderSync

	ui.refreshBoard = function()
		local now = Clock()
		local b = Store().board
		if b.month ~= Board.BoardMonth(now) then Board.BoardRollover(now) end
		b = Store().board
		leaderPaid:SetShown(Board.CanManage())
		ui.leaderTitle:SetText(("|cffffd100Monthly hunter board - %s|r"):format(b.month))
		local ranks = Board.BoardRanks(b.month)
		for i = 1, LEADER_ROWS do
			local row = ui.leaderRows[i]
			local r = ranks[i]
			if r then
				row.rank:SetText(tostring(i))
				row.who:SetText(r.who)
				row.count:SetText(("%d %s"):format(r.count, r.count == 1 and "kill" or "kills"))
				row.credit:SetText(Money(r.amount))
				row.rank:SetTextColor(i == 1 and 1 or 0.78, i == 1 and 0.82 or 0.72,
					i == 1 and 0.20 or 0.62)
			else
				row.rank:SetText("")
				row.who:SetText(i == 1 and "no bounties killed this month yet" or "")
				row.count:SetText("")
				row.credit:SetText("")
			end
		end
		if #ranks > 0 then
			ui.leaderWinner:SetText(("top hunter: %s with %d kill%s - wins the whole %s prize pool"):format(
				ranks[1].who, ranks[1].count, ranks[1].count == 1 and "" or "s",
				Money(Board.FundForMonth(b.month))))
		else
			ui.leaderWinner:SetText("the hunter with the most kills wins the pool")
		end
		local h = b.history[#b.history]
		ui.leaderPast:SetText(h and ("last month (%s): %s with %d %s - %s pool%s"):format(
			h.month, h.who, h.count, h.count == 1 and "kill" or "kills",
			Money(tonumber(h.prize) or 0),
			h.paid and (" handed to " .. (h.by ~= "" and h.by or "an officer")) or "")
			or "")
	end

	-- The Ledger tab: a real list of who owes what, including debts already cleared. Plain frame
	-- with the same bronze fill as the insets, so the board tab still has exactly three insets.
	local ledgerBox = CreateFrame("Frame", nil, f)
	ledgerBox:SetPoint("TOPLEFT", 18, -80)
	ledgerBox:SetPoint("BOTTOMRIGHT", -18, 40)
	local df = ledgerBox:CreateTexture(nil, "BACKGROUND", nil, 2)
	df:SetAllPoints(ledgerBox)
	if not (HasAtlas(INSET_ART) and pcall(df.SetAtlas, df, INSET_ART)) then
		df:SetColorTexture(INSET_FILL[1], INSET_FILL[2], INSET_FILL[3], INSET_FILL[4])
	end
	ui.ledgerBox = ledgerBox

	ui.ledgerTitle = ledgerBox:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	ui.ledgerTitle:SetPoint("TOPLEFT", 12, -10)
	ui.ledgerTitle:SetWidth(470)
	ui.ledgerTitle:SetJustifyH("LEFT")
	ui.ledgerTitle:SetTextColor(1, 0.82, 0.25)
	ui.ledgerTitle:SetText("Debts ledger")

	ui.ledgerSub = ledgerBox:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	ui.ledgerSub:SetPoint("TOPLEFT", 12, -32)
	ui.ledgerSub:SetWidth(470)
	ui.ledgerSub:SetJustifyH("LEFT")
	ui.ledgerSub:SetTextColor(0.79, 0.55, 0.29)
	ui.ledgerSub:SetText("Paid up = the requester handed the bank the 1g; GM/Valar mark it here")

	for _, h in ipairs({ { 2, "WHO" }, { 134, "GOLD" }, { 198, "FOR" }, { 310, "WHEN" }, { 378, "STATUS" } }) do
		local fs = ledgerBox:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
		fs:SetPoint("TOPLEFT", 12 + h[1], -54)
		fs:SetText(h[2])
		fs:SetTextColor(0.79, 0.55, 0.29)
	end

	ui.ledgerRows, ui.ledgerOffset = {}, 0
	for i = 1, 14 do
		local row = CreateFrame("Frame", nil, ledgerBox)
		row:SetSize(468, 20)
		row:SetPoint("TOPLEFT", 10, -72 - (i - 1) * 20)
		row.who = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
		row.who:SetPoint("LEFT", 2, 0) row.who:SetWidth(128) row.who:SetJustifyH("LEFT")
		row.gold = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
		row.gold:SetPoint("LEFT", 134, 0) row.gold:SetWidth(60) row.gold:SetJustifyH("LEFT")
		row.target = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		row.target:SetPoint("LEFT", 198, 0) row.target:SetWidth(108) row.target:SetJustifyH("LEFT")
		row.when = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		row.when:SetPoint("LEFT", 310, 0) row.when:SetWidth(62) row.when:SetJustifyH("LEFT")
		row.status = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		row.status:SetPoint("LEFT", 378, 0) row.status:SetWidth(90) row.status:SetJustifyH("LEFT")
		ui.ledgerRows[i] = row
	end

	ui.ledgerTotal = ledgerBox:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	ui.ledgerTotal:SetPoint("BOTTOMLEFT", 12, 12)
	ui.ledgerTotal:SetWidth(320)
	ui.ledgerTotal:SetJustifyH("LEFT")
	ui.ledgerTotal:SetTextColor(0.94, 0.90, 0.84)

	local ledgerPrev = CreateFrame("Button", nil, ledgerBox, "UIPanelButtonTemplate")
	ledgerPrev:SetSize(56, 22)
	ledgerPrev:SetPoint("BOTTOMRIGHT", -76, 8)
	ledgerPrev:SetText("Prev")
	ledgerPrev:SetScript("OnClick", function()
		ui.ledgerOffset = math.max(0, ui.ledgerOffset - #ui.ledgerRows)
		ui.refreshLedger()
	end)
	local ledgerNext = CreateFrame("Button", nil, ledgerBox, "UIPanelButtonTemplate")
	ledgerNext:SetSize(56, 22)
	ledgerNext:SetPoint("BOTTOMRIGHT", -12, 8)
	ledgerNext:SetText("Next")
	ledgerNext:SetScript("OnClick", function()
		ui.ledgerOffset = ui.ledgerOffset + #ui.ledgerRows
		ui.refreshLedger()
	end)
	ui.ledgerPagePrev, ui.ledgerPageNext = ledgerPrev, ledgerNext

	ui.refreshLedger = function()
		local rows = LedgerRows()
		if ui.ledgerFresh then
			if ui.ledgerOffset > math.max(0, #rows - #ui.ledgerRows) then
				ui.ledgerOffset = math.max(0, #rows - #ui.ledgerRows)
			end
			ui.ledgerFresh = nil
		end
		local open, closed = 0, 0
		for i = 1, #rows do
			if rows[i].status == "owes bank" or rows[i].status == "refund due" then
				open = open + rows[i].amount
			else
				closed = closed + rows[i].amount
			end
		end
		ui.ledgerTotal:SetText(("outstanding %s   -   settled %s"):format(Money(open), Money(closed)))
		for i, row in ipairs(ui.ledgerRows) do
			local r = rows[ui.ledgerOffset + i]
			if r then
				row.who:SetText(r.who)
				row.gold:SetText(Money(r.amount))
				row.target:SetText(r.target)
				row.when:SetText(Ago(r.when))
				row.status:SetText(r.status .. (r.by ~= "" and (" (" .. r.by .. ")") or ""))
				if r.status == "owes bank" or r.status == "refund due" then
					row.status:SetTextColor(1, 0.82, 0.25)
				else
					row.status:SetTextColor(0.55, 0.72, 0.52)
				end
			else
				row.who:SetText("") row.gold:SetText("") row.target:SetText("")
				row.when:SetText("") row.status:SetText("")
			end
		end
	end
	ledgerBox:SetShown(false)

	ui.boardWidgets = {
		ui.blurb, ui.subtitle, ui.listBox, ui.deathBox, ui.detailBox,
		ui.ledger, ui.owed, ui.add, ui.fund, ui.paid, ui.refund,
		ui.announce, ui.officers, ui.sync, ui.delete,
	}
	SetTab = function(which)
		if ui.tab ~= which then
			if which == "board" then ui.order, ui.offset = nil, 0 end
			if which == "ledger" then ui.ledgerOrder, ui.ledgerOffset = nil, 0 end
		end
		ui.tab = which
		local boardMode = which == "board"
		for _, w in ipairs(ui.boardWidgets) do w:SetShown(boardMode) end
		leaderBox:SetShown(which == "leader")
		ledgerBox:SetShown(which == "ledger")
		tabBoard:SetAlpha(boardMode and 1 or 0.55)
		tabHunters:SetAlpha(which == "leader" and 1 or 0.55)
		tabLedger:SetAlpha(which == "ledger" and 1 or 0.55)
		refresh()
	end
	SetTab("board")
	return f
end

function ns.ShowAdd()
	local f = ui.addBox
	if not f then
		f = MakeWindow("KillOnSightAdd", 420, 320, "DIALOG")
		Dress(f, "Kill on Sight - add a player", MEDIA .. "emblem")
		local blurb = f:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
		blurb:SetPoint("TOPLEFT", 66, -30)
		blurb:SetWidth(334)
		blurb:SetJustifyH("LEFT")
		blurb:SetWordWrap(true)
		blurb:SetText("This only puts a name on the board. |cffffd100/kos fund or a right-click makes the bounty live at once; the requester owes the bank until /kos paidup.|r")

		local box = Inset(f, 18, -66, -18, 52)

		local function label(text, y)
			local l = box:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
			l:SetPoint("TOPLEFT", 12, y)
			l:SetText(text)
			l:SetTextColor(0.79, 0.58, 0.34)
		end
		local function edit(y, width)
			local ok, b = pcall(CreateFrame, "EditBox", nil, box, "InputBoxTemplate")
			if not (ok and b) then
				b = CreateFrame("EditBox", nil, box)
				if b.SetBackdrop then pcall(b.SetBackdrop, b, {
					bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
					edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
					tile = true, tileSize = 16, edgeSize = 12,
					insets = { left = 3, right = 3, top = 3, bottom = 3 },
				}) end
				b:SetTextInsets(6, 6, 2, 2)
			end
			b:SetSize(width or 352, 20)
			b:SetPoint("TOPLEFT", 10, y)
			b:SetAutoFocus(false)
			b:SetFontObject("ChatFontNormal")
			return b
		end
		label("name", -10)
		f.nameBox = edit(-26)
		label("gold the bounty should ask for", -56)
		f.rewardBox = edit(-72, 90)
		label("why he is on the list", -100)
		f.reasonBox = edit(-116)
		f.nameBox:SetScript("OnEnterPressed", function() f.rewardBox:SetFocus() end)
		f.rewardBox:SetScript("OnEnterPressed", function() f.reasonBox:SetFocus() end)
		f.reasonBox:SetScript("OnEnterPressed", function() ns.AddFromBox() end)
		f.reasonBox:SetScript("OnEscapePressed", function() f:Hide() end)

		local add = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
		add:SetSize(100, 22)
		add:SetPoint("BOTTOMLEFT", 18, 18)
		add:SetText("Add")
		add:SetScript("OnClick", function() ns.AddFromBox() end)
		local cancel = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
		cancel:SetSize(100, 22)
		cancel:SetPoint("BOTTOMRIGHT", -18, 18)
		cancel:SetText("Cancel")
		cancel:SetScript("OnClick", function() f:Hide() end)
		ui.addBox = f
	end
	f.rewardBox:SetText(tostring(math.floor((tonumber(DB().defaultReward) or 0) / 10000)))
	f.nameBox:SetText("")
	f.reasonBox:SetText("")
	f:Show()
	f.nameBox:SetFocus()
	return f
end

function ns.AddFromBox()
	local f = ui.addBox
	if not f then return end
	local name = Clean(f.nameBox:GetText(), MAX_NAME)
	if name == "" then Say("type the player's name first.") return end
	local gold = tonumber(((f.rewardBox:GetText() or ""):gsub("[^%d%.]", ""))) or (DEFAULT_REWARD / 10000)
	local want = math.max(0, math.floor(gold * 10000))
	local reason = Clean(f.reasonBox:GetText() or "", MAX_REASON)
	if reason == "" then reason = "added by " .. MyName() end
	local guid = GuidForName(name)
	local e
	if guid then
		e = AddKill(guid, name, ClassFromGUID(guid), "manual", reason)
		if e then
			e.kills = math.max(0, (tonumber(e.kills) or 1) - 1)
			e.auto = false
			e.want = math.max(want, tonumber(e.funded) or 0)
			Bump(e)
			Broadcast(e, false)
		end
	else
		local s = Store()
		local key = "n:" .. name:lower()
		e = s.entries[key]
		if not e then
			e = { guid = key, name = name, class = "", kills = 0, want = want, funded = 0, auto = false,
				at = Clock(), by = MyName(), src = "manual", reason = reason, victims = {}, claims = {}, paid = false }
			s.entries[key] = e
		else
			e.want = want
			e.reason = reason
		end
		Bump(e)
		Broadcast(e, false)
	end
	if e then
		Say("%s added. |cffffd100/kos fund %s|r makes the %s bounty live at once; you owe the bank until a manager marks it paid.",
			e.name, e.name, Money(math.max(0, tonumber(e.want) or 0)))
	end
	f:Hide()
	refresh()
	ns.Toggle(true)
end

-- The shell calls this to get the panel without opening a second window.
KillOnSight_BuildUI = BuildWindow

function ns.Toggle(force)
	DB()
	local f = BuildWindow()
	-- Opening the window (or the merged panel) is the one moment the board re-sorts itself. Sync,
	-- funding and claims must never reshuffle the rows under the player's cursor.
	if force == true or not f:IsShown() then ui.order, ui.offset = nil, 0 end
	if OlympusMytikasLoaded then
		OlympusMytikas_Show("kos", f)
		if force == true and refresh then pcall(refresh) end
		return
	end
	if force == true then f:Show() refresh() return end
	if f:IsShown() then f:Hide() else f:Show() refresh() end
end

RefreshIfShown = function()
	if refresh then pcall(refresh) end
end

-- ============================================================================ minimap

local function PlaceMinimap(button)
	local a = math.rad(tonumber(DB().minimapAngle) or 210)
	button:SetPoint("CENTER", Minimap, "CENTER", math.cos(a) * 80, math.sin(a) * 80)
end

local function BuildMinimap()
	if ui.minimap or type(Minimap) ~= "table" then return ui.minimap end
	local b = CreateFrame("Button", "KillOnSightMinimap", Minimap)
	b:SetSize(32, 32)
	b:SetFrameStrata("MEDIUM")
	b:SetClampedToScreen(true)
	local icon = b:CreateTexture(nil, "BACKGROUND")
	icon:SetTexture("Interface\\AddOns\\OlympusMytikas\\Media\\minimap")
	icon:SetAllPoints(b)
	b:RegisterForDrag("LeftButton")
	b:SetScript("OnClick", function() ns.Toggle() end)
	b:SetScript("OnDragStart", function(self)
		self:SetScript("OnUpdate", function()
			local mx, my = Minimap:GetCenter()
			local px, py = GetCursorPosition()
			px, py = px / UIParent:GetScale(), py / UIParent:GetScale()
			DB().minimapAngle = math.deg(math.atan2(py - my, px - mx))
			PlaceMinimap(self)
		end)
	end)
	b:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
	b:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_LEFT")
		GameTooltip:AddLine("Kill on Sight")
		GameTooltip:AddLine("Left click: the board", 0.79, 0.58, 0.34)
		GameTooltip:AddLine("Drag: move this button", 0.55, 0.47, 0.36)
		GameTooltip:Show()
	end)
	b:SetScript("OnLeave", function() GameTooltip:Hide() end)
	PlaceMinimap(b)
	ui.minimap = b
	return b
end

-- ============================================================================ commands

local function Find(input)
	input = Clean(input or "", MAX_NAME)
	if input == "" then return nil end
	local s = Store()
	local direct = s.entries["n:" .. input:lower()]
	if direct then return direct end
	local best
	for _, e in pairs(s.entries) do
		if SameName(e.name, input) then
			if not best or (tonumber(e.at) or 0) > (tonumber(best.at) or 0) then best = e end
		end
	end
	return best
end

local function Status()
	local recap = C_DeathRecap
	local has = "missing"
	if type(recap) == "table" and type(recap.HasRecapEvents) == "function" then
		local ok, yes = pcall(recap.HasRecapEvents)
		has = ok and tostring(yes) or "error"
	end
	local s = Store()
	local count = 0
	for _ in pairs(s.entries) do count = count + 1 end
	local money = BankMoney()
	Say("board: %d entries, %d queued - scope %s", count, #queue, Scope())
	Say("death recap: %s (ready now: %s) - last death: %s",
		type(recap) == "table" and "present" or "MISSING", has, lastWhy)
	Say("kill event: %s - in a guild: %s - sharing: %s - sent %d, refused %d, failed %d, heard %d",
		ns.partyKill and "registered" or "not registered", tostring(Ask(IsInGuild)),
		tostring(DB().share ~= false), stats.sent, stats.refused, stats.failed, stats.recv)
	Say("delete authority: guild master or %s only - their deletes stay final on every client",
		Board.MANAGER_RANK)
	local rankName, rankIndex
	if type(GetGuildInfo) == "function" then
		local ok, _, rn, ri = pcall(GetGuildInfo, "player")
		if ok and not Secret(rn, ri) then rankName, rankIndex = rn, ri end
	end
	Say("your rank: %s (index %s) - can remove/settle/clear debts: %s (needs GM or %s)",
		tostring(rankName or "UNREADABLE"), tostring(rankIndex or "?"),
		tostring(Board.CanManage()), Board.MANAGER_RANK)
	Say("guild bank gold: %s - daily withdrawal left: %s - bank keeps %d%%",
		money and Money(money) or "UNREADABLE",
		BankWithdraw() and Money(BankWithdraw()) or "unreadable", tonumber(DB().cutPercent) or 0)
	Say("bounties are live on request, no deposit needed - totals: bank keeps %s, prize paid out %s, prize pool %s, refunded %s",
		Money(s.bank.cut), Money(s.bank.paid), Money(s.bank.pool), Money(s.bank.refunded))
	local nextDue, nextName
	for _, e in pairs(s.entries) do
		local due = RefundDue(e)
		if due and (not nextDue or due < nextDue) then nextDue, nextName = due, e.name end
	end
	Say("refund policy: %d days unclaimed - %s", tonumber(DB().refundDays) or 0,
		nextDue and ("next: %s in %s"):format(nextName, Left(nextDue - Clock())) or "nothing waiting")
	local owed, debts = Ious(), Debts()
	Say("members owe the bank: %d debt(s), %s - bank owes: %d payment(s), %s - officer chat: %s",
		#owed, #owed > 0 and Money(OwedTotal(owed)) or "nothing",
		#debts, #debts > 0 and Money(OwedTotal(debts)) or "the bank is square",
		OfficerChannel() == "OFFICER" and "officer chat" or "guild chat")
	Say("addon channel: %s - prefix: %s", SendFn() and "available" or "missing", ns.prefixRegistered and "registered" or "no")
	Say("if a death went unrecorded, |cffffd100/kos recap|r prints what the client actually gave.")
end

-- What the client actually answers about the last death: the one thing that settles "why did it not
-- register" without guessing. Everything here is read through pcall/Secret, so a secret answer is
-- printed as <secret> instead of throwing.
local function ShowValue(v)
	if v == nil then return "nil" end
	if Secret(v) then return "<secret>" end
	local t = type(v)
	if t == "string" then
		if #v > 70 then v = v:sub(1, 70) .. "..." end
		return ("%q"):format(v)
	end
	if t == "number" or t == "boolean" then return tostring(v) end
	return "<" .. t .. ">"
end

local function RecapDump()
	DB()
	local build = "?"
	if type(GetBuildInfo) == "function" then
		local ok, v = pcall(GetBuildInfo)
		if ok and v ~= nil then build = tostring(v) end
	end
	Say("recap dump - client %s, KillOnSight %s", build, ns.VERSION)
	local r = C_DeathRecap
	Say("C_DeathRecap: %s", type(r))
	if type(r) == "table" then
		local names = {}
		for k in pairs(r) do names[#names + 1] = tostring(k) end
		table.sort(names)
		Say("  members: %s", #names > 0 and table.concat(names, ", ") or "(none)")
		local okHas, has = pcall(function() return type(r.HasRecapEvents) == "function" and r.HasRecapEvents() end)
		Say("  HasRecapEvents(): ok=%s value=%s", tostring(okHas), okHas and ShowValue(has) or "error")
		local okGet, events = pcall(function() return type(r.GetRecapEvents) == "function" and r.GetRecapEvents() end)
		Say("  GetRecapEvents(): ok=%s type=%s rows=%s", tostring(okGet),
			okGet and type(events) or "error", okGet and tostring(RecapRows(events)) or "-")
		if okGet and type(events) == "table" then
			for i = 1, math.min(RecapRows(events), 3) do
				local row = events[i]
				if type(row) ~= "table" then
					Say("  row %d: %s (%s)", i, tostring(row), type(row))
				else
					local keys = {}
					for k in pairs(row) do keys[#keys + 1] = k end
					table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
					local parts = {}
					for _, k in ipairs(keys) do parts[#parts + 1] = tostring(k) .. "=" .. ShowValue(row[k]) end
					Say("  row %d: %s", i, #parts > 0 and table.concat(parts, " ") or "(no fields)")
				end
			end
		end
	end
	local guid = Ask(UnitGUID, "player")
	local okIn, inside, kind = pcall(IsInInstance)
	Say("player: %s | guid %s (parsed: %s)",
		ShowValue(Ask(UnitFullName, "player")), ShowValue(guid), tostring(Guid(guid)))
	Say("state: dead %s | instance %s (raw: %s, %s, %s) | server time %s",
		ShowValue(Ask(UnitIsDeadOrGhost, "player")), tostring(InstanceState()),
		tostring(okIn), tostring(inside), tostring(kind), tostring(Clock()))
	Say("last death: %s | key %s", tostring(lastWhy), tostring(lastDeathKey))
	if type(lastRecap) == "table" then
		Say("this addon has read a recap: %d row(s)%s", RecapRows(lastRecap),
			lastDeathAt and (", at " .. tostring(lastDeathAt)) or "")
	else
		Say("this addon has never read a recap.")
	end
	Say("ignore instances: %s | notices: %s | in a guild: %s",
		tostring(DB().ignoreInstances ~= false), tostring(DB().notices ~= false), tostring(Ask(IsInGuild)))
end

local function Help()
	Say("|cffffd100/kos|r - the board")
	Say("|cffffd100/kos add <name> [gold] [reason]|r - put a player on the board")
	Say("|cffffd100/kos bounty <name>|r, |cffffd100/kos fund <name>|r - put up a live 1g bounty now")
	Say("|cffffd100/kos paidup <name>|r - GM or " .. Board.MANAGER_RANK ..
		" only: mark a member's bounty debts paid")
	Say("|cffffd100/kos paid|r - each hunter's 70%% goes into this month's prize pool; /kos boardpaid records the hand-over")
	Say("|cffffd100/kos refund <name>|r - GM or " .. Board.MANAGER_RANK ..
		" only: decide an unclaimed bounty goes back")
	Say("|cffffd100/kos handed <name>|r - GM or " .. Board.MANAGER_RANK ..
		" only: you gave the money back; the refund is done")
	Say("|cffffd100/kos owed|r - who owes the bank for a live bounty, and what the bank has not handed over")
	Say("|cffffd100/kos log|r - who removed an entry, decided a refund, handed one back or paid the prize")
	Say("|cffffd100/kos chat|r - replay the hidden kill/death notices; |cffffd100/kos chat clear|r empties them")
	Say("|cffffd100/kos board|r - this month's ranking and the whole prize pool")
	Say("|cffffd100/kos boardpaid <name>|r - GM or " .. Board.MANAGER_RANK ..
		" only: you handed the board leader that pool")
	Say("|cffffd100/kos officers|r - say the owed line in officer chat (needs a click or this command)")
	Say("|cffffd100/kos officermode auto|officer|guild|r - where that line goes (now %s)", DB().officerMode or "auto")
	Say("|cffffd100/kos refunddays <n>|r - how long a bounty waits (now %d days, 0 = never)", tonumber(DB().refundDays) or 0)
	Say("|cffffd100/kos announce [name]|r - post one line to guild chat")
	Say("|cffffd100/kos swap [name]|r - whisper the victim who set the bounty for an invite to that killer's layer (LayerSwap hosts answer too)")
	Say("|cffffd100/kos cut <pct>|r - what the bank keeps (now %d%%)", tonumber(DB().cutPercent) or 0)
	Say("|cffffd100/kos remove <name> [force]|r - GM or " .. Board.MANAGER_RANK ..
		" only: take one off the board (refused while money is owed)")
	Say("anyone can add a name, put up a bounty and announce it - only GM or " .. Board.MANAGER_RANK ..
		" can remove entries, clear a member's debt or record what the bank handed over.")
	Say("|cffffd100/kos reward <gold>|r, |cffffd100/kos list|r, |cffffd100/kos bank|r, |cffffd100/kos sync|r, |cffffd100/kos status|r")
	Say("|cffffd100/kos where [name]|r - last known location, killer level/layer and what this client exposed")
	Say("|cffffd100/kos pins|r - refresh and count the map pins (they expire after 30 minutes; addon users only)")
	Say("|cffffd100/kos badge|r - scan visible nameplates and say whether the skull is actually on the bounty")
	Say("|cffffd100/kos warn|r - turn the local raid-style warning banner on/off (now %s)",
		DB().warnNearby == false and "off" or "on")
	Say("|cffffd100/kos recap|r - what the client gave about your last death (for a death that did not count)")
	Say("|cffffd100/kos kills|r - who killed who in the guild; |cffffd100/kos kills mine|r - only your deaths")
	Say("|cffffd100/kos share|r, |cffffd100/kos notices|r, |cffffd100/kos minimap|r, |cffffd100/kos reset|r")
	Say("|cffffd100/kos notice|r - show the read-this-first page again as a preview (no acknowledgement changes)")
end

local function Handler(msg)
	DB()
	msg = tostring(msg or "")
	local cmd, rest = msg:match("^%s*(%S*)%s*(.*)$")
	cmd = (cmd or ""):lower()
	rest = rest or ""
	if cmd == "on" then
		ns.SetEnabled(true)
		Say("Kill on Sight is ON.")
		return
	end
	if cmd == "off" then
		ns.SetEnabled(false)
		Say("Kill on Sight is OFF.")
		return
	end
	if not ns.Enabled() then
		Say("Kill on Sight is OFF - use the button in the Olympus Mytikas window or /kos on to turn it back on.")
		return
	end
	if cmd == "" then ns.Toggle() return end

	if cmd == "add" then
		local name, gold, reason = rest:match("^(%S+)%s*(%S*)%s*(.*)$")
		if not name then Say("usage: /kos add <name> [gold] [reason]") return end
		local want = tonumber(gold) and math.max(0, math.floor(tonumber(gold) * 10000)) or (tonumber(DB().defaultReward) or 0)
		local text = Clean(reason, MAX_REASON)
		local e
		local guid = GuidForName(name)
		if guid then
			e = AddKill(guid, name, ClassFromGUID(guid), "manual", text)
			if e then
				e.kills = math.max(0, (tonumber(e.kills) or 1) - 1)
				e.auto = false
				e.want = math.max(want, tonumber(e.funded) or 0)
				Bump(e)
				Broadcast(e, false)
			end
		else
			local s = Store()
			local key = "n:" .. Clean(name, MAX_NAME):lower()
			e = s.entries[key]
			if not e then
				e = { guid = key, name = Clean(name, MAX_NAME), class = "", kills = 0, want = want, funded = 0,
					auto = false, at = Clock(), by = MyName(), src = "manual",
					reason = text ~= "" and text or ("added by " .. MyName()), victims = {}, claims = {}, paid = false }
				s.entries[key] = e
			else
				e.want = want
				if text ~= "" then e.reason = text end
			end
			Bump(e)
			Broadcast(e, false)
		end
		if e then
			Say("%s added. /kos fund makes a %s bounty live at once.",
				e.name, Money(math.max(0, (tonumber(e.want) or 0) - (tonumber(e.funded) or 0))))
		end
		RefreshIfShown()
		return
	end

	if cmd == "bounty" or cmd == "job" then
		local e = Find(rest)
		if not e then e = ui.selected end
		if not e then Say("nobody called %q is on the board.", Clean(rest, MAX_NAME)) return end
		local ok, why = ns.StartBounty(e, true)
		if not ok then Say("%s", tostring(why)) end
		return
	end

	if cmd == "fund" then
		local e = Find(rest)
		if not e then
			if ui.selected then e = ui.selected end
		end
		if not e then Say("nobody called %q is on the board.", Clean(rest, MAX_NAME)) return end
		local ok, _, why = StartJob(e, true)
		if not ok then Say("%s", tostring(why)) end
		return
	end
	if cmd == "paidup" then
		local ok, why = PaidUp(rest, MyName())
		if not ok then Say("%s", tostring(why)) end
		return
	end
	if cmd == "deposited" then
		Say("nothing to check: a bounty is live as soon as somebody asks for it. The requester owes the gold until a manager uses /kos paidup.")
		return
	end
	if cmd == "payout" or cmd == "paid" then
		Say("hunters are not paid per kill: each hunter's 70%% goes into this month's prize pool. " ..
			"The board leader is paid once at month end - /kos boardpaid records it.")
		return
	end
	if cmd == "refund" then
		local e = Find(rest)
		if not e then Say("nobody called %q is on the board.", Clean(rest, MAX_NAME)) return end
		local ok, why = Refund(e.guid)
		if not ok then Say("%s", tostring(why)) end
		return
	end
	if cmd == "handed" or cmd == "handback" then
		local e = Find(rest)
		if not e then Say("nobody called %q is on the board.", Clean(rest, MAX_NAME)) return end
		if not e.refundDue then
			Say("%s has no refund waiting - /kos refund %s marks one first.", e.name, e.name)
			return
		end
		local ok, why = ConfirmRefund(e.guid, MyName())
		if not ok then Say("%s", tostring(why)) end
		return
	end
	if cmd == "owed" then
		local list, ious = Debts(), Ious()
		if #list == 0 and #ious == 0 then
			Say("nobody owes anything - every bounty is either open or settled.")
			return
		end
		if #ious > 0 then
			local total = 0
			for i = 1, #ious do total = total + (tonumber(ious[i].amount) or 0) end
			Say("|cffffd100members owe the guild bank %s|r - %d live bounty debt%s:",
				Money(total), #ious, #ious == 1 and "" or "s")
			for i = 1, #ious do
				local d = ious[i]
				Say("  %d. %s owes %s for %s%s", i, d.name, Money(d.amount), d.target or "?",
					d.entry and d.entry.paidUp and " (already paid up)" or "")
			end
			Say("a manager clears them with |cffffd100/kos paidup <name>|r.")
		end
		if #list > 0 then
			Say("|cffffd100the guild bank still owes %s|r - %d payment%s not handed over yet:",
				Money(OwedTotal(list)), #list, #list == 1 and "" or "s")
			for i = 1, #list do
				local d = list[i]
				Say("  %d. %s - %s %s%s", i, d.name, Money(d.amount),
					d.kind == "refund" and "back to "
						or (d.kind == "monthly" and "prize pool to " or "to "), d.to)
			end
		end
		Say("say it: |cffffd100/kos officers|r (%s) - refund: |cffffd100/kos handed <name>|r - prize: |cffffd100/kos boardpaid|r.",
			OfficerChannel() == "OFFICER" and "officer chat" or "guild chat")
		return
	end
	if cmd == "officers" then
		PostOwed()
		return
	end
	if cmd == "officermode" then
		local mode = (rest or ""):lower():match("^%s*(%a+)")
		if not mode then
			Say("officer lines go to: %s (auto) - usage: /kos officermode auto|officer|guild", OfficerChannel())
			return
		end
		if mode ~= "auto" and mode ~= "officer" and mode ~= "guild" then
			Say("usage: /kos officermode auto|officer|guild")
			return
		end
		DB().officerMode = mode
		Say("officer lines now go to %s (mode %s).", OfficerChannel(), mode)
		return
	end
	if cmd == "remove" then
		local force = false
		local name = rest
		local trimmed = name:match("^(.-)%s+force%s*$")
		if trimmed then force, name = true, trimmed end
		if name:lower() == "force" then force, name = true, "" end
		local e = Find(name)
		if not e and ui.selected then e = ui.selected end
		if not e then Say("nobody called %q is on the board.", Clean(name, MAX_NAME)) return end
		local ok, why = Remove(e.guid, force)
		if not ok then
			Say("%s", tostring(why))
			Say("if the money really is gone, force it: |cffffd100/kos remove %s force|r", e.name)
			return
		end
		Say("%s removed.", e.name)
		if ui.selected and ui.selected.guid == e.guid then ui.selected = nil end
		RefreshIfShown()
		return
	end
	if cmd == "announce" then
		local e = Find(rest)
		if not e then e = ui.selected end
		if not e then Say("nothing to announce yet.") return end
		ns.FillKillerInfo(e)
		Announce(e)
		return
	end
	if cmd == "swap" or cmd == "swapto" then
		local e = Find(rest)
		if not e then e = ui.selected end
		ns.SwapToLayer(e)
		return
	end
	if cmd == "cut" then
		local pct = tonumber(rest)
		if not pct or pct < 0 or pct > 50 then Say("usage: /kos cut <0-50>") return end
		DB().cutPercent = math.floor(pct)
		Say("the bank now keeps %d%% of a funded bounty.", DB().cutPercent)
		return
	end
	if cmd == "refunddays" then
		local days = tonumber(rest)
		if not days or days < 0 or days > 365 then Say("usage: /kos refunddays <0-365>") return end
		DB().refundDays = math.floor(days)
		Say(DB().refundDays > 0
			and ("an unclaimed bounty now goes back to its payer after %d days."):format(DB().refundDays)
			or "unclaimed bounties now stay until somebody refunds them by hand.")
		return
	end
	if cmd == "reward" then
		local gold = tonumber(rest)
		if not gold or gold < 0 then Say("usage: /kos reward <gold>") return end
		DB().defaultReward = math.floor(gold * 10000)
		Say("a bounty now asks for %s - live as soon as somebody requests it.", Money(DB().defaultReward))
		return
	end
	if cmd == "board" then
		Board.BoardPrint()
		return
	end
	if cmd == "boardpaid" then
		local ok, why = Board.BoardPaid(rest, MyName())
		if not ok then Say("%s", tostring(why)) end
		return
	end
	if cmd == "bank" then
		local money = BankMoney()
		local s = Store().bank
		Say("bank gold now: %s", money and Money(money) or "UNREADABLE")
		Say("bank keeps %s, prize paid out %s, prize pool %s, refunded %s - bounties are live on request",
			Money(s.cut), Money(s.paid), Money(s.pool), Money(s.refunded))
		local month = Board.BoardMonth(Clock())
		local owed = Board.FundForMonth(month)
		local a = Store().board.award
		if a.month == month and a.who and a.who ~= "" then owed = 0 end
		if owed <= 0 then
			local h = Board.PastPrize()
			if h then owed, month = h.prize, h.month end
		end
		Say("prize pool for %s: %s%s", month, Money(owed),
			owed > 0 and " (to the board leader - /kos boardpaid records the hand-over)"
				or " (nothing waiting)")
		return
	end
	if cmd == "kills" or cmd == "deaths" or cmd == "killed" then
		local mine = (rest or ""):lower():find("mine", 1, true) ~= nil
		local list = SortedDeaths(mine)
		if #list == 0 then
			Say(mine and "the guild has no death of yours recorded yet - a death shares itself with the guild."
				or "no guild deaths recorded yet - an enemy who kills a guild member appears here.")
			return
		end
		Say(mine and "|cffffd100who killed you|r - newest first:"
			or "|cffffd100who killed who in the guild|r - newest first:")
		for i = 1, math.min(#list, 15) do
			local d = list[i]
			local e = Entry(d.kguid)
			local bounty
			if not e then bounty = "not on the board"
			elseif (tonumber(e.funded) or 0) > 0 then bounty = Money(e.funded) .. " bounty"
			else bounty = StateText(e) end
			local where = SpotLine(d)
			local info = ns.KillerLine(d)
			Say("  %s%s|r killed %s - %s - %s%s%s", DeathColor(d), d.kname,
				SameName(d.vname, MyName()) and "|cffffd100you|r" or (d.vname ~= "" and d.vname or "?"),
				Ago(d.at), bounty, info and (" - " .. info) or "", where and (" - " .. where) or "")
		end
		Say("click a killer's name in the window to select him and set a bounty: |cffffd100/kos|r")
		return
	end
	if cmd == "list" then
		local list = SortedEntries()
		if #list == 0 then Say("the board is empty.") return end
		for i = 1, math.min(#list, 25) do
			local e = list[i]
			Say("%d. %s%s|r - %s/%s - %d kill(s) - %s", i, ClassColor(e), e.name,
				Money(tonumber(e.funded) or 0), Money(tonumber(e.want) or 0), tonumber(e.kills) or 0, StateText(e))
		end
		return
	end
	if cmd == "log" then
		Board.LogPrint()
		return
	end
	if cmd == "chat" then
		if rest:lower():match("^clear") then
			ns.chatLog = {}
			Say("hidden kill notices cleared.")
			return
		end
		if #ns.chatLog == 0 then
			Say("no hidden kill notices yet.")
			return
		end
		Say("|cffffd100hidden kill notices (oldest first):|r")
		for i = 1, #ns.chatLog do Say("%d. %s", i, ns.chatLog[i]) end
		return
	end
	if cmd == "sync" then
		SendDigest(true)
		QueueParts("Q", true)
		Say("asked the guild for its board and sent ours.")
		return
	end
	if cmd == "share" then
		DB().share = DB().share == false
		Say("sharing the board is now %s.", DB().share and "on" or "off")
		return
	end
	if cmd == "notices" then
		DB().notices = not (DB().notices ~= false)
		Say("chat notices are now %s.", DB().notices and "on" or "off")
		return
	end
	if cmd == "minimap" then
		local on
		if OlympusMytikasLoaded then
			on = not OlympusMytikasDB.minimap
			if type(OlympusMytikas_Minimap) == "function" then OlympusMytikas_Minimap(on) end
		else
			on = not (DB().minimap ~= false)
			local b = BuildMinimap()
			if b then if on then b:Show() else b:Hide() end end
		end
		DB().minimap = on
		Say("the minimap button is now %s.", on and "shown" or "hidden")
		return
	end
	if cmd == "status" then Status() return end
	if cmd == "warn" then
		DB().warnNearby = DB().warnNearby == false
		ns.warned = {}
		Say("nearby bounty warnings are now %s (a local raid-style banner; no chat raid warning is sent).",
			DB().warnNearby == false and "off" or "on")
		return
	end
	if cmd == "badge" or cmd == "marks" then
		if ns.BadgeReport then pcall(ns.BadgeReport) end
		return
	end
	if cmd == "notice" or cmd == "welcome" then
		Say("showing the read-this-first page as a preview; your acknowledgement is unchanged.")
		ShowWelcome(true)
		return
	end
	if cmd == "where" or cmd == "spot" then
		local e = Find(rest) or ui.selected
		if not e then
			Say("nobody called %q is on the board - select an enemy first. Client map reads: %s",
				Clean(rest, MAX_NAME), MapProbeLine())
			return
		end
		ns.FillKillerInfo(e)
		Say("%s: %s", e.name, SpotStatus(e))
		Say("killer: %s", ns.KillerLine(e) or "level and layer unknown - the client gave nothing readable")
		local cached = e and ns.seenLevels[e.guid]
		Say("level read: %s; guild roster: %s; Olympus record: %s; LayerSwap layer: %s",
			cached and ("seen level " .. tostring(cached.level) .. " " ..
				(Clock() - (tonumber(cached.at) or 0)) .. "s ago") or "no sighting cached",
			tostring(ns.GuildLevel(e.name) or "unknown"),
			tostring(ns.OlympusLevel(e.guid, e.name) or "unknown"),
			tostring(ns.MyLayer() or "unknown"))
		Say("client map reads: %s", MapProbeLine())
		return
	end
	if cmd == "pins" then
		if not MapLib.Pins() then
			Say("map pins are unavailable - HereBeDragons-Pins did not load.")
			return
		end
		MapLib.pinDirty = true
		local n = MapLib.Refresh()
		Say("%d last-known location pin(s): %d on the world map, %d on the minimap.",
			n, MapLib.worldCount, MapLib.miniCount)
		Say("pins expire 30 minutes after the last sighting; /kos where still keeps the location.")
		Say("only people running Kill on Sight see them; a nearby point is not an exact killer pin.")
		if MapLib.GamepadUI() then Say("world map pins are off in the gamepad UI; minimap pins stay.") end
		return
	end
	if cmd == "recap" then RecapDump() return end
	if cmd == "reset" then
		local s = Store()
		DB().scopes[Scope()] = { entries = {}, removed = {}, deaths = s.deaths or {}, ver = 1 }
		ui.selected = nil
		MapLib.pinDirty = true
		Say("this realm's board is wiped (the guild death history is kept).")
		RefreshIfShown()
		return
	end
	Help()
end

-- ============================================================================ nameplate badge
-- This local badge is NOT the shared raid marker - Forever refuses to let addons set that.
-- It uses Blizzard's own skull texture so it reads as the same icon, and it is drawn per client
-- for people running Kill on Sight. Nameplates are recycled between units, so the badge is made
-- once per plate and shown or hidden on every refresh; unfunded or settled targets get none.
local MARK_ART = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_8"
local marks = {}

local function MarkWanted(e)
	if not e or e.paid or e.refunded or e.refundDue then return false end
	return (tonumber(e.funded) or 0) > 0
end

-- A real RAID_WARNING chat send is protected on this client, but the game's own warning BANNER is
-- not: addons here already call RaidNotice_AddMessage(RaidWarningFrame, ...) from timers. Use that
-- for the "bounty is near me" notice - local to this hunter, no leader/assist needed, no spam chat.
ns.WARN_COOLDOWN = 30
ns.warned = ns.warned or {}
ns.BountyWarning = function(e)
	if not e then return end
	local name = (e.name ~= "") and e.name or "Unknown"
	local text = ("BOUNTY IN RANGE: %s (%s)"):format(name, Money(tonumber(e.funded) or 0))
	local color = (type(ChatTypeInfo) == "table" and ChatTypeInfo["RAID_WARNING"])
		or { r = 1, g = 0.82, b = 0 }
	if type(RaidNotice_AddMessage) == "function" and type(RaidWarningFrame) == "table" then
		pcall(RaidNotice_AddMessage, RaidWarningFrame, text, color)
	elseif type(UIErrorsFrame) == "table" and type(UIErrorsFrame.AddMessage) == "function" then
		pcall(UIErrorsFrame.AddMessage, UIErrorsFrame, text, 1, 0.82, 0)
	else
		Say("%s", text)
	end
	if type(PlaySoundFile) == "function" then
		pcall(PlaySoundFile, "Sound\\Interface\\RaidWarning.ogg")
	end
end

local function MakeMark(plate)
	local m = CreateFrame("Frame", nil, plate)
	m:SetSize(32, 32)
	local icon = m:CreateTexture(nil, "OVERLAY")
	icon:SetAllPoints(m)
	icon:SetTexture(MARK_ART)
	m.icon = icon
	return m
end

local function RefreshMarks()
	if not ns.Enabled() then
		for plate, m in pairs(marks) do m:Hide() end
		ns.warned = {}
		return
	end
	-- Keep the short sighting cache fed while the world is visible, before the death screen hides it.
	for _, unit in ipairs(ns.InfoUnits()) do ns.RememberLevel(unit) end
	if type(C_NamePlate) ~= "table" or type(C_NamePlate.GetNamePlateForUnit) ~= "function" then return end
	local seen = {}
	local nearby = {}
	local warn = (DB().warnNearby ~= false)
	if not warn then ns.warned = {} end
	for i = 1, 40 do
		local unit = "nameplate" .. i
		local ok, plate = pcall(C_NamePlate.GetNamePlateForUnit, unit)
		if ok and type(plate) == "table" then
			local guid = Guid(Ask(UnitGUID, unit))
			ns.RememberLevel(unit)
			local e = guid and Entry(guid) or nil
			-- An older row may have been saved with both numbers at 0. A target we can actually see
			-- now is a real sighting, so fill what is missing; never fill from a name alone.
			if e and ((tonumber(e.klevel) or 0) <= 0 or not ns.LayerFresh(e)) then
				pcall(ns.FillKillerInfo, e)
			end
			if guid and Ask(UnitIsPlayer, unit) ~= false and MarkWanted(e) then
				seen[plate] = true
				local m = marks[plate]
				if not m then
					m = MakeMark(plate)
					marks[plate] = m
				end
				m:SetPoint("CENTER", plate, "CENTER", 0, 30)
				m:Show()
				if warn then
					nearby[guid] = true
					local now = Mono()
					local last = ns.warned[guid]
					if not last or (now - last) >= ns.WARN_COOLDOWN then
						ns.warned[guid] = now
						pcall(ns.BountyWarning, e)
					end
				end
			end
		end
	end
	-- Leaving the area (or settling the bounty) clears the repeat timer, so walking
	-- back into range fires the banner again instead of waiting out the cooldown.
	for guid in pairs(ns.warned) do
		if not nearby[guid] then ns.warned[guid] = nil end
	end
	for plate, m in pairs(marks) do
		if not seen[plate] then m:Hide() end
	end
end

-- /kos badge: prove what the scan above can actually see on this client. It is a diagnostic,
-- not a second badge path - the skull is still drawn only by RefreshMarks.
local function BadgeReport()
	if type(C_NamePlate) ~= "table" or type(C_NamePlate.GetNamePlateForUnit) ~= "function" then
		Say("no nameplate API here, so no badge can be drawn.")
		return
	end
	local plates, players, skulls = 0, 0, 0
	for i = 1, 40 do
		local unit = "nameplate" .. i
		local ok, plate = pcall(C_NamePlate.GetNamePlateForUnit, unit)
		if ok and type(plate) == "table" then
			plates = plates + 1
			if Ask(UnitIsPlayer, unit) ~= false then
				players = players + 1
				local guid = Guid(Ask(UnitGUID, unit))
				local name = Clean(Ask(UnitName, unit) or "?", MAX_NAME)
				local e = guid and Entry(guid) or nil
				local m = marks[plate]
				if MarkWanted(e) and m and m:IsShown() then skulls = skulls + 1 end
				local why
				if not guid then why = "no usable GUID"
				elseif not e then why = "not on the board"
				elseif not MarkWanted(e) then why = "not a funded live bounty"
				elseif not m then why = "badge frame missing"
				elseif not m:IsShown() then why = "badge hidden"
				else why = "SKULL SHOWN" end
				Say("plate %d: %s - %s", i, name, why)
			end
		end
	end
	Say("badge scan: %d plate(s), %d player(s), %d skull(s) on screen", plates, players, skulls)
	Say("nearby bounty warning banner: %s (repeat %ds while one stays in range; never a chat raid warning)",
		DB().warnNearby == false and "off" or "on", tonumber(ns.WARN_COOLDOWN) or 30)
end

-- ============================================================================ wiring

local frame = CreateFrame("Frame")
ns.frame = frame
local handlers = {}

local function On(event, fn)
	handlers[event] = handlers[event] or {}
	table.insert(handlers[event], fn)
	pcall(frame.RegisterEvent, frame, event)
end

frame:SetScript("OnEvent", function(self, event, ...)
	-- A disabled addon does nothing in the world: no deaths, no sync, no plates, no reminders.
	-- ADDON_LOADED and PLAYER_LOGIN still pass so Init can run and the button can turn it back on.
	if not ns.Enabled() and event ~= "ADDON_LOADED" and event ~= "PLAYER_LOGIN" then return end
	local list = handlers[event]
	if not list then return end
	for i = 1, #list do
		local ok = pcall(list[i], ...)
		if not ok and DB().notices ~= false and not ns.reported then
			ns.reported = true
			Say("something in this addon failed (%s); /kos status still works.", tostring(event))
		end
	end
end)

On("ADDON_LOADED", function(name)
	if name ~= ADDON then return end
	Init()
	if not ns.Enabled() then return end
	ShowWelcome()
	ns.partyKill = pcall(frame.RegisterEvent, frame, "PARTY_KILL")
	ns.prefixRegistered = false
	if type(C_ChatInfo) == "table" and type(C_ChatInfo.RegisterAddonMessagePrefix) == "function" then
		ns.prefixRegistered = pcall(C_ChatInfo.RegisterAddonMessagePrefix, PREFIX)
	end
	if DB().minimap and not OlympusMytikasLoaded then BuildMinimap() end
end)

On("PLAYER_LOGIN", function()
	DB()
	Board.BoardRollover(Clock())
	if ns.Enabled() then ShowWelcome() end
	ns.prefixRegistered = false
	if type(C_ChatInfo) == "table" and type(C_ChatInfo.RegisterAddonMessagePrefix) == "function" then
		ns.prefixRegistered = pcall(C_ChatInfo.RegisterAddonMessagePrefix, PREFIX)
	end
	if type(C_Timer) == "table" and type(C_Timer.NewTicker) == "function" then
		local live = function() return ns.Enabled() end
		C_Timer.NewTicker(SEND_INTERVAL, function() if live() then pcall(Pump) end end)
		C_Timer.NewTicker(180, function() if live() then pcall(Sweep) end end)
		-- The debt reminder keeps coming back until somebody actually hands the gold over.
		C_Timer.NewTicker(OFFICER_REMIND, function() if live() then pcall(Remind) end end)
		-- A death watch, so a client that raises no PLAYER_DEAD still records who killed you.
		C_Timer.NewTicker(2, function() if live() then pcall(WatchDeath) end end)
		-- Nameplates come and go (and are recycled), so the bounty badge is reconciled often.
		C_Timer.NewTicker(0.5, function() pcall(RefreshMarks) end)
		-- The map pins are changed by board updates and input-mode switches, not every frame.
		-- A pin also ages out on its own 30 minutes after the last sighting.
		C_Timer.NewTicker(1, function()
			if not live() then return end
			local ok, expired = pcall(MapLib.HasExpired)
			if MapLib.pinDirty or (ok and expired) then pcall(MapLib.Refresh) end
		end)
	end
	if type(C_Timer) == "table" and type(C_Timer.After) == "function" then
		-- Old rows stay in saved variables with 0 level/layer. Repair them from Olympus evidence and
		-- LayerSwap's letter table on login so the board shows the fix without needing a new death.
		C_Timer.After(2, function() if ns.Enabled() then pcall(ns.BackfillSavedInfo) end end)
		C_Timer.After(8, function() if ns.Enabled() then SendDigest(false) QueueParts("H", false) end end)
		C_Timer.After(HELLO_EVERY, function() if ns.Enabled() then QueueParts("H", false) end end)
		C_Timer.After(20, function()
			-- Let other clients answer the first digest first, then remind debtors.
			if ns.Enabled() then pcall(Remind) end
		end)
	end
end)

On("PLAYER_ENTERING_WORLD", function()
	DB()
	if DB().minimap and not OlympusMytikasLoaded then BuildMinimap() end
	MapLib.pinDirty = true
	pcall(RefreshMarks)
end)

-- Blizzard's gamepad map touches protected canvas state on this client. The ticker then clears the
-- world pins; the minimap ones are harmless and stay.
On("INPUT_DEVICE_INTERFACE_TRANSITION", function() MapLib.pinDirty = true end)

On("NAME_PLATE_UNIT_ADDED", function() pcall(RefreshMarks) end)
On("NAME_PLATE_UNIT_REMOVED", function() pcall(RefreshMarks) end)

On("PLAYER_DEAD", function() OnPlayerDead() end)
On("PARTY_KILL", function(a, b) OnPartyKill(a, b) end)
On("CHAT_MSG_ADDON", function(prefix, text, dist, sender) OnAddonMessage(prefix, text, dist, sender) end)
On("CHAT_MSG_GUILD", function(text, sender) OnGuildChat(text, sender) end)
-- The LayerSwap notes last only a few seconds. Refresh them when our own whisper is actually sent,
-- so a player who waits before pressing Enter still reaches a host on the victim's side.
On("CHAT_MSG_WHISPER_INFORM", function(text, sender)
	local p = ns.pendingSwap
	if p and p.text and SameName(sender, p.target) and Clean(text, 200) == Clean(p.text, 200) then
		ns.SendSwapNotes(p.target, p.zone, p.id)
		ns.pendingSwap = nil
	end
end)

SLASH_KILLONSIGHT1 = "/kos"
SLASH_KILLONSIGHT2 = "/killonsight"
SlashCmdList["KILLONSIGHT"] = function(msg) Handler(msg) end

ns.Handler = Handler
ns.Init = Init
-- The merged shell calls this from its on/off button; KoS stands alone if it is absent.
KillOnSight_SetEnabled = ns.SetEnabled
KillOnSight_Enabled = ns.Enabled
ns.ui = ui
ns.ShowWelcome = ShowWelcome
ns.PreviewWelcome = function() ShowWelcome(true) end
ns.Status = Status
ns.RecapDump = RecapDump
ns.CaptureDeath = CaptureDeath
ns.OnPlayerDead = OnPlayerDead
ns.OnPartyKill = OnPartyKill
ns.OnAddonMessage = OnAddonMessage
ns.ApplyEntry = ApplyEntry
ns.ApplyRemoval = ApplyRemoval
ns.ParseEntry = ParseEntry
ns.RowFor = RowFor
ns.AddKill = AddKill
ns.ClaimKill = ClaimKill
ns.Fund = Fund
ns.PoolKill = PoolKill
ns.Refund = Refund
ns.Expire = Expire
ns.ConfirmRefund = ConfirmRefund
ns.HandOver = HandOver
ns.Debts = Debts
ns.Ious = Ious
ns.PaidUp = PaidUp
ns.BoardMonth = Board.BoardMonth
ns.BoardRow = Board.BoardRow
ns.ParseBoardRow = Board.ParseBoardRow
ns.BoardCredit = Board.BoardCredit
ns.ApplyBoardCredit = Board.ApplyBoardCredit
ns.FundForMonth = Board.FundForMonth
ns.ApplyBoardPaid = Board.ApplyBoardPaid
ns.PastPrize = Board.PastPrize
ns.BoardScores = Board.BoardScores
ns.BoardRanks = Board.BoardRanks
ns.BoardWinner = Board.BoardWinner
ns.BoardRollover = Board.BoardRollover
ns.BoardPaid = Board.BoardPaid
ns.BoardPrint = Board.BoardPrint
ns.OwedTotal = OwedTotal
ns.OwedLine = OwedLine
ns.OfficerChannel = OfficerChannel
ns.PostOwed = PostOwed
ns.Remind = Remind
ns.Sweep = Sweep
ns.RefundDue = RefundDue
ns.Left = Left
ns.Remove = Remove
ns.CanManage = Board.CanManage
ns.MANAGER_RANK = Board.MANAGER_RANK
ns.AuditRow = Board.AuditRow
ns.ParseAudit = Board.ParseAudit
ns.LogPrint = Board.LogPrint
ns.StateOf = StateOf
ns.StateText = StateText
ns.StartJob = StartJob
ns.ReopenEntry = ReopenEntry
ns.PayoutOf = PayoutOf
ns.CutOf = CutOf
ns.Scope = Scope
ns.Store = Store
ns.Entry = Entry
ns.Pump = Pump
ns.QueueParts = QueueParts
ns.SendDigest = SendDigest
ns.Announce = Announce
ns.AnnounceText = AnnounceText
ns.Money = Money
ns.MyName = MyName
ns.SortedEntries = SortedEntries
ns.RecordDeath = RecordDeath
ns.ApplyDeath = ApplyDeath
ns.ParseDeath = ParseDeath
ns.DeathRow = DeathRow
ns.SortedDeaths = SortedDeaths
ns.Ago = Ago
ns.KillingBlowRecap = KillingBlowRecap
ns.CaptureSpot = CaptureSpot
ns.SpotLine = SpotLine
ns.MapPins = MapLib
ns.RefreshMapPins = function()
	MapLib.pinDirty = true
	return MapLib.Refresh()
end
ns.RefreshMarks = RefreshMarks
ns.BadgeReport = BadgeReport
ns.marks = marks
ns.BankMoney = BankMoney
ns.stats = stats
ns.queue = queue
ns.PREFIX = PREFIX
ns.db = function() return DB() end
