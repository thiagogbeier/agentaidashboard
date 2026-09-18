# Security

## Reporting a vulnerability

Do not open a public issue for a suspected vulnerability. Use GitHub's private vulnerability
reporting feature for this repository, or contact the repository owner privately.

## Credential handling

- No Azure connection strings, access tokens, Grafana service-account tokens, or Collector binaries
  belong in source control.
- The generated `otel-collector-config.yaml`, `.state/`, `otelcol/`, and logs are ignored.
- The Application Insights connection string permits ingestion and must still be treated as
  sensitive configuration.
- Grafana uses a system-assigned managed identity; no client secret is created.

## Access scope

- The Grafana managed identity receives `Monitoring Reader` only on the deployment resource group.
- The deploying user receives `Grafana Admin` only on the Grafana resource.
- The deployment does not grant subscription `Owner`, `Contributor`, or `Reader`.
