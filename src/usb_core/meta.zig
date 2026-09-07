//this file contains the meta information for the USB device, it is used to generate the USB descriptors and other necessary information for the device.
//Meta information is expected to be processed by a meta parser before being used to generate the final USB descriptors, the meta parser will check for errors and generate the necessary information for the device.
//manully creating the meta information is possible but not recommended, as it is error prone and can lead to undefined behavior if not done correctly.

const std = @import("std");
const Endpoint = @import("endpoint.zig");
const descriptors = @import("USB/descriptors.zig");
const classes = @import("USB/classes.zig");
const Util = @import("meta_utils.zig");
const String = @import("strings.zig");
const Gateway = @import("gateway.zig");

pub const InterfaceLocalId = struct {
    parent: []const u8,
    Instance_num: usize,
};

///data that will be resolved by the config generator at compile time, this data is used to generate the final USB descriptors for the device.
pub const Blob = union(enum) {
    /// Resolve to the interface number of the interface with the provided local id.
    InterfaceNumber: InterfaceLocalId,

    ///Resolved to the configuration number for which this blob will be generated.
    ConfigurationNumber: void,

    ///Resolved to the string index  of the interface of this blob.
    IfaceIndex: void,

    ///Resolved to the Configuration String index which this blob will be generated for.
    IConfigIndex: void,

    ///Raw data, no operation will be performed on this data, it will be copied as is to the final USB descriptors.
    Raw: []const u8,

    pub fn interface_num(id: @EnumLiteral(), instance: usize) Blob {
        return Blob{ .InterfaceNumber = .{ .Instance_num = instance, .parent = @tagName(id) } };
    }

    pub fn raw(data: []const u8) Blob {
        return Blob{ .Raw = data };
    }
};

pub const MetaInterface = struct {
    alternate_setting: u8,
    class_code: classes.DeviceClass,
    subclass_code: u8,
    protocol_code: u8,
    blobs: []const Blob = &.{},
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

    ///automatically calculated in the meta parser, if no meta parser is used the user should manually set this value to the correct number of interfaces in the IAD.
    ///important note: if the user manually sets this value to an incorrect number of interfaces in the IAD, the device will not work correctly and may cause undefined behavior.
    ///config generation will only check if the value is set, but will not check if it is correct.
    interfaces_num: ?usize = null,

    pub fn into_descriptor(self: @This(), start_interface: u8, string_index: u8) descriptors.InterfaceAssociationDescriptor {
        return descriptors.InterfaceAssociationDescriptor{
            .bLength = descriptors.InterfaceAssociationDescriptor.size(),
            .bDescriptorType = @backingInt(descriptors.DescriptorType.InterfaceAssociation),
            .bFunctionClass = self.bFunctionClass,
            .bFunctionSubClass = self.bFunctionSubClass,
            .bFunctionProtocol = self.bFunctionProtocol,
            .bInterfaceCount = self.interfaces_num orelse unreachable, //automatically calculated, this value is set by the meta parser and should not be set manually.
            .bFirstInterface = start_interface,
            .iFunction = string_index,
        };
    }
};

pub const MetaDerive = struct {
    meta: []const Meta,
    id: @EnumLiteral(),

    pub fn from(id: @EnumLiteral(), meta: []const Meta) MetaDerive {
        return MetaDerive{
            .id = id,
            .meta = meta,
        };
    }
};

///same as derive but with checking if the provided from type is flat.
/// in this case flat means that the provided type is a struct with only MetaInterfaces and FlatMetaDerives as fields, and no other fields or nested structs.
pub const FlatMetaDerive = struct {
    meta: []const Meta,
    id: @EnumLiteral(),

    pub fn from(id: @EnumLiteral(), meta: []const Meta) FlatMetaDerive {
        return FlatMetaDerive{
            .id = id,
            .meta = meta,
        };
    }
};

///IAD_End is only used to mark the end of an IAD for the meta parser comptime checks, it does not generate any descriptors and is not used in the final descriptor generation.
///if meta parser is not used the user should manually set the interfaces_num field of the IAD to the correct value.
pub const IAD_End = struct {};

//TODO: Add more meta types in the future as needed
pub const Meta = union(enum) {
    IAD: MetaIAD,
    Interface: MetaInterface,
    Derive: MetaDerive,
    FlatDerive: MetaDerive,
};

/// This function will process the provided meta information and generate the necessary descriptors.
///
/// receives a tuple containing RAW interface or pre processed meta information.
/// and returns an array of processed Meta structs that can be used for generating the final USB descriptors for the device.
pub fn processMetaInterface(T: type, comptime meta: anytype) []const Meta {
    const main_type_name = @typeName(T);
    var metas: [meta_len(meta)]Meta = undefined;
    // we already check if the provided meta is a tuple and if it contains only valid entries in the meta_len function,
    // so we can safely process it here without additional checks.

    const type_info = @typeInfo(@TypeOf(meta)).@"struct";
    const names = type_info.field_names;
    const types = type_info.field_types;

    var meta_idx: usize = 0;
    var iad_count: usize = 0;
    var last_iad_idx: ?usize = null;

    for (0..types.len) |fd_idx| {
        const fd_t = types[fd_idx];
        const fd_name = names[fd_idx];

        if (std.meta.eql(fd_t, MetaIAD)) {
            if (last_iad_idx) |_| {
                @compileError(std.fmt.comptimePrint(
                    \\META PARSER ERROR:
                    \\ Nested IADs on type {s}.
                    \\ New IAD found on field {s} but the previous IAD on field {s} has not been closed yet.
                    \\
                    \\tip: close the previous IAD by adding an IAD_End after the last interface of the previous IAD.
                    \\
                , .{
                    main_type_name,
                    fd_name,
                    names[last_iad_idx.?],
                }));
            }
            last_iad_idx = meta_idx;
            metas[meta_idx] = Meta{ .IAD = meta[fd_idx] };
            meta_idx += 1;
        } else if (std.meta.eql(fd_t, MetaInterface)) {
            const iface: MetaInterface = meta[fd_idx];
            for (iface.endpoints) |ep| {
                _ = check_valid_ep(T, ep);
            }
            for (iface.blobs) |blob| {
                switch (blob) {
                    .InterfaceNumber => |id| {
                        if (id.parent.len == 0) continue;
                        _ = Util.PathFieldType(T, id.parent);
                    },
                    else => {},
                }
            }
            metas[meta_idx] = Meta{ .Interface = iface };
            meta_idx += 1;

            //if we are inside an IAD, we need to increment the interface count of the IAD.
            if (last_iad_idx) |_| iad_count += 1;
        } else if (std.meta.eql(fd_t, MetaDerive)) {
            if (last_iad_idx) |_| {
                @compileError(std.fmt.comptimePrint(
                    \\META PARSER ERROR:
                    \\ Derive inside an IAD on {s}.{s}.
                    \\
                    \\tip: use FlatMetaDerive instead of Derive if you want to derive a flat type inside an IAD.
                    \\
                , .{
                    main_type_name,
                    names[last_iad_idx.?],
                }));
            }
            metas[meta_idx] = Meta{ .Derive = meta[fd_idx] };
            meta_idx += 1;
        } else if (std.meta.eql(fd_t, FlatMetaDerive)) {
            const flat_derive: FlatMetaDerive = meta[fd_idx];
            //check if the provided type is flat, if not throw a compile error.
            const flat_len = blk: {
                var count: usize = 0;
                for (flat_derive.meta) |m| {
                    switch (m) {
                        .Interface => count += 1,
                        .FlatDerive => |derive| count += derive.meta.len,
                        else => @compileError(std.fmt.comptimePrint(
                            \\META PARSER ERROR:
                            \\ FlatMetaDerive on {s}.{s} contains a non flat meta: {s}.
                            \\
                            \\tip: use Derive instead of FlatMetaDerive if you want to derive a non flat type.
                            \\
                        , .{
                            main_type_name,
                            fd_name,
                            @tagName(m),
                        })),
                    }
                }
                break :blk count;
            };

            if (last_iad_idx) |_| iad_count += flat_len;
            metas[meta_idx] = Meta{ .FlatDerive = .{ .id = flat_derive.id, .meta = flat_derive.meta } };
            meta_idx += 1;
        } else if (std.meta.eql(fd_t, IAD_End)) {
            if (last_iad_idx) |idx| {
                if (iad_count == 0) {
                    @compileError(std.fmt.comptimePrint(
                        \\META PARSER ERROR:
                        \\ IAD on {s}.{s} has no interfaces.
                        \\
                        \\tip: add at least one interface to the IAD before the IAD_End.
                        \\
                    , .{
                        main_type_name,
                        names[idx],
                    }));
                }
                metas[idx].IAD.interfaces_num = iad_count;
                last_iad_idx = null;
                iad_count = 0;
            } else {
                @compileError(std.fmt.comptimePrint(
                    \\META PARSER ERROR:
                    \\ IAD_End on {s}.{s} without a matching IAD.
                    \\
                    \\tip: add an IAD before the IAD_End to mark the start of an IAD.
                    \\
                , .{
                    main_type_name,
                    fd_name,
                }));
            }
        } else unreachable; //we already check if the provided meta is a tuple and if it contains only valid entries in the meta_len function, so we can safely assume that the provided meta is valid here.
    }

    if (last_iad_idx) |idx| {
        if (iad_count == 0) {
            @compileError(std.fmt.comptimePrint(
                \\META PARSER ERROR:
                \\ IAD on {s}.{s} has no interfaces.
                \\
                \\tip: add at least one interface to the IAD before the IAD_End.
                \\
            , .{
                main_type_name,
                names[idx],
            }));
        }
        metas[idx].IAD.interfaces_num = iad_count;
    }

    return metas[0..meta_idx];
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
            std.meta.eql(fd, MetaDerive) or
            std.meta.eql(fd, FlatMetaDerive))
        {
            count += 1;
        } else if (std.meta.eql(fd, IAD_End)) {
            // IAD_End is only used to mark the end of an IAD, it does not count as a meta entry.
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
