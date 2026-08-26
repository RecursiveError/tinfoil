// default implementation of the event handling core / guide lines for the event handling core
// this entire USB stack is designed to be completely customizable, so despite this being the default implementation, it is not a standard to follow.

const std = @import("std");
const Endpoint = @import("endpoint.zig");
const Descriptors = @import("USB/descriptors.zig");
const ConfigGen = @import("config_gen.zig");
const Gateway = @import("gateway.zig");
const Descriptor = @import("USB/descriptors.zig");

const EpGateway = Gateway.EpGateway;
const InterfaceGateway = Gateway.InterfaceGateway;
const ConfigOutput = ConfigGen.ConfigOut;

const StringError = error{
    IndexOutOfBounds,
    LangIdNotSupported,
    NoString,
};

pub const EpRecvEvent = struct { ep_num: u4, data: usize };

pub const EventIn = union(enum) {
    reset: void,
    setup: void,
    ep_send_data: u4,
    ep_recive_data: EpRecvEvent,
};

pub const EventOut = union(enum) {
    got_addr: u16,
    config_eps: Driver.ConfigAssignment,
};

pub const EventError = error{
    NO_CONFIG,
    INVALID_EP,
    EP0_FAIL,
    INVALID_SETUP,
    INVALID_INTERFACE_CALL,
    NOT_IMPLEMENTED,
};

pub const CoreState = union(enum) {
    IDLE,
    ZLP,
    addr_setup: u16,
    sending_data: struct {
        data: []const u8,
        index: usize,
    },
};

pub const EventCore = struct {
    ep0_len: usize,
    device_blob: []const u8,
    config_blob: []const ConfigOutput,
    device_quili_blob: ?[]const u8 = null, //TODO: Add support to USB-HS

    id_len: usize,
    string_id_mapper: []const usize,
    string_blob: [*]const usize,
    all_strings: []const []const u8,

    interface_gateway: []InterfaceGateway,
    ep_gateway: []EpGateway,
    buffer: []u8,

    enabled: bool = false,
    API: *const Gateway.EpGatewayAPI = undefined,

    actual_config: ?*const ConfigOutput = null,
    state: CoreState = .IDLE,

    pub fn init(
        device_blob: []const u8,
        config_blob: []const ConfigOutput,
        id_len: usize, //how many entrys of string_id_mapper exist in string blob.
        string_blob: [*]const usize,
        string_id_mapper: []const usize,
        all_strings: []const []const u8,
        interface_gateway: []InterfaceGateway,
        ep_gateway: []EpGateway,
        buffer: []u8,
    ) EventCore {
        const ep0_len: usize = device_blob[7];
        return EventCore{
            .device_blob = device_blob,
            .config_blob = config_blob,

            .id_len = id_len,
            .string_id_mapper = string_id_mapper,
            .string_blob = string_blob,
            .all_strings = all_strings,

            .interface_gateway = interface_gateway,
            .ep_gateway = ep_gateway,
            .buffer = buffer,
            .ep0_len = ep0_len,
        };
    }

    // init from any kinf of blob that has the same layout as StandardDeviceBlob.
    // just a helper function to make it easier to use the event core with the standard device blob.
    pub fn init_from_blob(blob: anytype, buffer: []u8) EventCore {
        const blob_type = blk: {
            switch (@typeInfo(@TypeOf(blob))) {
                .pointer => |ptr| {
                    if (ptr.attrs.@"const") {
                        @compileError("blob must be mutable");
                    }
                    break :blk ptr.child;
                },
                else => @compileError("blob must be a pointer to a struct"),
            }
        };

        const device_blob = &blob_type.device_blob;
        const config_blob = &blob_type.config_blobs;
        const string_id_mapper = &@field(blob_type.string_blobs, "id_map");
        const string_blob = &@field(blob_type.string_blobs, "string_indexes");
        const all_strings = @field(blob_type.string_blobs, "all_strings");
        const interface_gateway = &@field(blob, "interfaces");
        const ep_gateway = &@field(blob, "endpoints");

        const ep0_len: usize = device_blob[7];

        return EventCore{
            .device_blob = device_blob,
            .config_blob = config_blob,
            .id_len = string_blob.len,
            .string_id_mapper = string_id_mapper,
            .string_blob = @ptrCast(string_blob.ptr),
            .all_strings = all_strings,
            .interface_gateway = interface_gateway,
            .ep_gateway = ep_gateway,
            .buffer = buffer,
            .ep0_len = ep0_len,
        };
    }

    pub fn enable_core(self: *EventCore, api: *const Gateway.EpGatewayAPI) void {
        self.API = api;
        for (self.ep_gateway) |*ep| {
            ep.hardware_api = self.API;
            const ep_inst = Endpoint.restore_ep(ep.instance);
            ep_inst.CTRL = ep;
            self.enabled = true;
        }
    }

    pub fn disable_core(self: *EventCore) void {
        for (self.ep_gateway) |*ep| {
            ep.ep = null;
            const ep_inst = Endpoint.restore_ep(ep.instance);
            ep_inst.event(ep.instance, .disable);
        }
        for (self.interface_gateway) |*inter| {
            if (inter.setup_call) |callback| {
                callback(inter.instance, .disable);
            }
        }
        self.enabled = false;
    }

    pub fn get_string(self: *const EventCore, index: usize, lang_id: usize) StringError![]const u8 {
        if (index > self.id_len) return StringError.IndexOutOfBounds;
        if (index == 0) return self.all_strings[0];
        const id_index = std.mem.find(usize, self.string_id_mapper, &.{lang_id}) orelse return StringError.LangIdNotSupported;
        const blob_idx = self.string_blob[index * self.string_id_mapper.len + id_index];
        if (blob_idx == 0) return StringError.NoString;

        return self.all_strings[blob_idx];
    }

    pub fn get_ep_gateway(self: *const EventCore, ep_num: u4, dir: Gateway.EpDir) EventError!*const Gateway.EpGateway {
        const conf = self.actual_config orelse return EventError.NO_CONFIG;
        const ep = switch (dir) {
            .In => conf.endpoint_assignment.in[ep_num - 1],
            .Out => conf.endpoint_assignment.out[ep_num - 1],
        };

        switch (ep) {
            .unused => return EventError.INVALID_EP,
            .assigned => |gate| {
                return &self.ep_gateway[gate.gateway_num];
            },
        }
    }

    pub fn process(self: *EventCore, event: EventIn) EventError!?EventOut {
        switch (event) {
            .reset => {
                if (self.actual_config) |conf| {
                    for (conf.interfaces_map) |inter| {
                        const iface = &self.interface_gateway[inter];
                        if (iface.setup_call) |setup| {
                            _ = setup(iface.instance, .disable);
                        }
                    }
                }
            },
            .setup => return try self.ep0_setup(),
            .ep_recive_data => |data| {
                const num = data.ep_num;
                if (num == 0) {
                    return self.ep0_rx();
                } else {
                    const gateway = try self.get_ep_gateway(num, .Out);
                    const ep = Endpoint.restore_ep(gateway.instance);
                    ep.event(gateway.instance, .ACK);
                }
            },
            .ep_send_data => |num| {
                if (num == 0) {
                    return self.ep0_tx();
                } else {
                    const gateway = try self.get_ep_gateway(num, .In);
                    const ep = Endpoint.restore_ep(gateway.instance);
                    ep.event(gateway.instance, .ACK);
                }
            },
        }
        return null;
    }

    inline fn ep0_read_api(self: *const EventCore, buf: []u8) EventError![]const u8 {
        return self.API.recive_data(self.API.driver, 0, buf) catch return EventError.EP0_FAIL;
    }

    inline fn ep0_send_api(self: *const EventCore, buf: []const u8) EventError!usize {
        return self.API.send_data(self.API.driver, 0, buf) catch return EventError.EP0_FAIL;
    }

    inline fn ep0_state_api(self: *const EventCore, dir: Gateway.EpDir, state: Gateway.EpState, force_pid: ?u4) EventError!void {
        return self.API.set_ep_state(self.API.driver, dir, 0, state, force_pid) catch return EventError.EP0_FAIL;
    }

    fn ep0_setup(self: *EventCore) EventError!?EventOut {
        self.state = .IDLE;
        const setup = try self.ep0_read_api(self.buffer);
        if (setup.len == 0) return EventError.INVALID_SETUP;
        const pkg = Descriptor.SetupPacket.parse(setup) catch return EventError.INVALID_SETUP;

        return switch (pkg.typ()) {
            .Standard => self.standart_setup(&pkg),
            .Class => self.class_setup(&pkg),
            else => EventError.NOT_IMPLEMENTED,
        };
    }

    fn ep0_rx(self: *EventCore) EventError!?EventOut {
        try self.ep0_state_api(.Out, .READY, null);
        return null;
    }

    fn ep0_tx(self: *EventCore) EventError!?EventOut {
        switch (self.state) {
            .IDLE => {
                try self.ep0_state_api(.Out, .READY, null);
            },
            .ZLP => {
                _ = try self.ep0_send_api(&.{});
                try self.ep0_state_api(.In, .READY, null);
                self.state = .IDLE;
            },
            .addr_setup => |addr| {
                try self.ep0_state_api(.Out, .READY, null);
                self.state = .IDLE;
                return EventOut{ .got_addr = addr };
            },

            .sending_data => |data| {
                const new_slice = data.data[data.index..];
                const min = @min(new_slice.len, self.ep0_len);
                const loaded = try self.ep0_send_api(new_slice[0..min]);
                if ((loaded + data.index) >= data.data.len and loaded == self.ep0_len) {
                    self.state = .ZLP;
                } else if ((loaded + data.index) >= data.data.len and loaded != self.ep0_len) {
                    self.state = .IDLE;
                } else {
                    self.state.sending_data.index += loaded;
                }

                try self.ep0_state_api(.In, .READY, null);
            },
        }
        return null;
    }

    fn get_interface_gateway(self: *const EventCore, index: usize) EventError!*const InterfaceGateway {
        return blk: {
            if (self.actual_config) |conf| {
                if (conf.interfaces_map.len > index) {
                    break :blk &self.interface_gateway[conf.interfaces_map[index]];
                }
            }
            break :blk EventError.INVALID_SETUP;
        };
    }

    //TODO: add more handlers
    fn standart_setup(self: *EventCore, setup: *const Descriptor.SetupPacket) EventError!?EventOut {
        const reciv = setup.recipient();
        const req_parsed = setup.standardRequest() catch unreachable;

        switch (req_parsed) {
            .GetDescriptor => |des| {
                const desct_num: u8 = des.descriptor_type;
                const index: u8 = des.index;
                const len = des.length;
                const to_send: []const u8 = blk: {
                    switch (reciv) {
                        .Device => {
                            switch (desct_num) {
                                0x01 => break :blk self.device_blob,
                                0x02 => break :blk self.config_blob[index].raw,
                                0x03 => {
                                    break :blk self.get_string(index, setup.wIndex) catch {
                                        try self.ep0_state_api(.In, .STALL, null);
                                        return null;
                                    };
                                },
                                0x06 => {
                                    break :blk self.device_quili_blob orelse {
                                        try self.ep0_state_api(.In, .STALL, null);
                                        return null;
                                    };
                                },
                                else => return EventError.NOT_IMPLEMENTED,
                            }
                        },
                        .Interface => {
                            const gate = try self.get_interface_gateway(setup.wIndex);
                            const ret = gate.setup(.{ .standart_setup = &req_parsed }) catch return EventError.INVALID_INTERFACE_CALL;

                            switch (ret) {
                                .send_data => |data| break :blk data,
                                else => return EventError.INVALID_SETUP,
                            }
                        },
                        else => return EventError.NOT_IMPLEMENTED,
                    }
                };
                const min = @min(to_send.len, len, self.ep0_len);
                const loaded = try self.ep0_send_api(to_send[0..min]);

                //check for imediate ZLP
                if (loaded == to_send.len and to_send.len == self.ep0_len) {
                    self.state = .ZLP;
                } else if (loaded < to_send.len and loaded < len) {
                    const new_min = @min(len, to_send.len);
                    self.state = .{ .sending_data = .{ .data = to_send[0..new_min], .index = loaded } };
                }
                try self.ep0_state_api(.In, .READY, null);
            },
            .SetAddress => |addr| {
                _ = try self.ep0_send_api(&.{});
                try self.ep0_state_api(.In, .READY, null);
                self.state = .{ .addr_setup = addr };
            },
            .SetConfiguration => |iconf| {
                if (iconf == 0) {
                    try self.ep0_state_api(.In, .STALL, null);
                    return null;
                }
                const conf = &self.config_blob[iconf - 1];
                //set eps
                for (conf.endpoint_assignment.in, conf.endpoint_assignment.out, 0..) |in, out, idx| {
                    switch (in) {
                        .assigned => |ca| {
                            const gate = &self.ep_gateway[ca.gateway_num];
                            gate.dir = .In;
                            gate.ep = @intCast(idx);
                        },
                        .unused => {},
                    }
                    switch (out) {
                        .assigned => |ca| {
                            const gate = &self.ep_gateway[ca.gateway_num];
                            gate.dir = .Out;
                            gate.ep = @intCast(idx);
                        },
                        .unused => {},
                    }
                }

                for (conf.interfaces_map) |if_idx| {
                    const iface = self.interface_gateway[if_idx];
                    if (iface.setup_call) |setup_call| {
                        _ = setup_call(iface.instance, .enabled);
                    }
                }

                self.actual_config = conf;
                _ = try self.ep0_send_api(&.{});
                try self.ep0_state_api(.In, .READY, null);
                return .{ .config_eps = conf.endpoint_assignment };
            },
            .ClearFeature => |feature| {
                switch (reciv) {
                    .Endpoint => {
                        const ep: u4 = @intCast(setup.wIndex & 0x0F);
                        const dir: Gateway.EpDir = if ((setup.wIndex & 0x80) == 0) Gateway.EpDir.Out else Gateway.EpDir.In;

                        const gate = try self.get_ep_gateway(ep, dir);

                        switch (feature) {
                            0x0 => {
                                const st = gate.get_ep_state() catch return EventError.INVALID_SETUP;
                                if (st.state == .STALL) {
                                    gate.set_ep_state(.NAK, null) catch return EventError.INVALID_EP;
                                }
                            },
                            else => return EventError.NOT_IMPLEMENTED,
                        }
                        _ = try self.ep0_send_api(&.{});
                        try self.ep0_state_api(.In, .READY, null);
                    },
                    else => return EventError.NOT_IMPLEMENTED,
                }
            },
            else => return EventError.NOT_IMPLEMENTED,
        }
        return null;
    }

    fn class_setup(self: *EventCore, setup: *const Descriptor.SetupPacket) EventError!?EventOut {
        switch (setup.recipient()) {
            .Interface => {
                const gate = try self.get_interface_gateway(setup.wIndex);
                const ret = gate.setup(.{ .class_setup = setup }) catch return EventError.INVALID_INTERFACE_CALL;
                try self.class_event_out(ret);
            },
            else => return EventError.NOT_IMPLEMENTED,
        }
        return null;
    }

    fn class_event_out(self: *const EventCore, event: Gateway.InterfaceEventOut) EventError!void {
        switch (event) {
            .ZLP => {
                _ = try self.ep0_send_api(&.{});
                try self.ep0_state_api(.In, .READY, null);
            },
            .STALL => {
                try self.ep0_state_api(.In, .STALL, null);
            },
            .send_data => {},
            else => {},
        }
    }
};

//Tests

const Driver = @import("driver.zig");
const Strings = @import("strings.zig");
const Meta = @import("meta.zig");

const DeviceConfig = ConfigGen.DeviceConfig;
const Config = ConfigGen.Config;
const DeviceBuilder = ConfigGen.DeviceBuilder;

const LANGID = Strings.LANGID;
const USBStrings = Strings.USBStrings;

// This is mock driver rules, in a real scenario, this should be set by the driver.
const EndpointRules = Driver.EndpointCapabilities{
    .in = @splat(Driver.EPConfig{ .enabled = .{
        .supported_types = .{
            .bulk = true,
            .interrupt = true,
            .iso = false,
        },
        .max_packet_size = 64,
    } }),
    .out = @splat(Driver.EPConfig{ .enabled = .{
        .supported_types = .{
            .bulk = true,
            .interrupt = true,
            .iso = false,
        },
        .max_packet_size = 64,
    } }),
    .EP0_max_size = 64,
};

//strings

const manufacturer_string = USBStrings{
    .fallback = &Strings.StringToUSB("Test Manufacturer"),
    .portuguese_brazil = &Strings.StringToUSB("Fabricante de Teste"),
};

const product_string = USBStrings{
    .fallback = &Strings.StringToUSB("Test Product"),
    .portuguese_brazil = &Strings.StringToUSB("Produto de Teste"),
};

const serial_number_string = USBStrings{
    .fallback = &Strings.StringToUSB("1234567890"),
    .portuguese_brazil = &Strings.StringToUSB("0987654321"),
};

const config_string1 = USBStrings{
    .fallback = &Strings.StringToUSB("Test Config"),
    .portuguese_brazil = &Strings.StringToUSB("Configuração de Teste"),
};

const config_string2 = USBStrings{
    .fallback = &Strings.StringToUSB("Test Config 2"),
    .portuguese_brazil = &Strings.StringToUSB("Configuração de Teste 2"),
};

const config_string3 = USBStrings{
    .fallback = &Strings.StringToUSB("Test Config 3"),
    .portuguese_brazil = &Strings.StringToUSB("Configuração de Teste 3"),
};

const foo_interface_string = USBStrings{
    .fallback = &Strings.StringToUSB("Foo Interface 1"),
    .portuguese_brazil = &Strings.StringToUSB("Interface  Foo"),
};

//this is a mock device config
const SomeRules = DeviceConfig{
    //.Device_class = .{ .class_code = .Hid, .subclass = 0x1, .protocol = 0x01 }, <- this is the expected way to set device class in the future, but for now we will use the old way to set it.
    .USB_version = 0x0200,
    .Device_class = .Hid,
    .subclass = 0x1,
    .protocol = 0x01,
    .id_vendor = 0x1234,
    .id_product = 0x5678,
    .bcd_device = 0x0100,
    .suported_languages = &.{ LANGID.english_us, LANGID.portuguese_brazil },
    .manufacturer = manufacturer_string,
    .product = product_string,
    .serial_number = serial_number_string,
    .endpoint_rules = EndpointRules, // in this test we set manually the endpoint rules, but in a real scenario, this should be set by the driver.
};

const Foo = struct {
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

    ep1_foo: usize = 0,
    ep2_foo: usize = 0,

    fn ep1_handler(self: *const anyopaque, _: Endpoint.EpEvent) void {
        const ep: *@FieldType(Foo, "ep1") = @ptrCast(@alignCast(@constCast(self)));
        const foo: *Foo = @fieldParentPtr("ep1", ep);

        std.debug.print("Foo EP1 Handler called \n", .{});
        foo.ep1_foo += 1;
    }

    fn ep2_handler(self: *const anyopaque, _: Endpoint.EpEvent) void {
        const ep: *@FieldType(Foo, "ep2") = @ptrCast(@alignCast(@constCast(self)));
        const foo: *Foo = @fieldParentPtr("ep2", ep);

        std.debug.print("Foo EP2 Handler called \n", .{});
        foo.ep2_foo += 1;
    }

    pub fn init() Foo {
        return Foo{
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
                .setup = null,
                .iInterface = foo_interface_string,
            },
        });
    }
};

const Bar = struct {
    FooBar: Foo,

    fn ep1_handler(self: *const anyopaque, _: Endpoint.EpEvent) void {
        const ep: *@FieldType(Foo, "ep1") = @ptrCast(@alignCast(@constCast(self)));
        const foo: *Foo = @fieldParentPtr("ep1", ep);

        std.debug.print("Bar EP1 Handler called \n", .{});
        foo.ep1_foo += 1;
    }

    fn ep2_handler(self: *const anyopaque, _: Endpoint.EpEvent) void {
        const ep: *@FieldType(Foo, "ep2") = @ptrCast(@alignCast(@constCast(self)));
        const foo: *Foo = @fieldParentPtr("ep2", ep);

        std.debug.print("Bar EP2 Handler called \n", .{});
        foo.ep2_foo += 1;
    }

    pub fn init() Bar {
        return Bar{ .FooBar = Foo{
            .ep1 = .{
                .event = ep1_handler,
            },
            .ep2 = .{
                .event = ep2_handler,
            },
        } };
    }

    pub fn into_meta() []const Meta.Meta {
        return Meta.processMetaInterface(@This(), .{
            Meta.derive_from(.FooBar, Foo.into_meta()),
        });
    }
};

test "EventCore test" {
    var buf: [128]u8 = undefined;
    var foo: Foo = .init();
    var bar: Bar = .init();

    try std.testing.expect(foo.ep1_foo == 0);
    try std.testing.expect(foo.ep2_foo == 0);
    try std.testing.expect(bar.FooBar.ep1_foo == 0);
    try std.testing.expect(bar.FooBar.ep2_foo == 0);

    var ret = DeviceBuilder(
        SomeRules,
        .{
            .foo = &foo,
            .bar = &bar,
        },
        &.{
            Config{
                .attributes = 0x80,
                .max_power = 0x32,
                .iConfig = config_string1,
                .interfaces = &.{
                    .foo,
                    .bar,
                },
            },
            Config{
                .attributes = 0x80,
                .max_power = 0x32,
                .iConfig = config_string2,
                .interfaces = &.{
                    .foo,
                },
            },
            Config{
                .attributes = 0x80,
                .max_power = 0x32,
                .iConfig = config_string3,
                .interfaces = &.{
                    .bar,
                },
            },
        },
    );

    const core = EventCore.init_from_blob(&ret, &buf);

    std.debug.print("Raw Config Descriptor: \n", .{});
    for (core.config_blob) |c| {
        std.debug.print("   - Raw Config Descriptor: {x}\n", .{c.raw});
    }

    std.debug.print("STRING RAW DESCRIPTORS\n", .{});
    for (0..core.id_len) |idx| {
        for (core.string_id_mapper) |id| {
            const str = try core.get_string(idx, id);
            std.debug.print("   - |Index {d}, Lang {x:0>4}| {x}\n", .{ idx, id, str });
        }
    }

    // ------ endpoint path find test ------

    for (core.config_blob[0].endpoint_assignment.in) |in| {
        switch (in) {
            .assigned => |a| {
                const ep = core.ep_gateway[a.gateway_num];
                Endpoint.restore_ep(ep.instance).event(ep.instance, .ACK);
            },
            else => {},
        }
    }

    for (core.config_blob[0].endpoint_assignment.out) |out| {
        switch (out) {
            .assigned => |a| {
                const ep = core.ep_gateway[a.gateway_num];
                Endpoint.restore_ep(ep.instance).event(ep.instance, .ACK);
            },
            else => {},
        }
    }
    //config 0 have both Foo and Bar interfaces
    try std.testing.expect(foo.ep1_foo == 1);
    try std.testing.expect(foo.ep2_foo == 1);
    try std.testing.expect(bar.FooBar.ep1_foo == 1);
    try std.testing.expect(bar.FooBar.ep2_foo == 1);

    for (core.config_blob[1].endpoint_assignment.in) |in| {
        switch (in) {
            .assigned => |a| {
                const ep = core.ep_gateway[a.gateway_num];
                Endpoint.restore_ep(ep.instance).event(ep.instance, .ACK);
            },
            else => {},
        }
    }

    for (core.config_blob[1].endpoint_assignment.out) |out| {
        switch (out) {
            .assigned => |a| {
                const ep = core.ep_gateway[a.gateway_num];
                Endpoint.restore_ep(ep.instance).event(ep.instance, .ACK);
            },
            else => {},
        }
    }
    //config 1 only have Foo
    try std.testing.expect(foo.ep1_foo == 2);
    try std.testing.expect(foo.ep2_foo == 2);
    try std.testing.expect(bar.FooBar.ep1_foo == 1);
    try std.testing.expect(bar.FooBar.ep2_foo == 1);

    for (core.config_blob[2].endpoint_assignment.in) |in| {
        switch (in) {
            .assigned => |a| {
                const ep = core.ep_gateway[a.gateway_num];
                Endpoint.restore_ep(ep.instance).event(ep.instance, .ACK);
            },
            else => {},
        }
    }

    for (core.config_blob[2].endpoint_assignment.out) |out| {
        switch (out) {
            .assigned => |a| {
                const ep = core.ep_gateway[a.gateway_num];
                Endpoint.restore_ep(ep.instance).event(ep.instance, .ACK);
            },
            else => {},
        }
    }
    //config 2 only have Bar
    try std.testing.expect(foo.ep1_foo == 2);
    try std.testing.expect(foo.ep2_foo == 2);
    try std.testing.expect(bar.FooBar.ep1_foo == 2);
    try std.testing.expect(bar.FooBar.ep2_foo == 2);
}
