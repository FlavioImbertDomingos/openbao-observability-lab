# Shared config for the PostgreSQL cluster (./lab.sh pg up): baopg-1 and baopg-2 in site A.
# Both nodes use the same database; PostgreSQL holds the data and the HA lock.
# OpenBao 2.7 adds read scaling on PostgreSQL: the standby serves reads itself.
# The DR node (baopg-dr) uses bao-pg-dr.hcl, which points to pg-b instead.
# LAB ONLY: TLS off, database password in the file.

ui            = true
cluster_name  = "openbao-pg"
log_level     = "info"
log_format    = "json"

storage "postgresql" {
  connection_url = "postgres://openbao:openbao@pg-a:5432/openbao?sslmode=disable"
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
