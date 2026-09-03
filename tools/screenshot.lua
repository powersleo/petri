-- Capture a PNG after N seconds of simulation, then quit.
-- Used by docs/capture-screenshot.sh; not loaded during normal play.
local delay = tonumber(os.getenv("EVECELL_SCREENSHOT")) or 2.5
local elapsed = 0
local requested = false

local prevUpdate = love.update
function love.update(dt)
    prevUpdate(dt)
    elapsed = elapsed + dt
end

local prevDraw = love.draw
function love.draw()
    prevDraw()
    if not requested and elapsed >= delay then
        requested = true
        love.graphics.captureScreenshot(function(image)
            image:encode("png", "portfolio.png")
            love.event.quit()
        end)
    end
end
