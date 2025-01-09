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

=== TEST 2: setup route with multiple backends
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/routes/1',
                ngx.HTTP_PUT,
                [[{
                    "uri": "/hello",
                    "plugins": {
                        "traffic-split": {
                            "rules": [
                                {
                                    "weighted_upstreams": [
                                        {
                                            "upstream": {
                                                "name": "backend1",
                                                "type": "roundrobin",
                                                "nodes": {
                                                    "backend1.default.svc:5000": 70
                                                }
                                            }
                                        },
                                        {
                                            "upstream": {
                                                "name": "backend2",
                                                "type": "roundrobin",
                                                "nodes": {
                                                    "backend2.default.svc:5000": 30
                                                }
                                            }
                                        }
                                    ]
                                }
                            ]
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

=== TEST 3: test metrics (should work without explicit plugin config)
--- request
GET /hello
--- more_headers
Host: grd6e24e-5000-default-14.103.232.255.nip.io
--- response_body
hello world
--- error_log eval
[
    qr/apisix_service_traffic_bytes_total.*service="grd6e24e".*type="ingress"/,
    qr/apisix_service_traffic_bytes_total.*service="grd6e24e".*type="egress"/
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