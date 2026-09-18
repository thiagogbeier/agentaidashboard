# Generated reports

`scripts\Status.ps1` writes the current deployment report to `reports\status.html`.

Generated reports are local runtime artifacts and are excluded from Git. Run:

```powershell
.\scripts\Status.ps1 -Open
```

to regenerate and open the report.
