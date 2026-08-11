--[[--
WebDAV client for KOReader plugin.
Uses PROPFIND to list files and GET to download.
Matches KOReader's apps/cloudstorage/webdavapi.lua: socket.http, user/password in request table.
--]]--

local ltn12 = require("ltn12")
local socket = require("socket")
local http = require("socket.http")
local logger = require("logger")
-- Use KOReader's socketutil for timeouts (same as WebDavApi)
local socketutil
local ok_su = pcall(function() socketutil = require("socketutil") end)
if not ok_su or not socketutil then socketutil = false end

local LOG = "[webdav-autosync] "

--- URL encode a string (encode spaces and special characters)
local function url_encode(str)
    if not str then return "" end
    str = str:gsub("([^%w%-%.%_%~%/:])", function(c)
        return string.format("%%%02X", string.byte(c))
    end)
    return str
end

local function normalize_url(url)
    if not url or type(url) ~= "string" then return "" end
    url = url:gsub("^%s+", ""):gsub("%s+$", ""):gsub("/*$", "")
    if url == "" then return "" end
    if not url:match("^https?://") then
        url = "https://" .. url
    end
    return url
end

--- Return true if URL has a non-empty host (e.g. https://host/path -> true).
local function url_has_host(url)
    local u = normalize_url(url)
    if u == "" then return false end
    local host = u:match("^https?://([^/%s]+)")
    return host and host ~= ""
end

-- RFC 1123 date parser for getlastmodified ("Wed, 31 Oct 2025 12:34:56 GMT").
local MONTHS = {
    Jan=1, Feb=2, Mar=3, Apr=4, May=5, Jun=6,
    Jul=7, Aug=8, Sep=9, Oct=10, Nov=11, Dec=12,
}
-- Compute local-vs-UTC offset once at module load so mtime values are
-- true UTC epoch seconds regardless of the device's timezone.
local TZ_OFFSET = (function()
    local now = os.time()
    if not now then return 0 end
    local utc_table = os.date("!*t", now)
    if type(utc_table) ~= "table" then return 0 end
    utc_table.isdst = false
    local local_interp = os.time(utc_table)
    if not local_interp then return 0 end
    -- Both values are integers (os.time resolution is 1 s); plain subtraction is exact.
    return local_interp - now
end)()

local function parse_http_date(s)
    if not s or type(s) ~= "string" then return nil end
    local day, mon, year, hour, minute, sec =
        s:match("(%d+)%s+(%a+)%s+(%d+)%s+(%d+):(%d+):(%d+)")
    if not day then return nil end
    local m = MONTHS[mon]
    if not m then return nil end
    local ok, t = pcall(os.time, {
        year = tonumber(year), month = m, day = tonumber(day),
        hour = tonumber(hour), min = tonumber(minute), sec = tonumber(sec),
        isdst = false,
    })
    if ok and type(t) == "number" then return t - TZ_OFFSET end
    return nil
end

--- Parse PROPFIND XML response. Returns list of
--- { href, href_raw, is_collection, path, etag, mtime, size }.
--- href     = decoded URL (for local-path comparisons)
--- href_raw = wire-format (percent-encoded, safe to use directly as a request URL)
--- etag     = ETag value with surrounding quotes stripped, or nil
--- mtime    = UTC epoch seconds from getlastmodified, or nil
--- size     = content length in bytes, or nil
local function parse_propfind_response(body)
    local list = {}
    for block in (body or ""):gmatch("<[^:]*:response[^>]*>.-</[^:]*:response>") do
        local href_raw = block:match("<[^:]*:href[^>]*>([^<]+)</[^:]*:href>")
        if href_raw then
            -- Decode XML entities then percent-encoding for local comparisons.
            local href = href_raw
                :gsub("&amp;", "&"):gsub("&lt;", "<"):gsub("&gt;", ">")
                :gsub("&apos;", "'"):gsub("&quot;", '"')
                :gsub("%%(%x%x)", function(x) return string.char(tonumber(x, 16)) end)
            local is_collection = not not block:match("<[^:]*:collection[^/]*/>")
            local path = href
            if path:match("^https?://") then
                path = path:gsub("^https?://[^/]+", "")
            end
            path = path:gsub("^/+", ""):gsub("/+$", "")
            if path == "" then path = "/" end
            -- etag: strip surrounding double-quotes that the spec requires
            local etag = block:match("<[^:]*:getetag[^>]*>([^<]+)</[^:]*:getetag>")
            if etag then etag = etag:gsub('^%s*"', ''):gsub('"%s*$', '') end
            local lastmod = block:match(
                "<[^:]*:getlastmodified[^>]*>([^<]+)</[^:]*:getlastmodified>")
            local mtime = parse_http_date(lastmod)
            local size_str = block:match(
                "<[^:]*:getcontentlength[^>]*>([^<]+)</[^:]*:getcontentlength>")
            local size = size_str and tonumber(size_str) or nil
            table.insert(list, {
                href = href,
                href_raw = href_raw,
                is_collection = is_collection,
                path = path,
                etag = etag,
                mtime = mtime,
                size = size,
            })
        end
    end
    return list
end

-- Request getetag + getcontentlength in addition to resourcetype/getlastmodified
-- so two-way sync can use etag/mtime for change detection without extra requests.
local PROPFIND_BODY = '<?xml version="1.0"?>' ..
    '<a:propfind xmlns:a="DAV:">' ..
        '<a:prop>' ..
            '<a:resourcetype/>' ..
            '<a:getcontentlength/>' ..
            '<a:getetag/>' ..
            '<a:getlastmodified/>' ..
        '</a:prop>' ..
    '</a:propfind>'

--- List a WebDAV URL (single level).
--- silent=true suppresses warning logs on failure (used for probing Depth:infinity).
local function list_one(url, username, password, depth, silent)
    url = url_encode(normalize_url(url))
    if not url_has_host(url) then
        return nil, nil, "host or service not provided, or not known"
    end
    if url:sub(-1) ~= "/" then url = url .. "/" end
    depth = depth or "1"
    logger.info(LOG .. "PROPFIND url=" .. url .. " depth=" .. depth)
    local body = {}
    local request = {
        url = url,
        method = "PROPFIND",
        headers = {
            ["Content-Type"] = "application/xml",
            ["Content-Length"] = #PROPFIND_BODY,
            ["Depth"] = depth,
        },
        source = ltn12.source.string(PROPFIND_BODY),
        sink = ltn12.sink.table(body),
        user = (username and username ~= "") and username or nil,
        password = (password and password ~= "") and password or nil,
    }
    if socketutil and socketutil.set_timeout then socketutil:set_timeout() end
    local code, resp_headers, status = socket.skip(1, http.request(request))
    if socketutil and socketutil.reset_timeout then socketutil:reset_timeout() end
    local body_str = table.concat(body)
    if type(code) ~= "number" or code < 200 or code > 299 then
        if not silent then
            logger.warn(LOG .. "PROPFIND failed: code=" .. tostring(code)
                .. " status=" .. tostring(status))
            logger.warn(LOG .. "PROPFIND response body=" .. tostring(body_str))
            if resp_headers then
                for k, v in pairs(resp_headers) do
                    logger.warn(LOG .. "PROPFIND resp header: " .. tostring(k) .. "=" .. tostring(v))
                end
            end
        end
        return nil, code or status, body_str or tostring(status)
    end
    logger.info(LOG .. "PROPFIND ok: code=" .. tostring(code) .. " response_len=" .. #body_str)
    return parse_propfind_response(body_str), code
end

-- Per-host memo of servers that refused Depth:infinity so we skip the
-- probe on subsequent syncs within the same process.
local infinity_unsupported = {}

--- Collect all entries under base_url. Tries Depth:infinity first (single
--- request); falls back to recursive Depth:1 if the server rejects it.
--- Returns flat list of { href, href_raw, is_collection, path, href_full,
--- etag, mtime } for all resources.
local function list_all(base_url, username, password)
    base_url = normalize_url(base_url)
    local base_domain = base_url:match("^(https?://[^/]+)") or ""
    local root_path = base_url:gsub("^https?://[^/]+", ""):gsub("^/+", ""):gsub("/+$", "")

    local function make_href_full(e)
        if e.href:match("^https?://") then return e.href end
        return base_domain ~= "" and (base_domain .. e.href:gsub("^/+", "/")) or e.href
    end

    local function filter_entries(list, self_path)
        local out = {}
        for _, e in ipairs(list) do
            local norm = (e.path or ""):gsub("^/+", ""):gsub("/+$", "")
            if norm ~= self_path and norm ~= "" then
                e.href_full = make_href_full(e)
                table.insert(out, e)
            end
        end
        return out
    end

    -- Fast path: single Depth:infinity request
    if base_domain ~= "" and not infinity_unsupported[base_domain] then
        local inf_list, code = list_one(base_url, username, password, "infinity", true)
        if inf_list then
            logger.info(LOG .. "list_all: Depth:infinity ok, " .. #inf_list .. " entries")
            return filter_entries(inf_list, root_path)
        end
        if type(code) == "number" and (code >= 400 or code == 501) then
            logger.info(LOG .. "list_all: Depth:infinity refused status=" .. tostring(code)
                .. " host=" .. base_domain .. " — falling back to recursive Depth:1")
            infinity_unsupported[base_domain] = true
        else
            logger.info(LOG .. "list_all: Depth:infinity failed, trying recursive")
        end
    end

    -- Fallback: recursive Depth:1
    local all = {}
    local function recurse(url)
        -- list_one encodes the URL internally, so pass decoded href_full here.
        local list, code, err = list_one(url, username, password, "1")
        if not list then return nil, code, err end
        local url_path = url:gsub("^https?://[^/]+", ""):gsub("^/+", ""):gsub("/+$", "")
        for _, e in ipairs(list) do
            local norm = (e.path or ""):gsub("^/+", ""):gsub("/+$", "")
            if norm ~= url_path and norm ~= "" then
                e.href_full = make_href_full(e)
                table.insert(all, e)
                if e.is_collection then
                    local ok, c, m = recurse(e.href_full)
                    if not ok then return nil, c, m end
                end
            end
        end
        return true
    end
    local ok, c, m = recurse(base_url)
    if not ok then return nil, c, m end
    return all
end

--- Download one file from WebDAV URL to local path. Creates parent dirs.
--- Returns true, or nil, error_message.
local function download_file(remote_url, local_path, username, password)
    local url = url_encode(normalize_url(remote_url))
    logger.dbg(LOG .. "GET " .. url .. " -> " .. tostring(local_path))
    local body = {}
    local request = {
        url = url,
        method = "GET",
        sink = ltn12.sink.table(body),
        user = (username and username ~= "") and username or nil,
        password = (password and password ~= "") and password or nil,
    }
    if socketutil and socketutil.set_timeout then
        socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
    end
    local code = socket.skip(1, http.request(request))
    if socketutil and socketutil.reset_timeout then socketutil:reset_timeout() end
    if type(code) ~= "number" or code ~= 200 then
        logger.warn(LOG .. "GET failed: code=" .. tostring(code) .. " url=" .. url)
        return nil, "HTTP " .. tostring(code)
    end
    local lpath = local_path
    if not lpath:match("^/") then
        local ok, DataStorage = pcall(require, "datastorage")
        if ok and DataStorage and DataStorage.getRealPath then
            lpath = DataStorage:getRealPath(local_path)
        end
    end
    local dir = lpath:match("^(.+)/[^/]+$")
    if dir then
        local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
        if not ok_lfs then ok_lfs, lfs = pcall(require, "lfs") end
        if ok_lfs and lfs and lfs.mkdir then
            local prefix = lpath:match("^/") and "/" or ""
            local current = prefix
            for part in dir:gmatch("[^/]+") do
                current = current .. part
                lfs.mkdir(current)
                current = current .. "/"
            end
        end
    end
    local f, err = io.open(lpath, "wb")
    if not f then
        logger.err(LOG .. "download_file: cannot write " .. tostring(lpath) .. ": " .. tostring(err))
        return nil, err
    end
    for _, chunk in ipairs(body) do f:write(chunk) end
    f:close()
    return true
end

--- Create a collection (directory) on WebDAV.
--- 405 = already exists, treated as success. Returns true or nil, error_message.
local function mkcol(url, username, password)
    url = url_encode(normalize_url(url))
    if url:sub(-1) ~= "/" then url = url .. "/" end
    logger.dbg(LOG .. "MKCOL " .. url)
    local request = {
        url = url,
        method = "MKCOL",
        headers = { ["Connection"] = "close" },
        sink = ltn12.sink.table({}),
        user = (username and username ~= "") and username or nil,
        password = (password and password ~= "") and password or nil,
    }
    local code = socket.skip(1, http.request(request))
    logger.dbg(LOG .. "MKCOL response: code=" .. tostring(code))
    if type(code) == "number" and ((code >= 200 and code < 300) or code == 405) then
        return true
    end
    logger.warn(LOG .. "MKCOL unexpected code=" .. tostring(code) .. " url=" .. url)
    return nil, "HTTP " .. tostring(code)
end

--- Ensure every parent collection of rel_path exists under server_url.
--- Idempotent: 405 (already exists) is treated as success.
local function ensure_remote_dirs(server_url, rel_path, username, password)
    if not rel_path or rel_path == "" then return true end
    local parts = {}
    for segment in rel_path:gsub("/+$", ""):gmatch("[^/]+") do
        table.insert(parts, segment)
    end
    if #parts < 2 then return true end
    local base = normalize_url(server_url):gsub("/+$", "")
    local accum = base
    for i = 1, #parts - 1 do
        accum = accum .. "/" .. parts[i]
        local ok, err = mkcol(accum, username, password)
        if not ok then return nil, err end
    end
    return true
end

--- Upload one local file via PUT. Returns true, etag_or_nil on success,
--- or nil, error_message on failure.
local function upload_file(remote_url, local_path, username, password)
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs then ok_lfs, lfs = pcall(require, "lfs") end
    local file_size = 0
    if ok_lfs and lfs then
        local attr = lfs.attributes(local_path)
        if attr then file_size = attr.size or 0 end
    end
    local f, err = io.open(local_path, "rb")
    if not f then
        logger.err(LOG .. "upload_file: cannot open " .. tostring(local_path) .. ": " .. tostring(err))
        return nil, "Cannot open: " .. tostring(err)
    end
    local url = url_encode(normalize_url(remote_url))
    logger.dbg(LOG .. "PUT " .. url .. " size=" .. tostring(file_size))
    local resp_body = {}
    local request = {
        url = url,
        method = "PUT",
        headers = {
            ["Content-Length"] = file_size,
            ["Content-Type"] = "application/octet-stream",
            ["Connection"] = "close",
        },
        source = ltn12.source.file(f),
        sink = ltn12.sink.table(resp_body),
        user = (username and username ~= "") and username or nil,
        password = (password and password ~= "") and password or nil,
    }
    if socketutil and socketutil.set_timeout then
        socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
    end
    local code, resp_headers = socket.skip(1, http.request(request))
    if socketutil and socketutil.reset_timeout then socketutil:reset_timeout() end
    pcall(f.close, f)
    if type(code) ~= "number" or code < 200 or code > 299 then
        logger.warn(LOG .. "PUT failed: code=" .. tostring(code) .. " url=" .. url)
        return nil, "HTTP " .. tostring(code)
    end
    logger.dbg(LOG .. "PUT ok: code=" .. tostring(code))
    local etag = resp_headers and (resp_headers.etag or resp_headers.ETag)
    if etag then etag = etag:gsub('^%s*"', ''):gsub('"%s*$', '') end
    return true, etag
end

--- Fetch a single resource's WebDAV properties (Depth:0). Returns the first
--- entry from parse_propfind_response (with etag + mtime), or nil, error.
--- Used after a PUT to re-read the server's canonical etag/mtime so the
--- cache reflects what the next PROPFIND will return.
local function get_props(url, username, password)
    url = url_encode(normalize_url(url))
    if not url_has_host(url) then return nil, "no host" end
    logger.dbg(LOG .. "PROPFIND depth=0 " .. url)
    local body = {}
    local request = {
        url = url,
        method = "PROPFIND",
        headers = {
            ["Content-Type"] = "application/xml",
            ["Content-Length"] = #PROPFIND_BODY,
            ["Depth"] = "0",
        },
        source = ltn12.source.string(PROPFIND_BODY),
        sink = ltn12.sink.table(body),
        user = (username and username ~= "") and username or nil,
        password = (password and password ~= "") and password or nil,
    }
    if socketutil and socketutil.set_timeout then socketutil:set_timeout() end
    local code = socket.skip(1, http.request(request))
    if socketutil and socketutil.reset_timeout then socketutil:reset_timeout() end
    if type(code) ~= "number" or code < 200 or code > 299 then
        return nil, "HTTP " .. tostring(code)
    end
    local list = parse_propfind_response(table.concat(body))
    return list[1]
end

--- DELETE a WebDAV resource. Returns true on success (including 404 = already
--- gone). Returns nil, error_message otherwise.
local function delete(remote_url, username, password)
    local url = url_encode(normalize_url(remote_url))
    logger.dbg(LOG .. "DELETE " .. url)
    local request = {
        url = url,
        method = "DELETE",
        sink = ltn12.sink.table({}),
        user = (username and username ~= "") and username or nil,
        password = (password and password ~= "") and password or nil,
    }
    local code = socket.skip(1, http.request(request))
    logger.dbg(LOG .. "DELETE response: code=" .. tostring(code))
    if type(code) == "number" and ((code >= 200 and code < 300) or code == 404) then
        return true
    end
    return nil, "HTTP " .. tostring(code)
end

return {
    normalize_url = normalize_url,
    url_has_host = url_has_host,
    url_encode = url_encode,
    parse_http_date = parse_http_date,
    list_one = list_one,
    list_all = list_all,
    download_file = download_file,
    mkcol = mkcol,
    ensure_remote_dirs = ensure_remote_dirs,
    upload_file = upload_file,
    get_props = get_props,
    delete = delete,
}
