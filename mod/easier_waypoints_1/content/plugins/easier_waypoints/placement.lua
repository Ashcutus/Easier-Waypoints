-- Waypoint placement tool, stacked on top of the Line Manager while it is active.
-- Hovering only reads game state; a click commits through native addWaypoint.
local react = ug_require "::/gui/main/react.lua"
local builtin = ug_require "::/gui/main/builtin.lua"
local appUtil = ug_require "::/scripts/app_util.tl"
local hudUtil = ug_require "::/gui/hud/hud_react_util.tl"
local langUtil = ug_require "::/scripts/lang_util.tl"
local lineUtil = ug_require "::/gui/line_vehicle_mgmt/line_util.tl"
local direction = ug_require "easier_waypoints::/plugins/easier_waypoints/direction.lua"
local game = ug_require "easier_waypoints::/plugins/easier_waypoints/game.lua"

local M = {}
local NAME = "EasierWaypointsPlacement"

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
    if not line or not line.entityAndRevision or line.entityAndRevision.entity ~= param.line then return nil end
    if not mode or mode[1] ~= "SEGMENT" then return nil end
    local after, before, nextStop = game.stretch(line, mode[2])
    if not after then return nil end
    local carriers = game.lineCarriers(lineUtil.getLineCarriers(line))
    local filters = common.gameCtx and common.gameCtx.filters and common.gameCtx.filters:get()
    local protectedEntities = filters and filters.protectedEntities
    return {
        common = common, line = line, mode = mode[2], after = after, before = before, nextStop = nextStop,
        carriers = carriers, points = carriers.WATER or carriers.AIR,
        protected = protectedEntities and lineUtil.isStopProtected(param.line, nil, protectedEntities) or false,
    }
end

local function target(details)
    if not details then return nil end
    if details.transportNetworkEdge then
        local snap = details.transportNetworkEdge.snap
        return {snap = snap, key = "lane:" .. tostring(snap.edgeId.entity) .. ":" .. tostring(snap.edgeId.index)
            .. ":" .. string.format("%.4f", snap.param)}
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
    else
        if not aim.snap then return nil end
        local ok, preview = pcall(direction.preview, {edgePos = aim.snap}, game.backend)
        candidate = {snap = aim.snap, preview = ok and preview or nil}
        if not ok then
            game.warnOnce("placement lane data unreadable", preview)
            candidate.problem = _("This lane's data couldn't be read, so no waypoint can be placed here.")
        elseif not candidate.preview then
            candidate.problem = _("This is not a lane vehicles can use.")
        elseif not direction.compatible(state.carriers, candidate.preview.carriers) then
            candidate.problem = _("This line's vehicles can't use the highlighted lane.")
        end
    end
    if not candidate.problem and state.protected then
        candidate.problem = _("This line can't be edited right now.")
    end
    return candidate
end

local function place(param, aim)
    local state = session(param)
    local candidate = evaluate(state, aim)
    if param.closed or not candidate or candidate.problem or aim.key == param.placedKey then return false end
    local waypoint = api.type.Waypoint.new()
    if candidate.snap then waypoint.edgePos = candidate.snap else waypoint.pos = candidate.pos end
    state.common.addWaypoint(waypoint, state.mode)
    param.placedKey = aim.key
    pcall(function()
        local sounds = api.gui.genericRep.get(api.gui.genericRep.find("::/gui/line_vehicle_mgmt/sound/lvm_sfx.gres")).data
        api.gui.sound.playRandomSoundEffect(sounds.AddWaypoint)
    end)
    return true
end

-- drawn is false when the candidate should have an overlay but none could be built.
local function tooltipParam(state, candidate, drawn)
    local finish = _("Press [iaHint=IA_MENU_BACK/] to finish.")
    if not state then
        return {hint = _("This stretch is no longer selected.") .. " " .. finish}
    end
    local result = {stretch = game.stretchText(state.line, state.mode, _("Adding waypoints between {from} and {to}."))}
    if candidate then
        result.problem = candidate.problem
        if not drawn then
            result.detail = game.previewUnavailableText(candidate.pos ~= nil, not candidate.problem)
        elseif candidate.preview then
            result.detail = game.directionText(candidate.preview)
        end
        result.hint = candidate.problem and finish or (_("Click to add a waypoint here.") .. " " .. finish)
    elseif state.carriers.AIR then
        result.hint = _("Point at the place the aircraft should fly over.") .. " " .. finish
    elseif state.points then
        result.hint = _("Point at the water the ship should pass through.") .. " " .. finish
    else
        result.hint = _("Point at the lane the vehicles should use; the other side of a road runs the other way.") .. " " .. finish
    end
    return result
end

local Tooltip = react.RegisterRecipe("EasierWaypointsPlacementTooltip", function(param)
    local children = {}
    if param.stretch then append(children, game.tooltipText(param.stretch)) end
    if param.problem then append(children, game.tooltipText(param.problem)) end
    if param.detail then append(children, game.tooltipText(param.detail)) end
    if param.hint then append(children, game.tooltipText(param.hint, true)) end
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

local function lineViewer(param, state, candidate)
    local visual = builtin.type.LineVisualization.new()
    visual.entity = param.line
    visual.transparency = 1.0
    local highlight = state and lineUtil.computeStopAndWaypointIndex0(param.line,
        state.after >= 1 and state.after or #state.line.path)
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
        -- false lets the lane under an existing line be picked, as when holding the modifier
        preferLineOverTransportNetworkEdge = false,
    }
end

-- Returns the overlay node and whether everything the candidate needs was drawn.
local function overlay(candidate)
    local build
    if candidate and candidate.preview then
        build = function() return game.laneOverlay(candidate.preview, not candidate.problem) end
    elseif candidate and candidate.pos then
        build = function() return game.pointOverlay(candidate.pos, not candidate.problem) end
    else
        return nil, true
    end
    local ok, node = pcall(build)
    if ok and node then return node, true end
    game.warnOnce(candidate.pos and "placement marker unavailable" or "placement lane preview unavailable",
        ok and "nothing to draw" or node)
    return nil, false
end

local function action(param, ctx)
    local aimState = react.useState(nil)
    local state = session(param)
    local candidate = evaluate(state, aimState:old())

    local function close()
        if param.closed then return end
        param.closed = true
        ctx.popSelf()
    end
    local function hover(entity, _indices, details)
        local aim = target(convert(entity, details))
        local old = aimState:old()
        if (aim and aim.key) ~= (old and old.key) then aimState:set(aim) end
    end
    local function choose(entity, _indices, details)
        local aim = target(convert(entity, details))
        return aim ~= nil and place(param, aim)
    end

    react.useInputAction("IA_MENU_BACK", react.iaHandler(close, function() return true end, _("Finish")))
    react.useInputAction("IA_SELECT", react.iaHandler(function()
        local aim = aimState:old()
        if aim then place(param, aim) end
    end, function() return candidate ~= nil and not candidate.problem end, _("Add Waypoint")))

    local children = {}
    append(children, lineViewer(param, state, candidate))
    append(children, builtin.Selector {
        onHover = hover,
        onSelect = choose,
        filter = selectable,
        lineViewerSupport = true,
        stopOnMenuBack = false,
    })
    local overlayNode, drawn = overlay(candidate)
    append(children, overlayNode)
    append(children, builtin.ActionTooltip {recipe = Tooltip, param = tooltipParam(state, candidate, drawn)})
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

-- Only offered when a stretch is selected; the Line Manager stays open underneath.
function M.start(common)
    local line = common.lineState and common.lineState:old()
    local entity = line and line.entityAndRevision and line.entityAndRevision.entity
    local stack = common.gameCtx and common.gameCtx.toolStack and common.gameCtx.toolStack:get()
    if not entity or not stack then return false end
    stack:getApi().push(M.Tool, nil, {commonParams = common, line = entity}, true)
    return true
end

return M
