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
local api = {
    type = {ComponentType = {BASE_EDGE = "base", BASE_EDGE_STREET = "street", BASE_NODE = "node",
            TRANSPORT_NETWORK = "network", TOWN_BUILDING = "town", TRANSPORT_VEHICLE = "vehicle", WORLD = "world", LINE = "line"},
        ["enum"] = {TransportMode = {CAR = "CAR", BUS = "BUS", TRUCK = "TRUCK", TRAM = "TRAM", ELECTRIC_TRAM = "ELECTRIC_TRAM",
            TRAM_TRACK = "TRAM_TRACK", ELECTRIC_TRAM_TRACK = "ELECTRIC_TRAM_TRACK", TRAIN = "TRAIN", ELECTRIC_TRAIN = "ELECTRIC_TRAIN"},
            Carrier = {ROAD = "road", TRAM = "tram", RAIL = "rail", WATER = "water", AIR = "air"}},
        Vec2f = {new = vec}, Vec3f = {new = vec}, Vec4f = {new = vec},
        EdgeGeometry = {new = function() return {} end, Type = {STRAIGHT = 1}, Straight = {new = function() return {} end},
            calcPos = function(g) return {{x = g.x, y = 20, z = 3}, {x = 0, y = 2 * g.dy, z = 0}} end,
            locate = function(g, p) return {0.5, math.abs(g.x - p.x) < 25} end},
        Waypoint = {new = function() return {tag = -1} end},
        StationTerminal = {new = function(s, t) return {station = s, terminal = t} end}},
    engine = {entityExists = function(entity) return exists and entities[entity] ~= nil end,
        getComponent = function(entity, component)
            local e = entities[entity] or {}
            return ({network = e.network, base = e.base, street = e.street, world = e.world})[component]
        end,
        util = {getEntityName = function(entity) return entities[entity] and entities[entity].name end}},
    gui = {SelectionDetails = {TransportNetworkEdge = {new = function() return {} end}},
        genericRep = {find = function() return 1 end, get = function() return {data = {AddWaypoint = {"add.wav"}}} end},
        sound = {playRandomSoundEffect = function() end}},
    cmd = setmetatable({}, {__index = function() error("UI code must never issue commands directly") end}),
}

local registry, tools = {}, {}
local hooks, hookIndex, inputActions = {}, 0, {}
local react = {
    RegisterRecipe = function(name, fn) local recipe = {name = name, fn = fn}; registry[name] = recipe; return recipe end,
    CallOriginalRecipe = function(original, param) return {kind = "original", recipe = original, param = param} end,
    RegisterTool = function(desc) tools[desc.name] = desc; return desc end,
    useState = function(initial)
        hookIndex = hookIndex + 1
        if not hooks[hookIndex] then
            local value = initial
            hooks[hookIndex] = {old = function() return value end, set = function(_, v) value = v end}
        end
        return hooks[hookIndex]
    end,
    useInputAction = function(key, handler) inputActions[key] = handler end,
    iaHandler = function(fn, enabled, text) return {fn = fn, enabled = enabled, text = text} end,
}
local builtin = {BoxLayout = node("layout"), TextView = node("text"), EdgeRenderable = node("overlay"),
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
local buttons = {makeTextButton = function(class, text, onClick, tooltip, disabled)
    return {kind = "button", class = class, text = text, onClick = onClick, tooltip = tooltip, disabled = disabled}
end}
local langUtil = {format = function(message, values) return (message:gsub("{(.-)}", function(k) return tostring(values[k]) end)) end}
local nativePanel = {name = "native panel"}
local tooltips = {LMAddWaypoint = {}, LMPromptWaypointModifier = {}, LMMoveWaypointTarget = {}}
local warnings = {}
local log = {warning = function(message) warnings[#warnings + 1] = message end}

local function environment(reactApi, builtins, tips, panel, buttonApi)
    local env, cache = nil, {}
    local doubles = {
        ["/react.lua"] = reactApi, ["/builtin.lua"] = builtins, ["manager_tooltips_util.tl"] = tips,
        ["line_manager_panel.tl"] = panel, ["button_react_util.tl"] = buttonApi, ["/line_util.tl"] = lineUtil,
        ["lang_util.tl"] = langUtil, ["app_util.tl"] = {isGamepadInputMode = function() return false end},
        ["hud_react_util.tl"] = {makeDefaultLineViewerSnapFactors = function() return {view = 0.05, world = 10} end},
    }
    env = setmetatable({api = api, log = log, _ = function(text) return text end, ug_require = function(path)
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

local env = environment(react, builtin, tooltips, nativePanel, buttons)
assert(loadfile(root .. "main.script.lua", "t", env))()
local replacements = {}
env.data().install({ReplaceRecipe = function(original, replacement) replacements[original] = replacement end})
local count = 0
for _ in pairs(replacements) do count = count + 1 end
assert(count == 4, "Only three tooltip recipes and the stop panel are replaced")
assert(tools.EasierWaypointsPlacement, "Placement tool registered once at load")

-- Native placement tooltips keep native text, add direction and the modifier hint.
local candidate = {edgePos = {edgeId = {entity = 1, index = 1}, param = 0.5}}
local result = replacements[tooltips.LMAddWaypoint].fn(candidate)
assert(result.kind == "layout" and #result.children == 3)
assert(result.children[1].recipe == tooltips.LMAddWaypoint and result.children[1].param == candidate)
assert(result.children[2].text:find("direction of travel", 1, true))
local overlay = result.children[3]
assert(overlay.kind == "overlay" and #overlay.edges == 4 and not overlay.ignoreDepth, "Lane plus one arrow")
assert(overlay.edges[1].geometry == entities[1].network.edges[2].geometry, "Highlight the actual snapped lane")
result = replacements[tooltips.LMPromptWaypointModifier].fn(candidate)
assert(result.children[2].text:find("[iaHint=IA_PRECISION_MODE/]", 1, true) and result.children[2].inlineHintSupport,
    "Prompt says the modifier must be held while clicking")
assert(not result.children[3].inlineHintSupport, "Direction text is plain text")
result = replacements[tooltips.LMPromptWaypointModifier].fn({pos = vec(1, 2, 3)})
assert(#result.children == 2 and result.children[2].text:find("IA_PRECISION_MODE", 1, true),
    "Ship/aircraft prompt also explains the modifier")
entities[1].network.edges[1].geometry.dy = 1
result = replacements[tooltips.LMMoveWaypointTarget].fn(candidate)
assert(#result.children == 3 and #result.children[3].edges == 1 and result.children[2].text:find("couldn't be confirmed", 1, true),
    "Contradictory lane data: highlight without an arrow")
entities[1].network.edges[1].geometry.dy = -1
local track = {edgePos = {edgeId = {entity = 2, index = 0}, param = 0.5}}
result = replacements[tooltips.LMAddWaypoint].fn(track)
assert(#result.children[3].edges == 7 and result.children[2].text:find("either direction", 1, true), "Rail tracks get both arrows")
exists = false
result = replacements[tooltips.LMAddWaypoint].fn(candidate)
assert(#result.children == 1 and result.children[1].param == candidate, "Stale lane falls back without overlay")
exists = true
result = replacements[tooltips.LMAddWaypoint].fn({edgePos = {edgeId = {entity = 3, index = 0}, param = 0.5}})
assert(#result.children == 1, "Footpath feedback unchanged")
local constructor = builtin.type.EdgeRenderable.Edge.new
builtin.type.EdgeRenderable.Edge.new = function() error("unsupported renderer") end
result = replacements[tooltips.LMAddWaypoint].fn(candidate)
assert(#result.children == 2 and result.children[2].text:find("Preview unavailable", 1, true)
    and not result.children[2].text:find("direction of travel", 1, true), "Never describe an arrow that wasn't drawn")
assert(not result.children[2].text:find("Clicking", 1, true), "The native prompt state still needs the modifier")
replacements[tooltips.LMMoveWaypointTarget].fn(candidate)
assert(#warnings == 1 and warnings[1]:find("tooltip lane preview unavailable", 1, true), "Each failure condition is logged once")
builtin.type.EdgeRenderable.Edge.new = constructor

-- Stop panel: mode-aware text, the stretch native addWaypoint will edit, and the tool button.
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
result = replacements[nativePanel].fn(params)
assert(result.children[1].text == "New waypoints go between Station 10 and Station 20.")
assert(result.children[1].meta.class == "font-scale-body" and not result.children[1].inlineHintSupport, "Names are plain text")
assert(result.children[2].inlineHintSupport and result.children[2].text:find("IA_PRECISION_MODE", 1, true))
assert(result.children[3].kind == "button" and result.children[3].text == "Place Waypoint")
assert(result.children[4].recipe == nativePanel and result.children[4].param == params)
mode = {"SEGMENT", nil}
line.path = {{stop = {stationGroup = 20}}, {waypoint = {}}, {stop = {stationGroup = 10}}}
result = replacements[nativePanel].fn(params)
assert(result.children[1].text == "New waypoints go between Station 20 and Station 10.",
    "No stretch selected: label where native addWaypoint inserts (before the last entry)")
line.path = {{stop = {stationGroup = 10}}, {waypoint = {}}, {stop = {stationGroup = 20}}}
mode = {"SEGMENT", -1}
result = replacements[nativePanel].fn(params)
assert(#result.children == 2 and result.children[1].text:find("Select a stretch", 1, true), "No button without a stretch")
mode = {"MOVE_WAYPOINT", {}}
result = replacements[nativePanel].fn(params)
assert(#result.children == 2 and result.children[1].text:find("new location", 1, true), "Move mode explains the move")
mode = {"MOVE_STOP", {}}
assert(#replacements[nativePanel].fn(params).children == 1, "Other modes only show the native panel")
line.carriers = {rail = true}
mode = {"SEGMENT", 1}
assert(#replacements[nativePanel].fn(params).children == 4, "Rail lines get the same guidance")
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
result = replacements[nativePanel].fn(params)
result.children[3].onClick()
assert(pushed == 1 and actionFn and manager.shelved, "Button pushes the placement tool over the shelved Line Manager")
local descriptor, selector, tooltip = render()
assert(selector.lineViewerSupport and find(descriptor.children, "lineViewer").preferLineOverTransportNetworkEdge == false)
assert(not find(descriptor.children, "overlay") and tooltip.param.stretch == "Adding waypoints between Station 10 and Station 20.")
local snaps = {}
for i, param in ipairs({0.2, 0.5, 0.8}) do
    snaps[i] = {edgeId = {entity = 1, index = 1}, param = param}
    selector.onHover(1, {}, {transportNetworkEdge = {snap = snaps[i]}})
    assert(#added == i - 1, "Hovering never edits the line")
    descriptor, selector, tooltip = render()
    overlay = find(descriptor.children, "overlay")
    assert(overlay and #overlay.edges == 4, "Overlay is a direct ActionDescriptor child")
    assert(tooltip.param.detail:find("direction of travel", 1, true) and not tooltip.param.problem)
    assert(tooltip.param.stretch == "Adding waypoints between Station 10 and Station 20.", "Every click stays in the stretch")
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

-- A preview that cannot be drawn is reported once and described honestly.
builtin.type.EdgeRenderable.Edge.new = function() error("unsupported renderer") end
local lane0 = {edgeId = {entity = 1, index = 0}, param = 0.4}
selector.onHover(1, {}, {transportNetworkEdge = {snap = lane0}})
render()
descriptor, selector, tooltip = render()
assert(not find(descriptor.children, "overlay") and tooltip.param.detail:find("Preview unavailable", 1, true)
    and not tooltip.param.detail:find("arrow", 1, true), "Never describe an arrow nobody can see")
assert(tooltip.param.detail:find("still uses the lane", 1, true) and inputActions.IA_SELECT.enabled(), "Placement stays available")
assert(#warnings == 2 and warnings[2]:find("placement lane preview unavailable", 1, true), "Logged once per failure condition")
builtin.type.EdgeRenderable.Edge.new = constructor

local trackSnap = {edgeId = {entity = 2, index = 0}, param = 0.5}
selector.onHover(2, {}, {transportNetworkEdge = {snap = trackSnap}})
descriptor, selector, tooltip = render()
assert(tooltip.param.problem:find("can't use", 1, true) and not inputActions.IA_SELECT.enabled(), "Road line rejects tracks")
assert(selector.onSelect(2, {}, {transportNetworkEdge = {snap = trackSnap}}) == false and #added == 3)
stopProtected = true
selector.onHover(1, {}, {transportNetworkEdge = {snap = {edgeId = {entity = 1, index = 0}, param = 0.25}}})
descriptor, selector, tooltip = render()
assert(tooltip.param.problem:find("can't be edited", 1, true) and #added == 3, "Protected lines are explained, not edited")
stopProtected = false
line.carriers = {water = true}
selector.onHover(5, {}, {world = {pos = vec(9, 9, 0), water = false}})
descriptor, selector, tooltip = render()
assert(tooltip.param.problem == "Ship waypoints must be on water." and descriptor.terrainCirclePolicy == "Always")
selector.onHover(5, {}, {world = {pos = vec(0/0, 9, 0), water = true}})
descriptor, selector, tooltip = render()
assert(tooltip.param.problem:find("couldn't be read", 1, true) and not tooltip.param.detail:find("Clicking", 1, true),
    "An unreadable point is refused, not offered as clickable")
selector.onHover(5, {}, {world = {pos = vec(9, 9, 0), water = true}})
descriptor, selector = render()
assert(#find(descriptor.children, "overlay").edges == 3, "Ship waypoint marker")
selector.onSelect(5, {}, {world = {pos = vec(9, 9, 0), water = true}})
assert(#added == 4 and line.path[6].waypoint.pos.x == 9 and line.path[6].waypoint.edgePos == nil and line.path[7].stop)
local finalMode = mode
line.carriers = {air = true}
tooClose = true
selector.onHover(5, {}, {world = {pos = vec(30, 9, 90), water = false}})
descriptor, selector, tooltip = render()
assert(tooltip.param.problem == "Too close to another waypoint." and #added == 4)
tooClose = false
mode = {"MOVE_STOP", {}}
descriptor, selector, tooltip = render()
assert(tooltip.param.hint:find("no longer selected", 1, true) and not find(descriptor.children, "overlay"))
mode = finalMode
inputActions.IA_MENU_BACK.fn()
descriptor.onBack()
assert(popped == 1 and #stack == 1, "Back pops the tool exactly once")
assert(not manager.shelved and mode == finalMode and #line.path == 7, "The Line Manager returns with its state intact")
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
local store = {builtin = {BoxLayout = 1, TextView = 2, EdgeRenderable = 3, WithComponentParams = 4, Button = 5},
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
local realButtons = {makeTextButton = function(_, text, onClick)
    return realBuiltin.Button {content = realBuiltin.TextView {text = text}, onClick = onClick}
end}
local function original(name) return realReact.RegisterRecipe(name, function() return realBuiltin.BoxLayout {children = {}} end) end
local realTips = {LMAddWaypoint = original("NativeAdd"), LMPromptWaypointModifier = original("NativePrompt"), LMMoveWaypointTarget = original("NativeMove")}
local realPanel = original("NativePanel")
local realEnv = environment(realReact, realBuiltin, realTips, realPanel, realButtons)
assert(loadfile(root .. "main.script.lua", "t", realEnv))()
realEnv.data().install({ReplaceRecipe = realReact.GloballyReplaceRecipeBeforeInitInternal})
assert(store.tools.EasierWaypointsPlacement, "Placement tool registered in the shipped registry")
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
for _, recipe in ipairs({realTips.LMAddWaypoint, realTips.LMPromptWaypointModifier, realTips.LMMoveWaypointTarget, realPanel}) do
    local id = realReact.GetRecipeId(recipe)
    local replacement = assert(store.recipeReplace[id])
    local replacementId = realReact.GetRecipeId(replacement)
    local arg = recipe == realPanel and params or candidate
    context.result = nil
    store.recipes[replacementId](context, {props = {arg}})
    assert(context.result)
end
print("PASS: shipped TF3 Lua React registration/replacement with opaque node IDs (native C++ untested)")
