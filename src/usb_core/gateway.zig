const Descriptor = @import("USB/descriptors.zig");
pub const SetupPacket = Descriptor.SetupPacket;
pub const StandardRequestData = Descriptor.StandardRequestData;

pub const GatewayError = error{
    GatewayOff,
    InvalidOp,
    InternalError,
};

pub const InterfaceEventIn = union(enum) {
    enabled: void,
    disable: void,
    send_complete: []const u8,
    class_setup: *const SetupPacket,
    standart_setup: *const StandardRequestData,
};

pub const InterfaceEventOut = union(enum) {
    STALL,
    ZLP,
    send_data: []const u8,
    None,
};

pub const InterfaceGateway = struct {
    instance: *const anyopaque,
    setup_call: ?*const fn (*const anyopaque, InterfaceEventIn) InterfaceEventOut,

    pub fn setup(self: *const @This(), event: InterfaceEventIn) GatewayError!InterfaceEventOut {
        if (self.setup_call) |handler| {
            return handler(self.instance, event);
        }
        return GatewayError.InvalidOp;
    }
};

pub const EpState = enum {
    READY,
    NAK,
    STALL,
    NYET,
};

pub const EpDir = enum {
    In,
    Out,
};

pub const HardwareState = struct {
    pid: u4,
    state: EpState,
};

// TODO: Add more methods
pub const EpGatewayAPI = struct {
    /// Current Driver instance
    driver: *const anyopaque,

    /// load data from Buffer to EP return the number of bytes send
    send_data: *const fn (*const anyopaque, EpNum: u4, data: []const u8) GatewayError!usize,

    /// load data from EP to buffer return the number os bytes read
    recive_data: *const fn (*const anyopaque, EpNum: u4, buf: []u8) GatewayError![]const u8,

    ///Set the state of a Ep
    set_ep_state: *const fn (*const anyopaque, dir: EpDir, EpNum: u4, state: EpState, force_pid: ?u4) GatewayError!void,

    get_ep_state: *const fn (*const anyopaque, dir: EpDir, EpNum: u4) GatewayError!HardwareState,
};

pub const EpGateway = struct {
    //instance of the EP, used to notify events
    instance: *const anyopaque,

    //runtime core data for IO_CTRL
    hardware_api: *const EpGatewayAPI = undefined,
    dir: EpDir = undefined,
    ep: ?u4 = null,

    inline fn check_ep(self: *const EpGateway) GatewayError!u4 {
        return self.ep orelse GatewayError.GatewayOff;
    }

    pub inline fn send_data(self: *const EpGateway, data: []const u8) GatewayError!usize {
        const ep = try self.check_ep();
        if (self.dir == .Out) return GatewayError.InvalidOp;
        return self.hardware_api.send_data(self.hardware_api.driver, ep, self.dir, data);
    }

    pub inline fn recive_data(self: *const EpGateway, data: []u8) GatewayError![]const u8 {
        const ep = try self.check_ep();
        if (self.dir == .In) return GatewayError.InvalidOp;
        return self.hardware_api.recive_data(self.hardware_api.driver, ep, self.dir, data);
    }

    pub inline fn set_ep_state(self: *const EpGateway, state: EpState, force_pid: ?u4) GatewayError!void {
        const ep = try self.check_ep();
        try self.hardware_api.set_ep_state(self.hardware_api.driver, self.dir, ep, state, force_pid);
    }

    pub inline fn get_ep_state(self: *const EpGateway) GatewayError!HardwareState {
        const ep = try self.check_ep();
        return self.hardware_api.get_ep_state(self.hardware_api.driver, self.dir, ep);
    }
};

pub const IO_CTRL = *const EpGateway;
