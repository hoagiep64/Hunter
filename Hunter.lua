-- Hunter Addon - Full Version with Prey Tracking and Overlay

_addon.name = 'Hunter'
_addon.author = 'Paulu'
_addon.version = '1.1'
_addon.commands = {'hunter','hunt'}

local logger = require('logger')
local chat = require('chat')
local config = require('config')
local texts = require('texts')

--============================--
-- Config and Defaults
--============================--
local defaults = {
    display = true,
    pos_x = 300,
    pos_y = 250,
    table_display = false,
    table_pos_x = 700,
    table_pos_y = 100
}

local settings = config.load(defaults)

--============================--
-- Prey and Tracker Variables
--============================--
local last_display_update = 0
local prey = {}
local prey_count = 1
local current_index = 1
local TheHuntIsOn = false
local tracked_ids = {}
local hunt_range = 2.5
local camp_range = 20
local current_target_point = nil
local stuck_check = {
    previous_dist = nil,
    stuck_cycles = 0,
    is_strafing = false
}

--============================--
-- Color Codes
--============================--
local COLOR_GREEN   = "\\cs(0,255,0)"
local COLOR_RED     = "\\cs(255,0,0)"
local COLOR_PURPLE  = "\\cs(180,80,250)"
local COLOR_WHITE   = "\\cs(255,255,255)"
local COLOR_RESET   = "\\cr"

--============================--
-- Text Displays
--============================--
local tracker_display = texts.new({
    pos = {x = settings.pos_x, y = settings.pos_y},
    text = {font = 'Consolas', size = 11, alpha = 255},
    flags = {draggable = true},
    bg = {alpha = 150, red = 0, green = 0, blue = 0},
    padding = 4,
})

local prey_display = texts.new({
    pos = {x = settings.table_pos_x, y = settings.table_pos_y},
    text = {font = 'Consolas', size = 11, alpha = 255},
    flags = {draggable = true},
    bg = {alpha = 180, red = 0, green = 0, blue = 0},
    padding = 4,
})

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
    local player_data = windower.ffxi.get_player()
    local player = player_data and windower.ffxi.get_mob_by_id(player_data.id)
    if not player or player.status ~= 0 then return end

        if valid and (not player.target_index or player.target_index ~= mob.index) then
            TargetEngage(mob.id)
            current_index = index % prey_count + 1
            return
        end

end

local function maintain_position_and_facing()
    local player = windower.ffxi.get_mob_by_id(windower.ffxi.get_player().id)
    local target = windower.ffxi.get_mob_by_target('t')
    if not player or not target then return end

    local dx = target.x - player.x
    local dy = target.y - player.y
    local distance = math.sqrt(dx^2 + dy^2)

    -- Stay close to mob (within 3 units)
    if distance > 3 then
        windower.ffxi.run(true)
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
    local shortest = hunt_range  -- 4 yalms range cap

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
                --windower.add_to_chat(123, 'Hunter: Skipped threat (outside camp range).')  -- Debugging
                return false
            end
        end

        TargetEngage(nearest.id)
        windower.add_to_chat(207, 'Hunter: Engaging nearby threat: '..nearest.name)
        return true
    end

    return false
end

local function hunt_loop()
    coroutine.sleep(1)
    while TheHuntIsOn do
        local player_data = windower.ffxi.get_player()
		local player = player_data and windower.ffxi.get_mob_by_id(player_data.id)
        if player and player.status == 1 then

            -- Stuck detection block
            local mob = windower.ffxi.get_mob_by_target('t')
            if mob and mob.x and mob.y then
                local dx = mob.x - player.x
                local dy = mob.y - player.y
                local dist = math.sqrt(dx^2 + dy^2)

                if dist > 3.5 then
                    if stuck_check.previous_dist and math.abs(dist - stuck_check.previous_dist) < 0.1 then
                        stuck_check.stuck_cycles = stuck_check.stuck_cycles + 1
                    else
                        stuck_check.stuck_cycles = 0
                    end
                    stuck_check.previous_dist = dist

                    if stuck_check.stuck_cycles >= 1 and not stuck_check.is_strafing then
                        stuck_check.is_strafing = true
                        windower.send_command('setkey numpad4 down')
                        coroutine.schedule(function()
                            windower.send_command('setkey numpad4 up')
                            stuck_check.is_strafing = false
                            stuck_check.stuck_cycles = 0
                            stuck_check.previous_dist = nil
                        end, 1)
                    end
                else
                    stuck_check.previous_dist = nil
                    stuck_check.stuck_cycles = 0
                end
            end

            maintain_position_and_facing()

        elseif player.status == 4 then
            TheHuntIsOn = true
            windower.send_command('hunt')

        elseif not check_for_nearby_threats() then
            HunterEngage()
        end

        coroutine.sleep(1.5)
    end
end

windower.register_event('zone change', function(new, old)
    TheHuntIsOn = false
end)

--============================--
-- Display Updaters
--============================--
windower.register_event('prerender', function()
    local clock_now = os.clock()
    if clock_now - last_display_update < 1 then return end
    last_display_update = clock_now

    local now = os.time()
    local lines = {}

	local current_target = windower.ffxi.get_mob_by_target('t')
	local current_id = current_target and current_target.id

	for id, entry in pairs(tracked_ids) do
		local numeric_id = tonumber(id)

		if now - entry.timestamp > 60 then
			tracked_ids[id] = nil
		else
			if current_id and numeric_id == current_id then
				-- Highlight only the mob you're targeting
				table.insert(lines, "\\cs(255,255,0)" .. string.format("%s: %d", entry.name, numeric_id) .. COLOR_RESET)
			else
				table.insert(lines, string.format("%s: %d", entry.name, numeric_id))
			end
		end
	end

    if settings.display and #lines > 0 then
        tracker_display:text(table.concat(lines, '\n'))
        tracker_display:show()
    else
        tracker_display:hide()
    end


    -- Prey table overlay
    if not settings.table_display then
        prey_display:hide()
        return
    end

    local player = windower.ffxi.get_player()
    if not player then return end

    --local display_lines = {COLOR_WHITE .. 'Marked Prey' .. COLOR_RESET}
    local valid_mobs = {}
	local header
	local display_lines = {}
    if TheHuntIsOn then
        table.insert(display_lines, COLOR_GREEN .. '-Hunter- On the hunt!' .. COLOR_RESET)
    else
        table.insert(display_lines, COLOR_WHITE .. '-Hunter- Standing By' .. COLOR_RESET)
    end
	table.insert(display_lines, COLOR_WHITE .. 'Hunting: ' .. hunt_range .. ' Yalms' .. COLOR_RESET)

	if is_camped then
		table.insert(display_lines,
			string.format("%sCamping: %s yalms%s [%sCamping%s]",
				COLOR_WHITE,
				tostring(camp_range or "?"),
				COLOR_RESET,
				COLOR_GREEN,
				COLOR_RESET
			)
		)
	else
		table.insert(display_lines,
			string.format("%sCamping: %s yalms%s [%sNo Camp%s]",
				COLOR_WHITE,
				tostring(camp_range or "?"),
				COLOR_RESET,
				COLOR_RED,
				COLOR_RESET
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
        table.insert(display_lines, string.format("%s%s: %d%s", color, mob.name, mob.id, COLOR_RESET))
    end

        prey_display:text(table.concat(display_lines, '\n'))
        prey_display:show()

end)

--============================--
-- Command Handler
--============================--
windower.register_event('addon command', function(cmd, ...)
    local args = {...}
    cmd = cmd and cmd:lower() or nil

    if not cmd or cmd == '' then
		TheHuntIsOn = not TheHuntIsOn
		windower.add_to_chat(200, 'Hunter: The hunt ' .. (TheHuntIsOn and 'is on!' or 'is called off.'))

		if TheHuntIsOn then
			coroutine.schedule(hunt_loop, 0)
		end
		return
	end

    if tonumber(cmd) and tonumber(cmd) >= 1 and tonumber(cmd) <= 20 then
        prey_count = tonumber(cmd)
		if windower.ffxi.get_mob_by_target('t') then
			populate_prey_from_target()
		end
        prey = {}

    elseif cmd == 'hunt' then
        HunterEngage()
		
	elseif (cmd == 'range' or cmd == 'r' or cmd == 'rng' or cmd == 'hr') and tonumber(args[1]) then
		local value = tonumber(args[1])
		if value >= 1 and value <= 30 then
			hunt_range = value
			windower.add_to_chat(200, 'Hunter: Defensive detection range set to ' .. hunt_range .. ' yalms.')
		else
			windower.add_to_chat(123, 'Hunter: Please enter a number between 1 and 30.')
		end
		
    elseif cmd == 'track' or cmd == 't' then
        local mob = windower.ffxi.get_mob_by_target('t')
        if mob then
            tracked_ids[tostring(mob.id)] = {name = mob.name, timestamp = os.time()}
            windower.add_to_chat(200, string.format("Hunter: Tracking %s (%d) for 1 minute.", mob.name, mob.id))
        else
            windower.add_to_chat(123, 'Hunter: No target selected.')
        end

    
    elseif cmd == 'camp' or cmd == 'c' then
        local p = windower.ffxi.get_mob_by_id(windower.ffxi.get_player().id)
        if p then
            camp_point = {x = p.x, y = p.y}
            is_camped = true
            windower.add_to_chat(200, 'Hunter: Camp set at your current position.')
        end

    elseif cmd == 'break' or cmd == 'b' then
        camp_point = nil
        is_camped = false
        windower.add_to_chat(200, 'Hunter: Camp cleared.')

    elseif (cmd == 'camprange' or cmd == 'cr') and tonumber(args[1]) then
        local val = tonumber(args[1])
        if val >= 1 and val <= 40 then
            camp_range = val
            windower.add_to_chat(200, 'Hunter: Camp range set to ' .. camp_range .. ' yalms.')
        else
            windower.add_to_chat(123, 'Hunter: Camp range must be between 1 and 40.')
        end
    
elseif cmd == 'display' or cmd =='d' then
		settings.display = not settings.display
		config.save(settings)
		windower.add_to_chat(200, 'Hunter: Tracker display ' .. (settings.display and 'enabled.' or 'disabled.'))

    elseif cmd == '?' then
        windower.add_to_chat(123, 'Hunter Commands:')
		windower.add_to_chat(123, '//hunter OR //hunt - Begin/Stop hunt loop')
        windower.add_to_chat(123, '//hunter <1-20> - Set prey list size')
		windower.add_to_chat(123, '//hunter range <1-30> - (r #) Set auto-engage range')
        windower.add_to_chat(123, '//hunter mark - (m) Plan prey list from target')
        windower.add_to_chat(123, '//hunter track - (t) Track target ID temporarily')
        windower.add_to_chat(123, '//hunter display - (d) Toggle small overlay')
		windower.add_to_chat(123, '//hunter camprange <1-40> - (cr) Set maximum engage radius')
		windower.add_to_chat(123, '//hunter camp - (c) Lock current position as camp')
    end
end)
---------
---------
