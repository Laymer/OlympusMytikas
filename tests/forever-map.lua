-- Load the bundled library as Forever would, with only the world-map root exposed.
local lib, root = {}, nil
local stub = setmetatable({NewLibrary = function() return lib end}, {
    __call = function() return {New = function() return {} end} end,
})
local env = setmetatable({
    WOW_PROJECT_ID = 99, WOW_PROJECT_CAMELOT = 99, LibStub = stub,
    CreateFrame = function() return {UnregisterAllEvents = function() end, RegisterEvent = function() end, SetScript = function() end} end,
    CreateVector2D = function() return {} end, IsLoggedIn = function() return false end,
    C_Map = {
        GetMapInfo = function() end,
        GetMapChildrenInfo = function(id) root = id end,
    },
}, {__index = _G})
setfenv(assert(loadfile("OlympusMytikas/libs/HereBeDragons-2.0.lua")), env)()
assert(root == 947)
local x, y = lib:GetWorldCoordinatesFromAzerothWorldMap(0.5, 0.5, 0)
assert(math.abs(x - 10256.765) < 0.001 and math.abs(y + 5002.63) < 0.001)
x, y = lib:GetWorldCoordinatesFromAzerothWorldMap(0, 0, 1)
assert(x == 8723.96 and y == 14824.53)
