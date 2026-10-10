-- pastewiki/convoylol

local Players = game:GetService("Players") 
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService") 
local PhysicsService = game:GetService("PhysicsService") 
local ReplicatedStorage = game:GetService("ReplicatedStorage") 

--------------------------------------------------------------------------------
-- 1. settings
--------------------------------------------------------------------------------

local config = {
	tag = "Furniture", -- furniture with this tag can be picked up
	folderName = "Furniture", -- furniture inside this workspace folder can also be picked up
	reach = 12, -- how far away you can be to pick something up
	holdDistance = 5, -- how far in front of you the furniture stays
	minDistance = 3, -- keeps furniture from getting too close when a wall is in the way
	snapDistance = 1.5, -- places furniture on a surface when it is close enough
	turnStep = math.rad(45), -- turns furniture by inputed degrees each time
	strength = 300, -- how strongly the furniture gets pulled toward you

	-- heavier furniture moves slower
	-- you can set the Weight attribute yourself, otherwise its size is used
	lightWeight = 10, -- furniture this light moves at full speed
	heavyWeight = 300, -- furniture this heavy moves much slower
	maxWeight = 400, -- one player cannot lift anything heavier than this
	maxHolders = 2, -- up to two players can carry the same item
	light = { follow = 25, maxSpeed = 40, turnSpeed = 40, walk = 1, jump = 1, sag = 0 }, -- light furniture is easy to move
	heavy = { follow = 6, maxSpeed = 12, turnSpeed = 6, walk = 0.45, jump = 0.2, sag = 2 }, -- heavy furniture is slower and hangs a little lower
	dropDistance = 15, -- drops the furniture if you get too far away
	useDelay = 0.2, -- time between e presses
	turnDelay = 0.08, -- stops furniture from turning too quickly
}

--------------------------------------------------------------------------------
-- 2. setup
--------------------------------------------------------------------------------

-- create collision groups if they do not exist yet
local function addCollisionGroup(name: string)
	if not PhysicsService:IsCollisionGroupRegistered(name) then
		PhysicsService:RegisterCollisionGroup(name)
	end
end

addCollisionGroup("Characters")
addCollisionGroup("Carried")

-- players and carried furniture can pass through each other
PhysicsService:CollisionGroupSetCollidable("Characters", "Carried", false)

-- keep all carry events in one folder
local remoteFolder = Instance.new("Folder")
remoteFolder.Name = "CarryRemotes"

local function makeRemote(name: string): RemoteEvent
	local remote = Instance.new("RemoteEvent")
	remote.Name = name
	remote.Parent = remoteFolder
	return remote
end

local useRemote = makeRemote("Use") -- press e to pick up or drop furniture
local aimRemote = makeRemote("Aim") -- tells the server where the player is looking
local turnRemote = makeRemote("Turn") -- handles furniture turning
local messageRemote = makeRemote("Message") -- sends messages to the player

remoteFolder.Parent = ReplicatedStorage

--------------------------------------------------------------------------------
-- 3. helper functions
--------------------------------------------------------------------------------

-- furniture can have the right tag or be inside the furniture folder
local function isFurniture(instance: Instance): boolean
	if CollectionService:HasTag(instance, config.tag) then
		return true
	end
	local parent = instance.Parent
	return parent ~= nil and parent.Parent == workspace and parent.Name == config.folderName
end

-- find the furniture model, even if the clicked part is deep inside it
local function findFurniture(instance: Instance): Instance?
	local current: Instance? = instance
	while current and current ~= workspace do
		if isFurniture(current) then
			return current
		end
		current = current.Parent
	end
	return nil
end

-- get every physical part inside the object
local function getParts(object: Instance): { BasePart }
	if object:IsA("BasePart") then
		return { object }
	end
	local parts = {}
	for _, child in object:GetDescendants() do
		if child:IsA("BasePart") then
			table.insert(parts, child)
		end
	end
	return parts
end

-- get the main part used to move the furniture
local function getRoot(object: Instance): BasePart?
	if object:IsA("BasePart") then
		return object
	elseif object:IsA("Model") then
		return object.PrimaryPart
	end
	return nil
end

-- get the furniture's position and size
local function getBox(object: Instance): (CFrame, Vector3)
	if object:IsA("Model") then
		return object:GetBoundingBox()
	end
	local part = object :: BasePart
	return part.CFrame, part.Size
end

-- find the distance from a point to the closest part of a box
local function distanceToBox(point: Vector3, boxCFrame: CFrame, size: Vector3): number
	local localPoint = boxCFrame:PointToObjectSpace(point)
	local half = size / 2
	local closest = Vector3.new(
		math.clamp(localPoint.X, -half.X, half.X),
		math.clamp(localPoint.Y, -half.Y, half.Y),
		math.clamp(localPoint.Z, -half.Z, half.Z)
	)
	return (localPoint - closest).Magnitude
end

-- find how far the furniture sticks out in a certain direction
local function getDepth(rotation: CFrame, size: Vector3, direction: Vector3): number
	local half = size / 2
	return math.abs(direction:Dot(rotation.RightVector)) * half.X
		+ math.abs(direction:Dot(rotation.UpVector)) * half.Y
		+ math.abs(direction:Dot(rotation.LookVector)) * half.Z
end

-- find the full size of the model, even if its parts are rotated
local function getWorldBox(parts: { BasePart }): (Vector3, Vector3)
	local low = Vector3.one * math.huge
	local high = -low
	for _, part in parts do
		local cframe = part.CFrame
		local half = part.Size / 2
		-- work out how far each part reaches along the world axes
		local reach = Vector3.new(
			math.abs(cframe.RightVector.X) * half.X + math.abs(cframe.UpVector.X) * half.Y + math.abs(cframe.LookVector.X) * half.Z,
			math.abs(cframe.RightVector.Y) * half.X + math.abs(cframe.UpVector.Y) * half.Y + math.abs(cframe.LookVector.Y) * half.Z,
			math.abs(cframe.RightVector.Z) * half.X + math.abs(cframe.UpVector.Z) * half.Y + math.abs(cframe.LookVector.Z) * half.Z
		)
		low = low:Min(cframe.Position - reach)
		high = high:Max(cframe.Position + reach)
	end
	return (low + high) / 2, high - low
end

-- work out how heavy the furniture is
local function getWeight(object: Instance): number
	local weight = object:GetAttribute("Weight")
	if typeof(weight) == "number" then
		return weight
	end
	local _, size = getBox(object)
	return size.X * size.Y * size.Z
end

-- turn the weight into a value between 0 and 1
local function getHeaviness(weight: number): number
	return math.clamp((weight - config.lightWeight) / (config.heavyWeight - config.lightWeight), 0, 1)
end

-- get a value between the light and heavy settings
local function byWeight(name: string, heaviness: number): number
	local light, heavy = config.light[name], config.heavy[name]
	return light + (heavy - light) * heaviness
end

-- get the weight label shown to the player
local function getWeightName(weight: number): string
	if weight > config.maxWeight * config.maxHolders then
		return "Too heavy"
	elseif weight > config.maxWeight then
		return "Needs two"
	elseif weight >= config.heavyWeight / 2 then
		return "Heavy"
	elseif weight >= config.heavyWeight / 10 then
		return "Medium"
	end
	return "Light"
end

-- get the furniture ready to be carried
local function prepare(object: Instance)
	if not (object:IsA("Model") or object:IsA("BasePart")) then
		return -- skip folders and other objects
	end
	if object:IsA("Model") then
		local parts = getParts(object)
		if #parts == 0 then
			return -- nothing to carry
		end
		-- make an invisible main part if the model does not have one
		local root = object:FindFirstChild("CarryRoot") :: BasePart?
		if not root then
			local center, size = getWorldBox(parts)
			root = Instance.new("Part")
			root.Name = "CarryRoot"
			root.Size = size
			root.CFrame = CFrame.new(center)
			root.Transparency = 1
			root.CanCollide = false
			root.CanQuery = false
			root.CanTouch = false
			root.Massless = true
			root.Parent = object
		end
		object.PrimaryPart = root
		-- connect every part to the main part so the model stays together
		for _, part in getParts(object) do
			if part ~= root and not part:FindFirstChild("FurnitureWeld") then
				local weld = Instance.new("WeldConstraint")
				weld.Name = "FurnitureWeld"
				weld.Part0 = root
				weld.Part1 = part
				weld.Parent = part
			end
		end
	end
	-- anchored parts cannot move, so turn anchoring off
	for _, part in getParts(object) do
		part.Anchored = false
	end
	local root = getRoot(object)
	if root and root:IsDescendantOf(workspace) then
		-- let the server control furniture when nobody is carrying it
		pcall(root.SetNetworkOwner, root, nil)
	end
	object:SetAttribute("WeightName", getWeightName(getWeight(object)))
end

-- put all character parts in the right collision group
local function setCharacterGroup(character: Model)
	for _, part in getParts(character) do
		part.CollisionGroup = "Characters"
	end
	-- make sure new parts, like accessories, get the same group
	character.DescendantAdded:Connect(function(child)
		if child:IsA("BasePart") then
			child.CollisionGroup = "Characters"
		end
	end)
end

--------------------------------------------------------------------------------
-- 4. carrying furniture
--------------------------------------------------------------------------------

-- stores everything needed to carry one piece of furniture
local Carry = {}
Carry.__index = Carry

function Carry.new(object: Instance)
	local self = setmetatable({}, Carry)
	self.object = object
	self.root = getRoot(object) :: BasePart
	self.weight = getWeight(object)
	self.holders = {} -- players currently holding this item
	self.lifted = false -- becomes true when the players can lift it
	self.sag = 0 -- how low heavy furniture hangs

	local boxCFrame, boxSize = getBox(object)
	self.boxSize = boxSize
	-- remember where the box is compared to the main part
	self.boxOffset = self.root.CFrame:ToObjectSpace(boxCFrame)

	-- keep the furniture upright and snap its angle to 45 degree steps
	local look = boxCFrame.LookVector
	local angle = math.atan2(-look.X, -look.Z)
	self.orientation = CFrame.Angles(0, math.round(angle / config.turnStep) * config.turnStep, 0)

	-- these settings help check for walls while moving the furniture
	self.castParams = RaycastParams.new()
	self.castParams.FilterType = Enum.RaycastFilterType.Exclude

	self.oldGroups = {} :: { [BasePart]: string } -- save the original collision groups
	self.seats = {} -- seats that need to be disabled while carrying

	for _, part in getParts(object) do
		self.oldGroups[part] = part.CollisionGroup
		part.CollisionGroup = "Carried"
		-- stop anyone from sitting on furniture while it is being carried
		if part:IsA("Seat") or part:IsA("VehicleSeat") then
			local seat = part :: any
			if seat.Occupant then
				seat.Occupant.Sit = false
			end
			seat.Disabled = true
			table.insert(self.seats, seat)
		end
	end

	-- the point that pulls the furniture toward its target position
	self.attachment = Instance.new("Attachment")
	self.attachment.Name = "CarryPoint"
	self.attachment.Parent = self.root

	-- moves the furniture toward the player
	self.mover = Instance.new("AlignPosition")
	self.mover.Mode = Enum.PositionAlignmentMode.OneAttachment
	self.mover.Attachment0 = self.attachment
	self.mover.MaxForce = math.max(self.root.AssemblyMass, 1) * config.strength
	self.mover.ApplyAtCenterOfMass = true
	self.mover.Position = self.root.Position
	self.mover.Enabled = false
	self.mover.Parent = self.root

	-- turns the furniture toward the right angle
	self.turner = Instance.new("AlignOrientation")
	self.turner.Mode = Enum.OrientationAlignmentMode.OneAttachment
	self.turner.Attachment0 = self.attachment
	self.turner.MaxTorque = math.huge
	self.turner.CFrame = self.root.CFrame.Rotation
	self.turner.Enabled = false
	self.turner.Parent = self.root

	-- show which furniture is being carried
	self.highlight = Instance.new("Highlight")
	self.highlight.FillTransparency = 0.85
	self.highlight.Adornee = object
	self.highlight.Parent = object
	return self
end

-- check if a player is already holding this item
function Carry:getHolder(player: Player)
	for _, holder in self.holders do
		if holder.player == player then
			return holder
		end
	end
	return nil
end

-- let a player start carrying the furniture
function Carry:addHolder(player: Player, character: Model)
	local humanoid = character:FindFirstChildOfClass("Humanoid") :: Humanoid
	local head = character:FindFirstChild("Head") :: BasePart
	local toBox = (self.root.CFrame * self.boxOffset).Position - head.Position
	table.insert(self.holders, {
		player = player,
		character = character,
		humanoid = humanoid,
		head = head,
		-- face the furniture, or use the head direction if standing inside it
		direction = if toBox.Magnitude > 0.01 then toBox.Unit else head.CFrame.LookVector,
		-- save the player's movement settings so we can restore them later
		oldWalkSpeed = humanoid.WalkSpeed,
		oldJumpPower = humanoid.JumpPower,
		oldJumpHeight = humanoid.JumpHeight,
	})
	player:SetAttribute("Carrying", true)
	self:refresh()
end

-- remove a player and restore their normal movement
function Carry:removeHolder(player: Player)
	for index, holder in self.holders do
		if holder.player == player then
			table.remove(self.holders, index)
			if holder.humanoid.Parent then
				holder.humanoid.WalkSpeed = holder.oldWalkSpeed
				holder.humanoid.JumpPower = holder.oldJumpPower
				holder.humanoid.JumpHeight = holder.oldJumpHeight
			end
			player:SetAttribute("Carrying", false)
			break
		end
	end
	self:refresh()
end

-- update the carry settings whenever someone starts or stops helping
function Carry:refresh()
	local count = #self.holders
	self.object:SetAttribute("Holders", count)
	if count == 0 then
		return -- nobody is holding it anymore
	end

	local share = self.weight / count -- split the weight between the players
	local heaviness = getHeaviness(share)
	self.lifted = share <= config.maxWeight
	self.mover.Enabled = self.lifted
	self.turner.Enabled = self.lifted

	-- heavy furniture takes longer to move and turn
	self.mover.MaxVelocity = byWeight("maxSpeed", heaviness)
	self.mover.Responsiveness = byWeight("follow", heaviness)
	self.turner.Responsiveness = byWeight("turnSpeed", heaviness)
	self.sag = byWeight("sag", heaviness)

	-- yellow means the furniture is lifted, red means it needs help
	self.highlight.OutlineColor = if self.lifted then Color3.fromRGB(255, 220, 120) else Color3.fromRGB(255, 90, 90)

	local skip = { self.object } -- ignore the furniture itself and the players holding it
	for _, holder in self.holders do
		table.insert(skip, holder.character)
		-- heavier furniture makes walking and jumping harder
		holder.humanoid.WalkSpeed = holder.oldWalkSpeed * byWeight("walk", heaviness)
		holder.humanoid.JumpPower = holder.oldJumpPower * byWeight("jump", heaviness)
		holder.humanoid.JumpHeight = holder.oldJumpHeight * byWeight("jump", heaviness)
	end
	self.castParams.FilterDescendantsInstances = skip

	-- one player controls the physics when carrying alone
	-- with two players, the server controls it so both see the same movement
	local owner = if count == 1 and self.lifted then self.holders[1].player else nil
	pcall(self.root.SetNetworkOwner, self.root, owner)
end

-- check if the player can keep carrying the furniture
function Carry:isHolderValid(holder): boolean
	if holder.humanoid.Health <= 0 or not holder.head:IsDescendantOf(workspace) then
		return false -- the player died or their character is gone
	end
	-- the player must stay close, with a little extra room while carrying
	local limit = if self.lifted then config.dropDistance else config.reach
	return distanceToBox(holder.head.Position, self.root.CFrame * self.boxOffset, self.boxSize) <= limit
end

-- update the furniture position every frame
function Carry:update()
	if not self.lifted then
		return -- wait for another player to help lift it
	end

	local sum = Vector3.zero
	for _, holder in self.holders do
		local start = CFrame.new(holder.head.Position) * self.orientation
		-- check if there is a wall in front of the player
		-- the box check uses the furniture size, so big items do not go through walls
		local reach = config.holdDistance + getDepth(self.orientation, self.boxSize, holder.direction)
		local distance = reach
		local hit = workspace:Blockcast(start, self.boxSize, holder.direction * reach, self.castParams)
		if hit then
			distance = math.max(config.minDistance, hit.Distance)
		end
		sum += holder.head.Position + holder.direction * distance
	end

	-- if two players are carrying it, keep it between them
	local target = CFrame.new(sum / #self.holders) * self.orientation
	target -= Vector3.new(0, self.sag, 0) -- heavy items hang a little lower

	-- check if there is a floor or table just below the furniture
	local below = workspace:Blockcast(target, self.boxSize, Vector3.new(0, -config.snapDistance, 0), self.castParams)
	if below then
		target += Vector3.new(0, -below.Distance, 0) -- move it down onto the surface
	end

	-- work out where the main part needs to go
	local rootTarget = target * self.boxOffset:Inverse()
	self.mover.Position = rootTarget.Position
	self.turner.CFrame = rootTarget.Rotation
end

-- turn the furniture or tilt it to one side
function Carry:turn(kind: string, sign: number, holder)
	local angle = config.turnStep * sign
	if kind == "Spin" then
		self.orientation = CFrame.Angles(0, angle, 0) * self.orientation -- turn left or right
	else
		-- choose the closest world axis so the furniture tilts in a clear direction
		local right = holder.direction:Cross(Vector3.yAxis)
		local axis = Vector3.xAxis
		if math.abs(right.Z) > math.abs(right.X) then
			axis = Vector3.zAxis * math.sign(right.Z)
		elseif right.X ~= 0 then
			axis = Vector3.xAxis * math.sign(right.X)
		end
		self.orientation = CFrame.fromAxisAngle(axis, angle) * self.orientation
	end
	self.orientation = self.orientation:Orthonormalize() -- clean up tiny errors after many turns
end

-- stop carrying the furniture and put everything back to normal
function Carry:finish()
	self.mover:Destroy()
	self.turner:Destroy()
	self.attachment:Destroy()
	self.highlight:Destroy()
	self.object:SetAttribute("Holders", nil)

	-- restore the original collision groups
	for part, group in self.oldGroups do
		if part.Parent then
			part.CollisionGroup = group
		end
	end

	-- let players use the seats again
	for _, seat in self.seats do
		if seat.Parent then
			seat.Disabled = false
		end
	end

	if self.root:IsDescendantOf(workspace) then
		-- give physics back to the server and stop the furniture from sliding away
		pcall(self.root.SetNetworkOwner, self.root, nil)
		self.root.AssemblyLinearVelocity = Vector3.zero
		self.root.AssemblyAngularVelocity = Vector3.zero
	end
end

--------------------------------------------------------------------------------
-- 5. players
--------------------------------------------------------------------------------

local carries: { [Player]: any } = {} -- the furniture each player is holding
local carriedBy: { [Instance]: any } = {} -- the players holding each item
local lastUse: { [Player]: number } = {} -- last time each player pressed e
local lastTurn: { [Player]: number } = {} -- last time each player turned furniture

local function tell(player: Player, text: string)
	messageRemote:FireClient(player, text) -- show a message on the player's screen
end

-- let go of the furniture
-- if nobody else is holding it, stop the carry completely
local function letGo(player: Player)
	local carry = carries[player]
	if not carry then
		return
	end

	carries[player] = nil
	carry:removeHolder(player)

	if #carry.holders == 0 then
		carry:finish()
		carriedBy[carry.object] = nil
	end
end

-- stop players from using the same action too quickly
local function canAct(times: { [Player]: number }, player: Player, delay: number): boolean
	local now = os.clock()
	if now - (times[player] or 0) < delay then
		return false
	end
	times[player] = now
	return true
end

-- when a player presses e, pick up the furniture or drop what they are holding
useRemote.OnServerEvent:Connect(function(player: Player, target: any)
	if not canAct(lastUse, player, config.useDelay) then
		return
	end

	if carries[player] then
		letGo(player) -- pressing e again drops the furniture
		return
	end

	if typeof(target) ~= "Instance" then
		return -- ignore invalid targets sent by the client
	end

	local object = findFurniture(target)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local head = character and character:FindFirstChild("Head") :: BasePart?
	local root = object and getRoot(object)

	if not object or not humanoid or humanoid.Health <= 0 or not head or not root or root.Anchored then
		return
	end

	-- check the distance on the server so players cannot grab furniture from far away
	local boxCFrame, boxSize = getBox(object)
	if distanceToBox(head.Position, boxCFrame, boxSize) > config.reach then
		return
	end

	-- even two players cannot carry furniture that is too heavy
	if getWeight(object) > config.maxWeight * config.maxHolders then
		tell(player, "Too heavy, even for " .. config.maxHolders .. " people")
		return
	end

	local carry = carriedBy[object]
	if carry then
		-- check if another player can join in
		if #carry.holders >= config.maxHolders then
			tell(player, "No room for another pair of hands")
			return
		end
	else
		carry = Carry.new(object) -- start a new carry
		carriedBy[object] = carry
	end

	carry:addHolder(player, character :: Model)
	carries[player] = carry

	if not carry.lifted then
		tell(player, "Too heavy alone - someone has to press E on it to help")
	end
end)

-- update the direction the player is looking
aimRemote.OnServerEvent:Connect(function(player: Player, direction: any)
	local carry = carries[player]
	local holder = carry and carry:getHolder(player)
	if not holder or typeof(direction) ~= "Vector3" then
		return
	end

	local length = direction.Magnitude
	if length ~= length or length < 0.5 or length > 1.5 then
		return -- ignore directions that do not look valid
	end

	holder.direction = direction / length -- keep the direction at a normal length
end)

-- handle furniture turning
turnRemote.OnServerEvent:Connect(function(player: Player, kind: any, sign: any)
	local carry = carries[player]
	local holder = carry and carry:getHolder(player)

	if not holder or not carry.lifted or (kind ~= "Spin" and kind ~= "Tip") then
		return
	end

	if not canAct(lastTurn, player, config.turnDelay) then
		return
	end

	carry:turn(kind, if sign == -1 then -1 else 1, holder)
end)

-- check every frame if players can still hold their furniture
RunService.Heartbeat:Connect(function()
	for object, carry in carriedBy do
		-- go backwards so removing a player does not skip anyone
		for index = #carry.holders, 1, -1 do
			local holder = carry.holders[index]
			if not carry.root:IsDescendantOf(workspace) or not carry:isHolderValid(holder) then
				letGo(holder.player)
			end
		end

		-- keep moving the furniture if someone is still holding it
		if carriedBy[object] then
			carry:update()
		end
	end
end)

-- set up collision groups when a player joins
Players.PlayerAdded:Connect(function(player: Player)
	player.CharacterAdded:Connect(setCharacterGroup)
end)

-- drop the furniture and clear saved data when a player leaves
Players.PlayerRemoving:Connect(function(player: Player)
	letGo(player)
	lastUse[player] = nil
	lastTurn[player] = nil
end)

-- set up players who were already in the game when the script started
for _, player in Players:GetPlayers() do
	player.CharacterAdded:Connect(setCharacterGroup)
	if player.Character then
		setCharacterGroup(player.Character)
	end
end

-- prepare all furniture that already has the tag
for _, object in CollectionService:GetTagged(config.tag) do
	prepare(object)
end

-- prepare new furniture when the tag gets added
CollectionService:GetInstanceAddedSignal(config.tag):Connect(prepare)

-- prepare furniture inside the workspace folder too
local furnitureFolder = workspace:FindFirstChild(config.folderName)
if furnitureFolder then
	for _, object in furnitureFolder:GetChildren() do
		prepare(object)
	end

	-- prepare any furniture added to the folder later
	furnitureFolder.ChildAdded:Connect(prepare)
end
