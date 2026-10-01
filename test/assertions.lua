--[[
	Assertions for the offline boot test. Runs after the real hub has booted, in
	the same Luau chunk, so `__harness` holds everything the mocks captured.
]]

local H = __harness
local Secrete = H.secrete
local check = H.check
local section = H.section

if type(Secrete) ~= "table" then
	print("\nFAIL  the hub did not return its table")
	error("hub boot failed", 0)
end

local created = H.created
local windowLog = H.windowLog
local humanoid = H.humanoid
local rootPart = H.rootPart
local RenderStepped = H.renderStepped
local InputBegan = H.inputBegan
local AS_OWNER = H.asOwner

local function module(name)
	return Secrete.Modules[name]
end

local function stateFile()
	return "secrete/profiles/" .. tostring(game.PlaceId) .. "/state.txt"
end

local function lastWarning()
	return H.warnings[#H.warnings]
end

local function elementsByFlag(target)
	local found = {}
	if not (target and target.toggleHandle) then
		return found
	end
	for _, element in ipairs(target.toggleHandle.tab.elements) do
		if element.props.flag then
			found[element.props.flag] = element
		end
	end
	return found
end

local function textMentions(needle)
	for index = #created.elements, 1, -1 do
		local element = created.elements[index]
		if element.kind == "Text" and tostring(element.props.body or ""):find(needle, 1, true) then
			return true
		end
	end
	return false
end

----------------------------------------------------------------------
section("boot")

check("hub returns its table", Secrete.Name == "secrete", Secrete.Name)
check("version is set", Secrete.Version == "0.2.0", Secrete.Version)
check("published to getgenv", H.genv.Secrete == Secrete)
check("executor detected", Secrete.Capabilities.executor == "mock-executor", Secrete.Capabilities.executor)
check("filesystem detected", Secrete.Capabilities.fs == true)
check("http detected", Secrete.Capabilities.http == true)
check("ownership gate follows the place", Secrete.Capabilities.ownsPlace == AS_OWNER)
check("state path is per place", Secrete.Store.Path() == stateFile(), Secrete.Store.Path())

----------------------------------------------------------------------
section("interface")

check("window created", H.window ~= nil)
check("window got the configuration block", H.window and H.window.props.configuration.autoSave == true)
check("config file is per place", H.window and H.window.props.configuration.fileName == "secrete_12345")
check("sidebar section added", H.window and H.window.sections[1] == "Client")

local tabs = {}
for _, tab in ipairs(created.tabs) do
	tabs[tab.name] = true
end
check("About tab", tabs.About == true)
check("Visuals tab", tabs.Visuals == true)
check("Developer tab", tabs.Developer == true)
check("Settings tab", tabs.Settings == true)
check("loaded notification", windowLog.notifications >= 1, windowLog.notifications)

----------------------------------------------------------------------
section("packs")

check("packs asked for by name", #H.packHookCalls >= 3, #H.packHookCalls)
check("universal and developer requested", H.packHookCalls[1] == "universal" and H.packHookCalls[2] == "developer")
check("the place was asked for too", table.concat(H.packHookCalls, ","):find("12345", 1, true) ~= nil)
check("loaded packs recorded", #Secrete.Loader.Loaded == 2, #Secrete.Loader.Loaded)
check("a clean boot warns about nothing", #H.warnings == 0, table.concat(H.warnings, " | "))

check("four modules registered", #Secrete.Order == 4, #Secrete.Order)
check("names are stable", Secrete.Order[1] == "Stats Overlay", Secrete.Order[1])
check("everything starts disabled", #Secrete.List(true) == 0)
check("nothing refused at boot", #Secrete.Util.Refusals == 0, table.concat(Secrete.Util.Refusals, ", "))

-- A pack file that returns a function: fetched, cached, then served from that
-- cache when the fetch fails.
section("loader")

local hook = shared.SecretePackLoader
shared.SecretePackLoader = nil

local first, origin = Secrete.Loader.Resolve("selftest")
check("a remote pack resolves", type(first) == "function", tostring(origin))
check("origin says remote", origin == "remote", tostring(origin))
check("fetched once", H.packFetches.selftest == 1, H.packFetches.selftest)
first(Secrete)
check("the pack function ran", H.selfTestPack == true)
check("source cached to disk", isfile("secrete/cache/selftest.lua"))

H.packOffline = true
local cached, cachedOrigin = Secrete.Loader.Resolve("selftest")
check("offline resolve still works", type(cached) == "function", tostring(cachedOrigin))
check("origin says cache", cachedOrigin == "cache", tostring(cachedOrigin))
check("and the fetch failure is warned about", lastWarning():find("cache", 1, true) ~= nil, lastWarning())
check("fetched again before falling back", H.packFetches.selftest == 2, H.packFetches.selftest)

local missing, reason = Secrete.Loader.Resolve("nope")
check("an unknown pack resolves to nothing", missing == nil)
check("with a reason", type(reason) == "string" and #reason > 0, tostring(reason))
check("and the reason the fetch gave, not a generic one", tostring(reason):find("blocked", 1, true) ~= nil, tostring(reason))

H.packOffline = false
local bad, badReason = Secrete.Loader.Resolve("badpack")
check("a pack that is not a function is rejected", bad == nil)
check("and says so", tostring(badReason):find("did not return a pack function", 1, true) ~= nil, tostring(badReason))

check("a missing listed pack fails soft", Secrete.Loader.Run("ghost") == false)
check("and loads nothing", #Secrete.Loader.Loaded == 2, #Secrete.Loader.Loaded)

H.packOffline = false
shared.SecretePackLoader = hook

----------------------------------------------------------------------
section("registry")

local stats = module("Stats Overlay")
check("module toggle built", stats.toggleHandle ~= nil and stats.toggleHandle.kind == "Toggle")
check("module toggle is not saved by rayfield", stats.toggleHandle.props.forgetState == true)
check("no element fell back to a stub", (function()
	for _, element in ipairs(created.elements) do
		if element.stub then
			return false
		end
	end
	return true
end)())

----------------------------------------------------------------------
section("stats overlay")

check("no surface before enabling", #stats._surfaces == 0)
check("enable reports success", Secrete.Enable("Stats Overlay") == true, lastWarning())
check("surface built and parented", #stats._surfaces == 1 and stats._surfaces[1].Parent ~= nil)
local statsGui = stats._surfaces[1]

for _ = 1, 4 do
	RenderStepped:Fire(0.5)
end

check("fps line samples", stats.lines.fps.Text == "fps      2", stats.lines.fps.Text)
check("ping line reads the stats service", stats.lines.ping.Text == "ping     43 ms", stats.lines.ping.Text)
check("memory line reads the stats service", stats.lines.memory.Text == "memory   512 MB", stats.lines.memory.Text)
check("place line", stats.lines.place.Text == "place    12345", stats.lines.place.Text)

local refreshHandle = elementsByFlag(stats).refresh
check("refresh slider built", refreshHandle ~= nil and refreshHandle.kind == "Slider")
refreshHandle:Set(5)
check("option mirrors the element", stats.options.refresh == 5, stats.options.refresh)
check("changing an option does not rebuild the surface", stats._surfaces[1] == statsGui and statsGui._destroyed ~= true)

RenderStepped:Fire(0.5)
check("refresh interval honoured", stats.lines.fps.Text == "fps      2", stats.lines.fps.Text)

-- An executor whose Stats service returns something other than numbers must
-- degrade to "n/a", not throw once per sample inside a render connection.
refreshHandle:Set(1)
H.statsGarbage = true
RenderStepped:Fire(1.1)
check("non-numeric ping degrades", stats.lines.ping.Text == "ping     n/a", stats.lines.ping.Text)
check("missing memory degrades", stats.lines.memory.Text == "memory   n/a", stats.lines.memory.Text)
H.statsGarbage = false
RenderStepped:Fire(1.1)
check("and recovers when the numbers come back", stats.lines.ping.Text == "ping     43 ms", stats.lines.ping.Text)
check("no errors escaped the sampling loop", #H.connectionErrors == 0, table.concat(H.connectionErrors, " | "))

Secrete.Disable("Stats Overlay")
check("surface destroyed on disable", statsGui._destroyed == true)
check("listener disconnected on disable", #stats._connections == 0, #stats._connections)

----------------------------------------------------------------------
section("crosshair")

local crosshair = module("Crosshair")
Secrete.Enable("Crosshair")

local crosshairGui = crosshair._surfaces[1]
check("crosshair built", crosshairGui ~= nil and crosshairGui.Parent ~= nil)
check("four bars plus a dot", #crosshairGui:GetChildren() == 5, #crosshairGui:GetChildren())

local crosshairElements = elementsByFlag(crosshair)
check("colour picker built", crosshairElements.color ~= nil)
check("colour picker is not a stub", crosshairElements.color ~= nil and crosshairElements.color.stub == false)

-- The whole point of the surface/bind split: an option change edits the frames
-- that are already there.
local leftBefore = crosshair.bars.left
crosshairElements.gap:Set(12)
check("gap option stored", crosshair.options.gap == 12, crosshair.options.gap)
check("the same frames are reused", crosshair.bars.left == leftBefore and crosshairGui._destroyed ~= true)
check("bar position follows the option", leftBefore.Position.X.Offset == -12, leftBefore.Position.X.Offset)

crosshairElements.length:Set(24)
check("bar size follows the option", leftBefore.Size.X.Offset == 24, leftBefore.Size.X.Offset)

crosshairElements.color:Set(Color3.fromRGB(255, 0, 0))
check("colour normalised to Color3", typeof(crosshair.options.color) == "Color3", typeof(crosshair.options.color))
check("colour applied to the bars", crosshair.bars.left.BackgroundColor3 == crosshair.options.color)

crosshairElements.dot:Set(false)
check("dot toggle stored", crosshair.options.dot == false)
check("dot hidden rather than rebuilt", crosshair.dot.Visible == false and #crosshairGui:GetChildren() == 5)

Secrete.Disable("Crosshair")
check("crosshair destroyed on disable", crosshairGui._destroyed == true)

----------------------------------------------------------------------
section("developer gate")

local dev = module("Developer Tools")
local devElements = elementsByFlag(dev)

if AS_OWNER then
	check("dev tools enabled", Secrete.Enable("Developer Tools") == true, lastWarning())
	check("walk speed applied", humanoid.WalkSpeed == 16, humanoid.WalkSpeed)

	devElements.speed:Set(120)
	check("walk speed follows the slider", humanoid.WalkSpeed == 120, humanoid.WalkSpeed)

	-- noclip and fly both stay on through the respawn below
	devElements.noclip:Set(true)
	check("noclip loop connected", dev.noclipConnection ~= nil)
	H.stepped:Fire(1)
	check("noclip touched the body", next(dev.touchedParts) ~= nil)

	devElements.fly:Set(true)
	check("fly body velocity attached", rootPart:FindFirstChild("secreteFly") ~= nil)
	check("fly loop connected", dev.flyConnection ~= nil)

	-- A respawn swaps the humanoid and the root under the module's feet.
	H.respawn()
	check("speed survives a respawn", H.humanoid2.WalkSpeed == 120, H.humanoid2.WalkSpeed)
	check("fly re-attaches to the new root", H.rootPart2:FindFirstChild("secreteFly") ~= nil)
	check("fly loop still connected", dev.flyConnection ~= nil)
	check("noclip loop still connected", dev.noclipConnection ~= nil)
	check("stale noclip parts dropped", next(dev.touchedParts) == nil, "touchedParts kept stale references")
	H.stepped:Fire(1)
	check("noclip re-touches the new body", next(dev.touchedParts) ~= nil)

	devElements.fly:Set(false)
	check("fly body velocity removed", H.rootPart2:FindFirstChild("secreteFly") == nil)
	check("fly loop disconnected", dev.flyConnection == nil)
	check("noclip loop survived the fly toggle", dev.noclipConnection ~= nil)

	Secrete.Disable("Developer Tools")
	check("walk speed restored", H.humanoid2.WalkSpeed == 16, H.humanoid2.WalkSpeed)
	check("noclip loop disconnected", dev.noclipConnection == nil)
else
	check("ownership refused", Secrete.Capabilities.ownsPlace == false)
	check("module toggle locked", dev.toggleHandle.locked == true, dev.toggleHandle.lockReason)
	check("enable refuses", Secrete.Enable("Developer Tools") == false)
	check("nothing applied", dev.Enabled == false)
	check("refusal explained to the player", #H.warnings >= 1, #H.warnings)
end

----------------------------------------------------------------------
section("refusals")

local aboutTab = Secrete.UI.Tabs.About
Secrete.UI.Element(aboutTab, "NoSuchKind", {})
check("a refused control is recorded", #Secrete.Util.Refusals == 1, table.concat(Secrete.Util.Refusals, ", "))
check("and returns an inert stub", (Secrete.UI.Element(aboutTab, "NoSuchKind", {})).stub == true)

Secrete.UI.About()
check("the About tab reports it", textMentions("NoSuchKind"))

----------------------------------------------------------------------
section("fault isolation")

local explodes = Secrete.CreateModule({
	Name = "Explodes",
	OnEnable = function()
		error("boom")
	end,
})
explodes:Mount()
check("a throwing module is caught", Secrete.Enable("Explodes") == false, lastWarning())
check("and left disabled", explodes.Enabled == false)
check("the hub keeps running", module("Stats Overlay") ~= nil)

----------------------------------------------------------------------
section("state file")

Secrete.Enable("Stats Overlay")
check("state file written", isfile(stateFile()), stateFile())
local contents = readfile(stateFile())
check("enabled module recorded", contents:find("Stats Overlay=true", 1, true) ~= nil, contents)
check("dev tools recorded as off", contents:find("Developer Tools=false", 1, true) ~= nil, contents)

Secrete.Disable("Stats Overlay")
contents = readfile(stateFile())
check("disable recorded", contents:find("Stats Overlay=false", 1, true) ~= nil, contents)

-- Unreadable lines and unknown modules are ignored rather than fatal.
writefile(stateFile(), "no equals sign here\nStats Overlay=true\nSome Other Hub=true\n")
local state = Secrete.Store.Load()
check("known module read back", state["Stats Overlay"] == true)
check("junk lines ignored", state["no equals sign here"] == nil)

----------------------------------------------------------------------
section("hotkeys")

InputBegan:Fire({ KeyCode = Enum.KeyCode.RightShift }, false)
check("right shift toggles the interface", windowLog.hidden == 1, windowLog.hidden)

InputBegan:Fire({ KeyCode = Enum.KeyCode.RightShift }, true)
check("processed input is ignored", windowLog.hidden == 1, windowLog.hidden)

local customFired = false
Secrete.BindKey(Enum.KeyCode.F5, function()
	customFired = true
end)
InputBegan:Fire({ KeyCode = Enum.KeyCode.F5 }, false)
check("custom bind fires", customFired == true)

----------------------------------------------------------------------
section("settings module")

check("hub settings enables", Secrete.Enable("Hub Settings") == true, lastWarning())

local panicButton
for _, element in ipairs(module("Hub Settings").toggleHandle.tab.elements) do
	if element.kind == "Button" and element.props.name == "Panic (disable all, unload)" then
		panicButton = element
	end
end
check("panic button built", panicButton ~= nil)

----------------------------------------------------------------------
section("heartbeat")

local heartbeat = Secrete.Heartbeat
check("started at boot", heartbeat:IsRunning() == true)
check("pinged once on start", H.heartbeatPings == 1, H.heartbeatPings)
check(
	"points at the sentivel monitor",
	heartbeat.URL:find("sentivel.com/api/heartbeat/", 1, true) ~= nil,
	heartbeat.URL
)
check("default interval is a minute", heartbeat.Interval == 60, heartbeat.Interval)

H.heartbeatSignal:Fire(30)
check("no ping before the interval", H.heartbeatPings == 1, H.heartbeatPings)
H.heartbeatSignal:Fire(31)
check("ping once the interval passes", H.heartbeatPings == 2, H.heartbeatPings)

H.heartbeatFails = true
H.heartbeatSignal:Fire(61)
check("a failed ping is counted", heartbeat.Failures == 1, heartbeat.Failures)
check("a failed ping is recorded, not raised", type(heartbeat.LastError) == "string", heartbeat.LastError)
H.heartbeatFails = false
H.heartbeatSignal:Fire(61)
check("it recovers on the next ping", H.heartbeatPings == 4 and heartbeat.Failures == 1, H.heartbeatPings)
check("error cleared after recovery", heartbeat.LastError == nil, heartbeat.LastError)

local heartbeatToggle = elementsByFlag(module("Hub Settings")).heartbeat
check("heartbeat toggle built", heartbeatToggle ~= nil)
check("toggle reflects the running heartbeat", heartbeatToggle.value == true, heartbeatToggle.value)

heartbeatToggle:Set(false)
check("toggle stops it", heartbeat:IsRunning() == false)
local beforeStop = H.heartbeatPings
H.heartbeatSignal:Fire(300)
check("stopped means no pings", H.heartbeatPings == beforeStop, H.heartbeatPings)

heartbeatToggle:Set(true)
check("toggle restarts it", heartbeat:IsRunning() == true)
check("restart pings immediately", H.heartbeatPings == beforeStop + 1, H.heartbeatPings)

-- Toggling is the documented way to pause the monitor, so it must not leave a
-- dead connection behind on every cycle.
local connectionsBefore = #Secrete._connections
for _ = 1, 3 do
	heartbeatToggle:Set(false)
	heartbeatToggle:Set(true)
end
check(
	"repeated toggling does not leak connections",
	#Secrete._connections == connectionsBefore,
	("%d -> %d"):format(connectionsBefore, #Secrete._connections)
)

-- Without HTTP there is nothing to start, and the switch must not claim
-- otherwise.
Secrete.Capabilities.http = false
heartbeatToggle:Set(false)
heartbeatToggle:Set(true)
check("an unavailable heartbeat stays off", heartbeat:IsRunning() == false)
check("and the switch reflects that", heartbeatToggle.value == false, tostring(heartbeatToggle.value))
Secrete.Capabilities.http = true
heartbeatToggle:Set(true)
check("available again after http returns", heartbeat:IsRunning() == true)

-- Re-asserting ON while it is already running must not flip the switch off:
-- Start() says false for "already running" just as it does for "cannot start".
heartbeatToggle:Set(true)
check("re-asserting on keeps it running", heartbeat:IsRunning() == true)
check("and keeps the switch on", heartbeatToggle.value == true, tostring(heartbeatToggle.value))

----------------------------------------------------------------------
section("panic")

Secrete.Enable("Crosshair")
local crosshairGuiForPanic = crosshair._surfaces[1]
Secrete.Panic()
check("heartbeat stopped by panic", heartbeat:IsRunning() == false)
local pingsAtPanic = H.heartbeatPings
H.heartbeatSignal:Fire(300)
check("no pings after panic", H.heartbeatPings == pingsAtPanic, H.heartbeatPings)
check("and it cannot be restarted afterwards", Secrete.Heartbeat:Start() == false)
check("panic disabled everything", #Secrete.List(true) == 0, #Secrete.List(true))
check("window unloaded", windowLog.unloaded == true)
check("hub marked unloaded", Secrete._unloaded == true)
check("hotkeys disconnected", #Secrete._connections == 0, #Secrete._connections)
check("surface torn down", crosshairGuiForPanic ~= nil and crosshairGuiForPanic._destroyed == true)
check("genv handle dropped", H.genv.Secrete == nil)

InputBegan:Fire({ KeyCode = Enum.KeyCode.RightShift }, false)
check("hotkeys are dead after panic", windowLog.hidden == 1, windowLog.hidden)

H.finish("assertions")
