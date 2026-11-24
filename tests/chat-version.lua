-- Exercise the shared shell through the game chat, slash-command and event APIs.
local LINE = "|cffbe5720[KoS]|r "
local function loadShell(settings)
    local env = setmetatable({ SlashCmdList = {}, OlympusMytikasDB = settings or {} }, { __index = _G })
    env._G = env
    local state = { clock = 0, timers = {}, printed = {}, visible = {}, sent = {} }
    local function capture(list, ...)
        list[#list + 1] = { n = select("#", ...), ... }
        return "forwarded"
    end
    env.issecretvalue = function(value) return rawequal(value, state.secret) end
    state.secret = setmetatable({}, { __tostring = function() error("secret was inspected") end })
    env.print = function(...) return capture(state.printed, ...) end
    env.DEFAULT_CHAT_FRAME = { AddMessage = function(self, ...)
        assert(self == env.DEFAULT_CHAT_FRAME)
        return capture(state.visible, ...)
    end }
    env.GetTime = function() return state.clock end
    env.C_AddOns = { GetAddOnMetadata = function() return "" end }
    env.GetAddOnMetadata = function() return "1.2.3" end
    env.IsInGuild = function() return true end
    env.IsInGroup = function() return true end
    env.C_Timer = { After = function(delay, callback)
        state.timers[#state.timers + 1] = { when = state.clock + delay, run = callback }
    end }
    env.C_ChatInfo = {
        RegisterAddonMessagePrefix = function(prefix) assert(prefix == "OMVER") end,
        SendAddonMessage = function(...) capture(state.sent, ...) end
    }
    env.CreateFrame = function()
        return {
            RegisterEvent = function() end,
            SetScript = function(_, name, handler) assert(name == "OnEvent"); state.event = handler end
        }
    end
    function state.advance(to)
        repeat
            local nextIndex
            for i, timer in ipairs(state.timers) do
                if timer.when <= to and (not nextIndex or timer.when < state.timers[nextIndex].when) then
                    nextIndex = i
                end
            end
            if not nextIndex then break end
            local timer = table.remove(state.timers, nextIndex)
            state.clock = timer.when
            timer.run()
        until false
        state.clock = to
    end
    setfenv(assert(loadfile("OlympusMytikas/OlympusMytikas.lua")), env)("OlympusMytikas")
    return env, state
end

local env, state = loadShell()
local hidden = env.OlympusMytikasChat.hidden
local initial = #hidden
assert(initial == 1 and #state.visible == 0, "Automatic load message stays quiet")
env.print("Bones:", 42)
env.DEFAULT_CHAT_FRAME:AddMessage(LINE .. "hello")
assert(#hidden == initial + 2 and hidden[#hidden - 1] == "Bones: 42")
local tricky = setmetatable({}, { __tostring = function() error("unexpected tostring") end })
assert(env.print("another addon:", tricky, nil) == "forwarded")
assert(state.printed[1].n == 3 and state.printed[1][2] == tricky)
assert(env.print("Bones:", state.secret) == "forwarded" and state.printed[2][2] == state.secret)
assert(env.print(state.secret) == "forwarded")
assert(env.DEFAULT_CHAT_FRAME:AddMessage(state.secret, 0.5) == "forwarded")
assert(env.DEFAULT_CHAT_FRAME:AddMessage(tricky, 0.2) == "forwarded")
assert(state.visible[2][1] == tricky and state.visible[2][2] == 0.2)
assert(env.DEFAULT_CHAT_FRAME:AddMessage("Bones: private context", state.secret) == "forwarded")
assert(state.visible[3][2] == state.secret)
env.SLASH_KILLONSIGHT1 = "/kos"
env.SlashCmdList.KILLONSIGHT = function(fail)
    if fail then error("command failed") end
    env.DEFAULT_CHAT_FRAME:AddMessage(LINE .. "command reply")
    return 1, nil, 3
end
env.OlympusMytikasChat.wrap()
local one, two, three = env.SlashCmdList.KILLONSIGHT()
assert(one == 1 and two == nil and three == 3 and #hidden == initial + 2)
assert(not pcall(env.SlashCmdList.KILLONSIGHT, true))
for i = 1, 55 do env.print("Bones:", i) end
assert(#hidden == 50 and hidden[1] == "Bones: 6")
env.SlashCmdList.OLYMPUSMYTIKAS("hidden")
assert(#hidden == 50 and state.visible[#state.visible][1]:find("Bones: 55", 1, true))

local function receive(payload, dist)
    state.event(nil, "CHAT_MSG_ADDON", "OMVER", payload, dist, "Guildmate")
end
state.event(nil, "PLAYER_LOGIN")
state.advance(15)
assert(#state.sent == 2 and state.sent[1][2] == "Q\t1.2.3")
assert(state.sent[1][3] == "GUILD" and state.sent[2][3] == "PARTY")
local before = #state.visible
for _, dist in ipairs({ "WHISPER", "CHANNEL", "INSTANCE_CHAT" }) do
    receive("V\t22.0.0", dist)
    receive("Q\t0.1.0", dist)
end
receive("V\t99.0.0|Htext", "GUILD")
receive("Q\t1..1", "GUILD")
receive(state.secret, "GUILD")
state.advance(25)
assert(#state.visible == before and #state.sent == 2)
receive("V\t1.2.3", "GUILD")
receive("Q\t1.2.2", "PARTY")
receive("Q\t1.2.2", "PARTY")
state.advance(32)
assert(#state.sent == 3 and state.sent[3][2] == "V\t1.2.3" and state.sent[3][3] == "PARTY")
receive("V\t1.2.12", "GUILD")
receive("V\t1.2.12", "PARTY")
assert(#state.visible == before + 1 and state.visible[#state.visible][1]:find("1.2.12", 1, true))
state.advance(200)
receive("V\t1.3.0", "RAID")
assert(env.OlympusMytikasDB.pendingNewVersion == "1.3.0" and #state.visible == before + 1)
local reloaded, nextState = loadShell(env.OlympusMytikasDB)
nextState.event(nil, "PLAYER_LOGIN")
nextState.advance(8)
assert(#nextState.visible == 1 and nextState.visible[1][1]:find("1.3.0", 1, true))
assert(reloaded.OlympusMytikasDB.pendingNewVersion == nil)
reloaded.SlashCmdList.OLYMPUSMYTIKAS("version off")
nextState.event(nil, "CHAT_MSG_ADDON", "OMVER", "V\t2.0.0", "GUILD", "Guildmate")
assert(#nextState.visible == 2 and nextState.visible[2][1]:find("OFF", 1, true))
print("Shared shell chat forwarding, hidden history and version notices passed.")
