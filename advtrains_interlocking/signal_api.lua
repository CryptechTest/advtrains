-- Signal API implementation

local F = advtrains.formspec

local DANGER = {
	main = 0,
	shunt = false,
}
advtrains.interlocking.DANGER = DANGER

advtrains.interlocking.GENERIC_FREE = {
	main = -1,
	shunt = false,
	dst = false,
}
advtrains.interlocking.FULL_FREE = {
	main = -1,
	shunt = false,
	proceed_as_main = true,
}

advtrains.interlocking.signal_convert_aspect_if_necessary = advtrains.interlocking.aspect

function advtrains.interlocking.update_signal_aspect(tcbs, skipdst)
	if tcbs.signal then
		local asp = tcbs.aspect or DANGER
		advtrains.interlocking.signal_set_aspect(tcbs.signal, asp, skipdst)
	end
end

function advtrains.interlocking.signal_can_dig(pos)
	return not advtrains.interlocking.db.get_sigd_for_signal(pos)
end

function advtrains.interlocking.signal_after_dig(pos)
	-- clear influence point

	advtrains.interlocking.signal_clear_aspect(pos)
	advtrains.distant.unassign_all(pos, true)
end

-- should be called when aspect has changed on this signal.
function advtrains.interlocking.signal_on_aspect_changed(pos)
	local ipts, iconn = advtrains.interlocking.db.get_ip_by_signalpos(pos)
	if not ipts then return end
	local ipos = minetest.string_to_pos(ipts)

	-- FIXME: invalidate_all_paths_ahead does not appear to always work as expected
	--advtrains.invalidate_all_paths_ahead(ipos)
	minetest.after(0, advtrains.invalidate_all_paths, ipos)
end

function advtrains.interlocking.signal_rc_handler(pos, node, player, itemstack, pointed_thing)
	local pname = player:get_player_name()
	local control = player:get_player_control()
	if control.aux1 then
		advtrains.interlocking.show_ip_form(pos, pname)
		return
	end
	advtrains.interlocking.show_signal_form(pos, node, pname)
end

function advtrains.interlocking.show_signal_form(pos, node, pname)
	local sigd = advtrains.interlocking.db.get_sigd_for_signal(pos)
	if sigd then
		advtrains.interlocking.show_signalling_form(sigd, pname)
	else
		local ndef = minetest.registered_nodes[node.name]
		if ndef.advtrains and ndef.advtrains.set_aspect then
			-- permit to set aspect manually
			local function callback(pname, aspect)
				advtrains.interlocking.signal_set_aspect(pos, aspect)
			end
			local isasp = advtrains.interlocking.signal_get_aspect(pos, node)

			advtrains.interlocking.show_signal_aspect_selector(
				pname,
				ndef.advtrains.supported_aspects,
				pos, callback,
				isasp)
		else
			--static signal - only IP
			advtrains.interlocking.show_ip_form(pos, pname)
		end
	end
end

-- Returns the aspect the signal at pos is supposed to show
function advtrains.interlocking.signal_get_supposed_aspect(pos)
	local sigd = advtrains.interlocking.db.get_sigd_for_signal(pos)
	if sigd then
		local tcbs = advtrains.interlocking.db.get_tcbs(sigd)
		if tcbs.aspect then
			return convert_aspect_if_necessary(tcbs.aspect)
		end
	end
	return DANGER;
end

local players_assign_ip = {}

local function ipmarker(ipos, connid)
	local node_ok, conns, rhe = advtrains.get_rail_info_at(ipos, advtrains.all_tracktypes)
	if not node_ok then return end
	local yaw = advtrains.dir_to_angle(conns[connid].c)

	-- using tcbmarker here
	local obj = minetest.add_entity(vector.add(ipos, {x=0, y=0.2, z=0}), "advtrains_interlocking:tcbmarker")
	if not obj then return end
	obj:set_yaw(yaw)
	obj:set_properties({
		textures = { "at_il_signal_ip.png" },
	})
end

function advtrains.interlocking.make_ip_formspec_component(pos, x, y, w)
	advtrains.interlocking.db.check_for_duplicate_ip(pos)
	local pts, connid = advtrains.interlocking.db.get_ip_by_signalpos(pos)
	if pts then
		return table.concat {
			F.S_label(x, y, "Influence point is set at @1.", string.format("%s/%s", pts, connid)),
			F.S_button_exit(x, y+0.5, w/2-0.125, "ip_set", "Modify"),
			F.S_button_exit(x+w/2+0.125, y+0.5, w/2-0.125, "ip_clear", "Clear"),
		}, pts, connid
	else
		return table.concat {
			F.S_label(x, y, "Influence point is not set."),
			F.S_button_exit(x, y+0.5, w, "ip_set", "Set influence point"),
		}
	end
end

-- shows small info form for signal properties
-- This function is named show_ip_form because it was originally only intended
-- for assigning/changing the influence point.
-- only_notset: show only if it is not set yet (used by signal tcb assignment)
function advtrains.interlocking.show_ip_form(pos, pname, only_notset)
	if not minetest.check_player_privs(pname, "interlocking") then
		return
	end
	local ipform, pts, connid = advtrains.interlocking.make_ip_formspec_component(pos, 0.5, 0.5, 7)
	local form = {
		"formspec_version[4]",
		"size[8,2.25]",
		ipform,
	}
	if pts then
		local ipos = minetest.string_to_pos(pts)
		ipmarker(ipos, connid)
	end
	if advtrains.distant.appropriate_signal(pos) then
		form[#form+1] = advtrains.interlocking.make_dst_formspec_component(pos, 0.5, 2, 7, 4.25)
		form[2] = "size[8,6.75]"
	end
	form = table.concat(form)
	if not only_notset or not pts then
		minetest.show_formspec(pname, "at_il_propassign_"..minetest.pos_to_string(pos), form)
	end
end

function advtrains.interlocking.handle_ip_formspec_fields(pname, pos, fields)
	if not (pos and minetest.check_player_privs(pname, {train_operator=true, interlocking=true})) then
		return
	end
	if fields.ip_set then
		advtrains.interlocking.signal_init_ip_assign(pos, pname)
	elseif fields.ip_clear then
		advtrains.interlocking.db.clear_ip_by_signalpos(pos)
	end
end

minetest.register_on_player_receive_fields(function(player, formname, fields)
	local pname = player:get_player_name()
	local pts = string.match(formname, "^at_il_propassign_([^_]+)$")
	local pos
	if pts then
		pos = minetest.string_to_pos(pts)
	end
	if pos then
		advtrains.interlocking.handle_ip_formspec_fields(pname, pos, fields)
		advtrains.interlocking.handle_dst_formspec_fields(pname, pos, fields)
	end
end)

-- inits the signal IP assignment process
function advtrains.interlocking.signal_init_ip_assign(pos, pname)
	if not minetest.check_player_privs(pname, "interlocking") then
		minetest.chat_send_player(pname, "Insufficient privileges to use this!")
		return
	end
	--remove old IP
	--advtrains.interlocking.db.clear_ip_by_signalpos(pos)
	minetest.chat_send_player(pname, "Configuring Signal: Please look in train's driving direction and punch rail to set influence point.")
	
	players_assign_ip[pname] = pos
end

minetest.register_on_punchnode(function(pos, node, player, pointed_thing)
	local pname = player:get_player_name()
	if not minetest.check_player_privs(pname, "interlocking") then
		return
	end
	-- IP assignment
	local signalpos = players_assign_ip[pname]
	if signalpos then
		if vector.distance(pos, signalpos)<=50 then
			local node_ok, conns, rhe = advtrains.get_rail_info_at(pos, advtrains.all_tracktypes)
			if node_ok and #conns == 2 then
				
				local yaw = player:get_look_horizontal()
				local plconnid = advtrains.yawToClosestConn(yaw, conns)
				
				-- add assignment if not already present.
				local pts = advtrains.roundfloorpts(pos)
				if not advtrains.interlocking.db.get_ip_signal_asp(pts, plconnid) then
					advtrains.interlocking.db.set_ip_signal(pts, plconnid, signalpos)
					ipmarker(pos, plconnid)
					minetest.chat_send_player(pname, "Configuring Signal: Successfully set influence point")
				else
					minetest.chat_send_player(pname, "Configuring Signal: Influence point of another signal is already present!")
				end
			else
				minetest.chat_send_player(pname, "Configuring Signal: This is not a normal two-connection rail! Aborted.")
			end
		else
			minetest.chat_send_player(pname, "Configuring Signal: Node is too far away. Aborted.")
		end
		players_assign_ip[pname] = nil
	end
end)
