///Endpoint Types and related helpers.
const std = @import("std");
const descriptors = @import("USB/descriptors.zig");
const Gateway = @import("gateway.zig");
const EndpointDescriptor = descriptors.EndpointDescriptor;

pub const EpEvent = union(enum) {
    ///ep completed a op.
    ACK: void,

    ///ep failed a op.
    /// not all hardwares can generate this event.
    FAIL: void,
};
pub const EventHandler = *const fn (*const anyopaque, EpEvent) void;

pub const EndpointDirection = enum(u1) {
    Out = 0,
    In = 1,
};

pub const IsochronousSyncType = enum(u2) {
    NoSync = 0,
    Async = 1,
    Adaptive = 2,
    Sync = 3,
};

pub const IsochronousUsageType = enum(u2) {
    Data = 0,
    Feedback = 1,
    ExplicitFeedbackData = 2,
    Reserved = 3,
};

pub const AdditionalTransactionOpportunities = enum(u2) {
    None = 0,
    One = 1,
    Two = 2,
};

pub const EndpointEnum = enum {
    Control,
    Interrupt,
    Isochronous,
    Bulk,
};

pub const EndpointTypes = union(EndpointEnum) {
    Control: void,
    Interrupt: struct {
        ATO: AdditionalTransactionOpportunities = .None,
    },
    Isochronous: struct {
        sync_type: IsochronousSyncType = .NoSync,
        usage_type: IsochronousUsageType = .Data,
        ATO: AdditionalTransactionOpportunities = .None,
    },
    Bulk: void,

    pub fn into_enum(self: @This()) EndpointEnum {
        return switch (self) {
            .Control => EndpointEnum.Control,
            .Interrupt => EndpointEnum.Interrupt,
            .Isochronous => EndpointEnum.Isochronous,
            .Bulk => EndpointEnum.Bulk,
        };
    }
};

/// EP are ny default automatically enumerated starting from 1
/// but the user can set a custom bias for the endpoint numbers if needed.
pub const EP_Bias = union(enum) {
    automatic, //normal bias
    soft_bias: u4, //try to use the provided bias for the endpoint number, but if it's already used, fallback to automatic enumeration.
    hard_bias: u4, //try to use the provided bias for the endpoint number, if it's already used, return an error at compile time.
};

//TODO: Add check for different USB speeds. for now the user must set manually.
pub const Config = struct {
    ep_type: EndpointTypes,
    direction: EndpointDirection,
    interval: u8,
    max_packet_size: u16 = 32,
    ep_bias: EP_Bias = .automatic,
};

fn no_op_event_handler(_: *const anyopaque, _: EpEvent) void {}

pub fn Endpoint(comptime config: Config) type {
    switch (config.ep_bias) {
        .hard_bias => |bias| {
            comptime {
                if (bias == 0) @compileError("Endpoint bias cannot be 0, as it would conflict with EP0.");
                if (bias > 15) @compileError("Endpoint bias cannot be greater than 15, as the endpoint number is represented by 4 bits.");
            }
        },
        .soft_bias => |bias| {
            comptime {
                if (bias == 0) @compileError("Endpoint bias cannot be 0, as it would conflict with EP0.");
                if (bias > 15) @compileError("Endpoint bias cannot be greater than 15, as the endpoint number is represented by 4 bits.");
            }
        },
        .automatic => {},
    }
    return struct {
        event: EventHandler = no_op_event_handler,
        ctrl: *const Gateway.IO_CTRL = undefined,

        pub fn into_descriptor(ep_num: u4) EndpointDescriptor {
            //Only in USB HS, for now we will assume that the user will set the ATO field correctly based on the USB speed they intend to use.
            const ATO = switch (config.ep_type) {
                .Control => 0b00,
                .Isochronous => |info| @as(u16, @backingInt(info.ATO)) << 11,
                .Bulk => 0b00,
                .Interrupt => |info| @as(u16, @backingInt(info.ATO)) << 11,
            };

            const bmAttributes = switch (config.ep_type) {
                .Control => 0b00,
                .Isochronous => |info| 0b01 | (@as(u8, @backingInt(info.sync_type)) << 2) | (@as(u8, @backingInt(info.usage_type)) << 4),
                .Bulk => 0b10,
                .Interrupt => 0b11,
            };

            return EndpointDescriptor{
                .bLength = 7,
                .bDescriptorType = @backingInt(descriptors.DescriptorType.Endpoint),
                .bEndpointAddress = (ep_num & 0x0F) | (@as(u8, @backingInt(config.direction)) << 7),
                .bmAttributes = bmAttributes,
                .wMaxPacketSize = config.max_packet_size | ATO,
                .bInterval = config.interval,
            };
        }

        pub fn get_options() Config {
            return config;
        }
    };
}

const GenericEP = Endpoint(.{
    .ep_type = .Control,
    .direction = .In,
    .interval = 0,
});

pub fn restore_ep(ep: *const anyopaque) *GenericEP {
    return @as(*GenericEP, @ptrCast(@alignCast(@constCast(ep))));
}
