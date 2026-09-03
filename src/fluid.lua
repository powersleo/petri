-- A coarse velocity-field simulation for the dish's water. Shake, tilt, and
-- swipe all inject velocity into this one field instead of shoving cells
-- directly; the field decays and diffuses every frame like viscosity
-- spreading motion out, and cells/food continuously drift with whatever
-- current sits under them -- currents can keep moving things after you've
-- stopped touching the screen, the same way real water doesn't stop the
-- instant you stop stirring it.
--
-- Deliberately simple: decay + a 4-neighbor blur, no pressure/incompress-
-- ibility solve. A real Navier-Stokes solver is overkill for a petri dish
-- and too expensive for a 60fps mobile budget; this reads as "water"
-- without the cost.
local Fluid = {}
Fluid.__index = Fluid

local DEFAULT_DECAY = 0.90 -- fraction of velocity kept per frame (viscosity/drag) -- adjustable per-instance, see setDecay
local DIFFUSE_RATE = 0.25  -- how far each cell blends toward its neighbors' average per frame
Fluid.MIN_DECAY = 0.75     -- thick/syrupy: currents die out almost immediately
Fluid.MAX_DECAY = 0.98     -- thin/runny: currents barely lose energy, drift for a long time

function Fluid.new(width, height, cellSize)
    local self = setmetatable({}, Fluid)
    self.cellSize = cellSize or 40
    self.cols = math.max(1, math.ceil(width / self.cellSize))
    self.rows = math.max(1, math.ceil(height / self.cellSize))
    self.decay = DEFAULT_DECAY
    self.vx = {}
    self.vy = {}
    for i = 1, self.cols * self.rows do
        self.vx[i] = 0
        self.vy[i] = 0
    end
    return self
end

-- Viscosity control: how much velocity survives each frame. Lower = more
-- drag = thicker water that resists flowing; higher = thinner water that
-- keeps moving longer on its own.
function Fluid:setDecay(d)
    self.decay = math.max(Fluid.MIN_DECAY, math.min(Fluid.MAX_DECAY, d))
end

function Fluid:index(cx, cy)
    return cy * self.cols + cx + 1
end

function Fluid:clampCell(cx, cy)
    return math.max(0, math.min(self.cols - 1, cx)), math.max(0, math.min(self.rows - 1, cy))
end

-- Adds velocity to every grid cell within `radius` of a world point, falling
-- off linearly with distance -- a local, directed impulse (a swipe).
function Fluid:addVelocity(wx, wy, dvx, dvy, radius)
    local cx0, cy0 = self:clampCell(math.floor((wx - radius) / self.cellSize), math.floor((wy - radius) / self.cellSize))
    local cx1, cy1 = self:clampCell(math.floor((wx + radius) / self.cellSize), math.floor((wy + radius) / self.cellSize))
    for cy = cy0, cy1 do
        for cx = cx0, cx1 do
            local wcx, wcy = (cx + 0.5) * self.cellSize, (cy + 0.5) * self.cellSize
            local dx, dy = wcx - wx, wcy - wy
            local dist = math.sqrt(dx * dx + dy * dy)
            if dist <= radius then
                local i = self:index(cx, cy)
                local falloff = 1 - dist / radius
                self.vx[i] = self.vx[i] + dvx * falloff
                self.vy[i] = self.vy[i] + dvy * falloff
            end
        end
    end
end

-- Adds the same velocity to the whole field -- tilt's continuous "gravity
-- pulls the water downhill" force.
function Fluid:addUniformVelocity(dvx, dvy)
    for i = 1, self.cols * self.rows do
        self.vx[i] = self.vx[i] + dvx
        self.vy[i] = self.vy[i] + dvy
    end
end

-- Independent random kick per cell (not a shared direction) -- turbulence,
-- for a shake.
function Fluid:agitate(strength)
    for i = 1, self.cols * self.rows do
        local angle = love.math.random() * math.pi * 2
        local mag = love.math.random() * strength
        self.vx[i] = self.vx[i] + math.cos(angle) * mag
        self.vy[i] = self.vy[i] + math.sin(angle) * mag
    end
end

function Fluid:update(dt)
    local newVx, newVy = {}, {}
    local decay = self.decay ^ (dt * 60) -- tuned per-frame at 60fps; scale so frame-rate hiccups don't change the feel
    for cy = 0, self.rows - 1 do
        for cx = 0, self.cols - 1 do
            local i = self:index(cx, cy)
            local sumX, sumY, count = self.vx[i], self.vy[i], 1
            if cx > 0 then
                local ni = self:index(cx - 1, cy)
                sumX, sumY, count = sumX + self.vx[ni], sumY + self.vy[ni], count + 1
            end
            if cx < self.cols - 1 then
                local ni = self:index(cx + 1, cy)
                sumX, sumY, count = sumX + self.vx[ni], sumY + self.vy[ni], count + 1
            end
            if cy > 0 then
                local ni = self:index(cx, cy - 1)
                sumX, sumY, count = sumX + self.vx[ni], sumY + self.vy[ni], count + 1
            end
            if cy < self.rows - 1 then
                local ni = self:index(cx, cy + 1)
                sumX, sumY, count = sumX + self.vx[ni], sumY + self.vy[ni], count + 1
            end
            local avgX, avgY = sumX / count, sumY / count
            newVx[i] = (self.vx[i] + (avgX - self.vx[i]) * DIFFUSE_RATE) * decay
            newVy[i] = (self.vy[i] + (avgY - self.vy[i]) * DIFFUSE_RATE) * decay
        end
    end
    self.vx, self.vy = newVx, newVy
end

-- Bilinear-sampled velocity at any world point, so an entity feels a smooth
-- current instead of snapping between blocky grid cells as it moves.
function Fluid:sample(wx, wy)
    local fx = wx / self.cellSize - 0.5
    local fy = wy / self.cellSize - 0.5
    local cx0, cy0 = math.floor(fx), math.floor(fy)
    local tx, ty = fx - cx0, fy - cy0
    local cxa, cya = self:clampCell(cx0, cy0)
    local cxb, cyb = self:clampCell(cx0 + 1, cy0 + 1)
    local i00, i10 = self:index(cxa, cya), self:index(cxb, cya)
    local i01, i11 = self:index(cxa, cyb), self:index(cxb, cyb)
    local vx = self.vx[i00] * (1 - tx) * (1 - ty) + self.vx[i10] * tx * (1 - ty)
        + self.vx[i01] * (1 - tx) * ty + self.vx[i11] * tx * ty
    local vy = self.vy[i00] * (1 - tx) * (1 - ty) + self.vy[i10] * tx * (1 - ty)
        + self.vy[i01] * (1 - tx) * ty + self.vy[i11] * tx * ty
    return vx, vy
end

return Fluid
