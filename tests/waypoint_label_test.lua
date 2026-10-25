-- Labels stay current while unchanged lane geometry avoids repeated work.
-- Engine revisions and lane reads are doubles; no game installation is needed.
local root = "mod/easier_waypoints_1/content/plugins/easier_waypoints/"
local name, heading, directionKind = "Ring Road", "north", "forward"
local revision = {num = {1, 1, 1}}
local failPreview, calls = false, 0
local direction = {
    preview = function()
        calls = calls + 1
        if failPreview then error("temporary lane read failure") end
        return {direction = directionKind, tangent = {heading = heading}}
    end,
    compass = function(tangent) return tangent.heading end,
}
local api = {engine = {
    entityExists = function() return true end,
    getRevision = function() return revision end,
    util = {getEntityName = function() return name end},
}}
local translated = false
local env = setmetatable({api = api, _ = function(text)
    return translated and ("translated " .. text) or text
end, ug_require = function(path)
    if path:match("/builtin.lua$") then return {} end
    if path:match("/lang_util.tl$") then return {format = function(text, values)
        return (text:gsub("{(.-)}", function(key) return values[key] end))
    end} end
    if path:match("/direction.lua$") then return direction end
    error("Unexpected import " .. path)
end}, {__index = _G})
local game = assert(loadfile(root .. "game.lua", "t", env))()
local waypoint = {edgePos = {edgeId = {entity = 1, index = 0}, param = 0.5}}
assert(game.waypointLabel(waypoint, {}) == "Waypoint - Ring Road - heading north" and calls == 1)
assert(game.waypointLabel(waypoint, {}) == "Waypoint - Ring Road - heading north" and calls == 1,
    "An unchanged revision reuses geometry")
name = "Renamed Road"
assert(game.waypointLabel(waypoint, {}) == "Waypoint - Renamed Road - heading north" and calls == 1,
    "Road names update even before a revision changes")
heading = "south"
revision.num[2] = 2 -- mutate the same engine-owned revision object
assert(game.waypointLabel(waypoint, {}) == "Waypoint - Renamed Road - heading south" and calls == 2,
    "A lane revision invalidates the old heading")
translated = true
assert(game.waypointLabel(waypoint, {}) == "translated Waypoint - Renamed Road - heading translated south" and calls == 2,
    "Translated text is never cached")
translated = false
directionKind = "unconfirmed"
revision.num[2] = 3
assert(game.waypointLabel(waypoint, {}) == "Waypoint - Renamed Road" and calls == 3)
directionKind = "forward"
assert(game.waypointLabel(waypoint, {}) == "Waypoint - Renamed Road - heading south" and calls == 4,
    "Unconfirmed previews retry without waiting for a revision")
waypoint.edgePos.param = 0.6
failPreview = true
assert(game.waypointLabel(waypoint, {}) == "Waypoint - Renamed Road" and calls == 5)
failPreview = false
heading = "north"
assert(game.waypointLabel(waypoint, {}) == "Waypoint - Renamed Road - heading north" and calls == 6,
    "A failed preview is retried")
api.engine.getRevision = function() error("revision temporarily unreadable") end
heading = "south"
assert(game.waypointLabel(waypoint, {}) == "Waypoint - Renamed Road - heading south" and calls == 7,
    "An unreadable revision bypasses the cache")
api.engine.getRevision = function() return revision end
heading = "west"
assert(game.waypointLabel(waypoint, {}) == "Waypoint - Renamed Road - heading west" and calls == 8)
api.engine.getRevision = nil
heading = "east"
assert(game.waypointLabel(waypoint, {}) == "Waypoint - Renamed Road - heading east" and calls == 9,
    "A missing revision API recomputes safely")
print("PASS: label cache refreshes names, revisions, translations, unknown data and temporary errors")
