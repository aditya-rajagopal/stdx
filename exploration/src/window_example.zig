const std = @import("std");
const objc = @import("objc");
const cocoa = @import("cocoa.zig");

const log = std.log.scoped(.window);

fn setup() !void {
    const Window = objc.allocateClassPair(objc.getClass("NSWindow").?, "Window").?;
    defer objc.registerClassPair(Window);

    const View = objc.allocateClassPair(objc.getClass("NSView").?, "View").?;
    std.debug.assert(View.addProtocol(objc.getProtocol("NSTextInputClient").?));
    defer objc.registerClassPair(View);

    const window = struct {
        fn init(target: objc.c.id, sel: objc.c.SEL) callconv(.c) objc.c.id {
            _ = sel;
            const self = objc.Object.fromId(target);
            const mask: cocoa.StyleMask = .{
                .miniaturizable = true,
                .titled = true,
                .fullscreen = false,
                .fullsize_content_view = true,
                .resizable = true,
                .closable = true,
            };

            self.msgSendSuper(
                objc.getClass("NSWindow").?,
                void,
                "initWithContentRect:styleMask:backing:defer:",
                .{
                    cocoa.NSRect.make(200, 200, 640, 480),
                    mask,
                    cocoa.BackingStore.Buffered,
                    cocoa.NO,
                },
            );

            self.msgSend(void, "setTitle:", .{cocoa.NSString("Window Exploration")});
            self.msgSend(void, "makeKeyAndOrderFront:", .{@as(objc.c.id, 0)});

            return self.value;
        }

        fn shouldClose(target: objc.c.id, sel: objc.c.SEL, sender: objc.c.id) callconv(.c) objc.c.BOOL {
            _ = sel;
            return shouldCloseInner(objc.Object.fromId(target), objc.Object.fromId(sender));
        }

        fn sendEvent(target: objc.c.id, sel: objc.c.SEL, event: objc.c.id) callconv(.c) void {
            _ = sel;
            const event_obj = objc.Object.fromId(event);
            const event_type: cocoa.EventType = @enumFromInt(event_obj.msgSend(u64, "type", .{}));

            log.debug("sendEvent called: {t}", .{event_type});

            if (event_type == .KeyDown or event_type == .KeyUp) {
                const chars = event_obj.msgSend(objc.Object, "characters", .{});
                const chars_utf8 = chars.getProperty([*:0]const u8, "UTF8String");
                const chars_slice = std.mem.sliceTo(chars_utf8, 0);
                if (event_type == .KeyDown) {
                    log.info("KeyDown: {s}", .{chars_slice});
                } else {
                    log.info("KeyUp: {s}", .{chars_slice});
                }
            }

            objc.Object.fromId(target).msgSendSuper(objc.getClass("NSWindow").?, void, "sendEvent:", .{event});
        }
    };

    const view = struct {
        fn initWithFrame(target: objc.c.id, sel: objc.c.SEL, frame: cocoa.NSRect) callconv(.c) objc.c.id {
            _ = sel;
            const self = objc.Object.fromId(target);
            self.msgSendSuper(objc.getClass("NSView").?, void, "initWithFrame:", .{frame});
            return self.value;
        }

        fn drawRect(target: objc.c.id, sel: objc.c.SEL, dirty_rect: cocoa.NSRect) callconv(.c) void {
            _ = sel;
            _ = dirty_rect;

            const self = objc.Object.fromId(target);
            const bounds = self.msgSend(cocoa.NSRect, "bounds", .{});

            const NSBezierPath = objc.getClass("NSBezierPath").?;
            const NSColor = objc.getClass("NSColor").?;

            const path = NSBezierPath.msgSend(objc.Object, "bezierPath", .{});

            const top_x = bounds.size.width / 2.0;
            const top_y = bounds.size.height * 0.2;
            const left_x = bounds.size.width * 0.2;
            const left_y = bounds.size.height * 0.8;
            const right_x = bounds.size.width * 0.8;
            const right_y = bounds.size.height * 0.8;

            path.msgSend(void, "moveToPoint:", .{cocoa.NSPoint.make(top_x, top_y)});
            path.msgSend(void, "lineToPoint:", .{cocoa.NSPoint.make(right_x, right_y)});
            path.msgSend(void, "lineToPoint:", .{cocoa.NSPoint.make(left_x, left_y)});
            path.msgSend(void, "closePath", .{});

            const redColor = NSColor.msgSend(objc.Object, "redColor", .{});
            redColor.msgSend(void, "set", .{});

            path.msgSend(void, "fill", .{});
            path.msgSend(void, "stroke", .{});
        }

        fn acceptsFirstResponder(target: objc.c.id, sel: objc.c.SEL) callconv(.c) objc.c.BOOL {
            _ = sel;
            _ = target;
            return cocoa.YES;
        }

        fn becomeFirstResponder(target: objc.c.id, sel: objc.c.SEL) callconv(.c) objc.c.BOOL {
            _ = sel;
            _ = target;
            return cocoa.YES;
        }

        fn canBecomeKeyView(target: objc.c.id, sel: objc.c.SEL) callconv(.c) objc.c.BOOL {
            _ = sel;
            _ = target;
            return cocoa.YES;
        }

        fn wantsUpdateLayer(target: objc.c.id, sel: objc.c.SEL) callconv(.c) objc.c.BOOL {
            _ = sel;
            _ = target;
            return cocoa.YES;
        }

        fn acceptsFirstMouse(target: objc.c.id, sel: objc.c.SEL, event: objc.c.id) callconv(.c) objc.c.BOOL {
            _ = sel;
            _ = target;
            _ = event;
            return cocoa.YES;
        }

        fn keyDown(target: objc.c.id, sel: objc.c.SEL, event: objc.c.id) callconv(.c) void {
            _ = sel;
            _ = target;
            const event_obj = objc.Object.fromId(event);
            const chars = event_obj.msgSend(objc.Object, "characters", .{});
            const chars_utf8 = chars.getProperty([*:0]const u8, "UTF8String");
            const chars_slice = std.mem.sliceTo(chars_utf8, 0);
            log.info("KeyDown: {s}", .{chars_slice});
        }

        fn keyUp(target: objc.c.id, sel: objc.c.SEL, event: objc.c.id) callconv(.c) void {
            _ = sel;
            _ = target;
            const event_obj = objc.Object.fromId(event);
            const chars = event_obj.msgSend(objc.Object, "characters", .{});
            const chars_utf8 = chars.getProperty([*:0]const u8, "UTF8String");
            const chars_slice = std.mem.sliceTo(chars_utf8, 0);
            log.info("KeyUp: {s}", .{chars_slice});
        }

        fn mouseDown(target: objc.c.id, sel: objc.c.SEL, event: objc.c.id) callconv(.c) void {
            _ = sel;
            _ = target;
            const event_obj = objc.Object.fromId(event);
            const location = event_obj.msgSend(cocoa.NSPoint, "locationInWindow", .{});
            log.info("MouseDown at ({d:.1}, {d:.1})", .{ location.x, location.y });
        }

        fn mouseUp(target: objc.c.id, sel: objc.c.SEL, event: objc.c.id) callconv(.c) void {
            _ = sel;
            _ = target;
            const event_obj = objc.Object.fromId(event);
            const location = event_obj.msgSend(cocoa.NSPoint, "locationInWindow", .{});
            log.info("MouseUp at ({d:.1}, {d:.1})", .{ location.x, location.y });
        }

        fn mouseMoved(target: objc.c.id, sel: objc.c.SEL, event: objc.c.id) callconv(.c) void {
            _ = sel;
            _ = target;
            const event_obj = objc.Object.fromId(event);
            const location = event_obj.msgSend(cocoa.NSPoint, "locationInWindow", .{});
            log.debug("MouseMoved at ({d:.1}, {d:.1})", .{ location.x, location.y });
        }

        fn mouseDragged(target: objc.c.id, sel: objc.c.SEL, event: objc.c.id) callconv(.c) void {
            _ = sel;
            const self = objc.Object.fromId(target);
            self.msgSend(void, "mouseMoved", .{event});
        }
    };

    Window.replaceMethod("init", window.init);
    Window.replaceMethod("sendEvent:", window.sendEvent);
    View.replaceMethod("initWithFrame:", view.initWithFrame);
    View.replaceMethod("drawRect:", view.drawRect);
    View.replaceMethod("acceptsFirstResponder", view.acceptsFirstResponder);
    View.replaceMethod("becomeFirstResponder", view.becomeFirstResponder);
    View.replaceMethod("keyDown:", view.keyDown);
    View.replaceMethod("keyUp:", view.keyUp);
    View.replaceMethod("mouseDown:", view.mouseDown);
    View.replaceMethod("mouseUp:", view.mouseUp);
    View.replaceMethod("mouseMoved:", view.mouseMoved);
    View.replaceMethod("mouseDragged:", view.mouseDragged);
    View.replaceMethod("canBecomeKeyView", view.canBecomeKeyView);
    View.replaceMethod("wantsUpdateLayer", view.wantsUpdateLayer);
    View.replaceMethod("acceptsFirstMouse:", view.acceptsFirstMouse);
}

fn shouldCloseInner(self: objc.Object, sender: objc.Object) objc.c.BOOL {
    const Block = objc.Block(struct { sender: objc.c.id }, .{i64}, void);
    const captures: Block.Captures = .{
        .sender = sender.value,
    };

    const inner = struct {
        fn invokeFn(blk: *const Block.Context, return_code: i64) callconv(.c) void {
            if (return_code == 1000) {
                log.info("User selected YES - closing window", .{});
                const sender_obj = objc.Object.fromId(blk.sender);
                sender_obj.msgSend(void, "close", .{});
                cocoa.NSApp().msgSend(void, "stop:", .{blk.sender});
            } else {
                log.info("User selected NO - keeping window open", .{});
            }
        }
    };

    const block = Block.init(captures, inner.invokeFn);

    const alert = cocoa.alloc(objc.getClass("NSAlert").?)
        .msgSend(objc.Object, "init", .{});

    alert.msgSend(void, "setMessageText:", .{cocoa.NSString("Close Window")});
    alert.msgSend(void, "setInformativeText:", .{cocoa.NSString("Are you sure you want to exit?")});
    alert.msgSend(void, "setAlertStyle:", .{@as(u64, 0)});
    alert.msgSend(void, "addButtonWithTitle:", .{cocoa.NSString("YES")});
    alert.msgSend(void, "addButtonWithTitle:", .{cocoa.NSString("NO")});

    alert.msgSend(void, "beginSheetModalForWindow:completionHandler:", .{
        self,
        block,
    });

    return cocoa.NO;
}

pub fn main() !void {
    try setup();
    const NSApp = cocoa.NSApp();
    const Window = objc.getClass("Window").?;
    const window = cocoa.alloc(Window)
        .msgSend(objc.Object, "init", .{})
        .msgSend(objc.Object, "autorelease", .{});
    window.msgSend(void, "makeMainWindow", .{});

    const View = objc.getClass("View").?;
    const view = cocoa.alloc(View)
        .msgSend(objc.Object, "initWithFrame:", .{cocoa.NSRect.make(0, 0, 640, 480)});

    window.msgSend(void, "setContentView:", .{view});
    window.msgSend(void, "makeFirstResponder:", .{view});
    window.msgSend(void, "orderFrontRegardless", .{});
    window.msgSend(void, "makeKeyWindow", .{});
    NSApp.msgSend(void, "activateIgnoringOtherApps:", .{cocoa.YES});

    const NSAutoReleasePool = objc.getClass("NSAutoreleasePool").?;
    var pool = cocoa.alloc(NSAutoReleasePool).msgSend(objc.Object, "init", .{});
    NSApp.msgSend(void, "finishLaunching", .{});
    log.info("Starting event loop...", .{});

    while (true) {
        pool.msgSend(void, "release", .{});
        pool = cocoa.alloc(NSAutoReleasePool).msgSend(objc.Object, "init", .{});
        const event = NSApp.msgSend(objc.Object, "nextEventMatchingMask:untilDate:inMode:dequeue:", .{
            cocoa.EventMask.any,
            objc.getClass("NSDate").?.msgSend(objc.Object, "distantFuture", .{}).value,
            cocoa.Mode(.default).value,
            cocoa.YES,
        });

        const event_type: cocoa.EventType = @enumFromInt(event.msgSend(u64, "type", .{}));

        if (event_type == .KeyDown or event_type == .KeyUp) {
            const chars = event.msgSend(objc.Object, "characters", .{});
            const chars_utf8 = chars.getProperty([*:0]const u8, "UTF8String");
            const chars_slice = std.mem.sliceTo(chars_utf8, 0);
            if (event_type == .KeyDown) {
                log.info("KeyDown: {s}", .{chars_slice});
            } else {
                log.info("KeyUp: {s}", .{chars_slice});
            }
        }

        NSApp.msgSend(void, "sendEvent:", .{event});
        NSApp.msgSend(void, "updateWindows", .{});
    }
    pool.msgSend(void, "release", .{});
}

// pub fn main() void {
//     setup();
//
//     const NSApp = cocoa.NSApp();
//     const Window = objc.getClass("Window").?;
//
//     cocoa.alloc(Window)
//         .msgSend(objc.Object, "init", .{})
//         .msgSend(objc.Object, "autorelease", .{})
//         .msgSend(void, "makeMainWindow", .{});
//
//     const NSAutoReleasePool = objc.getClass("NSAutoreleasePool").?;
//     var pool = cocoa.alloc(NSAutoReleasePool).msgSend(objc.Object, "init", .{});
//
//     NSApp.msgSend(void, "finishLaunching", .{});
//
//     logger.info("Starting event loop...", .{});
//
//     while (true) {
//         pool.msgSend(void, "release", .{});
//         pool = cocoa.alloc(NSAutoReleasePool).msgSend(objc.Object, "init", .{});
//
//         const event = NSApp.msgSend(objc.Object, "nextEventMatchingMask:untilDate:inMode:dequeue:", .{
//             cocoa.EventMask.any,
//             objc.getClass("NSDate").?.msgSend(objc.Object, "distantFuture", .{}).value,
//             objc.getClass("NSRunLoop").?.msgSend(objc.Object, "currentRunLoop", .{})
//                 .msgSend(objc.Object, "currentMode", .{}).value,
//             cocoa.YES,
//         });
//
//         if (event.value != null) {
//             const event_type_u64 = event.msgSend(u64, "type", .{});
//
//             switch (event_type_u64) {
//                 10, 11, 1, 2, 5, 3, 4 => {
//                     // KeyDown, KeyUp, LeftMouseDown, LeftMouseUp, MouseMoved, RightMouseDown, RightMouseUp
//                     // Let window methods handle these
//                 },
//                 22 => {
//                     // ScrollWheel
//                     const delta_y = event.msgSend(f64, "scrollingDeltaY", .{});
//                     logger.info("ScrollWheel: delta_y={d:.1}", .{delta_y});
//                 },
//                 else => {
//                     logger.debug("Event type: value={}", .{event_type_u64});
//                 },
//             }
//
//             NSApp.msgSend(void, "sendEvent:", .{event});
//             NSApp.msgSend(void, "updateWindows", .{});
//         }
//     }
//
//     pool.msgSend(void, "release", .{});
// }
