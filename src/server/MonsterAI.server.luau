local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = workspace

local Modules = ReplicatedStorage:WaitForChild("Modules")
local GridScanner = require(Modules:WaitForChild("GridScanner"))
local MonsterFSM = require(Modules:WaitForChild("MonsterFSM"))

local PATH_MARKER_NAME = "__MonsterPathDebugPoint"
local COLOR_NEAR = Color3.fromRGB(0, 200, 180)
local COLOR_FAR = Color3.fromRGB(255, 195, 0)
local MONSTER_MODEL_NAME = "Wavy"
local WALK_ANIMATION_ID = "rbxassetid://105790090049099"
local RUN_ANIMATION_ID = "rbxassetid://114796763148559"
local ATTACK_ANIMATION_ID = ""

local function findAnywhere(name: string): BasePart?
	for _ = 1, 50 do -- retry for up to ~5 seconds in case parts haven't replicated yet
		local found = Workspace:FindFirstChild(name, true)
		if found then
			return found :: BasePart
		end
		task.wait(0.1)
	end
	return nil
end

local minPart = findAnywhere("MonsterAreaMin")
local maxPart = findAnywhere("MonsterAreaMax")
assert(minPart and maxPart, "MonsterAreaMin/MonsterAreaMax not found anywhere under Workspace")

local grid = GridScanner.new(minPart.Position, maxPart.Position, 2, 4)

local function createPlaceholderMonster(): Model
	local model = Instance.new("Model")
	model.Name = MONSTER_MODEL_NAME

	local part = Instance.new("Part")
	part.Name = "Body"
	part.Size = Vector3.new(3, 5, 3)
	part.Color = Color3.fromRGB(200, 40, 40)
	part.Material = Enum.Material.SmoothPlastic
	part.Anchored = true
	part.CanCollide = false
	part.Position = minPart.Position
	part.Parent = model

	model.PrimaryPart = part
	model.Parent = Workspace
	return model
end

-- Recursive search (true = search descendants) so the model can live inside
-- a folder, not just directly under Workspace
local monsterModel = Workspace:FindFirstChild(MONSTER_MODEL_NAME, true) :: Model?
if not monsterModel then
	monsterModel = createPlaceholderMonster()
	print(("[MonsterAI] No '%s' model found -- created a placeholder block"):format(MONSTER_MODEL_NAME))
elseif not monsterModel.PrimaryPart then
	-- Rigged characters loaded via plugins usually have this set already,
	-- but fall back to HumanoidRootPart if it wasn't
	local root = monsterModel:FindFirstChild("HumanoidRootPart") :: BasePart?
	if root then
		monsterModel.PrimaryPart = root
	else
		warn(("[MonsterAI] '%s' has no PrimaryPart and no HumanoidRootPart -- movement will fail"):format(MONSTER_MODEL_NAME))
	end
end

-- Exclude the monster's own body from the grid scan so it never mistakes
-- itself for an obstacle standing on its own cell
grid.raycastParams.FilterDescendantsInstances = { monsterModel :: Instance }
grid.overlapParams.FilterDescendantsInstances = { monsterModel :: Instance }

grid:ScanAll()

do
	local count = 0
	for _ in grid.cells do
		count += 1
	end
	print(("[MonsterAI] Grid scan complete: %d cells"):format(count))
end

local fsm = MonsterFSM.new(monsterModel :: Model, grid, {
	WalkAnimationId = WALK_ANIMATION_ID ~= "" and WALK_ANIMATION_ID or nil,
	RunAnimationId = RUN_ANIMATION_ID ~= "" and RUN_ANIMATION_ID or nil,
	AttackAnimationId = ATTACK_ANIMATION_ID ~= "" and ATTACK_ANIMATION_ID or nil,
})

local function bindTarget(player: Player)
	local function onCharacter(character: Model)
		character:WaitForChild("HumanoidRootPart")
		fsm:SetTarget(character)
	end
	if player.Character then
		onCharacter(player.Character)
	end
	player.CharacterAdded:Connect(onCharacter)
end

for _, player in Players:GetPlayers() do
	bindTarget(player)
end
Players.PlayerAdded:Connect(bindTarget)

local function clearPathMarkers()
	for _, child in Workspace:GetChildren() do
		if child.Name == PATH_MARKER_NAME then
			child:Destroy()
		end
	end
end

local function drawPathMarkers(path: { Vector3 })
	clearPathMarkers()
	local total = #path
	for i, point in ipairs(path) do
		local t = total > 1 and (i - 1) / (total - 1) or 0
		local color = COLOR_NEAR:Lerp(COLOR_FAR, t)

		local marker = Instance.new("Part")
		marker.Name = PATH_MARKER_NAME
		marker.Anchored = true
		marker.CanCollide = false
		marker.Shape = Enum.PartType.Block
		marker.Material = Enum.Material.SmoothPlastic
		marker.Transparency = 0.25
		marker.Size = Vector3.new(1.5, 1.5, 1.5)
		marker.Color = color
		marker.Position = point + Vector3.new(0, 1, 0)
		marker.Parent = Workspace
	end
end

local lastState = fsm:GetState()
local lastDrawnPath: { Vector3 }? = nil

RunService.Heartbeat:Connect(function(dt)
	fsm:Update(dt)

	local state = fsm:GetState()
	if state ~= lastState then
		print(("[MonsterAI] State: %s -> %s"):format(lastState, state))
		lastState = state
	end

	-- Only Chase/Flee ever have a path; Search intentionally clears it, and
	-- Idle/Attack never set one
	local path = fsm:GetCurrentPath()
	if path then
		if path ~= lastDrawnPath then
			drawPathMarkers(path)
			lastDrawnPath = path
		end
	elseif lastDrawnPath then
		clearPathMarkers()
		lastDrawnPath = nil
	end
end)
