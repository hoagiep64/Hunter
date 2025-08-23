-- Hunter Addon - Full Version with Prey Tracking and Overlay

_addon.name = 'Hunter'
_addon.author = 'Paulu'
_addon.version = '2.0.0'
_addon.commands = {'hunter','hunt'}

local logger = require('logger')
local chat = require('chat')
local config = require('config')
local texts = require('texts')
require('pack')

--============================--
-- Config and Defaults
--============================--
local defaults = {
    display = true,
    pos_x = 200,
    pos_y = 400,
    table_display = true,
    table_pos_x = 300,
    table_pos_y = 100
}

local settings = config.load(defaults)

--============================--
-- Prey and Tracker Variables
--============================--
local prey = {}
local prey_count = 4
local current_index = 1
local TheHuntIsOn = false
local tracked_ids = {}
local hunt_range = 8
local point_a = nil
local point_b = nil
local prowl_active = false
local current_target_point = nil
local camp_point = nil
local camp_range = 25
local is_camped = false
local tracking_active = false
local last_update = 0

--============================--
-- Return-to-Position Variables
--============================--
local ret_active = false
local start_position = {x=nil, y=nil}
local returning = false

--============================--
-- Tunables (return controller)
--============================--
local ARRIVAL_RADIUS  = 1.5      -- stop when within this distance
local START_RADIUS    = 3.0      -- only (re)start moving if beyond this distance
local STOP_COOLDOWN   = 0.8      -- seconds we refuse to move after stopping
local POLL_INTERVAL   = 0.05

--============================--
-- Internal movement state
--============================--
local movement_token = 0
local last_stop_ts   = 0
local moving_forward = false
local reposition_running = false

--============================--
-- Color Codes
--============================--
local COLOR_GREEN   = "\\cs(0,255,0)"
local COLOR_RED     = "\\cs(255,0,0)"
local COLOR_PURPLE  = "\\cs(180,80,250)"
local COLOR_WHITE   = "\\cs(255,255,255)"
local COLOR_YELLOW 	= "\\cs(255,255,0)"
local COLOR_BLUE 	= "\\cs(68,203,237)"
local COLOR_RESET   = ""

--============================--
-- Text Displays
--============================--
local tracker_display = texts.new({
    pos = {x = 100, y = 400},
    text = {font = 'Consolas', size = 13, alpha = 255},
    flags = {draggable = true},
    bg = {alpha = 150, red = 0, green = 0, blue = 0},
    padding = 4,
})

local prey_display = texts.new({
    pos = {x = 200, y = 200},
    text = {font = 'Consolas', size = 13, alpha = 255},
    flags = {draggable = true},
    bg = {alpha = 180, red = 0, green = 0, blue = 0},
    padding = 4,
})

local map_open = false

windower.register_event('incoming chunk', function(id, data)
    if id == 0x05B then
        local menu_id = data:unpack('H', 0x05)

        if menu_id >= 0x0130 and menu_id <= 0x013F then
            if not map_open then
                map_open = true
                for _, box in pairs(Overlays) do
                    if box:visible() then
                        box:hide()
                        box._botter_hidden = true -- mark that we hid it
                    end
                end
            end
        else
            if map_open then
                map_open = false
                for _, box in pairs(Overlays) do
                    if box._botter_hidden then
                        box:show()
                        box._botter_hidden = false
                    end
                end
            end
        end
    end
end)

--============================--
-- Color Logic
--============================--
local function get_mob_color(mob, player_id)
    if not mob.valid_target or mob.hpp == 0 then
        return COLOR_RED
    elseif mob.claim_id and mob.claim_id ~= 0 then
        if mob.claim_id == player_id then
            return COLOR_WHITE
        else
            return COLOR_PURPLE
        end
    else
        return COLOR_GREEN
    end
end

--============================--
-- Core Functions
--============================--
local function populate_prey_from_target()
    local mob = windower.ffxi.get_mob_by_target('t')
    if not mob then
        windower.add_to_chat(123, 'Hunter: No target selected.')
        return
    end

    prey = {}
    for i = 1, prey_count do
        prey[i] = mob.id + (i - 1)
    end

    current_index = 1
    windower.add_to_chat(200, 'Hunter: Mark list populated from ID ' .. mob.id)
end

local packets = require('packets')

local function TargetEngage(target_id)
    local player = windower.ffxi.get_player()
    local mob = windower.ffxi.get_mob_by_id(target_id)
    if not player or not mob then return end

    if player.status == 0 and (not player.target or player.target.status == 'Idle') then
        local engage_packet = packets.new('outgoing', 0x01A, {
            ['Target'] = mob.id,
            ['Target Index'] = mob.index,
            ['Category'] = 0x02 -- Engage
        })
        packets.inject(engage_packet)
    elseif player.status == 1 and (not player.target or not player.lock_on) then
        windower.send_command('input /attack')
    end
end

local function HunterEngage()
    local player = windower.ffxi.get_player()
    if not player or player.status ~= 0 then return end

    for i = 1, prey_count do
        local index = ((current_index + i - 2) % prey_count) + 1
        local mob_id = prey[index]
        local mob = mob_id and windower.ffxi.get_mob_by_id(mob_id)

        if mob and mob.valid_target and mob.hpp > 0 then
            if not player.target_index or player.target_index ~= mob.index then
                TargetEngage(mob.id)
                current_index = index % prey_count + 1
                return
            end
        end
    end
end

local function maintain_position_and_facing()
    if reposition_running or returning then return end
	
	local player = windower.ffxi.get_mob_by_id(windower.ffxi.get_player().id)
    local target = windower.ffxi.get_mob_by_target('t')
    if not player or not target then return end

    local dx = target.x - player.x
    local dy = target.y - player.y
    local distance = math.sqrt(dx^2 + dy^2)

    -- prevent getting hung on a player target.
    if target.spawn_type ~= 16 then
        windower.send_command('input /lockon;wait. 2;setkey escape down;wait .2;setkey escape up')
        return
    end

    -- Stay close to mob (within ~3.4 yalms)
    if distance > 3.4 then
        windower.ffxi.run(true) -- engaged-run remains camera-forward; fine for combat micro
    else
        windower.ffxi.run(false)

        -- Correct facing
        local player_body = windower.ffxi.get_mob_by_id(player.id)
        local angle = (math.atan2((target.y - player_body.y), (target.x - player_body.x))*180/math.pi)*-1
        local rads = angle:radian()
        windower.ffxi.turn(rads)
    end
end

local function check_for_nearby_threats()
    local player = windower.ffxi.get_mob_by_id(windower.ffxi.get_player().id)
    if not player then return false end

    local nearest = nil
    local shortest = hunt_range

    for _, mob in pairs(windower.ffxi.get_mob_array()) do
        if mob and mob.id ~= player.id and mob.is_npc and mob.valid_target and mob.hpp > 0 and mob.claim_id == 0 and mob.spawn_type == 16 then
            local dx = mob.x - player.x
            local dy = mob.y - player.y
            local dist = math.sqrt(dx^2 + dy^2)
            if dist <= shortest then
                nearest = mob
                shortest = dist
            end
        end
    end

    if nearest then
        if is_camped and camp_point and nearest.x and nearest.y then
            local dx = nearest.x - camp_point.x
            local dy = nearest.y - camp_point.y
            local camp_dist = math.sqrt(dx^2 + dy^2)
            if camp_dist > camp_range then
                return false
            end
        end
        TargetEngage(nearest.id)
        return true
    end

    return false
end

--============================--
-- Absolute-heading run helpers (straight-line return)
--============================--
local function stop_run()
    windower.ffxi.run(false)
    moving_forward = false
end

local function run_towards(tx, ty)
    local me = windower.ffxi.get_mob_by_id(windower.ffxi.get_player().id)
    if not me then return end
    local dy = ty - me.y
    local dx = tx - me.x
    -- Match your working addon: heading in radians is *negative* atan2(dy, dx)
    local rads = -math.atan2(dy, dx)
    windower.ffxi.run(rads)
    moving_forward = true
end

--============================--
-- Straight-line return controller
--============================--
function RepositionTo(tx, ty)
    if reposition_running then return end
    reposition_running = true

	stop_run()
    movement_token = movement_token + 1
    local token = movement_token

    while token == movement_token do
        local player = windower.ffxi.get_player()
        if not player then break end
        local me = windower.ffxi.get_mob_by_id(player.id)
        if not me then break end

        local dx, dy = tx - me.x, ty - me.y
        local dist = math.sqrt(dx*dx + dy*dy)
        local now  = os.clock()

        -- Arrival: stop and honor cooldown to prevent immediate re-accel
        if dist <= ARRIVAL_RADIUS then
            if moving_forward then stop_run() end
            if now - last_stop_ts < STOP_COOLDOWN then
                coroutine.sleep(POLL_INTERVAL)
            else
                last_stop_ts = now
                break
            end

        -- Brake zone: inside hysteresis band → ensure full stop
        elseif dist <= START_RADIUS then
            if moving_forward then
                stop_run()
                last_stop_ts = now
            end
            coroutine.sleep(POLL_INTERVAL)

        -- Outside start radius: run straight toward the point (absolute heading)
        else
            if (now - last_stop_ts) >= STOP_COOLDOWN then
                run_towards(tx, ty)
            else
                if moving_forward then stop_run() end
            end
            coroutine.sleep(POLL_INTERVAL)
        end
    end

    -- Safety: guarantee stop if another routine stole the token
    if moving_forward and token ~= movement_token then
        stop_run()
    end

    reposition_running = false -- release single-owner lock
end

--============================--
-- Hunt loop
--============================--
local function hunt_loop()
    coroutine.sleep(1)
    while TheHuntIsOn do
        local player = windower.ffxi.get_player()
		
		if player and player.status == 1 and reposition_running then
			movement_token = movement_token + 1   -- tell RepositionTo to wind down
		end
		
        if player and player.status == 1 then
            maintain_position_and_facing()
        elseif not check_for_nearby_threats() then
            HunterEngage()
        end

        -- Return-to-position logic (non-blocking, hysteresis-controlled)
        if ret_active and player and player.status == 0 and start_position.x and start_position.y then
            local me = windower.ffxi.get_mob_by_id(player.id)
            if me then
                local dx = start_position.x - me.x
                local dy = start_position.y - me.y
                local distance = math.sqrt(dx*dx + dy*dy)

                -- Start a reposition job if we're outside the start radius and not already running
                if distance > START_RADIUS and not reposition_running then
                    returning = true
                    coroutine.schedule(function()
                        RepositionTo(start_position.x, start_position.y)
                        returning = false
                    end, 0)
                end

                -- If we're back inside the arrival radius, cancel any active job
                if distance <= ARRIVAL_RADIUS then
                    movement_token = movement_token + 1 -- wind down any active job
                end
            end
        end

        coroutine.sleep(0.3)
    end
end

local function prowl_loop()
    -- reserved for future A↔B prowl behavior
end

--============================--
-- Display Updaters
--============================--
windower.register_event('prerender', function()
    local now = os.clock()
    if now - last_update < 0.5 then
        return -- skip until 0.5s passes
    end
    last_update = now

    -- Tracked mobs overlay (if tracking is active)
    if tracking_active then
        local player = windower.ffxi.get_player()
        if player then
            local player_body = windower.ffxi.get_mob_by_id(player.id)
            local mobs_in_range = {}
            local target = windower.ffxi.get_mob_by_target('t')

            for _, mob in pairs(windower.ffxi.get_mob_array()) do
                if mob and mob.is_npc and mob.valid_target and mob.hpp > 0 and mob.spawn_type == 16 then
                    local dx = mob.x - player_body.x
                    local dy = mob.y - player_body.y
                    local dist = math.sqrt(dx^2 + dy^2)
                    if dist <= camp_range then
                        table.insert(mobs_in_range, mob)
                    end
                end
            end

            table.sort(mobs_in_range, function(a, b) return a.id < b.id end)

            local lines = {}
            table.insert(lines, COLOR_WHITE .. "HUNTER- Now tracking" .. COLOR_RESET)
            for _, mob in ipairs(mobs_in_range) do
                local color = get_mob_color(mob, player.id)
                local hex_index = string.format("%03X", mob.index)

                if target and target.id == mob.id then
                    table.insert(lines, string.format("%s%s%s: %d (%s) %s%s<<<%s",
                        COLOR_RESET,
                        color, hex_index, mob.id, mob.name, COLOR_RESET,
                        COLOR_YELLOW, COLOR_RESET
                    ))
                else
                    table.insert(lines, string.format("%s%s: %d (%s)%s   ",
                        color, hex_index, mob.id, mob.name, COLOR_RESET
                    ))
                end
            end

            if #lines > 0 then
                tracker_display:text(table.concat(lines, '\n'))
                tracker_display:show()
            else
                tracker_display:hide()
            end
        end
    else
        tracker_display:hide()
    end

    local player = windower.ffxi.get_player()
    if not player then return end

    local valid_mobs = {}
    local display_lines = {}
    if TheHuntIsOn then
        table.insert(display_lines, COLOR_GREEN .. 'HUNTER On the hunt!' .. COLOR_RESET)
    else
        table.insert(display_lines, COLOR_WHITE .. 'HUNTER Standing By' .. COLOR_RESET)
    end
    table.insert(display_lines, COLOR_WHITE .. 'Hunt (' .. hunt_range .. ') Yalms' .. COLOR_RESET)

    if is_camped then
        table.insert(display_lines,
            string.format("%sCamp (%s) Yalms%s [%sCamping%s]",
                COLOR_WHITE,
                tostring(camp_range or "?"),
                COLOR_RESET,
                COLOR_PURPLE,
                COLOR_WHITE
            )
        )
    else
        table.insert(display_lines,
            string.format("%sCamp (%s) Yalms%s [%sRoaming%s]",
                COLOR_WHITE,
                tostring(camp_range or "?"),
                COLOR_RESET,
                COLOR_BLUE,
                COLOR_WHITE
            )
        )
    end

    -- Return-to-position status
    if ret_active then
        table.insert(display_lines,
            string.format("%sReturn-to-Position:%s [%sON%s]",
                COLOR_WHITE, COLOR_RESET, COLOR_GREEN, COLOR_WHITE
            )
        )
    else
        table.insert(display_lines,
            string.format("%sReturn-to-Position:%s [%sOFF%s]",
                COLOR_WHITE, COLOR_RESET, COLOR_RED, COLOR_WHITE
            )
        )
    end

    for i = 1, #prey do
        local mob = windower.ffxi.get_mob_by_id(prey[i])
        if mob then table.insert(valid_mobs, mob) end
    end

    table.sort(valid_mobs, function(a, b) return a.id < b.id end)

    for _, mob in ipairs(valid_mobs) do
        local color = get_mob_color(mob, player.id)
        local hex_index = string.format("%03X", mob.index)
        table.insert(display_lines, string.format("%s%s: %d (%s)%s", color, mob.name, mob.id, hex_index, COLOR_RESET))
    end

    prey_display:text(table.concat(display_lines, '\n'))
    prey_display:show()
end)

--============================--
-- Helper Functions
--============================--
local function set_position()
    local player = windower.ffxi.get_player()
    if not player then return end
    local player_body = windower.ffxi.get_mob_by_id(player.id)
    if player_body then
        start_position.x = player_body.x
        start_position.y = player_body.y
        windower.add_to_chat(200, string.format("[Hunter] Return position set to (%.2f, %.2f).", start_position.x, start_position.y))
    end
end

--============================--
-- Other Register Events
--============================--
windower.register_event('zone change', function()
    -- Break camp
    camp_point = nil
    is_camped = false

    -- Disable hunt
    TheHuntIsOn = false
end)

--============================--
-- Command Handler
--============================--
windower.register_event('addon command', function(cmd, ...)
    local args = {...}
    cmd = cmd and cmd:lower() or nil

    if not cmd or cmd == '' then
        TheHuntIsOn = not TheHuntIsOn
        windower.add_to_chat(200, '[Hunter] The hunt ' .. (TheHuntIsOn and 'is on!.' or 'is called off.'))

        if TheHuntIsOn then
            coroutine.schedule(hunt_loop, 0)
        end
        return
    end

    if tonumber(cmd) and tonumber(cmd) >= 1 and tonumber(cmd) <= 20 then
        prey_count = tonumber(cmd)
        prey = {}
        for i = 1, prey_count do prey[i] = nil end
        windower.add_to_chat(200, '[Hunter] Prey list size set to ' .. prey_count)
        populate_prey_from_target()
        tracking_active = false

    elseif cmd == 'mark' or cmd == 'm' then
        if prey_count == 0 then
            windower.add_to_chat(123, '[Hunter] Set prey list size first.')
        else
            populate_prey_from_target()
            tracking_active = false
        end

    elseif cmd == 'hunt' then
        HunterEngage()

    elseif (cmd == 'range' or cmd == 'r' or cmd == 'rng') and tonumber(args[1]) then
        local value = tonumber(args[1])
        if value >= 1 and value <= 30 then
            hunt_range = value
            windower.add_to_chat(200, '[Hunter] Defensive detection range set to ' .. hunt_range .. ' yalms.')
        else
            windower.add_to_chat(123, '[Hunter] Please enter a number between 1 and 25.')
        end

    elseif cmd == 'camp' or cmd == 'c' then
        local p = windower.ffxi.get_mob_by_id(windower.ffxi.get_player().id)
        if p then
            camp_point = {x = p.x, y = p.y}
            is_camped = true
            windower.add_to_chat(200, '[Hunter] Camp point set.')
        end

    elseif cmd == 'ret' or cmd == 'return' then
        ret_active = not ret_active
        windower.add_to_chat(200, '[Hunter] Return-to-position is now ' .. (ret_active and 'ENABLED' or 'DISABLED') .. '.')

    elseif cmd == 'setpos' or cmd == 'setposition' then
        set_position()

    elseif cmd == 'break' then
        camp_point = nil
        is_camped = false
        windower.add_to_chat(200, '[Hunter] Breaking Camp. Camp mode deactivated.')

    elseif (cmd == 'camprange' or cmd == 'cr') and tonumber(args[1]) then
        local value = tonumber(args[1])
        if value >= 1 and value <= 40 then
            camp_range = value
            windower.add_to_chat(200, '[Hunter] Camp range set to ' .. camp_range .. ' yalms.')
        else
            windower.add_to_chat(123, '[Hunter] Enter a number between 1 and 40.')
        end

    elseif cmd == 'track' or cmd == 't' then
        tracking_active = not tracking_active
        windower.add_to_chat(200, '[Hunter] Tracking mode ' .. (tracking_active and 'ENABLED' or 'DISABLED') .. '. Use "//hunt t" to toggle.')
        windower.add_to_chat(200, '[Hunter] Mark a target with the "m" or "#".')

    elseif cmd == 'display' or cmd =='d' then
        settings.table_display = not settings.table_display
        config.save(settings)
        windower.add_to_chat(200, '[Hunter] Tracker display ' .. (settings.display and 'enabled.' or 'disabled.'))

    elseif cmd == '?' then
        windower.add_to_chat(123, 'Hunter Commands:')
        windower.add_to_chat(123, '//hunter or //hunt  - Begin/Stop hunt loop')
        windower.add_to_chat(123, '//hunter <1-20>     - Marks current target & Set prey list size')
        windower.add_to_chat(123, '//hunter range <1-30> - (r #) Set auto-engage range')
        windower.add_to_chat(123, '//hunter track      - (t) Tracks all targets within your camp range')
        windower.add_to_chat(123, '//hunter display    - (d) Toggle small overlay')
        windower.add_to_chat(123, '//hunter camp       - (c) Set & enable camp radius by current X/Y position')
        windower.add_to_chat(123, '//hunter camprange <1-30> - (cr #) Set camping range')
    end
end)
