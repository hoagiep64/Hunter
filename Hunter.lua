-- Hunter Addon - Full Version with Prey Tracking and Overlay

_addon.name = 'Hunter'
_addon.author = 'Paulu'
_addon.version = '1.0'
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
    pos_x = 100,
    pos_y = 100,
    table_display = false,
    table_pos_x = 300,
    table_pos_y = 100
}

local settings = config.load(defaults)

--============================--
-- Prey and Tracker Variables
--============================--
local prey = {}
local prey_count = 0
local current_index = 1
local TheHuntIsOn = false
local tracked_ids = {}
local hunt_range = 14
local point_a = nil
local point_b = nil
local prowl_active = false
local current_target_point = nil

--============================--
-- Color Codes
--============================--
local COLOR_GREEN   = "\\cs(0,255,0)"
local COLOR_RED     = "\\cs(255,0,0)"
local COLOR_PURPLE  = "\\cs(180,80,250)"
local COLOR_WHITE   = "\\cs(255,255,255)"
local COLOR_RESET   = ""

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
    text = {font = 'Consolas', size = 10, alpha = 255},
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
        TargetEngage(nearest.id)
        windower.add_to_chat(207, 'Hunter: Engaging nearby threat: '..nearest.name)
        return true
    end

    return false
end

local function hunt_loop()
    coroutine.sleep(1)
    while TheHuntIsOn do
        local player = windower.ffxi.get_player()
        if player and player.status == 1 then
            maintain_position_and_facing()
        elseif not check_for_nearby_threats() then
			HunterEngage()
		end
        coroutine.sleep(1.5)
    end
end

local function prowl_loop()
    
end

--============================--
-- Display Updaters
--============================--
windower.register_event('time change', function()
    -- Tracked IDs overlay
    local now = os.time()
    local lines = {}

    for id, entry in pairs(tracked_ids) do
        if now - entry.timestamp > 60 then
            tracked_ids[id] = nil
        else
            table.insert(lines, string.format("%s: %d", entry.name, id))
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
	table.insert(display_lines, COLOR_WHITE .. 'Range: ' .. hunt_range .. ' Yalms' .. COLOR_RESET)

    for i = 1, #prey do
        local mob = windower.ffxi.get_mob_by_id(prey[i])
        if mob then table.insert(valid_mobs, mob) end
    end

    table.sort(valid_mobs, function(a, b) return a.id < b.id end)

    for _, mob in ipairs(valid_mobs) do
        local color = get_mob_color(mob, player.id)
        table.insert(display_lines, string.format("%s%s: %d%s", color, mob.name, mob.id, COLOR_RESET))
    end

    --if #valid_mobs > 0 then
        prey_display:text(table.concat(display_lines, '\n'))
        prey_display:show()
    --else
        --prey_display:hide()
    --end
end)

--============================--
-- Command Handler
--============================--
windower.register_event('addon command', function(cmd, ...)
    local args = {...}
    cmd = cmd and cmd:lower() or nil

    if not cmd or cmd == '' then
		TheHuntIsOn = not TheHuntIsOn
		windower.add_to_chat(200, 'Hunter: The hunt ' .. (TheHuntIsOn and 'is on!.' or 'is called off.'))

		if TheHuntIsOn then
			coroutine.schedule(hunt_loop, 0)
		end
		return
	end

    if tonumber(cmd) and tonumber(cmd) >= 1 and tonumber(cmd) <= 20 then
        prey_count = tonumber(cmd)
        prey = {}
        for i = 1, prey_count do prey[i] = nil end
        windower.add_to_chat(200, 'Hunter: Prey list size set to ' .. prey_count)

    elseif cmd == 'mark' or cmd == 'm' then
        if prey_count == 0 then
            windower.add_to_chat(123, 'Hunter: Set prey list size first.')
        else
            populate_prey_from_target()
        end

    elseif cmd == 'hunt' then
        HunterEngage()
		
	elseif (cmd == 'range' or cmd == 'r' or cmd == 'rng') and tonumber(args[1]) then
		local value = tonumber(args[1])
		if value >= 1 and value <= 25 then
			hunt_range = value
			windower.add_to_chat(200, 'Hunter: Defensive detection range set to ' .. hunt_range .. ' yalms.')
		else
			windower.add_to_chat(123, 'Hunter: Please enter a number between 1 and 25.')
		end
		
    elseif cmd == 'track' or cmd == 't' then
        local mob = windower.ffxi.get_mob_by_target('t')
        if mob then
            tracked_ids[mob.id] = {name = mob.name, timestamp = os.time()}
            windower.add_to_chat(200, string.format("Hunter: Tracking %s (%d) for 1 minute.", mob.name, mob.id))
        else
            windower.add_to_chat(123, 'Hunter: No target selected.')
        end

    elseif cmd == 'clear' or  cmd == 'c' then
        tracked_ids = {}
        windower.add_to_chat(200, 'Hunter: Tracker display cleared.')

    elseif cmd == 'display' or cmd =='d' then
        settings.table_display = not settings.table_display
        config.save(settings)
        windower.add_to_chat(200, 'Hunter: Tracker display ' .. (settings.display and 'enabled.' or 'disabled.'))

    elseif cmd == '?' then
        windower.add_to_chat(123, 'Hunter Commands:')
		windower.add_to_chat(123, '//hunter     	 - Begin/Stop hunt loop')
        windower.add_to_chat(123, '//hunter <1-20> - Set prey list size')
		windower.add_to_chat(123, '//hunter range <1-25> - (r #) Set auto-engage range')
        windower.add_to_chat(123, '//hunter mark     - (m) Plan prey list from target')
        windower.add_to_chat(123, '//hunter track    - (t) Track target ID temporarily')
        windower.add_to_chat(123, '//hunter clear    - (c) Clear tracked list')
        windower.add_to_chat(123, '//hunter display  - (d) Toggle small overlay')
    end
end)
---------
---------
