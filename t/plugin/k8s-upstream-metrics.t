use t::APISIX 'no_plan';

repeat_each(1);
no_long_string();
no_shuffle();
no_root_location();

run_tests;

__DATA__

=== TEST 1: sanity - check schema
--- config
    location /t {
        content_by_lua_block {
            local plugin = require("apisix.plugins.k8s-upstream-metrics")
            local ok, err = plugin.check_schema({
                enable_service_id = true
            })
            if not ok then
                ngx.say(err)
            end
            ngx.say("done")
        }
    }
--- request
GET /t
--- response_body
done
--- no_error_log
[error]

=== TEST 2: setup route with upstream
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            -- 创建上游服务
            local code, body = t('/apisix/admin/upstreams/1',
                ngx.HTTP_PUT,
                [[{
                    "nodes": {
                        "test-service.test-ns.svc.cluster.local:8080": 1
                    },
                    "type": "roundrobin"
                }]]
            )
            if code >= 300 then
                ngx.status = code
                return
            end
            
            -- 创建路由
            code, body = t('/apisix/admin/routes/1',
                ngx.HTTP_PUT,
                [[{
                    "uri": "/hello",
                    "plugins": {
                        "k8s-upstream-metrics": {
                            "enable_service_id": true
                        }
                    },
                    "metadata": {
                        "namespace": "test-ns"
                    },
                    "labels": {
                        "service_id": "test-service-id"
                    },
                    "upstream_id": 1
                }]]
            )
            if code >= 300 then
                ngx.status = code
                return
            end
            ngx.say(body)
        }
    }
--- request
GET /t
--- response_body
passed
--- no_error_log
[error]

=== TEST 3: test ingress traffic
--- config
    location /t {
        content_by_lua_block {
            local http = require "resty.http"
            local httpc = http.new()
            local uri = "http://127.0.0.1:" .. ngx.var.server_port .. "/hello"
            local res, err = httpc:request_uri(uri, {
                method = "POST",
                body = '{"test":"data"}',
                headers = {
                    ["Content-Type"] = "application/json",
                }
            })
        }
    }
--- request
GET /t
--- error_log eval
[
    qr/apisix_service_traffic_bytes_total.*service="test-service".*type="ingress"/
]
--- no_error_log
[error]

=== TEST 4: test egress traffic
--- config
    location /t {
        content_by_lua_block {
            local http = require "resty.http"
            local httpc = http.new()
            local uri = "http://127.0.0.1:" .. ngx.var.server_port .. "/hello"
            local res, err = httpc:request_uri(uri)
        }
    }
--- request
GET /t
--- error_log eval
[
    qr/apisix_service_traffic_bytes_total.*service="test-service".*type="egress"/
]
--- no_error_log
[error]

=== TEST 5: verify metrics endpoint
--- request
GET /apisix/prometheus/metrics
--- response_body eval
qr/apisix_service_traffic_bytes_total\{.*\} \d+/
--- no_error_log
[error] 