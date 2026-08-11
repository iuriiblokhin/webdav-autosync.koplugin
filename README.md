# WebDAV Auto Sync – KOReader Plugin

Sync books between a WebDAV server and your device. Supports one-way download, one-way upload, and intelligent two-way sync with conflict resolution.

## Features

- **WebDAV connection** – Server URL with optional username/password (Basic auth).
- **Import from KOReader cloud** – Populate server URL and credentials automatically from KOReader's built-in cloud storage configuration (if already set up there).
- **Download folder** – Opens KOReader's file explorer; navigate and long-press a folder to select it (no typing paths).
- **File extensions (optional)** – Sync only specific extensions (e.g. `epub, pdf, txt`). Leave empty to sync all formats KOReader supports (EPUB, PDF, DjVu, XPS, CBT, CBZ, CB7, FB2, PDB, TXT, HTML, RTF, CHM, DOC, MOBI, ZIP, MD).
- **Auto sync on startup** – When enabled, a one-way download sync runs once when KOReader starts.
- **Sync now** – One-way download: pull all matching files from the server.
- **Upload now** – One-way upload: push all local files in the download folder to the server. Skips files that already exist on the server.
- **Two-way sync** – Bidirectional sync with etag- and size-based change detection:
  - Downloads files added or changed on the server.
  - Uploads files added or changed locally.
  - Skips transfers when the remote and local file sizes match (avoids redundant network I/O).
  - Prompts for each conflict (both sides changed) – keep server copy, keep local copy, or skip.
  - Prompts when files disappear from the server – remove local copies or keep them.
  - Maintains a per-server cache of sync state so only real changes are transferred on subsequent runs.

## Installation

1. Download or clone this repo so the folder is named `webdav-autosync.koplugin`.
2. Copy the whole `webdav-autosync.koplugin` folder into your KOReader plugins directory (e.g. `koreader/plugins/`).
3. Restart KOReader; the plugin appears in the main menu as **WebDAV Sync**.

## Usage

1. Open the main menu → **WebDAV Sync**.
2. **WebDAV server** – Set your WebDAV base URL (e.g. `https://example.com/webdav`).
   - Or tap **Import from KOReader cloud storage** to fill in URL and credentials from KOReader's existing cloud configuration.
3. **Set credentials (optional)** – Username and password if the server requires auth.
4. **Choose download folder** – Opens the file browser; navigate to a folder and long-press to select it.
5. **Set file extensions (optional)** – Comma- or space-separated list. Leave empty to sync all KOReader-supported formats.
6. Choose a sync mode from the menu:
   - **Auto sync on startup** – Toggle automatic one-way download on KOReader start.
   - **Sync now** – Download all matching files from the server.
   - **Two-way sync** – Bidirectional sync with conflict and deletion dialogs.
   - **Upload now** – Upload all local files to the server.

Syncs are recursive: subfolders on the server are mirrored under the local download folder.

## Requirements

- KOReader with LuaSocket (and HTTPS support for `https://` URLs).
- A WebDAV server that supports PROPFIND, GET, PUT, MKCOL, and DELETE.

## Files

- `_meta.lua` – Plugin manifest.
- `main.lua` – Entry point, menu, settings, WiFi check, auto sync.
- `webdav.lua` – WebDAV client (PROPFIND, GET, PUT, MKCOL, DELETE, Basic auth, ETag parsing).
- `sync.lua` – Sync logic: one-way download, one-way upload, two-way diff and cache.
- `runner.lua` – Two-way sync orchestrator: async action loop, conflict dialogs, deletion dialogs.
- `epub_metadata.lua` – EPUB metadata helpers.

## License

MIT.
