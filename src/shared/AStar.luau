--!strict

local AStar = {}

local NEIGHBOR_OFFSETS = {
	{ 1, 0, 1.0 },
	{ -1, 0, 1.0 },
	{ 0, 1, 1.0 },
	{ 0, -1, 1.0 },
	{ 1, 1, 1.4142 },
	{ 1, -1, 1.4142 },
	{ -1, 1, 1.4142 },
	{ -1, -1, 1.4142 },
}

-- Small binary min-heap used as the open set.
-- Typed via typeof(setmetatable(...)) so Luau knows the shape of `self` in every method below
-- otherwise strict mode can't confirm fields like self.size/self.items exist and underlines them even though they're set in MinHeap.new().
type HeapEntry = { item: any, priority: number }
type MinHeapFields = { items: { HeapEntry }, size: number }

local MinHeap = {}
MinHeap.__index = MinHeap

export type MinHeap = typeof(setmetatable({} :: MinHeapFields, MinHeap))

function MinHeap.new(): MinHeap
	return setmetatable({ items = {}, size = 0 }, MinHeap)
end

function MinHeap.push(self: MinHeap, item: any, priority: number)
	self.size += 1
	self.items[self.size] = { item = item, priority = priority }
	local i = self.size
	while i > 1 do
		local parent = i // 2
		if self.items[parent].priority <= self.items[i].priority then
			break
		end
		self.items[parent], self.items[i] = self.items[i], self.items[parent]
		i = parent
	end
end

function MinHeap.pop(self: MinHeap): any
	if self.size == 0 then
		return nil
	end
	local top = self.items[1]
	self.items[1] = self.items[self.size]
	self.items[self.size] = nil
	self.size -= 1

	local i = 1
	while true do
		local left, right = i * 2, i * 2 + 1
		local smallest = i
		if left <= self.size and self.items[left].priority < self.items[smallest].priority then
			smallest = left
		end
		if right <= self.size and self.items[right].priority < self.items[smallest].priority then
			smallest = right
		end
		if smallest == i then
			break
		end
		self.items[i], self.items[smallest] = self.items[smallest], self.items[i]
		i = smallest
	end

	return top.item
end

function MinHeap.isEmpty(self: MinHeap): boolean
	return self.size == 0
end

local function key(gx: number, gz: number): string
	return gx .. "," .. gz
end

local function octileHeuristic(gx1: number, gz1: number, gx2: number, gz2: number): number
	local dx, dz = math.abs(gx1 - gx2), math.abs(gz1 - gz2)
	return math.max(dx, dz) + (math.sqrt(2) - 1) * math.min(dx, dz)
end

-- Prevents cutting across a corner: a diagonal move is only allowed if both
-- adjacent straight cells are walkable
local function canMoveDiagonal(grid: any, gx: number, gz: number, dx: number, dz: number): boolean
	local side1 = grid:GetCell(gx + dx, gz)
	local side2 = grid:GetCell(gx, gz + dz)
	return (side1 ~= nil and side1.walkable) and (side2 ~= nil and side2.walkable)
end

-- grid: a GridScanner instance (kept as `any` on purpose -- AStar only needs GetCell/GetClosestCellCoords/CanStepBetween,
-- so it stays decoupled from GridScanner's concrete type and can work with any object shaped the same way)
-- startPos/goalPos: world-space Vector3
-- returns: an array of waypoint Vector3s (start and goal included), or nil if no path exists
function AStar.FindPath(grid: any, startPos: Vector3, goalPos: Vector3): { Vector3 }?
	local sgx, sgz = grid:GetClosestCellCoords(startPos)
	local ggx, ggz = grid:GetClosestCellCoords(goalPos)

	local startCell = grid:GetCell(sgx, sgz)
	local goalCell = grid:GetCell(ggx, ggz)
	if not startCell or not goalCell or not startCell.walkable or not goalCell.walkable then
		return nil
	end

	local openHeap = MinHeap.new()
	local gScore: { [string]: number } = { [key(sgx, sgz)] = 0 }
	local cameFrom: { [string]: { number } } = {} -- child key -> parent {gx, gz}
	local closed: { [string]: boolean } = {}

	openHeap:push({ sgx, sgz }, octileHeuristic(sgx, sgz, ggx, ggz))

	while not openHeap:isEmpty() do
		local current = openHeap:pop()
		local cgx, cgz = current[1], current[2]
		local ck = key(cgx, cgz)

		-- Lazy deletion: the heap can hold stale duplicate entries for a cell
		-- whose gScore has since improved; skip anything already finalized
		if closed[ck] then
			continue
		end
		closed[ck] = true

		if cgx == ggx and cgz == ggz then
			-- Goal reached: walk cameFrom backwards to rebuild the path
			local waypoints: { Vector3 } = {}
			local traceCoords: { number }? = { cgx, cgz }

			while traceCoords do
				local cell = grid:GetCell(traceCoords[1], traceCoords[2])
				table.insert(waypoints, 1, (cell :: any).position)
				traceCoords = cameFrom[key(traceCoords[1], traceCoords[2])]
			end

			return waypoints
		end

		local currentCell = grid:GetCell(cgx, cgz)

		for _, offset in NEIGHBOR_OFFSETS do
			local dx, dz, cost = offset[1], offset[2], offset[3]
			local ngx, ngz = cgx + dx, cgz + dz
			local nk = key(ngx, ngz)

			if closed[nk] then
				continue
			end

			local neighborCell = grid:GetCell(ngx, ngz)
			if not neighborCell or not neighborCell.walkable then
				continue
			end

			-- Reject moves that require too big a height jump (a wall), while
			-- allowing small jumps (stairs, curbs) through
			if currentCell and not grid:CanStepBetween(currentCell, neighborCell) then
				continue
			end

			if dx ~= 0 and dz ~= 0 then
				if not canMoveDiagonal(grid, cgx, cgz, dx, dz) then
					continue
				end
			end

			local tentativeG = gScore[ck] + cost
			if tentativeG < (gScore[nk] or math.huge) then
				gScore[nk] = tentativeG
				cameFrom[nk] = { cgx, cgz }
				local f = tentativeG + octileHeuristic(ngx, ngz, ggx, ggz)
				openHeap:push({ ngx, ngz }, f)
			end
		end
	end

	return nil
end

return AStar
