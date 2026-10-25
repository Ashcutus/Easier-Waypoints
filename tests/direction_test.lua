local model = dofile("mod/easier_waypoints_1/content/plugins/easier_waypoints/direction.lua")
local checks = 0
local function check(condition, message) checks = checks + 1; assert(condition, message) end

-- Lanes run along y at x = offset; dy is the geometry direction (+1 or -1).
local function lane(offset, dy, modes, forwardOnly)
    return {geometry = {x = offset, dy = dy}, transportModes = modes, forwardOnly = forwardOnly}
end
local car, walk, train = {car = true}, {person = true}, {train = true}
local seenEntity, seenParam
local info
local backend = {
    edgeInfo = function(entity) seenEntity = entity; return info end,
    laneCarriers = function(modes)
        if modes.car then return {ROAD = true} end
        if modes.train then return {RAIL = true} end
        return {}
    end,
    sample = function(geometry, param)
        seenParam = param
        return {{x = geometry.x, y = 200, z = geometry.z or 12}, {x = 0, y = 2 * geometry.dy, z = geometry.dy}}
    end,
    locate = function(geometry, position) return math.abs(geometry.x - position.x) < 25 and 0.5 or nil end,
}
local function street(edges, configs) return {kind = "street", edges = edges, laneConfigs = configs} end
local twoWay = {{forward = false, carriers = {ROAD = true}}, {forward = true, carriers = {ROAD = true}},
    {forward = true, carriers = {}}}
local oneWay = {{forward = true, carriers = {ROAD = true}}, {forward = true, carriers = {ROAD = true}}}

info = street({lane(-2, -1, car, true), lane(2, 1, car, true), lane(6, 1, walk, false)}, twoWay)
local waypoint = {edgePos = {edgeId = {entity = 42, index = 1}, param = 0.75}}
local preview = assert(model.preview(waypoint, backend))
check(seenEntity == 42 and seenParam ~= nil, "Use the actual snap, including zero-based edge indices")
check(preview.direction == "forward", "Two-way street with opposing lanes confirms the direction")
check(preview.position.z == 12 and preview.tangent.y == 1, "Preserve elevation and normalize XY tangent")
check(preview.carriers.ROAD and preview.kind == "street", "Report lane carriers and edge kind")
check(waypoint.edgePos.edgeId.index == 1, "Do not mutate candidate data")
local arrows = model.arrowSegments(preview)
check(#arrows == 3, "Confirmed direction gets one arrow")
check(arrows[1][2].y > arrows[1][1].y, "Arrow follows lane geometry, not screen axes")
check(arrows[1][2].z > arrows[1][1].z, "Arrow follows slope on a raised road")
waypoint.edgePos.edgeId.index = 0
preview = assert(model.preview(waypoint, backend))
check(preview.direction == "forward" and model.arrowSegments(preview)[1][2].y < model.arrowSegments(preview)[1][1].y,
    "The other side of a two-way road points the other way")

info = street({lane(-2, 1, car, true), lane(2, 1, car, true)}, twoWay)
check(assert(model.preview(waypoint, backend)).direction == "unconfirmed",
    "Two-way config but same-direction lanes: never claim a direction")
check(#model.arrowSegments(model.preview(waypoint, backend)) == 0, "Unconfirmed direction gets no arrow")
info = street({lane(-2, 1, car, true), lane(2, 1, car, true)}, oneWay)
check(model.preview(waypoint, backend).direction == "forward", "One-way street lanes all agree")
info = street({lane(-2, 1, car, true), lane(2, -1, car, true)}, oneWay)
check(model.preview(waypoint, backend).direction == "unconfirmed", "One-way config with an opposing lane is inconsistent")
info = street({lane(-2, 1, car, nil), lane(2, -1, car, true)}, twoWay)
check(model.preview(waypoint, backend).direction == "unconfirmed", "Missing direction is unknown, not bidirectional")
info = street({lane(-2, 1, car, true), lane(2, -1, car, false)}, twoWay)
check(model.preview(waypoint, backend).direction == "unconfirmed", "A two-way vehicle lane on a street is unexpected")
info = street({lane(-2, 1, car, true), lane(80, -1, car, true)}, twoWay)
check(model.preview(waypoint, backend).direction == "unconfirmed", "Distant lanes are not evidence")
info = street({lane(-2, 1, car, true), lane(2, -1, car, true)}, {})
check(model.preview(waypoint, backend).direction == "unconfirmed", "No lane config, no claim")

info = {kind = "track", edges = {lane(0, 1, train, false)}}
preview = assert(model.preview(waypoint, backend))
check(preview.direction == "both" and preview.carriers.RAIL, "Tracks are usable in either direction")
check(#model.arrowSegments(preview) == 6 and model.arrowSegments(preview)[4][2].y < model.arrowSegments(preview)[4][1].y,
    "Bidirectional lanes get opposing arrows")
info.edges[1].forwardOnly = true
check(model.preview(waypoint, backend).direction == "unconfirmed", "A one-way track cannot be cross-checked")

info = street({lane(6, 1, walk, false)}, twoWay)
check(model.preview(waypoint, backend) == nil, "Footpaths are not vehicle lanes")
info = street({lane(-2, 1, car, true)}, oneWay)
for _, value in ipairs({-1, 0.5, 1, math.huge, 0/0}) do
    waypoint.edgePos.edgeId.index = value
    check(model.preview(waypoint, backend) == nil, "Invalid/missing edge index must not select another lane")
end
waypoint.edgePos.edgeId.index = 0
for _, value in ipairs({-0.1, 1.1, math.huge, 0/0}) do
    waypoint.edgePos.param = value
    check(model.preview(waypoint, backend) == nil, "Reject invalid snap parameter")
end
waypoint.edgePos.param = 0.5
info = nil
check(model.preview(waypoint, backend) == nil, "Deleted edge retains native behavior")
check(model.preview({pos = {x = 1, y = 2, z = 3}}, backend) == nil, "Ship/aircraft waypoint is not a lane")

-- Route clicks: refuse ambiguous roads, sides and terrain/deck mismatches.
local networks = {
    [7] = street({lane(-2, -1, car, true), lane(2, 1, car, true), lane(6, 1, walk, false)}, twoWay),
    [8] = {kind = "track", edges = {lane(3, 1, train, false)}},
}
backend.edgeInfo = function(entity) return networks[entity] end
local nearest = model.nearestLane({x = 1.5, y = 200, z = 12}, {7, 8}, backend, {ROAD = true}, 8)
check(nearest and nearest.entity == 7 and nearest.index == 1 and nearest.param == 0.5,
    "One plausible road chooses the nearest side without considering incompatible tracks")
nearest = model.nearestLane({x = 3, y = 200, z = 12}, {7, 8}, backend, {RAIL = true}, 8)
check(nearest and nearest.entity == 8 and nearest.index == 0, "Rail lines only consider tracks")
check(model.nearestLane({x = 5.5, y = 200, z = 12}, {7}, backend, {ROAD = true}, 3) == nil, "Footpaths are never chosen")
check(model.nearestLane({x = 1.5, y = 200, z = 12}, {7}, backend, {ROAD = true}, 0.25) == nil, "Too far from any lane")
check(model.nearestLane({x = 0/0, y = 0, z = 0}, {7}, backend, {ROAD = true}, 8) == nil, "Invalid cursor position")
check(model.nearestLane({x = 1.5, y = 200, z = 0}, {}, backend, {ROAD = true}, 8) == nil, "No networks nearby")
local reason
nearest, reason = model.nearestLane({x = 0, y = 200, z = 12}, {7}, backend, {ROAD = true}, 8)
check(nearest == nil and reason == "ambiguous", "Equidistant opposite lanes do not choose an arbitrary direction")
nearest = model.nearestLane({x = 0.1, y = 200, z = 12}, {7}, backend, {ROAD = true}, 8)
check(nearest and nearest.index == 1, "Moving off the middle still allows side selection on the same road")
nearest = model.nearestLane({x = 1.5, y = 200, z = 9}, {7, 7}, backend, {ROAD = true}, 8)
check(nearest and nearest.entity == 7, "Small terrain clearance and repeated search results stay usable")
networks[9] = street({lane(4, 1, car, true)}, oneWay)
nearest, reason = model.nearestLane({x = 1.5, y = 200, z = 12}, {7, 9}, backend, {ROAD = true}, 8)
check(nearest == nil and reason == "ambiguous", "A nearby unrelated parallel road makes synthetic route picking ambiguous")
nearest, reason = model.nearestLane({x = 1.5, y = 200, z = 12}, {9, 7}, backend, {ROAD = true}, 8)
check(nearest == nil and reason == "ambiguous", "Ambiguity does not depend on octree result ordering")
-- Even when two segments meet at a shared position, proximity is not evidence
-- of which segment the route uses. Direct native lane picking handles this.
networks[9].edges[1].geometry.x = 2
nearest, reason = model.nearestLane({x = 2, y = 200, z = 12}, {7, 9}, backend, {ROAD = true}, 8)
check(nearest == nil and reason == "ambiguous", "Adjacent road segments near their join also require a native lane pick")
networks[10] = street({lane(2, 1, car, true)}, oneWay)
networks[10].edges[1].geometry.z = 24
nearest, reason = model.nearestLane({x = 1.5, y = 200, z = 12}, {7, 10}, backend, {ROAD = true}, 8)
check(nearest == nil and reason == "elevation", "A bridge over a ground road cannot silently select the lower road")
nearest, reason = model.nearestLane({x = 1.5, y = 200, z = 12}, {10, 7}, backend, {ROAD = true}, 8)
check(nearest == nil and reason == "elevation", "Stacked roads are rejected whichever road the octree lists first")
nearest, reason = model.nearestLane({x = 1.5, y = 200, z = 12}, {10}, backend, {ROAD = true}, 8)
check(nearest == nil and reason == "elevation", "A route above the terrain needs a native lane pick")
networks[10].edges[1].geometry.z = 0
nearest, reason = model.nearestLane({x = 1.5, y = 200, z = 12}, {10}, backend, {ROAD = true}, 8)
check(nearest == nil and reason == "elevation", "A tunnel below the terrain needs a native lane pick")
networks[10].edges[1].geometry.x = 20
nearest = model.nearestLane({x = 1.5, y = 200, z = 12}, {7, 10}, backend, {ROAD = true}, 8)
check(nearest and nearest.entity == 7, "An elevated road outside the pick radius does not block the intended road")

check(model.compass({x = 0, y = 1, z = 0}) == "north" and model.compass({x = 1, y = 0.2, z = 0}) == "east",
    "Compass: +y north, +x east")
check(model.compass({x = -1, y = -1, z = 0}) == "south-west" and model.compass({x = 0.3, y = -1, z = 0}) == "south",
    "Diagonals and near-axis headings")
check(model.compass({x = 0, y = 0, z = 1}) == nil and model.compass({x = 0/0, y = 1, z = 0}) == nil, "No heading without a direction")

local marker = model.markerSegments({x = 1, y = 2, z = 3})
check(#marker == 3 and marker[3][2].z == 9, "Point waypoints get a cross and a post")
check(#model.markerSegments({x = 0/0, y = 0, z = 0}) == 0, "Invalid points draw nothing")
check(model.compatible({ROAD = true}, {ROAD = true, TRAM = true}), "Shared tram/road lanes suit road lines")
check(not model.compatible({ROAD = true}, {RAIL = true}), "Road lines cannot use tracks")

local path = {{stop = {stationGroup = 11}}, {waypoint = {}}, {waypoint = {}}, {stop = {stationGroup = 22}}, {waypoint = {}}}
local before, after = model.segment(path, 2)
check(before == 1 and after == 4, "Find surrounding stops across multiple waypoints")
before, after = model.segment(path, 5)
check(before == 4 and after == 1, "After the last entry refers to the wraparound stretch")
before, after = model.segment(path, 0)
check(before == 4 and after == 1, "Insertion before first entry wraps correctly")
check(model.segment(path, -1) == nil and model.segment(path, nil) == nil, "No selected segment is not a stretch")
check(model.segment({{stop = {}}}, 1) == nil, "Do not invent a stretch on an incomplete line")
check(model.segment({}, 0) == nil, "Empty line is safe")

-- Native addWaypoint with no selected stretch inserts before the last entry.
local short = {{stop = {stationGroup = 1}}, {waypoint = {}}, {stop = {stationGroup = 2}}}
check(model.waypointAfterIndex(short, nil) == 2, "No stretch selected: insert before the last entry")
before, after = model.segment(short, model.waypointAfterIndex(short, nil))
check(before == 1 and after == 3, "Label the stretch native addWaypoint really edits (S1 -> S2, not S2 -> S1)")
check(model.waypointAfterIndex(short, 3) == 3 and model.waypointAfterIndex(short, 0) == 0, "Selected stretch is kept")
check(model.waypointAfterIndex(short, -1) == nil and model.waypointAfterIndex(short, 4) == nil, "Reject -1 and out of range")
check(model.waypointAfterIndex({}, nil) == 0, "Empty path stays safe")
check(model.stopOrdinal(path, 4) == 2 and model.stopOrdinal(path, 3) == 1, "Stop numbers skip waypoints")
print("PASS: " .. checks .. " direction cross-check, stale-data, slope, marker and stretch checks")
