const std = @import("std");
const core = @import("core");

const Endpoint = core.Endpoint;
const Strings = core.Strings;
const USBStrings = Strings.USBStrings;
const LANGID = core.Strings.LANGID;
const Meta = core.Meta;

const report_descriptor = [_]u8{
    0x05, 0x01, // Usage Page (Generic Desktop)
    0x09, 0x06, // Usage (Keyboard)
    0xA1, 0x01, // Collection (Application)

    0x05, 0x07, //   Usage Page (Keyboard/Keypad)
    0x19, 0xE0, //   Usage Minimum (Keyboard LeftControl)
    0x29, 0xE7, //   Usage Maximum (Keyboard Right GUI)
    0x15, 0x00, //   Logical Minimum (0)
    0x25, 0x01, //   Logical Maximum (1)
    0x75, 0x01, //   Report Size (1)
    0x95, 0x08, //   Report Count (8)
    0x81, 0x02, //   Input (Data, Variable, Absolute) - modifiers

    0x95, 0x01, //   Report Count (1)
    0x75, 0x08, //   Report Size (8)
    0x81, 0x01, //   Input (Constant) - reserved

    0x95, 0x05, //   Report Count (5)
    0x75, 0x01, //   Report Size (1)
    0x05, 0x08, //   Usage Page (LEDs)
    0x19, 0x01, //   Usage Minimum (Num Lock)
    0x29, 0x05, //   Usage Maximum (Kana)
    0x91, 0x02, //   Output (Data, Variable, Absolute) - LEDs

    0x95, 0x01, //   Report Count (1)
    0x75, 0x03, //   Report Size (3)
    0x91, 0x01, //   Output (Constant) - padding

    0x95, 0x06, //   Report Count (6)
    0x75, 0x08, //   Report Size (8)
    0x15, 0x00, //   Logical Minimum (0)
    0x25, 0x65, //   Logical Maximum (101)
    0x05, 0x07, //   Usage Page (Keyboard/Keypad)
    0x19, 0x00, //   Usage Minimum (Reserved)
    0x29, 0x65, //   Usage Maximum (Keyboard Application)
    0x81, 0x00, //   Input (Data, Array, Absolute) - keys

    0xC0, // End Collection
};

const foo_interface_string = USBStrings{
    .fallback = &Strings.StringToUSB("Basic Boot Keyboard"),
    .portuguese_brazil = &Strings.StringToUSB("teclado Boot basico"),
};

pub const BootKeyboard = struct {
    ep1: Endpoint.Endpoint(.{
        .direction = .In,
        .ep_type = .{ .Interrupt = .{} },
        .interval = 100,
    }),
    ep2: Endpoint.Endpoint(.{
        .direction = .Out,
        .ep_type = .{ .Interrupt = .{} },
        .interval = 100,
    }),

    fn setup_handler(inst: *const anyopaque, event: core.Gateway.InterfaceEventIn) core.Gateway.InterfaceEventOut {
        const self: *@This() = @ptrCast(@alignCast(@constCast(inst)));

        switch (event) {
            .enabled => {
                self.ep1.CTRL.set_ep_state(.NAK, 0) catch @panic("HID ENABLE FAIL");
                self.ep2.CTRL.set_ep_state(.READY, 0) catch @panic("HID ENABLE FAIL");
            },
            .class_setup => {
                return .ZLP;
            },
            .standart_setup => {
                return .{ .send_data = &report_descriptor };
            },
            else => {},
        }
        return .None;
    }

    fn ep1_handler(self: *const anyopaque, _: Endpoint.EpEvent) void {
        const ep: *@FieldType(@This(), "ep1") = @ptrCast(@alignCast(@constCast(self)));
        const foo: *@This() = @fieldParentPtr("ep1", ep);
        _ = foo;
    }

    fn ep2_handler(self: *const anyopaque, _: Endpoint.EpEvent) void {
        const ep: *@FieldType(@This(), "ep2") = @ptrCast(@alignCast(@constCast(self)));

        ep.CTRL.set_ep_state(.READY, null) catch @panic("HID ENABLE FAIL");
    }

    pub fn init() @This() {
        return @This(){
            .ep1 = .{
                .event = ep1_handler,
            },
            .ep2 = .{
                .event = ep2_handler,
            },
        };
    }

    pub fn into_meta() []const Meta.Meta {
        return Meta.processMetaInterface(@This(), .{
            Meta.MetaInterface{
                .class_code = .Hid,
                .subclass_code = 0x1,
                .protocol_code = 0x01,
                .alternate_setting = 0,
                .blobs = &.{
                    &.{ 0x09, 0x21, 0x11, 0x01, 0x00, 0x01, 0x22, 0x3F, 0x00 },
                },
                .endpoints = &.{ .ep1, .ep2 },
                .setup = setup_handler,
                .iInterface = foo_interface_string,
            },
        });
    }
};
