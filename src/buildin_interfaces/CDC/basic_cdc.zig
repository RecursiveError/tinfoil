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
    baudrate: u32 = 115200,
    stopbits: StopBits = .@"1",
    parity: Parity = .None,
    data: u8 = 8,

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

    fn to_pkg(self: Encoding) [7]u8 {
        return .{
            @truncate(self.baudrate),
            @truncate(self.baudrate >> 8),
            @truncate(self.baudrate >> 16),
            @truncate(self.baudrate >> 24),
            @backingInt(self.stopbits),
            @backingInt(self.parity),
            self.data,
        };
    }
};

const SerialState = packed struct(u8) {
    DTR: u1 = 0,
    RTS: u1 = 0,
    _res: u6 = 0,
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
    encoding: Encoding,
    state: SerialState = .{},
    encode_buf: [7]u8 = undefined,

    fn ep_handler(self: *const anyopaque, _: Core.Endpoint.EpEvent) void {
        const ep: *@FieldType(@This(), "cdc_ctrl_ep") = @ptrCast(@alignCast(@constCast(self)));

        //this example does not support Serial RTS/DTS/CTS
        // send fixed pkg
        _ = ep.ctrl.send_data(&.{ 0xA1, 0x20, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00 }) catch {};
        //ep.ctrl.set_ep_state(.READY, null) catch @panic("CDC CTRL FAIL");
    }

    fn setup_handler(inst: *const anyopaque, event: Core.Gateway.InterfaceEventIn) Core.Gateway.InterfaceEventOut {
        const self: *@This() = @ptrCast(@alignCast(@constCast(inst)));

        switch (event) {
            .enabled => {
                _ = self.cdc_ctrl_ep.ctrl.send_data(&.{ 0xA1, 0x20, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00 }) catch {};
                self.cdc_ctrl_ep.ctrl.set_ep_state(.READY, 0) catch @panic("CDC ENABLE FAIL");
                self.lock.unlock();
            },
            .class_setup => |setup| {
                switch (setup.bRequest) {
                    0x20 => {
                        //set_line_encoding
                        return .recive_data;
                    },
                    0x21 => {
                        //get_line_encoding
                        self.encode_buf = self.encoding.to_pkg();
                        return .{ .send_data = &self.encode_buf };
                    },
                    0x22 => {
                        self.state = @bitCast(@as(u8, @truncate(setup.wValue)));
                        return .ZLP;
                    },
                    0x23 => return .ZLP,
                    else => return .STALL,
                }
            },
            .recive_data => |data| {
                //this interface can only recives the set_line_encoding
                // so no need for any kind of state machine

                self.encoding = Encoding.from_pkg(data) catch return .STALL;
            },
            .recive_completed => return .ZLP,
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
                    // CDC Header Functional Descriptor
                    .raw(&.{ 0x05, 0x24, 0x00, 0x10, 0x01 }),
                    // CDC ACM Functional Descriptor
                    .raw(&.{ 0x04, 0x24, 0x02, 0x06 }),
                    // CDC Call Management Functional Descriptor
                    .raw(&.{ 0x05, 0x24, 0x01, 0x02 }),
                    .extern_interface_num(.data_interface, 0),
                    // CDC Union Functional Descriptor
                    .raw(&.{ 0x05, 0x24, 0x06 }),
                    .self_interface_num(),
                    .extern_interface_num(.data_interface, 0),
                },
                .endpoints = &.{.cdc_ctrl_ep},
                .setup = setup_handler,
            },
            Meta.FlatMetaDerive.from(.data_interface, CDC_data.into_meta()),
        });
    }

    pub fn init(encode: Encoding) @This() {
        return @This(){
            .cdc_ctrl_ep = .{
                .event = ep_handler,
            },
            .encoding = encode,
            .data_interface = .init(),
        };
    }
};
