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

--- Parse PROPFIND XML response into list of { href, is_collection, path }.
--- Accept any namespace prefix like WebDavApi (<*:response>, <*:href>, etc.).
local function parse_propfind_response(body, base_url)
    local base = base_url:gsub("^https?://[^/]+", ""):gsub("/*$", "") .. "/"
    local list = {}
    for block in (body or ""):gmatch("<[^:]*:response[^>]*>.-</[^:]*:response>") do
        local href = block:match("<[^:]*:href[^>]*>([^<]+)</[^:]*:href>")
        if href then
            -- Decode XML entities before percent-decoding
            href = href:gsub("&amp;", "&"):gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&apos;", "'"):gsub("&quot;", '"')
            href = href:gsub("%%(%x%x)", function(x) return string.char(tonumber(x, 16)) end)
            local is_collection = not not block:match("<[^:]*:collection[^/]*/>")
            -- Normalize: remove server base and leading slashes for path
            local path = href
            if path:match("^https?://") then
                path = path:gsub("^https?://[^/]+", "")
            end
            path = path:gsub("^/+", ""):gsub("/+$", "")
            if path == "" then path = "/" end
            table.insert(list, {
                href = href,
                is_collection = is_collection,
                path = path,
            })
        end
    end
    return list
end

local PROPFIND_BODY = '<?xml version="1.0"?><a:propfind xmlns:a="DAV:"><a:prop><a:resourcetype/><a:getlastmodified/></a:prop></a:propfind>'

--- List a WebDAV URL (single level). Returns list of { href, is_collection, path }.
--- silent=true suppresses warning logs on failure (used for probing Depth:infinity).
local function list_one(url, username, password, depth, silent)
    url = url_encode(normalize_url(url))
    if not url_has_host(url) then
        return nil, nil, "host or service not provided, or not known"
    end
    -- WebDavApi: "URL *must* have a trailing /" for PROPFIND on collection
    if url:sub(-1) ~= "/" then
        url = url .. "/"
    end
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
    if socketutil and socketutil.set_timeout then
        socketutil:set_timeout()
    end
    local code, resp_headers, status = socket.skip(1, http.request(request))
    if socketutil and socketutil.reset_timeout then
        socketutil:reset_timeout()
    end
    local body_str = table.concat(body)
    if type(code) ~= "number" or code < 200 or code > 299 then
        if not silent then
            logger.warn(LOG .. "PROPFIND failed: code=" .. tostring(code) .. " status=" .. tostring(status))
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
    return parse_propfind_response(body_str, url), code
end

--- Collect all entries under base_url. Tries Depth:infinity first (single request);
--- falls back to recursive Depth:1 if the server rejects it.
--- Returns flat list of { href, is_collection, path, href_full } for all resources.
local function list_all(base_url, username, password)
    base_url = normalize_url(base_url)
    local base_domain = base_url:match("^(https?://[^/]+)")
    local root_path = base_url:gsub("^https?://[^/]+", ""):gsub("^/+", ""):gsub("/+$", "")

    local function make_href_full(e)
        if e.href:match("^https?://") then return e.href end
        return base_domain and (base_domain .. e.href:gsub("^/+", "/")) or e.href
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

    -- Try Depth:infinity (single request, supported by many servers)
    local inf_list = list_one(base_url, username, password, "infinity", true)
    if inf_list then
        logger.info(LOG .. "list_all: Depth:infinity ok, " .. #inf_list .. " entries")
        return filter_entries(inf_list, root_path)
    end

    -- Fall back to recursive Depth:1
    logger.info(LOG .. "list_all: Depth:infinity unsupported, using recursive Depth:1")
    local all = {}
    local function recurse(url)
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
--- Returns true, or nil, error_message. Same request pattern as WebDavApi:downloadFile.
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
    if socketutil and socketutil.reset_timeout then
        socketutil:reset_timeout()
    end
    if type(code) ~= "number" or code ~= 200 then
        logger.warn(LOG .. "GET failed: code=" .. tostring(code) .. " url=" .. url)
        return nil, "HTTP " .. tostring(code)
    end
    -- Use path as-is if absolute, else relative to KOReader data dir
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
            -- Create all parent directories recursively (mkdir -p)
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
    for _, chunk in ipairs(body) do
        f:write(chunk)
    end
    f:close()
    return true
end

--- Create a collection (directory) on WebDAV. Returns true or nil, error_message.
--- 405 Method Not Allowed means the collection already exists — treated as success.
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
    if type(code) == "number" and (code == 201 or code == 405) then
        return true
    end
    logger.warn(LOG .. "MKCOL unexpected code=" .. tostring(code) .. " url=" .. url)
    return nil, "HTTP " .. tostring(code)
end

--- Upload one local file to a WebDAV URL via PUT. Returns true or nil, error_message.
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
    local request = {
        url = url,
        method = "PUT",
        headers = {
            ["Content-Length"] = file_size,
            ["Content-Type"] = "application/octet-stream",
            ["Connection"] = "close",
        },
        source = ltn12.source.file(f),
        sink = ltn12.sink.table({}),
        user = (username and username ~= "") and username or nil,
        password = (password and password ~= "") and password or nil,
    }
    if socketutil and socketutil.set_timeout then
        socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
    end
    local code = socket.skip(1, http.request(request))
    if socketutil and socketutil.reset_timeout then
        socketutil:reset_timeout()
    end
    -- ltn12.source.file only closes on EOF; close explicitly in case of early server response
    pcall(f.close, f)
    if type(code) ~= "number" or code < 200 or code > 299 then
        logger.warn(LOG .. "PUT failed: code=" .. tostring(code) .. " url=" .. url)
        return nil, "HTTP " .. tostring(code)
    end
    logger.dbg(LOG .. "PUT ok: code=" .. tostring(code))
    return true
end

return {
    normalize_url = normalize_url,
    url_has_host = url_has_host,
    list_one = list_one,
    list_all = list_all,
    download_file = download_file,
    mkcol = mkcol,
    upload_file = upload_file,
}
