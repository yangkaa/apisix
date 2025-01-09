local core     = require("apisix.core")
local exporter = require("apisix.plugins.prometheus.exporter")
local ngx = ngx
local pairs = pairs

local plugin_name = "k8s-upstream-metrics"

local schema = {
    type = "object",
    properties = {
        enable_service_id = {
            type = "boolean",
            default = true,
            description = "whether to fetch service_id from k8s service labels"
        }
    }
}

local _M = {
    version = 0.1,
    priority = 1000,
    name = plugin_name,
    schema = schema,
    metadata_schema = nil,
    type = 'auth',
    run_policy = 'prefer_route',
    phases = {
        log = 1,
        header_filter = 1
    }
}

-- 声明指标和 registry
local prometheus_registry
local metrics = {
    traffic_bytes = nil,
    request_seconds = nil
}

-- 初始化指标
local function init_metrics()
    if not prometheus_registry then
        prometheus_registry = exporter.get_prometheus()
        core.log.warn("prometheus registry initialized")
    end

    if not metrics.traffic_bytes then
        metrics.traffic_bytes = prometheus_registry:counter(
            "apisix_service_traffic_bytes_total",
            "Total bytes of service traffic",
            {"namespace", "service", "service_id", "port", "status", "type"}
        )
        core.log.warn("traffic_bytes metric initialized")
    end

    if not metrics.request_seconds then
        metrics.request_seconds = prometheus_registry:histogram(
            "apisix_service_request_seconds",
            "Request latency in seconds",
            {"namespace", "service", "service_id", "port"},
            {0.002, 0.005, 0.01, 0.02, 0.03, 0.05, 0.075, 0.1, 0.2, 0.3, 0.4, 0.5, 0.75, 1, 1.5, 2, 3}
        )
        core.log.warn("request_seconds metric initialized")
    end
end

function _M.init_worker()
    -- 在init_worker阶段初始化指标
    init_metrics()
end

-- 从route labels中获取service_id
local function get_service_id_from_labels(route)
    if not route or not route.value or not route.value.labels then
        return nil
    end
    
    return route.value.labels.service_id
end

-- 从 upstream name 提取信息
-- 例如: default_nginx_80 -> namespace=default, service=nginx, port=80
local function parse_upstream_name(name)
    if not name then
        return nil, nil, nil
    end
    
    local ns, svc, port = name:match("^([^_]+)_([^_]+)_(%d+)$")
    if not ns or not svc or not port then
        core.log.error("failed to parse upstream name: ", name)
        return nil, nil, nil
    end
    
    return ns, svc, port
end

-- 从upstream获取service名称
local function get_service_from_ctx(ctx)
    core.log.warn("========== get_service_from_ctx start ==========")
    core.log.warn("trying to get service name from context...")
    core.log.warn("upstream: ", ctx.var.upstream)
    core.log.warn("host: ", ctx.var.host)
    core.log.warn("upstream_host: ", ctx.var.upstream_host)
    
    -- 步骤1: 尝试从 upstream 获取
    if ctx.var.upstream then
        core.log.warn("step 1: trying to extract from upstream")
        local ip_port = ctx.var.upstream:match("http://([^/]+)")
        if ip_port then
            core.log.warn("extracted ip_port from upstream: ", ip_port)
        else
            core.log.warn("failed to extract ip_port from upstream")
        end
    else
        core.log.warn("step 1: upstream is nil, skipping")
    end

    -- 步骤2: 尝试从 picked_server 获取
    core.log.warn("step 2: trying to extract from picked_server")
    if ctx.picked_server then
        core.log.warn("found picked_server: ", ctx.picked_server)
        local service = ctx.picked_server:match("^([^.]+)")
        if service then
            core.log.warn("successfully extracted service from picked_server: ", service)
            return service
        else
            core.log.warn("failed to extract service from picked_server")
        end
    else
        core.log.warn("picked_server is nil, skipping")
    end

    -- 步骤3: 尝试从 upstream_conf 获取
    core.log.warn("step 3: trying to extract from upstream_conf")
    if ctx.upstream_conf then
        core.log.warn("found upstream_conf")
        if ctx.upstream_conf.name then
            core.log.warn("found name in upstream_conf: ", ctx.upstream_conf.name)
            local ns, svc, port = parse_upstream_name(ctx.upstream_conf.name)
            if ns and svc and port then
                core.log.warn("parsed upstream name: ns=", ns, ", svc=", svc, ", port=", port)
                return ns, svc, port
            end
        end
        if ctx.upstream_conf.nodes then
            core.log.warn("found nodes in upstream_conf")
            for node_addr, _ in pairs(ctx.upstream_conf.nodes) do
                core.log.warn("checking node address: ", node_addr)
                if type(node_addr) == "string" then
                    local service = node_addr:match("^([^.]+)")
                    if service then
                        core.log.warn("successfully extracted service from node address: ", service)
                        return service
                    else
                        core.log.warn("failed to extract service from node address")
                    end
                else
                    core.log.warn("node address is not a string: ", type(node_addr))
                end
            end
        else
            core.log.warn("no nodes found in upstream_conf")
        end
    else
        core.log.warn("upstream_conf is nil, skipping")
    end

    -- 步骤4: 尝试从 route 获取
    core.log.warn("step 4: trying to extract from matched_route")
    if ctx.matched_route and ctx.matched_route.value then
        core.log.warn("found matched_route")
        
        -- 4.1: 尝试从 service_name 获取
        if ctx.matched_route.value.service_name then
            core.log.warn("found service_name in route: ", ctx.matched_route.value.service_name)
            return ctx.matched_route.value.service_name
        else
            core.log.warn("no service_name found in route")
        end
        
        -- 4.2: 尝试从 name 获取
        if ctx.matched_route.value.name then
            core.log.warn("found route name: ", ctx.matched_route.value.name)
            local service = ctx.matched_route.value.name:match("default_([^-]+)")
            if service then
                core.log.warn("successfully extracted service from route name: ", service)
                return service
            else
                core.log.warn("failed to extract service from route name")
            end
        else
            core.log.warn("no name found in route")
        end
    else
        core.log.warn("matched_route or its value is nil, skipping")
    end

    core.log.warn("========== get_service_from_ctx end: no service found ==========")
    core.log.error("failed to get service name from all sources")
    return nil, nil, nil
end

function _M.check_args(conf)
    -- 允许空配置
    if not conf then
        return true
    end
    return core.schema.check(schema, conf)
end

function _M.log(conf, ctx)
    init_metrics()
    
    core.log.warn("==================== k8s-upstream-metrics processing request ====================")
    core.log.warn("metrics status:")
    core.log.warn("  prometheus: ", prometheus_registry and "initialized" or "nil")
    core.log.warn("  traffic_bytes: ", metrics.traffic_bytes and "initialized" or "nil")
    core.log.warn("  request_seconds: ", metrics.request_seconds and "initialized" or "nil")
    
    core.log.warn("request uri: ", ctx.var.uri)
    core.log.warn("request method: ", ctx.var.request_method)
    core.log.warn("host: ", ctx.var.host)
    core.log.warn("remote_addr: ", ctx.var.remote_addr)
    core.log.warn("picked_server: ", ctx.picked_server)
    core.log.warn("upstream_host: ", ctx.var.upstream_host)
    
    if ctx.upstream_conf then
        core.log.warn("upstream_conf: ", core.json.encode(ctx.upstream_conf))
    else
        core.log.warn("no upstream_conf found")
    end
    
    if ctx.matched_route then
        core.log.warn("matched_route: ", core.json.encode(ctx.matched_route))
    else
        core.log.warn("no matched_route found")
    end
    
    local namespace, service, port = get_service_from_ctx(ctx)
    if not service then
        core.log.error("no service found in context")
        return
    end
    core.log.warn("final selected: ns=", namespace, ", svc=", service, ", port=", port)
    
    local service_id
    if conf and conf.enable_service_id then
        service_id = get_service_id_from_labels(ctx.matched_route)
        core.log.warn("service_id from labels: ", service_id)
    end
    
    -- 计算请求和响应大小
    local request_size = tonumber(ctx.var.request_length) or 0
    local response_size = tonumber(ctx.var.bytes_sent or 0)
    
    -- 添加详细的响应大小计算日志
    core.log.warn("========== response size calculation ==========")
    core.log.warn("raw bytes_sent: ", ctx.var.bytes_sent)
    core.log.warn("raw bytes_sent type: ", type(ctx.var.bytes_sent))
    core.log.warn("tonumber(bytes_sent): ", tonumber(ctx.var.bytes_sent))
    core.log.warn("final response_size: ", response_size)
    core.log.warn("========== response size calculation end ==========")
    
    core.log.warn("request_size: ", request_size, ", response_size: ", response_size)
    core.log.warn("headers_size: ", ctx.upstream_headers_size)
    
    core.log.warn("updating metrics with:")
    core.log.warn("  namespace: ", namespace)
    core.log.warn("  service: ", service)
    core.log.warn("  service_id: ", service_id)
    core.log.warn("  status: ", ctx.var.status)
    
    
    metrics.traffic_bytes:inc(request_size, {
        namespace,
        service,
        service_id or "",
        port,
        tostring(ctx.var.status),
        "ingress"
    })
    
    metrics.traffic_bytes:inc(response_size, {
        namespace,
        service,
        service_id or "",
        port,
        tostring(ctx.var.status),
        "egress"
    })
    
    local upstream_latency = tonumber(ctx.var.upstream_response_time) or 0
    metrics.request_seconds:observe(upstream_latency, {
        namespace,
        service,
        service_id or "",
        port
    })
    
    core.log.warn("==================== k8s-upstream-metrics finished ====================")
end

return _M 