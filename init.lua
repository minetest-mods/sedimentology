--
-- Minetest Sedimentology Mod
--
local interval = 1.0
local count = 20
local radius = 100

local stat_considered = 0
local stat_displaced = 0
local stat_degraded = 0

local function round(f) 
	if f >= 0 then
		return math.floor(f + 0.5)
	else
		return math.ceil(f - 0.5)
	end
end

local walker = {
	[0] = {x = 0, z = 1},  {x = 1, z = 0},   {x = 0, z = -1}, {x = -1, z = 0},
	{x = 1, z = 1},  {x = 1, z = -1},  {x = -1, z = 1}, {x = -1, z = -1},
	{x = 2, z = 0},  {x = -2, z = 0},  {x = 0, z = 2},  {x = 0, z = -2},
	{x = 2, z = 1},  {x = 2, z = -1},  {x = 1, z = 2},  {x = 1, z = -2},
	{x = -1, z = 2}, {x = -1, z = -2}, {x = -2, z = 1}, {x = -2, z = -1},
	{x = 2, z = 2},  {x = -2, z = 2},  {x = 2, z = -2}, {x = -2, z = -2}
}
local walker_step = 0
local walker_start = 0
local walker_phase = 4

local function walker_f(x, y)
	if x == 0 and y == 0 then
		walker_step = 0
	end

	if walker_step == 0 or walker_step == 4 or walker_step == 8 or walker_step == 24 then
		walker_start = math.floor(math.random() * 4.0)
		walker_phase = 4
	elseif walker_step == 12 then
		walker_start = math.floor(math.random() * 8.0)
		walker_phase = 8
	end

	local section_start = walker_step - (walker_step % walker_phase)
	local section_part = ((walker_step - section_start) + walker_start) % walker_phase

	walker_step = walker_step + 1
	return walker[section_start + section_part]
end

local function roll(chance)
	return (math.random() >= chance)
end

local function node_above(node)
	local pos = minetest.get_pos(node)
	return {x = pos.x, y = pos.y + 1, z = pos.z}
end

local function node_below(node)
	local pos = minetest.get_pos(node)
	return {x = pos.x, y = pos.y - 1, z = pos.z}
end

local function pos_is_node(pos)
	return minetest.get_node_or_nil(pos)
end

local function node_is_air(node)
	return node.name == "air"
end

local function node_is_plant(node)
	if not node then
		return false
	end

	local name = node.name
	local drawtype = minetest.registered_nodes[name].drawtype
	if drawtype == "plantlike" then
		return true
	end

	if minetest.registered_nodes[node.name].groups.flora == 1 then
		return true
	end

	return ((name == "default:leaves") or
	        (name == "default:jungleleaves") or
	        (name == "default:pine_needles") or
	        (name == "default:cactus"))
end

local function node_is_water(node)
	if not node then
		return false
	end

	print(dump(node))

	return ((node.name == "default:water_source") or
	        (node.name == "default:water_flowing"))
end

local function node_is_lava(node)
	if not node then
		return false
	end

	return ((node.name == "default:lava_source") or
	        (node.name == "default:lava_flowing"))
end

local function node_is_liquid(node)
	if not node then
		return false
	end

	local name = node.name
	local drawtype = minetest.registered_nodes[name].drawtype
	if drawtype then
		if (drawtype == "liquid") or (drawtype == "flowingliquid") then
			return true
		end
	end

	return false
end

local function scan_for_water(pos, waterfactor)
	local w = waterfactor
	for xx = pos.x - 2,pos.x + 2,1 do
		for yy = pos.y - 2,pos.y + 2,1 do
			for zz = pos.z - 2,pos.z + 2,1 do
				local nn = minetest.get_node({xx, yy, zz})
				if nn.name == "default:water_flowing" then
					return 0.25
				elseif nn.name == "default:water_source" then
					w = 0.125
					break
				end
			end
		end
	end
	return w
end

local function scan_for_vegetation(pos)
	local v = 1.0
	for xx = pos.x - 3,pos.x + 3,1 do
		for yy = pos.y - 3,pos.y + 3,1 do
			for zz = pos.z - 3,pos.z + 3,1 do
				local nn = minetest.get_node({xx, yy, zz})
				if node_is_plant(nn) then
					-- factor distance to plant
					local d = (math.abs(xx - pos.x) + math.abs(yy - pos.y) + math.abs(zz - pos.z)) / 3.0
					-- scale it
					local vv = 0.5 / (4.0 - d)
					-- only take the lowest value
					if (vv < v) then
						v = vv
					end
				end
			end
		end
	end
	return v
end

local function node_is_valid_target_for_displacement(pos)
	local node = minetest.get_node(pos)

	if node_is_liquid(node) then
		return true
	elseif node_is_air(node) then
		return true
	elseif node_is_plant(node) then
		return true
	end
	return false
end

local function node_is_locked_in(pos)
	if
		node_is_valid_target_for_displacement({x = pos.x - 1, y = pos.y, z = pos.z}) or
		node_is_valid_target_for_displacement({x = pos.x + 1, y = pos.y, z = pos.z}) or
		node_is_valid_target_for_displacement({x = pos.x, y = pos.y, z = pos.z - 1}) or
		node_is_valid_target_for_displacement({x = pos.x, y = pos.y, z = pos.z + 1})
	then
		return false
	end
	return true
end

local function find_deposit_location(x, y, z)
	local yy = y
	while true do
		if node_is_valid_target_for_displacement({x = x, y = yy, z = z}) then
			yy = yy - 1
			if yy < -32768 then
				return y
			end
		else
			return yy + 1
		end
	end
end

local function sed()
	local underliquid = 0

	-- pick a random block in (radius) around (random online player)
	local playerlist = minetest.get_connected_players()
	local playercount = table.getn(playerlist)
	if playercount == 0 then
		return
	end
	local r = math.random(playercount)
	local randomplayer = playerlist[r]
	local playerpos = randomplayer:getpos()
	local pos = {
		x = math.random(playerpos.x - radius, playerpos.x + radius),
		y = 0,
		z = math.random(playerpos.z - radius, playerpos.z + radius)
	}
	local node = minetest.get_pos(pos)

	stat_considered = stat_considered + 1

	-- now go find the topmost non-air block
	repeat
		node = node_above(node)
	until node_is_air(node)

	repeat
		node = node_below(node)
	until not node_is_air(node)

	-- then search under water/lava and any see-through plant stuff
	while (node_is_liquid(node)) do
		underliquid = underliquid + 1
		node = node_below(node)
	end

	-- check if we're material that we can do something with
	local hardness = 1.0
	local resistance = 1.0

	if      node.name == "default:dirt" or
		node.name == "default:dirt_with_grass" or
		node.name == "default:dirt_with_grass_footsteps" or
		node.name == "default:dirt_with_snow" then
		-- default hardness (very soft) here
	elseif node.name == "default:sand" or node.name == "default:desert_sand" then
		-- sand is "hard" to break into clay, but moves easily
		hardness = 0.01
	elseif node.name == "default:gravel" then
		hardness = 0.15
		resistance = 0.70
	elseif node.name == "default:clay" then
		resistance = 0.3
	elseif node.name == "default:sandstone" or
		node.name == "default:cobble" or
		node.name == "default:mossycobble" or
		node.name == "default:desert_cobble" then
		hardness = 0.05
		resistance = 0.05
	elseif node.name == "default:desert_stone" or
		node.name == "default:stone" then
		hardness = 0.01
		resistance = 0.01
	elseif node.name == "default:stone_with_coal" or
		node.name == "default:stone_with_iron" or
		node.name == "default:stone_with_copper" or
		node.name == "default:stone_with_gold" or
		node.name == "default:stone_with_mese" or
		node.name == "default:stone_with_diamond" then
		hardness = 0.0001
		resistance = 0.01
	else
		-- we don't do anything with this node type
		return
	end

	-- determine nearby water scaling
	local waterfactor = 0.01
	if underliquid > 0 then
		waterfactor = 0.5
	else
		waterfactor = scan_for_water(pos, waterfactor)
	end

	if roll(waterfactor) then
		return
	end

	-- slow down deeper under sea level (wave action reduced energy)
	if underliquid and pos.y < 0.0 then
		if roll(2.0 * math.pow(0.5, 0.0 - pos.y)) then
			return
		end
	end

	-- factor in vegetation that slows erosion down
	if roll(scan_for_vegetation(pos)) then
		return
	end


	-- displacement - before we erode this material, we check to see if
	-- it's not easier to move the material first. If that fails, we'll
	-- end up degrading the material as calculated

	if not node_is_locked_in(pos) then
		local steps = 8

		if node.name == "default:sand" or
		   node.name == "default:desert_sand" or
		   (underliquid > 0) then
			steps = 24
		else
			steps = 8
		end

		-- walker algorithm here
		local lowest = pos.y
		local lowesto = {x = pos.x, z = pos.z}
		local o = {x = 0, z = 0}

		for step = 1, steps, 1 do
			o = walker_f(o.x, o.z)
			local h = find_deposit_location(pos.x + o.x, lowest, pos.z + o.z)
print("walking step " .. step .. " to " .. pos.x + o.x .. ", " .. pos.z + o.z .. " -> lowest = " .. h)

			if h < lowest then
				lowest = h
				lowesto = o
			end
		end

		if lowest < pos.y then
			local tpos = {x = pos.x + o.x, y = lowest, z = pos.z + o.z}

			if not roll(resistance) then
				local tnode = minetest.get_node(tpos)

				if node_is_air(tnode) or node_is_plant(tnode) or node_is_liquid(tnode) then
					-- time to displace the node from pos to tpos
					minetest.place_node(tpos, node)
					minetest.get_meta(tpos):from_table(minetest.get_meta(pos):to_table())
					minetest.remove_node(pos)

					-- FIXME
					-- fix water at source location
					-- fix water at target location

					print("Moved:", node.name, pos.x, pos.y, pos.z, "to:", tnode.name, tpos.x, tpos.y, tpos.z)
					stat_displaced = stat_displaced + 1

					-- done - don't degrade this block further
					return
				else
					--debug
					print("displacement failed: target has something:", tpos.x, tpos.y, tpos.z)
				end
			end
		end
	end

	-- degrade

	-- compensate speed for grass/dirt cycle

	-- sand only becomes clay under sealevel
	if ((node.name == "default:sand" or node.name == "default:desert_sand") and (underliquid > 0) and pos.y >= 0.0) then
		return
	end

	-- prevent dirt-to-sand outside deserts
	-- FIXME should account for Biome here too
	if (underliquid < 1) and (node.name == "default:sand" or node.name == "default:desert_sand") then
		return
	end

	if roll(hardness) then
		return
	end

	-- finally, determine new material type
	local newmat = "air"

	if node.name == "default:dirt" then
		newmat = "default:sand"
	elseif node.name == "default:dirt_with_grass" or
	       node.name == "default:dirt_with_grass_footsteps" or
	       node.name == "default:dirt_with_snow" then
		newmat = "default:dirt"
	elseif node.name == "default:sand" or node.name == "default:desert_sand" then
		newmat = "default:clay"
	elseif node.name == "default:gravel" then
		newmat = "default:dirt"
	elseif node.name == "default:clay" then
		return
	elseif node.name == "default:sandstone" or
	       node.name == "default:cobble" or
	       node.name == "default:mossycobble" or
	       node.name == "default:desert_cobble" then
		newmat = "default:gravel"
	elseif node.name == "default:desert_stone" or
	       node.name == "default:stone" then
		newmat = "default:cobble"
	elseif node.name == "default:stone_with_coal" or
	       node.name == "default:stone_with_iron" or
	       node.name == "default:stone_with_copper" or
	       node.name == "default:stone_with_gold" or
	       node.name == "default:stone_with_mese" or
	       node.name == "default:stone_with_diamond" then
		newmat = "default:stone"
	else
		print("wut", node.name)
		return
	end

	minetest.set_node(pos, {name = newmat})

	stat_degraded = stat_degraded + 1
end

local function sedimentology()
	-- select a random point that is loaded in the game
	for c=1,count,1 do
		sed()
	end
	-- requeue a timer to call again
	minetest.after(interval, sedimentology)
end

local function sedcmd(name, param)
	if param == "stats" then
		local output = "Sedimentology mod statistics:" ..
			"\nconsidered: " .. stat_considered ..
			"\ndisplaced: " .. stat_displaced ..
			"\ndegraded: " .. stat_degraded
		return true, output
	end
	return true, "Command completed succesfully"
end

minetest.register_chatcommand("sed", {
	params = "stats|...",
	description = "Various action commands for the sedimentology mod",
	func = sedcmd
})

minetest.after(interval, sedimentology)
print("Initialized Sedimentology")
