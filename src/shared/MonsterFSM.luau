--!strict

local AStar = require(script.Parent.AStar)
local LineOfSight = require(script.Parent.LineOfSight)
local PathSmoothing = require(script.Parent.PathSmoothing)

local function loadAnimationTrack(humanoid: Humanoid, animationId: string?, looped: boolean?): AnimationTrack?
	if not animationId then return nil end
	local animator = humanoid:FindFirstChildOfClass("Animator")
	if not animator then animator = Instance.new("Animator") animator.Parent = humanoid end
	local animation = Instance.new("Animation")
	animation.AnimationId = animationId
	local ok, trackOrError = pcall(function()
		return (animator :: Animator):LoadAnimation(animation)
	end)
	if not ok then
		warn(("[MonsterFSM] Failed to load animation '%s': %s"):format(animationId, tostring(trackOrError)))
		return nil
	end
	local track = trackOrError :: AnimationTrack
	track.Looped = looped ~= false
	return track
end

local MonsterFSM = {}
MonsterFSM.__index = MonsterFSM

export type State = "Idle" | "Chase" | "Attack" | "Search" | "Flee"

export type MonsterConfig = {
	DetectionRadius: number, LoseSightRadius: number, AttackRange: number, AttackDamage: number,
	AttackCooldown: number, SearchDuration: number, WanderRadius: number, WanderInterval: number,
	FleeHealthThreshold: number, FleeDuration: number, MoveSpeed: number, ChaseSpeed: number,
	PathRecalcInterval: number, WaypointReachedDistance: number,
	EyeHeight: number, MaxHealth: number,
	WalkAnimationId: string?, RunAnimationId: string?, AttackAnimationId: string?,
}

-- LoseSightRadius > DetectionRadius on purpose (hysteresis, avoids Chase/Search flicker at the edge)
local DEFAULT_CONFIG: MonsterConfig = {
	DetectionRadius = 40, LoseSightRadius = 55, AttackRange = 5, AttackDamage = 10,
	AttackCooldown = 1, SearchDuration = 4, WanderRadius = 20, WanderInterval = 5,
	FleeHealthThreshold = 0.3, FleeDuration = 5, MoveSpeed = 12, ChaseSpeed = 33,
	PathRecalcInterval = 0.5, WaypointReachedDistance = 2.5,
	EyeHeight = 3, MaxHealth = 100,
	WalkAnimationId = nil, RunAnimationId = nil, AttackAnimationId = nil,
}

local function buildConfig(overrides: { [string]: any }?): MonsterConfig
	local config = table.clone(DEFAULT_CONFIG) :: { [string]: any }
	if overrides then
		for key, value in overrides do config[key] = value end
	end
	return (config :: any) :: MonsterConfig
end

type MonsterFSMFields = {
	model: Model, primaryPart: BasePart, humanoid: Humanoid?, grid: any, config: MonsterConfig,
	walkTrack: AnimationTrack?, runTrack: AnimationTrack?, attackTrack: AnimationTrack?,
	isRunning: boolean, state: State, target: Model?, health: number,
	searchTimer: number, wanderTimer: number, fleeTimer: number, attackCooldownTimer: number,
	pathTimer: number, currentPath: { Vector3 }?, pathVersion: number,
	cframeWaypointIndex: number, wanderTarget: Vector3?,
}

export type MonsterFSM = typeof(setmetatable({} :: MonsterFSMFields, MonsterFSM))

function MonsterFSM.new(monsterModel: Model, grid: any, config: { [string]: any }?): MonsterFSM
	local primaryPart = monsterModel.PrimaryPart :: BasePart
	local humanoid = monsterModel:FindFirstChildOfClass("Humanoid") :: Humanoid?
	local mergedConfig = buildConfig(config)
	if humanoid then humanoid.WalkSpeed = mergedConfig.MoveSpeed end

	local self = setmetatable({
		model = monsterModel,
		primaryPart = primaryPart,
		humanoid = humanoid,
		grid = grid,
		config = mergedConfig,
		walkTrack = humanoid and loadAnimationTrack(humanoid, mergedConfig.WalkAnimationId, true) or nil,
		runTrack = humanoid and loadAnimationTrack(humanoid, mergedConfig.RunAnimationId, true) or nil,
		attackTrack = humanoid and loadAnimationTrack(humanoid, mergedConfig.AttackAnimationId, false) or nil,
		isRunning = false,
		state = "Idle" :: State,
		target = nil :: Model?,
		health = mergedConfig.MaxHealth,
		searchTimer = 0,
		wanderTimer = 0,
		fleeTimer = 0,
		attackCooldownTimer = 0,
		pathTimer = 0,
		currentPath = nil :: { Vector3 }?,
		pathVersion = 0,
		cframeWaypointIndex = 1,
		wanderTarget = nil :: Vector3?,
	}, MonsterFSM)
	return self
end

function MonsterFSM.SetTarget(self: MonsterFSM, target: Model?) self.target = target end
function MonsterFSM.TakeDamage(self: MonsterFSM, amount: number) self.health = math.max(0, self.health - amount) end
function MonsterFSM.GetState(self: MonsterFSM): State return self.state end
function MonsterFSM.GetCurrentPath(self: MonsterFSM): { Vector3 }? return self.currentPath end
function MonsterFSM._getTargetRootPart(self: MonsterFSM): BasePart?
	if not self.target then return nil end
	return self.target:FindFirstChild("HumanoidRootPart") :: BasePart?
end

function MonsterFSM._canSeeTarget(self: MonsterFSM, targetPos: Vector3): boolean
	local eyePos = self.primaryPart.Position + Vector3.new(0, self.config.EyeHeight, 0)
	return LineOfSight.HasClearSight(eyePos, targetPos, { self.model, self.target :: Instance })
end

function MonsterFSM._setRunning(self: MonsterFSM, isRunning: boolean)
	if self.isRunning == isRunning then return end
	self.isRunning = isRunning
	if self.humanoid then self.humanoid.WalkSpeed = isRunning and self.config.ChaseSpeed or self.config.MoveSpeed end
end

function MonsterFSM._setMoving(self: MonsterFSM, isMoving: boolean)
	local activeTrack = self.isRunning and self.runTrack or self.walkTrack
	local inactiveTrack = self.isRunning and self.walkTrack or self.runTrack
	if inactiveTrack and inactiveTrack.IsPlaying then inactiveTrack:Stop() end
	if not activeTrack then return end
	if isMoving and not activeTrack.IsPlaying then
		activeTrack:Play()
	elseif not isMoving and activeTrack.IsPlaying then
		activeTrack:Stop()
	end
end

function MonsterFSM._playAttackAnimation(self: MonsterFSM)
	if self.attackTrack then self.attackTrack:Play() end
end
-- Walks via MoveTo + MoveToFinished (Roblox's own waypoint-following pattern) instead of polling distance every frame -- Humanoid decides
-- arrival itself. pathVersion cancels a stale task at its next waypoint.
function MonsterFSM._walkHumanoidPath(self: MonsterFSM, path: { Vector3 }?)
	self.pathVersion += 1
	local version = self.pathVersion
	local humanoid = self.humanoid
	if not path or #path == 0 or not humanoid then self:_setMoving(false) return end
	self:_setMoving(true)
	task.spawn(function()
		for i = 2, #path do -- path[1] is ~the monster's own position already
			if self.pathVersion ~= version or self.humanoid ~= humanoid then return end
			humanoid:MoveTo(path[i])
			local reached = humanoid.MoveToFinished:Wait()
			if self.pathVersion ~= version then return end
			if not reached then break end
		end
		if self.pathVersion == version then self:_setMoving(false) end
	end)
end

-- Fallback for non-Humanoid placeholder models: steps PrimaryPart's CFrame.
function MonsterFSM._followCFramePath(self: MonsterFSM, dt: number)
	local path = self.currentPath
	if not path or #path == 0 then return end
	local waypoint = path[self.cframeWaypointIndex]
	if not waypoint then return end
	local current = self.primaryPart.Position
	local toWaypoint = waypoint - current
	local flatDistance = Vector3.new(toWaypoint.X, 0, toWaypoint.Z).Magnitude
	if flatDistance <= self.config.WaypointReachedDistance then self.cframeWaypointIndex += 1 return end
	self:_setMoving(true)
	local direction = toWaypoint.Unit
	local step = direction * (self.isRunning and self.config.ChaseSpeed or self.config.MoveSpeed) * dt
	local newPos = current + Vector3.new(step.X, 0, step.Z)
	self.model:PivotTo(CFrame.lookAt(newPos, newPos + Vector3.new(direction.X, 0, direction.Z)))
end

-- Recomputes path to `destination` (throttled), walks it, steps CFrame fallback.
function MonsterFSM._moveTowards(self: MonsterFSM, destination: Vector3, dt: number)
	self.pathTimer -= dt
	if self.pathTimer <= 0 or not self.currentPath then
		self.pathTimer = self.config.PathRecalcInterval
		local path = AStar.FindPath(self.grid, self.primaryPart.Position, destination)
		if path then path = PathSmoothing.StringPull(self.grid, path) end
		self.currentPath = path
		self.cframeWaypointIndex = 1
		if self.humanoid then self:_walkHumanoidPath(path) end
	end
	if not self.humanoid then self:_followCFramePath(dt) end
end

function MonsterFSM._clearPath(self: MonsterFSM)
	self.pathVersion += 1 -- invalidates any in-flight _walkHumanoidPath task
	self.currentPath = nil
	self.cframeWaypointIndex = 1
	self:_setMoving(false)
	if self.humanoid then self.humanoid:Move(Vector3.new(0, 0, 0)) end
end
-- Picks a random point within WanderRadius, repicking every WanderInterval
function MonsterFSM._wander(self: MonsterFSM, dt: number)
	self.wanderTimer -= dt
	if self.wanderTimer <= 0 or not self.wanderTarget then
		self.wanderTimer = self.config.WanderInterval
		local angle, radius = math.random() * math.pi * 2, math.random() * self.config.WanderRadius
		self.wanderTarget = self.primaryPart.Position + Vector3.new(math.cos(angle) * radius, 0, math.sin(angle) * radius)
		self.pathTimer = 0
	end
	self:_moveTowards(self.wanderTarget :: Vector3, dt)
end

function MonsterFSM._transitionTo(self: MonsterFSM, newState: State)
	if self.state == newState then return end
	self.state = newState
	if newState == "Search" then
		self.searchTimer = self.config.SearchDuration
		self.wanderTimer = 0
		self:_setRunning(false)
	elseif newState == "Idle" then
		self.wanderTimer = 0
		self:_setRunning(false)
	elseif newState == "Chase" then
		self:_setRunning(true)
	elseif newState == "Flee" then
		self.fleeTimer = self.config.FleeDuration
		self:_setRunning(true)
	elseif newState == "Attack" then
		self:_clearPath()
		self:_setRunning(false)
		self.attackCooldownTimer = 0
	end
end

function MonsterFSM.Update(self: MonsterFSM, dt: number)
	local targetRoot = self:_getTargetRootPart()
	local distance = math.huge
	local canSee = false
	if targetRoot then
		distance = (targetRoot.Position - self.primaryPart.Position).Magnitude
		canSee = distance <= self.config.LoseSightRadius and self:_canSeeTarget(targetRoot.Position)
	end

	local isLowHealth = self.health <= self.config.MaxHealth * self.config.FleeHealthThreshold
	if isLowHealth and self.state ~= "Flee" then self:_transitionTo("Flee") end

	if self.state == "Flee" then
		self.fleeTimer -= dt
		if self.fleeTimer <= 0 and not isLowHealth then self:_transitionTo("Idle") return end
		local fleeTarget = self.primaryPart.Position
		if targetRoot then
			local away = self.primaryPart.Position - targetRoot.Position
			if away.Magnitude > 0.01 then fleeTarget = self.primaryPart.Position + away.Unit * 30 end
		end
		self:_moveTowards(fleeTarget, dt)
		return
	end

	if self.state == "Idle" then
		if canSee and distance <= self.config.DetectionRadius then
			self:_transitionTo("Chase")
		else
			self:_wander(dt)
		end
	elseif self.state == "Chase" then
		if canSee and distance <= self.config.AttackRange then
			self:_transitionTo("Attack")
		elseif not canSee or distance > self.config.LoseSightRadius then
			self:_transitionTo("Search")
		else
			self:_moveTowards((targetRoot :: BasePart).Position, dt)
		end
	elseif self.state == "Attack" then
		if not targetRoot or not canSee or distance > self.config.AttackRange then
			self:_transitionTo("Chase")
		else
			self.attackCooldownTimer -= dt
			if self.attackCooldownTimer <= 0 then
				self.attackCooldownTimer = self.config.AttackCooldown
				self:_playAttackAnimation()
				local targetHumanoid = self.target and self.target:FindFirstChildOfClass("Humanoid")
				if targetHumanoid then targetHumanoid:TakeDamage(self.config.AttackDamage) end
			end
		end
	elseif self.state == "Search" then
		self.searchTimer -= dt
		if canSee and distance <= self.config.DetectionRadius then
			self:_transitionTo("Chase")
		elseif self.searchTimer <= 0 then
			self:_transitionTo("Idle")
		else
			self:_wander(dt)
		end
	end
end

return MonsterFSM
