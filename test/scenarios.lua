--[[
	Behavioural scenarios: whole lifecycles driven through the real hub on top
	of the unit-level assertions.

	Every scenario boots a fresh instance from the inlined hub source, so
	re-running the script inside a live session — the thing users actually do —
	is itself under test. The loader is exercised through its real network path
	(the mock HttpGet serves the inlined pack files) rather than a hook.
]]

local H = __harness
local check = H.check
local section = H.section

local function boot()
	shared.SecretePackLoader = nil
	local instance = loadstring(__harnessHubSource)()
	assert(type(instance) == "table", "the hub did not return its table")
	return instance
end

local function clearDisk()
	for key in pairs(H.disk) do
		H.disk[key] = nil
	end
end

local function statePath()
	return "secrete/profiles/" .. tostring(game.PlaceId) .. "/state.txt"
end

local function has(text, needle)
	return tostring(text):find(needle, 1, true) ~= nil
end

-- The About text is one of the elements the mock captured, whichever tab it
-- ended up on.
local function textMentions(needle)
	for index = #H.created.elements, 1, -1 do
		local element = H.created.elements[index]
		if element.kind == "Text" and has(element.props.body, needle) then
			return true, element.props.body
		end
	end
	return false
end

clearDisk()

----------------------------------------------------------------------
section("scenario: packs fetched over the network, then cached")

H.packOffline = false
local first = boot()

check("both packs fetched", H.packFetches.universal == 1 and H.packFetches.developer == 1, tostring(H.packFetches.universal) .. "/" .. tostring(H.packFetches.developer))
check("their modules registered", #first.Order == 4, #first.Order)
check("the packs are listed as loaded", #first.Loader.Loaded == 2, #first.Loader.Loaded)
check("the fetched source is cached verbatim", readfile("secrete/cache/universal.lua") == __harnessPackSources.universal)
check("heartbeat started", first.Heartbeat:IsRunning() == true)

----------------------------------------------------------------------
section("scenario: offline reboot served from that cache")

local warningsBefore = #H.warnings
local fetchesBefore = H.packFetches.universal
H.packOffline = true
local offline = boot()
local stats = offline.Modules["Stats Overlay"]

check("the network really was tried", H.packFetches.universal == fetchesBefore + 1, H.packFetches.universal)
check("everything still registered", #offline.Order == 4, #offline.Order)
check("the fetch failure was reported", #H.warnings > warningsBefore, #H.warnings)
check("with the reason the fetch gave", H.warnings[#H.warnings]:find("blocked", 1, true) ~= nil, H.warnings[#H.warnings])
check("ui still built", H.window ~= nil)
check("modules can still be enabled", offline.Enable("Stats Overlay") == true)
check("and still run", #stats._connections == 1, tostring(#stats._connections))
H.renderStepped:Fire(1)
H.renderStepped:Fire(1)
check("with a live sampling loop", has(stats.lines.fps.Text, "fps"), stats.lines.fps.Text)

----------------------------------------------------------------------
section("scenario: state survives a reboot, and comes back rendered")

H.packOffline = false
clearDisk()
local session = boot()

check("stats enable", session.Enable("Stats Overlay") == true)
check("crosshair enable", session.Enable("Crosshair") == true)

local stats = session.Modules["Stats Overlay"]
local crosshair = session.Modules["Crosshair"]
local statsSurface = stats._surfaces[1]
local crossSurface = crosshair._surfaces[1]
check("surfaces exist while enabled", statsSurface ~= nil and crossSurface ~= nil)
check("crosshair drew its five lines", crossSurface and #crossSurface:GetChildren() == 5, crossSurface and #crossSurface:GetChildren())

local savedState = readfile(statePath())
check("state file records stats on", has(savedState, "Stats Overlay=true"))
check("state file records crosshair on", has(savedState, "Crosshair=true"))

-- The user re-executes the script: exactly what boot() does.
local rebooted = boot()
local restoredStats = rebooted.Modules["Stats Overlay"]
local restoredCross = rebooted.Modules["Crosshair"]

check("the previous run was unloaded", session._unloaded == true and session.UI.Window == nil)
check("its on-screen tree was destroyed", statsSurface._destroyed == true and crossSurface._destroyed == true)
check("its connections were disconnected", #stats._connections == 0 and #crosshair._connections == 0, #stats._connections .. "/" .. #crosshair._connections)
check("stats came back enabled", restoredStats.Enabled == true)
check("and rebuilt its surface", restoredStats._surfaces[1] ~= nil and restoredStats._surfaces[1].Parent ~= nil)
check("crosshair came back with its lines", restoredCross._surfaces[1] ~= nil and #restoredCross._surfaces[1]:GetChildren() == 5, restoredCross._surfaces[1] and #restoredCross._surfaces[1]:GetChildren())
check("restoring did not rewrite the file", readfile(statePath()) == savedState)

-- A restored module has to actually be live, not just toggled on.
H.renderStepped:Fire(1)
H.renderStepped:Fire(1)
check("the restored overlay samples", has(restoredStats.lines.fps.Text, "fps"), restoredStats.lines.fps.Text)
check("no connection errors from the old run", #H.connectionErrors == 0, tostring(#H.connectionErrors))

-- This hub instance came through loadstring, so its typeof is the real thing:
-- a Color3 must survive the round trip instead of falling back.
local function elementByFlag(module, flag)
	for _, element in ipairs(module.toggleHandle.tab.elements) do
		if element.props.flag == flag then
			return element
		end
	end
end

local colour = elementByFlag(restoredCross, "color")
check("colour picker available after restore", colour ~= nil and colour.stub == false)
-- A colour no fallback would produce: the option table defaults to white.
local wanted = Color3.fromRGB(10, 20, 30)
colour:Set(wanted)
local stored = restoredCross.options.color
check("colour kept as the colour that was set", typeof(stored) == "Color3"
	and stored.R == wanted.R and stored.G == wanted.G and stored.B == wanted.B,
	typeof(stored) == "Color3" and tostring(stored.R) or typeof(stored))
check("and applied to the bars", restoredCross.bars.left.BackgroundColor3.R == wanted.R, tostring(restoredCross.bars.left.BackgroundColor3.R))

----------------------------------------------------------------------
section("scenario: a library missing an element kind still runs")

local notifiesBefore = H.windowLog.notifications
H.missingKinds = { Slider = true }
local degraded = boot()

check("modules still registered", #degraded.Order == 4, #degraded.Order)
check("the refusal is recorded", has(table.concat(degraded.Util.Refusals, ","), "Slider"), table.concat(degraded.Util.Refusals, ","))
check("the player was told", H.windowLog.notifications > notifiesBefore, H.windowLog.notifications - notifiesBefore)

local names, about = textMentions("Slider")
check("about names the refusal", names, about)

check("a stubbed control does not stop a module", degraded.Enable("Stats Overlay") == true)
H.renderStepped:Fire(1)
H.renderStepped:Fire(1)
check("and it still samples", has(degraded.Modules["Stats Overlay"].lines.fps.Text, "fps"), degraded.Modules["Stats Overlay"].lines.fps.Text)

H.missingKinds = {}

----------------------------------------------------------------------
section("scenario: heartbeat cadence over simulated minutes")

local timed = boot()
local pingsBefore = H.heartbeatPings
for _ = 1, 600 do
	H.heartbeatSignal:Fire(1)
end
check("one ping a minute, ten over ten minutes", H.heartbeatPings - pingsBefore == 10, H.heartbeatPings - pingsBefore)
check("and no errors from it", timed.Heartbeat.Failures == 0, timed.Heartbeat.Failures)

----------------------------------------------------------------------
section("scenario: panic, then a fresh run")

local doomed = boot()
doomed.Enable("Crosshair")
local doomedSurface = doomed.Modules["Crosshair"]._surfaces[1]

doomed.Panic()
check("panic destroyed the surface", doomedSurface._destroyed == true)
check("panic unloaded everything", #doomed.List(true) == 0 and doomed._unloaded == true)
check("panic stopped the monitor", doomed.Heartbeat:IsRunning() == false)

local recovered = boot()
check("a fresh run registers modules again", #recovered.Order == 4, #recovered.Order)
check("and starts its own heartbeat", recovered.Heartbeat:IsRunning() == true)
check("without inheriting the panic", recovered._unloaded == false)
check("with its hotkeys wired", #recovered._connections == 2, #recovered._connections)

----------------------------------------------------------------------
H.finish("scenarios")
