# Soverance Steamworks

Tooling and vendored SDK for publishing Soverance Studios games to Steam.

## Layout

```
Steamworks/
├── sdk/                # Vendored Steamworks SDK (gitignored contents)
├── Scripts/
│   ├── Publish-Steam.ps1
│   ├── Templates/      # VDF templates for app and depot builds
│   └── Projects/       # Per-project JSON configs
├── Output/             # Generated VDFs and Steam build cache (gitignored)
├── Logs/               # Publish logs (gitignored)
└── README.md
```

## One-time setup

1. Follow Valve's getting-started guide: https://partner.steamgames.com/doc/gettingstarted
2. Download the Steamworks SDK, extract it, copy into a top-level `sdk/` folder (gitignored). Do not modify SDK contents - update manually when needed.
3. In Steamworks, ensure the publishing account has Edit App Metadata + Publish Builds permissions for your AppID.

## Publishing a build

The `Scripts/Publish-Steam.ps1` wrapper generates the app_build and depot_build VDF files from templates and invokes the vendored `steamcmd.exe`.

### First run (preview validation)

Always do a `-Preview` run first on a new project or after major changes. Steam validates the build (login, content scan, depot mapping) without uploading.

```powershell
cd D:\Git\soverance\Steamworks
.\Scripts\Publish-Steam.ps1 -Project Ethereal -Preview
```

### Real upload

```powershell
.\Scripts\Publish-Steam.ps1 -Project Ethereal
```

### Auto go-live on a beta branch

```powershell
.\Scripts\Publish-Steam.ps1 -Project Ethereal -SetLive beta
```

## Adding a new project

Create `Scripts/Projects/<Name>.json` modeled after `Ethereal.json`:

```json
{
  "Name": "Your Game",
  "AppId": 1234567,
  "Description": "Your Game - Soverance Studios",
  "DefaultContentRoot": "C:\\path\\to\\staged\\build",
  "Depots": [
    {
      "Id": 1234568,
      "FileMappings": [
        { "LocalPath": "*", "DepotPath": ".", "Recursive": true }
      ]
    }
  ]
}
```

Optional: `"BuildScript": "C:\\path\\to\\Export.ps1"`. `Publish-Steam.ps1` runs it before anything else, so an upload is always a fresh build rather than whatever was last staged (`-SkipBuild` re-sends the staged build as it is). If the build writes a `BUILD.txt` into the content root, outside the depot mappings, its first line (Endless Reach writes the game's commit) goes into the default build description, which is how to pick the right build on the SteamPipe Builds page. Endless Reach uses `tools\Export-Builds.ps1` from its repo.

For UE5 projects, `DefaultContentRoot` should point to the UAT `-archivedirectory` output (the directory that contains the `.exe`, `Engine/`, and `<Project>/` subdirs). UE5 with `-platform=Win64` writes the staged build flat into the archive directory; older UE4-era `WindowsNoEditor` builds nested everything under a `WindowsNoEditor/` subfolder.

## Credentials

The script resolves Steam credentials in this order:
1. `-User` parameter, paired with `STEAM_PASS` env var or interactive prompt
2. `STEAM_USER` + `STEAM_PASS` env vars (unattended runs)
3. Interactive prompts for both

Passwords are read as SecureString where possible and scrubbed from memory after the steamcmd invocation. Steam Guard 2FA prompts on first-use are handled interactively by steamcmd's own stdin - subsequent runs use the cached sentry file.

Never commit credentials to a project JSON. Use `*.local.json` (gitignored) if you need per-machine overrides.
