--[[
	Universal pack — modules that make sense wherever the hub runs.

	A pack is a file that returns `function(Secrete) ... end`: the hub fetches
	it (or loads it from the cache), calls it once, and everything it registers
	through Secrete.CreateModule appears in the window.
]]

return function(Secrete)
	local Gui = Secrete.Gui
	local Store = Secrete.Store
	local Heartbeat = Secrete.Heartbeat

	local RunService = game:GetService("RunService")
	local StatsService = game:GetService("Stats")

	-- Visuals: your own client's numbers, nothing about anyone else.
	Secrete.CreateModule({
		Name = "Stats Overlay",
		Description = "FPS, ping and memory for your own client.",
		Tab = "Visuals",
		Icon = 93364949241311,

		-- The Stats service is not consistent across environments: it can hand
		-- back a non-number without raising, so read it through here instead of
		-- formatting blind.
		Measure = function(_, fn)
			local ok, value = pcall(fn)
			if not ok or type(value) ~= "number" then
				return nil
			end
			return value
		end,

		Init = function(self)
			self.options.refresh = 2
			self:Element("Slider", {
				name = "Refresh rate",
				description = "Seconds between samples.",
				flag = "refresh",
				range = { 1, 10 },
				value = 2,
			})
		end,

		-- Built once. The registry destroys the surface when this disables.
		OnEnable = function(self)
			local panel = Gui.Panel(self:Surface("secreteStats"))
			self.lines = {
				fps = Gui.Line(panel, 1),
				ping = Gui.Line(panel, 2),
				memory = Gui.Line(panel, 3),
				place = Gui.Line(panel, 4),
			}
			self.lines.place.Text = ("place    %d"):format(game.PlaceId)
			self.frames = 0
			self.elapsed = 0

			self:Track(RunService.RenderStepped:Connect(function(dt)
				if not self.lines then
					return
				end
				self.frames = self.frames + 1
				self.elapsed = self.elapsed + dt
				local interval = math.max(tonumber(self.options.refresh) or 2, 1)
				if self.elapsed < interval then
					return
				end

				local fps = self.frames / self.elapsed
				self.frames = 0
				self.elapsed = 0

				local ping = self:Measure(function()
					return StatsService.Network.ServerStatsItem["Data Ping"]:GetValue()
				end)
				local memory = self:Measure(function()
					return StatsService:GetTotalMemoryUsageMb()
				end)

				self.lines.fps.Text = ("fps      %d"):format(math.floor(fps + 0.5))
				self.lines.ping.Text = ("ping     %s"):format(
					ping and ("%d ms"):format(math.floor(ping + 0.5)) or "n/a"
				)
				self.lines.memory.Text = ("memory   %s"):format(
					memory and ("%d MB"):format(math.floor(memory + 0.5)) or "n/a"
				)
			end))
		end,

		OnDisable = function(self)
			self.lines = nil
		end,
	})

	-- Visuals: a crosshair you draw yourself. Cosmetic, client-side, yours.
	Secrete.CreateModule({
		Name = "Crosshair",
		Description = "A crosshair drawn on your own screen.",
		Tab = "Visuals",

		Init = function(self)
			self.options.dot = true
			self.options.gap = 6
			self.options.length = 10
			self.options.thickness = 2
			self.options.color = Color3.fromRGB(255, 255, 255)

			self:Element("Toggle", { name = "Centre dot", flag = "dot", value = true })
			self:Element("Slider", { name = "Gap", flag = "gap", range = { 0, 40 }, value = 6 })
			self:Element("Slider", { name = "Length", flag = "length", range = { 2, 40 }, value = 10 })
			self:Element("Slider", { name = "Thickness", flag = "thickness", range = { 1, 6 }, value = 2 })

			-- Builds differ on which key carries the picker's starting colour, so
			-- try `color` and fall back to `value`. `normalize` keeps whatever
			-- shape the picker hands back out of the option table.
			local props = {
				name = "Colour",
				flag = "color",
				color = self.options.color,
				normalize = function(value)
					return Secrete.Util.AsColor(value, self.options.color)
				end,
			}
			if self:Element("ColorPicker", props).stub then
				props.color = nil
				props.value = self.options.color
				self:Element("ColorPicker", props)
			end
		end,

		OnEnable = function(self)
			local gui = self:Surface("secreteCrosshair")
			self.bars = {
				left = Gui.Frame(gui),
				right = Gui.Frame(gui),
				top = Gui.Frame(gui),
				bottom = Gui.Frame(gui),
			}
			self.dot = Gui.Frame(gui)
			self:Apply()
		end,

		-- Writes straight into the frames it already has: rebuilding the whole
		-- screen per slider tick is what made this flicker.
		Apply = function(self)
			if not self.bars then
				return
			end
			local thickness = math.max(tonumber(self.options.thickness) or 2, 1)
			local length = math.max(tonumber(self.options.length) or 10, 1)
			local gap = math.max(tonumber(self.options.gap) or 0, 0)
			local color = self.options.color or Color3.fromRGB(255, 255, 255)

			local left, right = self.bars.left, self.bars.right
			local top, bottom = self.bars.top, self.bars.bottom

			-- AnchorPoint (1, 0.5) means "this frame's right edge sits here",
			-- which is what keeps the arms symmetric around the centre.
			left.Size = UDim2.fromOffset(length, thickness)
			left.Position = UDim2.new(0.5, -gap, 0.5, 0)
			left.AnchorPoint = Vector2.new(1, 0.5)

			right.Size = UDim2.fromOffset(length, thickness)
			right.Position = UDim2.new(0.5, gap, 0.5, 0)
			right.AnchorPoint = Vector2.new(0, 0.5)

			top.Size = UDim2.fromOffset(thickness, length)
			top.Position = UDim2.new(0.5, 0, 0.5, -gap)
			top.AnchorPoint = Vector2.new(0.5, 1)

			bottom.Size = UDim2.fromOffset(thickness, length)
			bottom.Position = UDim2.new(0.5, 0, 0.5, gap)
			bottom.AnchorPoint = Vector2.new(0.5, 0)

			for _, bar in ipairs({ left, right, top, bottom }) do
				bar.BackgroundColor3 = color
			end

			self.dot.Size = UDim2.fromOffset(thickness, thickness)
			self.dot.Position = UDim2.new(0.5, 0, 0.5, 0)
			self.dot.AnchorPoint = Vector2.new(0.5, 0.5)
			self.dot.BackgroundColor3 = color
			self.dot.Visible = self.options.dot == true
		end,
	})

	-- Settings: the hub's own switches.
	Secrete.CreateModule({
		Name = "Hub Settings",
		Description = "Heartbeat, saved state and panic.",
		Tab = "Settings",

		Init = function(self)
			self.heartbeatToggle = self:Element("Toggle", {
				name = "Sentivel heartbeat",
				description = "Pings the uptime monitor while the hub is running.",
				flag = "heartbeat",
				value = true,
				callback = function(value)
					if value ~= true then
						Heartbeat:Stop()
						return
					end
					-- Availability decides, not Start()'s return: that is false both
					-- when there is no HTTP and when the heartbeat is already running,
					-- and treating the second case as failure would switch the UI off
					-- while the pings carry on.
					if Heartbeat:Available() then
						Heartbeat:Start()
						return
					end
					if self.heartbeatToggle then
						pcall(function()
							self.heartbeatToggle:Set(false, true)
						end)
					end
				end,
			})

			self:Element("Divider", {})
			self:Element("Button", {
				name = "Forget module state",
				callback = function()
					Store.Clear()
					Secrete.UI.Notify({
						title = "Cleared",
						content = "Module on/off state reset for this place.",
					})
				end,
			})
			self:Element("Button", {
				name = "Panic (disable all, unload)",
				callback = function()
					Secrete.Panic()
				end,
			})
		end,
	})
end
