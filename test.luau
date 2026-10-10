-- pastewiki/convoylol

local Players = game:GetService("Players") 
local RunService = game:GetService("RunService") 
local CollectionService = game:GetService("CollectionService") 
local PhysicsService = game:GetService("PhysicsService") 
local ReplicatedStorage = game:GetService("ReplicatedStorage") 

--------------------------------------------------------------------------------
-- 1. Settings
--------------------------------------------------------------------------------

local config = {
	tag = "Furniture", -- things with this tag can be picked up
	folderName = "Furniture", -- everything right inside this workspace folder can be picked up too
	reach = 12, -- how close you must be to pick something up
	holdDistance = 5, -- the gap between your head and the near side of what you hold
	minDistance = 3, -- the closest it comes when a wall is in the way
	snapDistance = 1.5, -- if a surface is this close below, the furniture sits on it
	turnStep = math.rad(45), -- one key press turns it this much
	strength = 300, -- how hard it is pulled to the target (per unit of mass)

	-- Weight. A "Weight" attribute on the furniture is used if it has one; if not, its size (volume) is its weight.
	lightWeight = 10, -- this light or lighter: carried at full speed
	heavyWeight = 300, -- this heavy or heavier: carried at the slowest speed
	maxWeight = 400, -- heavier than this: one player can not lift it
	maxHolders = 2, -- how many players can hold one thing; the weight is split between them
	light = { follow = 25, maxSpeed = 40, turnSpeed = 40, walk = 1, jump = 1, sag = 0 }, -- how light things feel
	heavy = { follow = 6, maxSpeed = 12, turnSpeed = 6, walk = 0.45, jump = 0.2, sag = 2 }, -- how heavy things feel
	dropDistance = 15, -- if a holder ends up this far from it (stuck or cheating), they let go
	settleTime = 3, -- after a drop, furniture gets this long to fall and stop before it is anchored again
	useDelay = 0.2, -- min time between two E presses
	turnDelay = 0.08, -- min time between two turns
}

--------------------------------------------------------------------------------
-- 2. Setup
--------------------------------------------------------------------------------

-- Carried furniture should not hit players, but it should still hit walls and floors.
local function addCollisionGroup(name: string)
	if not PhysicsService:IsCollisionGroupRegistered(name) then
		PhysicsService:RegisterCollisionGroup(name) -- registering twice gives an error, so check first
	end
end
addCollisionGroup("Characters")
addCollisionGroup("Carried")
PhysicsService:CollisionGroupSetCollidable("Characters", "Carried", false) -- players and carried things pass through each other

local remoteFolder = Instance.new("Folder")
remoteFolder.Name = "CarryRemotes"

-- creates a remote event so the client and server can send this action
local function makeRemote(name: string): RemoteEvent
	local remote = Instance.new("RemoteEvent") -- one remote for each action
	remote.Name = name
	remote.Parent = remoteFolder
	return remote
end

local useRemote = makeRemote("Use") -- E: pick up the thing under the mouse, or drop what you hold
local aimRemote = makeRemote("Aim") -- where the player looks, sent many times a second
local turnRemote = makeRemote("Turn") -- R or T was pressed
local messageRemote = makeRemote("Message") -- server sends a short text to the client, like "too heavy"
remoteFolder.Parent = ReplicatedStorage

--------------------------------------------------------------------------------
-- 3. Helpers
--------------------------------------------------------------------------------

-- Furniture is anything with the tag, or anything placed right inside the Furniture folder.
local function isFurniture(instance: Instance): boolean
	if CollectionService:HasTag(instance, config.tag) then
		return true
	end
	local parent = instance.Parent
	return parent ~= nil and parent.Parent == workspace and parent.Name == config.folderName
end

-- The client sends the part it clicked. Furniture can be a model with more models inside,
-- so we walk up until we reach the furniture itself.
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

-- All parts of a piece of furniture: the part itself, or every part inside the model.
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

-- The main part. Forces are put on it, and all other parts are welded to it.
local function getRoot(object: Instance): BasePart?
	if object:IsA("BasePart") then
		return object
	elseif object:IsA("Model") then
		return object.PrimaryPart
	end
	return nil
end

-- A box around the whole thing. For a model, the box is turned the same way as its PrimaryPart.
local function getBox(object: Instance): (CFrame, Vector3)
	if object:IsA("Model") then
		return object:GetBoundingBox()
	end
	local part = object :: BasePart
	return part.CFrame, part.Size
end

-- Distance from a point to the closest spot on a box (0 if the point is inside).
-- We move the point into the box's own space, where the box is not turned, and clamp it to the box.
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

-- How far a turned box reaches from its middle toward a direction (half its depth that way).
local function getDepth(rotation: CFrame, size: Vector3, direction: Vector3): number
	local half = size / 2
	return math.abs(direction:Dot(rotation.RightVector)) * half.X
		+ math.abs(direction:Dot(rotation.UpVector)) * half.Y
		+ math.abs(direction:Dot(rotation.LookVector)) * half.Z
end

-- A box around many parts, lined up with the world (not turned).
local function getWorldBox(parts: { BasePart }): (Vector3, Vector3)
	local low = Vector3.one * math.huge
	local high = -low
	for _, part in parts do
		local cframe = part.CFrame
		local half = part.Size / 2
		-- How far a turned part reaches along each world axis:
		-- add up how much each of its three sides points along that axis.
		local reach = Vector3.new(
			math.abs(cframe.RightVector.X) * half.X + math.abs(cframe.UpVector.X) * half.Y + math.abs(cframe.LookVector.X) * half.Z,
			math.abs(cframe.RightVector.Y) * half.X + math.abs(cframe.UpVector.Y) * half.Y + math.abs(cframe.LookVector.Y) * half.Z,
			math.abs(cframe.RightVector.Z) * half.X + math.abs(cframe.UpVector.Z) * half.Y + math.abs(cframe.LookVector.Z) * half.Z
		)
		low = low:Min(cframe.Position - reach) -- the lowest corner so far
		high = high:Max(cframe.Position + reach) -- the highest corner so far
	end
	return (low + high) / 2, high - low -- the middle and the size
end

-- How heavy a piece of furniture is. A "Weight" attribute wins. If there is none, we use the size of its box,
-- because the real mass of free models is often random (here a TV weighs more than a fridge).
local function getWeight(object: Instance): number
	local weight = object:GetAttribute("Weight")
	if typeof(weight) == "number" then
		return weight
	end
	local _, size = getBox(object)
	return size.X * size.Y * size.Z
end

-- 0 = light as a feather, 1 = as heavy as it gets.
local function getHeaviness(weight: number): number
	return math.clamp((weight - config.lightWeight) / (config.heavyWeight - config.lightWeight), 0, 1)
end

-- Picks a value between the light and the heavy setting. Heaviness 0.5 gives the middle.
local function byWeight(name: string, heaviness: number): number
	local light, heavy = config.light[name], config.heavy[name]
	return light + (heavy - light) * heaviness
end

-- A word for the client to show when the player looks at the furniture.
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

-- Gets a piece of furniture ready: one main part, everything welded to it, nothing anchored.
local function prepare(object: Instance)
	if not (object:IsA("Model") or object:IsA("BasePart")) then
		return -- only models and parts can be furniture (not a folder or a script)
	end
	if object:IsA("Model") then
		local parts = getParts(object)
		if #parts == 0 then
			return -- an empty model, nothing to carry
		end
		-- Free models often have a turned main part, so they would be carried on their side.
		-- So we make our own invisible main part: a box around the whole model, lined up with the world.
		local root = object:FindFirstChild("CarryRoot") :: BasePart?
		if not root then
			local center, size = getWorldBox(parts)
			root = Instance.new("Part")
			root.Name = "CarryRoot"
			root.Size = size
			root.CFrame = CFrame.new(center) -- not turned, so its up is really up
			root.Transparency = 1
			root.CanCollide = false -- the real parts hit things, not this box
			root.CanQuery = false -- rays and box sweeps go through it
			root.CanTouch = false
			root.Massless = true -- it should not make the furniture heavier
			root.Parent = object
		end
		object.PrimaryPart = root
		for _, part in getParts(object) do
			if part ~= root and not part:FindFirstChild("FurnitureWeld") then
				local weld = Instance.new("WeldConstraint") -- keeps the model in one piece when it moves
				weld.Name = "FurnitureWeld"
				weld.Part0 = root
				weld.Part1 = part
				weld.Parent = part
			end
		end
	end
	for _, part in getParts(object) do
		part.Anchored = false -- the welds hold the model together, so only the main part needs anchoring
	end
	local root = getRoot(object)
	if root then
		-- Furniture nobody holds is anchored, so players can not push it by walking into it.
		-- Anchoring the main part is enough, because every other part is welded to it.
		root.Anchored = true
	end
	object:SetAttribute("WeightName", getWeightName(getWeight(object))) -- attributes are seen by the client too
end

-- Sets every part of a character to the "Characters" group, also parts added later (tools, hats).
local function setCharacterGroup(character: Model)
	for _, part in getParts(character) do
		part.CollisionGroup = "Characters"
	end
	character.DescendantAdded:Connect(function(child)
		if child:IsA("BasePart") then
			child.CollisionGroup = "Characters"
		end
	end)
end

local settling: { [Instance]: {} } = {} -- furniture -> the newest settle, so an old one can stop itself

-- True if the furniture lies on something that is being carried right now (like a mug on a carried table).
local function isOnCarried(object: Instance): boolean
	local boxCFrame, size = getBox(object)
	local bottom = boxCFrame * CFrame.new(0, -size.Y / 2, 0) -- a thin slab on the bottom side of the box
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { object }
	for _, part in workspace:GetPartBoundsInBox(bottom, Vector3.new(size.X, 0.5, size.Z), params) do
		local other = findFurniture(part)
		if other and other:GetAttribute("Holders") then
			return true
		end
	end
	return false
end

-- Lets a piece of furniture fall and come to rest, then anchors it again.
local function settle(object: Instance)
	local root = getRoot(object)
	if not root then
		return
	end
	root.Anchored = false -- let it fall onto whatever is below
	local token = {} -- a new empty table is different from every other table, so it marks this settle
	settling[object] = token
	task.spawn(function()
		local calmChecks = 0
		local started = os.clock()
		while os.clock() - started < config.settleTime do
			task.wait(0.1)
			if settling[object] ~= token or object:GetAttribute("Holders") or not root:IsDescendantOf(workspace) then
				return -- picked up again, settled again, or deleted
			end
			if isOnCarried(object) then
				started = os.clock() -- it rides on something in the air; wait until that is put down
				calmChecks = 0
				continue
			end
			local still = root.AssemblyLinearVelocity.Magnitude < 0.3 and root.AssemblyAngularVelocity.Magnitude < 0.3
			calmChecks = if still then calmChecks + 1 else 0
			if calmChecks >= 3 then
				break -- it has not moved for 0.3 seconds, so it is resting
			end
		end
		if settling[object] == token then
			settling[object] = nil
			root.Anchored = true -- if it is still moving after settleTime, it is anchored where it is
		end
	end)
end

--------------------------------------------------------------------------------
-- 4. Carry
--------------------------------------------------------------------------------

-- One Carry is one piece of furniture in the air. One or two players can hold it.
-- Each holder is a small table: { player, character, humanoid, head, direction, old walk and jump values }.
local Carry = {}
Carry.__index = Carry -- every carry uses the functions from this table

-- sets up the furniture and the physics needed to carry it
function Carry.new(object: Instance)
	local self = setmetatable({}, Carry)
	self.object = object
	self.root = getRoot(object) :: BasePart
	self.weight = getWeight(object)
	self.holders = {} -- the players holding it, in the order they grabbed it
	self.lifted = false -- false while it is too heavy for the people holding it
	self.sag = 0 -- how much lower it hangs; set in refresh

	local boxCFrame, boxSize = getBox(object)
	self.boxSize = boxSize
	-- Where the middle of the box is compared to the main part. We aim the box, then use this to place the part.
	self.boxOffset = self.root.CFrame:ToObjectSpace(boxCFrame)

	-- Keep its left/right angle, snapped to the 45 degree steps, but stand it up straight.
	local look = boxCFrame.LookVector
	local angle = math.atan2(-look.X, -look.Z) -- the angle of the front side around the up axis
	self.orientation = CFrame.Angles(0, math.round(angle / config.turnStep) * config.turnStep, 0)

	self.castParams = RaycastParams.new() -- made once per carry, used every frame
	self.castParams.FilterType = Enum.RaycastFilterType.Exclude -- what to skip is set in refresh

	self.oldGroups = {} :: { [BasePart]: string } -- to put the collision groups back on drop
	self.seats = {} -- seats are turned off while it is carried, so nobody can ride on it
	for _, part in getParts(object) do
		self.oldGroups[part] = part.CollisionGroup
		part.CollisionGroup = "Carried"
		if part:IsA("Seat") or part:IsA("VehicleSeat") then
			local seat = part :: any
			if seat.Occupant then
				seat.Occupant.Sit = false -- whoever sits on it stands up
			end
			seat.Disabled = true
			table.insert(self.seats, seat)
		end
	end

	self.attachment = Instance.new("Attachment") -- the point the forces pull on
	self.attachment.Name = "CarryPoint"
	self.attachment.Parent = self.root

	self.mover = Instance.new("AlignPosition") -- pulls the furniture to the target spot
	self.mover.Mode = Enum.PositionAlignmentMode.OneAttachment -- pull toward a point, not another attachment
	self.mover.Attachment0 = self.attachment
	self.mover.MaxForce = math.max(self.root.AssemblyMass, 1) * config.strength -- heavy things get more force
	self.mover.ApplyAtCenterOfMass = true -- pull the middle, so it does not start spinning
	self.mover.Position = self.root.Position
	self.mover.Enabled = false -- turned on in refresh, once someone can lift it
	self.mover.Parent = self.root

	self.turner = Instance.new("AlignOrientation") -- turns the furniture to the target angle
	self.turner.Mode = Enum.OrientationAlignmentMode.OneAttachment
	self.turner.Attachment0 = self.attachment
	self.turner.MaxTorque = math.huge -- always strong enough to turn it
	self.turner.CFrame = self.root.CFrame.Rotation
	self.turner.Enabled = false
	self.turner.Parent = self.root

	self.highlight = Instance.new("Highlight") -- everyone sees what is being carried
	self.highlight.FillTransparency = 0.85
	self.highlight.Adornee = object
	self.highlight.Parent = object

	settling[object] = nil -- stop a settle that may still run from the last drop
	self.root.Anchored = false -- physics has to move it while it is carried
	self:wakeThingsOnTop()
	return self
end

-- Things standing on top of it (like a mug on a table) should fall when it is lifted, not hang in the air.
function Carry:wakeThingsOnTop()
	local boxCFrame = self.root.CFrame * self.boxOffset
	local top = boxCFrame * CFrame.new(0, self.boxSize.Y / 2, 0) -- a thin slab lying on the top side of the box
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { self.object }
	local woken = {}
	for _, part in workspace:GetPartBoundsInBox(top, Vector3.new(self.boxSize.X, 1, self.boxSize.Z), params) do
		local other = findFurniture(part)
		if other and not woken[other] and not other:GetAttribute("Holders") then
			woken[other] = true -- a model has many parts; wake it only once
			settle(other)
		end
	end
end

-- finds this player in the list of people carrying the furniture
function Carry:getHolder(player: Player)
	for _, holder in self.holders do
		if holder.player == player then
			return holder
		end
	end
	return nil
end

-- adds a player to the carry and saves their normal movement settings
function Carry:addHolder(player: Player, character: Model)
	local humanoid = character:FindFirstChildOfClass("Humanoid") :: Humanoid
	local head = character:FindFirstChild("Head") :: BasePart
	local toBox = (self.root.CFrame * self.boxOffset).Position - head.Position
	table.insert(self.holders, {
		player = player,
		character = character,
		humanoid = humanoid,
		head = head,
		-- at the start, the player looks at it; if the head is right in the middle of it, use where the head faces
		direction = if toBox.Magnitude > 0.01 then toBox.Unit else head.CFrame.LookVector,
		oldWalkSpeed = humanoid.WalkSpeed, -- saved to put back when they let go
		oldJumpPower = humanoid.JumpPower,
		oldJumpHeight = humanoid.JumpHeight,
	})
	player:SetAttribute("Carrying", true) -- the client reads this to know it is holding something
	self:refresh()
end

-- removes a player and restores their normal movement settings
function Carry:removeHolder(player: Player)
	for index, holder in self.holders do
		if holder.player == player then
			table.remove(self.holders, index)
			if holder.humanoid.Parent then
				holder.humanoid.WalkSpeed = holder.oldWalkSpeed -- walk and jump like before
				holder.humanoid.JumpPower = holder.oldJumpPower
				holder.humanoid.JumpHeight = holder.oldJumpHeight
			end
			player:SetAttribute("Carrying", false)
			break
		end
	end
	self:refresh()
end

-- Runs when someone grabs or lets go. Shares the weight between the holders and sets everything up again.
function Carry:refresh()
	local count = #self.holders
	self.object:SetAttribute("Holders", count) -- the client shows "help carry" when this is 1
	if count == 0 then
		return -- nobody left; the caller puts it down
	end
	local share = self.weight / count -- each holder only carries their part of the weight
	local heaviness = getHeaviness(share)
	self.lifted = share <= config.maxWeight -- too heavy for one: it stays on the ground until a second player helps
	self.mover.Enabled = self.lifted
	self.turner.Enabled = self.lifted
	self.mover.MaxVelocity = byWeight("maxSpeed", heaviness) -- heavy things move slower
	self.mover.Responsiveness = byWeight("follow", heaviness) -- heavy things follow your look more slowly
	self.turner.Responsiveness = byWeight("turnSpeed", heaviness) -- heavy things turn more slowly
	self.sag = byWeight("sag", heaviness)
	-- Gold = in the air. Red = waiting for a helper.
	self.highlight.OutlineColor = if self.lifted then Color3.fromRGB(255, 220, 120) else Color3.fromRGB(255, 90, 90)

	local skip = { self.object } -- the box sweeps should not hit the furniture itself or anyone holding it
	for _, holder in self.holders do
		table.insert(skip, holder.character)
		-- Carrying something heavy makes you walk slower and jump lower.
		-- A humanoid uses JumpPower or JumpHeight, so we change both.
		holder.humanoid.WalkSpeed = holder.oldWalkSpeed * byWeight("walk", heaviness)
		holder.humanoid.JumpPower = holder.oldJumpPower * byWeight("jump", heaviness)
		holder.humanoid.JumpHeight = holder.oldJumpHeight * byWeight("jump", heaviness)
	end
	self.castParams.FilterDescendantsInstances = skip

	-- One holder: their computer runs the physics, so it moves with no ping delay for them.
	-- Two holders: the server runs it, so neither of them can cheat and it looks the same for both.
	local owner = if count == 1 and self.lifted then self.holders[1].player else nil
	pcall(self.root.SetNetworkOwner, self.root, owner)
end

-- False when this holder should let go: they died, or they are too far from the furniture.
function Carry:isHolderValid(holder): boolean
	if holder.humanoid.Health <= 0 or not holder.head:IsDescendantOf(workspace) then
		return false
	end
	-- Before it is lifted you must stay right next to it. In the air it can lag behind a bit.
	-- The holder may run the physics, so a cheater could try to move it far away; this check stops that.
	local limit = if self.lifted then config.dropDistance else config.reach
	return distanceToBox(holder.head.Position, self.root.CFrame * self.boxOffset, self.boxSize) <= limit
end

-- Works out where the furniture should be this frame.
function Carry:update()
	if not self.lifted then
		return -- still on the ground, waiting for a helper
	end
	local sum = Vector3.zero
	for _, holder in self.holders do
		local start = CFrame.new(holder.head.Position) * self.orientation -- the box at the head, turned the right way
		-- Sweep the whole box forward from the head. If it hits a wall, stop right before the wall.
		-- A box sweep is better than a ray here, because big furniture would stick into the wall with a ray.
		-- The middle of the box goes further out for big things, so a bed floats in front of you, not around you.
		local reach = config.holdDistance + getDepth(self.orientation, self.boxSize, holder.direction)
		local distance = reach
		local hit = workspace:Blockcast(start, self.boxSize, holder.direction * reach, self.castParams)
		if hit then
			distance = math.max(config.minDistance, hit.Distance)
		end
		sum += holder.head.Position + holder.direction * distance
	end
	-- With two holders it goes to the middle point between the two spots they hold it at.
	local target = CFrame.new(sum / #self.holders) * self.orientation
	target -= Vector3.new(0, self.sag, 0) -- heavy things hang lower, like tired arms

	-- Snapping: if a floor or a table is just below, move down so the furniture sits right on it.
	local below = workspace:Blockcast(target, self.boxSize, Vector3.new(0, -config.snapDistance, 0), self.castParams)
	if below then
		target += Vector3.new(0, -below.Distance, 0)
	end

	-- target is where the box should be; boxOffset turns that into where the main part should be.
	local rootTarget = target * self.boxOffset:Inverse()
	self.mover.Position = rootTarget.Position
	self.turner.CFrame = rootTarget.Rotation
end

-- "Spin" turns it around the up axis. "Tip" tips it over, away from or toward the player who pressed the key.
function Carry:turn(kind: string, sign: number, holder)
	local angle = config.turnStep * sign
	if kind == "Spin" then
		self.orientation = CFrame.Angles(0, angle, 0) * self.orientation -- world axis first, so up stays up
	else
		-- The player's right side, from where they look. We tip around the world X or Z axis,
		-- whichever is closer to it, so the furniture always lines up with walls after tipping.
		local right = holder.direction:Cross(Vector3.yAxis)
		local axis = Vector3.xAxis
		if math.abs(right.Z) > math.abs(right.X) then
			axis = Vector3.zAxis * math.sign(right.Z)
		elseif right.X ~= 0 then
			axis = Vector3.xAxis * math.sign(right.X)
		end
		self.orientation = CFrame.fromAxisAngle(axis, angle) * self.orientation
	end
	self.orientation = self.orientation:Orthonormalize() -- many turns add tiny math errors; this cleans them up
end

-- Puts the furniture down for good. Only called when nobody holds it anymore.
function Carry:finish()
	self.mover:Destroy()
	self.turner:Destroy()
	self.attachment:Destroy()
	self.highlight:Destroy()
	self.object:SetAttribute("Holders", nil)
	for part, group in self.oldGroups do
		if part.Parent then
			part.CollisionGroup = group -- players can bump into it again
		end
	end
	for _, seat in self.seats do
		if seat.Parent then
			seat.Disabled = false -- people can sit on it again
		end
	end
	if self.root:IsDescendantOf(workspace) then
		pcall(self.root.SetNetworkOwner, self.root, nil) -- take the physics back to the server first,
		self.root.AssemblyLinearVelocity = Vector3.zero -- then stop it, so nobody can throw furniture
		self.root.AssemblyAngularVelocity = Vector3.zero
		settle(self.object) -- let it land, then anchor it so nobody can push it
	end
end

--------------------------------------------------------------------------------
-- 5. Players
--------------------------------------------------------------------------------

local carries: { [Player]: any } = {} -- player -> the carry they hold on to
local carriedBy: { [Instance]: any } = {} -- furniture -> its carry, so a second player can join it
local lastUse: { [Player]: number } = {}
local lastTurn: { [Player]: number } = {}

-- sends a short message to one player
local function tell(player: Player, text: string)
	messageRemote:FireClient(player, text) -- shows a short text on that player's screen
end

-- The player lets go. If nobody holds the furniture anymore, it is put down.
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

-- Returns true if enough time passed since the last action of this kind.
local function canAct(times: { [Player]: number }, player: Player, delay: number): boolean
	local now = os.clock()
	if now - (times[player] or 0) < delay then
		return false -- too fast, ignore it
	end
	times[player] = now
	return true
end

useRemote.OnServerEvent:Connect(function(player: Player, target: any)
	if not canAct(lastUse, player, config.useDelay) then
		return
	end
	if carries[player] then
		letGo(player) -- E while holding = let go
		return
	end
	if typeof(target) ~= "Instance" then
		return -- a cheater can send anything
	end
	local object = findFurniture(target)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local head = character and character:FindFirstChild("Head") :: BasePart?
	local root = object and getRoot(object)
	if not object or not humanoid or humanoid.Health <= 0 or not head or not root then
		return
	end
	local boxCFrame, boxSize = getBox(object)
	if distanceToBox(head.Position, boxCFrame, boxSize) > config.reach then
		return -- too far away: the server does not trust the client's click
	end
	if getWeight(object) > config.maxWeight * config.maxHolders then
		tell(player, "Too heavy, even for " .. config.maxHolders .. " people")
		return
	end

	local carry = carriedBy[object]
	if carry then
		if #carry.holders >= config.maxHolders then
			tell(player, "No room for another pair of hands")
			return
		end
	else
		carry = Carry.new(object) -- nobody holds it yet
		carriedBy[object] = carry
	end
	carry:addHolder(player, character :: Model)
	carries[player] = carry
	if not carry.lifted then
		tell(player, "Too heavy alone - someone has to press E on it to help")
	end
end)

aimRemote.OnServerEvent:Connect(function(player: Player, direction: any)
	local carry = carries[player]
	local holder = carry and carry:getHolder(player)
	if not holder or typeof(direction) ~= "Vector3" then
		return
	end
	local length = direction.Magnitude
	if length ~= length or length < 0.5 or length > 1.5 then
		return -- NaN or not a direction; a real look direction has length 1
	end
	holder.direction = direction / length -- make the length exactly 1
end)

turnRemote.OnServerEvent:Connect(function(player: Player, kind: any, sign: any)
	local carry = carries[player]
	local holder = carry and carry:getHolder(player)
	if not holder or not carry.lifted or (kind ~= "Spin" and kind ~= "Tip") then
		return
	end
	if not canAct(lastTurn, player, config.turnDelay) then
		return
	end
	carry:turn(kind, if sign == -1 then -1 else 1, holder) -- only -1 or 1, anything else counts as 1
end)

-- Every frame: holders that are not valid anymore let go, then every carry moves.
RunService.Heartbeat:Connect(function()
	for object, carry in carriedBy do
		for index = #carry.holders, 1, -1 do -- backwards, so removing a holder does not skip the next one
			local holder = carry.holders[index]
			if not carry.root:IsDescendantOf(workspace) or not carry:isHolderValid(holder) then
				letGo(holder.player)
			end
		end
		if carriedBy[object] then -- still carried after the checks above
			carry:update()
		end
	end
end)

Players.PlayerAdded:Connect(function(player: Player)
	player.CharacterAdded:Connect(setCharacterGroup)
end)
Players.PlayerRemoving:Connect(function(player: Player)
	letGo(player) -- otherwise the furniture would stay floating
	lastUse[player] = nil
	lastTurn[player] = nil
end)
for _, player in Players:GetPlayers() do
	player.CharacterAdded:Connect(setCharacterGroup) -- players who joined before the script started
	if player.Character then
		setCharacterGroup(player.Character)
	end
end

for _, object in CollectionService:GetTagged(config.tag) do
	prepare(object)
end
CollectionService:GetInstanceAddedSignal(config.tag):Connect(prepare) -- furniture added later works too

local furnitureFolder = workspace:FindFirstChild(config.folderName)
if furnitureFolder then
	for _, object in furnitureFolder:GetChildren() do
		prepare(object)
	end
	furnitureFolder.ChildAdded:Connect(prepare) -- things put in the folder later work too
end
