-- Read-only game adapter shared by the tooltips, the stop panel and the
-- placement tool. Nothing here issues simulation commands.
local builtin = ug_require "::/gui/main/builtin.lua"
local langUtil = ug_require "::/scripts/lang_util.tl"
local direction = ug_require "easier_waypoints::/plugins/easier_waypoints/direction.lua"

local M = {}

local CARRIER_MODES = {
    ROAD = {"CAR", "BUS", "TRUCK"},
    TRAM = {"TRAM", "ELECTRIC_TRAM", "TRAM_TRACK", "ELECTRIC_TRAM_TRACK"},
    RAIL = {"TRAIN", "ELECTRIC_TRAIN"},
}
local LINE_CARRIERS = {"ROAD", "TRAM", "RAIL", "WATER", "AIR"}
local TOOLTIP_CLASS = "lvm-selector-tooltip, font-scale-tooltip, default-tooltip-configuration"
local warned = {}

-- Hover re-renders constantly, so each failure condition is logged only once.
function M.warnOnce(condition, detail)
    local key = condition .. "|" .. (tostring(detail):gsub("%d+", "#"))
    if warned[key] then return end
    warned[key] = true
    if type(log) == "table" and log.warning then
        log.warning("Easier Waypoints: " .. condition .. ": " .. tostring(detail))
    end
end

function M.laneCarriers(modes)
    local result = {}
    if not modes then return result end
    local tm = api.type["enum"].TransportMode
    for carrier, names in pairs(CARRIER_MODES) do
        for _, name in ipairs(names) do
            if modes[tm[name]] then result[carrier] = true end
        end
    end
    return result
end

function M.lineCarriers(carriers)
    local result = {}
    local enum = api.type["enum"].Carrier
    for _, name in ipairs(LINE_CARRIERS) do
        if carriers and carriers[enum[name]] then result[name] = true end
    end
    return result
end

M.backend = {
    -- Streets carry their own lane config; tracks and junction lanes do not.
    edgeInfo = function(entity)
        if not api.engine.entityExists(entity) then return nil end
        local ct = api.type.ComponentType
        local network = api.engine.getComponent(entity, ct.TRANSPORT_NETWORK)
        if not network then return nil end
        local base = api.engine.getComponent(entity, ct.BASE_EDGE)
        local kind = "other"
        if base then
            kind = api.engine.getComponent(entity, ct.BASE_EDGE_STREET) and "street" or "track"
        elseif api.engine.getComponent(entity, ct.BASE_NODE) then
            kind = "junction"
        end
        local configs = {}
        for _, config in ipairs(base and base.laneConfigs or {}) do
            configs[#configs + 1] = {forward = config.forward, carriers = M.laneCarriers(config.transportModes)}
        end
        return {edges = network.edges, kind = kind, laneConfigs = configs}
    end,
    laneCarriers = M.laneCarriers,
    sample = function(geometry, param)
        return api.type.EdgeGeometry.calcPos(geometry, param)
    end,
    -- Nearest point on another lane of the same road, if one runs alongside.
    locate = function(geometry, position)
        local result = api.type.EdgeGeometry.locate(geometry, api.type.Vec3f.new(position.x, position.y, position.z), 16, 25)
        if not result or not result[2] or type(result[1]) ~= "number" then return nil end
        return math.min(1, math.max(0, result[1]))
    end,
}

local function straightGeometry(a, b)
    local geometry = api.type.EdgeGeometry.new()
    geometry.type = api.type.EdgeGeometry.Type.STRAIGHT
    local straight = api.type.EdgeGeometry.Straight.new()
    straight.pos = {api.type.Vec2f.new(a.x, a.y), api.type.Vec2f.new(b.x, b.y)}
    geometry.straight = straight
    geometry.height = api.type.Vec2f.new(a.z, b.z)
    geometry.tangent = api.type.Vec2f.new(b.z - a.z, b.z - a.z)
    geometry.length = math.sqrt((b.x - a.x)^2 + (b.y - a.y)^2 + (b.z - a.z)^2)
    geometry.width = 0.25
    return geometry
end

local function renderable(geometry, width, color)
    local edge = builtin.type.EdgeRenderable.Edge.new(geometry)
    edge.width = width
    edge.offsetZ = 0.15
    edge.stepSize = 0.5
    edge.colors = {color, color}
    return edge
end

local function laneColor(valid)
    if valid then return api.type.Vec4f.new(0.1, 0.85, 1, 0.65) end
    return api.type.Vec4f.new(1, 0.3, 0.25, 0.7)
end

-- Depth testing stays enabled, so overlays do not paint through bridges.
function M.laneOverlay(preview, valid)
    local white = api.type.Vec4f.new(1, 1, 1, 1)
    local edges = {renderable(preview.geometry, 1.2, laneColor(valid))}
    for _, segment in ipairs(direction.arrowSegments(preview)) do
        edges[#edges + 1] = renderable(straightGeometry(segment[1], segment[2]), 0.3, white)
    end
    return builtin.EdgeRenderable {edges = edges, ignoreDepth = false}
end

function M.pointOverlay(position, valid)
    local edges = {}
    for _, segment in ipairs(direction.markerSegments(position)) do
        edges[#edges + 1] = renderable(straightGeometry(segment[1], segment[2]), 0.5, laneColor(valid))
    end
    if #edges == 0 then return nil end
    return builtin.EdgeRenderable {edges = edges, ignoreDepth = false}
end

function M.directionText(preview)
    if preview.direction == "forward" then
        return _("The arrow shows the direction of travel on the highlighted lane.")
    elseif preview.direction == "both" then
        if preview.kind == "track" then
            return _("Trains can use this track in either direction; the route decides which way.")
        end
        return _("Vehicles can use the highlighted lane in either direction.")
    end
    return _("The direction of travel couldn't be confirmed for this lane, so no arrow is shown.")
end

-- Shown instead of the direction text whenever the overlay could not be built.
function M.previewUnavailableText(point, clickStillWorks)
    if point then
        if clickStillWorks then
            return _("Preview unavailable: the marker couldn't be drawn. Clicking still uses the point under the cursor.")
        end
        return _("Preview unavailable: the marker couldn't be drawn.")
    end
    if clickStillWorks then
        return _("Preview unavailable: the lane highlight couldn't be drawn. Clicking still uses the lane under the cursor.")
    end
    return _("Preview unavailable: the lane highlight couldn't be drawn.")
end

-- Display names are plain text: only fixed strings may use inline key hints.
function M.tooltipText(text, hints)
    return builtin.TextView {meta = {class = TOOLTIP_CLASS}, text = text, inlineHintSupport = hints == true}
end

function M.stopName(path, index)
    local entity = path[index] and path[index].stop and path[index].stop.stationGroup
    if entity and api.engine.entityExists(entity) then
        local name = api.engine.util.getEntityName(entity)
        if type(name) == "string" and name ~= "" then return name end
    end
    return langUtil.format(_("Stop {number}"), {number = tostring(direction.stopOrdinal(path, index))})
end

-- Where native addWaypoint will put the next waypoint for this mode value.
function M.stretch(line, mode)
    if not line or not line.path then return nil end
    local after = direction.waypointAfterIndex(line.path, mode)
    if not after then return nil end
    local before, nextStop = direction.segment(line.path, after)
    if not before then return nil end
    return after, before, nextStop
end

function M.stretchText(line, mode, message)
    local after, before, nextStop = M.stretch(line, mode)
    if not after then return nil end
    return langUtil.format(message, {from = M.stopName(line.path, before), to = M.stopName(line.path, nextStop)})
end

return M
