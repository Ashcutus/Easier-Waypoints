local react = ug_require "::/gui/main/react.lua"
local builtin = ug_require "::/gui/main/builtin.lua"
local tooltips = ug_require "::/gui/line_vehicle_mgmt/manager_tooltips_util.tl"
local nativePanel = ug_require "::/gui/line_vehicle_mgmt/line_manager_panel.tl"
local lineUi = ug_require "::/gui/line_vehicle_mgmt/line_react_util.tl"
local direction = ug_require "easier_waypoints::/plugins/easier_waypoints/direction.lua"

local function vertical(children)
    return builtin.BoxLayout {orientation = builtin.type.Orientation.Vertical, children = children}
end

local backend = {
    roadNetwork = function(entity)
        if not api.engine.entityExists(entity) then return nil end
        -- Intersection-only networks and non-road entities retain native feedback.
        if not api.engine.getComponent(entity, api.type.ComponentType.BASE_EDGE_STREET) then return nil end
        return api.engine.getComponent(entity, api.type.ComponentType.TRANSPORT_NETWORK)
    end,
    isRoadMode = function(modes)
        local tm = api.type["enum"].TransportMode
        return modes and (modes[tm.BUS] or modes[tm.TRUCK] or modes[tm.CAR])
    end,
    sample = function(geometry, param)
        return api.type.EdgeGeometry.calcPos(geometry, param)
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

local function previewChildren(original, waypoint)
    local native = react.CallOriginalRecipe(original, waypoint)
    local ok, preview = pcall(direction.preview, waypoint, backend)
    if not ok or not preview then return {native} end
    local rendered, overlay = pcall(function()
        local cyan = api.type.Vec4f.new(0.1, 0.85, 1, 0.65)
        local white = api.type.Vec4f.new(1, 1, 1, 1)
        local edges = {renderable(preview.geometry, 1.2, cyan)}
        for _, segment in ipairs(direction.arrowSegments(preview)) do
            edges[#edges + 1] = renderable(straightGeometry(segment[1], segment[2]), 0.3, white)
        end
        -- Depth testing stays enabled, so this does not paint through bridges.
        return builtin.EdgeRenderable {edges = edges, ignoreDepth = false}
    end)
    if not rendered then return {native} end
    local message = preview.forwardOnly
        and _("Highlighted lane: travel follows the arrow.")
        or _("Highlighted edge allows both directions.")
    return {native, lineUi.makeTooltip(message .. "\n" .. _("Check this side of the road before clicking. Reachability is not checked.")), overlay}
end

local function tooltipReplacement(name, original)
    return react.RegisterRecipe(name, function(waypoint)
        -- Always return a layout, including native fallback; recipe nodes are opaque.
        return vertical(previewChildren(original, waypoint))
    end)
end

local function segmentText(common)
    local line = common.lineState:old()
    if not line or not line.carrierFilter or not line.carrierFilter[api.type["enum"].Carrier.ROAD] then return nil end
    local mode = common.getModeState()
    if not line or not line.path or not mode or mode[1] ~= "SEGMENT" then
        return _("Select a stretch of the line to choose where to add a waypoint.")
    end
    local before, after = direction.segment(line.path, mode[2])
    if not before then return _("Select a stretch between two stops.") end
    local function name(index)
        local entity = line.path[index].stop.stationGroup
        if entity and api.engine.entityExists(entity) then
            local component = api.engine.getComponent(entity, api.type.ComponentType.NAME)
            if component and component.name and component.name ~= "" then return component.name end
        end
        return string.format(_("Stop %d"), index)
    end
    -- Display names are plain text: never insert them into rich-text markup.
    return _("Editing stretch: ") .. name(before) .. " → " .. name(after)
end

local Panel = react.RegisterRecipe("EasierWaypointsPanel", function(params)
    local children = {}
    local ok, text = pcall(segmentText, params.commonParams)
    if ok and text then
        children[#children + 1] = builtin.TextView {text = text}
        children[#children + 1] = builtin.TextView {text = _("Waypoints: use the displayed Add Waypoint action, then check the highlighted road lane.")}
    end
    children[#children + 1] = react.CallOriginalRecipe(nativePanel, params)
    return vertical(children)
end)

local replacements = {
    {tooltips.LMAddWaypoint, tooltipReplacement("EasierWaypointsAdd", tooltips.LMAddWaypoint)},
    {tooltips.LMPromptWaypointModifier, tooltipReplacement("EasierWaypointsPrompt", tooltips.LMPromptWaypointModifier)},
    {tooltips.LMMoveWaypointTarget, tooltipReplacement("EasierWaypointsMove", tooltips.LMMoveWaypointTarget)},
    {nativePanel, Panel},
}

function data()
    return {
        install = function(replacementApi)
            for _, pair in ipairs(replacements) do
                replacementApi.ReplaceRecipe(pair[1], pair[2])
            end
        end,
    }
end
