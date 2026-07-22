--[[--
Two-way sync runner: UI dialogs, action loop, in-flight lock.
--]]--

local UIManager    = require("ui/uimanager")
local InfoMessage  = require("ui/widget/infomessage")
local ButtonDialogTitle = require("ui/widget/buttondialogtitle")
local T = require("ffi/util").template
local _ = require("gettext")
local logger = require("logger")
local sync = require("sync")

local LOG = "[webdav-autosync] "

-- Prevent concurrent sync runs within the same process lifetime.
local sync_in_flight = false

--- Format a summary string from a stats table.
local function format_summary(stats)
    local parts = {}
    if (stats.downloaded or 0) > 0 then
        table.insert(parts, T(_("%1 downloaded"), stats.downloaded))
    end
    if (stats.uploaded or 0) > 0 then
        table.insert(parts, T(_("%1 uploaded"), stats.uploaded))
    end
    if (stats.deleted_remote or 0) > 0 then
        table.insert(parts, T(_("%1 removed from server"), stats.deleted_remote))
    end
    if (stats.deleted_local or 0) > 0 then
        table.insert(parts, T(_("%1 removed locally"), stats.deleted_local))
    end
    if (stats.skipped or 0) > 0 then
        table.insert(parts, T(_("%1 skipped"), stats.skipped))
    end
    if (stats.errors or 0) > 0 then
        table.insert(parts, T(_("%1 error(s)"), stats.errors))
    end
    if #parts == 0 then return _("Nothing to do — already in sync.") end
    return table.concat(parts, ", ") .. "."
end

--- Show the final summary InfoMessage.
local function show_summary(stats, on_done)
    UIManager:show(InfoMessage:new{
        text = _("Two-way sync done. ") .. format_summary(stats),
        dismissable = true,
    })
    if on_done then on_done(stats) end
end

--- Execute all actions in a flat list of the same kind, then call next_fn.
local function run_actions(p, kind, actions, idx, on_done)
    idx = idx or 1
    if idx > #actions then
        if on_done then on_done() end
        return
    end
    local action = actions[idx]
    sync.do_action(p, kind, action)
    -- Schedule next tick so KOReader's event loop stays responsive.
    UIManager:scheduleIn(0, function()
        run_actions(p, kind, actions, idx + 1, on_done)
    end)
end

--- Interactive per-file conflict dialog chain.
--- For each conflict: keep remote (download) / keep local (upload) / skip.
local function resolve_conflicts(p, conflicts, idx, on_done)
    idx = idx or 1
    if idx > #conflicts then
        if on_done then on_done() end
        return
    end
    local c = conflicts[idx]
    local rel = c.rel
    UIManager:show(ButtonDialogTitle:new{
        title = T(_("Conflict: %1\n\nBoth the local copy and the server copy have changed since last sync."), rel),
        buttons = {
            {
                {
                    text = _("Keep server copy"),
                    callback = function()
                        UIManager:close(UIManager:getTopWidget())
                        sync.do_action(p, "download", { rel = rel, remote = c.remote })
                        UIManager:scheduleIn(0, function()
                            resolve_conflicts(p, conflicts, idx + 1, on_done)
                        end)
                    end,
                },
                {
                    text = _("Keep local copy"),
                    callback = function()
                        UIManager:close(UIManager:getTopWidget())
                        sync.do_action(p, "upload", { rel = rel, local_file = c.local_file })
                        UIManager:scheduleIn(0, function()
                            resolve_conflicts(p, conflicts, idx + 1, on_done)
                        end)
                    end,
                },
            },
            {
                {
                    text = _("Skip"),
                    callback = function()
                        UIManager:close(UIManager:getTopWidget())
                        p.stats.skipped = (p.stats.skipped or 0) + 1
                        UIManager:scheduleIn(0, function()
                            resolve_conflicts(p, conflicts, idx + 1, on_done)
                        end)
                    end,
                },
            },
        },
    })
end

--- Batch dialog for files deleted on the server that still exist locally.
--- Options: remove all local copies / keep all / review one by one.
local function resolve_deletions(p, deletions, on_done)
    if #deletions == 0 then
        if on_done then on_done() end
        return
    end
    local names = {}
    for i, d in ipairs(deletions) do
        if i <= 5 then table.insert(names, d.rel:match("([^/]+)$") or d.rel) end
    end
    if #deletions > 5 then table.insert(names, T(_("… and %1 more"), #deletions - 5)) end
    local title = T(
        _("%1 file(s) were removed from the server. What should happen to the local copies?\n\n%2"),
        #deletions, table.concat(names, "\n"))

    local function delete_all()
        for _, d in ipairs(deletions) do
            sync.do_action(p, "delete_local", { rel = d.rel })
        end
        if on_done then on_done() end
    end

    local function keep_all()
        p.stats.skipped = (p.stats.skipped or 0) + #deletions
        if on_done then on_done() end
    end

    UIManager:show(ButtonDialogTitle:new{
        title = title,
        buttons = {
            {
                {
                    text = _("Remove local copies"),
                    callback = function()
                        UIManager:close(UIManager:getTopWidget())
                        delete_all()
                    end,
                },
                {
                    text = _("Keep local copies"),
                    callback = function()
                        UIManager:close(UIManager:getTopWidget())
                        keep_all()
                    end,
                },
            },
        },
    })
end

--- Main two-way sync orchestrator.
--- ctx = { server_url, username, password, local_folder, extensions_filter, ignore_dotfiles }
--- on_done = optional function(stats) called after everything finishes.
local function run_two_way(ctx, on_done)
    if sync_in_flight then
        UIManager:show(InfoMessage:new{ text = _("Sync already in progress.") })
        return
    end
    sync_in_flight = true

    local syncing_msg = InfoMessage:new{ text = _("Syncing…") }
    UIManager:show(syncing_msg)
    UIManager:forceRePaint()

    local function release(stats)
        sync_in_flight = false
        UIManager:close(syncing_msg)
        show_summary(stats, on_done)
    end

    -- Build plan on next tick so the "Syncing…" message is visible.
    UIManager:scheduleIn(0, function()
        local p, err = sync.plan(ctx)
        if not p then
            sync_in_flight = false
            UIManager:close(syncing_msg)
            UIManager:show(InfoMessage:new{
                text = T(_("Two-way sync failed: %1"), tostring(err)),
            })
            if on_done then on_done(nil) end
            return
        end

        logger.info(LOG .. "two-way plan: download=" .. #p.to_download
            .. " upload=" .. #p.to_upload
            .. " conflicts=" .. #p.conflicts
            .. " deletions=" .. #p.deletions)

        -- Phase 1: downloads
        run_actions(p, "download", p.to_download, 1, function()
            -- Phase 2: uploads
            run_actions(p, "upload", p.to_upload, 1, function()
                -- Phase 3: interactive conflict resolution
                resolve_conflicts(p, p.conflicts, 1, function()
                    -- Phase 4: interactive deletion resolution
                    resolve_deletions(p, p.deletions, function()
                        -- Flush cache and finish.
                        sync.save_cache(p)
                        release(p.stats)
                    end)
                end)
            end)
        end)
    end)
end

return {
    run_two_way = run_two_way,
}
