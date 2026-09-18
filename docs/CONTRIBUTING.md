# Contributing

1. Fork or create a branch.
2. Keep generated/runtime files out of commits.
3. Parse every changed PowerShell file:

   ```powershell
   $errors = $null
   [System.Management.Automation.Language.Parser]::ParseFile(
     '.\scripts\Deploy.ps1',
     [ref]$null,
     [ref]$errors
   ) | Out-Null
   $errors
   ```

4. Build the Bicep template:

   ```powershell
   az bicep build --file .\infra\main.bicep --outfile .\infra\azuredeploy.json
   ```

5. Run the deployment script and choose `NO` to verify its preview/cancellation path.
6. Never include tenant IDs, subscription IDs, connection strings, tokens, or personal dashboard
   URLs in examples.
