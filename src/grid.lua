-- Simple uniform spatial hash grid used for fast neighbor queries.
local Grid = {}
Grid.__index = Grid

function Grid.new(cellSize)
    return setmetatable({ cellSize = cellSize, buckets = {} }, Grid)
end

function Grid:clear()
    self.buckets = {}
end

function Grid:insert(entity)
    local cx = math.floor(entity.x / self.cellSize)
    local cy = math.floor(entity.y / self.cellSize)
    local key = cx * 100000 + cy
    local bucket = self.buckets[key]
    if not bucket then
        bucket = {}
        self.buckets[key] = bucket
    end
    bucket[#bucket + 1] = entity
end

-- Returns all entities within `radius` of (x, y). Appends into `results` if given.
function Grid:queryRadius(x, y, radius, results)
    results = results or {}
    local cs = self.cellSize
    local minCx, maxCx = math.floor((x - radius) / cs), math.floor((x + radius) / cs)
    local minCy, maxCy = math.floor((y - radius) / cs), math.floor((y + radius) / cs)
    local r2 = radius * radius
    for cx = minCx, maxCx do
        for cy = minCy, maxCy do
            local bucket = self.buckets[cx * 100000 + cy]
            if bucket then
                for i = 1, #bucket do
                    local e = bucket[i]
                    local dx, dy = e.x - x, e.y - y
                    if dx * dx + dy * dy <= r2 then
                        results[#results + 1] = e
                    end
                end
            end
        end
    end
    return results
end

return Grid
