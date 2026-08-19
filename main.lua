local World = require("src.world")
local Genome = require("src.genome")
local Cell = require("src.cell")
local waterShaderSrc = require("src.water_shader")

local world
local paused = false
local timeScale = 1
local INITIAL_POPULATION = 90
local INITIAL_FOOD = 220

-- Pale, clear "lab water" tone rather than a murky dark tank -- both the
-- window background and the dish canvas clear to this.
local BACKGROUND_COLOR = { 0.86, 0.92, 0.94 }

-- Camera: `x`/`y` is the world-space point shown at the center of the
-- screen, `scale` is zoom. Scroll wheel zooms toward the cursor.
local camera = { x = 0, y = 0, scale = 1 }
local MIN_ZOOM = 0.4
local MAX_ZOOM = 6
local ZOOM_STEP = 1.15

local function screenToWorld(sx, sy)
    local w, h = love.graphics.getWidth(), love.graphics.getHeight()
    return camera.x + (sx - w / 2) / camera.scale,
        camera.y + (sy - h / 2) / camera.scale
end

-- The cell currently inspected via click, if any. Cleared on death or reset.
local selectedCell = nil

local function findCellAt(wx, wy)
    local hit, hitDist = nil, math.huge
    for _, c in ipairs(world.cells) do
        local dx, dy = c.x - wx, c.y - wy
        local d = math.sqrt(dx * dx + dy * dy)
        if d <= c:hitRadius() and d < hitDist then
            hit, hitDist = c, d
        end
    end
    return hit
end

-- Cell designer: a hand-picked genome the player can dial in trait-by-trait
-- and drop into the world, instead of waiting for evolution to produce it.
local designMode = false
local designGenome = nil
local designIndex = 1

local function spawnDesignedCellAt(wx, wy)
    local g = {}
    for k, v in pairs(designGenome) do g[k] = v end -- copy so each spawned cell owns its genome table
    table.insert(world.cells, Cell.new(wx, wy, g))
end

-- The scene (world + selection ring, not the HUD) is rendered into this
-- canvas at world scale (not screen scale) and then drawn back through the
-- camera transform with waterShader applied -- so the shimmer/vignette
-- stay confined to the dish itself and pan/zoom with it, instead of
-- washing over whatever empty window space surrounds it.
--
-- The canvas is padded past the world bounds because a cell right up
-- against the wall can still draw appendages (flagella, spikes, fangs)
-- and its contact shadow well past its own membrane; without the padding
-- those get hard-clipped at the canvas edge instead of fading into the
-- surrounding space the way they used to when the canvas was screen-sized.
local CANVAS_PADDING = 70
local sceneCanvas
local waterShader

local function ensureSceneCanvas()
    local w = world.width + CANVAS_PADDING * 2
    local h = world.height + CANVAS_PADDING * 2
    if not sceneCanvas or sceneCanvas:getWidth() ~= w or sceneCanvas:getHeight() ~= h then
        sceneCanvas = love.graphics.newCanvas(w, h)
    end
end

function love.load()
    love.window.setTitle("Evocell -- evolving petri dish")
    love.graphics.setBackgroundColor(BACKGROUND_COLOR)
    love.math.setRandomSeed(os.time())
    local w, h = love.graphics.getWidth(), love.graphics.getHeight()
    world = World.new(w, h)
    world:spawnInitialPopulation(INITIAL_POPULATION, true)
    for _ = 1, INITIAL_FOOD do world:spawnFood() end
    paused = false
    timeScale = 1
    camera.x, camera.y, camera.scale = w / 2, h / 2, 1
    selectedCell = nil
    designMode = false
    designGenome = Genome.default()
    designIndex = 1
    waterShader = love.graphics.newShader(waterShaderSrc)
    ensureSceneCanvas()
end

function love.update(dt)
    if paused then return end
    world:update(dt * timeScale)
end

local function drawUI()
    local s = world.stats
    local lines = {
        string.format("Population: %d   herbivore-ish: %d   predator-ish: %d",
            s.population, s.herbivores, s.predators),
        string.format("Food: %d   sources: %d   mega: %d",
            #world.food, world:countFoodByTier("source"), world:countFoodByTier("mega")),
        string.format("Avg speed: %.1f  size: %.1f  sense: %.0f",
            s.avg.speed or 0, s.avg.size or 0, s.avg.sense_radius or 0),
        string.format("Avg metabolism: %.2f  repro thresh: %.2f  aggression: %.2f",
            s.avg.metabolism or 0, s.avg.repro_threshold or 0, s.avg.aggression or 0),
        string.format("Avg armor: %.2f  toxicity: %.2f  camouflage: %.2f  flagella: %.2f  lifespan: %.0fs",
            s.avg.armor or 0, s.avg.toxicity or 0, s.avg.camouflage or 0, s.avg.flagella or 0, s.avg.lifespan or 0),
        string.format("Avg chlorophyll: %.2f  spikes: %.2f", s.avg.chlorophyll or 0, s.avg.spikes or 0),
        string.format("Avg boldness: %.2f  sociality: %.2f  forage persistence: %.2f",
            s.avg.boldness or 0, s.avg.sociality or 0, s.avg.forage_persistence or 0),
        string.format("Avg bite power: %.2f  venom: %.2f  pack hunting: %.2f",
            s.avg.bite_power or 0, s.avg.venom or 0, s.avg.pack_hunting or 0),
        string.format("Time: %.0fs   sim speed: x%.1f   zoom: x%.1f%s",
            world.time, timeScale, camera.scale, paused and "   [PAUSED]" or ""),
        "[space] pause  [r] reset  [up/down] sim speed  [scroll] zoom  [f] food burst  [c] add cells",
        "[click cell] inspect it   [click empty] drop food   [d] cell designer",
    }
    love.graphics.setColor(0, 0, 0, 0.5)
    love.graphics.rectangle("fill", 4, 4, 460, 8 + #lines * 16)
    love.graphics.setColor(1, 1, 1, 0.9)
    for i, line in ipairs(lines) do
        love.graphics.print(line, 10, 6 + (i - 1) * 16)
    end
end

local function drawSelectedInfo()
    if not selectedCell or selectedCell.dead then return end
    local c, g = selectedCell, selectedCell.genome
    local energyPct = math.max(0, math.min(1, c.energy / c.maxEnergy)) * 100
    local panelW = 300
    local panelX = love.graphics.getWidth() - panelW - 10

    local lines = {
        string.format("Selected cell -- %s", c:isPredatorish() and "predator" or "herbivore"),
        string.format("State: %s   Energy: %.0f%%   Tribe: #%d", c.state, energyPct, c.tribeId),
        string.format("Age: %.0fs / %.0fs lifespan", c.age, c.lifespanActual),
        string.format("speed %.1f  size %.1f  sense %.0f", g.speed, g.size, g.sense_radius),
        string.format("metabolism %.2f  repro thresh %.2f", g.metabolism, g.repro_threshold),
        string.format("aggression %.2f  armor %.2f", g.aggression, g.armor),
        string.format("toxicity %.2f  camouflage %.2f", g.toxicity, g.camouflage),
        string.format("flagella %.2f  lifespan trait %.0fs", g.flagella, g.lifespan),
        string.format("chlorophyll %.2f  spikes %.2f", g.chlorophyll, g.spikes),
        string.format("boldness %.2f  sociality %.2f", g.boldness, g.sociality),
        string.format("forage persistence %.2f", g.forage_persistence),
        string.format("bite power %.2f  venom %.2f  pack hunting %.2f", g.bite_power, g.venom, g.pack_hunting),
    }
    if c.jackpotTrait then
        lines[#lines + 1] = string.format("Jackpot mutation at birth: %s", c.jackpotTrait)
    end

    local panelH = 8 + #lines * 16
    love.graphics.setColor(0, 0, 0, 0.55)
    love.graphics.rectangle("fill", panelX - 10, 4, panelW, panelH)
    love.graphics.setColor(1, 1, 1, 0.95)
    for i, line in ipairs(lines) do
        love.graphics.print(line, panelX, 8 + (i - 1) * 16)
    end
end

local DESIGN_BAR_LEN = 22

local function drawDesignPanel()
    if not designMode then return end
    local w, h = love.graphics.getWidth(), love.graphics.getHeight()
    local panelW = 380
    local panelH = 56 + #Genome.TRAITS * 16 + 40
    local px, py = (w - panelW) / 2, (h - panelH) / 2

    love.graphics.setColor(0, 0, 0, 0.8)
    love.graphics.rectangle("fill", px, py, panelW, panelH)
    love.graphics.setColor(1, 1, 1, 0.95)
    love.graphics.print("Cell Designer -- build a genome, then place it", px + 12, py + 8)

    for i, t in ipairs(Genome.TRAITS) do
        local frac = (designGenome[t.key] - t.min) / (t.max - t.min)
        local filled = math.floor(frac * DESIGN_BAR_LEN + 0.5)
        local bar = string.rep("#", filled) .. string.rep("-", DESIGN_BAR_LEN - filled)
        local valueStr = (t.key == "lifespan") and string.format("%.0fs", designGenome[t.key])
            or string.format("%.2f", designGenome[t.key])
        local marker = (i == designIndex) and "> " or "  "
        local line = string.format("%s%-14s [%s] %s", marker, t.key, bar, valueStr)
        if i == designIndex then
            love.graphics.setColor(1, 1, 0.4, 1)
        else
            love.graphics.setColor(1, 1, 1, 0.8)
        end
        love.graphics.print(line, px + 12, py + 32 + (i - 1) * 16)
    end

    love.graphics.setColor(0.85, 0.85, 0.85, 0.95)
    local hintY = py + 32 + #Genome.TRAITS * 16 + 8
    love.graphics.print("[up/down] select trait   [left/right] adjust value", px + 12, hintY)
    love.graphics.print("[backspace] reset to defaults   [space/click] place   [d] close", px + 12, hintY + 18)
end

function love.draw()
    ensureSceneCanvas()

    -- Draw the dish at 1:1 world scale into its own canvas (no camera
    -- transform here beyond the padding offset), so the shader below only
    -- ever samples the dish itself, whatever the current pan/zoom.
    love.graphics.setCanvas(sceneCanvas)
    love.graphics.clear(BACKGROUND_COLOR)
    love.graphics.push()
    love.graphics.translate(CANVAS_PADDING, CANVAS_PADDING)
    world:draw()

    if selectedCell and not selectedCell.dead then
        local pulse = 3 + math.sin(world.time * 4) * 1.5
        love.graphics.setColor(1, 1, 0.3, 0.9)
        love.graphics.setLineWidth(2)
        love.graphics.circle("line", selectedCell.x, selectedCell.y, selectedCell.genome.size + 6 + pulse)
    end

    love.graphics.pop()
    love.graphics.setCanvas()

    local w, h = love.graphics.getWidth(), love.graphics.getHeight()
    love.graphics.push()
    love.graphics.translate(w / 2, h / 2)
    love.graphics.scale(camera.scale)
    love.graphics.translate(-camera.x, -camera.y)

    -- Soft contact shadow under the dish itself, like it's sitting on a
    -- lit table -- drawn before the shader pass since it isn't part of
    -- the liquid and shouldn't get distorted along with it.
    for step = 4, 1, -1 do
        local margin = step * 5
        love.graphics.setColor(0, 0, 0, 0.05)
        love.graphics.rectangle("fill", -margin, -margin, world.width + margin * 2, world.height + margin * 2, 10, 10)
    end

    -- Composite the dish canvas through the same camera transform, with
    -- the shader bound so the distortion rides along with pan/zoom
    -- instead of covering the whole window. insetFrac tells the shader
    -- where the real dish wall sits within the padded canvas, so the
    -- vignette/meniscus stay anchored to the wall rather than the
    -- (larger) canvas edge.
    waterShader:send("time", world.time)
    waterShader:send("resolution", { world.width, world.height })
    waterShader:send("insetFrac", {
        CANVAS_PADDING / sceneCanvas:getWidth(),
        CANVAS_PADDING / sceneCanvas:getHeight(),
    })
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.setShader(waterShader)
    love.graphics.draw(sceneCanvas, -CANVAS_PADDING, -CANVAS_PADDING)
    love.graphics.setShader()

    love.graphics.pop()

    drawUI()
    drawSelectedInfo()
    drawDesignPanel()
end

function love.wheelmoved(_, dy)
    if dy == 0 then return end
    local mx, my = love.mouse.getPosition()
    local worldX, worldY = screenToWorld(mx, my)

    local newScale = camera.scale * (dy > 0 and ZOOM_STEP or 1 / ZOOM_STEP)
    camera.scale = math.max(MIN_ZOOM, math.min(MAX_ZOOM, newScale))

    -- Keep the point under the cursor fixed on screen while zooming.
    local w, h = love.graphics.getWidth(), love.graphics.getHeight()
    camera.x = worldX - (mx - w / 2) / camera.scale
    camera.y = worldY - (my - h / 2) / camera.scale
end

-- Window resize: the simulation area itself stays a fixed size (so world
-- bounds, hotspots, etc. don't shift under the population's feet), but
-- the view rescales to fit the whole dish snugly into however big the
-- window now is, recentered.
function love.resize(w, h)
    local fitScale = math.min(w / world.width, h / world.height)
    camera.scale = math.max(MIN_ZOOM, math.min(MAX_ZOOM, fitScale))
    camera.x, camera.y = world.width / 2, world.height / 2
    ensureSceneCanvas()
end

function love.keypressed(key)
    if key == "d" then
        designMode = not designMode
        if designMode then
            designGenome = Genome.default()
            designIndex = 1
        end
        return
    end

    if designMode then
        local traitCount = #Genome.TRAITS
        if key == "up" then
            designIndex = designIndex - 1
            if designIndex < 1 then designIndex = traitCount end
        elseif key == "down" then
            designIndex = designIndex + 1
            if designIndex > traitCount then designIndex = 1 end
        elseif key == "left" or key == "right" then
            local t = Genome.TRAITS[designIndex]
            local step = (t.max - t.min) * 0.02 * (key == "left" and -1 or 1)
            designGenome[t.key] = math.max(t.min, math.min(t.max, designGenome[t.key] + step))
        elseif key == "backspace" then
            designGenome = Genome.default()
        elseif key == "space" or key == "return" then
            local mx, my = love.mouse.getPosition()
            local wx, wy = screenToWorld(mx, my)
            spawnDesignedCellAt(wx, wy)
        elseif key == "escape" then
            designMode = false
        end
        return
    end

    if key == "space" then
        paused = not paused
    elseif key == "r" then
        love.load()
    elseif key == "up" then
        timeScale = math.min(8, timeScale * 1.5)
    elseif key == "down" then
        timeScale = math.max(0.1, timeScale / 1.5)
    elseif key == "f" then
        for _ = 1, 40 do world:spawnFood() end
    elseif key == "c" then
        world:spawnInitialPopulation(20)
    elseif key == "escape" then
        love.event.quit()
    end
end

function love.mousepressed(x, y, button)
    if button == 1 and designMode then
        local wx, wy = screenToWorld(x, y)
        spawnDesignedCellAt(wx, wy)
        return
    end
    if button == 1 then
        local wx, wy = screenToWorld(x, y)
        local hit = findCellAt(wx, wy)
        if hit then
            selectedCell = hit
        else
            selectedCell = nil
            world:spawnFoodAt(wx, wy)
        end
    end
end
