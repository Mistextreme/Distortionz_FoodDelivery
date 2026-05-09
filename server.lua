-- ╔══════════════════════════════════════════════════════════════════╗
-- ║ Distortionz Food Delivery — server                               ║
-- ║                                                                  ║
-- ║ Receives "start delivery" requests from a restaurant ped, picks  ║
-- ║ a random customer location + menu items, gives the player the    ║
-- ║ items, and tracks the active job. On hand-over, validates items  ║
-- ║ are present, removes them, computes payout + tip + rating, pays  ║
-- ║ the player, and writes the rating to MySQL.                      ║
-- ╚══════════════════════════════════════════════════════════════════╝

-- ─── State ──────────────────────────────────────────────────────────
local activeJobs    = {}  -- src -> { restaurant, customerIndex, customerCoords, items, startTimeMs, expectedTimeMs, distance, ... }
local cooldownsAt   = {}  -- src -> ms timestamp until cooldown expires
local nextJobId     = 1

-- ─── Helpers ────────────────────────────────────────────────────────
local function Debug(...)
    if Config.Debug then
        print(('[fooddelivery:server] %s'):format(table.concat({...}, ' ')))
    end
end

local function getPlayer(src)
    local ok, p = pcall(function() return exports.qbx_core:GetPlayer(src) end)
    if not ok then return nil end
    return p
end

local function getCitizenId(src)
    local p = getPlayer(src)
    if not p or not p.PlayerData then return nil end
    return p.PlayerData.citizenid
end

local function notify(src, message, notifyType, duration, title)
    notifyType = notifyType or 'primary'
    duration   = duration or 5000
    title      = title or Config.Notify.title
    -- Prefer custom notify
    if GetResourceState(Config.Notify.resource) == 'started' then
        TriggerClientEvent('distortionz_fooddelivery:client:notify', src, message, notifyType, duration, title)
        return
    end
    TriggerClientEvent('ox_lib:notify', src, {
        title       = title,
        description = message,
        type        = notifyType,
        duration    = duration,
    })
end

-- ─── Resolve rating tier ────────────────────────────────────────────
local function resolveTier(avgRating, deliveryCount)
    -- Below minimum delivery count → standard tier
    if deliveryCount < (Config.Rating.minDeliveriesForTier or 5) then
        for _, tier in ipairs(Config.Rating.tiers) do
            if tier.label == 'Standard' then return tier end
        end
    end
    for _, tier in ipairs(Config.Rating.tiers) do
        if avgRating >= tier.minRating then return tier end
    end
    return Config.Rating.tiers[#Config.Rating.tiers]   -- fallback to lowest
end

-- ─── Generate a random order from a restaurant's menu ──────────────
local function generateOrder(restaurantId)
    local restaurant
    for _, r in ipairs(Config.Restaurants) do
        if r.id == restaurantId then restaurant = r; break end
    end
    if not restaurant then return nil end

    local menu = Config.MenuItems[restaurant.menu]
    if not menu or not menu.items or #menu.items == 0 then return nil end

    -- Roll number of distinct items
    local nItems = math.random(Config.Job.minOrderItems, Config.Job.maxOrderItems)
    if nItems > #menu.items then nItems = #menu.items end

    -- Pick distinct items by shuffle
    local pool = {}
    for _, name in ipairs(menu.items) do pool[#pool + 1] = name end
    for i = #pool, 2, -1 do
        local j = math.random(i)
        pool[i], pool[j] = pool[j], pool[i]
    end

    local order = {}
    for i = 1, nItems do
        order[#order + 1] = {
            name  = pool[i],
            count = math.random(1, 2),
        }
    end

    return order, restaurant
end

-- ─── Compute payout for a delivered order ──────────────────────────
-- Returns: finalPay, tier, breakdown table
local function computePayout(distanceM, elapsedSec, expectedSec, ratingTier)
    local base = Config.Payment.basePay or 80
    local distanceTip = math.floor(distanceM * (Config.Payment.perMeterTip or 0))

    local raw = base + distanceTip

    -- Time penalty
    if elapsedSec > expectedSec then
        raw = math.floor(raw * (1.0 - Config.Payment.timeOverrunPenaltyPct))
    end

    -- Rating multiplier
    local mult = (ratingTier and ratingTier.multiplier) or 1.0
    local final = math.floor(raw * mult)

    -- Clamp
    final = math.max(Config.Payment.minPayout or 0,
              math.min(Config.Payment.maxPayout or 9999, final))

    return final, {
        base        = base,
        distanceTip = distanceTip,
        timePenalty = elapsedSec > expectedSec,
        ratingMult  = mult,
    }
end

-- ─── Roll customer star rating ──────────────────────────────────────
-- Performance-influenced: on time and right mode = high; late or wrong
-- mode = low. Random jitter on top.
local function rollCustomerRating(elapsedSec, expectedSec, distance, tookVehicle)
    local base = 5.0
    local timeRatio = elapsedSec / math.max(1, expectedSec)

    -- Time scoring
    if timeRatio <= 0.85 then
        base = 5.0
    elseif timeRatio <= 1.0 then
        base = 4.5
    elseif timeRatio <= 1.25 then
        base = 4.0
    elseif timeRatio <= 1.6 then
        base = 3.0
    elseif timeRatio <= 2.0 then
        base = 2.0
    else
        base = 1.0
    end

    -- Mode appropriateness
    local needsVehicle = distance >= (Config.Job.walkVsVehicleThresholdM or 500.0)
    if needsVehicle and not tookVehicle then
        base = base - 0.5    -- player walked when they should've driven
    elseif (not needsVehicle) and tookVehicle then
        -- Driving for a short trip is fine, slight nudge down for being lazy
        base = base - 0.1
    end

    -- Random jitter
    local jitter = (math.random() * 2.0 - 1.0) * (Config.Rating.starRollVariance or 0.4)
    base = base + jitter

    -- Round to nearest 0.5
    base = math.floor((base * 2) + 0.5) / 2

    -- Clamp 1.0 to 5.0
    if base < 1.0 then base = 1.0 end
    if base > 5.0 then base = 5.0 end
    return base
end

-- ─── Pick a random customer spawn ──────────────────────────────────
local function pickCustomer(restaurantCoords)
    local spawns = Config.CustomerSpawns
    if not spawns or #spawns == 0 then return nil end

    -- Try up to 8 random picks; prefer ones that aren't right next to the restaurant
    local minDist = 100.0
    for _ = 1, 8 do
        local idx = math.random(#spawns)
        local c = spawns[idx]
        local dx = c.x - restaurantCoords.x
        local dy = c.y - restaurantCoords.y
        local d = math.sqrt(dx*dx + dy*dy)
        if d >= minDist then
            return idx, c, d
        end
    end

    -- Fallback: just take a random one
    local idx = math.random(#spawns)
    local c = spawns[idx]
    local dx = c.x - restaurantCoords.x
    local dy = c.y - restaurantCoords.y
    local d = math.sqrt(dx*dx + dy*dy)
    return idx, c, d
end

-- ─── ox_inventory item helpers ─────────────────────────────────────
local function giveOrderItems(src, items)
    local ok = true
    for _, it in ipairs(items) do
        local added = exports.ox_inventory:AddItem(src, it.name, it.count)
        if not added then
            ok = false
            -- Roll back any items we already added
            for _, prev in ipairs(items) do
                if prev == it then break end
                exports.ox_inventory:RemoveItem(src, prev.name, prev.count)
            end
            break
        end
    end
    return ok
end

local function hasOrderItems(src, items)
    for _, it in ipairs(items) do
        local count = exports.ox_inventory:GetItemCount(src, it.name)
        if (count or 0) < it.count then return false, it.name end
    end
    return true
end

local function removeOrderItems(src, items)
    for _, it in ipairs(items) do
        exports.ox_inventory:RemoveItem(src, it.name, it.count)
    end
end

-- ─── lib.callback: fetch player rating summary ─────────────────────
lib.callback.register('distortionz_fooddelivery:cb:getRating', function(src)
    local citizenid = getCitizenId(src)
    if not citizenid then return nil end

    local avg, count = DB.GetRollingAverage(citizenid)
    local tier = resolveTier(avg, count)
    return {
        average     = avg,
        deliveries  = count,
        tierLabel   = tier and tier.label or 'Standard',
        tierMult    = tier and tier.multiplier or 1.0,
    }
end)

-- ─── lib.callback: start a delivery from a restaurant ──────────────
lib.callback.register('distortionz_fooddelivery:cb:startJob', function(src, payload)
    if type(payload) ~= 'table' or not payload.restaurantId then
        return { ok = false, reason = 'Invalid request.' }
    end

    -- Cooldown check
    local now = GetGameTimer()
    if cooldownsAt[src] and now < cooldownsAt[src] then
        local left = math.ceil((cooldownsAt[src] - now) / 1000)
        return { ok = false, reason = ('On cooldown — %ds left.'):format(left) }
    end

    -- Already on a job?
    if activeJobs[src] then
        return { ok = false, reason = 'You already have an active delivery.' }
    end

    -- Generate order
    local order, restaurant = generateOrder(payload.restaurantId)
    if not order or not restaurant then
        return { ok = false, reason = 'Restaurant not available.' }
    end

    -- Pick customer
    local custIdx, custCoord, distance = pickCustomer(restaurant.coords)
    if not custIdx then
        return { ok = false, reason = 'No customers available right now.' }
    end

    -- Give items
    if not giveOrderItems(src, order) then
        return { ok = false, reason = 'Your inventory is too full.' }
    end

    -- Compute expected time
    local expectedSec = Config.Payment.expectedTimeBaseS + math.floor((distance / 1000.0) * Config.Payment.expectedTimePerKmS)

    local job = {
        id              = nextJobId,
        restaurantId    = restaurant.id,
        restaurantLabel = restaurant.label,
        customerIndex   = custIdx,
        customerCoords  = { x = custCoord.x, y = custCoord.y, z = custCoord.z, w = custCoord.w },
        items           = order,
        distance        = distance,
        startTimeMs     = now,
        expectedTimeMs  = expectedSec * 1000,
        timeoutAtMs     = now + (Config.Job.customerOrderTimeoutS * 1000),
    }
    activeJobs[src] = job
    nextJobId = nextJobId + 1

    Debug(('startJob src=%d restaurant=%s customer=%d distance=%.1f items=%d'):format(
        src, restaurant.id, custIdx, distance, #order))

    -- Schedule auto-cancel on timeout
    SetTimeout(Config.Job.customerOrderTimeoutS * 1000, function()
        if activeJobs[src] and activeJobs[src].id == job.id then
            -- Still active = timed out
            removeOrderItems(src, job.items)
            activeJobs[src] = nil
            cooldownsAt[src] = GetGameTimer() + (Config.Job.cooldownAfterCancelS * 1000)
            TriggerClientEvent('distortionz_fooddelivery:client:cancelJob', src, 'Order timed out.')
        end
    end)

    return {
        ok              = true,
        jobId           = job.id,
        restaurantLabel = restaurant.label,
        customerCoords  = job.customerCoords,
        customerIndex   = custIdx,
        items           = order,
        distance        = distance,
        expectedSec     = expectedSec,
        walkOnly        = distance < (Config.Job.walkVsVehicleThresholdM or 500.0),
    }
end)

-- ─── lib.callback: deliver order ───────────────────────────────────
lib.callback.register('distortionz_fooddelivery:cb:deliverJob', function(src, payload)
    local job = activeJobs[src]
    if not job then return { ok = false, reason = 'No active delivery.' } end

    -- Validate proximity
    local pPed = GetPlayerPed(src)
    if not pPed or pPed == 0 then return { ok = false, reason = 'Bad ped.' } end
    local pCoords = GetEntityCoords(pPed)
    local cx, cy, cz = job.customerCoords.x, job.customerCoords.y, job.customerCoords.z
    local dx, dy, dz = pCoords.x - cx, pCoords.y - cy, pCoords.z - cz
    if math.sqrt(dx*dx + dy*dy + dz*dz) > 8.0 then
        return { ok = false, reason = 'Too far from the customer.' }
    end

    -- Validate items
    local hasAll, missing = hasOrderItems(src, job.items)
    if not hasAll then
        return { ok = false, reason = ('Missing item: %s'):format(missing) }
    end

    -- Took vehicle? client supplies this hint
    local tookVehicle = (payload and payload.tookVehicle) and true or false

    -- Time math
    local now = GetGameTimer()
    local elapsedSec = math.floor((now - job.startTimeMs) / 1000)
    local expectedSec = math.floor(job.expectedTimeMs / 1000)

    -- Roll star rating
    local stars = rollCustomerRating(elapsedSec, expectedSec, job.distance, tookVehicle)

    -- Pull current rating tier (BEFORE this delivery is recorded)
    local citizenid = getCitizenId(src)
    if not citizenid then
        return { ok = false, reason = 'Could not resolve player citizenid.' }
    end
    local avg, count = DB.GetRollingAverage(citizenid)
    local tier = resolveTier(avg, count)

    -- Compute payout
    local finalPay, breakdown = computePayout(job.distance, elapsedSec, expectedSec, tier)

    -- Remove items + pay
    removeOrderItems(src, job.items)

    local player = getPlayer(src)
    if player and player.Functions and player.Functions.AddMoney then
        player.Functions.AddMoney(Config.Payment.payAccount or 'cash', finalPay, '[Food Delivery] Tip + base')
    elseif player and player.PlayerData then
        -- qbx_core export fallback
        local ok = pcall(function()
            exports.qbx_core:AddMoney(src, Config.Payment.payAccount or 'cash', finalPay, 'food-delivery-tip')
        end)
        if not ok then
            Debug('AddMoney fallback failed for src', src)
        end
    end

    -- Persist rating
    DB.AppendRating(citizenid, stars, Config.Rating.historyWindowSize or 50)

    -- Pick a quote
    local starBracket = math.floor(stars + 0.5)
    if starBracket < 1 then starBracket = 1 end
    if starBracket > 5 then starBracket = 5 end
    local pool = Config.CustomerQuotes[starBracket] or Config.CustomerQuotes[3]
    local quote = pool[math.random(#pool)]

    -- Compute new tier post-rating
    local newAvg, newCount = DB.GetRollingAverage(citizenid)
    local newTier = resolveTier(newAvg, newCount)

    activeJobs[src] = nil
    cooldownsAt[src] = now + (Config.Job.cooldownAfterDeliveryS * 1000)

    Debug(('deliverJob src=%d stars=%.1f pay=$%d elapsed=%ds expected=%ds dist=%.1fm'):format(
        src, stars, finalPay, elapsedSec, expectedSec, job.distance))

    return {
        ok           = true,
        stars        = stars,
        quote        = quote,
        payout       = finalPay,
        breakdown    = breakdown,
        tierLabel    = tier and tier.label or 'Standard',
        newAverage   = newAvg,
        newDeliveries = newCount,
        newTierLabel = newTier and newTier.label or 'Standard',
        elapsedSec   = elapsedSec,
        expectedSec  = expectedSec,
    }
end)

-- ─── Cancel job (player-initiated) ─────────────────────────────────
RegisterNetEvent('distortionz_fooddelivery:server:cancelJob', function()
    local src = source
    local job = activeJobs[src]
    if not job then return end

    removeOrderItems(src, job.items)
    activeJobs[src] = nil
    cooldownsAt[src] = GetGameTimer() + (Config.Job.cooldownAfterCancelS * 1000)
    notify(src, 'Order cancelled. Items removed from your inventory.', 'error', 5000)
    TriggerClientEvent('distortionz_fooddelivery:client:cancelJob', src, 'Cancelled by player.')
end)

-- ─── Cleanup on disconnect ─────────────────────────────────────────
AddEventHandler('playerDropped', function()
    local src = source
    local job = activeJobs[src]
    if job then
        -- Strip the order items so the player can't farm food by
        -- accepting → DCing → reconnecting with the items still on them.
        local ok = pcall(removeOrderItems, src, job.items)
        if not ok then Debug('playerDropped: removeOrderItems failed for src', src) end
        activeJobs[src] = nil
    end
    cooldownsAt[src] = nil
end)

-- ─── Startup banner ────────────────────────────────────────────────
CreateThread(function()
    Wait(500)
    print(('^5[distortionz_fooddelivery:server]^7 v%s loaded — restaurants=%d customer_spots=%d debug=%s')
        :format(Config.Script.version or '?', #Config.Restaurants, #Config.CustomerSpawns, tostring(Config.Debug)))
end)
