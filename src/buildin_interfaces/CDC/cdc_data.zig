// reusable data structures for CDC data interfaces

const std = @import("std");
const Core = @import("core");
const Endpoint = Core.Endpoint.Endpoint;
const Meta = Core.Meta;

pub const CDC_data = struct {
    const ReaderVtable = std.Io.Reader.VTable{
        .stream = stream,
    };
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

    enabled: std.atomic.Value(bool) = .init(false),
    rx_ready: std.atomic.Value(bool) = .init(false),
    tx_ready: std.atomic.Value(bool) = .init(true),

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
        const inner: *CDC_data = @fieldParentPtr("bulk_out", ep);
        inner.rx_ready.store(true, .monotonic);
    }

    fn tx(self: *const anyopaque, _: Core.Endpoint.EpEvent) void {
        const ep: *@FieldType(@This(), "bulk_in") = @ptrCast(@alignCast(@constCast(self)));
        const inner: *CDC_data = @fieldParentPtr("bulk_in", ep);
        inner.tx_ready.store(true, .release);
    }

    fn setup_handler(inst: *const anyopaque, event: Core.Gateway.InterfaceEventIn) Core.Gateway.InterfaceEventOut {
        const self: *@This() = @ptrCast(@alignCast(@constCast(inst)));

        switch (event) {
            .enabled => {
                self.bulk_out.ctrl.set_ep_state(.READY, 0) catch @panic("CDC ENABLE FAIL");
                self.bulk_in.ctrl.set_ep_state(.NAK, 0) catch @panic("CDC ENABLE FAIL");

                self.enabled.store(true, .monotonic);
            },
            else => {},
        }
        return .None;
    }

    fn stream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *CDC_data = @fieldParentPtr("reader", r);
        //check if interface is enabled
        if (!self.enabled.load(.monotonic)) return std.Io.Reader.StreamError.EndOfStream;
        //check if for peding data
        if (!self.rx_ready.load(.monotonic)) return 0;
        const min: usize = @backingInt(limit.min(@fromBackingInt(@intCast(self.pend_read.len))));
        const ret = try w.write(self.pend_read[0..min]);
        if (ret == self.pend_read.len) {
            self.rx_ready.store(false, .monotonic);
            self.bulk_out.ctrl.set_ep_state(.READY, null) catch return std.Io.Reader.StreamError.ReadFailed;
        } else {
            const aux = self.pend_read;
            self.pend_read = aux[min..];
        }
        return min;
    }

    pub fn send_data(self: *CDC_data, data: []const u8) !void {
        while (!self.tx_ready.load(.monotonic)) {}
        self.tx_ready.store(false, .release);
        _ = try self.bulk_in.ctrl.send_data(data);
        try self.bulk_in.ctrl.set_ep_state(.READY, null);
        while (!self.tx_ready.load(.monotonic)) {}
    }

    pub fn recv_data(self: *CDC_data, buf: []u8) ![]const u8 {
        while (!self.rx_ready.load(.acquire)) {}
        self.rx_ready.store(false, .monotonic);
        const ret = try self.bulk_out.ctrl.receive_data(buf);
        try self.bulk_out.ctrl.set_ep_state(.READY, null);
        return ret;
    }

    pub fn init() CDC_data {
        return CDC_data{
            .bulk_in = .{
                .event = tx,
            },
            .bulk_out = .{
                .event = rx,
            },
        };
    }
};
