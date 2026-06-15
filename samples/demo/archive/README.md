# Interactive TensorBoard Sample Result

This folder is the runnable sample result. It is not a screenshot and not a redesigned HTML mockup.

It contains the copied TensorBoard `training_log` event files for:

`SolarPanel_Finetuned_v01_1000Labels_ucheck Run2 - Stop when model stops improving - CONTINUE_TRAINING.`

## Start The Interactive Site

From the repository root:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\samples\demo\archive\start.ps1"
```

Then open:

```text
http://localhost:6015/?darkMode=true#timeseries
```

Double-click option:

```text
open.bat
```

If port `6015` is busy:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\samples\demo\archive\start.ps1" -Port 6016
```

Then open:

```text
http://localhost:6016/?darkMode=true#timeseries
```

## Notes

The launcher serves the copied event files through a short temporary junction path. This keeps TensorBoard tabs such as Images, Distributions, and Histograms available even when the archive folder has a long path.

The launcher searches for TensorBoard in ArcGIS Pro's Python environment first, then falls back to `tensorboard.exe` or `tensorboard` on `PATH`.
