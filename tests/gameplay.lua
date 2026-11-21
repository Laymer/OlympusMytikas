-- Lua 5.1 client fixtures. Only registered events, slash commands and the add
-- dialog's bound callback drive changes to the actual modules' SavedVariables.
local addon = "OlympusMytikas"

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

local function expectLine(messages, pattern)
    local last = messages[#messages] or ""
    assert(last:find(pattern, 1, true), "expected '" .. pattern .. "', got '" .. last .. "'")
end

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

local function edit()
    return {
        text = "", SetText = function(self,v) self.text=v end,
        GetText = function(self) return self.text end, SetFocus = function() end,
    }
end

local function board()
    local player = {realm = "Fixture", name = "Alpha", faction = "Alliance", rank = "Valar", rankIndex = 1}
    local oldEntry = {kills = 3, funded = 45000, want = 70000}
    local paid = {kills = 4, funded = 50000, want = 90000, paid = true}
    local stored = {welcomeAck = true, share = false, minimap = false, cutPercent = 10, defaultReward = 50000,
        scopes = {Legacy = {entries = {oldEntry, paid}}, Earlier = {entries = 42}}}
    local env, load, event, messages = client(player, {kos = stored})
    local ns = load("KillOnSight")
    event("ADDON_LOADED", addon)
    assert(not ns.reported and stored.v140Migrated and stored.v146Migrated and stored.v147Migrated)
    assert(stored.defaultReward == 30000 and stored.cutPercent == 30 and stored.minimap == false and stored.share == false)
    assert(oldEntry.want == 45000 and paid.want == 90000)
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
    -- A player arms a separate board entry, then the client reports two bank updates.
    local balance = 100000
    env.GetGuildBankMoney = function() return balance end
    command("fund Regular")
    assert(entries["n:regular"].job and entries["n:regular"].funded == 0)
    balance = balance + 10000
    event("GUILDBANK_UPDATE_MONEY")
    assert(entries["n:regular"].funded == 0 and ns.Store().bank.escrowed == 0)
    balance = balance + 2500
    event("GUILDBANK_UPDATE_MONEY")
    assert(entries["n:regular"].funded == 12345 and ns.Store().bank.escrowed == 12500 and ns.Store().bank.float == 155)
    event("GUILDBANK_UPDATE_MONEY")
    assert(ns.Store().bank.escrowed == 12500 and not ns.reported)
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
    assert(ns.Store().removed[target.guid] and #ns.Store().audit == 1)
    player.faction = "Horde"
    assert(next(ns.Store().entries) == nil)
    player.faction = "Alliance"
    local env2, reload, login = client(player,{kos=stored})
    local reloaded = reload("KillOnSight")
    login("ADDON_LOADED", addon)
    assert(not reloaded.reported and reloaded.Store().entries["n:other"].want == 1)
    assert(stored.cutPercent == 35 and stored.defaultReward == 12345 and stored.refundDays == 20)
    env2.SlashCmdList.KILLONSIGHT("share")
    assert(stored.share == true)
end

recruit()
savedShapes()
board()
print("Recruit and KillOnSight gameplay, saved profiles, migrations, input boundaries and reloads passed.")
