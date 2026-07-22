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
            else
                count_fail = count_fail + 1
                local filename = rel:match("([^/]+)$") or rel
                table.insert(failed_files, filename .. " (" .. tostring(msg) .. ")")
            end
        end
    end

    logger.info(LOG .. "run_upload done: uploaded=" .. count_ok .. " skipped=" .. count_skipped .. " failed=" .. count_fail)
    if count_fail > 0 then
        return count_ok, count_fail, tostring(count_fail) .. " file(s) failed:\n" .. table.concat(failed_files, "\n")
    end
    return count_ok, count_skipped, nil
end

return {
    run_sync = run_sync,
    run_upload = run_upload,
    KOREADER_DEFAULT_EXTENSIONS = KOREADER_DEFAULT_EXTENSIONS,
}
