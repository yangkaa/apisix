use t::APISIX 'no_plan';

repeat_each(1);
no_long_string();
no_shuffle();
no_root_location();

add_block_preprocessor(sub {
    my ($block) = @_;
});

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
                        "127.0.0.1:1980": 1
                    },
                    "type": "roundrobin",
                    "host": "test-service.test-ns.svc.cluster.local"
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

=== TEST 3: test metrics
--- request
GET /hello
--- more_headers
Content-Type: application/json
{"test":"data"}
--- response_body
hello world
--- no_error_log
[error]
--- error_log eval
[
    qr/apisix_service_traffic_bytes_total.*service="test-service".*type="ingress"/,
    qr/apisix_service_traffic_bytes_total.*service="test-service".*type="egress"/
]

=== TEST 4: verify metrics endpoint
--- request
GET /apisix/prometheus/metrics
--- response_body eval
qr/apisix_service_traffic_bytes_total\{.*\} \d+/
--- no_error_log
[error] 