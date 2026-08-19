-- Trait definitions and heredity (mutation) for cells.
--
-- Every cell carries one of these genomes. Traits trade off against each
-- other through the energy economy in cell.lua rather than through any
-- explicit rule here -- e.g. high `speed` and `size` are expensive to
-- maintain, so "predator" is not a separate species, it's just a region
-- of trait-space (high aggression + enough size/speed to back it up) that
-- the population can evolve into or drift away from.
local Genome = {}

Genome.TRAITS = {
    { key = "speed",           min = 10,   max = 140,  default = 55,   mutSigma = 8 },
    { key = "size",             min = 3,    max = 16,   default = 6,    mutSigma = 1.2 },
    { key = "sense_radius",     min = 20,   max = 240,  default = 90,   mutSigma = 15 },
    { key = "metabolism",       min = 0.55, max = 1.6,  default = 1.0,  mutSigma = 0.08 },
    { key = "repro_threshold",  min = 0.4,  max = 0.95, default = 0.68, mutSigma = 0.05 },
    { key = "aggression",       min = 0,    max = 1,    default = 0.05, mutSigma = 0.06 },
    { key = "armor",            min = 0,    max = 1,    default = 0.05, mutSigma = 0.08 },
    { key = "toxicity",         min = 0,    max = 1,    default = 0.05, mutSigma = 0.08 },
    { key = "camouflage",       min = 0,    max = 1,    default = 0.1,  mutSigma = 0.08 },
    { key = "lifespan",         min = 40,   max = 280,  default = 140,  mutSigma = 25 },
    { key = "flagella",         min = 0,    max = 1,    default = 0.15, mutSigma = 0.1 },
    { key = "chlorophyll",      min = 0,    max = 1,    default = 0.1,  mutSigma = 0.1 },
    { key = "spikes",           min = 0,    max = 1,    default = 0.05, mutSigma = 0.08 },

    -- Predator traits: the offensive mirror of armor/toxicity above.
    { key = "bite_power",       min = 0,    max = 1,    default = 0.05, mutSigma = 0.08 },
    { key = "venom",            min = 0,    max = 1,    default = 0.05, mutSigma = 0.08 },

    -- Behavioral traits: unlike the traits above, these carry no upkeep
    -- cost of their own -- they just shift decision thresholds, so their
    -- entire trade-off is mediated through risk and opportunity rather
    -- than a constant energy tax.
    { key = "boldness",         min = 0,    max = 1,    default = 0.1,  mutSigma = 0.1 },
    { key = "sociality",        min = 0,    max = 1,    default = 0.1,  mutSigma = 0.1 },
    { key = "forage_persistence", min = 0,  max = 1,    default = 1.0,  mutSigma = 0.15 },

    -- Pack hunting is behavioral too -- no upkeep, its cost is purely
    -- that it only pays off with allies nearby.
    { key = "pack_hunting",     min = 0,    max = 1,    default = 0.05, mutSigma = 0.08 },
}

local MUTATION_RATE = 0.3 -- chance any single trait mutates when a child is created
local JACKPOT_CHANCE = 0.04 -- chance a birth also gets one dramatic, whole-range trait leap on top of the usual small drift

function Genome.default()
    local g = {}
    for _, t in ipairs(Genome.TRAITS) do g[t.key] = t.default end
    return g
end

-- A starting population isn't genetically identical: spread traits out
-- around their defaults so there's variation for selection to act on
-- from generation zero.
function Genome.randomized(spread)
    spread = spread or 0.3
    local g = {}
    for _, t in ipairs(Genome.TRAITS) do
        local range = t.max - t.min
        local jitter = (love.math.random() * 2 - 1) * range * spread
        g[t.key] = math.max(t.min, math.min(t.max, t.default + jitter))
    end
    return g
end

-- Approximates a normal distribution via sum of uniforms so mutations
-- cluster near zero (small tweaks) with occasional larger jumps, instead
-- of a flat/uniform mutation.
local function gaussianish()
    return (love.math.random() + love.math.random() + love.math.random() + love.math.random() - 2) / 2
end

-- Returns the mutated child genome, plus the trait key that took a
-- jackpot leap this birth (nil if none did).
function Genome.mutate(parentGenome)
    local child = {}
    for _, t in ipairs(Genome.TRAITS) do
        local v = parentGenome[t.key]
        if love.math.random() < MUTATION_RATE then
            v = v + gaussianish() * t.mutSigma
        end
        child[t.key] = math.max(t.min, math.min(t.max, v))
    end

    local jackpotTrait = nil
    if love.math.random() < JACKPOT_CHANCE then
        local t = Genome.TRAITS[love.math.random(#Genome.TRAITS)]
        child[t.key] = t.min + love.math.random() * (t.max - t.min)
        jackpotTrait = t.key
    end

    return child, jackpotTrait
end

return Genome
