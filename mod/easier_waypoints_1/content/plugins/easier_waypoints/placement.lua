-- Waypoint placement tool, stacked on top of the Line Manager while it is active.
-- Hovering only reads game state; a click commits through native addWaypoint.
local react = ug_require "::/gui/main/react.lua"
local builtin = ug_require "::/gui/main/builtin.lua"
local appUtil = ug_require "::/scripts/app_util.tl"
local hudUtil = ug_require "::/gui/hud/hud_react_util.tl"
local lineUtil = ug_require "::/gui/line_vehicle_mgmt/line_util.tl"
local direction = ug_require "easier_waypoints::/plugins/easier_waypoints/direction.lua"
local game = ug_require "easier_waypoints::/plugins/easier_waypoints/game.lua"

local M = {}
local NAME = "EasierWaypointsPlacement"
local ROUTE_SEARCH_RADIUS = 20
local ROUTE_LANE_DISTANCE = 8
local ROUTE_FOLLOW_DISTANCE = 0.75
local CLICK_SLOP = 4 -- pixels a right click may move before it counts as a camera drag
local MANAGER_WINDOW = "menu.management"

local function append(list, item)
    if item ~= nil then list[#list + 1] = item end
    return list
end

-- Line and mode are read live: native addWaypoint advances the selected stretch,
-- so consecutive clicks keep their order along the line.
local function session(param)
    local common = param.commonParams
    local line = common.lineState and common.lineState:old()
    local mode = common.getModeState()
    if not line or not line.path or not line.entityAndRevision or line.entityAndRevision.entity ~= param.line then return nil end
    if not mode or mode[1] ~= "SEGMENT" then return nil end
    local carriers = game.lineCarriers(lineUtil.getLineCarriers(line))
    local filters = common.gameCtx and common.gameCtx.filters and common.gameCtx.filters:get()
    local protectedEntities = filters and filters.protectedEntities
    return {
        common = common, line = line, lineEntity = param.line, mode = mode[2],
        after = game.stretch(line, mode[2]),
        carriers = carriers, points = carriers.WATER or carriers.AIR,
        protected = protectedEntities and lineUtil.isStopProtected(param.line, nil, protectedEntities) or false,
    }
end

-- The game only ever copies lane references, so set fields when EdgeId.new is absent.
local function makeSnap(lane)
    local snap = api.type.EdgePos.new()
    if api.type.EdgeId and api.type.EdgeId.new then
        snap.edgeId = api.type.EdgeId.new(lane.entity, lane.index)
    else
        snap.edgeId.entity, snap.edgeId.index = lane.entity, lane.index
    end
    snap.param = lane.param
    return snap
end

local function laneKey(snap)
    return tostring(snap.edgeId.entity) .. ":" .. tostring(snap.edgeId.index) .. ":" .. string.format("%.4f", snap.param)
end

-- A pick on the drawn route names the exact leg (stop and waypoint sub-segment)
-- but no lane, so the lane is the nearest usable one under the cursor. The pick
-- and cursor are kept so the lane can follow the cursor across the road.
local function routeTarget(picked, state)
    if state.points or picked.entity ~= state.lineEntity or type(picked.stopNumber) ~= "number" then return nil end
    local after = game.stretch(state.line, picked.stopNumber)
    if not after then return nil end
    local position = game.backend.cursorPosition()
    local lane = position and direction.nearestLane(position, game.backend.edgesNear(position, ROUTE_SEARCH_RADIUS),
        game.backend, state.carriers, ROUTE_LANE_DISTANCE)
    local aim = {route = true, after = after, picked = picked, cursor = position}
    if not lane then
        aim.key = "route:" .. tostring(after) .. ":none"
        return aim
    end
    local built, snap = pcall(makeSnap, lane)
    if not built then
        game.warnOnce("route lane reference unavailable", snap)
        aim.unbuildable = true
        aim.key = "route:" .. tostring(after) .. ":unbuildable"
        return aim
    end
    aim.snap = snap
    aim.key = "route:" .. tostring(after) .. ":" .. laneKey(snap)
    return aim
end

local function moved(from, to)
    if not from or not to then return from ~= to end
    return (from.x - to.x) ^ 2 + (from.y - to.y) ^ 2 > ROUTE_FOLLOW_DISTANCE ^ 2
end

local function target(details, state)
    if not details or not state then return nil end
    if details.line then return routeTarget(details.line, state) end
    if details.transportNetworkEdge then
        local snap = details.transportNetworkEdge.snap
        return {snap = snap, key = "lane:" .. laneKey(snap)}
    end
    if details.world then
        local pos = details.world.pos
        return {pos = pos, water = details.world.water,
            key = string.format("point:%.1f:%.1f:%.1f:", pos.x, pos.y, pos.z) .. tostring(details.world.water)}
    end
    return nil
end

local function evaluate(state, aim)
    if not state or not aim then return nil end
    local candidate
    if state.points then
        if not aim.pos then return nil end
        candidate = {pos = aim.pos}
        if not direction.validPoint(aim.pos) then
            candidate.problem = _("This position couldn't be read, so no waypoint can be placed here.")
        elseif state.carriers.WATER and not state.carriers.AIR and not aim.water then
            candidate.problem = _("Ship waypoints must be on water.")
        elseif lineUtil.isWaypointTooClose(state.line, aim.pos, nil) then
            candidate.problem = _("Too close to another waypoint.")
        end
    elseif aim.unbuildable then
        candidate = {route = true, problem = _("Clicking the route isn't available in this game version. Point at the road or track itself.")}
    elseif aim.route and not aim.snap then
        candidate = {route = true, problem = _("No lane found under the route here. Point at the road or track itself.")}
    else
        if not aim.snap then return nil end
        local ok, preview = pcall(direction.preview, {edgePos = aim.snap}, game.backend)
        candidate = {snap = aim.snap, route = aim.route, preview = ok and preview or nil}
        if not ok then
            game.warnOnce("placement lane data unreadable", preview)
            candidate.problem = _("This lane's data couldn't be read, so no waypoint can be placed here.")
        elseif not candidate.preview then
            candidate.problem = _("This is not a lane vehicles can use.")
        elseif not direction.compatible(state.carriers, candidate.preview.carriers) then
            candidate.problem = _("This line's vehicles can't use the highlighted lane.")
        end
    end
    if not candidate.problem and not aim.route and not state.after then
        candidate.problem = _("Select a stretch of the line first, or point at the route.")
    end
    if not candidate.problem and state.protected then
        candidate.problem = _("This line can't be edited right now.")
    end
    return candidate
end

-- Route picks insert into their own leg; other picks use the selected stretch.
local function stretchMode(state, aim)
    if aim and aim.route then return aim.after end
    return state.mode
end

local function place(param, aim)
    local state = session(param)
    local candidate = evaluate(state, aim)
    if param.closed or not candidate or candidate.problem or aim.key == param.placedKey then return false end
    local waypoint = api.type.Waypoint.new()
    if candidate.snap then waypoint.edgePos = candidate.snap else waypoint.pos = candidate.pos end
    state.common.addWaypoint(waypoint, stretchMode(state, aim))
    param.placedKey = aim.key
    pcall(function()
        -- A soft interface click rather than the louder add-waypoint chime.
        local sounds = api.gui.genericRep.get(api.gui.genericRep.find("::/gui/sound/gui_comp_sfx.gres")).data
        api.gui.sound.playRandomSoundEffect(sounds.ButtonClick)
    end)
    return true
end

-- Only shown when there is something to say: nothing while idle, the leg while
-- aiming, and a problem or a direction caveat when there is one. The highlight
-- and arrow already show a confirmed direction. drawn is false when the
-- candidate should have an overlay but none could be built.
local function tooltipParam(state, aim, candidate, drawn, arrowsBuilt)
    if not state then
        return {problem = _("This line is no longer being edited. Right-click or press Esc to finish.")}
    end
    if not candidate then return nil end
    if candidate.problem then return {problem = candidate.problem} end
    local result = {stretch = game.stretchText(state.line, stretchMode(state, aim), _("Between {from} and {to}"))}
    if not drawn then
        result.detail = game.previewUnavailableText(candidate.pos ~= nil, true)
    elseif candidate.preview then
        result.detail = game.laneDetail(candidate.preview, arrowsBuilt)
    end
    return result
end

local Tooltip = react.RegisterRecipe("EasierWaypointsPlacementTooltip", function(param)
    local children = {}
    if param.stretch then append(children, game.tooltipText(param.stretch)) end
    if param.problem then append(children, game.tooltipText(param.problem)) end
    if param.detail then append(children, game.tooltipText(param.detail)) end
    return builtin.BoxLayout {orientation = builtin.type.Orientation.Vertical, children = children}
end)

local function selectable(entity)
    if type(entity) ~= "number" or entity < 0 or not api.engine.entityExists(entity) then return false end
    local ct = api.type.ComponentType
    if api.engine.getComponent(entity, ct.TOWN_BUILDING) or api.engine.getComponent(entity, ct.TRANSPORT_VEHICLE) then
        return false
    end
    return api.engine.getComponent(entity, ct.TRANSPORT_NETWORK) ~= nil
        or api.engine.getComponent(entity, ct.WORLD) ~= nil
        or api.engine.getComponent(entity, ct.LINE) ~= nil
end

local function convert(entity, details)
    local ok, result = pcall(lineUtil.convertDetails, entity, details)
    return ok and result or nil
end

local function lineViewer(param, state, aim, candidate)
    local visual = builtin.type.LineVisualization.new()
    visual.entity = param.line
    visual.transparency = 1.0
    local after = state and ((aim and aim.route) and aim.after or state.after)
    local highlight = after and lineUtil.computeStopAndWaypointIndex0(param.line, after >= 1 and after or #state.line.path)
    local snapPreview
    if candidate and candidate.snap and not candidate.problem then
        snapPreview = api.gui.SelectionDetails.TransportNetworkEdge.new()
        snapPreview.snap = candidate.snap
    end
    local snapFactors = hudUtil.makeDefaultLineViewerSnapFactors()
    return builtin.LineViewer {
        selectable = true,
        showLines = {visual},
        maxSnapFactorView = snapFactors.view,
        maxSnapFactorWorld = snapFactors.world,
        highlightedLine = highlight and param.line or -1,
        highlightedLineStop = highlight and highlight[1] or -1,
        highlightedLineWaypoint = highlight and highlight[2] or -1,
        highlightedTerminal = api.type.StationTerminal.new(-1, -2),
        snapPreview = snapPreview,
        showTerminals = false,
        -- Lane lines pick the drawn route first, so clicking it names the leg.
        -- Ships and aircraft place free points, which the route would block.
        preferLineOverTransportNetworkEdge = not (state and state.points),
    }
end

-- Returns the overlay node, whether everything the candidate needs was drawn,
-- and whether lane arrows could be built.
local function overlay(candidate)
    local build
    if candidate and candidate.preview then
        build = function() return game.laneOverlay(candidate.preview, not candidate.problem) end
    elseif candidate and candidate.pos then
        build = function() return game.pointOverlay(candidate.pos, not candidate.problem) end
    else
        return nil, true
    end
    local ok, node, arrowsBuilt = pcall(build)
    if ok and node then return node, true, arrowsBuilt ~= false end
    game.warnOnce(candidate.pos and "placement marker unavailable" or "placement lane preview unavailable",
        ok and "nothing to draw" or node)
    return nil, false
end

local function action(param, ctx)
    local aimState = react.useState(nil)
    local state = session(param)
    local aim = aimState:old()
    local candidate = evaluate(state, aim)

    local function close()
        if param.closed then return end
        param.closed = true
        ctx.popSelf()
    end
    -- Engine callbacks must never raise: an error repeats every frame. After the
    -- tool closes its state expires, so callbacks then do nothing.
    local function guarded(name, fn, fallback)
        return function(...)
            if param.closed or (aimState.hasExpired and aimState:hasExpired()) then return fallback end
            local ok, result = pcall(fn, ...)
            if ok then return result end
            game.warnOnce("placement " .. name .. " failed", result)
            return fallback
        end
    end
    local function hover(entity, _indices, details)
        local hovered = target(convert(entity, details), session(param))
        local old = aimState:old()
        if (hovered and hovered.key) ~= (old and old.key) then aimState:set(hovered) end
    end
    local function choose(entity, _indices, details)
        local chosen = target(convert(entity, details), session(param))
        return chosen ~= nil and place(param, chosen)
    end
    -- A right click finishes; a right drag still belongs to the camera.
    local function mouse(evt)
        if evt.button ~= 2 then return false end
        local types = api.gui.mouse.Event.Type
        if evt.type == types.Pressed then
            param.rightPress = {evt.x, evt.y}
            return false
        end
        local press = param.rightPress
        local still = press and math.abs(evt.x - press[1]) <= CLICK_SLOP and math.abs(evt.y - press[2]) <= CLICK_SLOP
        if evt.type == types.Released then param.rightPress = nil end
        if evt.type == types.Clicked or (evt.type == types.Released and still) then
            close()
            return true
        end
        return false
    end

    -- The route pick only changes with the leg, so the lane follows the cursor
    -- across the road on each update; that is how a side of the road is chosen.
    react.onStep(guarded("cursor follow", function()
        -- Opening a tool hides the Line Manager; keep it visible to watch the stop list grow.
        if not param.managerShown then
            param.managerShown = true
            api.gui.byId.setVisible(MANAGER_WINDOW, true)
        end
        local current = aimState:old()
        if not current or not current.route then return end
        if not moved(current.cursor, game.backend.cursorPosition()) then return end
        local live = session(param)
        local followed = live and routeTarget(current.picked, live)
        if not followed then return end
        if followed.key ~= current.key then
            aimState:set(followed)
        else
            current.cursor = followed.cursor -- same lane: remember where the search ran, no re-render
        end
    end))

    local enabled = function() return true end
    -- IA_CLOSE_TOPMOST_WINDOW keeps native back handlers from swallowing Escape.
    react.useInputAction("IA_CLOSE_TOPMOST_WINDOW", react.iaHandler(close, enabled, _("Finish")))
    react.useInputAction("IA_MENU_BACK", react.iaHandler(close, enabled, _("Finish")))
    react.useInputAction("IA_SELECT", react.iaHandler(guarded("select", function()
        local current = aimState:old()
        if current then place(param, current) end
    end), function() return candidate ~= nil and not candidate.problem end, _("Add Waypoint")))

    local children = {}
    append(children, lineViewer(param, state, aim, candidate))
    append(children, builtin.Selector {
        onHover = guarded("hover", hover),
        onSelect = guarded("click", choose, false),
        onProcessMouseEvent = guarded("mouse", mouse, false),
        filter = selectable,
        lineViewerSupport = true,
        stopOnMenuBack = false,
    })
    local overlayNode, drawn, arrowsBuilt = overlay(candidate)
    append(children, overlayNode)
    local tip = tooltipParam(state, aim, candidate, drawn, arrowsBuilt)
    if tip then append(children, builtin.ActionTooltip {recipe = Tooltip, param = tip}) end
    return builtin.ActionDescriptor {
        children = children,
        onBack = close,
        crosshair = appUtil.isGamepadInputMode(),
        terrainCirclePolicy = (state and state.points) and "Always" or "Never",
    }
end

M.Tool = react.RegisterTool {
    name = NAME,
    push = function(ctx, param)
        ctx.setActionFn(function() return action(param, ctx) end, NAME)
    end,
    pop = function(_ctx, param)
        param.closed = true
    end,
    shelve = function() end,
}

-- Offered from the stop panel; the Line Manager stays open underneath.
function M.start(common)
    local line = common.lineState and common.lineState:old()
    local entity = line and line.entityAndRevision and line.entityAndRevision.entity
    local stack = common.gameCtx and common.gameCtx.toolStack and common.gameCtx.toolStack:get()
    if not entity or not stack then return false end
    local toolStack = stack:getApi()
    if toolStack.getActiveTool and toolStack.getActiveTool() == M.Tool then return false end
    toolStack.push(M.Tool, nil, {commonParams = common, line = entity}, true)
    return true
end

return M
