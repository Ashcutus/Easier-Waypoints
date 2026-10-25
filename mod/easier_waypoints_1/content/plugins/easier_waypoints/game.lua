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
local TANGENT_STEP = 0.01
local LOCATE_STEPS = 12
local LOCATE_REFINE = 10
local LOCATE_TOLERANCE = 25
local warned = {}

-- The only lane-geometry function the game itself relies on.
local function positionAt(geometry, param)
    return api.engine.util.transport.calcPosition(geometry, param)
end

-- Hover re-renders constantly, so each failure condition is logged only once.
function M.warnOnce(condition, detail)
    local key = condition .. "|" .. (tostring(detail):gsub("%d+", "#"))
    if warned[key] then return end
    warned[key] = true
    if type(log) == "table" and log.warning then
        log.warning("Easier Waypoints: " .. condition .. ": " .. tostring(detail))
    end
end

-- One log line per session saying which optional engine functions this game build has.
function M.reportRuntime()
    local function has(value) return value ~= nil and "yes" or "no" end
    local ok, summary = pcall(function()
        local geometry = api.type.EdgeGeometry or {}
        return "EdgeGeometry.new=" .. has(geometry.new) .. " EdgeGeometry.Straight=" .. has(geometry.Straight)
            .. " EdgeGeometry.Type=" .. has(geometry.Type) .. " EdgeId.new=" .. has(api.type.EdgeId and api.type.EdgeId.new)
            .. " EdgePos.new=" .. has(api.type.EdgePos and api.type.EdgePos.new)
            .. " EdgeRenderable=" .. has(builtin.EdgeRenderable and builtin.type.EdgeRenderable)
            .. " calcPosition=" .. has(api.engine.util.transport.calcPosition)
    end)
    if type(log) == "table" and log.message then
        log.message("Easier Waypoints: runtime API " .. (ok and summary or ("check failed: " .. tostring(summary))))
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
    -- Position and travel tangent; the tangent comes from two nearby samples.
    sample = function(geometry, param)
        local a, b = math.max(0, param - TANGENT_STEP), math.min(1, param + TANGENT_STEP)
        local pa, pb = positionAt(geometry, a), positionAt(geometry, b)
        return {positionAt(geometry, param), {x = pb.x - pa.x, y = pb.y - pa.y, z = pb.z - pa.z}}
    end,
    -- Nearest point on a lane on the ground plane: a coarse scan, then refinement.
    locate = function(geometry, position)
        local function distance(param)
            local p = positionAt(geometry, param)
            return (p.x - position.x) ^ 2 + (p.y - position.y) ^ 2
        end
        local best, bestDistance = 0, math.huge
        for i = 0, LOCATE_STEPS do
            local d = distance(i / LOCATE_STEPS)
            if d < bestDistance then best, bestDistance = i / LOCATE_STEPS, d end
        end
        local low, high = math.max(0, best - 1 / LOCATE_STEPS), math.min(1, best + 1 / LOCATE_STEPS)
        for _ = 1, LOCATE_REFINE do
            local a, b = low + (high - low) / 3, high - (high - low) / 3
            if distance(a) < distance(b) then high = b else low = a end
        end
        best = (low + high) / 2
        if distance(best) > LOCATE_TOLERANCE ^ 2 then return nil end
        return best
    end,
    -- Ground point under the cursor; on bridges this lies below the deck.
    cursorPosition = function()
        if not api.gui.mouse.hasTerrainPosition() then return nil end
        return api.gui.mouse.getTerrainPosition()
    end,
    -- Street and track edges near a point.
    edgesNear = function(position, radius)
        return api.engine.util.octree.findEntitiesInCircle(api.type.Vec2f.new(position.x, position.y), radius,
            api.type.ComponentType.BASE_EDGE) or {}
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
-- Returns the node and whether the arrows could be built. Without arrows a
-- confirmed lane fades from dim to bright in the direction of travel instead.
function M.laneOverlay(preview, valid)
    local color = laneColor(valid)
    local highlight = renderable(preview.geometry, 1.2, color)
    local arrowsBuilt, arrows = pcall(function()
        local white = api.type.Vec4f.new(1, 1, 1, 1)
        local result = {}
        for _, segment in ipairs(direction.arrowSegments(preview)) do
            result[#result + 1] = renderable(straightGeometry(segment[1], segment[2]), 0.3, white)
        end
        return result
    end)
    local edges = {highlight}
    if arrowsBuilt then
        for _, edge in ipairs(arrows) do edges[#edges + 1] = edge end
    else
        M.warnOnce("direction arrows unavailable", arrows)
        if preview.direction == "forward" then
            highlight.colors = {api.type.Vec4f.new(color.x, color.y, color.z, 0.15), color}
        end
    end
    return builtin.EdgeRenderable {edges = edges, ignoreDepth = false}, arrowsBuilt
end

-- Tooltip detail for a drawn lane, or nil when the arrow speaks for itself.
function M.laneDetail(preview, arrowsBuilt)
    if preview.direction == "forward" then
        if arrowsBuilt then return nil end
        return _("The highlight gets brighter in the direction of travel.")
    end
    return M.directionText(preview)
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

-- Plain text only: display names must never be parsed as markup.
function M.tooltipText(text)
    return builtin.TextView {meta = {class = TOOLTIP_CLASS}, text = text}
end

local HEADINGS = {
    north = function() return _("north") end, ["north-east"] = function() return _("north-east") end,
    east = function() return _("east") end, ["south-east"] = function() return _("south-east") end,
    south = function() return _("south") end, ["south-west"] = function() return _("south-west") end,
    west = function() return _("west") end, ["north-west"] = function() return _("north-west") end,
}
local LABEL_CACHE_LIMIT = 512
local labelDirections, labelDirectionCount = {}, 0

-- Copy the native revision numbers: engine-owned revision objects may change in
-- place. Without a readable revision, recompute rather than retain a heading.
local function labelRevision(entity)
    if not api.engine.getRevision then return nil end
    local ok, revision = pcall(function()
        local numbers = api.engine.getRevision(entity).num
        if type(numbers[1]) ~= "number" or type(numbers[2]) ~= "number" or type(numbers[3]) ~= "number" then return nil end
        return tostring(numbers[1]) .. ":" .. tostring(numbers[2]) .. ":" .. tostring(numbers[3])
    end)
    return ok and revision or nil
end

-- Stop-list text for a waypoint row, e.g. "Waypoint - Ring Road - heading north-east".
function M.waypointLabel(waypoint, carriers)
    if waypoint.pos then
        if carriers.AIR then return _("Waypoint - in the air") end
        if carriers.WATER then return _("Waypoint - at sea") end
        return _("Waypoint")
    end
    local snap = waypoint.edgePos
    local entity = snap and snap.edgeId and snap.edgeId.entity
    if not entity or not api.engine.entityExists(entity) then return _("Waypoint") end
    local key = tostring(entity) .. ":" .. tostring(snap.edgeId.index) .. ":" .. string.format("%.17g", snap.param)
    local revision = labelRevision(entity)
    local cached = revision and labelDirections[key]
    local heading, both
    if cached and cached.revision == revision then
        heading, both = cached.heading, cached.both
    else
        local ok, preview = pcall(direction.preview, {edgePos = snap}, M.backend)
        heading = ok and preview and preview.direction == "forward" and direction.compass(preview.tangent)
        both = ok and preview and preview.direction == "both"
        -- Unavailable or unconfirmed data may be temporary; retry it next time.
        if revision and (heading or both) then
            if labelDirectionCount >= LABEL_CACHE_LIMIT then labelDirections, labelDirectionCount = {}, 0 end
            if not labelDirections[key] then labelDirectionCount = labelDirectionCount + 1 end
            labelDirections[key] = {revision = revision, heading = heading, both = both}
        elseif labelDirections[key] then
            labelDirections[key] = nil
            labelDirectionCount = labelDirectionCount - 1
        end
    end
    -- Names and translated text stay live even while the geometry is unchanged.
    local road = api.engine.util.getEntityName(entity)
    if type(road) ~= "string" or road == "" then road = nil end
    local label
    if heading then
        local values = {road = road, heading = HEADINGS[heading]()}
        label = road and langUtil.format(_("Waypoint - {road} - heading {heading}"), values)
            or langUtil.format(_("Waypoint - heading {heading}"), values)
    elseif both then
        label = road and langUtil.format(_("Waypoint - {road} - either direction"), {road = road})
            or _("Waypoint - either direction")
    else
        label = road and langUtil.format(_("Waypoint - {road}"), {road = road}) or _("Waypoint")
    end
    return label
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
