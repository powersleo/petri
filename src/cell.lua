-- A single organism: behavior, energy economy, and reproduction.
local Genome = require("src.genome")

local Cell = {}
Cell.__index = Cell

-- Tribe identity: a lineage tag, not a genetic trait -- it doesn't mutate
-- or affect the energy economy, it just marks who's kin. Every cell with
-- no parent (the starting population) founds its own tribe; a child
-- normally inherits its parent's tribe, occasionally founding a new one
-- of its own (see TRIBE_FOUNDING_CHANCE), so family trees gradually
-- fork into distinct clans rather than the whole population staying one
-- undifferentiated tribe forever.
local nextTribeId = 1
function Cell.allocTribeId()
    local id = nextTribeId
    nextTribeId = nextTribeId + 1
    return id
end

-- Energy economy constants. Tuned so that: pure foraging is viable,
-- being big/fast is expensive to maintain, and predation only pays off
-- if you can actually catch things.
local BASE_UPKEEP = 1.3         -- energy/sec, just being alive
local SIZE_UPKEEP = 0.35        -- energy/sec per unit of size
local SPEED_UPKEEP = 1.1        -- energy/sec at speed=70, scales quadratically (fast is expensive regardless of size)
local ARMOR_UPKEEP = 0.85       -- energy/sec at armor=1, maintaining a thick cell wall isn't free
local TOXICITY_UPKEEP = 0.7     -- energy/sec at toxicity=1, synthesizing toxin isn't free
local CAMOUFLAGE_UPKEEP = 0.45  -- energy/sec at camouflage=1, pigment/texture upkeep
local FLAGELLA_UPKEEP = 0.4     -- energy/sec at flagella=1, running a flagellar motor isn't free
local FLAGELLA_SPEED_FLOOR = 0.5 -- fraction of the `speed` trait reachable with zero flagella
local CHLOROPHYLL_ENERGY_RATE = 2.0 -- energy/sec generated at chlorophyll=1, regardless of activity
local CHLOROPHYLL_UPKEEP = 0.15 -- energy/sec at chlorophyll=1, maintaining light-harvesting machinery isn't free
local CHLOROPHYLL_EXPOSURE = 1.0 -- chlorophyll=1 cancels out this fraction of camouflage's stealth -- visible pigment is hard to hide
local PREY_CHLOROPHYLL_BONUS = 0.5 -- a fully-chlorophyll candidate looks up to this much closer when a predator is picking a target
local FOOD_ENERGY = 24
local GRAZING_ENERGY_BONUS = 0.6 -- fraction more energy per bite at grazing_efficiency=1
local GRAZING_UPKEEP = 0.4      -- energy/sec at grazing_efficiency=1, better digestion isn't free
local FORAGING_SPEED_EAT_CUT = 0.6 -- fraction less chewing time at foraging_speed=1
local FORAGING_SPEED_UPKEEP = 0.4  -- energy/sec at foraging_speed=1, a faster gut isn't free
local PREDATION_EFFICIENCY = 0.95 -- fraction of prey's energy converted to attacker's energy
local CONTACT_MARGIN = 2
local BASE_CATCH_CHANCE = 0.65  -- per-second catch probability at parity
local CATCH_SPEED_WEIGHT = 0.5
local CATCH_SIZE_WEIGHT = 0.5
local CATCH_ARMOR_WEIGHT = 0.2  -- armor=1 subtracts this much catch probability
local TOXIN_DAMAGE_MAX = 12     -- energy drained from an attacker that eats a fully-toxic prey
-- Dish temperature (world.temperature, 0-100, player-adjustable): no cost
-- to anyone inside the comfort band, but every degree past either edge
-- taxes upkeep unless blunted by the matching resistance trait -- e.g. at
-- heat_resistance=1 a scorching dish costs nothing extra; at 0 it costs the
-- full rate.
local TEMP_COMFORT_LOW = 35
local TEMP_COMFORT_HIGH = 65
local TEMP_STRESS_UPKEEP = 0.06 -- energy/sec per degree outside the comfort band, at zero resistance
local HEAT_RESIST_UPKEEP = 0.5  -- energy/sec at heat_resistance=1, maintained whether or not it's ever needed
local COLD_RESIST_UPKEEP = 0.5  -- energy/sec at cold_resistance=1, maintained whether or not it's ever needed
local STRENGTH_UPKEEP = 0.45    -- energy/sec at strength=1, bracing against the current isn't free
local STRENGTH_CURRENT_RESIST = 0.85 -- fraction of the fluid's push cancelled out at strength=1
local VISCOSITY_SWIM_PENALTY = 0.5   -- fraction of swim speed lost at world.viscosity=1
local SPIKES_UPKEEP = 0.8       -- energy/sec at spikes=1, growing and maintaining them isn't free
local SPIKE_DAMAGE_PER_SEC = 7  -- energy/sec drained from an attacker grappling a fully-spiked prey, win or lose
local BITE_POWER_UPKEEP = 0.7   -- energy/sec at bite_power=1, stronger jaws/mandibles aren't free
local CATCH_BITE_POWER_WEIGHT = 0.4 -- bite_power=1 adds this much catch probability -- the offensive mirror of armor
local VENOM_UPKEEP = 0.7        -- energy/sec at venom=1, synthesizing it isn't free
local VENOM_DAMAGE_PER_SEC = 6  -- energy/sec drained from prey grappled by a fully-venomous attacker, win or lose -- can kill outright
local PACK_HUNTING_PER_ALLY = 0.06 -- catch probability bonus per nearby predator-ish cell, scaled by pack_hunting
local PACK_HUNTING_MAX_BONUS = 0.3 -- cap on the pack-hunting bonus so a big crowd doesn't make catches a certainty
-- Below this, hunting is completely gated off, so low-grade aggression
-- stays neutral (free to drift either way) instead of being actively
-- selected against for occasionally wasting a trip chasing prey it can't
-- reliably catch. Above it, hunting is committed to and needs to actually
-- pay off -- see the predation constants below.
local HUNT_AGGRESSION_THRESHOLD = 0.13
local PREY_LEASH_MULT = 1.7     -- how far past sense_radius a locked-on target can drift before being dropped
local KIN_CANNIBALISM_DESPERATION = 0.25 -- energy fraction below which a starving predator will consider its own tribe as prey
local TRIBE_FOUNDING_CHANCE = 0.05 -- chance a newborn founds a new tribe instead of inheriting its parent's
local PREY_PREDATOR_PENALTY = 1.7 -- a predator-ish candidate looks this much farther away when picking a target
local PREY_SPIKE_PENALTY = 1.8  -- a fully-spiked candidate looks up to this much farther away on top of that
-- Aposematic deterrence: a fully-toxic candidate looks up to this much
-- farther away too, on top of the above -- predators learning to avoid
-- conspicuous toxicity, not just get hurt after already committing to it.
local PREY_TOXICITY_PENALTY = 1.4
local ESCAPE_BURST_BONUS = 0.5  -- fraction faster while actively fleeing, at escape_burst=1
local ESCAPE_BURST_UPKEEP = 0.35 -- energy/sec at escape_burst=1, keeping the reflex primed isn't free
local HERD_DEFENSE_UPKEEP = 0.35 -- energy/sec at herd_defense=1, staying alert for others isn't free
local CAMOUFLAGE_EFFECT = 0.6   -- camouflage=1 shrinks how close others must be to detect this cell by this fraction
local LIFESPAN_VARIANCE = 0.3   -- +/- spread applied to genome.lifespan so old-age death isn't a hard deterministic wall
local MAX_ENERGY_BASE = 45
local MAX_ENERGY_PER_SIZE = 10
local REPRO_COST_FRACTION = 0.5 -- fraction of energy handed to a new child
local WANDER_TURN_RATE = 2.2
local PERSONAL_SPACE_MULT = 1.15 -- combined-radii multiplier inside which cells start pushing apart
local SEPARATION_WEIGHT = 1.3    -- how strongly that push competes with whatever else the cell is doing
local DANGER_MEMORY_DURATION = 10 -- seconds a cell keeps steering clear of where it last spotted a bigger predator
local DANGER_AVOID_WEIGHT = 1.1  -- how strongly that lingering avoidance competes with whatever else the cell is doing
local SOCIALITY_WEIGHT = 0.8     -- how strongly herding attraction competes with whatever else the cell is doing
local DIVIDE_DURATION = 0.45    -- seconds the division animation plays for, on both parent and child
local EAT_DURATION = 0.5        -- seconds spent eating on contact with food, before it's actually consumed
local JACKPOT_FLASH_DURATION = 3.0 -- seconds a jackpot-mutated newborn sparkles for

-- birthFromX/Y, if given, is the parent's position at the moment of
-- division: the new cell animates growing outward from that point instead
-- of just appearing at its spawn offset. `parent` is a direct reference to
-- the parent Cell, kept so a child can inherit its tribe -- see isKin below.
function Cell.new(x, y, genome, energy, birthFromX, birthFromY, parent)
    local self = setmetatable({}, Cell)
    self.x, self.y = x, y
    self.genome = genome
    self.parent = parent
    if parent and love.math.random() >= TRIBE_FOUNDING_CHANCE then
        self.tribeId = parent.tribeId
    else
        self.tribeId = Cell.allocTribeId()
    end
    self.maxEnergy = MAX_ENERGY_BASE + genome.size * MAX_ENERGY_PER_SIZE
    self.energy = energy or self.maxEnergy * 0.6
    self.dead = false
    self.dir = love.math.random() * math.pi * 2
    self.age = 0
    self.lifespanActual = genome.lifespan * (1 - LIFESPAN_VARIANCE + love.math.random() * LIFESPAN_VARIANCE * 2)
    self.state = "wander" -- wander | seekFood | hunt | flee | eating
    self.targetPrey = nil
    self.eatingTimer = 0
    self.eatingTarget = nil

    -- Remembers the last spot a bigger predator was spotted, so the cell
    -- keeps steering clear of that area for a while even after losing
    -- sight of the threat, rather than just reacting only while it's
    -- actively visible.
    self.dangerX, self.dangerY = 0, 0
    self.dangerTimer = 0

    -- Division animation state: `divideAnim` plays on the parent (a brief
    -- stretch/pulse), `birthAnim` plays on a freshly-split child (grows
    -- outward from the parent's position). Cells with no birth point
    -- (the starting population) skip the animation entirely.
    self.divideAnim = 0
    if birthFromX then
        self.birthAnim = DIVIDE_DURATION
        self.birthFromX, self.birthFromY = birthFromX, birthFromY
    else
        self.birthAnim = 0
    end

    -- Set by the caller right after a reproduction that rolled a jackpot
    -- mutation: `jackpotTrait` is a permanent record (shown in the
    -- inspector), `jackpotFlashTimer` drives a brief celebratory sparkle.
    self.jackpotTrait = nil
    self.jackpotFlashTimer = 0

    -- Stable per-cell visual seeds (chosen once at birth) so the membrane
    -- wobble, nucleus position, and organelle flecks read as a fixed
    -- individual shape rather than reshuffling every frame.
    self.wobbleSeed = love.math.random() * math.pi * 2
    self.nucleusAngle = love.math.random() * math.pi * 2
    self.nucleusMag = 0.12 + love.math.random() * 0.16
    self.organelles = {}
    for _ = 1, 3 do
        self.organelles[#self.organelles + 1] = {
            angle = love.math.random() * math.pi * 2,
            dist = 0.15 + love.math.random() * 0.4,
            rFrac = 0.08 + love.math.random() * 0.09,
        }
    end

    -- Body shape: mostly random per individual, with elongation nudged by
    -- the `speed` trait (faster genetic potential -> a bit more streamlined
    -- on average) so the population's silhouettes drift visibly over time.
    self.shapeLobes = love.math.random(2, 5)
    self.shapeAmp = 0.08 + love.math.random() * 0.16
    local streamline = 1 + (genome.speed / 140) * 0.4
    self.elongation = math.max(0.65, math.min(1.9, streamline + (love.math.random() * 2 - 1) * 0.35))

    return self
end

function Cell:isPredatorish()
    return self.genome.aggression > HUNT_AGGRESSION_THRESHOLD
end

-- Tribalism: cells sharing a tribe (see Cell.new) are kin, not just direct
-- parent/child -- siblings, cousins, and further descendants all count.
function Cell:isKin(other)
    return self.tribeId == other.tribeId
end

-- `speed` is genetic potential; `flagella` is what actually turns it into
-- movement -- no flagella caps you at half your top speed. `chlorophyll`
-- no longer costs speed; its downside is exposure (see isDetectable and
-- the prey-preference scoring in :update). escape_burst only kicks in
-- while actively fleeing -- a reflexive sprint, not a standing top speed --
-- so it also raises a fleeing prey's effective speed as seen by whichever
-- predator is chasing it (its catch-chance math reads this same method).
function Cell:effectiveSpeed()
    local g = self.genome
    local spd = g.speed * (FLAGELLA_SPEED_FLOOR + (1 - FLAGELLA_SPEED_FLOOR) * g.flagella)
    if self.state == "flee" then
        spd = spd * (1 + g.escape_burst * ESCAPE_BURST_BONUS)
    end
    return spd
end

-- Generous click-hit radius: a circle that comfortably encloses the
-- elongated/wobbling membrane shape, for cursor selection.
function Cell:hitRadius()
    return self.genome.size * math.max(self.elongation, 1 / self.elongation) * 1.15
end

-- Visual tuning for the organic membrane outline (no gameplay effect).
local MEMBRANE_SEGMENTS = 12
local MEMBRANE_WOBBLE_SPEED = 1.3 -- rad/sec, driven by the cell's own age so pausing freezes it

-- Maps a point given in the cell's own local frame (angle + distance from
-- center, pre-elongation) into world space: stretches along the local
-- x-axis by `elongation`, compresses the y-axis to match, then rotates by
-- `facing` so the long axis points wherever the cell is heading.
local function localToWorld(cx, cy, angle, dist, elongation, facing)
    local lx = math.cos(angle) * dist * elongation
    local ly = math.sin(angle) * dist / elongation
    local cosF, sinF = math.cos(facing), math.sin(facing)
    return cx + lx * cosF - ly * sinF, cy + lx * sinF + ly * cosF
end

-- Builds a wobbling, elongated membrane outline for one cell. `lobes` and
-- `amp` give each individual a distinct bumpiness; `elongation` and
-- `facing` stretch the shape into a rod/oval and orient it along whatever
-- direction the cell is currently moving.
local function membranePoints(cx, cy, radius, seed, age, lobes, amp, elongation, facing)
    local points = {}
    for i = 0, MEMBRANE_SEGMENTS - 1 do
        local angle = (i / MEMBRANE_SEGMENTS) * math.pi * 2
        local wobble = 1 + amp * math.sin(angle * lobes + age * MEMBRANE_WOBBLE_SPEED + seed)
        local px, py = localToWorld(cx, cy, angle, radius * wobble, elongation, facing)
        points[#points + 1] = px
        points[#points + 1] = py
    end
    return points
end

-- Advances this cell by dt. Returns a newly spawned child Cell, or nil.
function Cell:update(dt, world)
    self.age = self.age + dt
    if self.divideAnim > 0 then self.divideAnim = math.max(0, self.divideAnim - dt) end
    if self.birthAnim > 0 then self.birthAnim = math.max(0, self.birthAnim - dt) end
    if self.jackpotFlashTimer > 0 then self.jackpotFlashTimer = math.max(0, self.jackpotFlashTimer - dt) end
    if self.dangerTimer > 0 then self.dangerTimer = math.max(0, self.dangerTimer - dt) end
    if self.age >= self.lifespanActual then
        self.dead = true
        self.deathCause = "old_age"
        return nil
    end
    local g = self.genome

    local neighbors = world:queryCells(self.x, self.y, g.sense_radius, self)

    -- Boldness raises how much bigger a predator has to be before it even
    -- registers as a threat (bold cells shrug off marginal danger and
    -- keep foraging/hunting; timid ones flee at the first sign of one).
    local function isThreatTo(other)
        local requiredMargin = 1.2 + g.boldness * 0.6
        return other:isPredatorish() and other.genome.size > g.size * requiredMargin
    end

    -- Camouflage shrinks the range at which a cell can be picked out of
    -- the crowd as a threat or as prey (it doesn't help once you're
    -- already being chased -- see the prey-lock leash below). Chlorophyll
    -- works against that: visible green pigment is hard to hide, so it
    -- cancels out camouflage's stealth the more of it a cell has.
    local function isDetectable(other, d)
        local effectiveCamouflage = math.max(0, other.genome.camouflage - other.genome.chlorophyll * CHLOROPHYLL_EXPOSURE)
        return d <= g.sense_radius * (1 - effectiveCamouflage * CAMOUFLAGE_EFFECT)
    end

    -- Bold cells also don't bother paying attention to danger until it's
    -- fairly close -- their effective threat-detection range shrinks
    -- toward the middle of sense_radius, on top of the size margin above.
    local threatRange = g.sense_radius * (1 - g.boldness * 0.4)
    local threat, threatDist = nil, math.huge
    for _, other in ipairs(neighbors) do
        if isThreatTo(other) then
            local dx, dy = other.x - self.x, other.y - self.y
            local d = math.sqrt(dx * dx + dy * dy)
            if d < threatDist and d <= threatRange and isDetectable(other, d) then threat, threatDist = other, d end
        end
    end
    if threat then
        self.dangerX, self.dangerY = threat.x, threat.y
        self.dangerTimer = DANGER_MEMORY_DURATION

        -- Herd alarm: a spotted threat can also warn nearby herd-mates
        -- before they've noticed it themselves -- the defensive mirror of
        -- pack_hunting's group bonus. Radius scales with herd_defense, so
        -- at 0 the alarm doesn't carry at all.
        if g.herd_defense > 0 then
            local alarmRadius = g.sense_radius * g.herd_defense
            for _, other in ipairs(neighbors) do
                if not other:isPredatorish() then
                    local adx, ady = other.x - self.x, other.y - self.y
                    if adx * adx + ady * ady <= alarmRadius * alarmRadius then
                        other.dangerX, other.dangerY = threat.x, threat.y
                        other.dangerTimer = DANGER_MEMORY_DURATION
                    end
                end
            end
        end
    end

    -- Predatorish cells lock onto one prey target and keep pursuing it
    -- (within a leash beyond sense_radius) rather than re-picking the
    -- nearest cell every frame, which would just thrash between targets.
    -- A hunt already in progress stays committed even if food happens to
    -- be closer; a *new* hunt is only started when prey is worth the
    -- forgone food, so low-grade aggression doesn't starve out foragers.
    local prey, preyDist = nil, math.huge
    if g.aggression > HUNT_AGGRESSION_THRESHOLD and self.targetPrey and not self.targetPrey.dead then
        local dx, dy = self.targetPrey.x - self.x, self.targetPrey.y - self.y
        local d = math.sqrt(dx * dx + dy * dy)
        if d <= g.sense_radius * PREY_LEASH_MULT then
            prey, preyDist = self.targetPrey, d
        else
            self.targetPrey = nil
        end
    end

    local food = world:nearestFood(self.x, self.y, g.sense_radius)
    local foodDist = food and math.sqrt((food.x - self.x) ^ 2 + (food.y - self.y) ^ 2) or math.huge

    if not threat and not prey and g.aggression > HUNT_AGGRESSION_THRESHOLD then
        -- Predators would rather not eat their own tribe -- kin, not just
        -- direct offspring; a starving one (low energy) will consider them
        -- anyway as a last resort.
        local desperate = self.energy < self.maxEnergy * KIN_CANNIBALISM_DESPERATION

        -- Among viable candidates, prefer the easy meal: a plain herbivore
        -- over a predator (which might fight back), unspiked over spiked,
        -- and chlorophyll-heavy prey (sluggish, conspicuous) looks like an
        -- even easier mark. This only biases *which* target gets picked --
        -- `candidateDist` stays the real physical distance so movement and
        -- the contact-range catch check downstream are unaffected.
        local candidate, candidateDist, candidateScore = nil, math.huge, math.huge
        for _, other in ipairs(neighbors) do
            if not isThreatTo(other) and (desperate or not self:isKin(other)) then
                local dx, dy = other.x - self.x, other.y - self.y
                local d = math.sqrt(dx * dx + dy * dy)
                if isDetectable(other, d) then
                    local difficulty = 1
                    if other:isPredatorish() then difficulty = difficulty * PREY_PREDATOR_PENALTY end
                    difficulty = difficulty * (1 + other.genome.spikes * PREY_SPIKE_PENALTY)
                    difficulty = difficulty * (1 + other.genome.toxicity * PREY_TOXICITY_PENALTY)
                    difficulty = difficulty * (1 - other.genome.chlorophyll * PREY_CHLOROPHYLL_BONUS)
                    local score = d * difficulty
                    if score < candidateScore then
                        candidate, candidateDist, candidateScore = other, d, score
                    end
                end
            end
        end
        -- Willing to travel further past food for prey the more aggressive we are.
        if candidate and candidateScore <= foodDist * (1 + g.aggression * 4) then
            self.targetPrey = candidate
            prey, preyDist = candidate, candidateDist
        end
    end

    local targetDx, targetDy = 0, 0

    if threat then
        self.state = "flee"
        targetDx, targetDy = self.x - threat.x, self.y - threat.y
        -- Getting spooked mid-meal means abandoning it.
        self.eatingTimer = 0
        self.eatingTarget = nil
    elseif self.eatingTimer > 0 then
        self.state = "eating"
        self.eatingTimer = self.eatingTimer - dt
        if self.eatingTimer <= 0 then
            -- Someone else may have finished it off while we were still
            -- chewing; only collect if it's still actually there.
            if self.eatingTarget and self.eatingTarget.remaining and self.eatingTarget.remaining > 0 then
                world:consumeFood(self.eatingTarget)
                local energyGain = FOOD_ENERGY * (1 + g.grazing_efficiency * GRAZING_ENERGY_BONUS)
                self.energy = math.min(self.maxEnergy, self.energy + energyGain)
            end
            self.eatingTarget = nil
        end
    elseif prey then
        self.state = "hunt"
        local contactRange = g.size + prey.genome.size + CONTACT_MARGIN
        if preyDist > contactRange then
            -- Still closing the gap. Once within contact range, hold
            -- position instead of continuing to drive toward the prey's
            -- exact center -- otherwise a chase that takes a few failed
            -- catch rolls (common; it's probabilistic) just accumulates
            -- into the two bodies sitting on top of each other.
            targetDx, targetDy = prey.x - self.x, prey.y - self.y
        end

        if preyDist <= contactRange then
            -- Spiky prey injures whoever's grappling it every frame it's
            -- in reach, whether or not the catch actually lands -- unlike
            -- toxicity (which only punishes a successful kill) or armor
            -- (which only lowers the odds), this makes a drawn-out fight
            -- against a heavily-spiked target costly in its own right.
            if prey.genome.spikes > 0 then
                self.energy = self.energy - prey.genome.spikes * SPIKE_DAMAGE_PER_SEC * dt
                if self.energy <= 0 then
                    self.dead = true
                    self.deathCause = "spiked"
                    return nil
                end
            end

            -- Venom: the offensive mirror of spikes -- damages prey every
            -- frame it's in reach, whether or not the catch lands, and
            -- can kill it outright before a catch roll even happens.
            if g.venom > 0 and not prey.dead then
                local preyEnergyBeforeVenom = prey.energy
                prey.energy = prey.energy - g.venom * VENOM_DAMAGE_PER_SEC * dt
                if prey.energy <= 0 then
                    self.energy = math.min(self.maxEnergy, self.energy + preyEnergyBeforeVenom * PREDATION_EFFICIENCY)
                    prey.dead = true
                    prey.deathCause = "envenomed"
                    self.targetPrey = nil
                end
            end

            if not prey.dead then
                -- Pack hunting: a catch-probability bonus scaled by how
                -- many other predator-ish cells are nearby -- hunting in
                -- numbers pays off, hunting alone doesn't get the boost.
                local nearbyPredators = 0
                for _, other in ipairs(neighbors) do
                    if other ~= prey and other:isPredatorish() then nearbyPredators = nearbyPredators + 1 end
                end
                local packBonus = math.min(PACK_HUNTING_MAX_BONUS, g.pack_hunting * nearbyPredators * PACK_HUNTING_PER_ALLY)

                local speedDiff = (self:effectiveSpeed() - prey:effectiveSpeed()) / 140
                local sizeDiff = (g.size - prey.genome.size) / 16
                local pPerSec = BASE_CATCH_CHANCE + CATCH_SPEED_WEIGHT * speedDiff + CATCH_SIZE_WEIGHT * sizeDiff
                    - CATCH_ARMOR_WEIGHT * prey.genome.armor + CATCH_BITE_POWER_WEIGHT * g.bite_power + packBonus
                pPerSec = math.max(0.05, math.min(0.95, pPerSec))
                local pFrame = 1 - (1 - pPerSec) ^ dt
                if love.math.random() < pFrame then
                    local gained = prey.energy * PREDATION_EFFICIENCY
                    local toxinDamage = prey.genome.toxicity * TOXIN_DAMAGE_MAX
                    self.energy = math.min(self.maxEnergy, self.energy + gained - toxinDamage)
                    prey.dead = true
                    prey.deathCause = "eaten"
                    self.targetPrey = nil
                end
            end
        end
    elseif food and foodDist <= g.sense_radius * (0.3 + g.forage_persistence * 0.7) then
        -- Foraging persistence: a picky cell only bothers with food close
        -- by, saving the trip; a persistent one will cross its whole
        -- sense range for a meal. Food beyond this cutoff is simply
        -- ignored -- the cell wanders instead of visibly beelining for
        -- something it isn't willing to chase.
        self.state = "seekFood"
        targetDx, targetDy = food.x - self.x, food.y - self.y
        local eatRange = g.size + food.radius
        if foodDist <= eatRange then
            self.eatingTimer = EAT_DURATION * (1 - g.foraging_speed * FORAGING_SPEED_EAT_CUT)
            self.eatingTarget = food
            targetDx, targetDy = 0, 0
        end
    else
        self.state = "wander"
        self.dir = self.dir + (love.math.random() * 2 - 1) * WANDER_TURN_RATE * dt
        targetDx, targetDy = math.cos(self.dir), math.sin(self.dir)
    end

    -- Personal space: nudge away from other cells that are overlapping or
    -- nearly overlapping, so cells converging on the same food (or a
    -- parent and its newborn) don't just sit stacked on top of each other
    -- forever. Excludes whatever this cell is actively hunting/fleeing so
    -- it doesn't fight against those far stronger, deliberate movements.
    local ix, iy = 0, 0
    local len = math.sqrt(targetDx * targetDx + targetDy * targetDy)
    if len > 0.0001 then ix, iy = targetDx / len, targetDy / len end

    local sepX, sepY = 0, 0
    for _, other in ipairs(neighbors) do
        if other ~= prey and other ~= threat then
            local dx, dy = self.x - other.x, self.y - other.y
            local d = math.sqrt(dx * dx + dy * dy)
            local personalSpace = (g.size + other.genome.size) * PERSONAL_SPACE_MULT
            if d < personalSpace and d > 0.0001 then
                local push = (personalSpace - d) / personalSpace
                sepX = sepX + (dx / d) * push
                sepY = sepY + (dy / d) * push
            end
        end
    end

    -- Sociality: an attraction toward the center of mass of nearby peers
    -- (anything that isn't a threat or the thing being hunted), pulling
    -- social cells into loose herds. Personal-space separation above
    -- still wins at close range, so this reads as clustering, not
    -- stacking -- and it costs nothing directly; the risk is purely that
    -- a dense, easy-to-find herd is also an easy hunting ground.
    local socX, socY = 0, 0
    if g.sociality > 0.05 then
        local cx, cy, count = 0, 0, 0
        for _, other in ipairs(neighbors) do
            if other ~= prey and other ~= threat then
                cx, cy = cx + other.x, cy + other.y
                count = count + 1
            end
        end
        if count > 0 then
            cx, cy = cx / count, cy / count
            local dx, dy = cx - self.x, cy - self.y
            local d = math.sqrt(dx * dx + dy * dy)
            if d > 0.0001 then
                socX, socY = (dx / d) * g.sociality, (dy / d) * g.sociality
            end
        end
    end

    -- Lingering avoidance of a recently-seen bigger predator's location,
    -- fading out as the memory ages. Only kicks in once the threat is no
    -- longer actually in sight -- while it's visible, the direct flee
    -- above already handles it.
    local danX, danY = 0, 0
    if not threat and self.dangerTimer > 0 then
        local dx, dy = self.x - self.dangerX, self.y - self.dangerY
        local d = math.sqrt(dx * dx + dy * dy)
        local avoidRadius = g.sense_radius * 2
        if d > 0.0001 and d < avoidRadius then
            local timeFade = self.dangerTimer / DANGER_MEMORY_DURATION
            local distFade = 1 - d / avoidRadius
            danX, danY = (dx / d) * timeFade * distFade, (dy / d) * timeFade * distFade
        end
    end

    local finalX = ix + sepX * SEPARATION_WEIGHT + danX * DANGER_AVOID_WEIGHT + socX * SOCIALITY_WEIGHT
    local finalY = iy + sepY * SEPARATION_WEIGHT + danY * DANGER_AVOID_WEIGHT + socY * SOCIALITY_WEIGHT
    local finalLen = math.sqrt(finalX * finalX + finalY * finalY)
    if finalLen > 0.0001 then
        local nx, ny = finalX / finalLen, finalY / finalLen
        self.dir = math.atan2(ny, nx)
        local dist = self:effectiveSpeed() * (1 - world.viscosity * VISCOSITY_SWIM_PENALTY) * dt
        self.x = self.x + nx * dist
        self.y = self.y + ny * dist
    end

    world:constrain(self)

    local speedRatio = g.speed / 70
    local upkeep = g.metabolism * (BASE_UPKEEP + SIZE_UPKEEP * g.size + SPEED_UPKEEP * speedRatio * speedRatio
        + ARMOR_UPKEEP * g.armor + TOXICITY_UPKEEP * g.toxicity + CAMOUFLAGE_UPKEEP * g.camouflage
        + FLAGELLA_UPKEEP * g.flagella + CHLOROPHYLL_UPKEEP * g.chlorophyll + SPIKES_UPKEEP * g.spikes
        + BITE_POWER_UPKEEP * g.bite_power + VENOM_UPKEEP * g.venom
        + HEAT_RESIST_UPKEEP * g.heat_resistance + COLD_RESIST_UPKEEP * g.cold_resistance
        + GRAZING_UPKEEP * g.grazing_efficiency + FORAGING_SPEED_UPKEEP * g.foraging_speed
        + ESCAPE_BURST_UPKEEP * g.escape_burst + HERD_DEFENSE_UPKEEP * g.herd_defense
        + STRENGTH_UPKEEP * g.strength)

    -- Dish temperature is environmental stress, not internal upkeep, so
    -- unlike the block above it isn't scaled by metabolism -- a fast or
    -- slow metabolism doesn't change how exposed a cell is to the water
    -- around it.
    local temp = world.temperature or TEMP_COMFORT_LOW
    if temp > TEMP_COMFORT_HIGH then
        upkeep = upkeep + TEMP_STRESS_UPKEEP * (temp - TEMP_COMFORT_HIGH) * (1 - g.heat_resistance)
    elseif temp < TEMP_COMFORT_LOW then
        upkeep = upkeep + TEMP_STRESS_UPKEEP * (TEMP_COMFORT_LOW - temp) * (1 - g.cold_resistance)
    end

    self.energy = self.energy - upkeep * dt

    -- Passive light-harvesting income, independent of foraging/hunting.
    -- Doesn't scale with size, so it matters most for small cells (better
    -- surface-to-volume ratio). Its real cost is exposure, not speed --
    -- see isDetectable and the prey-preference scoring above, where
    -- chlorophyll undermines camouflage and makes a cell a preferred
    -- target. Only ever a supplement, not a replacement, for a diet.
    self.energy = math.min(self.maxEnergy, self.energy + g.chlorophyll * CHLOROPHYLL_ENERGY_RATE * dt)

    if self.energy <= 0 then
        self.dead = true
        self.deathCause = "starved"
        return nil
    end

    if self.energy >= self.maxEnergy * g.repro_threshold then
        local childGenome, jackpotTrait = Genome.mutate(g)
        local giveEnergy = self.energy * REPRO_COST_FRACTION
        self.energy = self.energy - giveEnergy
        local angle = love.math.random() * math.pi * 2
        local spawnDist = g.size + 4
        local cx = self.x + math.cos(angle) * spawnDist
        local cy = self.y + math.sin(angle) * spawnDist
        self.divideAnim = DIVIDE_DURATION
        local child = Cell.new(cx, cy, childGenome, giveEnergy, self.x, self.y, self)
        if jackpotTrait then
            child.jackpotTrait = jackpotTrait
            child.jackpotFlashTimer = JACKPOT_FLASH_DURATION
        end
        return child
    end

    return nil
end

function Cell:draw()
    local g = self.genome
    local energyFrac = math.max(0, math.min(1, self.energy / self.maxEnergy))
    local aggr = g.aggression

    -- Blue-ish herbivores shade toward red as aggression rises; dims when low on energy.
    local r = 0.15 + (0.25 + aggr * 0.7) * energyFrac
    local gg = 0.1 + (0.35 + (1 - aggr) * 0.35) * energyFrac
    local b = 0.15 + (0.85 - aggr * 0.55) * energyFrac

    -- Toxicity reads as aposematic (warning) coloration: bright yellow-green.
    local warn = g.toxicity * 0.6
    r = r * (1 - warn) + 0.85 * warn
    gg = gg * (1 - warn) + 0.95 * warn
    b = b * (1 - warn) + 0.1 * warn

    -- Chlorophyll expresses as extra green layered on top of whatever
    -- aggression/toxicity already set, rather than overriding it -- a
    -- photosynthetic predator still reads as reddish, just with a
    -- greener cast, instead of every chlorophyll-heavy cell converging
    -- on the same forest-green regardless of its other traits.
    gg = math.min(1, gg + g.chlorophyll * 0.55)
    r = r * (1 - g.chlorophyll * 0.25)
    b = b * (1 - g.chlorophyll * 0.25)

    -- Venom expresses as a violet cast, same layered treatment.
    r = math.min(1, r + g.venom * 0.3)
    b = math.min(1, b + g.venom * 0.4)
    gg = gg * (1 - g.venom * 0.2)

    -- Cells dim a little as they approach the end of their natural lifespan.
    local ageFrac = self.age / self.lifespanActual
    local ageDim = 1 - 0.3 * ageFrac
    r, gg, b = r * ageDim, gg * ageDim, b * ageDim

    -- Camouflage fades the cell toward the background (a mild visual cue;
    -- the real detection-range effect is in Cell:update).
    local alpha = 1 - g.camouflage * 0.35

    -- Division animation: a newborn child grows outward from the point it
    -- split off from (birthAnim), while a dividing parent gets a brief
    -- elongation pulse (divideAnim). Wrapping the whole draw in a
    -- translate/scale pivoted on the cell's own center lets every shape
    -- below stay written in normal self.x/self.y coordinates.
    local drawX, drawY, sizeMul = self.x, self.y, 1
    if self.birthAnim > 0 then
        local t = 1 - self.birthAnim / DIVIDE_DURATION
        local ease = t * t * (3 - 2 * t)
        drawX = self.birthFromX + (self.x - self.birthFromX) * ease
        drawY = self.birthFromY + (self.y - self.birthFromY) * ease
        sizeMul = 0.25 + 0.75 * ease
    end
    love.graphics.push()
    love.graphics.translate(drawX, drawY)
    love.graphics.scale(sizeMul, sizeMul)
    love.graphics.translate(-self.x, -self.y)

    -- Soft contact shadow, offset from an implied angled light overhead,
    -- so the cell reads as resting in the liquid instead of pasted flat
    -- on the dish floor.
    love.graphics.setColor(0.03, 0.05, 0.06, 0.14 * alpha)
    love.graphics.circle("fill", self.x + g.size * 0.22, self.y + g.size * 0.3, g.size * 0.92)

    local drawElongation = self.elongation
    if self.divideAnim > 0 then
        local t = 1 - self.divideAnim / DIVIDE_DURATION
        drawElongation = self.elongation * (1 + math.sin(t * math.pi) * 0.6)
    end

    -- Flagellum first so the membrane draws over its base. Only cells
    -- that actually evolved one grow a visible tail; its length and whip
    -- speed track the trait (and how fast it's actually being used).
    if g.flagella > 0.15 then
        local tailLen = g.size * (0.5 + g.flagella * 1.8)
        local bx, by = localToWorld(self.x, self.y, math.pi, g.size * 0.85, drawElongation, self.dir)
        local px, py = -math.sin(self.dir), math.cos(self.dir)
        local whipSpeed = 4 + self:effectiveSpeed() / 140 * 8
        local wave = math.sin(self.age * whipSpeed + self.wobbleSeed) * g.size * 0.3
        local mx = bx - math.cos(self.dir) * tailLen * 0.5 + px * wave
        local my = by - math.sin(self.dir) * tailLen * 0.5 + py * wave
        local ex = bx - math.cos(self.dir) * tailLen - px * wave * 0.6
        local ey = by - math.sin(self.dir) * tailLen - py * wave * 0.6
        love.graphics.setColor(r, gg, b, alpha * 0.5)
        love.graphics.setLineWidth(1.2)
        love.graphics.line(bx, by, mx, my, ex, ey)
    end

    -- Membrane: a darker rim polygon with a brighter cytoplasm fill inset
    -- inside it, both gently wobbling so the outline reads as organic
    -- rather than a perfect circle.
    -- Spikes: drawn before the membrane so it covers their base, leaving
    -- only the outward-pointing tips visible past the rim. The fill was
    -- previously near-white -- almost the same color as the dish
    -- background -- so a dark outline is added for contrast against any
    -- backdrop, and the tips are drawn a bit longer/wider so they read
    -- clearly instead of vanishing into the membrane's wobble.
    if g.spikes > 0.1 then
        local spikeCount = 9
        local spikeLen = g.size * (0.4 + g.spikes * 0.9)
        local baseR = g.size * 0.88
        love.graphics.setLineWidth(1)
        for i = 0, spikeCount - 1 do
            local angle = (i / spikeCount) * math.pi * 2 + self.wobbleSeed
            local bx1, by1 = localToWorld(self.x, self.y, angle - 0.11, baseR, drawElongation, self.dir)
            local bx2, by2 = localToWorld(self.x, self.y, angle + 0.11, baseR, drawElongation, self.dir)
            local tx, ty = localToWorld(self.x, self.y, angle, baseR + spikeLen, drawElongation, self.dir)
            love.graphics.setColor(0.92, 0.9, 0.85, alpha * 0.95)
            love.graphics.polygon("fill", bx1, by1, tx, ty, bx2, by2)
            love.graphics.setColor(0.12, 0.1, 0.08, alpha * 0.85)
            love.graphics.polygon("line", bx1, by1, tx, ty, bx2, by2)
        end
    end

    -- Fangs (bite_power): two prominent points at the front, in the
    -- direction of travel, distinct from the all-around spikes above.
    if g.bite_power > 0.15 then
        local fangLen = g.size * (0.4 + g.bite_power * 0.9)
        local baseR = g.size * 0.9
        love.graphics.setColor(0.92, 0.88, 0.7, alpha * 0.95)
        for _, sign in ipairs({ -1, 1 }) do
            local angle = sign * 0.3
            local bx1, by1 = localToWorld(self.x, self.y, angle - 0.05, baseR, drawElongation, self.dir)
            local bx2, by2 = localToWorld(self.x, self.y, angle + 0.05, baseR, drawElongation, self.dir)
            local tx, ty = localToWorld(self.x, self.y, angle, baseR + fangLen, drawElongation, self.dir)
            love.graphics.polygon("fill", bx1, by1, tx, ty, bx2, by2)
        end
    end

    local outer = membranePoints(self.x, self.y, g.size, self.wobbleSeed, self.age,
        self.shapeLobes, self.shapeAmp, drawElongation, self.dir)
    love.graphics.setColor(r * 0.6, gg * 0.6, b * 0.6, alpha)
    love.graphics.polygon("fill", outer)

    local inner = membranePoints(self.x, self.y, g.size * 0.8, self.wobbleSeed, self.age,
        self.shapeLobes, self.shapeAmp, drawElongation, self.dir)
    love.graphics.setColor(math.min(1, r * 1.2), math.min(1, gg * 1.2), math.min(1, b * 1.2), alpha)
    love.graphics.polygon("fill", inner)

    -- Organelle flecks, scattered around the cytoplasm.
    for _, o in ipairs(self.organelles) do
        local ox, oy = localToWorld(self.x, self.y, o.angle, o.dist * g.size, drawElongation, self.dir)
        love.graphics.setColor(math.min(1, r * 1.5), math.min(1, gg * 1.5), math.min(1, b * 1.5), alpha * 0.6)
        love.graphics.circle("fill", ox, oy, g.size * o.rFrac)
    end

    -- Nucleus, offset off-center for an organic look.
    local nx, ny = localToWorld(self.x, self.y, self.nucleusAngle, self.nucleusMag * g.size, drawElongation, self.dir)
    love.graphics.setColor(r * 0.35 + 0.05, gg * 0.3 + 0.03, b * 0.5 + 0.08, alpha * 0.85)
    love.graphics.circle("fill", nx, ny, g.size * 0.34)

    -- Diet indicator: predator-ish cells get an unmistakable red ring
    -- (herbivores get none), so diet reads at a glance independent of the
    -- body-color gradient, which alone is too subtle right at the
    -- aggression threshold.
    if self:isPredatorish() then
        love.graphics.setColor(0.95, 0.2, 0.15, 0.85)
        love.graphics.setLineWidth(1.6)
        love.graphics.circle("line", self.x, self.y, g.size + 1.5)
    end
    if g.armor > 0.15 then
        love.graphics.setColor(0.8, 0.8, 0.85, 0.35 + g.armor * 0.4)
        love.graphics.circle("line", self.x, self.y, g.size + 2.5)
    end

    -- A rare jackpot mutation gets a brief celebratory sparkle of orbiting
    -- gold flecks when the cell is newborn.
    if self.jackpotFlashTimer > 0 then
        local fade = self.jackpotFlashTimer / JACKPOT_FLASH_DURATION
        local sparkCount = 6
        for i = 0, sparkCount - 1 do
            local sparkAngle = self.age * 3 + i * (math.pi * 2 / sparkCount)
            local sparkR = g.size + 5 + math.sin(self.age * 6 + i) * 2
            local sx = self.x + math.cos(sparkAngle) * sparkR
            local sy = self.y + math.sin(sparkAngle) * sparkR
            local twinkle = 0.6 + 0.4 * math.sin(self.age * 10 + i * 2)
            love.graphics.setColor(1, 0.85, 0.3, fade * twinkle)
            love.graphics.circle("fill", sx, sy, 1.6)
        end
    end

    love.graphics.pop()
end

return Cell
