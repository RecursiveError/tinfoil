//re-exports

pub const Endpoint = @import("endpoint.zig");
pub const Config = @import("config_gen.zig");
pub const EventCore = @import("event_core.zig");
pub const Meta = @import("meta.zig");
pub const Strings = @import("strings.zig");
pub const Driver = @import("driver.zig");
pub const Gateway = @import("gateway.zig");
pub const Descritors = struct {
    const base = @import("USB/descriptors.zig");
    pub const SetupPacket = base.SetupPacket;
};
