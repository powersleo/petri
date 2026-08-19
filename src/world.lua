-- Owns the population, food, and spatial index. Drives one simulation tick.
local Grid = require("src.grid")
local Cell = require("src.cell")
local Genome = require("src.genome")

local World = {}
World.__index = World

local FOOD_RADIUS = 3
local FOOD_SPAWN_INTERVAL = 0.1 -- seconds between spawn attempts
local FOOD_CAP = 400
local GRID_CELL_SIZE = 60

-- Food sources are larger, longer-lived nutrient patches: several cells
-- can feed from the same one over time (it shrinks with each bite)
-- instead of it vanishing after a single visit like regular food.
local FOOD_SOURCE_RADIUS = 11
local FOOD_SOURCE_BITES = 10
local FOOD_SOURCE_SPAWN_INTERVAL = 15 -- seconds between spawn attempts
local FOOD_SOURCE_CAP = 6

-- Mega food: a rare, much bigger deposit -- effectively three food
-- sources' worth in one spot.
local MEGA_FOOD_RADIUS = 20
local MEGA_FOOD_BITES = 30
local MEGA_FOOD_SPAWN_INTERVAL = 45 -- seconds between spawn attempts
local MEGA_FOOD_CAP = 2

-- Food hotspots: a handful of fixed zones where spawns land far more
-- often than the rest of the map. Herbivores cluster there for the easy
-- pickings, which in turn gives predators a reliable hunting ground --
-- no predator-specific rule needed, just prey density doing its thing.
local HOTSPOT_COUNT = 4
local HOTSPOT_RADIUS = 150
local HOTSPOT_BIAS_CHANCE = 0.28

local PREDATOR_SEED_FRACTION = 0.15 -- fraction of a freshly-spawned population nudged toward predation

-- Safety valve, independent of any trait balance: energy sources like
-- chlorophyll aren't limited by a shared/competed resource the way food
-- is, so a lineage that gets efficient enough could in principle grow
-- without bound. This caps it well above anything foraging alone would
-- sustain, purely to keep the simulation from grinding to a halt.
local MAX_POPULATION = 1000

-- Visual style for the death-burst effect, keyed by Cell.deathCause.
local DEATH_EFFECT_STYLES = {
    starved = { color = { 0.8, 0.75, 0.55 }, duration = 0.5, burst = 1.6 },
    old_age = { color = { 0.78, 0.68, 0.98 }, duration = 0.9, burst = 1.3 },
    eaten   = { color = { 1.0, 0.25, 0.15 }, duration = 0.4, burst = 2.4 },
    spiked  = { color = { 0.85, 0.85, 0.92 }, duration = 0.4, burst = 2.0 },
    envenomed = { color = { 0.55, 0.15, 0.75 }, duration = 0.45, burst = 1.9 },
}
local DEFAULT_DEATH_STYLE = { color = { 0.7, 0.7, 0.7 }, duration = 0.5, burst = 1.6 }

function World.new(width, height)
    local self = setmetatable({}, World)
    self.width, self.height = width, height
    self.cells = {}
    self.food = {}
    self.effects = {}
    self.grid = Grid.new(GRID_CELL_SIZE)
    self.foodTimer = 0
    self.foodSourceTimer = FOOD_SOURCE_SPAWN_INTERVAL
    self.megaFoodTimer = MEGA_FOOD_SPAWN_INTERVAL
    self.time = 0
    self.stats = { population = 0, predators = 0, herbivores = 0, avg = {} }

    self.hotspots = {}
    for _ = 1, HOTSPOT_COUNT do
        self.hotspots[#self.hotspots + 1] = {
            x = HOTSPOT_RADIUS + love.math.random() * (width - HOTSPOT_RADIUS * 2),
            y = HOTSPOT_RADIUS + love.math.random() * (height - HOTSPOT_RADIUS * 2),
        }
    end

    return self
end

-- Most spawns land uniformly at random; the rest land inside a randomly
-- chosen hotspot, biasing density toward those zones over time.
function World:randomSpawnPosition()
    if #self.hotspots > 0 and love.math.random() < HOTSPOT_BIAS_CHANCE then
        local h = self.hotspots[love.math.random(#self.hotspots)]
        local angle = love.math.random() * math.pi * 2
        local dist = love.math.random() * HOTSPOT_RADIUS
        local x = math.max(0, math.min(self.width, h.x + math.cos(angle) * dist))
        local y = math.max(0, math.min(self.height, h.y + math.sin(angle) * dist))
        return x, y
    end
    return love.math.random() * self.width, love.math.random() * self.height
end

-- Spawns a brief, cause-styled burst where a cell just died: a dim wilt
-- for starvation, a soft fade for old age, a sharp red splash for
-- predation. Purely cosmetic -- no gameplay effect.
function World:spawnDeathEffect(cell)
    local style = DEATH_EFFECT_STYLES[cell.deathCause] or DEFAULT_DEATH_STYLE
    self.effects[#self.effects + 1] = {
        x = cell.x,
        y = cell.y,
        size = cell.genome.size * 1.4,
        style = style,
        t = 0,
    }
end

-- Hard boundary: entities are clamped to stay inside the world rather than
-- wrapping to the opposite edge. Keeps the center at least the entity's own
-- radius away from each wall so its drawn body doesn't poke through.
function World:constrain(entity)
    local margin = (entity.genome and entity.genome.size) or 0
    if entity.x < margin then entity.x = margin end
    if entity.x > self.width - margin then entity.x = self.width - margin end
    if entity.y < margin then entity.y = margin end
    if entity.y > self.height - margin then entity.y = self.height - margin end
end

-- A fresh population starts mostly herbivorous but with a visible minority
-- already leaning predatory, so the predator/prey dynamic is on screen
-- from the first frame instead of depending on a lucky mutation streak.
-- `uniform`, if true, spawns identical default-genome clones with no
-- predator seeding -- for starting the map from a single common ancestor
-- so whatever diversity shows up later (predators included) is purely
-- the result of mutation and selection playing out, not a head start.
function World:spawnInitialPopulation(n, uniform)
    -- A uniform start represents one common ancestor, so the whole founding
    -- population shares a single tribe at generation zero -- any clan
    -- diversity later comes purely from tribe-founding events, not a head
    -- start. A randomized start has no shared ancestor, so each founder
    -- gets its own tribe (Cell.new's default when no parent is given).
    local sharedTribeId = uniform and Cell.allocTribeId() or nil
    for _ = 1, n do
        local g
        if uniform then
            g = Genome.default()
        else
            g = Genome.randomized(0.35)
            if love.math.random() < PREDATOR_SEED_FRACTION then
                g.aggression = 0.3 + love.math.random() * 0.4
                g.size = math.min(16, g.size * 1.3)
            end
        end
        local x, y = love.math.random() * self.width, love.math.random() * self.height
        local cell = Cell.new(x, y, g)
        if sharedTribeId then cell.tribeId = sharedTribeId end
        table.insert(self.cells, cell)
    end
end

function World:spawnFood()
    local x, y = self:randomSpawnPosition()
    self:spawnFoodAt(x, y)
end

function World:spawnFoodAt(x, y)
    table.insert(self.food, { x = x, y = y, radius = FOOD_RADIUS, baseRadius = FOOD_RADIUS,
        remaining = 1, maxRemaining = 1, tier = "regular" })
end

-- A larger nutrient patch that survives several bites, shrinking each
-- time, before it's fully depleted and removed.
function World:spawnFoodSource()
    local x, y = self:randomSpawnPosition()
    table.insert(self.food, { x = x, y = y, radius = FOOD_SOURCE_RADIUS, baseRadius = FOOD_SOURCE_RADIUS,
        remaining = FOOD_SOURCE_BITES, maxRemaining = FOOD_SOURCE_BITES, tier = "source" })
end

-- Rarer still, and much bigger: roughly three food sources' worth in one
-- deposit.
function World:spawnMegaFoodSource()
    local x, y = self:randomSpawnPosition()
    table.insert(self.food, { x = x, y = y, radius = MEGA_FOOD_RADIUS, baseRadius = MEGA_FOOD_RADIUS,
        remaining = MEGA_FOOD_BITES, maxRemaining = MEGA_FOOD_BITES, tier = "mega" })
end

function World:countFoodByTier(tier)
    local count = 0
    for _, f in ipairs(self.food) do
        if f.tier == tier then count = count + 1 end
    end
    return count
end

-- Eating one bite out of a food item. Depletes it by one; only fully
-- removes it once its reserve is exhausted, shrinking it visually in the
-- meantime so its remaining capacity is legible at a glance.
function World:consumeFood(food)
    food.remaining = food.remaining - 1
    if food.remaining <= 0 then
        for i, f in ipairs(self.food) do
            if f == food then
                table.remove(self.food, i)
                return
            end
        end
    else
        local frac = food.remaining / food.maxRemaining
        food.radius = food.baseRadius * (0.4 + 0.6 * frac)
    end
end

-- Food count is kept small enough that a brute-force scan is cheap and
-- avoids needing a second spatial index.
function World:nearestFood(x, y, radius)
    local best, bestD2 = nil, radius * radius
    for _, f in ipairs(self.food) do
        local dx, dy = f.x - x, f.y - y
        local d2 = dx * dx + dy * dy
        if d2 <= bestD2 then
            best, bestD2 = f, d2
        end
    end
    return best
end

function World:queryCells(x, y, radius, exclude)
    local res = self.grid:queryRadius(x, y, radius, {})
    if not exclude then return res end
    local filtered = {}
    for _, c in ipairs(res) do
        if c ~= exclude then filtered[#filtered + 1] = c end
    end
    return filtered
end

function World:update(dt)
    self.time = self.time + dt

    self.foodTimer = self.foodTimer - dt
    if self.foodTimer <= 0 then
        self.foodTimer = FOOD_SPAWN_INTERVAL
        if #self.food < FOOD_CAP then
            self:spawnFood()
        end
    end

    self.foodSourceTimer = self.foodSourceTimer - dt
    if self.foodSourceTimer <= 0 then
        self.foodSourceTimer = FOOD_SOURCE_SPAWN_INTERVAL
        if self:countFoodByTier("source") < FOOD_SOURCE_CAP then
            self:spawnFoodSource()
        end
    end

    self.megaFoodTimer = self.megaFoodTimer - dt
    if self.megaFoodTimer <= 0 then
        self.megaFoodTimer = MEGA_FOOD_SPAWN_INTERVAL
        if self:countFoodByTier("mega") < MEGA_FOOD_CAP then
            self:spawnMegaFoodSource()
        end
    end

    self.grid:clear()
    for _, c in ipairs(self.cells) do self.grid:insert(c) end

    local newCells = {}
    for _, c in ipairs(self.cells) do
        if not c.dead then
            local child = c:update(dt, self)
            if child then newCells[#newCells + 1] = child end
        end
    end

    local alive = {}
    for _, c in ipairs(self.cells) do
        if c.dead then
            self:spawnDeathEffect(c)
        else
            alive[#alive + 1] = c
        end
    end
    for _, c in ipairs(newCells) do
        if #alive < MAX_POPULATION then alive[#alive + 1] = c end
    end
    self.cells = alive

    local liveEffects = {}
    for _, e in ipairs(self.effects) do
        e.t = e.t + dt
        if e.t < e.style.duration then liveEffects[#liveEffects + 1] = e end
    end
    self.effects = liveEffects

    self:updateStats()
end

function World:updateStats()
    local s = self.stats
    s.population = #self.cells
    local predators = 0
    local sums = {}
    for _, t in ipairs(Genome.TRAITS) do sums[t.key] = 0 end
    for _, c in ipairs(self.cells) do
        if c:isPredatorish() then predators = predators + 1 end
        for k in pairs(sums) do sums[k] = sums[k] + c.genome[k] end
    end
    s.predators = predators
    s.herbivores = s.population - predators
    s.avg = {}
    if s.population > 0 then
        for k, v in pairs(sums) do s.avg[k] = v / s.population end
    end
end

function World:draw()
    -- Hotspot backdrop: a soft glow (cheaply faked with a few overlapping
    -- low-alpha circles, since Love has no built-in radial gradient) so
    -- the rich zones are visible even where food hasn't filled in yet.
    for _, h in ipairs(self.hotspots) do
        for step = 4, 1, -1 do
            love.graphics.setColor(0.25, 0.6, 0.3, 0.035)
            love.graphics.circle("fill", h.x, h.y, HOTSPOT_RADIUS * (step / 4))
        end
    end

    -- Dish rim as two concentric strokes -- a bright inner edge plus a
    -- dimmer outer one -- so it reads as glass thickness rather than a
    -- flat drawn line.
    love.graphics.setColor(0.85, 0.92, 0.95, 0.5)
    love.graphics.setLineWidth(1.5)
    love.graphics.rectangle("line", 3, 3, self.width - 6, self.height - 6)
    love.graphics.setColor(0.32, 0.42, 0.55, 0.9)
    love.graphics.setLineWidth(2)
    love.graphics.rectangle("line", 0, 0, self.width, self.height)

    for _, f in ipairs(self.food) do
        if f.tier == "mega" then
            -- Mega deposit: a slow pulse and a wider glow ring to signal
            -- it's a rare, big find.
            local pulse = 0.85 + math.sin(self.time * 2 + f.x) * 0.15
            love.graphics.setColor(0.35, 0.6, 0.3, 0.35)
            love.graphics.setLineWidth(2)
            love.graphics.circle("line", f.x, f.y, f.baseRadius + 4)
            love.graphics.setColor(0.3, 0.55, 0.35, 0.5)
            love.graphics.circle("line", f.x, f.y, f.baseRadius)
            love.graphics.setColor(0.6, 1.0, 0.35, 1)
            love.graphics.circle("fill", f.x, f.y, f.radius * pulse)
        elseif f.tier == "source" then
            -- Food source: brighter fill that shrinks as it depletes,
            -- inside a static ring marking its original full size so
            -- how much is left reads at a glance.
            love.graphics.setColor(0.3, 0.55, 0.35, 0.5)
            love.graphics.setLineWidth(1.5)
            love.graphics.circle("line", f.x, f.y, f.baseRadius)
            love.graphics.setColor(0.45, 0.95, 0.4, 1)
            love.graphics.circle("fill", f.x, f.y, f.radius)
        else
            love.graphics.setColor(0.3, 0.75, 0.3, 1)
            love.graphics.circle("fill", f.x, f.y, f.radius)
        end
    end

    for _, c in ipairs(self.cells) do
        c:draw()
    end

    for _, e in ipairs(self.effects) do
        local prog = e.t / e.style.duration
        local fade = 1 - prog
        local col = e.style.color

        love.graphics.setColor(col[1], col[2], col[3], fade * 0.6)
        love.graphics.circle("fill", e.x, e.y, e.size * (1 - prog * 0.6))

        love.graphics.setColor(col[1], col[2], col[3], fade)
        love.graphics.setLineWidth(2.5)
        love.graphics.circle("line", e.x, e.y, e.size * (1 + prog * e.style.burst))
    end
end

return World
