const std = @import("std");
const windows = std.os.windows;
const win32 = @import("win32.zig");

pub const WindowCreateError = error{
    FailedToCreateWindow,
    FailedToGetModuleHandle,
    FailedToRegisterWindowClass,
    FailedToGetDeviceContext,
    FailedToLoadCursor,
} || std.mem.Allocator.Error;

pub const Win32Platform = @This();

instance: windows.HINSTANCE,
window: windows.HWND,
device_context: windows.HDC,
window_placement: win32.WINDOWPLACEMENT,
fullscreen: bool = false,

const Self = @This();

pub fn createWindow(
    window_title: [*:0]const u8,
    window_width: i32,
    window_height: i32,
    class_name: [*:0]const u8,
) WindowCreateError!Win32Platform {
    var platform_state: Win32Platform = undefined;

    platform_state.instance = win32.GetModuleHandleA(null) orelse return error.FailedToGetModuleHandle;

    var window_class: win32.WNDCLASSA = .zero;
    window_class.style = .{ .OWNDC = 1 };
    window_class.lpfnWndProc = windowProc;
    window_class.hInstance = platform_state.instance;
    window_class.lpszClassName = class_name;
    // window_class.hCursor = win32.LoadCursorA(null, win32.IDC_ARROW) orelse return error.FailedToLoadCursor;

    const result = win32.RegisterClassA(&window_class);
    if (result == 0) {
        _ = win32.MessageBoxA(null, "Windows Registration Failed", "Error", win32.MB_ICONEXCLAMATION);
        return error.FailedToRegisterWindowClass;
    }

    var window_x: i32 = 0;
    var window_y: i32 = 0;
    var window_final_width: i32 = window_width;
    var window_final_height: i32 = window_height;

    var window_style: u32 = win32.WS_SYSMENU | win32.WS_CAPTION | win32.WS_OVERLAPPED;
    const window_style_ex: u32 = win32.WS_EX_APPWINDOW;

    window_style |= win32.WS_MINIMIZEBOX;
    window_style |= win32.WS_MAXIMIZEBOX;
    window_style |= win32.WS_THICKFRAME;

    var border_rect: windows.RECT = std.mem.zeroes(windows.RECT);
    _ = win32.AdjustWindowRectEx(&border_rect, @bitCast(window_style), 0, @bitCast(window_style_ex));

    window_x += border_rect.left;
    window_y += border_rect.right;

    window_final_width += border_rect.right - border_rect.left;
    window_final_height += border_rect.bottom - border_rect.top;

    platform_state.window = win32.CreateWindowExA(
        @bitCast(window_style_ex),
        class_name,
        window_title,
        @bitCast(window_style),
        window_x,
        window_y,
        window_final_width,
        window_final_height,
        null,
        null,
        platform_state.instance,
        null,
    ) orelse {
        _ = win32.MessageBoxA(null, "Windows Creation Failed", "Error", win32.MB_ICONEXCLAMATION);
        return error.FailedToCreateWindow;
    };
    errdefer _ = win32.DestroyWindow(platform_state.window);

    platform_state.device_context = win32.GetDC(platform_state.window) orelse return error.FailedToGetDeviceContext;
    platform_state.window_placement.length = @sizeOf(win32.WINDOWPLACEMENT);
    platform_state.fullscreen = false;
    return platform_state;
}

pub fn destroyWindow(self: *Win32Platform) void {
    _ = win32.DestroyWindow(self.window);
}

pub fn showWindow(self: *Win32Platform) void {
    const show_window_command_flags: u32 = win32.SW_SHOW;
    _ = win32.ShowWindow(self.window, @bitCast(show_window_command_flags));
}

pub fn toggleFullscreen(self: *Self) void {
    const window_style = win32.GetWindowLongA(self.window, win32.GWL_STYLE);
    const WS_OVERLAPPEDWINDOW = @as(i32, @bitCast(win32.WS_OVERLAPPEDWINDOW));

    if ((window_style & WS_OVERLAPPEDWINDOW) != 0) {
        self.fullscreen = true;
        var monitor_info: win32.MONITORINFO = .{
            .cbSize = @sizeOf(win32.MONITORINFO),
            .rcMonitor = undefined,
            .rcWork = undefined,
            .dwFlags = 0,
        };
        // NOTE: Save the current window placement so we can restore it later.
        const result = win32.GetWindowPlacement(self.window, &self.window_placement);

        const result2 = win32.GetMonitorInfoA(
            // NOTE: In case windows cannot find which is the closest monitor we default to getting the primary monitor
            win32.MonitorFromWindow(self.window, win32.MONITOR_DEFAULTTOPRIMARY),
            &monitor_info,
        );
        if (result != 0 and result2 != 0) {
            // NOTE: We are changing the window style so that it has no borders or title bar and then
            // setting the window position and size to be the top left corner of the monitor and the size of the monitor
            _ = win32.SetWindowLongA(self.window, win32.GWL_STYLE, window_style & ~WS_OVERLAPPEDWINDOW);
            _ = win32.SetWindowPos(
                self.window,
                win32.HWND_TOPMOST,
                monitor_info.rcMonitor.left,
                monitor_info.rcMonitor.top,
                monitor_info.rcMonitor.right - monitor_info.rcMonitor.left,
                monitor_info.rcMonitor.bottom - monitor_info.rcMonitor.top,
                @bitCast(win32.SWP_NOOWNERZORDER | win32.SWP_FRAMECHANGED),
            );
        }
    } else {
        self.fullscreen = false;
        _ = win32.SetWindowLongA(self.window, win32.GWL_STYLE, window_style | WS_OVERLAPPEDWINDOW);
        _ = win32.SetWindowPlacement(self.window, &self.window_placement);
        _ = win32.SetWindowPos(
            self.window,
            null,
            0,
            0,
            0,
            0,
            @bitCast(win32.SWP_NOMOVE | win32.SWP_NOSIZE | win32.SWP_NOZORDER | win32.SWP_NOOWNERZORDER | win32.SWP_FRAMECHANGED),
        );
    }
}

pub fn pumpMessages(self: *Win32Platform, event_queue: *std.ArrayList(WindowsEvent)) void {
    _ = self;
    var msg: win32.MSG = undefined;
    while (win32.PeekMessageA(&msg, null, 0, 0, win32.PM_REMOVE) != 0) {
        const lparam: usize = @bitCast(msg.lParam);
        const wparam: usize = @bitCast(msg.wParam);
        switch (msg.message) {
            win32.WM_QUIT => {
                event_queue.appendAssumeCapacity(.{ .quit = {} });
            },
            win32.WM_MOUSEMOVE => {
                event_queue.appendAssumeCapacity(.{
                    .mouse_move = .{
                        .x = @truncate(msg.lParam & 0xffff),
                        .y = @truncate(msg.lParam >> 16),
                    },
                });
            },
            win32.WM_MOUSEWHEEL => {
                // TODO: Do we want to parse the rest of the message? l_param has the mouse position
                // https://learn.microsoft.com/en-us/windows/win32/inputdev/wm-mousehwheel
                const z_delta: i16 = @bitCast(@as(u16, @truncate(wparam >> 16)));
                // NOTE: We are compressing the delta into just 1 direction.
                const delta: i8 = if (z_delta < 0) -1 else 1;
                // TODO: We are only storing the last delta. Could we do better?
                event_queue.appendAssumeCapacity(.{ .mouse_wheel = delta });
            },
            win32.WM_LBUTTONDOWN => event_queue.appendAssumeCapacity(.{ .mouse_button_down = .left }),
            win32.WM_LBUTTONUP => event_queue.appendAssumeCapacity(.{ .mouse_button_up = .left }),
            win32.WM_RBUTTONDOWN => event_queue.appendAssumeCapacity(.{ .mouse_button_down = .right }),
            win32.WM_RBUTTONUP => event_queue.appendAssumeCapacity(.{ .mouse_button_up = .right }),
            win32.WM_MBUTTONDOWN => event_queue.appendAssumeCapacity(.{ .mouse_button_down = .middle }),
            win32.WM_MBUTTONUP => event_queue.appendAssumeCapacity(.{ .mouse_button_up = .middle }),
            win32.WM_XBUTTONDOWN => {
                if (wparam & 0x100000000 != 0) {
                    event_queue.appendAssumeCapacity(.{ .mouse_button_down = .x1 });
                } else {
                    event_queue.appendAssumeCapacity(.{ .mouse_button_down = .x2 });
                }
            },
            win32.WM_XBUTTONUP => {
                if (wparam & 0x100000000 != 0) {
                    event_queue.appendAssumeCapacity(.{ .mouse_button_up = .x1 });
                } else {
                    event_queue.appendAssumeCapacity(.{ .mouse_button_up = .x2 });
                }
            },
            win32.WM_KEYDOWN,
            win32.WM_SYSKEYDOWN,
            => {
                var key: WindowsEvent.Key = @enumFromInt(wparam);

                const is_extended: bool = lparam & 0x01000000 != 0;

                switch (key) {
                    .alt => key = if (is_extended) .ralt else .lalt,
                    .control => key = if (is_extended) .rcontrol else .lcontrol,
                    .shift => {
                        // NOTE: This scan code is defined by windows for left shift.
                        // https://learn.microsoft.com/en-us/windows/win32/inputdev/about-keyboard-input#keystroke-message-flags
                        const left_shift: u8 = 0x2A;
                        const scan_code: u8 = @truncate(lparam >> 16);
                        key = if (scan_code == left_shift) .lshift else .rshift;
                    },
                    else => {},
                }

                // NOTE: For (sys)KeyDown messages this bit is set to 1 if the key was down before this message and 0 if it was up.
                // this means for key down messages we need to check if this is 0 for transition count and 1 if it is sysUp message
                const is_half_transition = lparam & 0x40000000 == 0;
                if (is_half_transition) {
                    event_queue.appendAssumeCapacity(.{ .key_down = key });
                }
            },
            win32.WM_KEYUP,
            win32.WM_SYSKEYUP,
            => {
                var key: WindowsEvent.Key = @enumFromInt(wparam);

                const is_extended: bool = lparam & 0x01000000 != 0;

                switch (key) {
                    .alt => key = if (is_extended) .ralt else .lalt,
                    .control => key = if (is_extended) .rcontrol else .lcontrol,
                    .shift => {
                        // NOTE: This scan code is defined by windows for left shift.
                        // https://learn.microsoft.com/en-us/windows/win32/inputdev/about-keyboard-input#keystroke-message-flags
                        const left_shift: u8 = 0x2A;
                        const scan_code: u8 = @truncate(lparam >> 16);
                        key = if (scan_code == left_shift) .lshift else .rshift;
                    },
                    else => {},
                }

                // NOTE: The 30th bit is always 1 for (sys)KeyUp messages. Since we only get up messages from the down state.
                // this message always means a transition
                event_queue.appendAssumeCapacity(.{ .key_up = key });
            },
            win32.WM_SIZE => {
                // We have handled the resize event here.
                // TODO: Check if we get resize events when not parsing the message queue.
                // std.log.info("WM_SIZE", .{});
            },
            else => {
                _ = win32.TranslateMessage(&msg);
                _ = win32.DispatchMessageA(&msg);
            },
        }
    }
    return true;
}

pub const WindowsEvent = union(enum) {
    quit: void,
    // resize: struct { width: u32, height: u32 },
    mouse_move: struct { x: i32, y: i32 },
    mouse_wheel: u8,
    mouse_button_down: MouseButton,
    mouse_button_up: MouseButton,
    key_down: Key,
    key_up: Key,

    pub const MouseButton = enum(u8) {
        left = 0,
        right = 1,
        middle = 2,
        x1 = 3,
        x2 = 4,
    };

    pub const Key = enum(u8) {
        mouse_left = 0x00,
        mouse_right = 0x01,
        mouse_middle = 0x02,
        mouse_x1 = 0x03,
        mouse_x2 = 0x04,

        backspace = 0x08,

        tab = 0x09,
        enter = 0x0d,
        shift = 0x10,
        control = 0x11,
        alt = 0x12,
        pause = 0x13,
        caps = 0x14,

        kana_hangul_mode = 0x15,
        ime_on = 0x16,
        junja = 0x17,
        ime_final = 0x18,
        kanji_hanja_mode = 0x19,
        ime_off = 0x1a,

        escape = 0x1b,

        convert = 0x1c,
        nonconvert = 0x1d,
        accept = 0x1e,
        modechange = 0x1f,

        space = 0x20,
        pageup = 0x21,
        pagedown = 0x22,
        end = 0x23,
        home = 0x24,

        left = 0x25,
        up = 0x26,
        right = 0x27,
        down = 0x28,

        select = 0x29,
        print = 0x2a,
        execute = 0x2b,

        printscreen = 0x2c,

        insert = 0x2d,

        delete = 0x2e,
        help = 0x2f,

        @"0" = 0x30,
        @"1" = 0x31,
        @"2" = 0x32,
        @"3" = 0x33,
        @"4" = 0x34,
        @"5" = 0x35,
        @"6" = 0x36,
        @"7" = 0x37,
        @"8" = 0x38,
        @"9" = 0x39,

        a = 0x41,
        b = 0x42,
        c = 0x43,
        d = 0x44,
        e = 0x45,
        f = 0x46,
        g = 0x47,
        h = 0x48,
        i = 0x49,
        j = 0x4a,
        k = 0x4b,
        l = 0x4c,
        m = 0x4d,
        n = 0x4e,
        o = 0x4f,
        p = 0x50,
        q = 0x51,
        r = 0x52,
        s = 0x53,
        t = 0x54,
        u = 0x55,
        v = 0x56,
        w = 0x57,
        x = 0x58,
        y = 0x59,
        z = 0x5a,

        lsuper = 0x5b,
        rsuper = 0x5c,

        apps = 0x5d,

        /// put computer to sleep
        sleep = 0x5f,

        numpad0 = 0x60,
        numpad1 = 0x61,
        numpad2 = 0x62,
        numpad3 = 0x63,
        numpad4 = 0x64,
        numpad5 = 0x65,
        numpad6 = 0x66,
        numpad7 = 0x67,
        numpad8 = 0x68,
        numpad9 = 0x69,

        multiply = 0x6a,
        add = 0x6b,
        separator = 0x6c,
        subtract = 0x6d,
        decimal = 0x6e,
        divide = 0x6f,

        f1 = 0x70,
        f2 = 0x71,
        f3 = 0x72,
        f4 = 0x73,
        f5 = 0x74,
        f6 = 0x75,
        f7 = 0x76,
        f8 = 0x77,
        f9 = 0x78,
        f10 = 0x79,
        f11 = 0x7a,
        f12 = 0x7b,
        f13 = 0x7c,
        f14 = 0x7d,
        f15 = 0x7e,
        f16 = 0x7f,
        f17 = 0x80,
        f18 = 0x81,
        f19 = 0x82,
        f20 = 0x83,
        f21 = 0x84,
        f22 = 0x85,
        f23 = 0x86,
        f24 = 0x87,

        numlock = 0x90,
        scroll = 0x91,
        numpad_equal = 0x92,

        lshift = 0xa0,
        rshift = 0xa1,
        lcontrol = 0xa2,
        rcontrol = 0xa3,
        lalt = 0xa4,
        ralt = 0xa5,

        browser_back = 0xa6,
        browser_forward = 0xa7,
        browser_refresh = 0xa8,
        browser_stop = 0xa9,
        browser_search = 0xaa,
        browser_favourites = 0xab,
        browser_home = 0xac,

        volume_mute = 0xad,
        volume_down = 0xae,
        volume_up = 0xaf,

        media_next_track = 0xb0,
        media_prev_track = 0xb1,
        media_stop = 0xb2,
        media_play_pause = 0xb3,

        launch_app1 = 0xb6,
        launch_app2 = 0xb7,

        semicolon = 0x3b,
        colon = 0xba,
        equal = 0xbb,
        comma = 0xbc,
        minus = 0xbd,
        period = 0xbe,
        slash = 0xbf,

        grave = 0xc0,
        lbracket = 0xdb,
        backslash = 0xdc,
        rbracket = 0xdd,
        apostrophe = 0xde,

        ime_process = 0xe5,
    };
};

fn windowProc(
    window: windows.HWND,
    message: u32,
    w_param: windows.WPARAM,
    l_param: windows.LPARAM,
) callconv(.winapi) windows.LRESULT {
    var result: windows.LRESULT = 0;

    switch (message) {
        win32.WM_ERASEBKGND => result = 1,
        win32.WM_DESTROY => {
            _ = win32.PostQuitMessage(0);
        },
        win32.WM_CLOSE => {
            _ = win32.PostQuitMessage(0);
        },
        // win32.WM_SETCURSOR => {
        //     if (DBG_show_cursor) {
        //         _ = win32.SetCursor(DBG_cursor);
        //     } else {
        //         _ = win32.SetCursor(null);
        //     }
        // },
        // TODO: We might not want to resize the back buffer every time the window is resized.
        // We might want the backbuffer to stay at a fixed resolution and just rely on stretchDIBits to scale it.
        // We could figure out a way to keep the aspect ration the same, but that might be tricky.
        // win32.WM_SIZE => {
        // var rect: windows.RECT = undefined;
        // _ = win32.GetClientRect(app_state.window, &rect);
        // app_state.back_buffer.width = @intCast(rect.right - rect.left);
        // app_state.back_buffer.height = @intCast(rect.bottom - rect.top);
        //
        // app_state.back_buffer.info.bmiHeader.biWidth = @intCast(app_state.back_buffer.width);
        // app_state.back_buffer.info.bmiHeader.biHeight = -@as(i32, @intCast(app_state.back_buffer.height));
        //
        // const bytes_per_pixel: usize = 4;
        // const new_bitmap_size: usize = @as(usize, app_state.back_buffer.width) * @as(usize, app_state.back_buffer.height) * bytes_per_pixel;
        // app_state.back_buffer.data = app_state.allocator.realloc(app_state.back_buffer.data, new_bitmap_size) catch unreachable;
        // },

        // TODO: When we lose focus we should reset the input state so that the game does not react to input in anyway
        // win32.WM_KILLFOCUS => {},
        // win32.WM_SETFOCUS => {},
        else => {
            result = win32.DefWindowProcA(window, message, w_param, l_param);
        },
    }

    return result;
}
