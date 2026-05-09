-- ╔══════════════════════════════════════════════════════════════════╗
-- ║ Distortionz Food Delivery — client                               ║
-- ║                                                                  ║
-- ║ Spawns restaurant peds with ox_target, manages active-job state, ║
-- ║ spawns/despawns customer peds when a job is active, handles the  ║
-- ║ NUI active-order card + rating popup.                            ║
-- ╚══════════════════════════════════════════════════════════════════╝

local restaurantPeds = {}      -- restaurantId -> ped entity
local restaurantBlips = {}     -- restaurantId -> blip
local customerPed    = nil
local customerBlip   = nil
local customerLocation = nil   -- vec4 of current customer
local activeJob      = nil     -- mirrored from server callback response
local jobStartTimeMs = 0
local jobExpectedMs  = 0
local rememberedTookVehicle = false   -- tracked: did the player drive at any point?

-- ─── Helpers ────────────────────────────────────────────────────────
local function Debug(...)
    if Config.Debug then
        print(('[fooddelivery:client] %s'):format(table.concat({...}, ' ')))
    end
end

local function Notify(message, notifyType, duration, title)
    notifyType = notifyType or 'primary'
    duration   = duration or 5000
    title      = title or Config.Notify.title

    if notifyType == 'inform' then notifyType = 'info' end

    if GetResourceState(Config.Notify.resource) == 'started' then
        exports[Config.Notify.resource]:Notify(message, notifyType, duration, title)
        return
    end

    lib.notify({
        title       = title,
        description = message,
        type        = notifyType,
        duration    = duration,
    })
end

RegisterNetEvent('distortionz_fooddelivery:client:notify', function(message, notifyType, duration, title)
    Notify(message, notifyType, duration, title)
end)

local function loadModel(model)
    local hash = type(model) == 'number' and model or joaat(model)
    if not IsModelInCdimage(hash) or not IsModelValid(hash) then return nil end
    RequestModel(hash)
    local timeout = GetGameTimer() + 10000
    while not HasModelLoaded(hash) do
        Wait(20)
        if GetGameTimer() > timeout then return nil end
    end
    return hash
end

-- ─── Restaurant ped spawn + ox_target ───────────────────────────────
local function spawnRestaurantPed(restaurant)
    local hash = loadModel(restaurant.model)
    if not hash then
        Debug('failed to load model for', restaurant.id, restaurant.model)
        return
    end
    local c = restaurant.coords
    local ped = CreatePed(0, hash, c.x, c.y, c.z, c.w, false, true)
    if not ped or ped == 0 then
        Debug('CreatePed failed for', restaurant.id)
        return
    end

    SetEntityInvincible(ped, true)
    SetBlockingOfNonTemporaryEvents(ped, true)
    FreezeEntityPosition(ped, true)
    SetPedCanRagdoll(ped, false)
    SetPedDiesWhenInjured(ped, false)
    SetModelAsNoLongerNeeded(hash)

    -- Distortionz protected ped convention
    Entity(ped).state:set('distortionz_protected_ped', true, true)
    Entity(ped).state:set('distortionz_contact_ped',   true, true)
    Entity(ped).state:set('distortionz_food_restaurant_ped', true, true)

    exports.ox_target:addLocalEntity(ped, {
        {
            name     = ('distortionz_food_start_%s'):format(restaurant.id),
            label    = 'Start Delivery Job',
            icon     = 'fa-solid fa-burger',
            distance = Config.Job.restaurantPedDistance,
            canInteract = function() return activeJob == nil end,
            onSelect = function() TriggerEvent('distortionz_fooddelivery:client:requestJob', restaurant.id) end,
        },
        {
            name     = ('distortionz_food_rating_%s'):format(restaurant.id),
            label    = 'Check Rating',
            icon     = 'fa-solid fa-star',
            distance = Config.Job.restaurantPedDistance,
            onSelect = function() TriggerEvent('distortionz_fooddelivery:client:checkRating') end,
        },
    })

    restaurantPeds[restaurant.id] = ped

    -- Map blip
    if Config.Blips.showRestaurants and restaurant.blip then
        local b = AddBlipForCoord(c.x, c.y, c.z)
        SetBlipSprite(b, restaurant.blip.sprite or 106)
        SetBlipColour(b, restaurant.blip.color or 0)
        SetBlipScale(b, 0.7)
        SetBlipAsShortRange(b, true)
        BeginTextCommandSetBlipName('STRING')
        AddTextComponentSubstringPlayerName(restaurant.blip.label or restaurant.label or 'Restaurant')
        EndTextCommandSetBlipName(b)
        restaurantBlips[restaurant.id] = b
    end
end

local function despawnAllRestaurantPeds()
    for id, ped in pairs(restaurantPeds) do
        if DoesEntityExist(ped) then
            exports.ox_target:removeLocalEntity(ped)
            DeleteEntity(ped)
        end
        restaurantPeds[id] = nil
    end
    for id, blip in pairs(restaurantBlips) do
        if DoesBlipExist(blip) then RemoveBlip(blip) end
        restaurantBlips[id] = nil
    end
end

-- ─── Customer ped spawn (only when player is near) ─────────────────
local function despawnCustomer()
    if customerPed and DoesEntityExist(customerPed) then
        exports.ox_target:removeLocalEntity(customerPed)
        DeleteEntity(customerPed)
    end
    customerPed = nil
    if customerBlip and DoesBlipExist(customerBlip) then
        RemoveBlip(customerBlip)
    end
    customerBlip = nil
end

local function spawnCustomerPed(coords)
    if customerPed and DoesEntityExist(customerPed) then return end

    local pool = Config.CustomerPedModels
    local model = pool[math.random(#pool)]
    local hash = loadModel(model)
    if not hash then
        Debug('customer model failed to load', model)
        return
    end

    local ped = CreatePed(0, hash, coords.x, coords.y, coords.z, coords.w or 0.0, false, true)
    if not ped or ped == 0 then return end

    SetEntityInvincible(ped, true)
    SetBlockingOfNonTemporaryEvents(ped, true)
    FreezeEntityPosition(ped, true)
    SetPedCanRagdoll(ped, false)
    SetPedDiesWhenInjured(ped, false)
    SetModelAsNoLongerNeeded(hash)

    -- Distortionz protected ped convention
    Entity(ped).state:set('distortionz_protected_ped', true, true)
    Entity(ped).state:set('distortionz_food_customer_ped', true, true)

    -- Idle scenario for life
    TaskStartScenarioInPlace(ped, 'WORLD_HUMAN_STAND_MOBILE', 0, true)

    exports.ox_target:addLocalEntity(ped, {
        {
            name     = 'distortionz_food_handover',
            label    = 'Hand Over Order',
            icon     = 'fa-solid fa-bag-shopping',
            distance = Config.Job.customerInteractDistance,
            canInteract = function() return activeJob ~= nil end,
            onSelect = function() TriggerEvent('distortionz_fooddelivery:client:handover') end,
        },
    })

    customerPed = ped
end

-- ─── Manage customer ped lifecycle while a job is active ────────────
CreateThread(function()
    while true do
        if activeJob and customerLocation then
            local pCoords = GetEntityCoords(PlayerPedId())
            local dx = pCoords.x - customerLocation.x
            local dy = pCoords.y - customerLocation.y
            local dz = pCoords.z - customerLocation.z
            local dist = math.sqrt(dx*dx + dy*dy + dz*dz)

            if dist <= Config.Job.customerSpawnDistance then
                if not customerPed or not DoesEntityExist(customerPed) then
                    spawnCustomerPed(customerLocation)
                end
            else
                if customerPed then despawnCustomer() end
            end
        end
        Wait(2000)
    end
end)

-- ─── Track if player ever entered a vehicle during this job ─────────
CreateThread(function()
    while true do
        Wait(1000)
        if activeJob then
            local ped = PlayerPedId()
            if IsPedInAnyVehicle(ped, false) then
                rememberedTookVehicle = true
            end
        end
    end
end)

-- ─── Live HUD tick ──────────────────────────────────────────────────
CreateThread(function()
    while true do
        Wait(1000)
        if activeJob then
            local pCoords = GetEntityCoords(PlayerPedId())
            local cx, cy, cz = customerLocation.x, customerLocation.y, customerLocation.z
            local dist = math.floor(#(vector3(pCoords.x, pCoords.y, pCoords.z) - vector3(cx, cy, cz)))
            local elapsedMs = GetGameTimer() - jobStartTimeMs
            local elapsedSec = math.floor(elapsedMs / 1000)
            local expectedSec = math.floor(jobExpectedMs / 1000)
            local timeLeft = math.max(0, expectedSec - elapsedSec)

            SendNUIMessage({
                action     = 'tick',
                distanceM  = dist,
                elapsedSec = elapsedSec,
                expectedSec = expectedSec,
                timeLeftSec = timeLeft,
            })
        end
    end
end)

-- ─── Request a new job from a restaurant ───────────────────────────
RegisterNetEvent('distortionz_fooddelivery:client:requestJob', function(restaurantId)
    if activeJob then
        Notify('You already have an active delivery.', 'error', 4000)
        return
    end
    local result = lib.callback.await('distortionz_fooddelivery:cb:startJob', false, { restaurantId = restaurantId })
    if not result or not result.ok then
        Notify(result and result.reason or 'Could not start job.', 'error', 5000)
        return
    end

    activeJob = result
    customerLocation = result.customerCoords
    jobStartTimeMs   = GetGameTimer()
    jobExpectedMs    = (result.expectedSec or 60) * 1000
    rememberedTookVehicle = false

    -- v1.0.3 — Customer blip with reliable route drawing.
    -- SetBlipRoute alone isn't enough — without SetBlipRouteColour
    -- the route can silently fail to draw (which was the bug sir saw
    -- with the Cluckin' Bell Paleto job — blip placed but no route).
    -- Also dropped the SetBlipFlashTimer which was killing the blip
    -- (and its route) after 8 seconds.
    local cb = AddBlipForCoord(result.customerCoords.x, result.customerCoords.y, result.customerCoords.z)
    SetBlipSprite(cb, Config.Blips.customerBlip.sprite or 280)
    SetBlipColour(cb, Config.Blips.customerBlip.color or 5)
    SetBlipScale(cb, Config.Blips.customerBlip.scale or 0.9)
    SetBlipAsShortRange(cb, false)
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentSubstringPlayerName(Config.Blips.customerBlip.label or 'Customer')
    EndTextCommandSetBlipName(cb)

    -- Optional pulse (no timer — let the player dismiss visually)
    if Config.Blips.customerBlip.flash then
        SetBlipFlashes(cb, true)
    end

    -- Route MUST come last, after all other blip properties are set,
    -- and route colour MUST be set explicitly or the route may not draw.
    SetBlipRoute(cb, true)
    SetBlipRouteColour(cb, Config.Blips.customerBlip.color or 5)

    customerBlip = cb

    -- Build readable item summary for the HUD
    local itemSummary = {}
    for _, it in ipairs(result.items or {}) do
        itemSummary[#itemSummary + 1] = ('%dx %s'):format(it.count, (it.name:gsub('_', ' '):gsub('^%l', string.upper)))
    end

    SendNUIMessage({
        action          = 'show',
        restaurantLabel = result.restaurantLabel,
        items           = itemSummary,
        distance        = math.floor(result.distance or 0),
        walkOnly        = result.walkOnly,
        expectedSec     = result.expectedSec,
    })

    Notify(result.walkOnly
        and ('Order ready — short trip, you can walk. %s items in inventory.'):format(#result.items)
        or  ('Order ready — long trip, take a vehicle. %s items in inventory.'):format(#result.items),
        'success', 6000)
end)

-- ─── Hand-over interaction ─────────────────────────────────────────
RegisterNetEvent('distortionz_fooddelivery:client:handover', function()
    if not activeJob then return end
    local result = lib.callback.await('distortionz_fooddelivery:cb:deliverJob', false, {
        tookVehicle = rememberedTookVehicle,
    })
    if not result or not result.ok then
        Notify(result and result.reason or 'Hand-over failed.', 'error', 5000)
        return
    end

    -- Pop the rating popup
    SendNUIMessage({
        action       = 'rating',
        stars        = result.stars,
        quote        = result.quote,
        payout       = result.payout,
        tierLabel    = result.tierLabel,
        newAverage   = result.newAverage,
        newDeliveries = result.newDeliveries,
        newTierLabel = result.newTierLabel,
        elapsedSec   = result.elapsedSec,
        expectedSec  = result.expectedSec,
    })

    Notify(('Delivered! +$%s · %s★'):format(result.payout, result.stars), 'success', 7000)

    -- Cleanup
    activeJob = nil
    customerLocation = nil
    jobStartTimeMs = 0
    jobExpectedMs  = 0
    rememberedTookVehicle = false
    if customerBlip and DoesBlipExist(customerBlip) then
        RemoveBlip(customerBlip); customerBlip = nil
    end
    -- Despawn customer ped after a short delay so the rating popup feels good
    SetTimeout(Config.Job.customerDespawnAfterDeliveryS * 1000, function()
        despawnCustomer()
    end)
end)

-- ─── Cancel from server (timeout / forced) ─────────────────────────
RegisterNetEvent('distortionz_fooddelivery:client:cancelJob', function(reason)
    if not activeJob then return end
    Notify(('Order cancelled — %s'):format(reason or 'unknown'), 'error', 6000)

    activeJob = nil
    customerLocation = nil
    rememberedTookVehicle = false
    if customerBlip and DoesBlipExist(customerBlip) then
        RemoveBlip(customerBlip); customerBlip = nil
    end
    despawnCustomer()
    SendNUIMessage({ action = 'hide' })
end)

-- ─── Manual cancel (chat command) ──────────────────────────────────
RegisterCommand('cancelfood', function()
    if not activeJob then
        Notify('No active delivery.', 'error', 3000)
        return
    end
    TriggerServerEvent('distortionz_fooddelivery:server:cancelJob')
end, false)

-- ─── Check rating (interaction with restaurant ped) ────────────────
RegisterNetEvent('distortionz_fooddelivery:client:checkRating', function()
    local rating = lib.callback.await('distortionz_fooddelivery:cb:getRating', false)
    if not rating then
        Notify('Could not fetch rating.', 'error', 3000)
        return
    end
    Notify(('You: %.1f★ · %s · %d deliveries'):format(rating.average, rating.tierLabel, rating.deliveries),
        'inform', 7000, 'Driver Rating')
end)

-- ─── Initial spawn ──────────────────────────────────────────────────
CreateThread(function()
    Wait(500)
    print(('^5[distortionz_fooddelivery:client]^7 v%s loaded — spawning %d restaurant peds')
        :format(Config.Script.version or '?', #Config.Restaurants))
    for _, r in ipairs(Config.Restaurants) do
        spawnRestaurantPed(r)
    end
end)

-- ─── Cleanup on resource stop ───────────────────────────────────────
AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    despawnAllRestaurantPeds()
    despawnCustomer()
    if customerBlip and DoesBlipExist(customerBlip) then RemoveBlip(customerBlip) end
    SendNUIMessage({ action = 'hideAll' })
end)
