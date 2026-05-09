Config = Config or {}

-- ─── Script meta ────────────────────────────────────────────────────
Config.Script = {
    name    = 'Distortionz Food Delivery',
    version = '1.0.5',
}

Config.VersionCheck = {
    enabled      = true,
    checkOnStart = true,
    url          = 'https://raw.githubusercontent.com/Distortionzz/Distortionz_FoodDelivery/main/version.json',
}
Config.CurrentVersion = '1.0.5'

-- ─── Notifications ──────────────────────────────────────────────────
Config.Notify = {
    title    = 'Food Delivery',
    resource = 'distortionz_notify',  -- preferred; falls back to ox_lib if not started
}

-- ─── Job rules ──────────────────────────────────────────────────────
Config.Job = {
    -- Restaurant ped settings
    restaurantPedDistance      = 12.0,    -- ox_target detection distance
    -- Customer ped lifecycle
    customerSpawnDistance      = 50.0,    -- player must be within this to spawn the customer ped
    customerDespawnAfterDeliveryS = 60,   -- despawn N seconds after order is handed over
    customerOrderTimeoutS      = 900,     -- 15 minutes — order auto-cancels if not delivered
    customerInteractDistance   = 2.5,     -- ox_target distance to customer ped
    -- Cooldown between jobs (per-player)
    cooldownAfterDeliveryS     = 30,
    cooldownAfterCancelS       = 60,
    -- Distance threshold that decides walk vs vehicle
    walkVsVehicleThresholdM    = 500.0,
    -- Order item count rolls
    minOrderItems              = 2,
    maxOrderItems              = 4,
}

-- ─── Payment / tip math ─────────────────────────────────────────────
-- Final payout = basePay + distanceTip + ratingTipBonus
-- All values clamped to minPayout/maxPayout.
Config.Payment = {
    basePay              = 80,        -- $ flat baseline per delivery
    perMeterTip          = 0.04,      -- $ per meter of straight-line distance to customer
    minPayout            = 100,
    maxPayout            = 600,
    -- Time penalty
    expectedTimeBaseS    = 60,        -- "expected" delivery time floor (very short trip)
    expectedTimePerKmS   = 90,        -- + this many seconds per km of distance
    timeOverrunPenaltyPct = 0.4,      -- 40% reduction if you go over expected time

    -- Account to pay into ('cash' or 'bank')
    payAccount = 'cash',
}

-- ─── Rating tiers (multiplier on top of pay) ────────────────────────
-- Server averages last 50 ratings, looks up the tier here.
-- Lower tiers = lower tip ceiling; better ratings = bigger payouts.
-- Tiers are checked in order; first matching minRating wins.
Config.Rating = {
    -- Start every player at this rating until they have at least minDeliveriesForTier deliveries
    defaultRating              = 5.0,
    minDeliveriesForTier       = 5,
    historyWindowSize          = 50,    -- only keep last N ratings for the average

    -- Customer-facing star roll: base rating modified by performance
    -- (delivered fast in the right mode = high; slow + wrong mode = low)
    -- Random variance applied on top so it's not purely deterministic
    starRollVariance           = 0.4,    -- ±0.4 stars random jitter

    -- Tier brackets (highest to lowest)
    tiers = {
        { label = 'Top Driver',  minRating = 4.8, multiplier = 1.50, color = 'success' },
        { label = 'Trusted',     minRating = 4.5, multiplier = 1.25, color = 'success' },
        { label = 'Standard',    minRating = 4.0, multiplier = 1.00, color = 'primary' },
        { label = 'Probation',   minRating = 0.0, multiplier = 0.75, color = 'warning' },
    },
}

-- ─── Order package items ────────────────────────────────────────────
-- Define one entry per restaurant chain. Each entry is a "menu" — a
-- list of inventory item names that orders from that chain can pull
-- from. When a player accepts a job, the server picks a random
-- subset (between Config.Job.minOrderItems and maxOrderItems) and
-- adds them to the player's inventory.
--
-- Format:
--   [menu_key] = {
--       label = 'Display Name',
--       items = { 'ox_inventory_item_name', 'another_item', ... },
--   }
--
-- Rules:
--   • menu_key must match a `menu = '...'` field in Config.Restaurants
--   • Every item name MUST exist in your ox_inventory data/items.lua
--   • Recommended 3–6 items per menu so orders feel varied
--
-- ─── Copy-paste template ───────────────────────────────────────────
-- Config.MenuItems = {
--     burger_shot = {
--         label = 'Burger Shot',
--         items = { 'food_burger', 'food_fries', 'drink_cola' },
--     },
--     pizza_this = {
--         label = 'Pizza This',
--         items = { 'food_pizzabox', 'food_garlicbread', 'drink_water' },
--     },
-- }
Config.MenuItems = {
    -- Add menus here. See template above.
}

-- ─── Restaurants (where the player picks up the order) ──────────────
-- Each entry defines a pickup ped — walk up, ox_target, "Start
-- Delivery Job".
--
-- Format:
--   {
--       id     = 'unique_id',                        -- internal, must be unique
--       menu   = 'menu_key',                         -- key in Config.MenuItems
--       label  = 'Display Name — Location',          -- shown in HUD
--       coords = vec4(x, y, z, heading),             -- ped spawn (use distortionz_admin's vec4 button)
--       model  = 'mp_m_shopkeep_01',                 -- ped model
--       blip   = { sprite = 106, color = 47, label = 'Burger Shot' },  -- nil = no blip
--   }
--
-- Rules:
--   • id must be unique across the whole list
--   • menu must match a key in Config.MenuItems above
--   • coords are used EXACTLY — no Z offset applied at spawn
--   • model must be a valid GTA ped model
--
-- ─── Copy-paste template ───────────────────────────────────────────
-- Config.Restaurants = {
--     {
--         id     = 'burger_shot_1',
--         menu   = 'burger_shot',
--         label  = 'Burger Shot — Innocence Blvd',
--         coords = vec4(-1183.99, -892.32, 13.32, 124.0),
--         model  = 'mp_m_shopkeep_01',
--         blip   = { sprite = 106, color = 47, label = 'Burger Shot' },
--     },
--     {
--         id     = 'pizza_this_1',
--         menu   = 'pizza_this',
--         label  = 'Pizza This — Little Italy',
--         coords = vec4(289.65, -966.13, 29.42, 175.0),
--         model  = 's_m_m_chemsec_01',
--         blip   = { sprite = 267, color = 1, label = 'Pizza This' },
--     },
-- }
Config.Restaurants = {
    -- Add restaurants here. See template above.
}

-- ─── Customer spawn locations ──────────────────────────────────────
-- A flat list of vec4 doorstep / sidewalk / parking spots. When a
-- player accepts an order the server picks one of these at random
-- and sends them there. Customer ped spawns here, despawns after
-- delivery.
--
-- Format:
--   vec4(x, y, z, heading),     -- optional comment for your reference
--
-- Rules:
--   • Coords are used EXACTLY — NEVER apply Z offset at spawn. If a
--     customer is floating or underground, fix the Z here, not in
--     code. Use distortionz_admin's vec4 button to grab clean coords.
--   • Recommend 30+ entries spread across the map — too few and
--     players see the same spot repeatedly.
--   • Pick OUTDOOR spots only (doorsteps, sidewalks, driveways).
--   • Customer ped model is picked randomly from Config.CustomerPedModels.
--
-- ─── Copy-paste template ───────────────────────────────────────────
-- Config.CustomerSpawns = {
--     -- Optional region grouping comments make editing easier:
--     -- Vinewood / Rockford
--     vec4(-696.58,  53.03,  41.45, 175.0),     -- North Conker Ave apartments
--     vec4(-1135.30, -16.15, 49.24, 220.0),     -- W Vinewood Pl
--
--     -- Sandy Shores
--     vec4(1973.86, 3819.50, 32.43, 211.0),     -- Mountain View trailers
-- }
Config.CustomerSpawns = {
    -- Add customer spawn vec4s here. See template above.
}

-- ─── Customer ped models (rotated randomly per spawn) ──────────────
Config.CustomerPedModels = {
    -- Mix of urban / suburban / rural
    'a_m_y_business_01', 'a_m_y_business_02', 'a_m_y_business_03',
    'a_f_y_business_01', 'a_f_y_business_02', 'a_f_y_business_03', 'a_f_y_business_04',
    'a_m_y_hipster_01',  'a_m_y_hipster_02',  'a_m_y_hipster_03',
    'a_f_y_hipster_01',  'a_f_y_hipster_02',  'a_f_y_hipster_03',  'a_f_y_hipster_04',
    'a_m_m_business_01', 'a_m_m_genfat_01',
    'a_f_m_business_02', 'a_f_m_eastsa_01',   'a_f_m_eastsa_02',
    'a_m_y_genstreet_01','a_m_y_genstreet_02',
    'a_f_y_genhot_01',   'a_f_y_runner_01',
    'a_m_y_skater_01',   'a_m_y_skater_02',
    'a_m_m_indian_01',   'a_m_m_eastsa_01',   'a_m_m_eastsa_02',
    'a_m_o_genstreet_01','a_m_o_soucent_01',
    'a_f_o_indian_01',   'a_f_o_genstreet_01',
}

-- ─── Customer dialogue (random quote on rating) ────────────────────
-- Quote pool by star rating (5★ very happy → 1★ very angry).
-- Picks a random quote from the bracket the customer rolls into.
Config.CustomerQuotes = {
    [5] = {
        "Wow, that was fast! Thanks!",
        "Perfect timing, just what I needed.",
        "You're a lifesaver, thanks!",
        "Best delivery I've had all week.",
        "Five stars without a doubt.",
    },
    [4] = {
        "Thanks, appreciate it.",
        "Good service.",
        "Right on time, thanks.",
        "Solid delivery.",
    },
    [3] = {
        "Took a while but it's here.",
        "Thanks I guess.",
        "Just barely on time.",
        "It's fine.",
    },
    [2] = {
        "Took forever, dude.",
        "I almost canceled.",
        "Not great.",
        "You're slow.",
    },
    [1] = {
        "What took you so long?",
        "I'm starving here!",
        "Worst delivery ever.",
        "Don't expect a tip.",
    },
}

-- ─── Map blips ──────────────────────────────────────────────────────
Config.Blips = {
    showRestaurants     = true,    -- show all restaurant blips on map
    customerBlip = {
        sprite = 280,
        color  = 5,                -- yellow
        scale  = 0.9,
        label  = 'Customer',
        flash  = true,
        flashTimerMs = 8000,
    },
}

-- ─── Debug ──────────────────────────────────────────────────────────
Config.Debug = false
