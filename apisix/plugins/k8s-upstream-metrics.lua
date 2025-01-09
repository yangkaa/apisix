local core     = require("apisix.core")
local prometheus = require("apisix.plugins.prometheus.exporter")
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
}

-- 声明指标
local metrics = {
    traffic_bytes = nil,
    request_seconds = nil
}

-- 初始化指标
local function init_metrics()
    if not metrics.traffic_bytes then
        metrics.traffic_bytes = prometheus:counter(
            "apisix_service_traffic_bytes_total",
            "Total bytes of service traffic",
            {"namespace", "service", "service_id", "status", "type"}
        )
        core.log.info("traffic_bytes metric initialized")
    end

    if not metrics.request_seconds then
        metrics.request_seconds = prometheus:histogram(
            "apisix_service_request_seconds",
            "Request latency in seconds",
            {"namespace", "service", "service_id"},
            {0.002, 0.005, 0.01, 0.02, 0.03, 0.05, 0.075, 0.1, 0.2, 0.3, 0.4, 0.5, 0.75, 1, 1.5, 2, 3}
        )
        core.log.info("request_seconds metric initialized")
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

-- 从upstream获取service名称
local function get_service_from_ctx(ctx)
    core.log.info("trying to get service name from context...")

    -- 尝试从picked_server获取
    if ctx.picked_server then
        core.log.info("found picked_server: ", ctx.picked_server)
        local service = ctx.picked_server:match("^([^.]+)")
        if service then
            core.log.info("extracted service from picked_server: ", service)
            return service
        end
    else
        core.log.info("no picked_server found")
    end

    -- 尝试从upstream获取
    if ctx.upstream_conf then
        core.log.info("found upstream_conf: ", core.json.encode(ctx.upstream_conf))
        if ctx.upstream_conf.nodes then
            -- 遍历nodes表获取第一个节点
            for node_addr, _ in pairs(ctx.upstream_conf.nodes) do
                core.log.info("found node address: ", node_addr)
                if type(node_addr) == "string" then
                    local service = node_addr:match("^([^.]+)")
                    if service then
                        core.log.info("extracted service from node address: ", service)
                        return service
                    end
                else
                    core.log.info("node address is not a string: ", type(node_addr))
                end
            end
            core.log.info("no valid node address found in upstream_conf.nodes")
        else
            core.log.info("no nodes found in upstream_conf")
        end
    else
        core.log.info("no upstream_conf found")
    end

    -- 尝试从var.upstream_host获取
    if ctx.var and ctx.var.upstream_host then
        core.log.info("found upstream_host: ", ctx.var.upstream_host)
        local service = ctx.var.upstream_host:match("^([^.]+)")
        if service then
            core.log.info("extracted service from upstream_host: ", service)
            return service
        end
    else
        core.log.info("no upstream_host found")
    end

    -- 最后尝试从route的service_name获取
    if ctx.matched_route then
        core.log.info("found matched_route: ", core.json.encode(ctx.matched_route))
        if ctx.matched_route.value and ctx.matched_route.value.service_name then
            core.log.info("found service_name in route: ", ctx.matched_route.value.service_name)
            return ctx.matched_route.value.service_name
        else
            core.log.info("no service_name found in route")
        end
    else
        core.log.info("no matched_route found")
    end

    core.log.error("failed to get service name from all sources")
    return nil
end

function _M.check_args(conf)
    -- 允许空配置
    if not conf then
        return true
    end
    return core.schema.check(schema, conf)
end

-- 记录响应头大小
local function get_headers_size(headers)
    local size = 0
    for k, v in pairs(headers) do
        size = size + #k + #v + 2  -- 2 for ": "
    end
    return size + 2  -- 2 for CRLF
end

function _M.header_filter(conf, ctx)
    ctx.upstream_headers_size = get_headers_size(ngx.resp.get_headers())
end

function _M.log(conf, ctx)
    -- 确保指标已初始化
    init_metrics()
    
    -- 添加详细的调试日志
    core.log.info("==================== k8s-upstream-metrics processing request ====================")
    core.log.info("metrics status:")
    core.log.info("  prometheus: ", prometheus and "initialized" or "nil")
    core.log.info("  traffic_bytes: ", metrics.traffic_bytes and "initialized" or "nil")
    core.log.info("  request_seconds: ", metrics.request_seconds and "initialized" or "nil")
    
    core.log.info("request uri: ", ctx.var.uri)
    core.log.info("request method: ", ctx.var.request_method)
    core.log.info("host: ", ctx.var.host)
    core.log.info("remote_addr: ", ctx.var.remote_addr)
    core.log.info("picked_server: ", ctx.picked_server)
    core.log.info("upstream_host: ", ctx.var.upstream_host)
    
    -- 打印完整的upstream配置
    if ctx.upstream_conf then
        core.log.info("upstream_conf: ", core.json.encode(ctx.upstream_conf))
    else
        core.log.info("no upstream_conf found")
    end
    
    -- 打印路由信息
    if ctx.matched_route then
        core.log.info("matched_route: ", core.json.encode(ctx.matched_route))
    else
        core.log.info("no matched_route found")
    end
    
    -- 从ctx获取service信息
    local service = get_service_from_ctx(ctx)
    if not service then
        core.log.error("no service found in context")
        return
    end
    core.log.info("final selected service: ", service)
    
    -- 从route获取namespace
    local route = ctx.matched_route
    if not route then
        core.log.error("no matched route found")
        return
    end
    
    local namespace = route.value and route.value.metadata and route.value.metadata.namespace
    if not namespace then
        core.log.warn("no namespace found in route metadata, using default")
        namespace = "default"
    end
    core.log.info("namespace: ", namespace)
    
    -- 获取service_id
    local service_id
    if conf and conf.enable_service_id then
        service_id = get_service_id_from_labels(route)
        core.log.info("service_id from labels: ", service_id)
    end
    
    -- 计算请求和响应大小
    local request_size = tonumber(ctx.var.request_length) or 0
    local response_size = (ctx.upstream_headers_size or 0) + (ctx.var.body_bytes_sent or 0)
    core.log.info("request_size: ", request_size, ", response_size: ", response_size)
    
    -- 更新指标前的最终确认
    core.log.info("updating metrics with:")
    core.log.info("  namespace: ", namespace)
    core.log.info("  service: ", service)
    core.log.info("  service_id: ", service_id)
    core.log.info("  status: ", ctx.var.status)
    
    -- 更新指标
    metrics.traffic_bytes:inc(request_size, {
        namespace = namespace or "",
        service = service,
        service_id = service_id or "",
        status = ctx.var.status,
        type = "ingress"
    })
    
    metrics.traffic_bytes:inc(response_size, {
        namespace = namespace or "",
        service = service,
        service_id = service_id or "",
        status = ctx.var.status,
        type = "egress"
    })
    
    -- 更新延迟指标
    local upstream_latency = tonumber(ctx.var.upstream_response_time) or 0
    metrics.request_seconds:observe(upstream_latency, {
        namespace = namespace or "",
        service = service,
        service_id = service_id or ""
    })
    
    core.log.info("==================== k8s-upstream-metrics finished ====================")
end

return _M 