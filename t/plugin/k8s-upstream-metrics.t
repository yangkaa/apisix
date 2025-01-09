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

=== TEST 1: set global rule
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/global_rules/1',
                ngx.HTTP_PUT,
                [[{
                    "plugins": {
                        "k8s-upstream-metrics": {
                            "enable_service_id": true
                        }
                    }
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

=== TEST 2: setup route without plugin config
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/routes/1',
                ngx.HTTP_PUT,
                [[{
                    "uri": "/hello",
                    "upstream": {
                        "type": "roundrobin",
                        "nodes": {
                            "127.0.0.1:1980": 1
                        },
                        "host": "test-service.test-ns.svc.cluster.local"
                    }
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

=== TEST 3: test metrics (should work without explicit plugin config)
--- request
GET /hello
--- more_headers
Content-Type: application/json
{"test":"data"}
--- response_body
hello world
--- error_log eval
[
    qr/apisix_service_traffic_bytes_total.*service="test-service".*type="ingress"/,
    qr/apisix_service_traffic_bytes_total.*service="test-service".*type="egress"/
]
--- no_error_log
[error]

=== TEST 4: verify metrics endpoint
--- request
GET /apisix/prometheus/metrics
--- response_body eval
qr/apisix_service_traffic_bytes_total\{.*\} \d+/
--- no_error_log
[error] 