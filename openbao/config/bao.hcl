# Shared config for bao-1, bao-2 and bao-3 (Integrated Storage / Raft).
# Node-specific values come from environment variables in docker-compose.yml:
#   BAO_RAFT_NODE_ID, BAO_API_ADDR, BAO_CLUSTER_ADDR
# and from openbao/nodes/bao-N.hcl (log file per node).
# LAB ONLY: TLS is disabled so the stack starts without a PKI. Never do this in production.

ui            = true
cluster_name  = "openbao-lab"
log_level     = "info"
log_format    = "json"        # operational logs in JSON, easier to ship to a SIEM

storage "raft" {
  path = "/openbao/file"

  retry_join {
    leader_api_addr = "http://bao-1:8200"
  }
  retry_join {
    leader_api_addr = "http://bao-2:8200"
  }
  retry_join {
    leader_api_addr = "http://bao-3:8200"
  }
}

listener "tcp" {
  address         = "0.0.0.0:8200"
  cluster_address = "0.0.0.0:8201"
  tls_disable     = true

  telemetry {
    # lets every node, standbys included, answer /v1/sys/metrics without a token
    unauthenticated_metrics_access = true
  }
}

telemetry {
  prometheus_retention_time = "24h"   # 0 would disable the Prometheus endpoint
  disable_hostname          = true    # metric names without the hostname prefix
  usage_gauge_period        = "1m"    # token/entity/secret counts; default is 10m
}

# OpenBao 2.x refuses "bao audit enable" through the API by default
# (unsafe_allow_api_audit_creation = false). Audit devices are declared here instead,
# applied at startup and on SIGHUP. Standbys serve reads in 2.5+, so every node writes
# audit entries: the SIEM has to collect from all of them, not only the active node.
audit "file" "file" {
  description = "file audit device read by the SIEM"
  options {
    file_path = "/openbao/logs/audit.log"
    mode      = "0640"     # default 0600; 0640 lets a log shipper in the openbao group read it
  }
}
