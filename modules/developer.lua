--[[
	Developer pack — movement debugging, and only where the place is yours.

	The gate is checked again at enable time, so being handed this file (or
	loading it in someone else's game) does not unlock anything.
]]

return function(Secrete)
	local Util = Secrete.Util

	local Players = game:GetService("Players")
	local RunService = game:GetService("RunService")
	local UserInputService = game:GetService("UserInputService")
	local LocalPlayer = Players.LocalPlayer

	Secrete.CreateModule({
		Name = "Developer Tools",
		Description = "Movement debugging for a place you own.",
		Tab = "Developer",

		Init = function(self)
			self.options.speed = 16
			self.options.flySpeed = 60
			self.options.fly = false
			self.options.noclip = false

			self:Element("Text", {
				name = "Locked unless you own the place",
				body = "These toggles only affect your own character, and they refuse to "
					.. "run in a place you do not own or co-own.",
			})
			self:Element("Slider", {
				name = "Walk speed",
				flag = "speed",
				range = { 16, 200 },
				value = 16,
			})
			self:Element("Toggle", { name = "Fly", flag = "fly", value = false })
			self:Element("Slider", {
				name = "Fly speed",
				flag = "flySpeed",
				range = { 10, 300 },
				value = 60,
			})
			self:Element("Toggle", { name = "Noclip", flag = "noclip", value = false })

			if not Secrete.Capabilities.ownsPlace and self.toggleHandle then
				pcall(function()
					self.toggleHandle:Lock("Only available in your own place")
				end)
			end
		end,

		Character = function(self)
			local character = LocalPlayer.Character
			if not character then
				return nil, nil, nil
			end
			local humanoid = character:FindFirstChildOfClass("Humanoid")
			local root = character:FindFirstChild("HumanoidRootPart") or character.PrimaryPart
			return character, humanoid, root
		end,

		Apply = function(self)
			if not self.Enabled then
				return
			end
			local _, humanoid = self:Character()
			if humanoid then
				humanoid.WalkSpeed = tonumber(self.options.speed) or 16
			end

			if self.options.noclip == true and not self.noclipConnection then
				self.noclipConnection = RunService.Stepped:Connect(function()
					local character = LocalPlayer.Character
					if not character then
						return
					end
					for _, part in ipairs(character:GetDescendants()) do
						if part:IsA("BasePart") and part.CanCollide then
							part.CanCollide = false
							self.touchedParts[part] = true
						end
					end
				end)
				self:Track(self.noclipConnection)
			elseif self.options.noclip ~= true and self.noclipConnection then
				self:StopNoclip()
			end

			if self.options.fly == true then
				self:StartFly()
			else
				self:StopFly()
			end
		end,

		StopNoclip = function(self)
			if self.noclipConnection then
				pcall(function()
					self.noclipConnection:Disconnect()
				end)
				self.noclipConnection = nil
			end
			for part in pairs(self.touchedParts) do
				pcall(function()
					part.CanCollide = true
				end)
			end
			table.clear(self.touchedParts)
		end,

		StartFly = function(self)
			if self.flyVelocity then
				return
			end
			local _, humanoid, root = self:Character()
			if not (humanoid and root) then
				return
			end

			humanoid.PlatformStand = true
			humanoid:ChangeState(Enum.HumanoidStateType.Physics)

			local velocity = Instance.new("BodyVelocity")
			velocity.Name = "secreteFly"
			velocity.MaxForce = Vector3.new(9e9, 9e9, 9e9)
			velocity.P = 1250
			velocity.Velocity = Vector3.zero
			velocity.Parent = root
			self.flyVelocity = velocity

			self.flyConnection = self:Track(RunService.RenderStepped:Connect(function()
				local _, currentHumanoid, currentRoot = self:Character()
				if not (currentHumanoid and currentRoot) or not self.flyVelocity then
					return
				end
				local camera = workspace.CurrentCamera
				if not camera then
					return
				end

				local direction = Vector3.zero
				if UserInputService:IsKeyDown(Enum.KeyCode.W) then
					direction = direction + camera.CFrame.LookVector
				end
				if UserInputService:IsKeyDown(Enum.KeyCode.S) then
					direction = direction - camera.CFrame.LookVector
				end
				if UserInputService:IsKeyDown(Enum.KeyCode.D) then
					direction = direction + camera.CFrame.RightVector
				end
				if UserInputService:IsKeyDown(Enum.KeyCode.A) then
					direction = direction - camera.CFrame.RightVector
				end
				if UserInputService:IsKeyDown(Enum.KeyCode.Space) then
					direction = direction + Vector3.yAxis
				end
				if UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) then
					direction = direction - Vector3.yAxis
				end

				local speed = tonumber(self.options.flySpeed) or 60
				if direction.Magnitude > 0 then
					direction = direction.Unit * speed
				end
				self.flyVelocity.Velocity = direction
			end))
		end,

		StopFly = function(self)
			if self.flyVelocity then
				pcall(function()
					self.flyVelocity:Destroy()
				end)
				self.flyVelocity = nil
			end
			local _, humanoid = self:Character()
			if humanoid then
				pcall(function()
					humanoid.PlatformStand = false
					humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
				end)
			end
			-- Only the fly loop goes away here: the noclip loop is its own toggle
			-- and must survive a fly toggle in either direction.
			if self.flyConnection then
				pcall(function()
					self.flyConnection:Disconnect()
				end)
				self.flyConnection = nil
			end
		end,

		OnEnable = function(self)
			self.touchedParts = {}
			if not Secrete.Capabilities.ownsPlace then
				Util.Warn("Developer Tools refused: this place belongs to someone else")
				self.Enabled = false
				return
			end
			-- A respawn replaces the humanoid and the root, so re-apply from the
			-- options: without this the sliders still read 120 while the new body
			-- walks at 16, and fly holds a destroyed handle and quietly stops.
			self:Track(LocalPlayer.CharacterAdded:Connect(function()
				self.touchedParts = {}
				self:StopFly()
				self:Apply()
			end))
			self:Apply()
		end,

		OnDisable = function(self)
			self:StopFly()
			self:StopNoclip()
			local _, humanoid = self:Character()
			if humanoid then
				humanoid.WalkSpeed = 16
			end
		end,
	})
end
