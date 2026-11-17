# Merge 1–2 eGames Xray JSON subscriptions into ONE Xray process.
# Port 19080 is for profile #1, 19081 for profile #2.
# All outbound and balancer tags are namespaced, routing stays per-inbound.
def pref($p): if type == "string" then $p + . else . end;
def transform_outbound($p):
  .tag |= pref($p)
  | if (.proxySettings.tag? | type) == "string" then .proxySettings.tag |= pref($p) else . end
  | if (.streamSettings.sockopt.dialerProxy? | type) == "string" then .streamSettings.sockopt.dialerProxy |= pref($p) else . end;
# Preserve explicit VPN reserve outbounds, but never fail over to "direct".
# Missing fallback also becomes a dedicated blackhole for fail-closed operation.
def transform_balancer($p):
  .tag |= pref($p)
  | .selector |= map(pref($p))
  | .fallbackTag = (
      if (.fallbackTag? | type) != "string" or .fallbackTag == "direct"
      then $p + "failclosed"
      else ($p + .fallbackTag) end
    );
def transform_rule($p; $in):
  .inboundTag = [$in]
  | if (.outboundTag? | type) == "string" then .outboundTag |= pref($p) else . end
  | if (.balancerTag? | type) == "string" then .balancerTag |= pref($p) else . end;

(if type == "object" then [.] elif type == "array" then . else error("Expected Xray JSON object or array") end) as $configs
| if ($configs | length) < 1 or ($configs | length) > 2 then
    error("Expected 1 or 2 JSON profiles")
  elif ($configs | all(.[]; type == "object" and (.outbounds | type) == "array" and (.routing.balancers | type) == "array" and (.routing.balancers | length) > 0 and (.routing.rules | type) == "array" and (.burstObservatory.subjectSelector | type) == "array")) | not then
    error("Every profile must contain outbounds, routing.balancers, routing.rules and burstObservatory")
  elif ($configs | any(.[]; ((.outbounds | map(.tag) | unique | length) != (.outbounds | length)))) then
    error("Duplicate outbound tags in a profile")
  elif ($configs | map(.burstObservatory.pingConfig) | unique | length) != 1 then
    error("Different burstObservatory pingConfig values; cannot combine safely")
  elif ($configs | map(.dns) | unique | length) != 1 then
    error("Different DNS configurations; cannot combine safely")
  elif ($configs | map(.routing | del(.rules, .balancers)) | unique | length) != 1 then
    error("Different global routing options; cannot combine safely")
  else
    ($configs | to_entries | map(
      .key as $idx | .value as $c
      | ("synet-" + (($idx + 1) | tostring) + "-") as $p
      | ("synet-" + (($idx + 1) | tostring) + "-in") as $in
      | ($port + $idx) as $listen_port
      | {
          inlet: {"tag": $in, "listen":"127.0.0.1", "port": $listen_port, "protocol":"socks", "settings":{"udp":true,"auth":"noauth"}},
          outbounds: (($c.outbounds | map(transform_outbound($p))) + [{"tag": ($p + "failclosed"),"protocol":"blackhole"}]),
          balancers: ($c.routing.balancers | map(transform_balancer($p))),
          # A final per-inbound rule prevents an unmatched request from using
          # Xray's first outbound as an implicit route.
          rules: (($c.routing.rules | map(transform_rule($p; $in))) +
            [{"inboundTag": [$in], "balancerTag": ($p + $c.routing.balancers[0].tag)}]),
          selectors: ($c.burstObservatory.subjectSelector | map(pref($p)))
        }
    )) as $parts
    | ($configs[0] | {dns,log,policy}) as $opts
    | $opts + {
        inbounds: [$parts[].inlet],
        outbounds: [$parts[].outbounds[]],
        routing: (($configs[0].routing | del(.balancers, .rules)) + {
          balancers: [$parts[].balancers[]],
          rules: [$parts[].rules[]]
        }),
        burstObservatory: ($configs[0].burstObservatory + {
          subjectSelector: ([$parts[].selectors[]] | unique)
        })
      }
  end
