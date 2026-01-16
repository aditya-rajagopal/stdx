const std = @import("std");
const objc = @import("objc");

// Geometry structs
pub const NSPoint = extern struct {
    x: f64,
    y: f64,

    pub fn make(x: f64, y: f64) NSPoint {
        return .{ .x = x, .y = y };
    }
};

pub const NSSize = extern struct {
    width: f64,
    height: f64,

    pub fn make(w: f64, h: f64) NSSize {
        return .{ .width = w, .height = h };
    }
};

pub const NSRect = extern struct {
    origin: NSPoint,
    size: NSSize,

    pub fn make(x: f64, y: f64, w: f64, h: f64) NSRect {
        return .{
            .origin = .{ .x = x, .y = y },
            .size = .{ .width = w, .height = h },
        };
    }
};

// NSWindow helpers
pub const StyleMask = packed struct {
    titled: bool,
    closable: bool,
    miniaturizable: bool,
    resizable: bool,
    utility_window: bool = false,
    _unused_1: bool = false,
    doc_modal_window: bool = false,
    nonactivating_panel: bool = false,
    _unused_2: u4 = 0,
    unified_title_and_toolbar: bool = false,
    hud_window: bool = false,
    fullscreen: bool,
    fullsize_content_view: bool,
    _padding: u48 = 0,

    pub const default: StyleMask = .{
        .titled = true,
        .closable = true,
        .miniaturizable = true,
        .resizable = true,
        .fullscreen = false,
        .fullsize_content_view = true,
    };

    comptime {
        std.debug.assert(@sizeOf(@This()) == @sizeOf(u64));
        std.debug.assert(@bitSizeOf(@This()) == @bitSizeOf(u64));
    }
};

pub const BackingStore = enum(c_uint) {
    Retained = 0,
    Nonretained = 1,
    Buffered = 2,
};

// NSEvent enums
pub const EventType = enum(u64) {
    LeftMouseDown = 1,
    LeftMouseUp = 2,
    RightMouseDown = 3,
    RightMouseUp = 4,
    MouseMoved = 5,
    LeftMouseDragged = 6,
    RightMouseDragged = 7,
    MouseEntered = 8,
    MouseExited = 9,
    KeyDown = 10,
    KeyUp = 11,
    FlagsChanged = 12,
    AppKitDefined = 13,
    SystemDefined = 14,
    ApplicationDefined = 15,
    Periodic = 16,
    CursorUpdate = 17,
    ScrollWheel = 22,
    TabletPoint = 23,
    TabletProximity = 24,
    OtherMouseDown = 25,
    OtherMouseUp = 26,
    OtherMouseDragged = 27,
    Gesture = 29,
    Magnify = 30,
    Swipe = 31,
    Rotate = 18,
    BeginGesture = 19,
    EndGesture = 20,
    SmartMagnify = 32,
    QuickLook = 33,
    Pressure = 34,
    DirectTouch = 37,
    ChangeMode = 38,
};

pub const EventMask = packed struct {
    LeftMouseDown: bool,
    LeftMouseUp: bool,
    RightMouseDown: bool,
    RightMouseUp: bool,
    MouseMoved: bool,
    LeftMouseDragged: bool,
    RightMouseDragged: bool,
    MouseEntered: bool,
    MouseExited: bool,
    KeyDown: bool,
    KeyUp: bool,
    FlagsChanged: bool,
    AppKitDefined: bool,
    SystemDefined: bool,
    ApplicationDefined: bool,
    Periodic: bool,
    CursorUpdate: bool,
    Rotate: bool,
    BeginGesture: bool,
    EndGesture: bool,
    _unused: bool = false,
    ScrollWheel: bool,
    TabletPoint: bool,
    TabletProximity: bool,
    OtherMouseDown: bool,
    OtherMouseUp: bool,
    OtherMouseDragged: bool,
    _unused_2: bool = false,
    Gesture: bool,
    Magnify: bool,
    Swipe: bool,
    SmartMagnify: bool,
    QuickLook: bool,
    Pressure: bool,
    _unused_3: u2 = 0,
    DirectTouch: bool,
    ChangeMode: bool,
    _padding: u26 = 0,

    pub const any = @as(@This(), @bitCast(@as(u64, std.math.maxInt(u64))));

    comptime {
        std.debug.assert(@sizeOf(@This()) == @sizeOf(u64));
        std.debug.assert(@bitSizeOf(@This()) == @bitSizeOf(u64));
    }
};

pub const ModifierFlags = packed struct {
    _padding: u15 = 0,
    CapsLock: bool,
    Shift: bool,
    Control: bool,
    Option: bool,
    Command: bool,
    NumericPad: bool,
    Help: bool,
    Function: bool,
    _padding_2: u41 = 0,

    comptime {
        std.debug.assert(@sizeOf(@This()) == @sizeOf(u64));
        std.debug.assert(@bitSizeOf(@This()) == @bitSizeOf(u64));
    }
};

// String helpers
pub fn NSString(string: [:0]const u8) objc.Object {
    const nsstring = objc.getClass("NSString").?;
    return nsstring.msgSend(objc.Object, "stringWithUTF8String:", .{string.ptr});
}

// App helpers
pub fn NSApp() objc.Object {
    const NSApplication = objc.getClass("NSApplication").?;
    return NSApplication.msgSend(objc.Object, "sharedApplication", .{});
}

pub const YES = if (objc.c.BOOL == bool) true else @as(i8, 1);
pub const NO = if (objc.c.BOOL == bool) false else @as(i8, 0);

pub fn alloc(class: objc.Class) objc.Object {
    return class.msgSend(objc.Object, "alloc", .{});
}

pub const LoopMode = enum {
    default,
    common_modes,
    event_tracking,
    modal_panel,
};

pub fn Mode(mode: LoopMode) objc.Object {
    return switch (mode) {
        .default => NSString("kCFRunLoopDefaultMode"),
        .common_modes => NSString("kCFRunLoopCommonModes"),
        .modal_panel => NSString("NSModalPanelRunLoopMode"),
        .event_tracking => NSString("NSEventTrackingRunLoopMode"),
    };
}

// Logger
const logger = std.log.scoped(.window);
