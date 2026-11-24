-- Lua 5.1 client fixtures. Only registered events, slash commands and the add
-- dialog's bound callback drive changes to the actual modules' SavedVariables.
local addon = "OlympusMytikas"
dofile("tests/forever-map.lua")

local function client(player, saved)
    local messages, sends, timers, frames = {}, {}, {}, {}
    local env = setmetatable({
        OlympusMytikasLoaded = true, OlympusMytikasDB = { minimap = true },
        OlympusRecruitDB = saved.recruit, KillOnSightDB = saved.kos,
        SlashCmdList = {}, UISpecialFrames = {},
        GetRealmName = function() return player.realm end,
        UnitFactionGroup = function() return player.faction end,
        UnitName = function(unit) if unit == "player" then return player.name end end,
        GetGuildInfo = function() return "Fixture Guild", player.rank, player.rankIndex end,
        GetServerTime = function() return 1800000000 end,
        DEFAULT_CHAT_FRAME = { AddMessage = function(_, text) messages[#messages+1] = text end },
        SendChatMessage = function(...) sends[#sends+1] = {...} end,
        C_Timer = { After = function(_, callback) timers[#timers+1] = callback end },
        CreateFrame = function()
            local frame = { events = {}, scripts = {} }
            function frame:RegisterEvent(name) self.events[name] = true end
            function frame:SetScript(name, callback) self.scripts[name] = callback end
            frames[#frames+1] = frame
            return frame
        end,
    }, { __index = _G })
    env._G = env
    env.OlympusMytikas_Minimap = function(on) env.OlympusMytikasDB.minimap = on end
    local function loadModule(name)
        local ns = {}
        setfenv(assert(loadfile(addon .. "/" .. name .. ".lua")), env)(addon, ns)
        return ns
    end
    local function event(name, ...)
        for _, frame in ipairs(frames) do
            if frame.events[name] then frame.scripts.OnEvent(frame, name, ...) end
        end
    end
    return env, loadModule, event, messages, sends, timers
end

local function interleavedFragments()
    local env, load = client({name = "Beta", realm = "Fixture"}, {})
    local ns = load("KillOnSight")
    env.IsInGuild = function() return true end
    local function fragment(index, sender, body)
        ns.OnAddonMessage("KOS", "C1:" .. index .. ":2:" .. body, "GUILD", sender)
    end
    fragment(1, "Alpha", "E~Player-1-00000001~")
    fragment(1, "Gamma", "E~Player-1-00000002~")
    fragment(2, "Gamma", "2~100~0~0~0~~Two")
    fragment(2, "Alpha", "1~100~0~0~0~~One")
    assert(ns.Entry("Player-1-00000001").name == "One")
    assert(ns.Entry("Player-1-00000002").name == "Two")
end
interleavedFragments()

local function expectLine(messages, pattern)
    local last = messages[#messages] or ""
    assert(last:find(pattern, 1, true), "expected '" .. pattern .. "', got '" .. last .. "'")
end

local function builtInAds()
    local env, load, _, messages, sends = client({name = "Alpha", realm = "Fixture"}, {})
    load("OlympusRecruit")
    local command = env.SlashCmdList.OLYMPUSRECRUIT
    command("profile")
    local count = assert(tonumber(table.concat(messages):match("(%d+) in the pool")))
    for index = 1, count do
        command("pick " .. index)
        assert(#sends == index * 2 and #sends[#sends][1] <= 255)
    end
end
builtInAds()

local function recruit()
    local player = { realm = "Fixture" }
    local stored = { custom = {"<Olympus Mytikas> Existing ad"}, minimap = false, minimapAngle = 45 }
    local env, load, event, messages, sends, timers = client(player, {recruit = stored})
    load("OlympusRecruit")
    local command = env.SlashCmdList.OLYMPUSRECRUIT
    event("ADDON_LOADED", "AnotherAddon")
    assert(#messages == 0)
    event("ADDON_LOADED", addon) -- Name is unavailable early in login.
    assert(stored.chars == nil and #stored.custom == 1)
    player.name = "Alpha"
    command("profile")
    assert(stored.chars["Fixture-Alpha"].minimap == false and stored.chars["Fixture-Alpha"].minimapAngle == 45)
    command("minimap")
    command("minimap")
    assert(stored.chars["Fixture-Alpha"].minimap == true and stored.minimap == false)
    player.name = "Beta"
    command("profile")
    assert(stored.chars["Fixture-Beta"].minimap == false)

    command("add   Raids   on Friday  ")
    assert(stored.custom[2] == "<Olympus Mytikas> Raids on Friday")
    local index = assert(tonumber(messages[#messages]:match("added as ad (%d+)")))
    command("add Raids on Friday")
    assert(#stored.custom == 2)
    expectLine(messages, "already in the list")
    -- The channel limit counts encoded bytes, including the automatically added tag.
    local prefix = "<Olympus Mytikas> "
    local exact = string.rep("a", 255 - #prefix - #"é") .. "é"
    command("add " .. exact)
    assert(#stored.custom[3] == 255)
    command("add " .. exact .. "a")
    expectLine(messages, "256 bytes")
    assert(#stored.custom == 3)

    command("del " .. (index + 0.5))
    assert(#stored.custom == 3 and stored.custom[2] == "<Olympus Mytikas> Raids on Friday")
    command("del 1")
    expectLine(messages, "only your own ads")
    command("pick " .. index)
    assert(#sends == 2)
    for slot, send in ipairs(sends) do
        assert(send[1] == stored.custom[2] and send[2] == "CHANNEL" and send[4] == slot)
    end
    event("CHAT_MSG_CHANNEL", stored.custom[2])
    timers[1]()
    expectLine(messages, "check that General is on /1")
    event("PLAYER_ENTERING_WORLD")
    assert(#sends == 2, "Events and timers should not send additional posts")

    local function echo(sender, channel)
        event("CHAT_MSG_CHANNEL", stored.custom[2], sender, nil, nil, nil, nil, nil, channel)
    end
    command("pick " .. index)
    echo("Other", 1)
    echo("Beta-Elsewhere", 2)
    echo("Beta-Fixture", 3)
    timers[#timers]()
    assert(messages[#messages - 1]:find("no echo", 1, true))
    echo("Beta-Fixture", 1)
    echo("Beta", 1)
    timers[#timers]()
    assert(messages[#messages - 1]:find("only one echo", 1, true))
    echo("Beta", 2)
    local before = #messages
    timers[#timers]()
    assert(#messages == before)

    local nextEnv, reload = client(player, {recruit = stored})
    reload("OlympusRecruit")
    local nextCommand = nextEnv.SlashCmdList.OLYMPUSRECRUIT
    nextEnv.C_Timer = nil
    nextCommand("pick " .. index) -- Chat posting also works without optional timer diagnostics.
    nextCommand("del " .. index)
    assert(#stored.custom == 2 and stored.custom[1] == "<Olympus Mytikas> Existing ad")
    nextCommand("reset")
    assert(#stored.custom == 0 and stored.chars["Fixture-Beta"].minimapAngle == 200)
    assert(stored.chars["Fixture-Alpha"].minimapAngle == 45)
    assert(stored.chars["Fixture-Alpha"].minimap == true)
end

local function monthly()
    local player = {realm = "Fixture", name = "Officer", rank = "Valar", rankIndex = 1}
    local saved = {}
    local boundary = 1738368000 -- 2025-02-01 00:00 UTC
    local function login(at)
        local env, load, event = client(player, saved)
        env.date, env.os = os.date, false
        env.GetServerTime = function() return at end
        local ns = load("KillOnSight")
        event("ADDON_LOADED", addon)
        event("PLAYER_LOGIN")
        saved.kos = env.KillOnSightDB
        return ns
    end
    local ns = login(boundary - 1)
    assert(ns.BoardMonth(boundary - 1) == "2025-01")
    local credit = {who = "Hunter", target = "Player-1-00000001", amount = 10000, at = boundary - 1}
    assert(ns.ApplyBoardCredit(credit))
    local board = ns.Store().board
    board.month, board.ledger[1].month = "unknown", "unknown"
    board.ledger[1].key = "unknown|hunter|" .. credit.target
    ns = login(boundary)
    assert(ns.Store().board.month == "2025-02" and ns.PastPrize().prize == 7000)
    assert(ns.BoardPaid("Hunter", "Officer"))
    ns = login(boundary)
    assert(ns.Store().board.history[1].paid and ns.Store().bank.paid == 7000)
end
monthly()

local function savedShapes()
    local player = {realm = "Fixture", name = "Beta"}
    for _, old in ipairs({
        "obsolete", {custom = false, chars = "obsolete"},
        {custom = {"<Olympus Mytikas> Kept"}, chars = {["Fixture-Beta"] = 42, ["Fixture-Alpha"] = {minimapAngle = 10}}},
    }) do
        local env, load, event = client(player, {recruit = old})
        load("OlympusRecruit")
        event("ADDON_LOADED", addon)
        local d = env.OlympusRecruitDB
        assert(type(d.custom) == "table" and type(d.chars["Fixture-Beta"]) == "table")
        if d.chars["Fixture-Alpha"] then
            assert(d.custom[1] == "<Olympus Mytikas> Kept" and d.chars["Fixture-Alpha"].minimapAngle == 10)
        end
    end
end

local function framing()
    local env, load = client({name = "Alpha", realm = "Fixture"}, {})
    local ns = load("KillOnSight")
    env.IsInGuild = function() return true end
    for _, size in ipairs({210, 211, 250, 251}) do
        local wire = {}
        env.SendAddonMessage = function(_, part) wire[#wire + 1] = part end
        local payload = string.rep("x", size)
        ns.QueueParts(payload, true)
        for i = 1, 3 do ns.Pump() end
        if size <= 250 then
            assert(#wire == 1 and wire[1] == payload)
        else
            assert(#wire == 2 and wire[1]:match("^C%d+:1:2:") and wire[2]:match("^C%d+:2:2:"))
            assert(wire[1]:match("^C%d+:1:2:(.*)") .. wire[2]:match("^C%d+:2:2:(.*)") == payload)
        end
    end
end
framing()

local function offscreenSync()
    local env, load = client({name = "Alpha", realm = "Fixture", faction = "Alliance", rankIndex = 0}, {})
    local ns = load("KillOnSight")
    local command, entries = env.SlashCmdList.KILLONSIGHT, ns.Store().entries
    -- A guildmate first receives a name-only target, then its real player ID.
    local peerEnv, peerLoad = client({name = "Beta", realm = "Fixture", faction = "Alliance"}, {})
    local peer = peerLoad("KillOnSight")
    peerEnv.IsInGuild = function() return true end
    peerEnv.GetNumGuildMembers = function() return 1 end
    peerEnv.GetGuildRosterInfo = function() return "Alpha", "Valar", 1 end
    local function receive(row) peer.OnAddonMessage("KOS", row, "GUILD", "Alpha") end
    command("add Offscreen 1")
    local loose = entries["n:offscreen"]
    local row = ns.RowFor(loose, true)
    receive(row)
    assert(peer.Entry(loose.guid) and peer.Entry(loose.guid).want == 10000)
    assert(not peer.ApplyBoardCredit({who="Hunter", target=loose.guid, amount=10000, at=1800000000}))
    assert(ns.Remove(loose.guid))
    local removal = "R~n:offscreen~" .. ns.Store().removed["n:offscreen"]
    receive(removal)
    local oldCopy = row:gsub("^(E~[^~]+~)%d+~", "%1" .. tostring(ns.Store().removed["n:offscreen"] + 10) .. "~")
    receive(oldCopy)
    assert(not peer.Entry("n:offscreen"))
    assert(not ns.AddKill("Player-1-ABCDEF11", "Offscreen", "MAGE", "death"))
    command("add Offscreen 1")
    row = ns.RowFor(entries["n:offscreen"], true)
    receive(row)
    receive(removal)
    assert(peer.Entry("n:offscreen"))
    local real = ns.AddKill("Player-1-ABCDEF11", "Offscreen", "MAGE")
    receive(ns.RowFor(real, true))
    receive(row) -- A delayed old digest must not resurrect the loose name.
    assert(peer.Entry(real.guid) and not peer.Entry("n:offscreen"))
    assert(ns.Remove(real.guid))
    receive("R~" .. real.guid .. "~" .. ns.Store().removed[real.guid])
    assert(not peer.Entry(real.guid))
end
offscreenSync()

local function edit()
    return {
        text = "", SetText = function(self,v) self.text=v end,
        GetText = function(self) return self.text end, SetFocus = function() end,
    }
end

local function largeDigest()
    local env, load = client({name = "Alpha", realm = "Fixture"}, {})
    local ns = load("KillOnSight")
    local receiverEnv, receiverLoad = client({name = "Beta", realm = "Fixture"}, {})
    local receiver = receiverLoad("KillOnSight")
    receiverEnv.IsInGuild = function() return true end
    env.IsInGuild = function() return true end
    -- The 1.0.1 receiver expires a set 30 seconds after its first frame.
    local elapsed = 0
    receiverEnv.GetTime = function() return elapsed end
    local bytes, sets = 0, {}
    env.SendAddonMessage = function(prefix, frame, channel)
        local id, count = frame:match("^C(%d+):%d+:(%d+):")
        if id then sets[id] = tonumber(count) end
        elapsed = elapsed + 1.2 -- One pump per SEND_INTERVAL in the game.
        bytes = bytes + #frame
        receiver.OnAddonMessage(prefix, frame, channel, "Alpha")
    end
    for i = 1, 100 do
        local id = ("Player-1-%08X"):format(i)
        ns.Store().entries[id] = {victims = {}, claims = {}, guid = id, stamp = i, name = "Rival" .. i, reason = string.rep("x", 65)}
    end
    assert(ns.SendDigest(true))
    for i = 1, 300 do ns.Pump() end
    assert(bytes > 8400)
    for _, count in pairs(sets) do assert(count <= 40) end
    for id in pairs(ns.Store().entries) do assert(receiver.Entry(id)) end
end
largeDigest()

local function sharedBounty()
    local now = 1800000000
    local env, load = client({name = "Officer", realm = "Fixture", rankIndex = 0}, {})
    local peerEnv, peerLoad, event, messages = client({name = "Member", realm = "Fixture"}, {})
    local ns, peer = load("KillOnSight"), peerLoad("KillOnSight")
    env.GetServerTime = function() return now end
    peerEnv.GetServerTime = env.GetServerTime
    peerEnv.IsInGuild = function() return true end
    peerEnv.GetNumGuildMembers = function() return 1 end
    peerEnv.GetGuildRosterInfo = function() return "Officer", "Valar", 1 end
    local function send(row, name)
        event("CHAT_MSG_ADDON", "KOS", row, "GUILD", name or "Officer")
    end
    local command = peerEnv.SlashCmdList.KILLONSIGHT
    local e = ns.AddKill("Player-1-ABCDEF01", "Rival", "MAGE", "death", nil, nil, 54, "P")
    env.SlashCmdList.KILLONSIGHT("bounty Rival")
    assert(e.funded == 10000 and e.fundedBy == "Officer")
    command("off")
    send(ns.RowFor(e))
    assert(not peer.Enabled() and not peer.Entry(e.guid))
    command("on")
    local before = #messages
    local unpaidRow = ns.RowFor(e)
    send(unpaidRow)
    local shared = assert(peer.Entry(e.guid))
    assert(peer.Enabled() and #messages == before and #peer.chatLog > 0)
    command("chat")
    expectLine(messages, "Rival")
    command("chat clear")
    assert(#peer.chatLog == 0)
    assert(peer.KillerLine(shared) == "level 54, layer P")
    now = now + 3600
    assert(peer.KillerLine(shared) == "level 54")
    assert(not peer.LayerFresh(peer.ParseEntry(ns.RowFor(e))))
    assert(not peer.LayerFresh({klayer = "S", klayerAt = now}))

    -- The previous generation sent 3g in the ask and funded fields.
    local oldRow = "E~Player-1-ABCDEF02~2~30000~30000~1~0~~Prior"
    send(oldRow)
    local old = assert(peer.Entry("Player-1-ABCDEF02"))
    assert(old.want == 10000 and old.funded == 10000)
    -- A pre-1.1 row has no debt metadata. Its original deposit is already in the bank.
    assert(old.paidUp)
    env.IsInGuild = function() return true end
    ns.OnAddonMessage("KOS", peer.RowFor(old, true), "GUILD", "Member")
    assert(ns.Entry(old.guid).paidUp, "Relaying a legacy deposit must not create a debt")
    local oldFields = {}
    for value in (unpaidRow .. "~"):gmatch("([^~]*)~") do oldFields[#oldFields + 1] = value end
    oldFields[3] = tostring(e.stamp + 1)
    send(table.concat(oldFields, "~", 1, 28), "Guildmate")
    assert(not peer.Entry(e.guid).paidUp, "An old peer cannot clear an existing live bounty debt")
    -- Observe the updated row on the manager's client before issuing the clearance.
    ns.OnAddonMessage("KOS", peer.RowFor(peer.Entry(e.guid), true), "GUILD", "Member")
    e = assert(ns.Entry(e.guid))
    env.SlashCmdList.KILLONSIGHT("paidup Officer")
    local cleared = ns.RowFor(e)
    send(cleared, "Guildmate")
    assert(not peer.Entry(e.guid).paidUp)
    send(cleared)
    shared = peer.Entry(e.guid)
    assert(shared.paidUp and shared.clearedBy == "Officer" and shared.clearedAt == now)
    local clearedStamp = shared.stamp
    send(peer.RowFor(shared, true))
    assert(peer.Entry(e.guid).stamp == clearedStamp)
    -- A later digest from a member still running an unpaid copy must preserve the payment.
    local replay = unpaidRow:gsub("^(E~[^~]+~)%d+~", "%1" .. tostring(shared.stamp + 10) .. "~")
    send(replay, "Guildmate")
    assert(peer.Entry(e.guid).paidUp and peer.Entry(e.guid).clearedAt == now)
    assert(ns.ClaimKill(e.guid, "Hunter"))
    assert(not ns.ClaimKill(e.guid, "Hunter"))
    local scope = ns.Store()
    assert(e.paid and #scope.board.ledger == 1)
    assert(scope.bank.pool == 7000 and scope.bank.cut == 3000 and scope.bank.paid == 0)
    assert(not peer.reported)
end
sharedBounty()

local function board()
    local player = {realm = "Fixture", name = "Alpha", faction = "Alliance", rank = "Valar", rankIndex = 1}
    local oldEntry = {kills = 3, funded = 45000, want = 70000, fundedBy = "LegacyPayer", fundedAt = 1799900000}
    local pending = {name = "Pending", job = true, want = 30000, funded = 0}
    local paid = {kills = 4, funded = 50000, want = 90000, paid = true}
    local stored = {welcomeAck = true, share = false, minimap = false, cutPercent = 10, defaultReward = 50000,
        scopes = {Legacy = {entries = {oldEntry, paid, pending}}, Earlier = {entries = 42}}}
    local env, load, event, messages = client(player, {kos = stored})
    local ns = load("KillOnSight")
    event("ADDON_LOADED", addon)
    assert(not ns.reported and stored.v140Migrated and stored.v146Migrated and stored.v147Migrated and stored.v120Migrated)
    assert(stored.defaultReward == 10000 and stored.cutPercent == 30 and stored.minimap == false and stored.share == false)
    assert(oldEntry.want == 10000 and oldEntry.funded == 10000 and oldEntry.paidUp)
    assert(paid.want == 90000 and paid.funded == 50000)
    assert(not pending.job and pending.funded == 0 and pending.want == 10000)
    local command = env.SlashCmdList.KILLONSIGHT
    command("cut 35"); command("refunddays 20"); command("reward 1.2345")
    assert(stored.defaultReward == 12345)
    command("cut 51"); command("refunddays 366"); command("reward 10001")
    assert(stored.cutPercent == 35 and stored.refundDays == 20 and stored.defaultReward == 12345)

    local box = {nameBox=edit(),rewardBox=edit(),reasonBox=edit(),Show=function(self) self.shown=true end,Hide=function(self) self.shown=false end}
    ns.ui.addBox = box
    ns.Toggle = function() end -- The shared-window suite exercises panel rendering.
    ns.ShowAdd()
    assert(box.rewardBox.text == "1.2345", "Opening Add must retain fractional gold in the saved default")
    box.nameBox:SetText("FixtureRival")
    box.rewardBox:SetText("3.0.5")
    ns.AddFromBox()
    assert(box.shown and not ns.Store().entries["n:fixturerival"])
    box.rewardBox:SetText(" 2.0001 ")
    box.reasonBox:SetText("At the bridge")
    ns.AddFromBox()
    local entries = ns.Store().entries
    local target = assert(entries["n:fixturerival"])
    assert(target.want == 20001 and target.funded == 0 and target.reason == "At the bridge" and not box.shown)
    command("add Other 0.0001 At the gate")
    assert(entries["n:other"].want == 1)
    command("add Regular At the crossing")
    assert(entries["n:regular"].want == 12345 and entries["n:regular"].reason == "At the crossing")
    command("add Large 10000")
    assert(entries["n:large"].want == 100000000)
    command("add Excess 10001")
    assert(entries["n:excess"] == nil)
    local balance = 100000
    env.GetGuildBankMoney = function() return balance end
    local regular = entries["n:regular"]
    player.rank, player.rankIndex = "Member", 5
    command("fund Regular")
    assert(regular.want == 10000 and regular.funded == 10000 and regular.fundedBy == "Alpha")
    assert(not regular.paidUp and #ns.Ious() == 1)
    command("bounty Regular")
    balance = balance + 10000
    event("GUILDBANK_UPDATE_MONEY")
    command("deposited")
    assert(#ns.Ious() == 1 and ns.Store().bank.escrowed == 0)
    command("paidup Alpha")
    assert(not regular.paidUp and ns.DebtLedger()[1].status == "owes bank")
    player.rank, player.rankIndex = "Valar", 1
    command("paidup Alpha")
    local ledger = ns.DebtLedger()
    assert(#ns.Ious() == 0 and #ledger == 1 and ledger[1].status == "paid up")
    assert(ledger[1].amount == 10000 and ledger[1].when == 1800000000 and ledger[1].by == "Alpha")
    local auditAfterPayment = #ns.Store().audit
    assert(auditAfterPayment == 1 and regular.paidUp)
    command("paidup Alpha")
    assert(#ns.Store().audit == auditAfterPayment)
    ns.ui.selected = target

    for _, cmd in ipairs({"bounty", "fund", "remove", "where"}) do
        command(cmd .. " NotOnBoard")
        assert(messages[#messages]:find("nobody called", 1, true))
        assert(entries["n:fixturerival"] == target and ns.ui.selected == target)
    end
    command("announce NotOnBoard")
    expectLine(messages, "nothing to announce")
    player.rank, player.rankIndex = "Member", 5
    command("remove FixtureRival")
    assert(entries["n:fixturerival"] == target)
    player.rank, player.rankIndex = "Valar", 1
    command("remove") -- An omitted name deliberately selects the highlighted row.
    assert(entries["n:fixturerival"] == nil and ns.ui.selected == nil)
    assert(ns.Store().removed[target.guid] and #ns.Store().audit == auditAfterPayment + 1)
    env.os, env.date = false, os.date
    command("log")
    assert(messages[#messages]:find(os.date("!%Y-%m-%d %H:%M", 1800000000), 1, true))
    player.faction = "Horde"
    assert(next(ns.Store().entries) == nil)
    player.faction = "Alliance"
    local env2, reload, login = client(player,{kos=stored})
    local reloaded = reload("KillOnSight")
    login("ADDON_LOADED", addon)
    assert(not reloaded.reported and reloaded.Store().entries["n:other"].want == 1)
    assert(reloaded.DebtLedger()[1].status == "paid up" and #reloaded.Ious() == 0)
    assert(stored.cutPercent == 35 and stored.defaultReward == 12345 and stored.refundDays == 20)
    local scope = reloaded.Store()
    scope.bank.pool, scope.bank.paid = 7000, 3500
    scope.board.ledger = {{who = "Alpha", amount = 10000}}
    scope.board.award = {who = "Alpha", amount = 3500}
    env2.SlashCmdList.KILLONSIGHT("reset")
    local _, loadAgain, enter = client(player, {kos = stored})
    local after = loadAgain("KillOnSight")
    enter("ADDON_LOADED", addon)
    local kept = after.Store()
    assert(next(kept.entries) == nil and next(kept.removed) == nil)
    assert(kept.bank.pool == 7000 and kept.bank.paid == 3500)
    assert(kept.board.ledger[1].who == "Alpha" and kept.board.award.amount == 3500)
    assert(#kept.audit == auditAfterPayment + 1)
    env2.SlashCmdList.KILLONSIGHT("share")
    assert(stored.share == true)
end

recruit()
savedShapes()
board()
print("Recruit and KillOnSight gameplay, saved profiles, migrations, input boundaries and reloads passed.")
