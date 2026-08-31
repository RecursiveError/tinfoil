const std = @import("std");
const Endpoint = @import("endpoint.zig");
const descriptors = @import("USB/descriptors.zig");
const classes = @import("USB/classes.zig");
const Util = @import("meta_utils.zig");
const String = @import("strings.zig");
const Gateway = @import("gateway.zig");

pub const MetaInterface = struct {
    alternate_setting: u8,
    class_code: classes.DeviceClass,
    subclass_code: u8,
    protocol_code: u8,
    blobs: []const []const u8,
    endpoints: []const @EnumLiteral(),
    setup: ?*const fn (*const anyopaque, Gateway.InterfaceEventIn) Gateway.InterfaceEventOut,
    iInterface: String.USBStrings = .{},
    instance_num: ?usize = null,

    pub fn into_descriptor(self: @This(), number: u8, string_index: u8) descriptors.InterfaceDescriptor {
        return descriptors.InterfaceDescriptor{
            .bLength = descriptors.InterfaceDescriptor.size(),
            .bDescriptorType = @backingInt(descriptors.DescriptorType.Interface),
            .bInterfaceNumber = number,
            .bAlternateSetting = self.alternate_setting,
            .bNumEndpoints = @as(u8, @intCast(self.endpoints.len)),
            .bInterfaceClass = @as(u8, @backingInt(self.class_code)),
            .bInterfaceSubClass = self.subclass_code,
            .bInterfaceProtocol = self.protocol_code,
            .iInterface = string_index, //TODO: Add support for interface string descriptors in the future.
        };
    }
};

pub const MetaIAD = struct {
    bFunctionClass: u8,
    bFunctionSubClass: u8,
    bFunctionProtocol: u8,
    iFunction: String.USBStrings = .{},
    interfaces: []const MetaInterface,

    pub fn into_descriptor(self: @This(), start_interface: u8, string_index: u8) descriptors.InterfaceAssociationDescriptor {
        return descriptors.InterfaceAssociationDescriptor{
            .bLength = descriptors.InterfaceAssociationDescriptor.size(),
            .bDescriptorType = @backingInt(descriptors.DescriptorType.InterfaceAssociation),
            .bFunctionClass = self.bFunctionClass,
            .bFunctionSubClass = self.bFunctionSubClass,
            .bFunctionProtocol = self.bFunctionProtocol,
            .bInterfaceCount = self.interfaces.len,
            .bFirstInterface = start_interface,
            .iFunction = string_index,
        };
    }
};

pub const MetaDerive = struct {
    meta: []const Meta,
    from: @EnumLiteral(),
};

//TODO: Add more meta types in the future as needed
pub const Meta = union(enum) {
    IAD: MetaIAD,
    Interface: MetaInterface,
    Derive: MetaDerive,
};

pub fn derive_from(from: @EnumLiteral(), meta: []const Meta) MetaDerive {
    return MetaDerive{
        .from = from,
        .meta = meta,
    };
}

/// This function will process the provided meta information and generate the necessary descriptors.
///
/// receives a tuple containing RAW interface or pre processed meta information.
/// and returns an array of processed Meta structs that can be used for generating the final USB descriptors for the device.
pub fn processMetaInterface(T: type, comptime meta: anytype) []const Meta {
    var metas: [meta_len(meta)]Meta = undefined;
    // we already check if the provided meta is a tuple and if it contains only valid entries in the meta_len function,
    // so we can safely process it here without additional checks.
    var idx = 0;
    const type_info = @typeInfo(@TypeOf(meta));
    const st = type_info.@"struct";
    for (st.field_types, 0..) |fd, field_idx| {
        if (std.meta.eql(fd, MetaIAD)) {
            const iad: MetaIAD = meta[field_idx];
            metas[idx] = Meta{ .IAD = iad };
            for (iad.interfaces) |iface| {
                for (iface.endpoints) |ep| {
                    _ = check_valid_ep(T, ep); //will fail if EP is invalid
                }
            }
        } else if (std.meta.eql(fd, MetaInterface)) {
            const iface: MetaInterface = meta[field_idx];
            metas[idx] = Meta{ .Interface = iface };
            for (iface.endpoints) |ep| {
                _ = check_valid_ep(T, ep); //will fail if EP is invalid
            }
        } else if (std.meta.eql(fd, MetaDerive)) {
            const derive: MetaDerive = meta[field_idx];
            if (@hasField(T, @tagName(derive.from))) {
                metas[idx] = Meta{ .Derive = derive };
            } else {
                @compileError(std.fmt.comptimePrint("META PARSER ERROR: {s}:{s} does not exist", .{ @typeName(T), @tagName(derive.from) }));
            }
        } else {
            unreachable;
        }
        idx += 1;
    }
    return metas[0..idx];
}

fn meta_len(comptime meta: anytype) comptime_int {
    var count = 0;
    const type_info = @typeInfo(@TypeOf(meta));
    if (type_info != .@"struct") @compileError("ERROR: processMetaInterface expects a tuple");
    const st = type_info.@"struct";
    if (!st.is_tuple) @compileError("ERROR: processMetaInterface expects a tuple");
    for (st.field_types) |fd| {
        if (std.meta.eql(fd, MetaIAD) or
            std.meta.eql(fd, MetaInterface) or
            std.meta.eql(fd, MetaDerive))
        {
            count += 1;
        } else {
            @compileError("ERROR: processMetaInterface expects only IADs, Interface or Derives in the tuple");
        }
    }
    return count;
}

pub fn check_valid_ep(base_T: type, ep: @EnumLiteral()) Endpoint.Config {
    const T = Util.PathFieldType(base_T, @tagName(ep));
    if (!@hasField(T, "event")) @compileError(std.fmt.comptimePrint("META PARSER ERROR: {s} is not a valid EP", .{@tagName(ep)}));
    const event_type = @FieldType(T, "event");
    if (!std.meta.eql(event_type, Endpoint.EventHandler)) @compileError(std.fmt.comptimePrint("META PARSER ERROR: {s} is not a valid EP", .{@tagName(ep)}));
    if (@hasDecl(T, "get_options")) {
        const config = T.get_options();
        if (std.meta.eql(Endpoint.Config, @TypeOf(config))) {
            return config;
        } else {
            @compileError(std.fmt.comptimePrint("META PARSER ERROR: on node {s}\n expected a type {s} found {s}", .{ @tagName(ep), @typeName(Endpoint.Config), @typeName(config) }));
        }
    } else {
        @compileError(std.fmt.comptimePrint("META PARSER ERROR: fail to find EP: .{s} on type {s}", .{ @tagName(ep), @typeName(T) }));
    }
}
