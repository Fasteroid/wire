AddCSLuaFile()
DEFINE_BASECLASS( "base_wire_entity" )
ENT.PrintName		= "Wire LED Tape Controller"
ENT.WireDebugName 	= "LED Tape"

function ENT:SharedInit()
	self.Color = Color(255,255,255)
	self.Path  = {}
end

Wire_LEDTape = Wire_LEDTape or {}

Wire_LEDTape.MaxPoints = 256
Wire_LEDTape.NumBits   = math.ceil( math.log(Wire_LEDTape.MaxPoints, 2) )

if CLIENT then

	-- TODO: move this into modelplug after the cleanup PR gets accepted

	--[[
		name	= tooltip to display in the spawnmenu ........................ (required)
		sprite	= path to 3x width sprite material ........................... (optional)
		scale	= scaled texture height divided by original texture height ... (required with sprite)
		backlit = draw fullbright base texture even when using a sprite? ..... (optional)
		connect = connect the beams in the sprite texture? ................... (optional)
	]]--

	Wire_LEDTape.materialData = {
		["fasteroid/ledtape01"] = {
			name   = "5050 Sparse",
			sprite = "fasteroid/ledtape01_sprite",
			scale  = 512 / 904
		},
		["fasteroid/ledtape02"] = {
			name   = "5050 Dense",
			sprite = "fasteroid/ledtape02_sprite",
			scale  = 512 / 434
		},
		["cable/white"] = {
			name = "White Cable"
		},
		["arrowire/arrowire2"] = {
			name = "Glowing Arrows",
		},
		["fasteroid/elwire"] = {
			name   = "Electroluminescent Wire",
			sprite = "fasteroid/elwire_sprite",
			scale  = 256 / 2048,
			backlit = true
		},
	}

	local DEFAULT_SCALE = 0.5

	local LIGHT_UPDATE_INTERVAL = CreateClientConVar( "wire_ledtape_lightinterval", "0.5", true, false, "How often environmental lighting on LED tape is calculated", 0 )

	local LIGHT_DIRECTIONS = {
		Vector(1,0,0),
		Vector(-1,0,0),
		Vector(0,1,0),
		Vector(0,-1,0),
		Vector(0,0,1),
		Vector(0,0,-1)
	}

	local function getLitNodeColor(node)
		if not node.lighting or node.nextlight < CurTime() then
			local lightsum = Vector()
			local pos = node[1]:LocalToWorld( node[2] )
			for _, dir in ipairs(LIGHT_DIRECTIONS) do
				lightsum:Add( render.ComputeLighting(pos, dir) )
			end
			lightsum:Mul( 1 / #LIGHT_DIRECTIONS )
			node.lighting = lightsum:ToColor()
			node.nextlight = CurTime() + LIGHT_UPDATE_INTERVAL:GetFloat()
		end
		return node.lighting
	end


	-- This system prevents calling LocalToWorld hundreds of times every frame, as it strains the garbage collector.
	-- This is a necessary evil to prevent stuttering.
	local LocalToWorld_NoGarbage_Ents = {}

	local function LocalToWorld_NoGarbage(ent, pos)
		local LEDTapeVecs = ent.LEDTapeVecs
		if not LEDTapeVecs then LEDTapeVecs = {} ent.LEDTapeVecs = LEDTapeVecs end

		local oldval = LEDTapeVecs[pos]
		if oldval and ent.LEDTapeLastPos == ent:GetPos() and ent.LEDTapeLastAng == ent:GetAngles() then
			return oldval
		end

		LEDTapeVecs[pos] = ent:LocalToWorld(pos)
		LocalToWorld_NoGarbage_Ents[ent] = true -- update positions at the end

		return LEDTapeVecs[pos]
	end

	local function LocalToWorld_NoGarbage_End()
		for ent, _ in pairs(LocalToWorld_NoGarbage_Ents) do
			if IsValid(ent) then
				ent.LEDTapeLastPos = ent:GetPos()
				ent.LEDTapeLastAng = ent:GetAngles()
			end
		end
		LocalToWorld_NoGarbage_Ents = {}
	end

	hook.Add("PlayerPostThink", "LEDTapeCleanup", LocalToWorld_NoGarbage_End)

	local function calcBeams(width, scrollmul, mater, path, getColor, extravertex)
		if not IsValid(path[1][1]) then return end

		local scroll = 0

		scrollmul = scrollmul / width -- scale this

		local cache = {}
		cache[-1] = mater
		cache[-2] = width

		local node1 = path[1]

		local pt1 = LocalToWorld_NoGarbage(node1[1], node1[2])

		cache[1] = { pt1, scroll, getColor(node1) }

		local idx = 2
		for i = 2, #path do
			local node2 = path[i]
			local nodeEnt = node2[1]
			if IsValid(nodeEnt) then
				local nodeOffset = node2[2]

				local pt2 = LocalToWorld_NoGarbage(nodeEnt, nodeOffset)
				local distance = pt2:Distance(pt1) * scrollmul * 0.5

				cache[idx] = { pt1, scroll, getColor(node1) }
				idx = idx + 1
				scroll = scroll + distance

				cache[idx] = { pt2, scroll, getColor(node2) }
				idx = idx + 1
				if extravertex then
					cache[idx] = { pt2, scroll, getColor(node2) }
					idx = idx + 1
				end

				pt1 = pt2
				node1 = node2
			end
		end

		cache[idx] = { pt1, scroll, getColor(node1) }

		cache[0] = idx

		return cache
	end

	local beam = render.AddBeam
	local function drawBeams(cache)
		if not cache then return end

		local len = cache[0]
		local width = cache[-2]

		render.SetMaterial(cache[-1])
		render.StartBeam(len)

		for _, node in ipairs(cache) do
			beam(node[1], width, node[2], node[3])
		end

		render.EndBeam()
		return cache[#cache][1]
	end

	-- Yeah sorry I gave up on these

	local function drawShaded(width, scrollmul, mater, path)
		return calcBeams(width, scrollmul, mater, path, getLitNodeColor)
	end
	Wire_LEDTape.DrawShaded = drawShaded

	local function drawFullbright(width, scrollmul, color, mater, path, extravert)
		return calcBeams(width, scrollmul, mater, path, function() return color end, extravert)
	end
	Wire_LEDTape.DrawFullbright = drawFullbright

	local function recalcBeams(self)
		local color = self.Color
		local colorfunc = function() return color end
		if self.SpriteMaterial then
			if self.Backlit then
				self.LEDCache = calcBeams(self.Width, self.ScrollMul / 3, self.BaseMaterial, self.Path, colorfunc, false)
			else
				self.LEDCache = calcBeams(self.Width, self.ScrollMul / 3, self.BaseMaterial, self.Path, getLitNodeColor, false)
			end
			self.LEDSpriteCache = calcBeams(self.Width * 3, self.ScrollMul, self.SpriteMaterial, self.Path, colorfunc, false)
		else
			self.LEDCache = calcBeams(self.Width, self.ScrollMul, self.BaseMaterial, self.Path, colorfunc, false)
		end
	end

	local function draw_spr(self)
		drawBeams(self.LEDCache)
		drawBeams(self.LEDSpriteCache)
	end
	local function draw_nospr(self)
		drawBeams(self.LEDCache)
	end

	function ENT:Initialize()
		self:SharedInit()
		self.ScrollMul = DEFAULT_SCALE

		net.Start("LEDTapeData")
			net.WriteEntity(self)
			net.WriteBool(true) -- request full update
		net.SendToServer()

		self:SetOverlayText("LED Tape Controller")
	end

	function ENT:Think()
		self.Color.r = self:GetNW2Int("LedTape_R")
		self.Color.g = self:GetNW2Int("LedTape_G")
		self.Color.b = self:GetNW2Int("LedTape_B")

		-- Could maybe be opt better
		if self.Path[1] then recalcBeams(self) end
	end

	net.Receive("LEDTapeData", function()
		local controller = net.ReadEntity()
		if not controller:IsValid() or controller:GetClass() ~= "gmod_wire_ledtape" then return end

		local full = net.ReadBool()

		local width = net.ReadFloat()
		controller.Width = width
		local mater = net.ReadString()

		local basemat = Material(mater)
		controller.BaseMaterial = basemat

		local metadata = Wire_LEDTape.materialData[mater]

		local sprite = metadata.sprite and Material(metadata.sprite)
		controller.SpriteMaterial = sprite
		local scrollmul = metadata.scale or DEFAULT_SCALE
		controller.ScrollMul = scrollmul
		local connect = metadata.connect or false
		controller.Connect = connect
		local backlit = metadata.backlit or false
		controller.Backlit = backlit

		if full then
			local pathLength = net.ReadUInt(Wire_LEDTape.NumBits) + 1
			for _ = 1, pathLength do
				table.insert(controller.Path,{net.ReadEntity(), net.ReadVector()})
			end
		end

		recalcBeams(controller)

		if #controller.Path > 1 then
			local drawfunc

			if sprite then
				drawfunc = draw_spr
			else
				drawfunc = draw_nospr
			end

			hook.Add("PostDrawOpaqueRenderables", controller, function()
				drawfunc(controller)
			end)
		else
			hook.Remove("PostDrawOqueRenderables", controller)
		end

		controller:SetOverlayText("LED Tape Controller\n(" .. (#controller.Path - 1) .. " Segments)")

	end)

end


if SERVER then

	util.AddNetworkString("LEDTapeData")
	net.Receive("LEDTapeData", function(len, ply)
		local controller = net.ReadEntity()
		local full       = net.ReadBool()
		if not IsValid(controller) then return end
		table.insert(controller.DownloadQueue, {ply = ply, full = full})
	end )

	function ENT:Initialize()
		BaseClass.Initialize(self)
		WireLib.CreateInputs(self, {
			"Color [VECTOR]"
		})
		self:SharedInit()
		self.DownloadQueue = {}
	end

	function ENT:SendMaterialUpdate()
		net.WriteFloat  ( self.Width )
		net.WriteString ( self.BaseMaterial )
	end

	function ENT:SendFullUpdate()
		self:SendMaterialUpdate()
		net.WriteUInt(#self.Path - 1, Wire_LEDTape.NumBits)
		for k, node in ipairs(self.Path) do
			net.WriteEntity(node[1])
			net.WriteVector(node[2])
		end
	end

	function ENT:Think()

		if self.BaseMaterial and self.Width and self.Path then -- don't send updates with nil stuff!
			for _, request in ipairs(self.DownloadQueue) do
				net.Start("LEDTapeData")

					net.WriteEntity( self )
					net.WriteBool(request.full)

					if request.full then self:SendFullUpdate()
					else self:SendMaterialUpdate() end

				net.Send(request.ply)
			end
			self.DownloadQueue = {}
		end

		BaseClass.Think( self )
		self:NextThink(CurTime() + 0.05)
		return true
	end

	-- duplicator support
	function ENT:BuildDupeInfo()
		local info = BaseClass.BuildDupeInfo(self) or {}
			info.BaseMaterial = self.BaseMaterial
			info.Width    = self.Width
			info.Path     = {}
			for k, node in ipairs(self.Path) do
				info.Path[k] = {node[1]:EntIndex(), node[2]}
			end
		return info
	end

	function ENT:ApplyDupeInfo(ply, ent, info, GetEntByID)
		BaseClass.ApplyDupeInfo(self, ply, ent, info, GetEntByID)
		self.BaseMaterial = info.BaseMaterial
		self.Width = info.Width
		self.Path = {}
		for k, node in ipairs(info.Path) do
			self.Path[k] = { GetEntByID(node[1], game.GetWorld()), node[2] }
		end
	end
	duplicator.RegisterEntityClass("gmod_wire_ledtape", WireLib.MakeWireEnt, "Data")

	function ENT:TriggerInput(iname, value)
		if (iname == "Color") then
			self:SetNW2Int("LedTape_R", value[1])
			self:SetNW2Int("LedTape_G", value[2])
			self:SetNW2Int("LedTape_B", value[3])
		end
	end

	function MakeWireLEDTapeController( pl, Pos, Ang, model, path, width, material )
		local controller = WireLib.MakeWireEnt(pl, {Class = "gmod_wire_ledtape", Pos = Pos, Angle = Ang, Model = model})
		if not IsValid(controller) then return end

		controller.Path = path
		controller.Width = math.Clamp(width,0.1,4)
		controller.BaseMaterial = material

		return controller
	end

end


