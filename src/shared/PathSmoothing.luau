--!strict

local PathSmoothing = {}

-- Removes waypoints wherever there's a clear walkable line to a later one,
-- turning a jagged grid path into the shortest natural-looking route.
function PathSmoothing.StringPull(grid: any, path: { Vector3 }): { Vector3 }
	if #path <= 2 then
		return path
	end

	local cellSize = (grid :: any).cellSize or 4
	local function isClear(a: Vector3, b: Vector3): boolean
		local steps = math.max(1, math.ceil((b - a).Magnitude / cellSize))
		for step = 0, steps do
			local point = a:Lerp(b, step / steps)
			local gx, gz = grid:GetClosestCellCoords(point)
			local cell = grid:GetCell(gx, gz)
			if not cell or not cell.walkable then
				return false
			end
		end
		return true
	end

	local pulled = { path[1] }
	local i = 1
	while i < #path do
		local j = #path
		while j > i + 1 and not isClear(path[i], path[j]) do
			j -= 1
		end
		table.insert(pulled, path[j])
		i = j
	end
	return pulled
end

return PathSmoothing
