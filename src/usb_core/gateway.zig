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
    recive_data: []const u8,
    recive_completed: void, //on short pkg or ZLP,
    class_setup: *const SetupPacket,
    standard_setup: *const StandardRequestData,
};

pub const InterfaceEventOut = union(enum) {
    STALL,
    ZLP,
    send_data: []const u8,
    recive_data,
    None,
};

pub const InterfaceGateway = struct {
    instance: *const anyopaque,
    setup_call: ?*const fn (*const anyopaque, InterfaceEventIn) InterfaceEventOut,
    instance_num: ?usize,

    pub fn setup(self: *const @This(), event: InterfaceEventIn) GatewayError!InterfaceEventOut {
        if (self.setup_call) |handler| {
            return handler(self.instance, event);
        }
        return GatewayError.InvalidOp;
    }
};

pub const EP_State = enum {
    READY,
    NAK,
    STALL,
    NYET,
};

pub const EP_Dir = enum {
    In,
    Out,
};

pub const HardwareState = struct {
    pid: u4,
    state: EP_State,
};

// TODO: Add more methods
pub const EP_Gateway_API = struct {
    /// Current Driver instance
    driver: *const anyopaque,

    /// load data from Buffer to EP return the number of bytes send
    send_data: *const fn (*const anyopaque, EP_Num: u4, data: []const u8) GatewayError!usize,

    /// load data from EP to buffer return the number os bytes read
    receive_data: *const fn (*const anyopaque, EP_Num: u4, buf: []u8) GatewayError![]const u8,

    ///Set the state of a Ep
    set_ep_state: *const fn (*const anyopaque, dir: EP_Dir, EP_Num: u4, state: EP_State, force_pid: ?u4) GatewayError!void,

    get_ep_state: *const fn (*const anyopaque, dir: EP_Dir, EP_Num: u4) GatewayError!HardwareState,
};

pub const IO_CTRL = struct {
    pub inline fn send_data(self: *const IO_CTRL, data: []const u8) GatewayError!usize {
        const gate: *const EP_Gateway = @alignCast(@fieldParentPtr("ctrl", self));
        const ep = try gate.check_ep();
        if (gate.dir == .Out) return GatewayError.InvalidOp;
        return gate.hardware_api.send_data(gate.hardware_api.driver, ep, data);
    }

    pub inline fn receive_data(self: *const IO_CTRL, data: []u8) GatewayError![]const u8 {
        const gate: *const EP_Gateway = @alignCast(@fieldParentPtr("ctrl", self));
        const ep = try gate.check_ep();
        if (gate.dir == .In) return GatewayError.InvalidOp;
        return gate.hardware_api.receive_data(gate.hardware_api.driver, ep, data);
    }

    pub inline fn set_ep_state(self: *const IO_CTRL, state: EP_State, force_pid: ?u4) GatewayError!void {
        const gate: *const EP_Gateway = @alignCast(@fieldParentPtr("ctrl", self));
        const ep = try gate.check_ep();
        try gate.hardware_api.set_ep_state(gate.hardware_api.driver, gate.dir, ep, state, force_pid);
    }

    pub inline fn get_ep_state(self: *const IO_CTRL) GatewayError!HardwareState {
        const gate: *const EP_Gateway = @alignCast(@fieldParentPtr("ctrl", self));
        const ep = try gate.check_ep();
        return gate.hardware_api.get_ep_state(gate.hardware_api.driver, gate.dir, ep);
    }
};

pub const EP_Gateway = struct {
    //instance of the EP, used to notify events
    instance: *const anyopaque,

    //runtime core data for IO_CTRL
    hardware_api: *const EP_Gateway_API = undefined,
    dir: EP_Dir = undefined,
    ep: ?u4 = null,
    ctrl: IO_CTRL = .{},

    inline fn check_ep(self: *const EP_Gateway) GatewayError!u4 {
        return self.ep orelse GatewayError.GatewayOff;
    }
};
