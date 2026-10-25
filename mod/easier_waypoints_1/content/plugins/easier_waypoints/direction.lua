-- Geometry and segment calculations have no access to the simulation API.
local M = {}

local function finite(value)
    return type(value) == "number" and value == value and math.abs(value) < math.huge
end

local function xyz(vector)
    if not vector or not finite(vector.x) or not finite(vector.y) or not finite(vector.z) then return nil end
    return {x = vector.x, y = vector.y, z = vector.z}
end

-- Edge IDs are zero-based; the Lua transport-network edge list is one-based.
function M.preview(waypoint, backend)
    local snap = waypoint and waypoint.edgePos
    local id = snap and snap.edgeId
    if not id or not finite(id.entity) or id.entity < 0 or id.entity % 1 ~= 0
        or not finite(id.index) or id.index < 0 or id.index % 1 ~= 0
        or not finite(snap.param) or snap.param < 0 or snap.param > 1 then
        return nil, "unavailable"
    end
    local network = backend.roadNetwork(id.entity)
    local edge = network and network.edges and network.edges[id.index + 1]
    if not edge or not edge.geometry or not backend.isRoadMode(edge.transportModes) then return nil, "unsupported" end
    -- Missing direction data is not evidence that the edge is bidirectional.
    if type(edge.forwardOnly) ~= "boolean" then return nil, "unavailable" end
    local sample = backend.sample(edge.geometry, snap.param)
    local position = sample and xyz(sample[1])
    local tangent = sample and xyz(sample[2])
    if not position or not tangent then return nil, "unavailable" end
    local magnitude = math.sqrt(tangent.x * tangent.x + tangent.y * tangent.y)
    if not finite(magnitude) or magnitude < 0.000001 then return nil, "unavailable" end
    return {
        geometry = edge.geometry,
        position = position,
        tangent = {x = tangent.x / magnitude, y = tangent.y / magnitude, z = tangent.z / magnitude},
        forwardOnly = edge.forwardOnly,
    }
end

-- Each arrow is three small straight segments; height follows the local slope.
function M.arrowSegments(preview)
    local p, t = preview.position, preview.tangent
    local result = {}
    local function point(distance, side)
        return {x = p.x + t.x * distance - t.y * side,
                y = p.y + t.y * distance + t.x * side,
                z = p.z + t.z * distance}
    end
    local function arrow(sign)
        local tail, tip = point(-2 * sign, 0), point(2 * sign, 0)
        result[#result + 1] = {tail, tip}
        result[#result + 1] = {point(0.5 * sign, 1.1), tip}
        result[#result + 1] = {point(0.5 * sign, -1.1), tip}
    end
    arrow(1)
    if not preview.forwardOnly then arrow(-1) end
    return result
end

-- Resolve surrounding station stops, not just adjacent waypoint entries.
-- A nil insertion index means append, matching the native manager.
function M.segment(path, insertion)
    local count = #path
    if count == 0 then return nil end
    if insertion == nil then insertion = count end
    if not finite(insertion) or insertion % 1 ~= 0 or insertion < 0 or insertion > count then return nil end
    local before, after
    for offset = 0, count - 1 do
        local index = ((insertion - 1 - offset) % count) + 1
        if path[index].stop then before = index; break end
    end
    for offset = 1, count do
        local index = ((insertion - 1 + offset) % count) + 1
        if path[index].stop then after = index; break end
    end
    if not before or not after or before == after then return nil end
    return before, after
end

return M
