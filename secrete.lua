--[[
	secrete — a client-side hub on Rayfield Gen2.

	One file executes; the content lives in packs. Packs are fetched from this
	repo, cached into the executor's filesystem, and served from that cache when
	HTTP fails, so a client that ran once still runs offline.

	Usage:
		loadstring(game:HttpGet(
			"https://raw.githubusercontent.com/0craxy0/secrete/main/secrete.lua", true))()

	Hotkeys work even if the UI fails to load: RightShift shows and hides the
	window, End panics. Packs, module API and layout: README.md.
]]

local HUB = {
	Name = "secrete",
	Version = "0.2.0",
	RawBase = "https://raw.githubusercontent.com/0craxy0/secrete/main/",
	RayfieldURL = "https://sirius.menu/gen2",
	StateRoot = "secrete/profiles",
	CacheRoot = "secrete/cache",
	-- Fetched in order at boot. A pack named after the PlaceId is loaded too,
	-- when the repo has one, for modules that only make sense in one game.
	Packs = { "universal", "developer" },
	-- Sentivel uptime monitor. A heartbeat key is public by nature: anyone
	-- reading the repo can ping it, so it is an uptime signal, not a secret.
	HeartbeatURL = "https://www.sentivel.com/api/heartbeat/50fddf8f644df0fa550c6261e4a08701c91fb9339b6ab4f38ef96db382d0fd4f",
	HeartbeatInterval = 60,
}

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local StatsService = game:GetService("Stats")

local LocalPlayer = Players.LocalPlayer
local DevMode = false
pcall(function()
	DevMode = shared.SecreteDeveloper == true
end)

----------------------------------------------------------------------
-- 1. capabilities — detect once, degrade instead of exploding
----------------------------------------------------------------------

local Capabilities = {
	executor = "unknown",
	fs = false,
	http = false,
	gethui = false,
	ownsPlace = false,
}

do
	local ok, name = pcall(function()
		return identifyexecutor and identifyexecutor()
	end)
	if ok and type(name) == "string" then
		Capabilities.executor = name
	end

	Capabilities.fs = type(writefile) == "function"
		and type(readfile) == "function"
		and type(makefolder) == "function"
	Capabilities.http = type(game.HttpGet) == "function" or type(request) == "function"
	Capabilities.gethui = type(gethui) == "function"
end

-- The Developer pack only unlocks where you are the owner. `game.CreatorId` is
-- the place owner, not the server owner, so this is a real gate and not a
-- formality: in someone else's game it stays locked.
do
	local ok, result = pcall(function()
		if RunService:IsStudio() then
			return true
		end
		if game.CreatorType == Enum.CreatorType.User then
			return game.CreatorId == LocalPlayer.UserId
		elseif game.CreatorType == Enum.CreatorType.Group then
			-- rank 200 is "Owner" in a group; lower ranks can still develop
			return LocalPlayer:GetRankInGroup(game.CreatorId) >= 200
		end
		return false
	end)
	Capabilities.ownsPlace = ok and result == true
end

----------------------------------------------------------------------
-- 2. utility
----------------------------------------------------------------------

local Util = {
	Refusals = {},
}

local function prefix()
	return ("[%s %s]"):format(HUB.Name, HUB.Version)
end

function Util.Log(...)
	print(prefix(), ...)
end

function Util.Warn(...)
	warn(prefix(), ...)
end

-- This hub never lets one module take the whole script down with it.
function Util.Guard(label, fn)
	local ok, err = pcall(fn)
	if not ok then
		Util.Warn(("%s failed: %s"):format(label, tostring(err)))
	end
	return ok, err
end

-- Executors disagree about what HTTP looks like: game:HttpGet is the common
-- one, request and http_request are the older shapes some builds still ship.
-- The first attempt's failure is kept, because "the network is down" and "this
-- executor has no HTTP at all" are different problems and the caller reports
-- whichever happened.
function Util.Fetch(url)
	local failure

	local function tried(label, fn)
		local ok, result = pcall(fn)
		if ok and type(result) == "string" and #result > 0 then
			return result
		end
		if not failure then
			failure = ok and ("empty response from " .. label) or ("%s: %s"):format(label, tostring(result))
		end
		return nil
	end

	if type(game.HttpGet) == "function" then
		local body = tried("game:HttpGet", function()
			return game:HttpGet(url)
		end)
		if body then
			return body
		end
	end
	if type(request) == "function" then
		local body = tried("request", function()
			local response = request({ Url = url, Method = "GET" })
			return type(response) == "table" and response.Body or nil
		end)
		if body then
			return body
		end
	end
	if type(http_request) == "function" then
		local body = tried("http_request", function()
			local response = http_request({ Url = url, Method = "GET" })
			return type(response) == "table" and response.Body or nil
		end)
		if body then
			return body
		end
	end
	error(failure or "no usable HTTP function: game:HttpGet, request and http_request are all missing")
end

function Util.EnsureFolder(path)
	if type(makefolder) ~= "function" then
		return false
	end
	if type(isfolder) == "function" and isfolder(path) then
		return true
	end
	local ok = pcall(makefolder, path)
	return ok or (type(isfolder) == "function" and isfolder(path) == true)
end

-- Rayfield hands colour callbacks a Color3, and some builds hand back a table.
function Util.AsColor(value, fallback)
	if typeof(value) == "Color3" then
		return value
	end
	if type(value) == "table" then
		return value.Color or value.color or value[1] or fallback
	end
	return fallback
end

function Util.GuiParent()
	if Capabilities.gethui then
		local ok, parent = pcall(gethui)
		if ok and parent then
			return parent
		end
	end
	return LocalPlayer:FindFirstChild("PlayerGui") or LocalPlayer:WaitForChild("PlayerGui")
end

-- A control the library would not build. Worth counting rather than only
-- logging: it is the difference between a menu and a menu with holes in it.
function Util.Refuse(what)
	table.insert(Util.Refusals, what)
	Util.Warn("refused: " .. what)
end

----------------------------------------------------------------------
-- 3. store — per-PlaceId module state
----------------------------------------------------------------------

local Store = {}

function Store.Available()
	return Capabilities.fs
end

function Store.Path()
	return ("%s/%s/state.txt"):format(HUB.StateRoot, tostring(game.PlaceId))
end

function Store.Load()
	if not Store.Available() or type(readfile) ~= "function" then
		return {}
	end
	local ok, contents = pcall(readfile, Store.Path())
	if not ok or type(contents) ~= "string" then
		return {}
	end
	local state = {}
	for line in contents:gmatch("[^\r\n]+") do
		local key, value = line:match("^(.-)=(.*)$")
		if key and key ~= "" then
			state[key] = value == "true"
		end
	end
	return state
end

function Store.Save(state)
	if not Store.Available() then
		return false
	end
	local lines = {}
	for name, enabled in pairs(state) do
		if type(name) == "string" and not name:find("=", 1, true) then
			lines[#lines + 1] = ("%s=%s"):format(name, tostring(enabled == true))
		end
	end
	table.sort(lines)
	return (pcall(function()
		Util.EnsureFolder("secrete")
		Util.EnsureFolder(HUB.StateRoot)
		Util.EnsureFolder(("%s/%s"):format(HUB.StateRoot, tostring(game.PlaceId)))
		writefile(Store.Path(), table.concat(lines, "\n"))
	end))
end

function Store.Clear()
	if not Store.Available() or type(isfile) ~= "function" then
		return
	end
	pcall(function()
		if isfile(Store.Path()) and type(delfile) == "function" then
			delfile(Store.Path())
		end
	end)
end

----------------------------------------------------------------------
-- 4. gui — the shell every module draws into
----------------------------------------------------------------------

-- Modules used to hand-build their own surfaces, which is how one of them
-- ended up unparented. Everything on screen now comes from here, and the
-- registry destroys it when the module disables.
local Gui = {}

function Gui.Screen(name)
	local gui = Instance.new("ScreenGui")
	gui.Name = name
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = Util.GuiParent()
	return gui
end

function Gui.Frame(parent, props)
	props = props or {}
	local frame = Instance.new("Frame")
	frame.BackgroundColor3 = props.color or Color3.fromRGB(255, 255, 255)
	frame.BorderSizePixel = 0
	frame.Parent = parent
	return frame
end

function Gui.Panel(parent, props)
	props = props or {}
	local frame = Instance.new("Frame")
	frame.Name = props.name or "Panel"
	frame.BackgroundColor3 = props.color or Color3.fromRGB(16, 16, 20)
	frame.BackgroundTransparency = props.transparency or 0.35
	frame.BorderSizePixel = 0
	frame.Position = props.position or UDim2.new(0, 12, 0, 12)
	frame.Size = props.size or UDim2.new(0, 172, 0, 0)
	frame.AutomaticSize = props.automaticSize or Enum.AutomaticSize.Y
	frame.Parent = parent

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, props.corner or 6)
	corner.Parent = frame

	local pad = props.padding or 6
	local padding = Instance.new("UIPadding")
	padding.PaddingTop = UDim.new(0, pad)
	padding.PaddingBottom = UDim.new(0, pad)
	padding.PaddingLeft = UDim.new(0, pad + 2)
	padding.PaddingRight = UDim.new(0, pad + 2)
	padding.Parent = frame

	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, props.spacing or 2)
	layout.Parent = frame

	return frame
end

function Gui.Line(parent, order, props)
	props = props or {}
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Font = props.font or Enum.Font.Code
	label.TextColor3 = props.color or Color3.fromRGB(226, 226, 232)
	label.TextSize = props.size or 13
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Size = UDim2.new(1, 0, 0, props.height or 15)
	label.LayoutOrder = order
	label.Text = ""
	label.Parent = parent
	return label
end

----------------------------------------------------------------------
-- 5. module registry
----------------------------------------------------------------------

-- Declared up front because these refer to each other in a circle: modules
-- build elements through the library surface, that surface reports the
-- heartbeat and the loaded packs, and the heartbeat reports through the
-- loader. A Lua local is only visible after its declaration, so the tables
-- are created here and filled in by their own sections.
local UI, Heartbeat, Loader

local Secrete = {
	Name = HUB.Name,
	Version = HUB.Version,
	Util = Util,
	Store = Store,
	Gui = Gui,
	Capabilities = Capabilities,
	Modules = {},
	Order = {},
	_connections = {},
	_unloaded = false,
}

local Module = {}
Module.__index = Module

function Module:Track(connection)
	if typeof(connection) == "RBXScriptConnection" then
		table.insert(self._connections, connection)
	end
	return connection
end

function Module:ClearConnections()
	for _, connection in ipairs(self._connections) do
		pcall(function()
			connection:Disconnect()
		end)
	end
	table.clear(self._connections)
end

function Module:SetOption(key, value)
	self.options[key] = value
	if self.Enabled and type(self.Apply) == "function" then
		Util.Guard(("%s apply"):format(self.Name), function()
			self:Apply()
		end)
	end
end

-- Build an element inside this module's tab. Flags give every value a stable
-- save key, and the wrapper mirrors the value into the module's options so the
-- same logic runs with or without a UI.
function Module:Element(kind, props)
	props = props or {}
	local flag = props.flag
	local callback = props.callback
	local normalize = props.normalize
	props.normalize = nil -- hub-side only, never handed to the library
	if flag then
		if props.value == nil and props.default == nil then
			props.value = self.options[flag]
		end
		props.callback = function(value, ...)
			local stored = value
			if normalize then
				stored = normalize(value, ...)
			end
			self:SetOption(flag, stored)
			if callback then
				callback(stored, ...)
			end
		end
	end
	return UI.Element(self.Tab, kind, props)
end

-- Everything a module puts on screen belongs to one of these, and the registry
-- removes them all when the module disables or the hub unloads.
function Module:Surface(name)
	local gui = Gui.Screen(name)
	table.insert(self._surfaces, gui)
	return gui
end

function Module:DestroySurfaces()
	for _, gui in ipairs(self._surfaces) do
		pcall(function()
			gui:Destroy()
		end)
	end
	table.clear(self._surfaces)
end

-- `persist` is false for toggles the hub makes on its own behalf — restore
-- and teardown — because saving those would overwrite what the player chose.
function Module:Toggle(state, persist)
	local target
	if state == nil then
		target = not self.Enabled
	else
		target = state == true
	end
	if target == self.Enabled then
		return self.Enabled
	end
	-- Disabling during a panic is fine; enabling an unloaded hub is not.
	if target and Secrete._unloaded then
		return false
	end

	if target then
		local ok = Util.Guard(("%s enable"):format(self.Name), function()
			self.Enabled = true
			if type(self.OnEnable) == "function" then
				self:OnEnable()
			end
		end)
		if not ok then
			self.Enabled = false
			self:DestroySurfaces()
			self:ClearConnections()
		end
	else
		self.Enabled = false
		Util.Guard(("%s disable"):format(self.Name), function()
			if type(self.OnDisable) == "function" then
				self:OnDisable()
			end
		end)
		self:DestroySurfaces()
		self:ClearConnections()
	end

	if self.toggleHandle and self.toggleHandle.value ~= self.Enabled then
		pcall(function()
			self.toggleHandle:Set(self.Enabled, true)
		end)
	end

	if persist ~= false then
		Secrete.SaveState()
	end
	return self.Enabled
end

function Module:Mount()
	self.Tab = UI.Tab(self.TabName, self.TabIcon)
	self.toggleHandle = self:Element("Toggle", {
		name = self.Name,
		description = self.Description,
		flag = "secrete_enabled_" .. self.Name,
		forgetState = true, -- the hub owns enable state, see section 3
		value = false,
		callback = function(value)
			if self.Enabled ~= (value == true) then
				self:Toggle(value)
			end
		end,
	})
	Util.Guard(("%s init"):format(self.Name), function()
		if type(self.Init) == "function" then
			self:Init()
		end
	end)
end

function Secrete.CreateModule(def)
	assert(type(def) == "table", "CreateModule wants a table")
	assert(type(def.Name) == "string", "CreateModule wants a Name")

	def.TabName = def.Tab or "Modules"
	def.TabIcon = def.Icon
	def.Enabled = false
	def.options = def.options or {}
	def._connections = {}
	def._surfaces = {}

	local module = setmetatable(def, Module)
	Secrete.Modules[module.Name] = module
	table.insert(Secrete.Order, module.Name)
	return module
end

function Secrete.Enable(name)
	local module = Secrete.Modules[name]
	return module and module:Toggle(true)
end

function Secrete.Disable(name)
	local module = Secrete.Modules[name]
	return module and module:Toggle(false)
end

function Secrete.List(onlyEnabled)
	local list = {}
	for _, name in ipairs(Secrete.Order) do
		local module = Secrete.Modules[name]
		if not onlyEnabled or module.Enabled then
			table.insert(list, module)
		end
	end
	return list
end

function Secrete.SaveState()
	local state = {}
	for _, name in ipairs(Secrete.Order) do
		state[name] = Secrete.Modules[name].Enabled
	end
	return Store.Save(state)
end

----------------------------------------------------------------------
-- 6. library surface — the only place Rayfield is called
----------------------------------------------------------------------

UI = {
	Window = nil,
	Tabs = {},
}

function UI.Load()
	local source
	if DevMode and Capabilities.fs and type(isfile) == "function" and isfile("RayfieldGen2.lua") then
		source = readfile("RayfieldGen2.lua")
	else
		source = Util.Fetch(HUB.RayfieldURL)
	end
	assert(type(source) == "string" and #source > 0, "empty library response")
	local chunk = loadstring(source)
	assert(type(chunk) == "function", "loadstring refused the library")
	return chunk()
end

function UI.Build()
	local rayfield = UI.Load()
	assert(rayfield and type(rayfield.CreateWindow) == "function", "library has no CreateWindow")

	UI.Window = rayfield:CreateWindow({
		name = "secrete",
		subtitle = ("v%s · %s"):format(HUB.Version, Capabilities.executor),
		sidebarLayout = true,
		theme = "cobalt",
		configuration = {
			autoSave = true,
			autoLoad = true,
			fileName = "secrete_" .. tostring(game.PlaceId),
			customFolder = "secrete",
		},
	})
	assert(UI.Window ~= nil, "CreateWindow returned nothing")

	-- Sidebar headings, when the layout supports them.
	pcall(function()
		UI.Window:CreateSection({ name = "Client" })
	end)

	return UI.Window
end

function UI.Tab(name, icon)
	if not UI.Window or not name then
		return nil
	end
	if UI.Tabs[name] then
		return UI.Tabs[name]
	end
	local ok, tab = pcall(UI.Window.CreateTab, UI.Window, { name = name, icon = icon })
	if not ok or tab == nil then
		return nil
	end
	UI.Tabs[name] = tab
	return tab
end

-- A stand-in for an element handle when there is no UI (the library failed to
-- load, or the tab was refused). Modules keep their options and their logic.
local function stub(props)
	local handle = {
		value = props.value or props.default,
		locked = false,
		stub = true,
	}
	function handle:Set(value)
		self.value = value
	end
	function handle:Lock()
		self.locked = true
	end
	function handle:Unlock()
		self.locked = false
	end
	return handle
end

function UI.Element(tab, kind, props)
	props = props or {}
	if type(tab) ~= "table" then
		return stub(props)
	end
	local method = "Create" .. kind
	if type(tab[method]) ~= "function" then
		Util.Refuse(kind)
		return stub(props)
	end
	local ok, handle = pcall(tab[method], tab, props)
	if not ok or handle == nil then
		Util.Refuse(kind)
		return stub(props)
	end
	return handle
end

function UI.Notify(props)
	if not UI.Window then
		return
	end
	pcall(UI.Window.Notify, UI.Window, props)
end

function UI.ToggleHide()
	if UI.Window and type(UI.Window.ToggleHide) == "function" then
		pcall(UI.Window.ToggleHide, UI.Window)
	end
end

-- Built after the packs and modules are known, so it reports what actually
-- happened rather than what was planned.
function UI.About()
	local tab = UI.Tab("About", 93364949241311)
	if not tab then
		return
	end
	local lines = {
		("secrete v%s"):format(HUB.Version),
		("executor: %s"):format(Capabilities.executor),
		("filesystem: %s   http: %s"):format(
			Capabilities.fs and "yes" or "memory only",
			Capabilities.http and "yes" or "no"
		),
		("place owner: %s"):format(Capabilities.ownsPlace and "yes" or "no"),
		("state file: %s"):format(Store.Available() and Store.Path() or "not writable"),
		("heartbeat: %s"):format(
			Heartbeat:IsRunning() and ("running, every %ds"):format(Heartbeat.Interval) or "off"
		),
		("packs: %s"):format(#Loader.Loaded > 0 and table.concat(Loader.Loaded, ", ") or "none"),
		("refused: %s"):format(#Util.Refusals > 0 and table.concat(Util.Refusals, ", ") or "nothing"),
	}
	UI.Element(tab, "Text", { name = "Build", body = table.concat(lines, "\n") })
	UI.Element(tab, "Divider", {})
	UI.Element(tab, "Text", {
		name = "Scope",
		body = "Client-side only: no aim assistance, no hit spoofing, no "
			.. "information about other players. Developer tools unlock only in a "
			.. "place you own.",
	})
end

Secrete.UI = UI

----------------------------------------------------------------------
-- 7. heartbeat — Sentivel uptime pings
----------------------------------------------------------------------

-- The hub pings its own monitor instead of passing `heartbeat` to CreateWindow:
-- that window property is preview-channel only, and driving the ping here means
-- one mechanism works on whichever channel is loaded. A ping is a plain GET,
-- which is what the endpoint answers.
Heartbeat = {
	URL = HUB.HeartbeatURL,
	Interval = HUB.HeartbeatInterval,
	Pings = 0,
	Failures = 0,
	LastError = nil,
	_running = false,
	_elapsed = 0,
}

function Heartbeat:Available()
	return Capabilities.http == true and type(self.URL) == "string" and #self.URL > 0
end

function Heartbeat:Ping()
	if not self:Available() then
		return false, "no HTTP function available"
	end
	local ok, result = pcall(Util.Fetch, self.URL)
	self.Pings = self.Pings + 1
	if ok then
		self.LastError = nil
		return true, result
	end
	self.Failures = self.Failures + 1
	self.LastError = tostring(result)
	return false, result
end

function Heartbeat:Start()
	if self._running then
		return false -- already running
	end
	if not self:Available() then
		return false
	end
	if Secrete._unloaded then
		return false -- a panic tore the hub down; nothing may start again
	end

	self._running = true
	self._elapsed = 0
	self:Ping() -- ping now, so a fresh script shows up on the monitor at once

	-- Deliberately not on the hub's connection list: Stop() owns this connection
	-- and Unload() calls Stop(), so tracking it would leave one dead handle
	-- behind on every off/on toggle.
	self._connection = RunService.Heartbeat:Connect(function(dt)
		self._elapsed = self._elapsed + dt
		local interval = math.max(tonumber(self.Interval) or HUB.HeartbeatInterval, 5)
		if self._elapsed >= interval then
			self._elapsed = 0
			self:Ping()
		end
	end)
	return true
end

function Heartbeat:Stop()
	if self._connection then
		pcall(function()
			self._connection:Disconnect()
		end)
		self._connection = nil
	end
	self._running = false
	self._elapsed = 0
end

function Heartbeat:IsRunning()
	return self._running == true
end

Secrete.Heartbeat = Heartbeat

----------------------------------------------------------------------
-- 8. hotkeys, panic, unload
----------------------------------------------------------------------

function Secrete.BindKey(keycode, fn)
	if typeof(keycode) ~= "EnumItem" then
		return nil
	end
	local connection = UserInputService.InputBegan:Connect(function(input, processed)
		if processed then
			return
		end
		if input.KeyCode == keycode then
			pcall(fn)
		end
	end)
	table.insert(Secrete._connections, connection)
	return connection
end

function Secrete.ToggleUI()
	UI.ToggleHide()
end

-- Unload disables every module on its way out, so panic is that with a louder
-- log line.
function Secrete.Panic()
	Util.Log("panic")
	Secrete.Unload()
end

function Secrete.Unload()
	if Secrete._unloaded then
		return
	end
	Secrete._unloaded = true

	Heartbeat:Stop()

	for _, module in ipairs(Secrete.List(true)) do
		module:Toggle(false, false)
	end
	for _, module in ipairs(Secrete.List()) do
		module:ClearConnections()
	end
	for _, connection in ipairs(Secrete._connections) do
		pcall(function()
			connection:Disconnect()
		end)
	end
	table.clear(Secrete._connections)

	if UI.Window then
		pcall(function()
			if type(UI.Window.Unload) == "function" then
				UI.Window:Unload()
			end
		end)
	end
	UI.Window = nil

	pcall(function()
		getgenv().Secrete = nil
	end)
	Util.Log("unloaded")
end

----------------------------------------------------------------------
-- 9. loader — packs, fetched once and cached
----------------------------------------------------------------------

Loader = {
	Loaded = {},
}

function Loader.Url(name)
	return ("%smodules/%s.lua"):format(HUB.RawBase, name)
end

function Loader.CachePath(name)
	return ("%s/%s.lua"):format(HUB.CacheRoot, (name:gsub("[^%w%-_]", "_")))
end

-- A pack is a file that returns `function(Secrete) ... end`. Resolving one is
-- the only step with two sources: the repo, and the executor's cache when the
-- repo cannot be reached.
function Loader.Resolve(name)
	local custom = nil
	pcall(function()
		custom = shared.SecretePackLoader
	end)
	if type(custom) == "function" then
		local ok, module, err = pcall(custom, name)
		if not ok or type(module) ~= "function" then
			return nil, tostring(err or module)
		end
		return module, "local"
	end

	local source, origin = nil, nil
	local fetched, body = pcall(Util.Fetch, Loader.Url(name))
	if fetched and type(body) == "string" and #body > 0 then
		source, origin = body, "remote"
		if Util.EnsureFolder(HUB.CacheRoot) then
			pcall(writefile, Loader.CachePath(name), body)
		end
	elseif type(readfile) == "function" then
		local read, contents = pcall(readfile, Loader.CachePath(name))
		if read and type(contents) == "string" and #contents > 0 then
			source, origin = contents, "cache"
			Util.Warn(("pack %q served from cache — fetch failed: %s"):format(name, tostring(body)))
		end
	end

	if not source then
		return nil, ("unavailable (%s)"):format(tostring(body))
	end
	local chunk = loadstring(source)
	if type(chunk) ~= "function" then
		return nil, "did not compile"
	end
	local ran, module = pcall(chunk)
	if not ran or type(module) ~= "function" then
		return nil, ("did not return a pack function: %s"):format(tostring(module))
	end
	return module, origin
end

function Loader.Run(name)
	local module, origin = Loader.Resolve(name)
	if not module then
		Util.Warn(("pack %q skipped: %s"):format(name, tostring(origin)))
		return false
	end
	local ok = Util.Guard(("pack %q"):format(name), function()
		module(Secrete)
	end)
	if ok then
		table.insert(Loader.Loaded, name)
		Util.Log(("pack %q loaded (%s)"):format(name, tostring(origin)))
	end
	return ok
end

Secrete.Loader = Loader

----------------------------------------------------------------------
-- 10. boot
----------------------------------------------------------------------

local function boot()
	pcall(function()
		if getgenv().Secrete and getgenv().Secrete.Unload then
			getgenv().Secrete:Unload()
		end
	end)

	Util.Log(("v%s — executor %s, %s filesystem"):format(
		HUB.Version,
		Capabilities.executor,
		Capabilities.fs and "real" or "in-memory only"
	))

	if Heartbeat:Start() then
		Util.Log(("heartbeat started — every %ds"):format(Heartbeat.Interval))
	elseif not Heartbeat:Available() then
		Util.Warn("heartbeat not started: this executor has no usable HTTP function")
	end

	if not Util.Guard("interface", UI.Build) then
		Util.Warn("running without a UI — modules still register and hotkeys still work")
	end

	for _, name in ipairs(HUB.Packs) do
		Loader.Run(name)
	end

	-- A pack named after the place is optional and absent for most games.
	local placeName = tostring(game.PlaceId)
	local placePack = Loader.Resolve(placeName)
	if placePack then
		Util.Guard("place pack", function()
			placePack(Secrete)
		end)
		table.insert(Loader.Loaded, placeName)
		Util.Log(("pack %q loaded (place)"):format(placeName))
	end

	for _, name in ipairs(Secrete.Order) do
		Util.Guard(("%s mount"):format(name), function()
			Secrete.Modules[name]:Mount()
		end)
	end

	-- Restore module on/off state for this place. Rayfield's own configuration
	-- restores element values separately, through the element callbacks.
	local restored = 0
	for name, enabled in pairs(Store.Load()) do
		local module = Secrete.Modules[name]
		if module and enabled then
			module:Toggle(true, false)
			restored = restored + 1
		end
	end
	if restored > 0 then
		Util.Log(("restored %d module(s) for place %s"):format(restored, placeName))
	end

	UI.About()

	Secrete.BindKey(Enum.KeyCode.RightShift, Secrete.ToggleUI)
	Secrete.BindKey(Enum.KeyCode.End, Secrete.Panic)

	local refused = #Util.Refusals
	UI.Notify({
		title = ("secrete v%s"):format(HUB.Version),
		content = refused > 0
				and ("%d control(s) unavailable here — see About."):format(refused)
			or "RightShift toggles the window · End panics.",
		duration = 6,
	})

	pcall(function()
		getgenv().Secrete = Secrete
	end)
end

boot()
return Secrete
