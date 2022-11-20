--[[

Minetest Sedimentology Mod

Copyright (c) 2015 Auke Kok, All rights reserved.

This library is free software; you can redistribute it and/or
modify it under the terms of the GNU Lesser General Public
License as published by the Free Software Foundation; either
version 2.1 of the License, or (at your option) any later version.

This library is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
Lesser General Public License for more details.

You should have received a copy of the GNU Lesser General Public
License along with this library

]]--

-- bugs? questions? Please find this project and me at
--   github.com/sofar
--

local NODE_RIVER_SRC = "default:river_water_source"
local NODE_RIVER_FLO = "default:river_water_flowing"
local NODE_WATER_SRC = "default:water_source"
local NODE_WATER_FLO = "default:water_flowing"

local mprops = dofile(minetest.get_modpath(minetest.get_current_modname()) .. "/nodes.lua")

local interval = 1.0
local count = 20
local radius = 100

local stat_considered = 0
local stat_displaced = 0
local stat_degraded = 0

local sealevel = 0
if not minetest.get_mapgen_params == nil then
	sealevel = minetest.get_mapgen_params().water_level
end

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

local function node_is_plant(node)

	local name = node.name
	if not minetest.registered_nodes[name] then
		return false
	end
	
	local groups = minetest.registered_nodes[name].groups

	return groups.flora == 1 or
			groups.leaves == 1 or
			groups.tree == 1 or
			name == "default:cactus"
end

local function scan_for_water(pos, waterfactor)
	local w = waterfactor
	for xx = pos.x - 2,pos.x + 2,1 do
		for yy = pos.y - 2,pos.y + 2,1 do
			for zz = pos.z - 2,pos.z + 2,1 do
				local nn = minetest.get_node({xx, yy, zz})
				if (nn.name == NODE_WATER_FLO) or (nn.name == NODE_RIVER_FLO) then
					return 0.25
				elseif (nn.name == NODE_WATER_SRC) or (nn.name == NODE_RIVER_SRC) then
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
	local groups = minetest.registered_nodes[node.name].groups
	
	return (groups.liquid or 0) >= 1 or
			node.name == "air" or
			node_is_plant(node)
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
		if node_is_valid_target_for_displacement({x = x, y = yy - 1, z = z}) then
			yy = yy - 1
			if yy < -32768 then
				break
			end
		else
			break
		end
	end
	return yy
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

	-- keep it in a real circle
	if (pos.x - playerpos.x) * (pos.x - playerpos.x) + (pos.z - playerpos.z) * (pos.z - playerpos.z) > radius * radius then
		return
	end

	stat_considered = stat_considered + 1

	-- force load map
	local vm = minetest.get_voxel_manip()
	local minp, maxp = vm:read_from_map(
		{x = pos.x - 3, y = pos.y - 100, z = pos.z - 3},
		{x = pos.x + 3, y = pos.y + 100, z = pos.z + 3}
	)

	-- now go find the topmost world block
	repeat
		pos = {x=pos.x, y=pos.y+1, z=pos.z}
	until (minetest.get_node(pos).name == "ignore")

	-- then find lowest air block
	repeat
		pos = {x=pos.x, y=pos.y-1, z=pos.z}
		if not minetest.get_node_or_nil(pos) then
			return -- not loaded: abort
		end
	until not (minetest.get_node(pos).name == "air")

	local function node_is_liquid(pos)
		local ndef = minetest.registered_nodes[minetest.get_node(pos).name]
		return ndef and (ndef.groups.liquid or 0) >= 1
	end

	-- then search under water/lava and any see-through plant stuff
	while node_is_liquid(pos) do
		underliquid = underliquid + 1
		pos = {x=pos.x, y=pos.y-1, z=pos.z}
		if not minetest.get_node_or_nil(pos) then
			return
		end
	end

	-- protected?
	if minetest.is_protected(pos, "mod:sedimentology") then
		return
	end

	local node = minetest.get_node(pos)

	-- do we handle this material?
	if not mprops[node.name] then
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
	if underliquid and pos.y <= sealevel then
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
		
		local groups = minetest.registered_nodes[node.name].groups
		
		if groups.sand == 1 or (underliquid > 0) then
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

			if h < lowest then
				lowest = h
				lowesto = o
			end
		end

		if lowest < pos.y then
			local tpos = {x = pos.x + lowesto.x, y = lowest, z = pos.z + lowesto.z}

			if minetest.is_protected(tpos, "mod:sedimentology") then
				return
			end

			if not roll(mprops[node.name].r) then
				local tnode = minetest.get_node(tpos)

				if node_is_valid_target_for_displacement(tpos) then
					-- time to displace the node from pos to tpos
					minetest.set_node(tpos, node)
					minetest.sound_play({name = "default_place_node"}, { pos = tpos })
					minetest.get_meta(tpos):from_table(minetest.get_meta(pos):to_table())
					minetest.remove_node(pos)

					stat_displaced = stat_displaced + 1

					-- fix water edges at or below sea level.
					if pos.y > sealevel then
						return
					end

					-- check 4 surrounding nodes
					local node_1 = minetest.get_node({x = pos.x - 1, y = pos.y, z = pos.z}).name
					local node_2 = minetest.get_node({x = pos.x + 1, y = pos.y, z = pos.z}).name
					local node_3 = minetest.get_node({x = pos.x, y = pos.y, z = pos.z - 1}).name
					local node_4 = minetest.get_node({x = pos.x, y = pos.y, z = pos.z + 1}).name
					local have_no_air = (
						node_1 ~= "air" and
					    node_2 ~= "air" and
					    node_3 ~= "air" and
					    node_4 ~= "air")
					
					if have_no_air and (node_1 == NODE_WATER_SRC or
							node_2 == NODE_WATER_SRC or
							node_3 == NODE_WATER_SRC or
							node_4 == NODE_WATER_SRC) then
						-- instead of air, leave a water node
						minetest.set_node(pos, { name = NODE_WATER_SRC})
					end
					
					if have_no_air and (node_1 == NODE_RIVER_SRC or
							node_2 == NODE_RIVER_SRC or
							node_3 == NODE_RIVER_SRC or
							node_4 == NODE_RIVER_SRC) then
						-- instead of air, leave a water node
						minetest.set_node(pos, { name = NODE_RIVER_SRC})
					end

					-- done - don't degrade this block further
					return
				end
			end
		end
	end

	-- degrade

	-- compensate speed for grass/dirt cycle

	-- sand only becomes clay under sealevel
	local groups = minetest.registered_nodes[node.name].groups
	if ((groups.sand == 1) and (underliquid > 0) and pos.y >= 0.0) then
		return
	end

	-- prevent sand-to-clay unless under water
	-- FIXME should account for Biome here too (should be ocean, river, or beach-like)
	if (groups.sand == 1) and (underliquid < 1) then
		return
	end

	-- prevent sand in dirt-dominated areas above water
	if (groups.soil == 1) and underliquid < 1 then
		-- since we don't have biome information, we'll assume that if there is no sand or
		-- desert sand anywhere nearby, we shouldn't degrade this block further
		local fpos = minetest.find_node_near({x = pos.x, y = pos.y + 1, z = pos.z}, 1, {"group:sand"})
		if not fpos then
			return
		end
	end

	if roll(mprops[node.name].h) then
		return
	end

	-- finally, determine new material type
	local newmat = "air"

	if table.getn(mprops[node.name].t) > 1 then
		-- multiple possibilities, scan area around for best suitable type
		for i = table.getn(mprops[node.name].t), 2, -1 do
			local fpos = minetest.find_node_near(pos, 5, mprops[node.name].t[i])
			if fpos then
				newmat = mprops[node.name].t[i]
				break
			end
		end
		if newmat == "air" then
			newmat = mprops[node.name].t[1]
		end
	else
		newmat = mprops[node.name].t[1]
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
	local paramlist = string.split(param, " ")
	if paramlist[1] == "stats" then
		local output = "Sedimentology mod statistics:" ..
			"\nradius: " .. radius .. ", blocks: " .. count ..
			"\nconsidered: " .. stat_considered ..
			"\ndisplaced: " .. stat_displaced ..
			"\ndegraded: " .. stat_degraded
		return true, output
	elseif paramlist[1] == "blocks" then
		if not minetest.check_player_privs(name, {server=true}) then
			return false, "You do not have privileges to execute that command"
		end
		if tonumber(paramlist[2]) then
			count = tonumber(paramlist[2])
			return true, "Set blocks to " .. count
		else
			return true, "Blocks: " .. count
		end
	else
		return false, "/sed [blocks|stats|help]\n" ..
			"blocks    - get or set block count per interval (requires 'server' privs)\n" ..
			"stats     - display operational statistics"
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
