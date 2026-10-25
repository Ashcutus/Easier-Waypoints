-- Geometry and segment calculations have no access to the simulation API.
-- Runtime Lua must stay compatible with the game's embedded Lua 5.2.
local M = {}

local function finite(value)
    return type(value) == "number" and value == value and math.abs(value) < math.huge
end

local function xyz(vector)
    if not vector or not finite(vector.x) or not finite(vector.y) or not finite(vector.z) then return nil end
    return {x = vector.x, y = vector.y, z = vector.z}
end

local function index0(value)
    return finite(value) and value >= 0 and value % 1 == 0
end

-- Edge IDs are zero-based; the Lua transport-network edge list is one-based.
-- Direction is "forward" (travel follows the tangent), "both" or "unconfirmed".
function M.preview(waypoint, backend)
    local snap = waypoint and waypoint.edgePos
    local id = snap and snap.edgeId
    if not id or not index0(id.entity) or not index0(id.index)
        or not finite(snap.param) or snap.param < 0 or snap.param > 1 then
        return nil, "unavailable"
    end
    local info = backend.edgeInfo(id.entity)
    local edge = info and info.edges and info.edges[id.index + 1]
    if not edge or not edge.geometry then return nil, "unavailable" end
    local carriers = backend.laneCarriers(edge.transportModes)
    if not next(carriers) then return nil, "unsupported" end
    local sample = backend.sample(edge.geometry, snap.param)
    local position = sample and xyz(sample[1])
    local tangent = sample and xyz(sample[2])
    if not position or not tangent then return nil, "unavailable" end
    local magnitude = math.sqrt(tangent.x * tangent.x + tangent.y * tangent.y)
    if not finite(magnitude) or magnitude < 0.000001 then return nil, "unavailable" end
    tangent = {x = tangent.x / magnitude, y = tangent.y / magnitude, z = tangent.z / magnitude}
    return {
        geometry = edge.geometry,
        position = position,
        tangent = tangent,
        carriers = carriers,
        kind = info.kind,
        direction = M.direction(info, id.index + 1, position, tangent, backend),
    }
end

-- Every vehicle lane of a street is one-way in its lane config. A single arrow
-- is only shown when the lanes at this spot agree with the street's own config;
-- otherwise the data is not what we assume and no direction is claimed.
function M.direction(info, laneIndex, position, tangent, backend)
    local edge = info.edges[laneIndex]
    if info.kind ~= "street" then
        return edge.forwardOnly == false and "both" or "unconfirmed"
    end
    if edge.forwardOnly ~= true then return "unconfirmed" end
    local forward, backward = false, false
    for _, config in ipairs(info.laneConfigs or {}) do
        if next(config.carriers) then
            if config.forward then forward = true else backward = true end
        end
    end
    if not forward and not backward then return "unconfirmed" end
    local opposite = 0
    for index, other in ipairs(info.edges) do
        if index ~= laneIndex and other.geometry and next(backend.laneCarriers(other.transportModes)) then
            local param = backend.locate(other.geometry, position)
            local sample = param and backend.sample(other.geometry, param)
            local otherTangent = sample and xyz(sample[2])
            if otherTangent then
                if other.forwardOnly ~= true then return "unconfirmed" end
                if otherTangent.x * tangent.x + otherTangent.y * tangent.y < 0 then opposite = opposite + 1 end
            end
        end
    end
    if forward and backward then return opposite > 0 and "forward" or "unconfirmed" end
    return opposite == 0 and "forward" or "unconfirmed"
end

function M.compatible(lineCarriers, laneCarriers)
    for carrier in pairs(laneCarriers) do
        if lineCarriers[carrier] then return true end
    end
    return false
end

-- Closest lane the line's vehicles can use, measured on the ground plane.
-- Returns {entity, index (zero-based), param} or nil beyond maxDistance.
function M.nearestLane(position, entities, backend, lineCarriers, maxDistance)
    local p = xyz(position)
    if not p then return nil end
    local best, bestDistance
    for _, entity in ipairs(entities) do
        local info = backend.edgeInfo(entity)
        for index, edge in ipairs(info and info.edges or {}) do
            if edge.geometry and M.compatible(lineCarriers, backend.laneCarriers(edge.transportModes)) then
                local param = backend.locate(edge.geometry, p)
                local sample = param and backend.sample(edge.geometry, param)
                local point = sample and xyz(sample[1])
                if point then
                    local distance = math.sqrt((point.x - p.x) ^ 2 + (point.y - p.y) ^ 2)
                    if distance <= maxDistance and (not best or distance < bestDistance) then
                        best, bestDistance = {entity = entity, index = index - 1, param = param}, distance
                    end
                end
            end
        end
    end
    return best
end

local function segments(p, t, sign, result)
    local function point(distance, side)
        return {x = p.x + t.x * distance - t.y * side,
                y = p.y + t.y * distance + t.x * side,
                z = p.z + t.z * distance}
    end
    local tail, tip = point(-2 * sign, 0), point(2 * sign, 0)
    result[#result + 1] = {tail, tip}
    result[#result + 1] = {point(0.5 * sign, 1.1), tip}
    result[#result + 1] = {point(0.5 * sign, -1.1), tip}
end

-- Each arrow is three small straight segments; height follows the local slope.
function M.arrowSegments(preview)
    local result = {}
    if preview.direction == "forward" or preview.direction == "both" then
        segments(preview.position, preview.tangent, 1, result)
    end
    if preview.direction == "both" then
        segments(preview.position, preview.tangent, -1, result)
    end
    return result
end

-- Eight-point heading of a ground-plane direction, assuming +x east and +y north.
function M.compass(tangent)
    local t = xyz(tangent)
    if not t or (t.x == 0 and t.y == 0) then return nil end
    local ax, ay, slope = math.abs(t.x), math.abs(t.y), 0.41421356 -- tan(22.5°)
    local northSouth = t.y >= 0 and "north" or "south"
    local eastWest = t.x >= 0 and "east" or "west"
    if ay <= ax * slope then return eastWest end
    if ax <= ay * slope then return northSouth end
    return northSouth .. "-" .. eastWest
end

function M.validPoint(position)
    return xyz(position) ~= nil
end

-- Ship and aircraft waypoints are points: a flat cross with a short post.
function M.markerSegments(position)
    local p = xyz(position)
    if not p then return {} end
    local function at(dx, dy, dz) return {x = p.x + dx, y = p.y + dy, z = p.z + dz} end
    return {{at(-3, 0, 0), at(3, 0, 0)}, {at(0, -3, 0), at(0, 3, 0)}, {at(0, 0, 0), at(0, 0, 6)}}
end

-- Native addWaypoint inserts after path[mode] when a stretch is selected, but
-- before the last entry when none is (mode nil). -1 means nothing can be added.
function M.waypointAfterIndex(path, mode)
    if mode == nil then return math.max(#path, 1) - 1 end
    if not finite(mode) or mode % 1 ~= 0 or mode < 0 or mode > #path then return nil end
    return mode
end

-- Resolve surrounding station stops, not just adjacent waypoint entries.
function M.segment(path, after)
    local count = #path
    if count == 0 or not finite(after) or after % 1 ~= 0 or after < 0 or after > count then return nil end
    local before, nextStop
    for offset = 0, count - 1 do
        local index = ((after - 1 - offset) % count) + 1
        if path[index].stop then before = index; break end
    end
    for offset = 1, count do
        local index = ((after - 1 + offset) % count) + 1
        if path[index].stop then nextStop = index; break end
    end
    if not before or not nextStop or before == nextStop then return nil end
    return before, nextStop
end

-- Position of a stop among stops only; waypoints are not counted.
function M.stopOrdinal(path, index)
    local ordinal = 0
    for i = 1, index do
        if path[i] and path[i].stop then ordinal = ordinal + 1 end
    end
    return ordinal
end

return M
