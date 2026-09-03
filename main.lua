local World = require("src.world")
local Genome = require("src.genome")
local Cell = require("src.cell")
local Fluid = require("src.fluid")
local waterShaderSrc = require("src.water_shader")

local world
local fluid
local paused = false
local timeScale = 1
local INITIAL_POPULATION = 90
local INITIAL_FOOD = 220

-- Pale, clear "lab water" tone rather than a murky dark tank -- both the
-- window background and the dish canvas clear to this.
local BACKGROUND_COLOR = { 0.86, 0.92, 0.94 }
local WARM_TINT = { 1.0, 0.5, 0.3 }
local COOL_TINT = { 0.3, 0.55, 1.0 }
local TINT_STRENGTH = 0.4 -- how far toward the tint color the water shifts at the hottest/coldest extreme

-- The water's own color as a visual read on dish temperature -- warmer
-- toward orange above the comfort band, cooler toward blue below it,
-- staying the neutral pale color anywhere inside it. Purely cosmetic; the
-- actual energy effect is in cell.lua's TEMP_COMFORT_LOW/HIGH.
local function currentBackgroundColor()
    local t = math.max(-1, math.min(1, (world.temperature - 50) / 50))
    local target = t > 0 and WARM_TINT or COOL_TINT
    local amount = math.abs(t) * TINT_STRENGTH
    return {
        BACKGROUND_COLOR[1] + (target[1] - BACKGROUND_COLOR[1]) * amount,
        BACKGROUND_COLOR[2] + (target[2] - BACKGROUND_COLOR[2]) * amount,
        BACKGROUND_COLOR[3] + (target[3] - BACKGROUND_COLOR[3]) * amount,
    }
end

-- Camera: `x`/`y` is the world-space point shown at the center of the
-- screen, `scale` is zoom. Scroll wheel zooms toward the cursor.
local camera = { x = 0, y = 0, scale = 1 }
local MAX_ZOOM = 6
local ZOOM_STEP = 1.15

local function screenToWorld(sx, sy)
    local w, h = love.graphics.getWidth(), love.graphics.getHeight()
    return camera.x + (sx - w / 2) / camera.scale,
        camera.y + (sy - h / 2) / camera.scale
end

-- iOS points run roughly 160 to the inch, so this is "about an inch" of
-- combined margin around the dish once you're zoomed all the way out (split
-- across both sides of whichever axis is tighter -- on a phone-width
-- screen, a full inch reserved on *each* side would shrink the dish itself
-- to almost nothing, which isn't the point here).
local ZOOM_OUT_MARGIN = 160

-- The floor for zooming out: past showing the whole container, you can keep
-- going until there's about ZOOM_OUT_MARGIN of empty space around it (on
-- whichever axis is tighter -- the other axis will show more, same as the
-- existing letterboxing when the window and dish aspect ratios don't match).
local function minZoomForWindow()
    local w, h = love.graphics.getWidth(), love.graphics.getHeight()
    local mw = math.max(w - ZOOM_OUT_MARGIN, 1)
    local mh = math.max(h - ZOOM_OUT_MARGIN, 1)
    return math.min(mw / world.width, mh / world.height)
end

-- Keeps the visible viewport inside the container's bounds at the current
-- zoom, so panning/pinching can never reveal space beyond its edges. When
-- the viewport is bigger than the container on an axis (at min zoom, or a
-- mismatched aspect ratio), that axis just centers instead of clamping to a
-- range that doesn't exist.
local function clampCamera()
    local w, h = love.graphics.getWidth(), love.graphics.getHeight()
    local viewW, viewH = w / camera.scale, h / camera.scale
    if viewW >= world.width then
        camera.x = world.width / 2
    else
        camera.x = math.max(viewW / 2, math.min(world.width - viewW / 2, camera.x))
    end
    if viewH >= world.height then
        camera.y = world.height / 2
    else
        camera.y = math.max(viewH / 2, math.min(world.height - viewH / 2, camera.y))
    end
end

-- iOS/Android have no keyboard and no real mouse -- love.mousepressed still
-- fires from the first finger (SDL synthesizes it), but every other control
-- needs a touch equivalent, so the whole input layer below is gated on this.
local IS_TOUCH = love.system.getOS() == "iOS" or love.system.getOS() == "Android"

-- One entry per finger currently down, keyed by touch id. `button`/`rowIndex`
-- mark a touch as already claimed by a UI control (so it can't also drag-pan
-- or place something on release); plain touches carry the tap/drag state
-- needed to tell a tap from a pan once they're released or move far enough.
local activeTouches = {}
local TAP_MOVE_THRESHOLD = 14
local TAP_TIME_THRESHOLD = 0.35

-- Set while exactly two fingers are down and neither is claimed by a
-- button/panel control -- drives pinch-to-zoom in love.touchmoved.
local pinch = nil

local BAR_BUTTON_H = 34
local BAR_MARGIN = 5

-- The cell currently inspected via click, if any. Cleared on death or reset.
local selectedCell = nil

-- The stats overlay (population/genome averages) is dense and covers a good
-- chunk of the dish on a phone screen, so it starts hidden -- tucked behind
-- a button/key instead of always on.
local showInfo = false

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

-- Settings: everything but pause/speed, tucked behind one panel -- see
-- SETTINGS_BUTTON_DEFS. Mutually exclusive with the designer below since both are centered modal panels and shouldn't be open at once.
local settingsMode = false

local function spawnDesignedCellAt(wx, wy)
    local g = {}
    for k, v in pairs(designGenome) do g[k] = v end -- copy so each spawned cell owns its genome table
    table.insert(world.cells, Cell.new(wx, wy, g))
end

-- Shared by love.mousepressed and the touch tap path: inspect a cell, drop
-- food, or (in design mode) place the designed cell -- whatever a plain
-- click/tap at this screen position means right now.
local function handleWorldTap(x, y)
    local wx, wy = screenToWorld(x, y)
    if designMode then
        spawnDesignedCellAt(wx, wy)
        return
    end
    local hit = findCellAt(wx, wy)
    if hit then
        selectedCell = hit
    else
        selectedCell = nil
        world:spawnFoodAt(wx, wy)
    end
end

-- Actions shared between keyboard shortcuts (desktop) and the on-screen
-- button bar (touch) so each one has exactly one implementation.
local function togglePause() paused = not paused end
local function doReset() love.load() end
local function speedDown() timeScale = math.max(0.1, timeScale / 1.5) end
local function speedUp() timeScale = math.min(8, timeScale * 1.5) end
local function foodBurst() for _ = 1, 40 do world:spawnFood() end end
local function addCells() world:spawnInitialPopulation(20) end
local function toggleInfo() showInfo = not showInfo end
local TEMP_STEP = 5
local function tempDown() world:setTemperature(world.temperature - TEMP_STEP) end
local function tempUp() world:setTemperature(world.temperature + TEMP_STEP) end

-- Viscosity: a 0 (thin/runny) .. 1 (thick/syrupy) dial, lives on world (like
-- temperature) since cell.lua's swim-speed drag reads it directly too --
-- mapped onto the fluid's decay range so "+" (thicker) reads as more drag/
-- less lasting current, matching intuition rather than exposing the raw
-- decay number.
local VISCOSITY_STEP = 0.1
local function applyViscosity()
    fluid:setDecay(Fluid.MAX_DECAY - world.viscosity * (Fluid.MAX_DECAY - Fluid.MIN_DECAY))
end
local function viscosityDown()
    world:setViscosity(world.viscosity - VISCOSITY_STEP)
    applyViscosity()
end
local function viscosityUp()
    world:setViscosity(world.viscosity + VISCOSITY_STEP)
    applyViscosity()
end

local FOOD_RATE_STEP = 0.2
local function foodRateDown() world:setFoodRate(world.foodRate - FOOD_RATE_STEP) end
local function foodRateUp() world:setFoodRate(world.foodRate + FOOD_RATE_STEP) end

local function toggleDesign()
    designMode = not designMode
    if designMode then
        designGenome = Genome.default()
        designIndex = 1
        settingsMode = false
    end
end

local function toggleSettings()
    settingsMode = not settingsMode
    if settingsMode then designMode = false end
end

-- Accelerometer input: on iOS/Android, SDL exposes it as a virtual joystick
-- (conf.lua leaves the default t.accelerometerjoystick = true), giving three
-- axes of g-force normalized into the usual -1..1 joystick range, in the
-- device's fixed physical (portrait) frame regardless of UI orientation.
-- Drives two effects sharing one joystick lookup per frame: a one-off jolt
-- on a shake, and continuous tilt-gravity while the phone is tipped.
local SHAKE_JERK_THRESHOLD = 0.28
local SHAKE_COOLDOWN = 0.4
local shakeLastMag = nil
local shakeCooldownTimer = 0

-- World units/sec of drift per 1.0 of in-plane tilt reading. Raw axis
-- values only reach roughly 0.2-0.3 for a natural tilt (SDL scales the
-- accelerometer to +-5g over the +-1 axis range, and gravity alone is 1g),
-- so this is set high enough for that range to read as a clear, deliberate
-- drift rather than a nudge.
local TILT_SPEED = 260
local TILT_DEADZONE = 0.04

-- Shake, tilt, and swipe all feed the same fluid field (src/fluid.lua)
-- instead of moving cells/food directly -- see advectEntities, which is
-- what actually carries them along with whatever current ends up under
-- them, every frame, regardless of what stirred the water up.
local SHAKE_FLUID_STRENGTH = 340

local function shakeCells()
    fluid:agitate(SHAKE_FLUID_STRENGTH)
end

-- Continuous injection, called every frame while tipped -- scaled by dt so
-- the total injected per second doesn't depend on frame rate; decay in
-- Fluid:update keeps this from building up without bound, settling at a
-- steady drift rather than accelerating forever.
local TILT_FIELD_RATE = 12
local function tiltCells(gx, gy, dt)
    if gx == 0 and gy == 0 then return end
    fluid:addUniformVelocity(gx * TILT_SPEED * TILT_FIELD_RATE * dt, gy * TILT_SPEED * TILT_FIELD_RATE * dt)
end

-- A one-finger drag stirs the water instead of panning the camera (two
-- fingers still pan, via the pinch branch below re-centering on a moving
-- midpoint): each drag injects a burst of current into the fluid field at
-- the touch point, rotated a few degrees off the drag direction to fake a
-- bit of vorticity (cheap swirl, instead of solving real curl), and the
-- field's own diffusion carries it outward over the next several frames --
-- so something right by the finger reacts almost immediately while
-- something further out only feels it a beat later. No visual on top of
-- this -- the current itself, carrying cells/food, is the effect.
local SWIPE_FIELD_STRENGTH = 55
local SWIPE_FIELD_RADIUS = 50
local SWIPE_SWIRL_ANGLE = 0.4 -- radians the injected velocity is rotated by
local SWIPE_INJECT_INTERVAL = 0.06 -- min seconds between injections while dragging
local swipeInjectCooldown = 0

local function updateSwipeCooldown(dt)
    swipeInjectCooldown = math.max(0, swipeInjectCooldown - dt)
end

local function injectSwipeCurrent(wx, wy, dx, dy)
    if swipeInjectCooldown > 0 then return end
    swipeInjectCooldown = SWIPE_INJECT_INTERVAL

    local mag = math.sqrt(dx * dx + dy * dy)
    if mag > 0.001 then
        local cosA, sinA = math.cos(SWIPE_SWIRL_ANGLE), math.sin(SWIPE_SWIRL_ANGLE)
        local rdx, rdy = dx * cosA - dy * sinA, dx * sinA + dy * cosA
        fluid:addVelocity(wx, wy, rdx * SWIPE_FIELD_STRENGTH, rdy * SWIPE_FIELD_STRENGTH, SWIPE_FIELD_RADIUS)
    end
end

-- Every cell and food item drifts with whatever current the fluid field
-- has at its position -- this is what actually moves things; shake/tilt/
-- swipe above only ever perturb the field itself.
-- Fraction of the fluid's push cancelled out at genome.strength=1 -- food
-- has no genome/strength, so it's always fully at the current's mercy;
-- cells can breed their way to bracing against it.
local STRENGTH_CURRENT_RESIST = 0.85

local function advectEntities(dt)
    for _, c in ipairs(world.cells) do
        local vx, vy = fluid:sample(c.x, c.y)
        local resist = 1 - c.genome.strength * STRENGTH_CURRENT_RESIST
        c.x = c.x + vx * resist * dt
        c.y = c.y + vy * resist * dt
        world:constrain(c)
    end
    for _, f in ipairs(world.food) do
        local vx, vy = fluid:sample(f.x, f.y)
        f.x = f.x + vx * dt
        f.y = f.y + vy * dt
        world:constrain(f)
    end
end

-- Makes the fluid field itself visible, drawn over the cells so they read
-- as submerged in it rather than floating on top of a flat background.
-- Three things combine into each cell's tint:
--   1. A slow drifting shimmer that's always present, so the water reads as
--      alive even completely undisturbed -- two overlapping sine waves at
--      different directions/speeds so it doesn't look like one uniform
--      pulse. Runs on love.timer, not world.time, so it keeps drifting
--      even while the sim itself is paused.
--   2. Extra opacity wherever the field actually has velocity, so stirring/
--      tilting/shaking reads as a real current on top of that baseline.
--   3. One continuous light/dark color gradient across the *whole* dish,
--      not a separate gradient per grid cell (that just looked like
--      repeating tiles) -- oriented along the field's overall dominant
--      flow direction, lightening toward wherever the water's actually
--      heading and darkening behind it, the same way a real current's
--      leading edge catches the light.
local FLUID_AMBIENT_ALPHA_MIN = 0.05
local FLUID_AMBIENT_ALPHA_MAX = 0.16
local FLUID_AMBIENT_WAVE_SCALE = 0.05  -- spatial frequency of the shimmer
local FLUID_AMBIENT_WAVE_SPEED = 0.6
local FLUID_ACTIVITY_MAX_ALPHA = 0.35
local FLUID_ACTIVITY_SCALE = 0.01 -- velocity magnitude -> extra alpha
local FLUID_TOTAL_MAX_ALPHA = 0.55
local FLUID_DARK_TINT = { 0.32, 0.55, 0.82 }
local FLUID_LIGHT_TINT = { 0.75, 0.92, 1.0 }
local FLUID_NEUTRAL_TINT = { 0.6, 0.85, 1.0 } -- used when there's no coherent overall direction to gradient along

-- The field's overall direction, weighted toward its faster-moving cells
-- (so a few small numerical-noise cells elsewhere don't drag the average
-- toward nothing in particular), plus how far the dish spans along that
-- direction -- together enough to place any point on a 0..1 gradient ramp
-- from the "behind" edge to the "leading" edge of the current.
local function fluidFlowGradientAxis()
    local sumX, sumY, weight = 0, 0, 0
    for i = 1, fluid.cols * fluid.rows do
        local vx, vy = fluid.vx[i], fluid.vy[i]
        local mag = math.sqrt(vx * vx + vy * vy)
        sumX, sumY, weight = sumX + vx * mag, sumY + vy * mag, weight + mag
    end
    if weight < 1 then return nil end
    local dirX, dirY = sumX / weight, sumY / weight
    local dmag = math.sqrt(dirX * dirX + dirY * dirY)
    if dmag < 0.0001 then return nil end
    dirX, dirY = dirX / dmag, dirY / dmag

    local minP, maxP = math.huge, -math.huge
    for _, corner in ipairs({ { 0, 0 }, { world.width, 0 }, { 0, world.height }, { world.width, world.height } }) do
        local p = corner[1] * dirX + corner[2] * dirY
        minP, maxP = math.min(minP, p), math.max(maxP, p)
    end
    return dirX, dirY, minP, maxP
end

local function drawFluidLayer()
    local t = love.timer.getTime()
    local dirX, dirY, minP, maxP = fluidFlowGradientAxis()
    local spread = dirX and math.max(1, maxP - minP) or 1

    for cy = 0, fluid.rows - 1 do
        for cx = 0, fluid.cols - 1 do
            local i = fluid:index(cx, cy)
            local vx, vy = fluid.vx[i], fluid.vy[i]
            local mag = math.sqrt(vx * vx + vy * vy)
            local activity = math.min(FLUID_ACTIVITY_MAX_ALPHA, mag * FLUID_ACTIVITY_SCALE)

            local wx, wy = cx * fluid.cellSize, cy * fluid.cellSize
            local shimmer = math.sin(wx * FLUID_AMBIENT_WAVE_SCALE + t * FLUID_AMBIENT_WAVE_SPEED)
                + math.sin(wy * FLUID_AMBIENT_WAVE_SCALE - t * FLUID_AMBIENT_WAVE_SPEED * 0.7)
            shimmer = (shimmer + 2) / 4 -- normalize [-2,2] -> [0,1]
            local ambient = FLUID_AMBIENT_ALPHA_MIN + (FLUID_AMBIENT_ALPHA_MAX - FLUID_AMBIENT_ALPHA_MIN) * shimmer
            local alpha = math.min(FLUID_TOTAL_MAX_ALPHA, ambient + activity)

            local r, g, b
            if dirX then
                local cxw, cyw = wx + fluid.cellSize / 2, wy + fluid.cellSize / 2
                local frac = 1 - ((cxw * dirX + cyw * dirY) - minP) / spread
                r = FLUID_DARK_TINT[1] + (FLUID_LIGHT_TINT[1] - FLUID_DARK_TINT[1]) * frac
                g = FLUID_DARK_TINT[2] + (FLUID_LIGHT_TINT[2] - FLUID_DARK_TINT[2]) * frac
                b = FLUID_DARK_TINT[3] + (FLUID_LIGHT_TINT[3] - FLUID_DARK_TINT[3]) * frac
            else
                r, g, b = FLUID_NEUTRAL_TINT[1], FLUID_NEUTRAL_TINT[2], FLUID_NEUTRAL_TINT[3]
            end

            love.graphics.setColor(r, g, b, alpha)
            love.graphics.rectangle("fill", wx, wy, fluid.cellSize, fluid.cellSize)
        end
    end
end

local function updateAccelerometer(dt)
    if not IS_TOUCH then return end
    local joy = love.joystick.getJoysticks()[1]
    if not joy or joy:getAxisCount() < 3 then
        shakeLastMag = nil
        return
    end

    local ax, ay, az = joy:getAxis(1), joy:getAxis(2), joy:getAxis(3)

    -- Shake: a jump in total acceleration magnitude between frames.
    shakeCooldownTimer = math.max(0, shakeCooldownTimer - dt)
    local mag = math.sqrt(ax * ax + ay * ay + az * az)
    local delta = shakeLastMag and math.abs(mag - shakeLastMag) or 0
    if shakeLastMag and shakeCooldownTimer <= 0 and delta > SHAKE_JERK_THRESHOLD then
        shakeCells()
        shakeCooldownTimer = SHAKE_COOLDOWN
    end
    shakeLastMag = mag

    -- Tilt: the in-plane component of gravity, rotated from the device's
    -- fixed physical frame into current screen space so "down" always
    -- matches the edge you're actually tipping toward.
    local orientation = love.window.getDisplayOrientation and love.window.getDisplayOrientation(1) or "landscape"
    local gx, gy
    if orientation == "landscapeflipped" then
        gx, gy = -ay, ax
    else -- landscape (the common case) and unknown/portrait fall back the same way
        gx, gy = ay, -ax
    end
    if math.abs(gx) < TILT_DEADZONE then gx = 0 end
    if math.abs(gy) < TILT_DEADZONE then gy = 0 end
    tiltCells(gx, gy, dt)
end

local function pointInRect(x, y, r)
    return x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h
end

-- Falls back to the full window when love.window.getSafeArea isn't available
-- (older LÖVE, or desktop where it just returns the window bounds anyway) --
-- keeps the touch bar clear of the iPhone's notch/home-indicator.
local function getSafeArea()
    if love.window and love.window.getSafeArea then
        local ok, x, y, w, h = pcall(love.window.getSafeArea)
        if ok and w and h then return x, y, w, h end
    end
    return 0, 0, love.graphics.getWidth(), love.graphics.getHeight()
end

-- Kept on the always-visible bottom bar -- the controls you reach for
-- constantly. Everything else (resets, one-off spawns, the designer/info
-- toggles, and every dish dial) lives behind the Settings button instead,
-- see SETTINGS_BUTTON_DEFS below -- the bar was up to 14 buttons and
-- getting cramped.
local TOUCH_BUTTON_DEFS = {
    { id = "pause",  label = function() return paused and "Play" or "Pause" end },
    { id = "speeddown", label = function() return "Speed -" end },
    { id = "speedup",   label = function() return "Speed +" end },
    { id = "settings", label = function() return settingsMode and "Close" or "Settings" end },
}
local TOUCH_BUTTON_ACTIONS = {
    pause = togglePause,
    speeddown = speedDown,
    speedup = speedUp,
    settings = toggleSettings,
}

-- Rebuilt (cheaply -- a handful of entries) wherever it's needed rather
-- than cached, so it's always correct for the current window size/
-- orientation with no extra bookkeeping on resize.
local function layoutButtons()
    if not IS_TOUCH then return {} end
    local sx, sy, sw, sh = getSafeArea()
    local n = #TOUCH_BUTTON_DEFS
    local barW = sw - BAR_MARGIN * 2
    local btnW = (barW - BAR_MARGIN * (n - 1)) / n
    local by = sy + sh - BAR_MARGIN - BAR_BUTTON_H
    local buttons = {}
    for i, def in ipairs(TOUCH_BUTTON_DEFS) do
        buttons[i] = {
            id = def.id, label = def.label,
            x = sx + BAR_MARGIN + (i - 1) * (btnW + BAR_MARGIN),
            y = by, w = btnW, h = BAR_BUTTON_H,
        }
    end
    return buttons
end

local function findButtonAt(x, y)
    for _, b in ipairs(layoutButtons()) do
        if pointInRect(x, y, b) then return b end
    end
    return nil
end

-- The dish's settings, tucked behind one button instead of living directly
-- on the bar: resets/one-off spawns, the designer/info toggles, and every
-- environmental dial (temperature, viscosity, food rate). Laid out as a
-- grid inside a centered panel, the same modal pattern as the cell
-- designer -- see drawSettingsPanel/settingsButtonRect below.
local SETTINGS_BUTTON_DEFS = {
    { id = "reset",  label = function() return "Reset" end },
    { id = "food",   label = function() return "Food" end },
    { id = "cells",  label = function() return "+Cells" end },
    { id = "design", label = function() return "Design" end },
    { id = "info",   label = function() return showInfo and "Hide Info" or "Info" end },
    { id = "tempdown", label = function() return "Temp -" end },
    { id = "tempup",   label = function() return "Temp +" end },
    { id = "viscdown", label = function() return "Visc -" end },
    { id = "viscup",   label = function() return "Visc +" end },
    { id = "fratedown", label = function() return "FRate -" end },
    { id = "frateup",   label = function() return "FRate +" end },
}
local SETTINGS_BUTTON_ACTIONS = {
    reset = doReset,
    food = foodBurst,
    cells = addCells,
    design = toggleDesign,
    info = toggleInfo,
    tempdown = tempDown,
    tempup = tempUp,
    viscdown = viscosityDown,
    viscup = viscosityUp,
    fratedown = foodRateDown,
    frateup = foodRateUp,
}
local SETTINGS_GRID_COLS = 4

-- Design panel geometry, touch-first: falls back to a single column when
-- there's room (desktop), splits into two once the trait list wouldn't fit
-- above the touch bar (phone landscape).
local DESIGN_ROW_H = 18
local DESIGN_HEADER_H = 30
local DESIGN_FOOTER_H = 30
local DESIGN_COL_GAP = 24
local DESIGN_COL_W = 240

local function designGeometry()
    local w, h = love.graphics.getWidth(), love.graphics.getHeight()
    local barH = IS_TOUCH and (BAR_BUTTON_H + BAR_MARGIN * 2) or 0
    local availH = h - barH - 16
    local n = #Genome.TRAITS
    local cols, rowsPerCol = 1, n
    if (DESIGN_HEADER_H + n * DESIGN_ROW_H + DESIGN_FOOTER_H) > availH then
        cols = 2
        rowsPerCol = math.ceil(n / 2)
    end
    local panelW = math.min(w - 24, cols * DESIGN_COL_W + (cols - 1) * DESIGN_COL_GAP + 24)
    local colW = (panelW - 24 - (cols - 1) * DESIGN_COL_GAP) / cols
    local panelH = DESIGN_HEADER_H + rowsPerCol * DESIGN_ROW_H + DESIGN_FOOTER_H
    local px = (w - panelW) / 2
    local py = math.max(8, (h - barH - panelH) / 2)
    return { px = px, py = py, panelW = panelW, panelH = panelH, colW = colW, rowsPerCol = rowsPerCol }
end

local function designRowRect(geo, i)
    local col = math.ceil(i / geo.rowsPerCol)
    local rowInCol = i - (col - 1) * geo.rowsPerCol
    return {
        x = geo.px + 12 + (col - 1) * (geo.colW + DESIGN_COL_GAP),
        y = geo.py + DESIGN_HEADER_H + (rowInCol - 1) * DESIGN_ROW_H,
        w = geo.colW,
        h = DESIGN_ROW_H - 3,
    }
end

local function designCloseRect(geo)
    return { x = geo.px + geo.panelW - 28, y = geo.py + 6, w = 22, h = 22 }
end

local function designResetRect(geo)
    return { x = geo.px + geo.panelW / 2 - 70, y = geo.py + geo.panelH - DESIGN_FOOTER_H + 6, w = 140, h = 22 }
end

-- Settings panel: a grid of action buttons, same centered-modal shape as
-- the design panel above but simpler (no per-value sliders, just buttons).
local SETTINGS_HEADER_H = 36
local SETTINGS_BTN_W = 130
local SETTINGS_BTN_H = 40
local SETTINGS_GRID_GAP = 10

local function settingsGeometry()
    local w, h = love.graphics.getWidth(), love.graphics.getHeight()
    local barH = IS_TOUCH and (BAR_BUTTON_H + BAR_MARGIN * 2) or 0
    local n = #SETTINGS_BUTTON_DEFS
    local cols = SETTINGS_GRID_COLS
    local rows = math.ceil(n / cols)
    local panelW = math.min(w - 24, cols * SETTINGS_BTN_W + (cols - 1) * SETTINGS_GRID_GAP + 24)
    local btnW = (panelW - 24 - (cols - 1) * SETTINGS_GRID_GAP) / cols
    local panelH = SETTINGS_HEADER_H + rows * SETTINGS_BTN_H + (rows - 1) * SETTINGS_GRID_GAP + 16
    local px = (w - panelW) / 2
    local py = math.max(8, (h - barH - panelH) / 2)
    return { px = px, py = py, panelW = panelW, panelH = panelH, cols = cols, rows = rows, btnW = btnW }
end

local function settingsButtonRect(geo, i)
    local col = (i - 1) % geo.cols
    local row = math.floor((i - 1) / geo.cols)
    return {
        x = geo.px + 12 + col * (geo.btnW + SETTINGS_GRID_GAP),
        y = geo.py + SETTINGS_HEADER_H + row * (SETTINGS_BTN_H + SETTINGS_GRID_GAP),
        w = geo.btnW, h = SETTINGS_BTN_H,
    }
end

local function settingsCloseRect(geo)
    return { x = geo.px + geo.panelW - 28, y = geo.py + 6, w = 22, h = 22 }
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
    -- On touch, the button bar permanently covers a strip along the bottom
    -- edge -- size the container to the space actually left visible above
    -- it, rather than the full screen, so no cell/food ever sits hidden (and
    -- untappable) behind the bar.
    local containerH = h
    if IS_TOUCH then
        local _, _, _, safeH = getSafeArea()
        -- getSafeArea() can legitimately report 0 on the very first frame on
        -- real hardware (safe-area insets aren't always settled before the
        -- first layout pass) -- floored so a bad reading here can never
        -- produce a zero/negative container instead of just a slightly
        -- generous one.
        containerH = math.max(h * 0.5, math.min(h, safeH - (BAR_BUTTON_H + BAR_MARGIN * 2)))
    end
    world = World.new(w, containerH)
    fluid = Fluid.new(world.width, world.height)
    -- world.viscosity just came back to its default with the fresh World
    -- above (same as temperature does on reset) -- sync the fresh fluid's
    -- decay to match rather than leaving it at Fluid.new's own default.
    applyViscosity()
    world:spawnInitialPopulation(INITIAL_POPULATION, true)
    for _ = 1, INITIAL_FOOD do world:spawnFood() end
    paused = false
    timeScale = 1
    camera.x, camera.y, camera.scale = world.width / 2, world.height / 2, 1
    clampCamera()
    selectedCell = nil
    designMode = false
    designGenome = Genome.default()
    designIndex = 1
    waterShader = love.graphics.newShader(waterShaderSrc)
    ensureSceneCanvas()
end

function love.update(dt)
    updateAccelerometer(dt)
    updateSwipeCooldown(dt)
    fluid:update(dt)
    advectEntities(dt)
    if paused then return end
    world:update(dt * timeScale)
end

local function drawUI()
    if not showInfo then return end
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
        string.format("Avg grazing efficiency: %.2f  foraging speed: %.2f",
            s.avg.grazing_efficiency or 0, s.avg.foraging_speed or 0),
        string.format("Avg escape burst: %.2f  herd defense: %.2f",
            s.avg.escape_burst or 0, s.avg.herd_defense or 0),
        string.format("Dish temp: %.0f   Avg heat resist: %.2f  cold resist: %.2f",
            world.temperature, s.avg.heat_resistance or 0, s.avg.cold_resistance or 0),
        string.format("Viscosity: %.0f%%   Avg strength: %.2f", world.viscosity * 100, s.avg.strength or 0),
        string.format("Food rate: x%.1f", world.foodRate),
        string.format("Time: %.0fs   sim speed: x%.1f   zoom: x%.1f%s",
            world.time, timeScale, camera.scale, paused and "   [PAUSED]" or ""),
        IS_TOUCH and "Use the buttons below to pause/reset/speed/food/cells/design"
            or "[space] pause  [r] reset  [up/down] sim speed  [scroll] zoom  [f] food burst  [c] add cells",
        IS_TOUCH and "[tap cell] inspect it   [tap empty] drop food   [drag] stir   [2-finger drag/pinch] pan/zoom"
            or "[click cell] inspect it   [click empty] drop food   [d] cell designer",
    }
    love.graphics.setColor(0, 0, 0, 0.5)
    love.graphics.rectangle("fill", 4, 4, 460, 8 + #lines * 16)
    love.graphics.setColor(1, 1, 1, 0.9)
    for i, line in ipairs(lines) do
        love.graphics.print(line, 10, 6 + (i - 1) * 16)
    end
end

-- The stats panel itself carries the [i]-to-hide hint, but with it hidden
-- there'd be nothing on screen at all telling a desktop player it exists --
-- touch players don't need this, the button bar already says "Info".
local function drawInfoHint()
    if IS_TOUCH or showInfo then return end
    love.graphics.setColor(0, 0, 0, 0.5)
    love.graphics.rectangle("fill", 4, 4, 82, 20)
    love.graphics.setColor(1, 1, 1, 0.9)
    love.graphics.print("[i] info", 10, 7)
end

-- Dish temperature, viscosity, and food rate are active dials, not passive
-- stats, so they stay visible even with the (much bigger) full stats panel
-- hidden -- all three are already folded into that panel's own lines once
-- Info is open, so this only needs to show when that one doesn't.
local function drawTempReadout()
    if showInfo then return end
    local x = IS_TOUCH and 4 or 90
    love.graphics.setColor(0, 0, 0, 0.5)
    love.graphics.rectangle("fill", x, 4, 175, 20)
    love.graphics.setColor(1, 1, 1, 0.9)
    love.graphics.print(string.format("Temp: %.0f  Visc: %.0f%%  Food: x%.1f",
        world.temperature, world.viscosity * 100, world.foodRate), x + 6, 7)
end

-- Genome.TRAITS lookup by key, so each printed value's min/max is available
-- without re-scanning the list per trait per frame.
local TRAIT_DEF_BY_KEY = {}
for _, t in ipairs(Genome.TRAITS) do TRAIT_DEF_BY_KEY[t.key] = t end

-- Rows of (label, genome key, value format) segments -- printed as separate
-- colored runs (see traitExpressionColor) instead of one flat-colored
-- string per line, so a trait sitting near the top of its range visibly
-- pops out from one sitting near the bottom.
local INFO_TRAIT_ROWS = {
    { { "speed", "speed", "%.1f" }, { "size", "size", "%.1f" }, { "sense", "sense_radius", "%.0f" } },
    { { "metabolism", "metabolism", "%.2f" }, { "repro thresh", "repro_threshold", "%.2f" } },
    { { "aggression", "aggression", "%.2f" }, { "armor", "armor", "%.2f" } },
    { { "toxicity", "toxicity", "%.2f" }, { "camouflage", "camouflage", "%.2f" } },
    { { "flagella", "flagella", "%.2f" }, { "lifespan trait", "lifespan", "%.0fs" } },
    { { "chlorophyll", "chlorophyll", "%.2f" }, { "spikes", "spikes", "%.2f" } },
    { { "heat resist", "heat_resistance", "%.2f" }, { "cold resist", "cold_resistance", "%.2f" } },
    { { "boldness", "boldness", "%.2f" }, { "sociality", "sociality", "%.2f" } },
    { { "forage persistence", "forage_persistence", "%.2f" } },
    { { "bite power", "bite_power", "%.2f" }, { "venom", "venom", "%.2f" }, { "pack hunting", "pack_hunting", "%.2f" } },
    { { "grazing efficiency", "grazing_efficiency", "%.2f" }, { "foraging speed", "foraging_speed", "%.2f" } },
    { { "escape burst", "escape_burst", "%.2f" }, { "herd defense", "herd_defense", "%.2f" } },
    { { "strength", "strength", "%.2f" } },
}

local TRAIT_EXPRESSION_LOW = { 0.55, 0.55, 0.62 }  -- near the trait's min: dim, unremarkable
local TRAIT_EXPRESSION_HIGH = { 1.0, 0.85, 0.3 }   -- near the trait's max: warm highlight, catches the eye

local function traitExpressionColor(key, value)
    local t = TRAIT_DEF_BY_KEY[key]
    if not t then return 1, 1, 1 end
    local frac = math.max(0, math.min(1, (value - t.min) / (t.max - t.min)))
    return TRAIT_EXPRESSION_LOW[1] + (TRAIT_EXPRESSION_HIGH[1] - TRAIT_EXPRESSION_LOW[1]) * frac,
        TRAIT_EXPRESSION_LOW[2] + (TRAIT_EXPRESSION_HIGH[2] - TRAIT_EXPRESSION_LOW[2]) * frac,
        TRAIT_EXPRESSION_LOW[3] + (TRAIT_EXPRESSION_HIGH[3] - TRAIT_EXPRESSION_LOW[3]) * frac
end

local function drawSelectedInfo()
    if not selectedCell or selectedCell.dead then return end
    local c, g = selectedCell, selectedCell.genome
    local energyPct = math.max(0, math.min(1, c.energy / c.maxEnergy)) * 100
    local panelW = math.min(300, love.graphics.getWidth() - 20)
    local panelX = love.graphics.getWidth() - panelW - 10

    local headerLines = {
        string.format("Selected cell -- %s", c:isPredatorish() and "predator" or "herbivore"),
        string.format("State: %s   Energy: %.0f%%   Tribe: #%d", c.state, energyPct, c.tribeId),
        string.format("Age: %.0fs / %.0fs lifespan", c.age, c.lifespanActual),
    }
    local rowCount = #INFO_TRAIT_ROWS + (c.jackpotTrait and 1 or 0)
    local panelH = 8 + (#headerLines + rowCount) * 16

    love.graphics.setColor(0, 0, 0, 0.55)
    love.graphics.rectangle("fill", panelX - 10, 4, panelW, panelH)

    love.graphics.setColor(1, 1, 1, 0.95)
    for i, line in ipairs(headerLines) do
        love.graphics.print(line, panelX, 8 + (i - 1) * 16)
    end

    local font = love.graphics.getFont()
    local y = 8 + #headerLines * 16
    for _, row in ipairs(INFO_TRAIT_ROWS) do
        local x = panelX
        for _, seg in ipairs(row) do
            local label, key, fmt = seg[1], seg[2], seg[3]
            local text = string.format("%s " .. fmt .. "  ", label, g[key])
            love.graphics.setColor(traitExpressionColor(key, g[key]))
            love.graphics.print(text, x, y)
            x = x + font:getWidth(text)
        end
        y = y + 16
    end

    if c.jackpotTrait then
        love.graphics.setColor(1, 1, 1, 0.95)
        love.graphics.print(string.format("Jackpot mutation at birth: %s", c.jackpotTrait), panelX, y)
    end
end

local function drawDesignPanel()
    if not designMode then return end
    local geo = designGeometry()
    local px, py, panelW, panelH = geo.px, geo.py, geo.panelW, geo.panelH

    love.graphics.setColor(0, 0, 0, 0.82)
    love.graphics.rectangle("fill", px, py, panelW, panelH, 6, 6)
    love.graphics.setColor(1, 1, 1, 0.95)
    love.graphics.print("Cell Designer -- tap/drag a bar to set it", px + 12, py + 8)

    for i, t in ipairs(Genome.TRAITS) do
        local r = designRowRect(geo, i)
        local valueStr = (t.key == "lifespan") and string.format("%.0fs", designGenome[t.key])
            or string.format("%.2f", designGenome[t.key])
        local frac = math.max(0, math.min(1, (designGenome[t.key] - t.min) / (t.max - t.min)))
        local highlight = (i == designIndex)

        love.graphics.setColor(1, 1, 1, 0.12)
        love.graphics.rectangle("fill", r.x, r.y, r.w, r.h, 3, 3)
        if highlight then
            love.graphics.setColor(1, 1, 0.4, 0.55)
        else
            love.graphics.setColor(0.45, 0.7, 1, 0.4)
        end
        love.graphics.rectangle("fill", r.x, r.y, r.w * frac, r.h, 3, 3)
        love.graphics.setColor(1, 1, 1, highlight and 1 or 0.85)
        love.graphics.print(string.format("%-16s%s", t.key, valueStr), r.x + 4, r.y + 1)
    end

    local reset = designResetRect(geo)
    love.graphics.setColor(0, 0, 0, 0.5)
    love.graphics.rectangle("fill", reset.x, reset.y, reset.w, reset.h, 4, 4)
    love.graphics.setColor(1, 1, 1, 0.9)
    love.graphics.printf("Reset defaults", reset.x, reset.y + 4, reset.w, "center")

    local close = designCloseRect(geo)
    love.graphics.setColor(0, 0, 0, 0.5)
    love.graphics.rectangle("fill", close.x, close.y, close.w, close.h, 4, 4)
    love.graphics.setColor(1, 1, 1, 0.9)
    love.graphics.printf("x", close.x, close.y + 3, close.w, "center")

    if not IS_TOUCH then
        love.graphics.setColor(0.85, 0.85, 0.85, 0.95)
        love.graphics.print("[up/down] select trait   [left/right] adjust value   [backspace] reset   [space/click] place   [d] close",
            px, py + panelH + 6)
    end
end

local function drawSettingsPanel()
    if not settingsMode then return end
    local geo = settingsGeometry()

    love.graphics.setColor(0, 0, 0, 0.82)
    love.graphics.rectangle("fill", geo.px, geo.py, geo.panelW, geo.panelH, 6, 6)
    love.graphics.setColor(1, 1, 1, 0.95)
    love.graphics.print("Settings", geo.px + 12, geo.py + 8)

    for i, def in ipairs(SETTINGS_BUTTON_DEFS) do
        local r = settingsButtonRect(geo, i)
        love.graphics.setColor(0, 0, 0, 0.5)
        love.graphics.rectangle("fill", r.x, r.y, r.w, r.h, 6, 6)
        love.graphics.setColor(1, 1, 1, 0.9)
        love.graphics.printf(def.label(), r.x, r.y + r.h / 2 - 7, r.w, "center")
    end

    local close = settingsCloseRect(geo)
    love.graphics.setColor(0, 0, 0, 0.5)
    love.graphics.rectangle("fill", close.x, close.y, close.w, close.h, 4, 4)
    love.graphics.setColor(1, 1, 1, 0.9)
    love.graphics.printf("x", close.x, close.y + 3, close.w, "center")
end

local function drawTouchBar()
    if not IS_TOUCH then return end
    for _, b in ipairs(layoutButtons()) do
        love.graphics.setColor(0, 0, 0, 0.6)
        love.graphics.rectangle("fill", b.x, b.y, b.w, b.h, 6, 6)
        love.graphics.setColor(1, 1, 1, 0.92)
        love.graphics.printf(b.label(), b.x, b.y + b.h / 2 - 7, b.w, "center")
    end
end

-- DIAGNOSTIC (temporary): the offscreen canvas + water-shader composite
-- below is the prime suspect for the on-device black-screen report -- a
-- half-rendered-rectangle artifact is a known symptom of a render-to-
-- texture path tripping a driver quirk on some mobile GPUs. This path skips
-- the canvas/shader entirely and draws the world straight to the screen, to
-- isolate whether that's really the cause. Revert to the canvas path (or
-- find a canvas fix) once confirmed either way.
local function drawWorldDirect()
    local w, h = love.graphics.getWidth(), love.graphics.getHeight()
    love.graphics.push()
    love.graphics.translate(w / 2, h / 2)
    love.graphics.scale(camera.scale)
    love.graphics.translate(-camera.x, -camera.y)

    for step = 4, 1, -1 do
        local margin = step * 5
        love.graphics.setColor(0, 0, 0, 0.05)
        love.graphics.rectangle("fill", -margin, -margin, world.width + margin * 2, world.height + margin * 2, 10, 10)
    end

    world:draw()
    drawFluidLayer()

    if selectedCell and not selectedCell.dead then
        local pulse = 3 + math.sin(world.time * 4) * 1.5
        love.graphics.setColor(1, 1, 0.3, 0.9)
        love.graphics.setLineWidth(2)
        love.graphics.circle("line", selectedCell.x, selectedCell.y, selectedCell.genome.size + 6 + pulse)
    end

    love.graphics.pop()
end

local function drawWorldViaCanvas()
    ensureSceneCanvas()

    -- Draw the dish at 1:1 world scale into its own canvas (no camera
    -- transform here beyond the padding offset), so the shader below only
    -- ever samples the dish itself, whatever the current pan/zoom.
    love.graphics.setCanvas(sceneCanvas)
    love.graphics.clear(currentBackgroundColor())
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
end

function love.draw()
    -- Refreshed every frame (not just at load) so the tint tracks the
    -- temperature dial live as it's adjusted, not just on reset.
    love.graphics.setBackgroundColor(currentBackgroundColor())

    if IS_TOUCH then
        drawWorldDirect()
    else
        drawWorldViaCanvas()
    end

    drawUI()
    drawInfoHint()
    drawTempReadout()
    drawSelectedInfo()
    drawDesignPanel()
    drawSettingsPanel()
    drawTouchBar()
end

function love.wheelmoved(_, dy)
    if dy == 0 then return end
    local mx, my = love.mouse.getPosition()
    local worldX, worldY = screenToWorld(mx, my)

    local newScale = camera.scale * (dy > 0 and ZOOM_STEP or 1 / ZOOM_STEP)
    camera.scale = math.max(minZoomForWindow(), math.min(MAX_ZOOM, newScale))

    -- Keep the point under the cursor fixed on screen while zooming.
    local w, h = love.graphics.getWidth(), love.graphics.getHeight()
    camera.x = worldX - (mx - w / 2) / camera.scale
    camera.y = worldY - (my - h / 2) / camera.scale
    clampCamera()
end

-- Window resize: the simulation area itself stays a fixed size (so world
-- bounds, hotspots, etc. don't shift under the population's feet), but
-- the view rescales to fit the whole dish snugly into however big the
-- window now is, recentered.
function love.resize(w, h)
    local fitScale = math.min(w / world.width, h / world.height)
    camera.scale = math.min(fitScale, MAX_ZOOM)
    camera.x, camera.y = world.width / 2, world.height / 2
    ensureSceneCanvas()
end

function love.keypressed(key)
    if key == "d" then
        toggleDesign()
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
        togglePause()
    elseif key == "r" then
        doReset()
    elseif key == "up" then
        speedUp()
    elseif key == "down" then
        speedDown()
    elseif key == "f" then
        foodBurst()
    elseif key == "c" then
        addCells()
    elseif key == "i" then
        toggleInfo()
    elseif key == "left" then
        tempDown()
    elseif key == "right" then
        tempUp()
    elseif key == "[" then
        viscosityDown()
    elseif key == "]" then
        viscosityUp()
    elseif key == "-" then
        foodRateDown()
    elseif key == "=" then
        foodRateUp()
    elseif key == "escape" then
        love.event.quit()
    end
end

function love.mousepressed(x, y, button, istouch)
    -- On touch platforms SDL synthesizes a mouse click from the first
    -- finger; the touch layer below already handles it, so ignore the
    -- synthetic one here to avoid double input.
    if istouch and IS_TOUCH then return end
    if button == 1 then
        handleWorldTap(x, y)
    end
end

-- Touch input (iOS/Android). Design-panel controls and the button bar claim
-- a touch immediately on press; everything else is tracked in activeTouches
-- so love.touchreleased can tell a tap from a drag, and love.touchmoved can
-- turn two simultaneous plain touches into a pinch-zoom gesture.
function love.touchpressed(id, x, y)
    if not IS_TOUCH then return end

    if designMode then
        local geo = designGeometry()
        if pointInRect(x, y, { x = geo.px, y = geo.py, w = geo.panelW, h = geo.panelH }) then
            if pointInRect(x, y, designCloseRect(geo)) then
                toggleDesign()
                return
            end
            if pointInRect(x, y, designResetRect(geo)) then
                designGenome = Genome.default()
                return
            end
            for i, t in ipairs(Genome.TRAITS) do
                local r = designRowRect(geo, i)
                if pointInRect(x, y, r) then
                    designIndex = i
                    local frac = math.max(0, math.min(1, (x - r.x) / r.w))
                    designGenome[t.key] = t.min + frac * (t.max - t.min)
                    activeTouches[id] = { rowIndex = i, rowRect = r }
                    return
                end
            end
            activeTouches[id] = { consumed = true } -- tapped panel chrome/whitespace
            return
        end
    end

    if settingsMode then
        local geo = settingsGeometry()
        if pointInRect(x, y, { x = geo.px, y = geo.py, w = geo.panelW, h = geo.panelH }) then
            if pointInRect(x, y, settingsCloseRect(geo)) then
                toggleSettings()
                return
            end
            for i, def in ipairs(SETTINGS_BUTTON_DEFS) do
                local r = settingsButtonRect(geo, i)
                if pointInRect(x, y, r) then
                    SETTINGS_BUTTON_ACTIONS[def.id]()
                    activeTouches[id] = { consumed = true }
                    return
                end
            end
            activeTouches[id] = { consumed = true } -- tapped panel chrome/whitespace
            return
        end
    end

    local btn = findButtonAt(x, y)
    if btn then
        TOUCH_BUTTON_ACTIONS[btn.id]()
        activeTouches[id] = { consumed = true }
        return
    end

    activeTouches[id] = { x = x, y = y, startX = x, startY = y, startTime = love.timer.getTime(), moved = false }

    local ids = {}
    for tid, t in pairs(activeTouches) do
        if not t.consumed and not t.rowIndex then ids[#ids + 1] = tid end
    end
    if #ids == 2 then
        local a, b = activeTouches[ids[1]], activeTouches[ids[2]]
        local dx, dy = b.x - a.x, b.y - a.y
        local midX, midY = (a.x + b.x) / 2, (a.y + b.y) / 2
        local focusWX, focusWY = screenToWorld(midX, midY)
        pinch = {
            ids = ids,
            startDist = math.max(1, math.sqrt(dx * dx + dy * dy)),
            startScale = camera.scale,
            focusWX = focusWX, focusWY = focusWY,
        }
    end
end

function love.touchmoved(id, x, y)
    if not IS_TOUCH then return end
    local t = activeTouches[id]
    if not t then return end

    if t.rowIndex then
        local trait = Genome.TRAITS[t.rowIndex]
        local frac = math.max(0, math.min(1, (x - t.rowRect.x) / t.rowRect.w))
        designGenome[trait.key] = trait.min + frac * (trait.max - trait.min)
        return
    end
    if t.consumed then return end
    t.x, t.y = x, y

    if pinch then
        local a, b = activeTouches[pinch.ids[1]], activeTouches[pinch.ids[2]]
        if a and b then
            local dx, dy = b.x - a.x, b.y - a.y
            local dist = math.max(1, math.sqrt(dx * dx + dy * dy))
            camera.scale = math.max(minZoomForWindow(), math.min(MAX_ZOOM, pinch.startScale * (dist / pinch.startDist)))
            local midX, midY = (a.x + b.x) / 2, (a.y + b.y) / 2
            local w, h = love.graphics.getWidth(), love.graphics.getHeight()
            camera.x = pinch.focusWX - (midX - w / 2) / camera.scale
            camera.y = pinch.focusWY - (midY - h / 2) / camera.scale
            clampCamera()
        end
        return
    end

    local dx, dy = x - t.startX, y - t.startY
    if not t.moved and (dx * dx + dy * dy) > TAP_MOVE_THRESHOLD * TAP_MOVE_THRESHOLD then
        t.moved = true
    end
    if t.moved then
        local wx, wy = screenToWorld(x, y)
        injectSwipeCurrent(wx, wy, dx / camera.scale, dy / camera.scale)
        t.startX, t.startY = x, y
    end
end

function love.touchreleased(id, x, y)
    if not IS_TOUCH then return end
    local t = activeTouches[id]
    activeTouches[id] = nil

    if pinch and (id == pinch.ids[1] or id == pinch.ids[2]) then
        pinch = nil
    end

    if not t or t.consumed or t.rowIndex then return end
    if not t.moved and (love.timer.getTime() - t.startTime) < TAP_TIME_THRESHOLD then
        handleWorldTap(x, y)
    end
end

-- Loaded only when capturing a README screenshot; see docs/capture-screenshot.sh.
if os.getenv("EVECELL_SCREENSHOT") then
    require("tools.screenshot")
end
