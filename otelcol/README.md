# OpenTelemetry Collector runtime

`Deploy.ps1` downloads the pinned OpenTelemetry Collector Contrib release into this directory for a
new workstation and verifies the published SHA-256 checksum before extraction.

The executable and other downloaded release files are intentionally excluded from Git. If a
compatible Collector is already listening on ports 4317 and 4318 and targets the selected
Application Insights resource, `Deploy.ps1` reuses that installation instead of duplicating it.

The generated `otel-collector-config.yaml` is stored at the repository root and is also excluded
from Git because it contains the Application Insights ingestion connection string.
