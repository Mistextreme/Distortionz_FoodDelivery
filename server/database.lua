-- ╔══════════════════════════════════════════════════════════════════╗
-- ║ Distortionz Food Delivery — database layer (ESX-Legacy)          ║
-- ║ Schema bootstrap + rating CRUD via oxmysql.                      ║
-- ║                                                                  ║
-- ║ ESX-Legacy change: primary key column renamed from               ║
-- ║ `citizenid` (QBCore) to `identifier` (ESX xPlayer.identifier).  ║
-- ╚══════════════════════════════════════════════════════════════════╝

DB = DB or {}

-- ─── Schema bootstrap ──────────────────────────────────────────────
-- Runs once on resource start. Idempotent — safe to run on every boot.
-- NOTE: identifier uses VARCHAR(60) — ESX identifiers (license:xxx,
-- steam:xxx) can exceed 50 chars used by QBCore citizenids.
local SCHEMA = [[
CREATE TABLE IF NOT EXISTS distortionz_fooddelivery_ratings (
    identifier VARCHAR(60) PRIMARY KEY,
    total_deliveries INT NOT NULL DEFAULT 0,
    rating_sum DECIMAL(12, 2) NOT NULL DEFAULT 0,
    last_ratings JSON NOT NULL,
    last_delivery_at TIMESTAMP NULL DEFAULT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    INDEX idx_total (total_deliveries),
    INDEX idx_last_delivery (last_delivery_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
]]

CreateThread(function()
    local ok, err = pcall(function()
        MySQL.query.await(SCHEMA, {})
    end)
    if not ok then
        print(('^1[distortionz_fooddelivery] ^7DB schema bootstrap FAILED: %s'):format(tostring(err)))
        return
    end
    print('^2[distortionz_fooddelivery]^7 DB schema verified.')
end)

-- ─── Get rating row for an identifier (creates default if missing) ──
function DB.GetRating(identifier)
    if not identifier or identifier == '' then return nil end

    local rows = MySQL.query.await(
        'SELECT total_deliveries, rating_sum, last_ratings, last_delivery_at FROM distortionz_fooddelivery_ratings WHERE identifier = ? LIMIT 1',
        { identifier }
    )

    if rows and rows[1] then
        local row = rows[1]
        local last = {}
        if row.last_ratings and row.last_ratings ~= '' then
            local ok, decoded = pcall(json.decode, row.last_ratings)
            if ok and type(decoded) == 'table' then last = decoded end
        end
        return {
            identifier      = identifier,
            totalDeliveries = tonumber(row.total_deliveries) or 0,
            ratingSum       = tonumber(row.rating_sum) or 0,
            lastRatings     = last,
            lastDeliveryAt  = row.last_delivery_at,
        }
    end

    -- No row yet — return empty default
    return {
        identifier      = identifier,
        totalDeliveries = 0,
        ratingSum       = 0,
        lastRatings     = {},
        lastDeliveryAt  = nil,
    }
end

-- ─── Append a new rating to a player's history ──────────────────────
-- starsRating = number 1.0–5.0, windowSize = max history entries
function DB.AppendRating(identifier, starsRating, windowSize)
    if not identifier or identifier == '' then return false end

    local current = DB.GetRating(identifier)
    if not current then return false end

    -- Append new rating
    local list = current.lastRatings or {}
    list[#list + 1] = tonumber(starsRating) or 5.0

    -- Trim to window size (keep most recent N)
    while #list > windowSize do
        table.remove(list, 1)
    end

    local newTotal = current.totalDeliveries + 1
    local newSum   = current.ratingSum + (tonumber(starsRating) or 5.0)

    -- Upsert
    MySQL.query.await([[
        INSERT INTO distortionz_fooddelivery_ratings
            (identifier, total_deliveries, rating_sum, last_ratings, last_delivery_at)
        VALUES (?, ?, ?, ?, NOW())
        ON DUPLICATE KEY UPDATE
            total_deliveries = VALUES(total_deliveries),
            rating_sum       = VALUES(rating_sum),
            last_ratings     = VALUES(last_ratings),
            last_delivery_at = VALUES(last_delivery_at)
    ]], {
        identifier,
        newTotal,
        newSum,
        json.encode(list),
    })

    return true
end

-- ─── Get the rolling average over the last N ratings ───────────────
-- Returns: average (number), count (int)
function DB.GetRollingAverage(identifier)
    local rec = DB.GetRating(identifier)
    if not rec then return Config.Rating.defaultRating, 0 end

    local list = rec.lastRatings or {}
    if #list == 0 then
        return Config.Rating.defaultRating, 0
    end

    local sum = 0
    for _, r in ipairs(list) do sum = sum + (tonumber(r) or 0) end
    return (sum / #list), #list
end
