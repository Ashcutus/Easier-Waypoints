-- No game installation needed. Native renderer objects are test doubles.
local root = "mod/easier_waypoints_1/content/plugins/easier_waypoints/"
local function vec(x, y, z, w) return {x = x, y = y, z = z, w = w} end
local function node(kind) return function(params) params.kind = kind; return params end end
local function find(children, kind)
    for _, child in ipairs(children) do if child.kind == kind then return child end end
end

-- Street entity 1: two opposing car lanes; entity 2: a track; entity 3: footpath only.
local function lane(x, dy, modes, forwardOnly) return {geometry = {x = x, dy = dy}, transportModes = modes, forwardOnly = forwardOnly} end
local entities = {
    [1] = {network = {edges = {lane(-2, -1, {CAR = true}, true), lane(2, 1, {BUS = true}, true)}},
        base = {laneConfigs = {{forward = false, transportModes = {CAR = true}}, {forward = true, transportModes = {CAR = true}}}},
        street = {}},
    [2] = {network = {edges = {lane(0, 1, {TRAIN = true}, false)}}, base = {laneConfigs = {}}},
    [3] = {network = {edges = {lane(5, 1, {PERSON = true}, false)}}, base = {laneConfigs = {}}, street = {}},
    [10] = {name = "Station 10"}, [20] = {name = "Station 20"},
}
local exists = true
local cursor -- ground point under the mouse, or nil
local shownWindows, soundSets, sounds = {}, {}, {}
-- Private stop-row recipe as the game's React registry holds it.
local recipeIdFor = function(name) return name == "LineStopItem" and 501 or 999 end
local nativeRow = function(rowParams) return {kind = "nativeRow", param = rowParams} end
local registryStore = {recipes = {[501] = function() end}, originalRecipeFn = {[501] = nativeRow}, recipeReplace = {},
    recipeReplacementAllowed = true}
local edgeQueries = 0
local api = {
    type = {ComponentType = {BASE_EDGE = "base", BASE_EDGE_STREET = "street", BASE_NODE = "node",
            TRANSPORT_NETWORK = "network", TOWN_BUILDING = "town", TRANSPORT_VEHICLE = "vehicle", WORLD = "world", LINE = "line"},
        ["enum"] = {TransportMode = {CAR = "CAR", BUS = "BUS", TRUCK = "TRUCK", TRAM = "TRAM", ELECTRIC_TRAM = "ELECTRIC_TRAM",
            TRAM_TRACK = "TRAM_TRACK", ELECTRIC_TRAM_TRACK = "ELECTRIC_TRAM_TRACK", TRAIN = "TRAIN", ELECTRIC_TRAIN = "ELECTRIC_TRAIN"},
            Carrier = {ROAD = "road", TRAM = "tram", RAIL = "rail", WATER = "water", AIR = "air"}},
        Vec2f = {new = vec}, Vec3f = {new = vec}, Vec4f = {new = vec},
        -- Only what the running game provides: no calcPos or locate here.
        EdgeGeometry = {new = function() return {} end, Type = {STRAIGHT = 1}, Straight = {new = function() return {} end}},
        Waypoint = {new = function() return {tag = -1} end},
        EdgeId = {new = function(entity, index) return {entity = entity, index = index} end},
        EdgePos = {new = function() return {} end},
        StationTerminal = {new = function(s, t) return {station = s, terminal = t} end}},
    engine = {entityExists = function(entity) return exists and entities[entity] ~= nil end,
        getComponent = function(entity, component)
            local e = entities[entity] or {}
            return ({network = e.network, base = e.base, street = e.street, world = e.world})[component]
        end,
        util = {getEntityName = function(entity) return entities[entity] and entities[entity].name end,
            -- Lanes run along y through y = 20 at t = 0.5, in the direction of dy.
            transport = {calcPosition = function(g, t) return {x = g.x, y = 20 + (t - 0.5) * 4 * g.dy, z = 3} end},
            octree = {findEntitiesInCircle = function(center, radius, component)
                assert(component == "base" and radius > 0, "Search street and track edges")
                edgeQueries = edgeQueries + 1
                local found = {}
                for entity, e in pairs(entities) do
                    if e.network and math.abs(e.network.edges[1].geometry.x - center.x) < radius then found[#found + 1] = entity end
                end
                table.sort(found)
                return found
            end}}},
    gui = {SelectionDetails = {TransportNetworkEdge = {new = function() return {} end}},
        react = {detail = {makeRecipeId = function(name) return recipeIdFor(name) end}},
        byId = {setVisible = function(id, visible) shownWindows[#shownWindows + 1] = {id, visible} end},
        mouse = {hasTerrainPosition = function() return cursor ~= nil end, getTerrainPosition = function() return cursor end,
            Event = {Type = {Pressed = "pressed", Released = "released", Clicked = "clicked"}}},
        genericRep = {find = function(path) soundSets[#soundSets + 1] = path; return path end,
            get = function(path) return {data = {AddWaypoint = {"bell.wav"}, ButtonClick = {"click.wav"}}} end},
        sound = {playRandomSoundEffect = function(sound) sounds[#sounds + 1] = sound[1] end}},
    cmd = setmetatable({}, {__index = function() error("UI code must never issue commands directly") end}),
}

local registry, tools = {}, {}
local hooks, hookIndex, inputActions, stepFn, expired = {}, 0, {}, nil, false
local react = {
    RegisterRecipe = function(name, fn) local recipe = {name = name, fn = fn}; registry[name] = recipe; return recipe end,
    CallOriginalRecipe = function(original, param) return {kind = "original", recipe = original, param = param} end,
    RegisterTool = function(desc) tools[desc.name] = desc; return desc end,
    useState = function(initial)
        hookIndex = hookIndex + 1
        if not hooks[hookIndex] then
            local value = initial
            -- Like the game, reading expired state is an error.
            hooks[hookIndex] = {old = function() assert(not expired, "old() on expired state"); return value end,
                set = function(_, v) value = v end,
                hasExpired = function() return expired end}
        end
        return hooks[hookIndex]
    end,
    useInputAction = function(key, handler) inputActions[key] = handler end,
    onStep = function(fn) stepFn = fn end,
    iaHandler = function(fn, enabled, text) return {fn = fn, enabled = enabled, text = text} end,
}
local builtin = {BoxLayout = node("layout"), TextView = node("text"), EdgeRenderable = node("overlay"), Component = node("component"),
    FloatingLayout = node("floating"), FloatingLayoutChild = node("floatingChild"),
    Selector = node("selector"), LineViewer = node("lineViewer"), ActionDescriptor = node("action"),
    ActionTooltip = node("tooltip"),
    type = {Orientation = {Vertical = 1}, EdgeRenderable = {Edge = {new = function(geometry) return {geometry = geometry} end}},
        LineVisualization = {new = function() return {} end}}}
local stopProtected, tooClose = false, false
local lineUtil = {
    getLineCarriers = function(line) return line.carriers end,
    isStopProtected = function() return stopProtected end,
    isWaypointTooClose = function() return tooClose end,
    convertDetails = function(_, details) return details end,
    computeStopAndWaypointIndex0 = function(_, stopNumber) return {0, stopNumber} end,
}
local buttons = {makeIconTextButton = function(class, icon, text, onClick, tooltip, enabled, tag, textClass)
    return {kind = "button", class = class, icon = icon, text = text, onClick = onClick, tooltip = tooltip,
        enabled = enabled, tag = tag, textClass = textClass}
end}
local langUtil = {format = function(message, values) return (message:gsub("{(.-)}", function(k) return tostring(values[k]) end)) end}
local nativePanel = {name = "native panel"}
local tooltips = {LMAddWaypoint = {}, LMPromptWaypointModifier = {}, LMMoveWaypointTarget = {}}
local warnings = {}
local messages = {}
local log = {warning = function(message) warnings[#warnings + 1] = message end,
    message = function(message) messages[#messages + 1] = message end}

local function environment(reactApi, builtins, tips, panel, buttonApi, store)
    local env, cache = nil, {}
    local doubles = {
        ["/react.lua"] = reactApi, ["/builtin.lua"] = builtins, ["manager_tooltips_util.tl"] = tips,
        ["line_manager_panel.tl"] = panel, ["button_react_util.tl"] = buttonApi, ["/line_util.tl"] = lineUtil,
        ["lang_util.tl"] = langUtil, ["app_util.tl"] = {isGamepadInputMode = function() return false end},
        ["hud_react_util.tl"] = {makeDefaultLineViewerSnapFactors = function() return {view = 0.05, world = 10} end},
    }
    env = setmetatable({api = api, log = log, _react = store, _ = function(text) return text end, ug_require = function(path)
        local own = path:match("^easier_waypoints::/plugins/easier_waypoints/(.+)$")
        if own then
            cache[own] = cache[own] or assert(loadfile(root .. own, "t", env))()
            return cache[own]
        end
        for suffix, double in pairs(doubles) do
            if path:sub(-#suffix) == suffix then return double end
        end
        error("Unexpected import " .. path)
    end}, {__index = _G})
    return env
end

local env = environment(react, builtin, tooltips, nativePanel, buttons, registryStore)
assert(loadfile(root .. "main.script.lua", "t", env))()
local replacements = {}
env.data().install({ReplaceRecipe = function(original, replacement) replacements[original] = replacement end})
local count = 0
for _ in pairs(replacements) do count = count + 1 end
assert(count == 2, "Only the waypoint prompt tooltip and the stop panel are replaced")
assert(tools.EasierWaypointsPlacement, "Placement tool registered once at load")

assert(#messages == 1 and messages[1]:find("Easier Waypoints: runtime API", 1, true)
    and messages[1]:find("calcPosition=yes", 1, true), "One runtime report per session")

-- The native prompt keeps its text and adds a plain hint. Tooltips never contain
-- world graphics: the engine aborts if they are built inside a tooltip tree.
local function noWorldGraphics(nodeTree)
    assert(nodeTree.kind ~= "overlay", "No EdgeRenderable inside a tooltip")
    for _, child in ipairs(nodeTree.children or {}) do noWorldGraphics(child) end
end
local candidate = {edgePos = {edgeId = {entity = 1, index = 1}, param = 0.5}}
local result = replacements[tooltips.LMPromptWaypointModifier].fn(candidate)
assert(result.kind == "layout" and #result.children == 2)
assert(result.children[1].recipe == tooltips.LMPromptWaypointModifier and result.children[1].param == candidate)
assert(result.children[2].text:find("Hold the key shown above while clicking", 1, true)
    and result.children[2].text:find("Add Waypoint", 1, true), "Prompt explains the key and points to the button")
assert(not result.children[2].inlineHintSupport and not result.children[2].text:find("[iaHint", 1, true), "Plain text only")
noWorldGraphics(result)
result = replacements[tooltips.LMPromptWaypointModifier].fn({pos = vec(1, 2, 3)})
assert(#result.children == 2, "Ship/aircraft prompt gets the same hint")
noWorldGraphics(result)
assert(not replacements[tooltips.LMAddWaypoint] and not replacements[tooltips.LMMoveWaypointTarget],
    "Other native tooltips are left alone")

-- Waypoint rows in the stop list get text; stop rows stay exactly native.
local StopRow = registry.EasierWaypointsStopItem
assert(registryStore.recipeReplace[501] == StopRow and registryStore.recipeReplace[999] == nil,
    "Only the private stop row is replaced, by name")
entities[1].name = "Ring Road"
local rowPath = {{stop = {stationGroup = 10}},
    {waypoint = {edgePos = {edgeId = {entity = 1, index = 1}, param = 0.5}}},
    {waypoint = {edgePos = {edgeId = {entity = 1, index = 0}, param = 0.5}}},
    {waypoint = {edgePos = {edgeId = {entity = 2, index = 0}, param = 0.5}}},
    {waypoint = {pos = vec(1, 2, 0)}}}
local rowLine = {carriers = {road = true}}
local function row(n, carriers)
    rowLine.carriers = carriers or {road = true}
    return StopRow.fn({stopNumber = n, viaState = {old = function() return rowPath end},
        commonParams = {lineState = {old = function() return rowLine end}}})
end
local function rowText(r) return r.children[2].item.layout.children[1].text end
assert(row(1).kind == "nativeRow", "Stop rows are returned untouched")
local waypointRow = row(2)
assert(waypointRow.kind == "floating" and waypointRow.children[1].item.kind == "nativeRow"
    and waypointRow.children[2].item.meta.mouseTransparent, "Label floats over the native row without taking clicks")
assert(rowText(waypointRow) == "Waypoint - Ring Road - heading north", "Road and heading")
assert(rowText(row(3)) == "Waypoint - Ring Road - heading south", "The other side of the road heads the other way")
assert(rowText(row(4)) == "Waypoint - either direction", "Tracks")
assert(rowText(row(5, {water = true})) == "Waypoint - at sea" and rowText(row(5, {air = true})) == "Waypoint - in the air")
entities[1].name = nil

-- Stop panel: one compact waypoint button; the stretch native addWaypoint will edit is in its tooltip.
local added, pushed, popped = {}, 0, 0
local actionFn
local line = {entityAndRevision = {entity = 77}, carriers = {road = true},
    path = {{stop = {stationGroup = 10}}, {waypoint = {}}, {stop = {stationGroup = 20}}}}
local mode = {"SEGMENT", 1}

-- Tool stack double: a stacked push shelves the Line Manager and a pop restores it.
local manager = {shelved = false}
manager.shelve = function(_, _, shelve) manager.shelved = shelve end
local stack = {{tool = manager}}
local stackApi
stackApi = {
    push = function(tool, key, param, stacking)
        assert(tool == tools.EasierWaypointsPlacement and key == nil and stacking == true and param.line == 77)
        local below = stack[#stack]
        below.tool.shelve(below.ctx, below.param, true)
        local entry = {tool = tool, param = param}
        entry.ctx = {setActionFn = function(fn, name) actionFn = fn; assert(name == "EasierWaypointsPlacement") end,
            popSelf = function() stackApi.pop(tool, key) end}
        stack[#stack + 1] = entry
        pushed = pushed + 1
        tool.push(entry.ctx, param)
    end,
    getActiveTool = function() return stack[#stack].tool end,
    pop = function(tool)
        local entry = stack[#stack]
        if entry.tool ~= tool then return end
        stack[#stack] = nil
        popped = popped + 1
        tool.pop(entry.ctx, entry.param)
        local below = stack[#stack]
        below.tool.shelve(below.ctx, below.param, false)
    end,
}
local common = {
    lineState = {old = function() return line end},
    getModeState = function() return mode end,
    -- Mirrors native addWaypoint: insert after the selected entry, or before the
    -- last one when none is selected, then select the stretch after the new waypoint.
    addWaypoint = function(waypoint, insertAt)
        local at = insertAt and insertAt + 1 or math.max(#line.path, 1)
        table.insert(line.path, at, {waypoint = waypoint})
        added[#added + 1] = {waypoint = waypoint, insertAt = insertAt}
        mode = {"SEGMENT", at}
    end,
    gameCtx = {filters = {get = function() return {protectedEntities = {}} end},
        toolStack = {get = function() return {getApi = function() return stackApi end} end}},
}
local params = {commonParams = common}
local normalPath = line.path
local function waypointButton(panel)
    local row = panel.children[1]
    assert(row.kind == "component" and row.meta.class == "ew-waypoint-row", "One compact row above the stop list")
    return row.layout.children[1]
end
result = replacements[nativePanel].fn(params)
assert(#result.children == 2 and result.children[2].recipe == nativePanel and result.children[2].param == params)
local button = waypointButton(result)
assert(button.text == "Add Waypoint" and button.class:find("ew-add-waypoint", 1, true) and button.class:find("secondary", 1, true))
assert(button.icon:find("category_waypoints", 1, true) and button.textClass == "font-scale-annotation", "Small native waypoint button")
assert(button.enabled and button.tooltip:find("between Station 10 and Station 20", 1, true), "The stretch lives in the tooltip")
for _, child in ipairs(result.children) do assert(child.kind ~= "text", "No permanent text block in the panel") end
mode = {"SEGMENT", nil}
line.path = {{stop = {stationGroup = 20}}, {waypoint = {}}, {stop = {stationGroup = 10}}}
assert(waypointButton(replacements[nativePanel].fn(params)).tooltip:find("between Station 20 and Station 10", 1, true),
    "No stretch selected: name where native addWaypoint inserts (before the last entry)")
line.path = normalPath
mode = {"SEGMENT", -1}
button = waypointButton(replacements[nativePanel].fn(params))
assert(button.enabled == false and button.tooltip:find("Select a stretch", 1, true), "Visible but disabled without a stretch")
mode = {"MOVE_WAYPOINT", {}}
assert(#replacements[nativePanel].fn(params).children == 1, "Moving a waypoint: native panel only")
mode = {"MOVE_STOP", {}}
assert(#replacements[nativePanel].fn(params).children == 1, "Other modes only show the native panel")
line.carriers = {rail = true}
mode = {"SEGMENT", 1}
assert(waypointButton(replacements[nativePanel].fn(params)).enabled, "Rail lines get the button too")
line.carriers = {road = true}
common.lineState = nil
assert(#replacements[nativePanel].fn(params).children == 1, "No line state: native panel only")
common.lineState = {old = function() return line end}

-- Placement tool: hover only reads; each click commits once through native addWaypoint.
local function render()
    hookIndex = 0
    local descriptor = actionFn()
    assert(descriptor.kind == "action" and descriptor.onBack)
    return descriptor, find(descriptor.children, "selector"), find(descriptor.children, "tooltip")
end
mode = {"SEGMENT", nil} -- the Line Manager's state after a waypoint was moved
waypointButton(replacements[nativePanel].fn(params)).onClick()
assert(pushed == 1 and actionFn and manager.shelved, "Button pushes the placement tool over the shelved Line Manager")
waypointButton(replacements[nativePanel].fn(params)).onClick()
assert(pushed == 1, "A second click while placing does not stack another tool")
local descriptor, selector, tooltip = render()
assert(selector.lineViewerSupport and find(descriptor.children, "lineViewer").preferLineOverTransportNetworkEdge == true,
    "Lane lines pick the drawn route first, so it can be clicked")
assert(not find(descriptor.children, "overlay") and not tooltip, "Nothing to say while idle: no tooltip")
local snaps = {}
for i, param in ipairs({0.2, 0.5, 0.8}) do
    snaps[i] = {edgeId = {entity = 1, index = 1}, param = param}
    selector.onHover(1, {}, {transportNetworkEdge = {snap = snaps[i]}})
    assert(#added == i - 1, "Hovering never edits the line")
    descriptor, selector, tooltip = render()
    overlay = find(descriptor.children, "overlay")
    assert(overlay and #overlay.edges == 4, "Overlay is a direct ActionDescriptor child")
    assert(tooltip.param.stretch == "Between Station 10 and Station 20" and not tooltip.param.detail and not tooltip.param.problem,
        "A confirmed direction needs only the leg; the arrow shows the rest")
    assert(find(descriptor.children, "lineViewer").snapPreview.snap == snaps[i])
    assert(selector.onSelect(1, {}, {transportNetworkEdge = {snap = snaps[i]}}) == true)
    inputActions.IA_SELECT.fn()
    assert(#added == i, "One native add per click")
    descriptor, selector, tooltip = render()
end
assert(#line.path == 6 and line.path[2].waypoint and line.path[6].stop.stationGroup == 20)
for i = 1, 3 do
    assert(line.path[2 + i].waypoint.edgePos == snaps[i], "Consecutive clicks keep their order along the line")
end
assert(added[1].insertAt == nil and added[2].insertAt == 3 and added[3].insertAt == 4, "Each click follows the last one")
assert(#sounds == 3 and sounds[1] == "click.wav" and soundSets[#soundSets] == "::/gui/sound/gui_comp_sfx.gres",
    "A soft interface click, not the add-waypoint chime")

-- Clicking the drawn route adds the waypoint to that leg, on the lane nearest the cursor.
assert(mode[2] == 5, "The selected stretch follows the last placement")
cursor = vec(1.5, 20, 0)
local returnLeg = {line = {entity = 77, stopNumber = 6}} -- Station 20 back to Station 10
selector.onHover(77, {}, returnLeg)
descriptor, selector, tooltip = render()
assert(tooltip.param.stretch == "Between Station 20 and Station 10", "The hovered leg, not the selected stretch")
local routeSnap = find(descriptor.children, "lineViewer").snapPreview.snap
assert(find(descriptor.children, "overlay") and routeSnap.edgeId.entity == 1 and routeSnap.edgeId.index == 1
    and math.abs(routeSnap.param - 0.5) < 0.001, "Nearest usable lane under the cursor is previewed")
-- The route pick does not change while crossing the road, so the lane follows the cursor each update.
local queries = edgeQueries
cursor = vec(1.9, 20, 0)
stepFn()
assert(#shownWindows == 1 and shownWindows[1][1] == "menu.management" and shownWindows[1][2] == true,
    "The Line Manager stays visible while placing, set once")
assert(edgeQueries == queries, "Small cursor jitter does not search again")
cursor = vec(-1.5, 20, 0)
stepFn()
descriptor, selector, tooltip = render()
routeSnap = find(descriptor.children, "lineViewer").snapPreview.snap
local arrow = find(descriptor.children, "overlay").edges[2].geometry.straight.pos
assert(routeSnap.edgeId.index == 0 and arrow[2].y < arrow[1].y, "Crossing the road picks the other side and flips the arrow")
cursor = vec(1.5, 20, 0)
stepFn()
descriptor, selector, tooltip = render()
assert(find(descriptor.children, "lineViewer").snapPreview.snap.edgeId.index == 1, "And back again")
assert(selector.onSelect(77, {}, returnLeg) == true)
inputActions.IA_SELECT.fn()
local routed = line.path[7] and line.path[7].waypoint and line.path[7].waypoint.edgePos
assert(#added == 4 and added[4].insertAt == 6 and #line.path == 7 and line.path[6].stop and routed
    and routed.edgeId.entity == 1 and routed.edgeId.index == 1 and math.abs(routed.param - 0.5) < 0.001,
    "A route click inserts into that leg, once, on the previewed lane")
cursor = vec(500, 20, 0)
selector.onHover(77, {}, {line = {entity = 77, stopNumber = 1}})
descriptor, selector, tooltip = render()
assert(tooltip.param.problem:find("No lane found", 1, true) and not inputActions.IA_SELECT.enabled(), "No lane nearby")
cursor = nil
selector.onHover(77, {}, {line = {entity = 77, stopNumber = 2}})
descriptor, selector, tooltip = render()
assert(tooltip.param.problem:find("No lane found", 1, true), "No ground position: refuse rather than guess")
selector.onHover(99, {}, {line = {entity = 99, stopNumber = 1}})
descriptor, selector, tooltip = render()
assert(not tooltip and not find(descriptor.children, "overlay"), "Other lines' routes are ignored")
assert(#added == 4)

-- A preview that cannot be drawn is reported once and described honestly.
local constructor = builtin.type.EdgeRenderable.Edge.new
builtin.type.EdgeRenderable.Edge.new = function() error("unsupported renderer") end
local lane0 = {edgeId = {entity = 1, index = 0}, param = 0.4}
selector.onHover(1, {}, {transportNetworkEdge = {snap = lane0}})
render()
descriptor, selector, tooltip = render()
assert(not find(descriptor.children, "overlay") and tooltip.param.detail:find("Preview unavailable", 1, true)
    and not tooltip.param.detail:find("arrow", 1, true), "Never describe an arrow nobody can see")
assert(tooltip.param.detail:find("still uses the lane", 1, true) and inputActions.IA_SELECT.enabled(), "Placement stays available")
assert(#warnings == 1 and warnings[1]:find("placement lane preview unavailable", 1, true), "Logged once per failure condition")
builtin.type.EdgeRenderable.Edge.new = constructor
-- If straight arrow shapes can't be built, the lane fades towards the direction of travel.
local geometryNew = api.type.EdgeGeometry.new
api.type.EdgeGeometry.new = nil
selector.onHover(1, {}, {transportNetworkEdge = {snap = {edgeId = {entity = 1, index = 1}, param = 0.3}}})
render()
descriptor, selector, tooltip = render()
overlay = find(descriptor.children, "overlay")
assert(#overlay.edges == 1 and overlay.edges[1].colors[1].w < overlay.edges[1].colors[2].w
    and tooltip.param.detail:find("brighter in the direction of travel", 1, true), "Arrow-less fallback still shows direction")
assert(#warnings == 2 and warnings[2]:find("direction arrows unavailable", 1, true), "Logged once")
api.type.EdgeGeometry.new = geometryNew

local trackSnap = {edgeId = {entity = 2, index = 0}, param = 0.5}
selector.onHover(2, {}, {transportNetworkEdge = {snap = trackSnap}})
descriptor, selector, tooltip = render()
assert(tooltip.param.problem:find("can't use", 1, true) and not inputActions.IA_SELECT.enabled(), "Road line rejects tracks")
assert(selector.onSelect(2, {}, {transportNetworkEdge = {snap = trackSnap}}) == false and #added == 4)
stopProtected = true
selector.onHover(1, {}, {transportNetworkEdge = {snap = {edgeId = {entity = 1, index = 0}, param = 0.25}}})
descriptor, selector, tooltip = render()
assert(tooltip.param.problem:find("can't be edited", 1, true) and #added == 4, "Protected lines are explained, not edited")
stopProtected = false
line.carriers = {water = true}
selector.onHover(5, {}, {world = {pos = vec(9, 9, 0), water = false}})
descriptor, selector, tooltip = render()
assert(tooltip.param.problem == "Ship waypoints must be on water." and descriptor.terrainCirclePolicy == "Always")
assert(find(descriptor.children, "lineViewer").preferLineOverTransportNetworkEdge == false, "Ships pick free points")
selector.onHover(5, {}, {world = {pos = vec(0/0, 9, 0), water = true}})
descriptor, selector, tooltip = render()
assert(tooltip.param.problem:find("couldn't be read", 1, true) and not tooltip.param.detail,
    "An unreadable point is refused, not offered as clickable")
selector.onHover(5, {}, {world = {pos = vec(9, 9, 0), water = true}})
descriptor, selector = render()
assert(#find(descriptor.children, "overlay").edges == 3, "Ship waypoint marker")
selector.onSelect(5, {}, {world = {pos = vec(9, 9, 0), water = true}})
assert(#added == 5 and #line.path == 8 and line.path[8].waypoint.pos.x == 9 and line.path[8].waypoint.edgePos == nil)
local finalMode = mode
line.carriers = {air = true}
tooClose = true
selector.onHover(5, {}, {world = {pos = vec(30, 9, 90), water = false}})
descriptor, selector, tooltip = render()
assert(tooltip.param.problem == "Too close to another waypoint." and #added == 5)
tooClose = false
mode = {"MOVE_STOP", {}}
descriptor, selector, tooltip = render()
assert(tooltip.param.problem:find("no longer being edited", 1, true) and not find(descriptor.children, "overlay"))
mode = finalMode

-- Engine callbacks never raise: an error is contained and logged once per cause.
local getModeState = common.getModeState
common.getModeState = function() error("engine data changed") end
local warningsBefore = #warnings
selector.onHover(1, {}, {})
selector.onHover(1, {}, {})
common.getModeState = getModeState
assert(#warnings == warningsBefore + 1 and warnings[#warnings]:find("placement hover failed", 1, true),
    "A failing hover is contained and logged once")
line.carriers = {road = true}
cursor = vec(1.5, 20, 0)
local nearestLane = env.ug_require("easier_waypoints::/plugins/easier_waypoints/direction.lua").nearestLane
selector.onHover(77, {}, {line = {entity = 77, stopNumber = 1}})
descriptor, selector, tooltip = render()
env.ug_require("easier_waypoints::/plugins/easier_waypoints/direction.lua").nearestLane = function() error("no lane data") end
cursor = vec(-1.5, 20, 0)
stepFn()
stepFn()
env.ug_require("easier_waypoints::/plugins/easier_waypoints/direction.lua").nearestLane = nearestLane
assert(warnings[#warnings]:find("placement cursor follow failed", 1, true)
    and not warnings[#warnings - 1]:find("cursor follow", 1, true), "A failing update is contained and logged once")
mode = finalMode

-- Finishing: a right drag belongs to the camera, a right click closes the tool once.
assert(inputActions.IA_CLOSE_TOPMOST_WINDOW and inputActions.IA_MENU_BACK, "Escape is captured before native back handlers")
local mouse = selector.onProcessMouseEvent
assert(mouse({type = "pressed", button = 0, x = 0, y = 0}) == false, "Left button untouched")
assert(mouse({type = "pressed", button = 2, x = 100, y = 100}) == false, "A right press may start a camera drag")
assert(mouse({type = "released", button = 2, x = 160, y = 120}) == false and popped == 0, "A right drag does not close")
mouse({type = "pressed", button = 2, x = 100, y = 100})
assert(mouse({type = "released", button = 2, x = 102, y = 101}) == true and popped == 1, "A right click closes")
mouse({type = "clicked", button = 2, x = 102, y = 101})
inputActions.IA_CLOSE_TOPMOST_WINDOW.fn()
inputActions.IA_MENU_BACK.fn()
descriptor.onBack()
assert(popped == 1 and #stack == 1, "Closing happens exactly once")
assert(not manager.shelved and mode == finalMode and #line.path == 8, "The Line Manager returns with its state intact")
-- After closing, late engine callbacks find expired state and do nothing.
expired = true
local warningsAtClose = #warnings
assert(selector.onHover(1, {}, {transportNetworkEdge = {snap = snaps[1]}}) == nil)
assert(selector.onSelect(1, {}, {transportNetworkEdge = {snap = snaps[1]}}) == false)
stepFn()
assert(#added == 5 and popped == 1 and #warnings == warningsAtClose, "Nothing happens, or is logged, after the tool has closed")
expired = false

-- The stylesheet only styles this mod's panel row, never native widgets elsewhere.
local selectors = {}
local cssEnv = setmetatable({require = function(path)
    assert(path == "::/gui/main/stylesheetutil.lua")
    return {makeAdder = function(result) return function(selector, style)
        result[#result + 1] = {selector, style}
        selectors[#selectors + 1] = selector
    end end}
end}, {__index = _G})
assert(loadfile(root .. "panel.css.lua", "t", cssEnv))()
assert(#cssEnv.data() == #selectors and #selectors > 0)
local styled = table.concat(selectors, "\n")
for _, selector in ipairs(selectors) do
    for part in selector:gmatch("[^,]+") do
        assert(part:match("^%s*R::EasierWaypointsPanel ") or part:match("^%s*R::EasierWaypointsStopItem "),
            "Scoped to the mod's own nodes: " .. part)
    end
end
assert(styled:find("!ew-waypoint-row", 1, true) and styled:find("Button!ew-add-waypoint", 1, true)
    and styled:find("!ew-waypoint-label", 1, true), "Panel and row classes are styled")

-- If the registry is missing or another mod already replaced the row, rows stay native.
for _, store in ipairs({false, {recipes = {[501] = function() end}, originalRecipeFn = {[501] = nativeRow},
        recipeReplace = {[501] = function() end}, recipeReplacementAllowed = true}}) do
    local otherEnv = environment(react, builtin, tooltips, nativePanel, buttons, store or nil)
    assert(loadfile(root .. "main.script.lua", "t", otherEnv))()
    local before = #warnings
    otherEnv.data().install({ReplaceRecipe = function() end})
    assert(#warnings == before + 1 and warnings[#warnings]:find("waypoint row text unavailable", 1, true),
        "Row patch declines and says why, once")
    assert(not store or store.recipeReplace[501] ~= registry.EasierWaypointsStopItem, "Another mod's row is left alone")
end
print("PASS: UI delegation, mode-aware guidance, placement tool, invalid-data fallback and no simulation commands")

-- Optional: execute the actual shipped Lua recipe registry with opaque node IDs.
local nativeReactPath = os.getenv("TF3_REACT_LUA")
if not nativeReactPath then
    print("SKIP: shipped React registry check (set TF3_REACT_LUA)")
    return
end
-- The game's react.lua expects Lua 5.2; shim it when the suite runs on LuaJIT.
table.unpack = table.unpack or unpack
table.pack = table.pack or function(...) return {n = select("#", ...), ...} end
local store = {builtin = {BoxLayout = 1, TextView = 2, EdgeRenderable = 3, WithComponentParams = 4, Button = 5,
        Component = 6, ImageView = 7},
    recipes = {}, recipeMetas = {}, originalRecipeFn = {}, recipeReplace = {}, tools = {}, recipeReplacementAllowed = true,
    extensionPoints = {}}
local ids, nextId, nodes = {}, 100, {}
local hostApi = {gui = {react = {params = {builtin = {WithComponentParams = {new = function() return {} end}}}, detail = {makeRecipeId = function(name)
    if not ids[name] then nextId = nextId + 1; ids[name] = nextId end
    return ids[name]
end}}}}
local host = setmetatable({_react = store, api = hostApi,
    log = {verbose = function() end, warning = function() end, error = function(message) error(message) end},
    require = function(path)
        assert(path == "/scripts/string_util.tl")
        return {format = langUtil.format}
    end,
    ug_require = function(path) assert(path == "/scripts/util.tl"); return {} end}, {__index = _G})
local realReact = assert(loadfile(nativeReactPath, "t", host))()
local realBuiltin = {type = builtin.type}
for name in pairs(store.builtin) do realBuiltin[name] = realReact.DeclareBuiltin(name, function() end) end
local realButtons = {makeIconTextButton = function(_, icon, text, onClick)
    return realBuiltin.Button {content = realBuiltin.BoxLayout {children = {realBuiltin.ImageView {path = icon},
        realBuiltin.TextView {text = text}}}, onClick = onClick}
end}
local function original(name) return realReact.RegisterRecipe(name, function() return realBuiltin.BoxLayout {children = {}} end) end
local realTips = {LMAddWaypoint = original("NativeAdd"), LMPromptWaypointModifier = original("NativePrompt"), LMMoveWaypointTarget = original("NativeMove")}
local realPanel = original("NativePanel")
local realRow = original("LineStopItem")
recipeIdFor = hostApi.gui.react.detail.makeRecipeId
local realEnv = environment(realReact, realBuiltin, realTips, realPanel, realButtons, store)
assert(loadfile(root .. "main.script.lua", "t", realEnv))()
realEnv.data().install({ReplaceRecipe = realReact.GloballyReplaceRecipeBeforeInitInternal})
assert(store.tools.EasierWaypointsPlacement, "Placement tool registered in the shipped registry")
local rowId = realReact.GetRecipeId(realRow)
local rowReplacement = store.recipeReplace[rowId]
assert(rowReplacement and realReact.GetRecipeName(rowReplacement) == "EasierWaypointsStopItem",
    "The private row is replaced by name in the shipped registry")
local context = {}
function context:makeNodeWithProps(recipeId, _, props)
    nodes[#nodes + 1] = {recipeId = recipeId, props = props}
    return #nodes -- opaque ID, not a mutable node table
end
function context:setResult(children)
    assert(#children == 1 and nodes[children[1]].recipeId == store.builtin.BoxLayout,
        "Replacement recipes must return a layout")
    self.result = nodes[children[1]]
end
assert(not store.recipeReplace[realReact.GetRecipeId(realTips.LMAddWaypoint)]
    and not store.recipeReplace[realReact.GetRecipeId(realTips.LMMoveWaypointTarget)], "Only the prompt tooltip is replaced")
for _, recipe in ipairs({realTips.LMPromptWaypointModifier, realPanel}) do
    local id = realReact.GetRecipeId(recipe)
    local replacement = assert(store.recipeReplace[id])
    local replacementId = realReact.GetRecipeId(replacement)
    local arg = recipe == realPanel and params or candidate
    context.result = nil
    store.recipes[replacementId](context, {props = {arg}})
    assert(context.result)
end
print("PASS: shipped TF3 Lua React registration/replacement with opaque node IDs (native C++ untested)")
