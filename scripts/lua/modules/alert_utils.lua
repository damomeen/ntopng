--
-- (C) 2014-15 - ntop.org
--

-- This file contains the description of all functions
-- used to trigger host alerts

local verbose = false

j = require("dkjson")
require "persistence"

function ndpival_bytes(json, protoname)
    key = "ndpiStats"

    -- Host
    if((json[key] == nil) or (json[key][protoname] == nil)) then
        if(verbose) then print("## ("..protoname..") Empty<br>\n") end
        return(0)
    else
        local v = json[key][protoname]["bytes"]["sent"]+json[key][protoname]["bytes"]["rcvd"]
        if(verbose) then print("##  ("..protoname..") "..v.."<br>\n") end
        return(v)
    end
end

function proto_bytes(old, new, protoname)
    return(ndpival_bytes(new, protoname)-ndpival_bytes(old, protoname))
end
-- =====================================================

function bytes(old, new)
    if(new["sent"] ~= nil) then
        -- Host
        return((new["sent"]["bytes"]+new["rcvd"]["bytes"])-(old["sent"]["bytes"]+old["rcvd"]["bytes"]))
    else
        -- Interface
        return(new["stats.bytes"]-old["stats.bytes"])
    end
end
function packets(old, new)
    if(new["sent"] ~= nil) then
        -- Host
        return((new["sent"]["packets"]+new["rcvd"]["packets"])-(old["sent"]["packets"]+old["rcvd"]["packets"]))
    else
        -- Interface
        return(new["stats.packets"]-old["stats.packets"])
    end
end
function dns(old, new)   return(proto_bytes(old, new, "DNS")) end
function p2p(old, new)   return(proto_bytes(old, new, "eDonkey")+proto_bytes(old, new, "BitTorrent")+proto_bytes(old, new, "Skype")) end

function are_alerts_suppressed(observed)
    local suppressAlerts = ntop.getHashCache("ntopng.prefs.alerts", observed)
    if((suppressAlerts == "") or (suppressAlerts == nil) or (suppressAlerts == "true")) then
        if(verbose) then print("Alert check for ("..address..")<br>\n") end
        return false  -- alerts are not suppressed
    else
        if(verbose) then print("Skipping alert check for("..address.."): disabled in preferences<br>\n") end
        return true -- alerts are suppressed
    end
end

alerts_granularity = {
    { "min", "Every Minute" },
    { "5mins", "Every 5 Minutes" },
    { "hour", "Hourly" },
    { "day", "Daily" }
}

alert_functions_description = {
    ["bytes"]   = "Bytes delta (sent + received)",
    ["packets"] = "Packets delta (sent + received)",
    ["dns"]     = "DNS traffic delta bytes (sent + received)",
    ["p2p"]     = "Peer-to-peer traffic delta bytes (sent + received)",
}

network_alert_functions_description = {
    ["ingress"]   = "Ingress Bytes delta",
    ["egress"] = "Egress Bytes delta",
    ["inner"]     = "Inner Bytes delta",
}

-- #################################################################

function delete_host_alert_configuration(host_ip)
    for k,v in pairs(alerts_granularity) do
        key = "ntopng.prefs.alerts_"..v[1]
        -- print(key.."<br>\n")
        ntop.delHashCache(key, host_ip)
    end
end


function delete_network_alert_configuration(network_name)
    for k,v in pairs(alerts_granularity) do
        key = "ntopng.prefs.network_alerts_"..v[1]
        -- print(key.."<br>\n")
        ntop.delHashCache(key, network_name)
    end
end

function delete_interface_alert_configuration(if_name)
    for k,v in pairs(alerts_granularity) do
        key = "ntopng.prefs.alerts_"..v[1]
        -- print(key.."<br>\n")
        ntop.delHashCache(key, if_name)
    end
end

function check_host_alert(ifname, hostname, mode, key, old_json, new_json)
    if(verbose) then
        print("check_host_alert("..ifname..", "..hostname..", "..mode..", "..key..")<br>\n")

        print("<p>--------------------------------------------<p>\n")
        print("NEW<br>"..new_json.."<br>\n")
        print("<p>--------------------------------------------<p>\n")
        print("OLD<br>"..old_json.."<br>\n")
        print("<p>--------------------------------------------<p>\n")
    end

    old = j.decode(old_json, 1, nil)
    new = j.decode(new_json, 1, nil)

    -- str = "bytes;>;123,packets;>;12"
    hkey = "ntopng.prefs.alerts_"..mode

    str = ntop.getHashCache(hkey, hostname)

    -- if(verbose) then ("--"..hkey.."="..str.."--<br>") end
    if((str ~= nil) and (str ~= "")) then
        tokens = split(str, ",")

        for _,s in pairs(tokens) do
            -- if(verbose) then ("<b>"..s.."</b><br>\n") end
            t = string.split(s, ";")

            if(t[2] == "gt") then
                op = ">"
            else
                if(t[2] == "lt") then
                    op = "<"
                else
                    op = "=="
                end
            end

            local what = "val = "..t[1].."(old, new); if(val ".. op .. " " .. t[3] .. ") then return(true) else return(false) end"
            local f = loadstring(what)
            local rc = f()


            if(rc) then
                local alert_msg = "Threshold <b>"..t[1].."</b> crossed by host <A HREF="..ntop.getHttpPrefix().."/lua/host_details.lua?host="..key..">"..key.."</A> [".. val .." ".. op .. " " .. t[3].."]"
                local alert_level = 1 -- alert_level_warning
                local alert_type = 2 -- alert_threshold_exceeded

                ntop.queueAlert(alert_level, alert_type, alert_msg)
                if(verbose) then print("<font color=red>".. alert_msg .."</font><br>\n") end
            else
                if(verbose) then print("<p><font color=green><b>Threshold "..t[1].."@"..key.." not crossed</b> [value="..val.."]["..op.." "..t[3].."]</font><p>\n") end
            end
        end
    end
end


function check_network_alert(ifname, network_name, mode, key, old_table, new_table)
    if(verbose) then
        io.write("check_newtowrk_alert("..ifname..", "..network_name..", "..mode..", "..key..")\n")
        io.write("new:\n")
        tprint(new_table)
        io.write("old:\n")
        tprint(old_table)
    end

    deltas = {}
    local delta_names = {'ingress', 'egress', 'inner'}
    for i = 1, 3 do
        local delta_name = delta_names[i]
        deltas[delta_name] = 0
        if old_table[delta_name] and new_table[delta_name] then
            deltas[delta_name] = new_table[delta_name] - old_table[delta_name]
        end
    end
    -- str = "bytes;>;123,packets;>;12"
    hkey = "ntopng.prefs.network_alerts_"..mode

    local str = ntop.getHashCache(hkey, network_name)

    -- if(verbose) then ("--"..hkey.."="..str.."--<br>") end
    if((str ~= nil) and (str ~= "")) then
        local tokens = split(str, ",")

        for _,s in pairs(tokens) do
            -- if(verbose) then ("<b>"..s.."</b><br>\n") end
            local t = string.split(s, ";")

            if(t[2] == "gt") then
                op = ">"
            else
                if(t[2] == "lt") then
                    op = "<"
                else
                    op = "=="
                end
            end

            local what = "val = deltas['"..t[1].."']; if(val ".. op .. " " .. t[3] .. ") then return(true) else return(false) end"
            local f = loadstring(what)
            local rc = f()


            if(rc) then
                local alert_msg = "Threshold <b>"..t[1].."</b> crossed by network <A HREF="..ntop.getHttpPrefix().."/lua/network_details.lua?network="..key.."&page=historical>"..network_name.."</A> [".. val .." ".. op .. " " .. t[3].."]"
                local alert_level = 1 -- alert_level_warning
                local alert_type = 2 -- alert_threshold_exceeded

                ntop.queueAlert(alert_level, alert_type, alert_msg)
                if(verbose) then print("<font color=red>".. alert_msg .."</font><br>\n") end
            else
                if(verbose) then print("<p><font color=green><b>Network threshold "..t[1].."@"..network_name.." not crossed</b> [value="..val.."]["..op.." "..t[3].."]</font><p>\n") end
            end
        end
    end
end

-- #################################

function check_interface_alert(ifname, mode, old_table, new_table)
    local ifname_clean = string.gsub(ifname, "/", "_")
    if(verbose) then
        print("check_interface_alert("..ifname..", "..mode..", "..key..")<br>\n")
    end

    -- Needed because Lua. loadstring() won't work otherwise.
    old = old_table
    new = new_table

    -- str = "bytes;>;123,packets;>;12"
    hkey = "ntopng.prefs.alerts_"..mode

    str = ntop.getHashCache(hkey, ifname_clean)

    -- if(verbose) then ("--"..hkey.."="..str.."--<br>") end
    if((str ~= nil) and (str ~= "")) then
        tokens = split(str, ",")

        for _,s in pairs(tokens) do
            -- if(verbose) then ("<b>"..s.."</b><br>\n") end
            t = string.split(s, ";")

            if(t[2] == "gt") then
                op = ">"
            else
                if(t[2] == "lt") then
                    op = "<"
                else
                    op = "=="
                end
            end

            local what = "val = "..t[1].."(old, new); if(val ".. op .. " " .. t[3] .. ") then return(true) else return(false) end"
            local f = loadstring(what)
            local rc = f()

            if(rc) then
                local alert_msg = "Threshold <b>"..t[1].."</b> crossed by interface <A HREF="..ntop.getHttpPrefix().."/lua/if_stats.lua?if_name="..ifname..
                ">"..ifname.."</A> [".. val .." ".. op .. " " .. t[3].."]"
                local alert_level = 1 -- alert_level_warning
                local alert_type = 2 -- alert_threshold_exceeded

                ntop.queueAlert(alert_level, alert_type, alert_msg)
                if(verbose) then print("<font color=red>".. alert_msg .."</font><br>\n") end
            else
                if(verbose) then print("<p><font color=green><b>Threshold "..t[1].."@"..ifname.." not crossed</b> [value="..val.."]["..op.." "..t[3].."]</font><p>\n") end
            end
        end
    end
end


-- #################################

function check_interface_threshold(ifname, mode)
    interface.select(ifname)
    local ifstats = aggregateInterfaceStats(interface.getStats())
    ifname_id = ifstats.id

    if are_alerts_suppressed("iface_"..ifname_id) then return end

    if(verbose) then print("check_interface_threshold("..ifname_id..", "..host_ip..", "..mode..")<br>\n") end
    basedir = fixPath(dirs.workingdir .. "/" .. ifname_id .. "/json/" .. mode)
    if(not(ntop.exists(basedir))) then
        ntop.mkdir(basedir)
    end

    --if(verbose) then print(basedir.."<br>\n") end
    interface.select(ifname)
    ifstats = aggregateInterfaceStats(interface.getStats())

    if (ifstats ~= nil) then
        fname = fixPath(basedir.."/iface_"..ifname_id.."_lastdump")

        if(verbose) then print(fname.."<p>\n") end
        if (ntop.exists(fname)) then
            -- Read old version
            old_dump = persistence.load(fname)
            if (old_dump ~= nil) then
                check_interface_alert(ifname, mode, old_dump, ifstats)
            end
        end

        -- Write new version
        persistence.store(fname, ifstats)
    end
end


function check_networks_threshold(ifname, mode)
    interface.select(ifname)
    local subnet_stats = interface.getNetworksStats()
    alarmed_subnets = ntop.getHashKeysCache("ntopng.prefs.network_alerts_"..mode)
    local ifname_id = interface.getStats().id

    local basedir = fixPath(dirs.workingdir .. "/" .. ifname_id .. "/json/" .. mode)
    if not ntop.exists(basedir) then
        ntop.mkdir(basedir)
    end

    for subnet,sstats in pairs(subnet_stats) do
        if sstats == nil or (alarmed_subnets and alarmed_subnets[subnet] == nil) or are_alerts_suppressed(subnet) then goto continue end
        local statspath = getPathFromKey(subnet)
        statspath = fixPath(basedir.. "/" .. statspath)
        if not ntop.exists(statspath) then
            ntop.mkdir(statspath)
        end
        statspath = fixPath(statspath .. "/alarmed_subnet_stats_lastdump")

        if ntop.exists(fname) then
            -- Read old version
            old_dump = persistence.load(statspath)
            if (old_dump ~= nil) then
                -- (ifname, network_name, mode, key, old_table, new_table)
                check_network_alert(ifname, subnet, mode, sstats['network_id'], old_dump, subnet_stats[subnet])
            end
        end
        persistence.store(statspath, subnet_stats[subnet])
        ::continue::
    end
end

-- #################################

function check_host_threshold(ifname, host_ip, mode)
    interface.select(ifname)
    local ifstats = aggregateInterfaceStats(interface.getStats())
    ifname_id = ifstats.id

    if are_alerts_suppressed(host_ip) then return end

    if(verbose) then print("check_host_threshold("..ifname_id..", "..host_ip..", "..mode..")<br>\n") end
    basedir = fixPath(dirs.workingdir .. "/" .. ifname_id .. "/json/" .. mode)
    if(not(ntop.exists(basedir))) then
        ntop.mkdir(basedir)
    end

    json = interface.getHostInfo(host_ip)

    if(json ~= nil) then
        fname = fixPath(basedir.."/".. host_ip ..".json")

        if(verbose) then print(fname.."<p>\n") end
        -- Read old version
        f = io.open(fname, "r")
        if(f ~= nil) then
            old_json = f:read("*all")
            f:close()
            check_host_alert(ifname, host_ip, mode, host_ip, old_json, json["json"])
        end

        -- Write new version
        f = io.open(fname, "w")

        if(f ~= nil) then
            f:write(json["json"])
            f:close()
        end
    end
end

-- #################################

function scanAlerts(granularity)
    local ifnames = interface.getIfNames()
    for _,_ifname in pairs(ifnames) do
        ifname = purifyInterfaceName(_ifname)
        if(verbose) then print("[minute.lua] Processing interface " .. ifname.."<p>\n") end

        check_interface_threshold(ifname, granularity)
        check_networks_threshold(ifname, granularity)
        -- host alerts checks
        local hash_key = "ntopng.prefs.alerts_"..granularity
        local hosts = ntop.getHashKeysCache(hash_key)
        if(hosts ~= nil) then
            for h in pairs(hosts) do
                if(verbose) then print("[minute.lua] Checking host " .. h.." alerts<p>\n") end
                check_host_threshold(ifname, h, granularity)
            end
        end
        -- network alerts checks
        if(networks ~= nil) then
            for n in pairs(networks) do
                if(verbose) then print("[minute.lua] Checking network " .. h.." alerts<p>\n") end
            end
        end
    end -- interfaces
end

