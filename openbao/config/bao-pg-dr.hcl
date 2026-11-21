# DR node in site B (./lab.sh pg failover). Same as bao-pg.hcl but pointed at pg-b,
# the streaming replica that is promoted when site A is lost.
# Its data is whatever reached pg-b before site A was lost (asynchronous replication).
# LAB ONLY: TLS off, database password in the file.

ui            = true
cluster_name  = "openbao-pg"
log_level     = "info"
log_format    = "json"

storage "postgresql" {
  connection_url = "postgres://openbao:openbao@pg-b:5432/openbao?sslmode=disable"
  ha_enabled     = "true"
}

listener "tcp" {
  address         = "0.0.0.0:8200"
  cluster_address = "0.0.0.0:8201"
  tls_disable     = true
  telemetry {
    unauthenticated_metrics_access = true
  }
}

telemetry {
  prometheus_retention_time = "24h"
  disable_hostname          = true
  usage_gauge_period        = "1m"
}

audit "file" "file" {
  description = "file audit device read by the SIEM"
  options {
    file_path = "/openbao/logs/audit-pg.log"
    mode      = "0640"
  }
}
