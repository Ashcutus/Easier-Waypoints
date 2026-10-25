local model = dofile("mod/easier_waypoints_1/content/plugins/easier_waypoints/direction.lua")
local checks = 0
local function check(condition, message) checks = checks + 1; assert(condition, message) end
local geometry = {}
local edge = {geometry = geometry, transportModes = {bus = true}, forwardOnly = true}
local seenEntity, seenParam
local backend = {
    roadNetwork = function(entity) seenEntity = entity; return {edges = {edge}} end,
    isRoadMode = function(modes) return modes.bus end,
    sample = function(shape, param)
        assert(shape == geometry); seenParam = param
        return {{x = 100, y = 200, z = 12}, {x = 0, y = 2, z = 1}}
    end,
}
local waypoint = {edgePos = {edgeId = {entity = 42, index = 0}, param = 0.75}}
local preview = assert(model.preview(waypoint, backend))
check(seenEntity == 42 and seenParam == 0.75, "Use the actual snap, including zero-based edge zero")
check(preview.position.z == 12 and preview.tangent.y == 1, "Preserve elevation and normalize XY tangent")
check(waypoint.edgePos.edgeId.index == 0, "Do not mutate candidate data")
local arrows = model.arrowSegments(preview)
check(#arrows == 3, "One-way edge gets one arrow")
check(arrows[1][2].y > arrows[1][1].y, "Arrow follows lane geometry, not screen axes")
check(arrows[1][2].z > arrows[1][1].z, "Arrow follows slope on a raised road")
edge.forwardOnly = false
preview = assert(model.preview(waypoint, backend)); arrows = model.arrowSegments(preview)
check(#arrows == 6 and arrows[4][2].y < arrows[4][1].y, "Bidirectional edges get opposing arrows")
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
edge.forwardOnly = nil
check(model.preview(waypoint, backend) == nil, "Missing direction is unknown, not bidirectional")
edge.forwardOnly = true; edge.transportModes.bus = false
check(model.preview(waypoint, backend) == nil, "Non-road modes retain native behavior")
edge.transportModes.bus = true
backend.roadNetwork = function() return nil end
check(model.preview(waypoint, backend) == nil, "Deleted edge retains native behavior")
check(model.preview({pos = {x = 1, y = 2, z = 3}}, backend) == nil, "Ship/aircraft waypoint is not a lane")
local path = {{stop = {stationGroup = 11}}, {waypoint = {}}, {waypoint = {}}, {stop = {stationGroup = 22}}, {waypoint = {}}}
local before, after = model.segment(path, 2)
check(before == 1 and after == 4, "Find surrounding stops across multiple waypoints")
before, after = model.segment(path, nil)
check(before == 4 and after == 1, "Append refers to the wraparound stretch")
before, after = model.segment(path, 0)
check(before == 4 and after == 1, "Insertion before first entry wraps correctly")
check(model.segment(path, -1) == nil, "No selected segment is not append")
check(model.segment({{stop = {}}}, 1) == nil, "Do not invent a stretch on an incomplete line")
check(model.segment({}, nil) == nil, "Empty line is safe")
print("PASS: " .. checks .. " direction, stale-data, slope and cyclic segment checks")
