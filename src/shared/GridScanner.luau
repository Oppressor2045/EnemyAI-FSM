--!strict

local GridScanner = {}
GridScanner.__index = GridScanner

local DEFAULT_CELL_SIZE = 4
local DEFAULT_MAX_STEP_HEIGHT = 3 -- studs; how big a height jump between adjacent cells still counts as walkable (stairs, curbs)
local RAY_HEIGHT = 200 -- scan start height offset above the region's top corner
local MIN_FLOOR_NORMAL_Y = 0.7 -- surfaces must be at least this flat to be walkable
local OBSTACLE_CHECK_HEIGHT = 5 -- height of the overlap box used to detect obstacles above the floor

export type Cell = {
	gx: number,
	gz: number,
	position: Vector3?,
	walkable: boolean,
}

-- Typed via typeof(setmetatable(...)) so every method below has a concrete
-- `self` type -- otherwise strict mode can't confirm fields like
-- self.minCorner/self.cells exist and underlines them despite being set in
-- GridScanner.new().
type GridScannerFields = {
	minCorner: Vector3,
	maxCorner: Vector3,
	cellSize: number,
	maxStepHeight: number,
	cells: { [string]: Cell },
	raycastParams: RaycastParams,
	overlapParams: OverlapParams,
}

export type GridScanner = typeof(setmetatable({} :: GridScannerFields, GridScanner))

function GridScanner.new(minCorner: Vector3, maxCorner: Vector3, cellSize: number?, maxStepHeight: number?): GridScanner
	local raycastParams = RaycastParams.new()
	raycastParams.FilterType = Enum.RaycastFilterType.Exclude
	raycastParams.FilterDescendantsInstances = {}

	local overlapParams = OverlapParams.new()
	overlapParams.FilterType = Enum.RaycastFilterType.Exclude
	overlapParams.FilterDescendantsInstances = {}

	-- Normalize so the scanner works correctly no matter which corner was
	-- passed as "min" and which as "max"
	local self = setmetatable({
		minCorner = Vector3.new(
			math.min(minCorner.X, maxCorner.X),
			math.min(minCorner.Y, maxCorner.Y),
			math.min(minCorner.Z, maxCorner.Z)
		),
		maxCorner = Vector3.new(
			math.max(minCorner.X, maxCorner.X),
			math.max(minCorner.Y, maxCorner.Y),
			math.max(minCorner.Z, maxCorner.Z)
		),
		cellSize = cellSize or DEFAULT_CELL_SIZE,
		maxStepHeight = maxStepHeight or DEFAULT_MAX_STEP_HEIGHT,
		cells = {} :: { [string]: Cell },
		raycastParams = raycastParams,
		overlapParams = overlapParams,
	}, GridScanner)

	return self
end

function GridScanner._key(self: GridScanner, gx: number, gz: number): string
	return gx .. "," .. gz
end

function GridScanner._worldToGrid(self: GridScanner, pos: Vector3): (number, number)
	local gx = math.floor((pos.X - self.minCorner.X) / self.cellSize)
	local gz = math.floor((pos.Z - self.minCorner.Z) / self.cellSize)
	return gx, gz
end

function GridScanner._gridToWorldCenterXZ(self: GridScanner, gx: number, gz: number): Vector3
	local x = self.minCorner.X + (gx + 0.5) * self.cellSize
	local z = self.minCorner.Z + (gz + 0.5) * self.cellSize
	return Vector3.new(x, 0, z)
end

-- Raycasts a single cell only; does not classify the result
function GridScanner._raycastCell(self: GridScanner, gx: number, gz: number): RaycastResult?
	local centerXZ = self:_gridToWorldCenterXZ(gx, gz)
	local rayOrigin = Vector3.new(centerXZ.X, self.maxCorner.Y + RAY_HEIGHT, centerXZ.Z)
	return workspace:Raycast(rayOrigin, Vector3.new(0, -(RAY_HEIGHT * 2), 0), self.raycastParams)
end

-- Decides walkability purely from the local surface: flat enough, and no
-- obstacle sitting on top of it. Does NOT compare against other cells --
-- that comparison happens per-edge in AStar via MaxStepHeight.
function GridScanner._classifyCell(self: GridScanner, gx: number, gz: number, hit: RaycastResult?)
	local cellKey = self:_key(gx, gz)

	if not hit then
		self.cells[cellKey] = { gx = gx, gz = gz, position = nil, walkable = false }
		return
	end

	local isFlatEnough = hit.Normal.Y >= MIN_FLOOR_NORMAL_Y
	local worldPos = hit.Position

	local checkCFrame = CFrame.new(worldPos + Vector3.new(0, OBSTACLE_CHECK_HEIGHT / 2 + 0.1, 0))
	local checkSize = Vector3.new(self.cellSize * 0.9, OBSTACLE_CHECK_HEIGHT, self.cellSize * 0.9)
	local overlapping = workspace:GetPartBoundsInBox(checkCFrame, checkSize, self.overlapParams)
	local blocked = #overlapping > 0

	self.cells[cellKey] = {
		gx = gx,
		gz = gz,
		position = worldPos,
		walkable = isFlatEnough and not blocked,
	}
end

-- Rescans a single cell (used for dynamic updates)
function GridScanner.ScanCell(self: GridScanner, gx: number, gz: number)
	local hit = self:_raycastCell(gx, gz)
	self:_classifyCell(gx, gz, hit)
end

-- Scans the whole region (intended for the initial one-time build; expensive
-- for large regions, so avoid calling repeatedly).
function GridScanner.ScanAll(self: GridScanner)
	local gxMax = math.floor((self.maxCorner.X - self.minCorner.X) / self.cellSize)
	local gzMax = math.floor((self.maxCorner.Z - self.minCorner.Z) / self.cellSize)

	for gx = 0, gxMax do
		for gz = 0, gzMax do
			self:ScanCell(gx, gz)
		end
	end
end

-- Rescans only the world-space region that changed (used for dynamic obstacles)
function GridScanner.RescanRegion(self: GridScanner, worldMin: Vector3, worldMax: Vector3)
	local gxMin, gzMin = self:_worldToGrid(worldMin)
	local gxMax, gzMax = self:_worldToGrid(worldMax)

	for gx = gxMin, gxMax do
		for gz = gzMin, gzMax do
			self:ScanCell(gx, gz)
		end
	end
end

function GridScanner.GetCell(self: GridScanner, gx: number, gz: number): Cell?
	return self.cells[self:_key(gx, gz)]
end

function GridScanner.GetClosestCellCoords(self: GridScanner, worldPos: Vector3): (number, number)
	return self:_worldToGrid(worldPos)
end

-- Whether a Humanoid could step directly from cell A to adjacent cell B,
-- based on the height difference between their surfaces
function GridScanner.CanStepBetween(self: GridScanner, cellA: Cell, cellB: Cell): boolean
	if not cellA.position or not cellB.position then
		return false
	end
	return math.abs(cellA.position.Y - cellB.position.Y) <= self.maxStepHeight
end

return GridScanner
