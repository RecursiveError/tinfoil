const std = @import("std");
const Core = @import("core");
const CDC_data = @import("cdc_data.zig").CDC_data;
const Endpoint = Core.Endpoint.Endpoint;
const Meta = Core.Meta;

const CDC_String = Core.Strings.USBStrings{
    .fallback = &Core.Strings.StringToUSB("BASIC CDC ACM"),
};
const StopBits = enum(u8) {
    @"1" = 0,
    @"1.5" = 1,
    @"2" = 2,
    _,
};

const Parity = enum(u8) {
    None = 0,
    Odd = 1,
    Even = 2,
    Mark = 3,
    Space = 4,
    _,
};

const Encoding = struct {
    baudrate: u32,
    stopbits: StopBits,
    parity: Parity,
    data: u8,

    fn from_pkg(pkg: []const u8) !Encoding {
        if (pkg.len < 7) return error.InvalidEncoding;
        var enc: Encoding = undefined;
        const baudbyte_1: u32 = pkg[3];
        const baudbyte_2: u32 = pkg[2];
        const baudbyte_3: u32 = pkg[1];
        const baudbyte_4: u32 = pkg[0];
        const stp = pkg[4];
        const parity = pkg[5];
        const db = pkg[6];
        enc.baudrate = (baudbyte_1) | (baudbyte_2 << 8) | (baudbyte_3 << 16) | (baudbyte_4 << 24);
        enc.stopbits = @fromBackingInt(stp);
        enc.parity = @fromBackingInt(parity);
        enc.data = db;
        return enc;
    }
};

const SerialState = packed struct(u8) {
    DTR: u1,
    RTS: u1,
    _res: u6,
};

pub const CDC_ACM = struct {
    cdc_ctrl_ep: Endpoint(.{
        .direction = .In,
        .ep_type = .{ .Interrupt = .{} },
        .max_packet_size = 32,
        .interval = 10,
    }),

    lock: std.atomic.Mutex = .locked,

    data_interface: CDC_data,

    fn ep_handler(self: *const anyopaque, _: Core.Endpoint.EpEvent) void {
        const ep: *@FieldType(@This(), "cdc_ctrl_ep") = @ptrCast(@alignCast(@constCast(self)));
        ep.ctrl.set_ep_state(.NAK, null) catch @panic("CDC CTRL FAIL");
    }

    fn setup_handler(inst: *const anyopaque, event: Core.Gateway.InterfaceEventIn) Core.Gateway.InterfaceEventOut {
        const self: *@This() = @ptrCast(@alignCast(@constCast(inst)));

        switch (event) {
            .enabled => {
                self.cdc_ctrl_ep.ctrl.set_ep_state(.NAK, 0) catch @panic("CDC ENABLE FAIL");
                self.lock.unlock();
            },
            else => {},
        }
        return .None;
    }

    pub fn into_meta() []const Meta.Meta {
        return Meta.processMetaInterface(@This(), .{
            Meta.MetaIAD{
                .bFunctionClass = 0x02,
                .bFunctionSubClass = 0x02,
                .bFunctionProtocol = 0,
                .iFunction = CDC_String,
            },
            Meta.MetaInterface{
                .alternate_setting = 0,
                .class_code = .Communication,
                .subclass_code = 0x02,
                .protocol_code = 0,
                .blobs = &.{
                    .raw(&.{ 0x05, 0x24, 0x00, 0x10, 0x01 }), // CDC Header Functional Descriptor
                    .raw(&.{ 0x05, 0x24, 0x01, 0x02 }), // CDC Call Management Functional Descriptor
                    .interface_num(.data_interface, 0),
                    .raw(&.{ 0x04, 0x24, 0x02, 0x06 }), // CDC ACM Functional Descriptor
                    .raw(&.{ 0x05, 0x24, 0x06, 0x00, 0x01 }), // CDC Union Functional Descriptor
                },
                .endpoints = &.{.cdc_ctrl_ep},
                .setup = setup_handler,
            },
            Meta.FlatMetaDerive.from(.data_interface, CDC_data.into_meta()),
        });
    }

    pub fn init() @This() {
        return @This(){
            .cdc_ctrl_ep = .{
                .event = ep_handler,
            },
            .data_interface = .init(),
        };
    }
};
