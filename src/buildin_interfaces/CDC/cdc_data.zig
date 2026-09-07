// reusable data structures for CDC data interfaces

const std = @import("std");
const Core = @import("core");
const Endpoint = Core.Endpoint.Endpoint;
const Meta = Core.Meta;

pub const CDC_data = struct {
    bulk_in: Endpoint(.{
        .direction = .In,
        .ep_type = .Bulk,
        .max_packet_size = 64,
        .interval = 0,
    }),

    bulk_out: Endpoint(.{
        .direction = .Out,
        .ep_type = .Bulk,
        .max_packet_size = 64,
        .interval = 0,
    }),

    lock: std.atomic.Mutex = .locked,

    //for now lets just use fixed size buffers.
    tx_buffer: [64]u8 = undefined,
    rx_buffer: [64]u8 = undefined,

    pub fn into_meta() []const Meta.Meta {
        return Meta.processMetaInterface(@This(), .{
            Meta.MetaInterface{
                .alternate_setting = 0,
                .class_code = .CDCData,
                .subclass_code = 0x00,
                .protocol_code = 0x00,
                .iInterface = .{ .fallback = &Core.Strings.StringToUSB("CDC DATA") },
                .endpoints = &.{ .bulk_in, .bulk_out },
                .setup = setup_handler,
                .instance_num = 0, //<- ID of this interface on this type
            },
        });
    }

    fn rx(self: *const anyopaque, _: Core.Endpoint.EpEvent) void {
        //TODO: implement a ring buffer for the reader and writer
        const ep: *@FieldType(@This(), "bulk_out") = @ptrCast(@alignCast(@constCast(self)));
        ep.ctrl.set_ep_state(.READY, null) catch @panic("CDC DATA RX FAIL");
    }

    fn tx(_: *const anyopaque, _: Core.Endpoint.EpEvent) void {
        //TODO: implement a ring buffer for the reader and writer
    }

    fn setup_handler(inst: *const anyopaque, event: Core.Gateway.InterfaceEventIn) Core.Gateway.InterfaceEventOut {
        const self: *@This() = @ptrCast(@alignCast(@constCast(inst)));

        switch (event) {
            .enabled => {
                self.bulk_out.ctrl.set_ep_state(.READY, 0) catch @panic("CDC ENABLE FAIL");
                self.bulk_in.ctrl.set_ep_state(.NAK, 0) catch @panic("CDC ENABLE FAIL");
                self.lock.unlock();
            },
            else => {},
        }
        return .None;
    }

    pub fn init() @This() {
        return @This(){
            .bulk_in = .{
                .event = tx,
            },
            .bulk_out = .{
                .event = rx,
            },
        };
    }
};
