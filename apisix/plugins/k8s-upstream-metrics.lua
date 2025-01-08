local core     = require("apisix.core")
local prometheus = require("apisix.plugins.prometheus")
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
}

-- 声明指标
local metrics = {}

function _M.init_worker()
    -- 在init_worker阶段初始化指标
    metrics = {
        traffic_bytes = prometheus:counter(
            "apisix_service_traffic_bytes_total",
            "Total bytes of service traffic",
            {"namespace", "service", "service_id", "status", "type"}
        ),
        request_seconds = prometheus:histogram(
            "apisix_service_request_seconds", 
            "Request latency in seconds",
            {"namespace", "service", "service_id"},
            {0.002, 0.005, 0.01, 0.02, 0.03, 0.05, 0.075, 0.1, 0.2, 0.3, 0.4, 0.5, 0.75, 1, 1.5, 2, 3}
        )
    }
end

-- 从route labels中获取service_id
local function get_service_id_from_labels(route)
    if not route or not route.value or not route.value.labels then
        return nil
    end
    
    return route.value.labels.service_id
end

-- 从upstream_info获取service名称
local function get_service_from_upstream(ctx)
    local upstream_info = ctx.upstream_info
    if not upstream_info then
        return nil
    end
    
    -- upstream_info.host 通常格式为: service.namespace.svc.cluster.local
    local host = upstream_info.host
    if not host then
        return nil
    end
    
    -- 解析service名称
    local service = host:match("^([^.]+)")
    return service
end

function _M.check_schema(conf)
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
    -- 从upstream_info获取实际访问的service信息
    local service = get_service_from_upstream(ctx)
    if not service then
        core.log.error("failed to get service from upstream info")
        return
    end
    
    -- 从route获取namespace
    local route = ctx.matched_route
    if not route then
        core.log.error("no matched route found")
        return
    end
    
    local namespace = route.value and route.value.metadata and route.value.metadata.namespace
    if not namespace then
        core.log.warn("no namespace found in route metadata")
    end
    
    -- 获取service_id
    local service_id
    if conf.enable_service_id then
        service_id = get_service_id_from_labels(route)
    end
    
    -- 计算请求和响应大小
    local request_size = tonumber(ctx.var.request_length) or 0  -- 入口流量
    local response_headers_size = ctx.upstream_headers_size or 0
    local response_body_size = ctx.var.body_bytes_sent or 0
    local response_size = response_headers_size + response_body_size  -- 出口流量
    
    -- 更新入口流量指标
    metrics.traffic_bytes:inc(request_size, {
        namespace = namespace or "",
        service = service,
        service_id = service_id or "",
        status = ctx.var.status,
        type = "ingress"
    })
    
    -- 更新出口流量指标
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