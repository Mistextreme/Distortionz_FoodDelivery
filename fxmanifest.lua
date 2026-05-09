fx_version 'cerulean'
game 'gta5'
lua54 'yes'

author 'Distortionz'
description 'Distortionz Food Delivery — premium Uber Eats-style food delivery job for Qbox. 8 restaurants, 50+ customer locations, dynamic order generation, rating system with rolling 50-delivery average, distance-tiered pay, and a polished active-order HUD.'
version '1.0.5'
repository 'https://github.com/Distortionzz/Distortionz_FoodDelivery'

ui_page 'html/index.html'

shared_scripts {
    '@ox_lib/init.lua',
    'config.lua',
}

client_scripts {
    'client.lua',
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'server/database.lua',
    'server.lua',
    'version_check.lua',
}

files {
    'html/index.html',
    'html/style.css',
    'html/app.js',
}

dependencies {
    'ox_lib',
    'ox_inventory',
    'oxmysql',
    'qbx_core',
}
