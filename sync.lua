--[[--
Sync logic: list all files from WebDAV and download to local folder.
--]]--

local webdav = require("webdav")
local epub_metadata = require("epub_metadata")
local logger = require("logger")

local LOG = "[webdav-autosync] "


--- File extensions KOReader supports (default when user leaves filter empty).
local KOREADER_DEFAULT_EXTENSIONS = {
    "epub", "pdf", "djvu", "xps", "cbt", "cbz", "cb7", "fb2", "pdb",
    "txt", "html", "htm", "rtf", "chm", "doc", "mobi", "zip", "md",
}
local KOREADER_DEFAULT_EXTENSIONS_SET = {}
for _, e in ipairs(KOREADER_DEFAULT_EXTENSIONS) do
    KOREADER_DEFAULT_EXTENSIONS_SET[e] = true
end

--- Parse extension filter string (comma/space separated) into lowercase set.
--- Returns nil when str is nil or "" (meaning: use default KOReader formats).
local function parse_extensions(str)
    if not str or str:match("^%s*$") then
        return nil
    end
    local set = {}
    for ext in str:gmatch("[^,%s]+") do
        ext = ext:lower():gsub("^%.", "")
        if ext ~= "" then
            set[ext] = true
        end
    end
    if next(set) == nil then
        return nil
    end
    return set
end

--- Check if path has an extension in the allowed set (or default KOReader set).
local function extension_allowed(path, extensions_set)
    local ext = path:match("%.(%w+)$")
    if not ext then return false end
    ext = ext:lower()
    if extensions_set then
        return extensions_set[ext] == true
    end
    return KOREADER_DEFAULT_EXTENSIONS_SET[ext] == true
end

--- Get base path from WebDAV URL (path part only, no trailing slash).
local function base_path_from_url(url)
    url = webdav.normalize_url(url)
    local path = url:match("^https?://[^/]+(.+)$") or ""
    path = path:gsub("^/+", ""):gsub("/+$", "")
    return path
end

--- Returns true if any component of a relative path starts with ".".
local function is_dotfile(rel)
    for part in rel:gmatch("[^/]+") do
        if part:sub(1, 1) == "." then return true end
    end
    return false
end

--- Run full sync: list all resources, download every file to local_folder.
--- local_folder: path on device (e.g. /mnt/onboard/books or relative path).
--- extensions_filter: optional string (e.g. "epub, pdf"); empty/nil = all KOReader formats.
--- ignore_dotfiles: if true, skip files/folders whose name starts with ".".
--- Returns: count_downloaded, count_skipped, error_message (nil on success).
local function run_sync(server_url, username, password, local_folder, progress_cb, extensions_filter, ignore_dotfiles)
    if not server_url or type(server_url) ~= "string" then
        return 0, 0, "Server URL is not set"
    end
    server_url = server_url:gsub("^%s+", ""):gsub("%s+$", "")
    if server_url == "" then
        return 0, 0, "Server URL is not set"
    end
    if not webdav.url_has_host(server_url) then
        return 0, 0, "Server URL has no host (e.g. use https://example.com/webdav)"
    end
    if not local_folder or local_folder == "" then
        return 0, 0, "Download folder is not set"
    end
    local_folder = local_folder:gsub("/+$", "")
    logger.info(LOG .. "run_sync: url=" .. server_url .. " folder=" .. local_folder)
    local list, code, err = webdav.list_all(server_url, username, password)
    if not list then
        logger.err(LOG .. "run_sync: list_all failed code=" .. tostring(code) .. " err=" .. tostring(err))
        return 0, 0, "List failed: " .. tostring(code) .. " " .. tostring(err)
    end
    logger.info(LOG .. "run_sync: listed " .. #list .. " remote entries")
    local base = base_path_from_url(server_url)
    local extensions_set = parse_extensions(extensions_filter)
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs then ok_lfs, lfs = pcall(require, "lfs") end
    local files = {}
    for _, e in ipairs(list) do
        local rel = (e.path or ""):gsub("^/+", "")
        if base ~= "" and rel:sub(1, #base) == base then
            rel = rel:sub(#base + 1):gsub("^/+", "")
        end
        if not e.is_collection and extension_allowed(rel, extensions_set)
                and not (ignore_dotfiles and is_dotfile(rel)) then
            e._rel = rel  -- cache to avoid recomputing in download loop
            table.insert(files, e)
        end
    end
    local count_ok = 0
    local count_fail = 0
    local count_skipped = 0
    local failed_files = {}
    for i, e in ipairs(files) do
        local remote_url = e.href_full or e.href
        local rel = e._rel
        local local_path = local_folder .. "/" .. rel
        local file_exists = ok_lfs and lfs and lfs.attributes(local_path) ~= nil
        if file_exists then
            count_skipped = count_skipped + 1
        else
            if progress_cb then progress_cb(i, #files, rel) end
            local ok, msg = webdav.download_file(remote_url, local_path, username, password)
            if ok then
                count_ok = count_ok + 1
                -- For EPUB files, try to rename based on metadata title
                local ext = local_path:match("%.([^%.]+)$")
                if ext and ext:lower() == "epub" then
                    local title = epub_metadata.extract_title(local_path)
                    if title and title ~= "" then
                        local dir = local_path:match("^(.+)/[^/]+$") or local_folder
                        local new_path = dir .. "/" .. title .. ".epub"
                        -- Rename file (this will overwrite if duplicate exists)
                        local rename_ok = os.rename(local_path, new_path)
                        if not rename_ok then
                            -- If rename fails, try using io operations
                            local old_f = io.open(local_path, "rb")
                            local new_f = io.open(new_path, "wb")
                            if old_f and new_f then
                                new_f:write(old_f:read("*a"))
                                old_f:close()
                                new_f:close()
                                os.remove(local_path)
                            end
                        end
                    end
                end
            else
                count_fail = count_fail + 1
                -- Get just the filename for cleaner error messages
                local filename = rel:match("([^/]+)$") or rel
                table.insert(failed_files, filename .. " (" .. tostring(msg) .. ")")
            end
        end
    end
    logger.info(LOG .. "run_sync done: downloaded=" .. count_ok .. " skipped=" .. count_skipped .. " failed=" .. count_fail)
    if (tonumber(count_fail) or 0) > 0 then
        local error_msg = tostring(count_fail) .. " file(s) failed:\n" .. table.concat(failed_files, "\n")
        return count_ok, count_fail, error_msg
    end
    return count_ok, count_skipped, nil
end

--- Recursively scan local_folder for files matching extensions_set.
--- Returns a list of relative paths (e.g. "subdir/book.epub"), or nil, err.
local function scan_local_files(folder, extensions_set, ignore_dotfiles)
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs then ok_lfs, lfs = pcall(require, "lfs") end
    if not ok_lfs or not lfs then
        logger.err(LOG .. "scan_local_files: lfs not available")
        return nil, "lfs not available"
    end
    logger.dbg(LOG .. "scan_local_files: scanning " .. tostring(folder))
    local files = {}
    local function scan(dir, prefix)
        local ok_iter, iter, state = pcall(lfs.dir, dir)
        if not ok_iter or not iter then
            logger.warn(LOG .. "scan_local_files: cannot open dir " .. tostring(dir) .. " iter=" .. tostring(iter) .. " ok=" .. tostring(ok_iter))
            return
        end
        for entry in iter, state do
            if entry ~= "." and entry ~= ".." then
                if ignore_dotfiles and entry:sub(1, 1) == "." then
                    -- skip dotfiles and dot-directories entirely
                else
                    local full = dir .. "/" .. entry
                    local rel = prefix == "" and entry or (prefix .. "/" .. entry)
                    local attr = lfs.attributes(full)
                    if attr then
                        if attr.mode == "directory" then
                            scan(full, rel)
                        elseif attr.mode == "file" and extension_allowed(entry, extensions_set) then
                            table.insert(files, rel)
                        end
                    end
                end
            end
        end
    end
    scan(folder, "")
    logger.info(LOG .. "scan_local_files: found " .. #files .. " files in " .. tostring(folder))
    return files
end

--- Upload local files to WebDAV. Skips files already present on the server.
--- ignore_dotfiles: if true, skip files/folders whose name starts with ".".
--- Returns: count_uploaded, count_skipped, error_message (nil on success).
local function run_upload(server_url, username, password, local_folder, progress_cb, extensions_filter, ignore_dotfiles)
    if not server_url or type(server_url) ~= "string" then
        return 0, 0, "Server URL is not set"
    end
    server_url = server_url:gsub("^%s+", ""):gsub("%s+$", "")
    if server_url == "" then
        return 0, 0, "Server URL is not set"
    end
    if not webdav.url_has_host(server_url) then
        return 0, 0, "Server URL has no host (e.g. use https://example.com/webdav)"
    end
    if not local_folder or local_folder == "" then
        return 0, 0, "Download folder is not set"
    end
    local_folder = local_folder:gsub("/+$", "")

    logger.info(LOG .. "run_upload: url=" .. server_url .. " folder=" .. local_folder)
    local extensions_set = parse_extensions(extensions_filter)
    local local_files, scan_err = scan_local_files(local_folder, extensions_set, ignore_dotfiles)
    if not local_files then
        return 0, 0, "Local scan failed: " .. tostring(scan_err)
    end
    if #local_files == 0 then
        logger.info(LOG .. "run_upload: no local files to upload")
        return 0, 0, nil
    end

    local base = base_path_from_url(server_url)
    local base_url = webdav.normalize_url(server_url)
    local remote_set = {}
    local remote_dirs = {}
    local list = webdav.list_all(server_url, username, password)
    if list then
        logger.info(LOG .. "run_upload: listed " .. #list .. " remote entries")
        for _, e in ipairs(list) do
            local rel = e.path:gsub("^/+", "")
            if base ~= "" and rel:sub(1, #base) == base then
                rel = rel:sub(#base + 1):gsub("^/+", "")
            end
            rel = rel:gsub("/+$", "")
            if e.is_collection then
                remote_dirs[rel] = true
            else
                remote_set[rel] = true
            end
        end
    else
        logger.warn(LOG .. "run_upload: list_all failed, uploading all local files without skip check")
    end
    -- If listing fails, remote_set/remote_dirs stay empty and we upload everything;
    -- PUT is idempotent so overwriting is safe, MKCOL on existing dirs returns 405 (ok).

    local count_ok = 0
    local count_skipped = 0
    local count_fail = 0
    local failed_files = {}
    local created_dirs = {}
    local uploaded_rels = {}

    for i, rel in ipairs(local_files) do
        if remote_set[rel] then
            count_skipped = count_skipped + 1
        else
            if progress_cb then progress_cb(i, #local_files, rel) end

            -- Ensure each parent collection exists on the server
            local dir_rel = rel:match("^(.+)/[^/]+$")
            if dir_rel then
                local path_acc = ""
                for part in dir_rel:gmatch("[^/]+") do
                    path_acc = path_acc == "" and part or (path_acc .. "/" .. part)
                    if not created_dirs[path_acc] and not remote_dirs[path_acc] then
                        webdav.mkcol(base_url .. "/" .. path_acc, username, password)
                    end
                    created_dirs[path_acc] = true
                end
            end

            local local_path = local_folder .. "/" .. rel
            local remote_url = base_url .. "/" .. rel
            local ok, msg = webdav.upload_file(remote_url, local_path, username, password)
            if ok then
                count_ok = count_ok + 1
                table.insert(uploaded_rels, rel)
            else
                count_fail = count_fail + 1
                local filename = rel:match("([^/]+)$") or rel
                table.insert(failed_files, filename .. " (" .. tostring(msg) .. ")")
            end
        end
    end

    -- Invalidate two-way cache entries for uploaded files. A PUT creates a new
    -- server-side etag; without invalidation the next two-way sync would see a
    -- stale cached etag, treat the file as "remote changed", and re-download it.
    -- Removing the entry causes two-way sync to re-seed it on the next run
    -- (both sides present, no cache → seed baseline, no download).
    if #uploaded_rels > 0 then
        local cs, cf = open_cache(server_url, local_folder)
        if cs and cf then
            for _, rel in ipairs(uploaded_rels) do
                cf[rel] = nil
            end
            cs:saveSetting("files", cf)
            cs:flush()
        end
    end

    logger.info(LOG .. "run_upload done: uploaded=" .. count_ok .. " skipped=" .. count_skipped .. " failed=" .. count_fail)
    if count_fail > 0 then
        return count_ok, count_fail, tostring(count_fail) .. " file(s) failed:\n" .. table.concat(failed_files, "\n")
    end
    return count_ok, count_skipped, nil
end

-- ============================================================
-- Two-way sync: cache, plan, diff, execute
-- ============================================================

-- Forward declaration so run_upload (defined above) can call open_cache
-- (defined below). Lua closures capture the variable slot, not the value,
-- so the assignment below fills this in before any caller can reach it.
local open_cache

local _LuaSettings
local _DataStorage

local function get_settings_modules()
    if not _LuaSettings then
        local ok, m = pcall(require, "luasettings")
        if ok then _LuaSettings = m end
    end
    if not _DataStorage then
        local ok, m = pcall(require, "datastorage")
        if ok then _DataStorage = m end
    end
    return _LuaSettings, _DataStorage
end

local function load_lfs()
    local ok, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok then ok, lfs = pcall(require, "lfs") end
    if ok then return lfs end
    return nil
end

--- Reject relative paths that could escape the local folder.
local function rel_is_safe(rel)
    if not rel or rel == "" then return false end
    if rel:match("^/") or rel:match("%z") then return false end
    for part in rel:gmatch("[^/]+") do
        if part == ".." then return false end
    end
    return true
end

--- Recursive walk of folder, calling predicate(rel) for each file.
--- Returns list of { rel, path, mtime, size } or nil, error.
local function walk_local(folder, predicate)
    local lfs = load_lfs()
    if not lfs then return nil, "lfs not available" end
    local results = {}
    local function scan(dir, prefix)
        local ok_iter, iter, state = pcall(lfs.dir, dir)
        if not ok_iter or not iter then return end
        for entry in iter, state do
            if entry ~= "." and entry ~= ".." then
                local rel = prefix == "" and entry or (prefix .. "/" .. entry)
                local full = dir .. "/" .. entry
                local attr = lfs.attributes(full)
                if attr then
                    if attr.mode == "directory" then
                        scan(full, rel)
                    elseif attr.mode == "file" and predicate(rel) then
                        table.insert(results, {
                            rel  = rel,
                            path = full,
                            mtime = attr.modification or 0,
                            size  = attr.size or 0,
                        })
                    end
                end
            end
        end
    end
    scan(folder, "")
    return results
end

--- Walk local folder filtered by extensions and dotfile setting.
local function walk_local_files(folder, extensions_set, ignore_dotfiles)
    return walk_local(folder, function(rel)
        if ignore_dotfiles and is_dotfile(rel) then return false end
        return extension_allowed(rel, extensions_set)
    end)
end

--- True if remote resource differs from last-known state in the cache.
local function remote_changed(remote, cached)
    if not cached then return true end
    if remote.etag and cached.remote_etag then
        return remote.etag ~= cached.remote_etag
    end
    if remote.mtime and cached.remote_mtime then
        return math.abs((remote.mtime or 0) - (cached.remote_mtime or 0)) > 1
    end
    return true
end

--- True if local file differs from last-known state in the cache.
local function local_changed(loc, cached)
    if not cached then return true end
    if (loc.size or 0) ~= (cached.local_size or 0) then return true end
    return math.abs((loc.mtime or 0) - (cached.local_mtime or 0)) > 2
end

--- Build remote index: rel → { href, etag, mtime } for non-collection entries.
local function build_remote_index(list, base, server_url)
    local origin = webdav.normalize_url(server_url):gsub("/+$", "")
    local index = {}
    for _, e in ipairs(list) do
        if not e.is_collection then
            local rel = (e.path or ""):gsub("^/+", "")
            if base ~= "" and rel:sub(1, #base) == base then
                rel = rel:sub(#base + 1):gsub("^/+", "")
            end
            rel = rel:gsub("/+$", "")
            if rel ~= "" and rel_is_safe(rel) then
                local href = e.href_full or e.href
                if not href:match("^https?://") then
                    href = origin .. (href:gsub("^/*", "/"))
                end
                index[rel] = { href = href, etag = e.etag, mtime = e.mtime }
            end
        end
    end
    return index
end

--- Derive a stable, filesystem-safe cache key from server_url + local_folder.
local function make_cache_key(server_url, local_folder)
    local s = (server_url or ""):gsub("[^%w%-]", "_"):sub(1, 40)
    local l = (local_folder or ""):gsub("[^%w%-]", "_"):sub(1, 40)
    return s .. "__" .. l
end

--- Open (or create) the LuaSettings cache file for this server+folder pair.
--- Returns settings_obj, files_table  or  nil, nil, error_message.
open_cache = function(server_url, local_folder)
    local LS, DS = get_settings_modules()
    if not LS or not DS then
        return nil, nil, "LuaSettings/DataStorage not available"
    end
    local cache_dir = DS:getDataDir() .. "/cache"
    local lfs = load_lfs()
    if lfs then lfs.mkdir(cache_dir) end
    local key = make_cache_key(server_url, local_folder)
    local cache_path = cache_dir .. "/webdav_autosync_" .. key .. ".lua"
    local ok_s, settings = pcall(LS.open, LS, cache_path)
    if not ok_s or not settings then
        return nil, nil, "Cannot open cache: " .. tostring(settings)
    end
    local files = settings:readSetting("files") or {}
    return settings, files
end

--- Produce action lists by comparing remote/local indexes against cache.
--- Mutates cache_files in place (drops entries gone from both sides).
--- Returns { to_download, to_upload, conflicts, deletions }.
local function diff_indices(remote_index, local_index, cache_files)
    local to_download = {}
    local to_upload   = {}
    local conflicts   = {}
    local deletions   = {}
    local seen_rel    = {}

    logger.dbg(LOG .. "diff_indices: remote=" .. tostring(#(function() local t={} for k in pairs(remote_index) do t[#t+1]=k end return t end)())
        .. " local=" .. tostring(#(function() local t={} for k in pairs(local_index) do t[#t+1]=k end return t end)())
        .. " cached=" .. tostring(#(function() local t={} for k in pairs(cache_files) do t[#t+1]=k end return t end)()))

    -- Process everything present on the remote.
    for rel, remote in pairs(remote_index) do
        seen_rel[rel] = true
        local cached   = cache_files[rel]
        local loc      = local_index[rel]
        local r_chg    = remote_changed(remote, cached)
        local l_chg    = loc and local_changed(loc, cached) or false

        if not cached then
            if loc then
                -- Both sides have the file but no cache baseline yet (first run).
                -- Assume in sync; seed the cache so future runs detect real changes.
                logger.dbg(LOG .. "diff seed (no cache, both sides): " .. rel)
                cache_files[rel] = {
                    remote_etag  = remote.etag,
                    remote_mtime = remote.mtime,
                    local_mtime  = loc.mtime,
                    local_size   = loc.size,
                }
            else
                -- File only on remote, never seen locally: download.
                logger.dbg(LOG .. "diff download (no cache, remote only): " .. rel)
                table.insert(to_download, { rel = rel, remote = remote })
            end
        elseif r_chg and l_chg then
            logger.dbg(LOG .. "diff conflict (both changed): " .. rel
                .. " r_etag=" .. tostring(remote.etag) .. " c_r_etag=" .. tostring(cached.remote_etag)
                .. " r_mtime=" .. tostring(remote.mtime) .. " c_r_mtime=" .. tostring(cached.remote_mtime)
                .. " loc_size=" .. tostring(loc and loc.size) .. " c_loc_size=" .. tostring(cached.local_size)
                .. " loc_mtime=" .. tostring(loc and loc.mtime) .. " c_loc_mtime=" .. tostring(cached.local_mtime))
            table.insert(conflicts, { rel = rel, remote = remote, local_file = loc })
        elseif r_chg then
            logger.dbg(LOG .. "diff download (remote changed): " .. rel
                .. " r_etag=" .. tostring(remote.etag) .. " c_r_etag=" .. tostring(cached.remote_etag)
                .. " r_mtime=" .. tostring(remote.mtime) .. " c_r_mtime=" .. tostring(cached.remote_mtime)
                .. " local_in_index=" .. tostring(loc ~= nil))
            table.insert(to_download, { rel = rel, remote = remote })
        elseif l_chg and loc then
            logger.dbg(LOG .. "diff upload (local changed): " .. rel)
            table.insert(to_upload, { rel = rel, local_file = loc })
        else
            logger.dbg(LOG .. "diff skip (unchanged): " .. rel)
        end
    end

    -- Process local files not present on the remote.
    for rel, loc in pairs(local_index) do
        if not seen_rel[rel] then
            local cached = cache_files[rel]
            if not cached then
                -- New local file: upload.
                logger.dbg(LOG .. "diff upload (local only, no cache): " .. rel)
                table.insert(to_upload, { rel = rel, local_file = loc })
            else
                -- Known file vanished from remote: remote deleted it.
                logger.dbg(LOG .. "diff deletion (in local+cache, not remote): " .. rel
                    .. " c_r_etag=" .. tostring(cached.remote_etag)
                    .. " c_r_mtime=" .. tostring(cached.remote_mtime)
                    .. " c_loc_size=" .. tostring(cached.local_size)
                    .. " c_loc_mtime=" .. tostring(cached.local_mtime))
                table.insert(deletions, { rel = rel, side = "remote_deleted", local_file = loc })
            end
        end
    end

    -- Drop cache entries gone from both sides (no action needed, just housekeeping).
    for rel in pairs(cache_files) do
        if not remote_index[rel] and not local_index[rel] then
            cache_files[rel] = nil
        end
    end

    return { to_download=to_download, to_upload=to_upload, conflicts=conflicts, deletions=deletions }
end

--- Build a plan for two-way sync.
--- ctx = { server_url, username, password, local_folder, extensions_filter, ignore_dotfiles }
--- Returns plan_obj or nil, error_message.
local function plan(ctx)
    local server_url = (ctx.server_url or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if server_url == "" then return nil, "Server URL is not set" end
    if not webdav.url_has_host(server_url) then return nil, "Server URL has no host" end
    local local_folder = (ctx.local_folder or ""):gsub("/+$", "")
    if local_folder == "" then return nil, "Download folder is not set" end

    local extensions_set  = parse_extensions(ctx.extensions_filter)
    local ignore_dotfiles = ctx.ignore_dotfiles ~= false
    local base            = base_path_from_url(server_url)

    local remote_list, code, err = webdav.list_all(server_url, ctx.username, ctx.password)
    if not remote_list then
        return nil, "Remote listing failed: " .. tostring(code) .. " " .. tostring(err)
    end

    local remote_index = build_remote_index(remote_list, base, server_url)
    for rel in pairs(remote_index) do
        if not extension_allowed(rel, extensions_set)
                or (ignore_dotfiles and is_dotfile(rel)) then
            remote_index[rel] = nil
        end
    end

    local local_list, scan_err = walk_local_files(local_folder, extensions_set, ignore_dotfiles)
    if not local_list then
        return nil, "Local scan failed: " .. tostring(scan_err)
    end
    local local_index = {}
    for _, f in ipairs(local_list) do
        if rel_is_safe(f.rel) then
            local_index[f.rel] = f
        end
    end

    local cache_settings, cache_files, cache_err = open_cache(server_url, local_folder)
    if not cache_settings then
        logger.warn(LOG .. "plan: cache unavailable (" .. tostring(cache_err) .. ") — treating all as new")
        cache_files = {}
    else
        cache_files = cache_files or {}
        local n = 0; for _ in pairs(cache_files) do n = n + 1 end
        logger.dbg(LOG .. "plan: cache loaded, " .. n .. " entries")
        for rel, c in pairs(cache_files) do
            logger.dbg(LOG .. "  cache[" .. rel .. "] r_etag=" .. tostring(c.remote_etag)
                .. " r_mtime=" .. tostring(c.remote_mtime)
                .. " loc_size=" .. tostring(c.local_size)
                .. " loc_mtime=" .. tostring(c.local_mtime))
        end
    end

    local actions  = diff_indices(remote_index, local_index, cache_files)
    local base_url = webdav.normalize_url(server_url)

    return {
        server_url     = server_url,
        base_url       = base_url,
        username       = ctx.username,
        password       = ctx.password,
        local_folder   = local_folder,
        cache_settings = cache_settings,
        cache_files    = cache_files,
        to_download    = actions.to_download,
        to_upload      = actions.to_upload,
        conflicts      = actions.conflicts,
        deletions      = actions.deletions,
        stats = {
            downloaded=0, uploaded=0,
            deleted_remote=0, deleted_local=0,
            skipped=0, errors=0,
        },
    }
end

--- Execute one action from a plan, updating p.cache_files in place.
--- kind: "download" | "upload" | "delete_remote" | "delete_local"
local function do_action(p, kind, action)
    local rel = action.rel
    local lfs = load_lfs()

    if kind == "download" then
        local remote     = action.remote
        local local_path = p.local_folder .. "/" .. rel
        local ok, err    = webdav.download_file(remote.href, local_path, p.username, p.password)
        if not ok then
            logger.warn(LOG .. "do_action download failed: " .. rel .. ": " .. tostring(err))
            p.stats.errors = p.stats.errors + 1
            return nil, err
        end
        local attr = lfs and lfs.attributes(local_path)
        p.cache_files[rel] = {
            remote_etag  = remote.etag,
            remote_mtime = remote.mtime,
            local_mtime  = attr and attr.modification or 0,
            local_size   = attr and attr.size or 0,
        }
        p.stats.downloaded = p.stats.downloaded + 1
        return true

    elseif kind == "upload" then
        local loc        = action.local_file
        local local_path = loc and loc.path or (p.local_folder .. "/" .. rel)
        local remote_url = p.base_url .. "/" .. rel
        webdav.ensure_remote_dirs(p.server_url, rel, p.username, p.password)
        local ok, etag = webdav.upload_file(remote_url, local_path, p.username, p.password)
        if not ok then
            logger.warn(LOG .. "do_action upload failed: " .. rel .. ": " .. tostring(etag))
            p.stats.errors = p.stats.errors + 1
            return nil, etag
        end
        local props = webdav.get_props(remote_url, p.username, p.password)
        local attr  = lfs and lfs.attributes(local_path)
        p.cache_files[rel] = {
            remote_etag  = (props and props.etag) or etag,
            remote_mtime = props and props.mtime,
            local_mtime  = attr and attr.modification or 0,
            local_size   = attr and attr.size or 0,
        }
        p.stats.uploaded = p.stats.uploaded + 1
        return true

    elseif kind == "delete_remote" then
        local remote = action.remote
        if not remote then return nil, "no remote entry for delete_remote" end
        local ok, err = webdav.delete(remote.href, p.username, p.password)
        if not ok then
            logger.warn(LOG .. "do_action delete_remote failed: " .. rel .. ": " .. tostring(err))
            p.stats.errors = p.stats.errors + 1
            return nil, err
        end
        p.cache_files[rel] = nil
        p.stats.deleted_remote = p.stats.deleted_remote + 1
        return true

    elseif kind == "delete_local" then
        local local_path = p.local_folder .. "/" .. rel
        if not os.remove(local_path) then
            logger.warn(LOG .. "do_action delete_local failed: " .. rel)
            p.stats.errors = p.stats.errors + 1
            return nil, "os.remove failed"
        end
        p.cache_files[rel] = nil
        p.stats.deleted_local = p.stats.deleted_local + 1
        return true
    end

    return nil, "unknown action kind: " .. tostring(kind)
end

--- Flush the in-memory cache back to disk.
local function save_cache(p)
    if not p.cache_settings then return end
    p.cache_settings:saveSetting("files", p.cache_files)
    p.cache_settings:flush()
end

return {
    run_sync   = run_sync,
    run_upload = run_upload,
    plan       = plan,
    do_action  = do_action,
    save_cache = save_cache,
    KOREADER_DEFAULT_EXTENSIONS = KOREADER_DEFAULT_EXTENSIONS,
}
