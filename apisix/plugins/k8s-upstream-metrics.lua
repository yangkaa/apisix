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
}

-- 声明指标
local metrics = {
    traffic_bytes = nil,
    request_seconds = nil
}

function _M.init_worker()
    -- 在init_worker阶段初始化指标
    if not metrics.traffic_bytes then
        metrics.traffic_bytes = exporter.metric({
            type = "counter",
            name = "apisix_service_traffic_bytes_total",
            help = "Total bytes of service traffic",
            labels = {"namespace", "service", "service_id", "status", "type"}
        })
    end

    if not metrics.request_seconds then
        metrics.request_seconds = exporter.metric({
            type = "histogram",
            name = "apisix_service_request_seconds",
            help = "Request latency in seconds",
            labels = {"namespace", "service", "service_id"},
            buckets = {0.002, 0.005, 0.01, 0.02, 0.03, 0.05, 0.075, 0.1, 0.2, 0.3, 0.4, 0.5, 0.75, 1, 1.5, 2, 3}
        })
    end
end

-- 从route labels中获取service_id
local function get_service_id_from_labels(route)
    if not route or not route.value or not route.value.labels then
        return nil
    end
    
    return route.value.labels.service_id
end

-- 从picked_server获取service名称
local function get_service_from_picked_server(ctx)
    local server = ctx.picked_server
    if not server then
        return nil
    end
    
    -- server通常格式为: serviceName.namespace.svc:port
    local service = server:match("^([^.]+)")
    return service
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
    -- 添加详细的调试日志
    core.log.info("k8s-upstream-metrics processing request")
    core.log.info("host: ", ctx.var.host)
    core.log.info("picked_server: ", ctx.picked_server)
    
    -- 从picked_server获取实际处理请求的service信息
    local service = get_service_from_picked_server(ctx)
    if not service then
        core.log.error("no service found in picked_server")
        return
    end
    core.log.info("service: ", service)
    
    -- 从route获取namespace
    local route = ctx.matched_route
    if not route then
        core.log.error("no matched route found")
        return
    end
    core.log.info("route: ", core.json.encode(route))
    
    local namespace = route.value and route.value.metadata and route.value.metadata.namespace
    if not namespace then
        core.log.warn("no namespace found in route metadata")
        namespace = "default"  -- 使用默认namespace
    end
    core.log.info("namespace: ", namespace)
    
    -- 获取service_id
    local service_id
    if conf and conf.enable_service_id then
        service_id = get_service_id_from_labels(route)
    end
    core.log.info("service_id: ", service_id)
    
    -- 计算请求和响应大小
    local request_size = tonumber(ctx.var.request_length) or 0
    local response_size = (ctx.upstream_headers_size or 0) + (ctx.var.body_bytes_sent or 0)
    core.log.info("request_size: ", request_size, ", response_size: ", response_size)
    
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
end

return _M 