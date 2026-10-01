--[[
	Mock Roblox + executor surface for the offline boot test.

	This file is concatenated *before* secrete.lua and test/assertions.lua by
	test/run.sh so all three share one global environment. Nothing here talks
	to Roblox, an executor or the network.
]]

local mode = ...
local AS_OWNER = mode == "owner"

----------------------------------------------------------------------
-- harness plumbing
----------------------------------------------------------------------

local passed, failed, currentSection = 0, 0, "boot"
local reportedPassed, reportedFailed = 0, 0

local harness = {
	asOwner = AS_OWNER,
	created = { tabs = {}, elements = {} },
	disk = {},
	warnings = {},
	genv = {},
	windowLog = { notifications = 0, unloaded = false, hidden = 0 },
	heartbeatPings = 0,
	heartbeatFails = false,
	statsGarbage = false,
	connectionErrors = {},
	packFetches = {},
	packHookCalls = {},
	packOffline = false,
	missingKinds = {},
}

function harness.section(name)
	currentSection = name
	print(("\n%s"):format(name))
end

function harness.check(label, condition, detail)
	if condition then
		passed = passed + 1
		print(("  ok    %s"):format(label))
	else
		failed = failed + 1
		local suffix = detail ~= nil and (": " .. tostring(detail)) or ""
		print(("  FAIL  %s%s"):format(label, suffix))
	end
end

-- Reports the assertions made since the last call, so each phase in the
-- bundle gets its own summary instead of a running total.
function harness.finish(label)
	print(("\n%s: %d passed, %d failed"):format(label or "assertions", passed - reportedPassed, failed - reportedFailed))
	if failed > 0 then
		error(("%d assertion(s) failed"):format(failed), 0)
	end
	reportedPassed, reportedFailed = passed, failed
end

__harness = harness

----------------------------------------------------------------------
-- datatypes
----------------------------------------------------------------------

local realTypeof = typeof

function typeof(value)
	if type(value) == "table" then
		local meta = getmetatable(value)
		if meta and meta.__mocktype then
			return meta.__mocktype
		end
		return "table"
	end
	return realTypeof(value)
end

-- A direct `typeof(x)` inside a chunk compiled by loadstring goes to Luau's
-- builtin, not to the override above, because the compiler emits it as a
-- builtin fastcall. The hub and every pack arrive through loadstring, so
-- without this preamble their typeof checks see mock datatypes as plain
-- tables: connections would never be tracked. Binding it as a local is what
-- makes a loaded chunk behave the way Roblox does. Prepended without a newline
-- so reported line numbers still match the source.
__harnessTypeof = typeof

local realLoadstring = loadstring
function loadstring(source, chunkname)
	if type(source) == "string" then
		source = "local typeof = __harnessTypeof;" .. source
	end
	if chunkname ~= nil then
		return realLoadstring(source, chunkname)
	end
	return realLoadstring(source)
end

local function tag(value, name)
	setmetatable(value, { __mocktype = name })
	return value
end

local function mockCtor(name, fields)
	local ctor = {}
	function ctor.new(...)
		local args = { ... }
		local value = tag({}, name)
		for index, field in ipairs(fields) do
			value[field] = args[index]
		end
		return value
	end
	return ctor
end

Color3 = mockCtor("Color3", { "R", "G", "B" })
function Color3.fromRGB(r, g, b)
	return Color3.new(r / 255, g / 255, b / 255)
end

Vector3 = mockCtor("Vector3", { "X", "Y", "Z" })
function Vector3.zero()
	return Vector3.new(0, 0, 0)
end
function Vector3.yAxis()
	return Vector3.new(0, 1, 0)
end

Vector2 = mockCtor("Vector2", { "X", "Y" })

UDim = mockCtor("UDim", { "Scale", "Offset" })

UDim2 = mockCtor("UDim2", { "X", "Y" })
function UDim2.new(xs, xo, ys, yo)
	local value = tag({}, "UDim2")
	value.X = UDim.new(xs, xo)
	value.Y = UDim.new(ys, yo)
	return value
end
function UDim2.fromOffset(x, y)
	return UDim2.new(0, x, 0, y)
end

-- Identity matters: Enum.KeyCode.RightShift must not equal Enum.KeyCode.End.
local enumCache = {}
Enum = setmetatable({}, {
	__index = function(_, category)
		return setmetatable({}, {
			__index = function(_, key)
				local cacheKey = tostring(category) .. "." .. tostring(key)
				local item = enumCache[cacheKey]
				if not item then
					item = tag({ Category = category, Name = key }, "EnumItem")
					enumCache[cacheKey] = item
				end
				return item
			end,
		})
	end,
})

----------------------------------------------------------------------
-- instances and signals
----------------------------------------------------------------------

local InstanceMethods = {}

-- Minimal class hierarchy, enough for the IsA("BasePart") checks the hub makes.
local CLASS_PARENTS = {
	Part = "BasePart",
	MeshPart = "BasePart",
	WedgePart = "BasePart",
	TrussPart = "BasePart",
	BasePart = "PVInstance",
	Model = "PVInstance",
	Humanoid = "Instance",
	Player = "Instance",
	Frame = "GuiObject",
	TextLabel = "GuiObject",
}

function InstanceMethods:IsA(className)
	return self.ClassName == className or CLASS_PARENTS[self.ClassName] == className
end

function InstanceMethods:Destroy()
	self._destroyed = true
	local parent = rawget(self, "Parent")
	if parent and parent._children then
		for index, child in ipairs(parent._children) do
			if child == self then
				table.remove(parent._children, index)
				break
			end
		end
	end
end

function InstanceMethods:GetDescendants()
	return self._children or {}
end

function InstanceMethods:GetChildren()
	return self._children or {}
end

function InstanceMethods:FindFirstChild(name)
	for _, child in ipairs(self._children or {}) do
		if child.Name == name then
			return child
		end
	end
	return nil
end

function InstanceMethods:FindFirstChildOfClass(className)
	for _, child in ipairs(self._children or {}) do
		if child.ClassName == className then
			return child
		end
	end
	return nil
end

function InstanceMethods:WaitForChild(name)
	return self:FindFirstChild(name)
end

local InstanceMeta = {
	__index = InstanceMethods,
	__newindex = function(self, key, value)
		if key == "Parent" then
			local old = rawget(self, "Parent")
			if old and old._children then
				for index, child in ipairs(old._children) do
					if child == self then
						table.remove(old._children, index)
						break
					end
				end
			end
			rawset(self, "Parent", value)
			if value and value._children then
				table.insert(value._children, self)
			end
			return
		end
		rawset(self, key, value)
	end,
}

Instance = {}

function Instance.new(className)
	local instance = tag({ ClassName = className, Name = className, _children = {} }, "Instance")
	return setmetatable(instance, InstanceMeta)
end

local function newSignal()
	local signal = {}
	signal._handlers = {}
	function signal:Connect(fn)
		local connection = tag({ fn = fn, connected = true }, "RBXScriptConnection")
		function connection:Disconnect()
			self.connected = false
		end
		table.insert(self._handlers, connection)
		return connection
	end
	-- Roblox reports an error inside a connection to the console and leaves the
	-- connection alive, so the mock does the same instead of letting one bad
	-- callback take the whole chunk down.
	function signal:Fire(...)
		for _, connection in ipairs(self._handlers) do
			if connection.connected then
				local ok, err = pcall(connection.fn, ...)
				if not ok then
					table.insert(harness.connectionErrors, tostring(err))
				end
			end
		end
	end
	return signal
end

----------------------------------------------------------------------
-- services
----------------------------------------------------------------------

local UserId = 424242
local PlayerGui = Instance.new("PlayerGui")

local humanoid = Instance.new("Humanoid")
humanoid.WalkSpeed = 16
humanoid.PlatformStand = false
humanoid.ChangeState = function() end

local rootPart = Instance.new("Part")
rootPart.Name = "HumanoidRootPart"

local character = Instance.new("Model")
character.Name = "MockCharacter"
local function inCharacter(className, name)
	if className == "Humanoid" then
		return humanoid
	end
	if name == "HumanoidRootPart" then
		return rootPart
	end
	return nil
end
character.FindFirstChildOfClass = function(_, className)
	return inCharacter(className, nil)
end
character.FindFirstChild = function(_, name)
	return inCharacter(nil, name)
end

-- something for noclip to actually touch
local torso = Instance.new("Part")
torso.Name = "Torso"
torso.CanCollide = true
torso.Parent = character

local CharacterAdded = newSignal()

local LocalPlayer = Instance.new("Player")
LocalPlayer.UserId = UserId
LocalPlayer.Character = character
LocalPlayer.CharacterAdded = CharacterAdded
LocalPlayer.FindFirstChild = function(_, name)
	if name == "PlayerGui" then
		return PlayerGui
	end
	return nil
end
LocalPlayer.WaitForChild = LocalPlayer.FindFirstChild

local RenderStepped = newSignal()
local Stepped = newSignal()
local HeartbeatSignal = newSignal()
local InputBegan = newSignal()

local camera = Instance.new("Camera")
camera.CFrame = { LookVector = Vector3.new(0, 0, -1), RightVector = Vector3.new(1, 0, 0) }

workspace = { CurrentCamera = camera }

local Players = {
	LocalPlayer = LocalPlayer,
	GetPlayerFromCharacter = function()
		return LocalPlayer
	end,
}

local RunService = {
	RenderStepped = RenderStepped,
	Stepped = Stepped,
	Heartbeat = HeartbeatSignal,
	IsStudio = function()
		return false
	end,
}

local UserInputService = {
	InputBegan = InputBegan,
	IsKeyDown = function()
		return false
	end,
}

local StatsService = {
	Network = {
		ServerStatsItem = {
			["Data Ping"] = {
				GetValue = function()
					-- environments differ: sometimes this is not a number at all
					if harness.statsGarbage then
						return {}
					end
					return 42.6
				end,
			},
		},
	},
	GetTotalMemoryUsageMb = function()
		if harness.statsGarbage then
			return nil
		end
		return 512.4
	end,
}

local services = {
	Players = Players,
	RunService = RunService,
	UserInputService = UserInputService,
	Stats = StatsService,
}

game = {
	PlaceId = 12345,
	JobId = "mock-job",
	CreatorId = AS_OWNER and UserId or 999999,
	CreatorType = Enum.CreatorType.User,
	HttpGet = function(_, url)
		if url == "https://sirius.menu/gen2" then
			return "return __secreteRayfieldMock"
		end
		-- the hub's uptime monitor: counted, and failable on demand
		if type(url) == "string" and url:find("/api/heartbeat/", 1, true) then
			harness.heartbeatPings = harness.heartbeatPings + 1
			if harness.heartbeatFails then
				error("heartbeat endpoint unreachable")
			end
			return '{"ok":true}'
		end
		-- one synthetic pack, so the fetch/cache/offline path is exercised for
		-- real without duplicating a real pack's source in here
		local pack = type(url) == "string" and url:match("/modules/([%w%-_]+)%.lua$")
		if pack then
			harness.packFetches[pack] = (harness.packFetches[pack] or 0) + 1
			if harness.packOffline then
				error("pack fetch blocked")
			end
			-- a real pack file, inlined by run.sh
			local real = __harnessPackSources and __harnessPackSources[pack]
			if real then
				return real
			end
			if pack == "selftest" then
				return "return function(Secrete) __harness.selfTestPack = Secrete ~= nil end"
			end
			if pack == "badpack" then
				return "return 42"
			end
			error("unexpected pack fetch: " .. pack)
		end
		error("unexpected fetch: " .. tostring(url))
	end,
	GetService = function(_, name)
		local service = services[name]
		if not service then
			error("unmocked service: " .. tostring(name))
		end
		return service
	end,
}

harness.humanoid = humanoid
harness.rootPart = rootPart
harness.characterAdded = CharacterAdded

-- A respawn: new humanoid, new root, and the old body is gone.
function harness.respawn()
	local nextHumanoid = Instance.new("Humanoid")
	nextHumanoid.WalkSpeed = 16
	nextHumanoid.PlatformStand = false
	nextHumanoid.ChangeState = function() end

	local nextRoot = Instance.new("Part")
	nextRoot.Name = "HumanoidRootPart"

	local nextCharacter = Instance.new("Model")
	nextCharacter.Name = "RespawnedCharacter"
	nextCharacter.FindFirstChildOfClass = function(_, className)
		if className == "Humanoid" then
			return nextHumanoid
		end
		return nil
	end
	nextCharacter.FindFirstChild = function(_, name)
		if name == "HumanoidRootPart" then
			return nextRoot
		end
		return nil
	end

	local nextTorso = Instance.new("Part")
	nextTorso.Name = "Torso"
	nextTorso.CanCollide = true
	nextTorso.Parent = nextCharacter

	LocalPlayer.Character = nextCharacter
	harness.humanoid2 = nextHumanoid
	harness.rootPart2 = nextRoot
	CharacterAdded:Fire(nextCharacter)
	return nextCharacter
end
harness.renderStepped = RenderStepped
harness.stepped = Stepped
harness.heartbeatSignal = HeartbeatSignal
harness.inputBegan = InputBegan
harness.userId = UserId

----------------------------------------------------------------------
-- executor surface
----------------------------------------------------------------------

local disk = harness.disk
local warnings = harness.warnings
local genv = harness.genv

function writefile(path, contents)
	disk[path] = contents
	return true
end

function readfile(path)
	local contents = disk[path]
	if contents == nil then
		error("no such file: " .. tostring(path))
	end
	return contents
end

function isfile(path)
	return disk[path] ~= nil
end

function makefolder(path)
	disk["dir:" .. path] = true
end

function isfolder(path)
	return disk["dir:" .. path] == true
end

function delfile(path)
	disk[path] = nil
end

-- Packs come from disk here: the hub asks this hook instead of the network.
-- run.sh inlines each pack file's source into __harnessPackSources, so the hook
-- compiles it the same way the hub does and the real pack files stay the only
-- copy of that code.
shared = {
	SecretePackLoader = function(name)
		table.insert(harness.packHookCalls, name)
		local source = __harnessPackSources[name]
		if not source then
			return nil, "no such pack"
		end
		local chunk = loadstring(source)
		if type(chunk) ~= "function" then
			return nil, "did not compile"
		end
		local ok, module = pcall(chunk)
		if not ok or type(module) ~= "function" then
			return nil, tostring(module)
		end
		return module
	end,
}

function identifyexecutor()
	return "mock-executor"
end

function getgenv()
	return genv
end

function gethui()
	return Instance.new("Folder")
end

warn = function(...)
	local parts = {}
	for index = 1, select("#", ...) do
		parts[index] = tostring(select(index, ...))
	end
	table.insert(warnings, table.concat(parts, " "))
end

----------------------------------------------------------------------
-- rayfield mock
----------------------------------------------------------------------

local function makeHandle(kind, props)
	props = props or {}
	local handle = tag({
		kind = kind,
		name = props.name,
		value = props.value,
		props = props,
		locked = false,
		stub = false,
	}, "ElementHandle")

	function handle:Set(value, silent)
		self.value = value
		if not silent and type(self.props.callback) == "function" then
			self.props.callback(value)
		end
	end
	function handle:Lock(reason)
		self.locked = true
		self.lockReason = reason
	end
	function handle:Unlock()
		self.locked = false
	end
	function handle:Fire()
		if type(self.props.callback) == "function" then
			self.props.callback()
		end
	end
	return handle
end

local ELEMENT_KINDS = {
	"Toggle", "Slider", "Dropdown", "Input", "Keybind", "ColorPicker",
	"Button", "Stat", "Progress", "Console", "Text", "Divider",
}

local function makeTab(name, icon)
	local tab = tag({ name = name, icon = icon, elements = {} }, "Tab")

	for _, kind in ipairs(ELEMENT_KINDS) do
		-- a build that does not offer this element kind at all
		if not harness.missingKinds[kind] then
			tab["Create" .. kind] = function(_, props)
				local handle = makeHandle(kind, props)
				handle.tab = tab
				table.insert(tab.elements, handle)
				table.insert(harness.created.elements, handle)
				return handle
			end
		end
	end
	tab.Select = function() end
	tab.Remove = function() end

	table.insert(harness.created.tabs, tab)
	return tab
end

local windowLog = harness.windowLog

__secreteRayfieldMock = {
	CreateWindow = function(_, props)
		local window = tag({ props = props, tabs = {}, sections = {} }, "Window")
		window.Flags = {}
		window.CreateTab = function(_, tabProps)
			local tab = makeTab(tabProps.name, tabProps.icon)
			table.insert(window.tabs, tab)
			return tab
		end
		window.CreateSection = function(_, sectionProps)
			table.insert(window.sections, sectionProps.name)
		end
		window.Notify = function()
			windowLog.notifications = windowLog.notifications + 1
		end
		window.ToggleHide = function()
			windowLog.hidden = windowLog.hidden + 1
		end
		window.Unload = function()
			windowLog.unloaded = true
		end
		harness.window = window
		return window
	end,
}
