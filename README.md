# ArcGIS TensorBoard Keeper

Preserve interactive TensorBoard dashboards created while training deep learning models in ArcGIS Pro.

## Why This Exists

ArcGIS Pro's Image Analyst **Train Deep Learning Model** tool includes an optional **Enable Tensorboard** parameter. When enabled, ArcGIS Pro writes TensorBoard metrics while the model trains and exposes a TensorBoard URL in the tool messages.

That URL is useful during training, but it is not a durable documentation artifact. Once the training process, environment, or temporary TensorBoard server goes away, the live dashboard URL may no longer be available.

This tool turns that temporary TensorBoard dashboard into a local, relaunchable archive.

Official Esri reference:

- [Train Deep Learning Model (Image Analyst Tools)](https://doc.esri.com/en/arcgis-pro/latest/tool-reference/image-analyst/train-deep-learning-model.html?tabs=dialog#parameters)

## What It Does

`Save-TensorBoardArchive.ps1` asks one question at a time and then:

- Reads the live TensorBoard site's source `training_log` path from `/data/environment`.
- Copies only that source TensorBoard log directory.
- Verifies copied files against the source using SHA-256 hashes.
- Creates a PowerShell launcher and a double-click batch launcher.
- Picks a new unused local port by checking existing archive manifests and active ports.
- Relaunches the copied dashboard from the archived event files.
- Compares the source dashboard against the copied dashboard:
  - enabled TensorBoard tabs/plugins
  - run list
  - source/copy file hashes
- Creates a ZIP backup plus SHA-256 checksum.
- Updates the archive HTML/CSV/Markdown index after successful verification.

The launcher always serves logs through a short temporary junction path. This avoids a Windows/TensorBoard path-length problem where long archive paths can make tabs such as **Images**, **Distributions**, or **Histograms** disappear even though the event data exists.

## Sample Result

This repository includes a runnable copied TensorBoard archive as the demo result:

[samples/demo/archive](samples/demo/archive)

This is the same kind of result the tool creates: a folder with copied TensorBoard event files, a PowerShell launcher, a batch launcher, and a manifest. It launches a real interactive TensorBoard dashboard from local event files.

The sample is not a screenshot or frozen HTML. TensorBoard interactivity comes from running TensorBoard against the copied event files.

Double-click:

```text
samples\demo\open-demo.bat
```

Or run from the repository root:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\samples\demo\archive\start.ps1"
```

Then open the runnable dashboard:

```text
http://localhost:6015/?darkMode=true#timeseries
```

The sample index is here:

[samples/demo/dashboard.html]([samples/demo/dashboard.html](https://architsriva.github.io/arcgis-tensorboard-keeper/samples/demo/dashboard.html))

## Requirements

- Windows
- PowerShell
- ArcGIS Pro deep learning environment or another environment with `tensorboard.exe`
- A live TensorBoard URL that is reachable from the same machine running this tool

The launcher searches for TensorBoard in this order:

1. `C:\Program Files\ArcGIS\Pro\bin\Python\envs\arcgispro-py3\Scripts\tensorboard.exe`
2. `D:\Program Files\ArcGIS\Pro\bin\Python\envs\arcgispro-py3\Scripts\tensorboard.exe`
3. `tensorboard.exe` on `PATH`
4. `tensorboard` on `PATH`

If your ArcGIS Pro installation is elsewhere, make sure `tensorboard.exe` is available on `PATH` before running the archived launcher.

## Quick Start

Clone or download this repository, then run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\tools\Save-TensorBoardArchive.ps1"
```

The tool will ask for:

1. Live TensorBoard URL
2. Archive root
3. Training note
4. Folder name selection from generated suggestions, or a custom name
5. Final confirmation before copying

By default, archives are written to:

```text
.\archives
```

The `archives` folder is ignored by Git so training logs and generated dashboards are not accidentally committed.

## Example

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\tools\Save-TensorBoardArchive.ps1"
```

Example prompts:

```text
Live TensorBoard URL: http://my-workstation:60593/?darkMode=true#timeseries
Archive root [C:\path\to\repo\archives]:
Training note for this archive: Trains Mask R-CNN solar model with 1000 labels.
Choose 1-3, or type a custom folder name: 1
Proceed with this archive copy? [Y/n]: Y
```

## Output Structure

Each saved dashboard becomes one folder:

```text
archives/
  Example_Run_TensorBoard/
    training_log/
    start.ps1
    open.bat
    manifest.json
    verification.json
    source_file_inventory.json
    copied_file_inventory.json
  Example_Run_TensorBoard.zip
  Example_Run_TensorBoard.zip.sha256
  dashboard.html
  dashboard.csv
  archive-index.md
```

## Manual Review Is Still Recommended

The tool compares the source and copied dashboard programmatically and reports that comparison, but you should still manually open the copied dashboard once while the source dashboard is still available.

This is especially important for documentation workflows where the live ArcGIS Pro TensorBoard URL may disappear later.

## Update Existing Archive Index

To refresh the HTML/CSV/Markdown index without copying a new site:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\tools\Update-TensorBoardArchiveDocs.ps1" -ArchiveRoot ".\archives"
```

## What This Tool Does Not Do

- It does not copy training data, model weights, or ArcGIS Pro model output folders unless those files are inside the TensorBoard `training_log` directory.
- It does not scrape or freeze the TensorBoard web app HTML.
- It does not upload data anywhere.
- It does not replace manual review of the copied dashboard.

## Git Safety

This repository is intended to track the tool only. The `.gitignore` excludes generated archives, event logs, ZIP backups, checksums, logs, and verification inventories.

## License

MIT License. See [LICENSE](LICENSE).

## Attribution

This project is an independent utility for preserving local TensorBoard dashboards created during ArcGIS Pro deep learning workflows. It is not affiliated with or endorsed by Esri.
