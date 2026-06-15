# Demo Sample

This folder contains the runnable interactive TensorBoard sample result.

Primary sample archive:

`archive`

The archive folder contains copied TensorBoard event files and launches as a local interactive TensorBoard dashboard.

Double-click:

```text
open-demo.bat
```

Run from the repository root:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\samples\demo\archive\start.ps1"
```

Then open:

```text
http://localhost:6015/?darkMode=true#timeseries
```

If port `6015` is busy:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\samples\demo\archive\start.ps1" -Port 6016
```
