-- Freely place and resize the focused window without changing the workspace layout.
-- Drag with SUPER + left mouse; resize with SUPER + right mouse.
hl.bind("SUPER + SHIFT + F", function()
    local win = hl.get_active_window()
    if not win then return end

    if win.floating then
        hl.dispatch(hl.dsp.window.float({ action = "off" }))
        return
    end

    local monitor = hl.get_active_monitor()
    if not monitor then return end

    local reserved = monitor.reserved or {}
    local scale = monitor.scale or 1
    local left = reserved.left or 0
    local right = reserved.right or 0
    local top = reserved.top or 0
    local bottom = reserved.bottom or 0
    local margin = 24
    local width = monitor.width / scale - left - right - margin * 2
    local height = monitor.height / scale - top - bottom - margin * 2

    hl.dispatch(hl.dsp.window.float({ action = "on" }))
    hl.dispatch(hl.dsp.window.resize({ x = width, y = height, relative = false }))
    hl.dispatch(hl.dsp.window.move({
        x = monitor.x + left + margin,
        y = monitor.y + top + margin,
        relative = false,
    }))
end)
