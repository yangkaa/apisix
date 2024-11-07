local dbg = require("apisix.inspect.dbg")
local core = require("apisix.core")
dbg.set_hook("apisix/core/config_etcd.lua", 629, nil, function(info)
    local filter_res = "/routes"
    if info.vals.self.key:sub(-#filter_res) == filter_res and not info.vals.err then
        core.log.warn("etcd watch /routes response: ", core.json.encode(info.vals.dir_res, true))
        return false
    end
    return false
end)


dbg.set_hook("apisix/radixtree_uri.lua", 33, require("apisix").match, function(info)
    core.log.warn("[radixtree_uri.lua]---user_routes=", core.json.delay_encode(info.vals.user_routes), "--service_version=", core.json.delay_encode(info.vals.service_version))
    return true
end)

--  vi /usr/local/apisix/plugin_inspect_hooks.lua


--
--dbg.set_hook("apisix/radixtree_host_uri.lua", 170, require("apisix").matching, function(info)
--    core.log.warn("match opts =", core.json.delay_encode(info.vals.match_opts, true), "ok status", info.vals.ok)
--    return true
--end)
--
