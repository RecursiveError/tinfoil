const std = @import("std");

const Descriptors = @import("USB/descriptors.zig");
const Meta = @import("meta.zig");
const Utils = @import("meta_utils.zig");
const Endpoint = @import("endpoint.zig");
const Driver = @import("driver.zig");
const Classes = @import("USB/classes.zig");
const Strings = @import("strings.zig");
const Gateway = @import("gateway.zig");

const InterfaceGateway = Gateway.InterfaceGateway;
const ep_gateway = Gateway.EP_Gateway;

pub const EndpointMap = struct {
    out: [15]?usize = @splat(null),
    in: [15]?usize = @splat(null),
};

pub const Config = struct {
    iConfig: Strings.USBStrings = .{},
    attributes: u8,
    max_power: u8,

    /// the interface name used in the all_interfaces param
    /// will comptime fail if not found
    interfaces: []const @EnumLiteral(),
};

const InnerInterfaceMap = struct {
    runtime_index: usize,
    data: Meta.MetaInterface,
    endpoint_start_idx: usize,
    inner_string_index: usize = 0,
};

const InnerIADMap = struct {
    data: Meta.MetaIAD,
    interfaces_start_idx: usize,
    inner_string_index: usize = 0,
};

const InnerInterfaces = struct {
    parent: []const u8,
    meta: union(enum) {
        interface_idx: usize,
        iad: InnerIADMap,
    },
};

const InnerEP = struct {
    current_address: u8 = undefined,
    config: Endpoint.Config,
};

const InnerMapInterface = struct {
    path: []const u8,
    setup: ?*const fn (*const anyopaque, Gateway.InterfaceEventIn) Gateway.InterfaceEventOut,
    instance_num: ?usize,
};

//TODO marge class and subclass/protocol into a single type, and add support for class specific descriptors in the future.
pub const DeviceConfig = struct {
    USB_version: u16,
    Device_class: Classes.DeviceClass,
    subclass: u8,
    protocol: u8,
    id_vendor: u16,
    id_product: u16,
    bcd_device: u16,
    supported_languages: []const Strings.LANGID,
    manufacturer: Strings.USBStrings = .{},
    product: Strings.USBStrings = .{},
    serial_number: Strings.USBStrings = .{},
    endpoint_rules: Driver.EndpointCapabilities,
};

///Out blobs of each configuration
pub const ConfigOut = struct {
    raw: []const u8, //raw config descriptor data
    interfaces_map: []const usize, //map interface index to interface gateway index
    endpoint_assignment: Driver.ConfigAssignment, // data to be sent to the driver after a configuration is selected
};

///string blobs of the device, MUST BE KEEP IN SYNC WITH THE BLOBS IN THE DEVICE BLOB, the order of the strings in this blob must be the same as the order of the string descriptors in the device blob.
pub fn StringBlob(comptime dev: DeviceConfig) type {
    return struct {
        pub const id_len = dev.supported_languages.len;
        /// this array holds the layout of the string descriptors.
        /// the order of Lang-Ids in this array corresponds to the order of the string descriptors in a String Index.
        /// Example: if the array is [LANGID.en, LANGID.pt_br], then ALL string index will have the English string descriptor first, followed by the Portuguese (Brazil) string descriptor.
        id_map: [id_len]usize,

        /// this array holds the indexes of the strings in the all_strings buffer, for each string index.
        /// indexes are 0 based, but index 0 is reserved for the LANGID string descriptor and index 1-3 are reserved for the manufacturer, product and serial number string descriptors, respectively.
        string_indexes: []const [id_len]usize,

        /// this buffer holds ALL the strings used in the device, including the manufacturer, product, serial number and configuration strings.
        all_strings: []const []const u8,
    };
}

pub fn OutBlob(comptime dev: DeviceConfig, comptime configs: []const Config) type {
    return struct {
        string_blobs: StringBlob(dev) = undefined,
        config_blobs: [configs.len]ConfigOut = undefined,
    };
}

pub fn StdDeviceBlob(all: type, comptime configs: []const Config, comptime device: DeviceConfig) type {
    @setEvalBranchQuota(20000);
    const len = comptime calc_all_interface(all);
    const out = comptime gen_out_data(all, configs, device);
    const device_desc = comptime gen_device_descriptor(device, configs.len);
    return struct {
        pub const config_blobs = out.config_blobs;
        pub const string_blobs = out.string_blobs;
        pub const device_blob = device_desc;
        interfaces: [len.@"0"]InterfaceGateway,
        endpoints: [len.@"1"]ep_gateway,
    };
}

pub fn DeviceBuilder(comptime device: DeviceConfig, all_interfaces: anytype, comptime configs: []const Config) StdDeviceBlob(@TypeOf(all_interfaces), configs, device) {
    const iface_path = comptime get_interface_paths(@TypeOf(all_interfaces));
    const ep_path = comptime get_endpoint_paths(@TypeOf(all_interfaces));
    //gen config raw data based on type metadata:
    var blob = StdDeviceBlob(@TypeOf(all_interfaces), configs, device){
        .endpoints = undefined,
        .interfaces = undefined,
    };

    inline for (comptime iface_path, 0..) |path, idx| {
        blob.interfaces[idx] = InterfaceGateway{
            .instance = get_instance(all_interfaces, path.path),
            .setup_call = path.setup,
            .instance_num = path.instance_num,
        };
    }

    inline for (comptime ep_path, 0..) |path, idx| {
        blob.endpoints[idx] = ep_gateway{
            .instance = get_instance(all_interfaces, path),
        };
    }

    return blob;
}

fn get_instance(all: anytype, comptime path: []const u8) *const anyopaque {
    const dot = comptime std.mem.indexOfScalar(u8, path, '.');
    if (dot) |d| return Utils.resolve_path(@field(all, path[0..d]), path[d + 1 ..]);
    return @field(all, path);
}

/// returns the device descriptor for the given device configuration.
/// device descriptors are always 18 bytes long, so the size of the returned array is always 18.
fn gen_device_descriptor(comptime device: DeviceConfig, comptime config_len: usize) [18]u8 {

    //in this framework string index 1 - 3 are always reserved for: manufacturer, product and serial number string descriptors
    // so we can check if the string descriptors are empty and set the index to 0 if they are, otherwise set them to 1, 2 and 3 respectively.

    const manufacturer_index: u8 = if (device.manufacturer.check_string(device.supported_languages)) 1 else 0;
    const product_index: u8 = if (device.product.check_string(device.supported_languages)) 2 else 0;
    const serial_number_index: u8 = if (device.serial_number.check_string(device.supported_languages)) 3 else 0;

    const desc = Descriptors.DeviceDescriptor{
        .bLength = 18,
        .bDescriptorType = @backingInt(Descriptors.DescriptorType.Device),
        .bcdUSB = device.USB_version,
        .bDeviceClass = @backingInt(device.Device_class),
        .bDeviceSubClass = device.subclass,
        .bDeviceProtocol = device.protocol,
        .bMaxPacketSize0 = device.endpoint_rules.EP0_max_size,
        .idVendor = device.id_vendor,
        .idProduct = device.id_product,
        .bcdDevice = device.bcd_device,
        .iManufacturer = manufacturer_index,
        .iProduct = product_index,
        .iSerialNumber = serial_number_index,
        .bNumConfigurations = @intCast(config_len),
    };

    var raw: [18]u8 = undefined;
    _ = desc.writeTo(raw[0..18]) catch unreachable;
    return raw;
}

fn gen_out_data(all: type, comptime configs: []const Config, comptime device: DeviceConfig) OutBlob(device, configs) {
    comptime {
        const sizes = calc_all_interface(all);
        const strs = calc_max_strings(sizes.@"2", configs.len, device.supported_languages.len);
        const strs_entrys = sizes.@"2" + configs.len + 4; //interfaces + configs + 4 for manufacturer, product, serial number and LANGID string descriptors

        var string_blob: [strs][]const u8 = undefined;
        var string_mapper: [strs_entrys][device.supported_languages.len]usize = undefined;
        var string_id_mapper: [device.supported_languages.len]usize = undefined;
        var str_blob_idx: usize = 0;
        var str_mapper_idx: usize = 0;

        var OUT: [configs.len]ConfigOut = undefined;
        var iface_idx: usize = 0;
        var inner_interfaces: [sizes.@"0"]InnerInterfaceMap = undefined;

        var eps_idx: usize = 0;
        var inner_eps: [sizes.@"1"]InnerEP = undefined;

        var lookup_idx: usize = 0;
        var inner_lookup_table: [sizes.@"2"]InnerInterfaces = undefined;
        const st = @typeInfo(all).@"struct";
        for (st.field_names, st.field_types) |nf, fd| {
            const inner_t = @typeInfo(fd).pointer.child;
            const meta = inner_t.into_meta();
            get_meta_ir(
                inner_t,
                nf,
                meta,
                &iface_idx,
                &inner_interfaces,
                &eps_idx,
                &inner_eps,
                &lookup_idx,
                &inner_lookup_table,
            );
        }

        const used_interfaces = inner_interfaces[0..iface_idx];
        const used_eps = inner_eps[0..eps_idx];
        const used_lookup = inner_lookup_table[0..lookup_idx];

        // generate strings blobs before generating the config raw data, so we can use the string indexes in the config descriptors.
        // the order of the strings does not matter, as long as the string indexes are consistent with the string blob and string mapper
        //so we just load  Device->Interfaces->IAD->Config strings just becuase it is easier to reason about.

        //load the Device strings and the LANGID string descriptor into the string blob and string mapper.
        init_string_blob(
            device,
            &string_id_mapper,
            &string_blob,
            &string_mapper,
            &str_blob_idx,
            &str_mapper_idx,
        );

        //load interfaces/IAD and other strings into the string blob and string mapper.

        load_interface_strings(
            device,
            used_interfaces,
            used_lookup,
            &string_blob,
            &string_mapper,
            &str_blob_idx,
            &str_mapper_idx,
        );

        // finally load the configuration strings into the string blob and string mapper.

        for (configs, 0..) |c, i| {
            const config_string_index = apply_string(device.supported_languages.len, c.iConfig, device, &string_blob, &string_mapper, &str_blob_idx, &str_mapper_idx);
            OUT[i] = gen_config_out(c, i + 1, config_string_index, device.endpoint_rules, used_interfaces, used_eps, used_lookup);
        }

        const final_blob = blk: {
            var fixed: [str_blob_idx][]const u8 = undefined;
            for (0..str_blob_idx) |i| {
                fixed[i] = string_blob[i];
            }
            break :blk fixed;
        };

        const final_mapper = blk: {
            var fixed: [str_mapper_idx][device.supported_languages.len]usize = undefined;
            for (0..str_mapper_idx) |i| {
                fixed[i] = string_mapper[i];
            }
            break :blk fixed;
        };

        const blobs = StringBlob(device){
            .id_map = string_id_mapper,
            .all_strings = &final_blob,
            .string_indexes = &final_mapper,
        };
        return OutBlob(device, configs){
            .string_blobs = blobs,
            .config_blobs = OUT,
        };
    }
}

/// load initial string blobs and string mapper for the device, based on the device configuration and the supported languages.
fn init_string_blob(
    comptime device: DeviceConfig,
    comptime string_id_mapper: []usize,
    comptime string_blob: [][]const u8,
    comptime string_mapper: [][device.supported_languages.len]usize,
    comptime str_blob_idx: *usize,
    comptime str_mapper_idx: *usize,
) void {
    const lang_len = device.supported_languages.len;

    //load index 0 with the LANGID string descriptor, which is always present in the device.
    const total_len = (device.supported_languages.len * 2) + 2;
    comptime var idx_0: [total_len]u8 = undefined;
    idx_0[0] = @intCast(total_len);
    idx_0[1] = @backingInt(Descriptors.DescriptorType.String);

    for (device.supported_languages, 0..) |lang, i| {
        string_id_mapper[i] = @as(usize, @backingInt(lang));
        const raw: u16 = @backingInt(lang);
        const low_byte: u8 = @intCast(raw & 0xFF);
        const high_byte: u8 = @intCast((raw >> 8) & 0xFF);
        idx_0[(i * 2) + 2] = low_byte;
        idx_0[(i * 2 + 1) + 2] = high_byte;
    }

    const clean = idx_0;
    string_blob[0] = &clean;
    string_mapper[0] = @splat(0);
    str_mapper_idx.* += 1;
    str_blob_idx.* += 1;

    //no need to save de mapper id as those are always the same for all devices, and the string indexes are always 1, 2 and 3 for manufacturer, product and serial number respectively.
    _ = apply_string(lang_len, device.manufacturer, device, string_blob, string_mapper, str_blob_idx, str_mapper_idx);
    _ = apply_string(lang_len, device.product, device, string_blob, string_mapper, str_blob_idx, str_mapper_idx);
    _ = apply_string(lang_len, device.serial_number, device, string_blob, string_mapper, str_blob_idx, str_mapper_idx);
}

fn load_interface_strings(
    comptime device: DeviceConfig,
    comptime interfaces: []InnerInterfaceMap,
    comptime lookup_table: []InnerInterfaces,
    comptime string_blob: [][]const u8,
    comptime string_mapper: [][device.supported_languages.len]usize,
    comptime str_blob_idx: *usize,
    comptime str_mapper_idx: *usize,
) void {

    //load all interface strings into the string blob and string mapper
    for (interfaces) |*iface| {
        const string = iface.data.iInterface;
        iface.inner_string_index = apply_string(device.supported_languages.len, string, device, string_blob, string_mapper, str_blob_idx, str_mapper_idx);
    }

    //load all IAD strings into the string blob and string mapper
    for (lookup_table) |*lookup| {
        switch (lookup.meta) {
            .iad => |*iad| {
                const string = iad.data.iFunction;
                iad.inner_string_index = apply_string(device.supported_languages.len, string, device, string_blob, string_mapper, str_blob_idx, str_mapper_idx);
            },
            else => {},
        }
    }
}

fn gen_config_out(
    comptime c_config: Config,
    comptime config_index: usize,
    comptime config_string_index: usize,
    comptime EPRules: Driver.EndpointCapabilities,
    comptime interfaces: []const InnerInterfaceMap,
    comptime eps: []InnerEP,
    comptime lookup_table: []const InnerInterfaces,
) ConfigOut {
    comptime {
        const used_interfaces = c_config.interfaces;
        const max_interfaces = calc_interfaces(lookup_table, used_interfaces);
        const max_endpoints = calc_endpoints(lookup_table, interfaces, used_interfaces);
        const raw_size = 9 + (max_interfaces * 9) + (max_endpoints * 7) + (calc_IADs(lookup_table, used_interfaces) * 8) + calc_blobs(lookup_table, interfaces, used_interfaces);

        var raw: [raw_size]u8 = undefined;
        var interface_map: [max_interfaces]usize = undefined;

        var used_eps: [max_endpoints]usize = undefined;
        var ep_assignment: Driver.ConfigAssignment = .init();

        const config_descriptor = Descriptors.ConfigurationDescriptor{
            .bLength = 9,
            .bDescriptorType = @backingInt(Descriptors.DescriptorType.Configuration),
            .wTotalLength = @as(u16, raw_size),
            .bNumInterfaces = @as(u8, max_interfaces),
            .bConfigurationValue = @as(u8, config_index),
            .iConfiguration = @intCast(config_string_index),
            .bmAttributes = c_config.attributes,
            .bMaxPower = c_config.max_power,
        };

        load_used_eps(lookup_table, interfaces, used_interfaces, &used_eps);
        automatic_enumarate_ep(eps, &used_eps, EPRules, &ep_assignment);

        _ = config_descriptor.writeTo(raw[0..9]) catch unreachable; //write the config descriptor to the beginning of the raw data.
        gen_raw_config(
            raw[9..],
            interfaces,
            lookup_table,
            eps,
            used_interfaces,
            &interface_map,
        );
        const out_raw = raw;
        const out_interface_map = interface_map;
        return ConfigOut{
            .raw = &out_raw,
            .interfaces_map = &out_interface_map,
            .endpoint_assignment = ep_assignment,
        };
    }
}

//Util functions to generate the intermediate representation of the metadata.

/// Calculates the maximum number of strings that will be used in the device, based on the number of interfaces and supported languages.
/// assumes the worst case scenario, where all interfaces have strings for all supported languages, and the manufacturer, product and serial number strings are also present for all supported languages.
fn calc_max_strings(interfaces_len: usize, configs_len: usize, supported_languages: usize) usize {
    const device_strs = 3 * supported_languages + 1; //manufacturer, product and serial number strings}
    return device_strs + ((interfaces_len * supported_languages) * 2) + ((configs_len * supported_languages) * 2);
}

fn calc_gateway_len(meta: []const Meta.Meta) struct { usize, usize, usize } {
    var interface_len: usize = 0;
    var ep_len: usize = 0;
    var full_len: usize = 0;
    for (meta) |m| {
        switch (m) {
            .Interface => |iface| {
                interface_len += 1;
                ep_len += iface.endpoints.len;
                full_len += 1;
            },
            .IAD => {
                full_len += 1;
            },
            .Derive, .FlatDerive => |derive| {
                const ret = calc_gateway_len(derive.meta);
                interface_len += ret.@"0";
                ep_len += ret.@"1";
                full_len += ret.@"2";
            },
        }
    }
    return .{
        interface_len,
        ep_len,
        full_len,
    };
}

fn calc_all_interface(all: type) struct { usize, usize, usize } {
    const info = @typeInfo(all);
    var interfaces_len: comptime_int = 0;
    var endpoints_len: comptime_int = 0;
    var full_inter_len: comptime_int = 0;
    switch (info) {
        .@"struct" => |st| {
            for (st.field_types, st.field_names) |fd, name| {
                const inner = @typeInfo(fd);
                switch (inner) {
                    .pointer => |pt| {
                        const inter = pt.child;
                        if (@hasDecl(inter, "into_meta")) {
                            const meta = inter.into_meta();
                            if (std.meta.eql(@TypeOf(meta), []const Meta.Meta)) {
                                const ret = calc_gateway_len(meta);
                                interfaces_len += ret.@"0";
                                endpoints_len += ret.@"1";
                                full_inter_len += ret.@"2";
                            } else {
                                @compileError(std.fmt.comptimePrint("field: {s} type {s} into_meta function does not return valid metadata ([]const Meta)", .{ name, @typeName(inter) }));
                            }
                        } else {
                            @compileError(std.fmt.comptimePrint("field: {s} type {s} does not have a into_meta function", .{ name, @typeName(inter) }));
                        }
                    },
                    else => @compileError(std.fmt.comptimePrint("field: {s} is not a pointer to a interface instance", .{name})),
                }
            }
        },
        else => @compileError("all_interfaces need to be a struct!"),
    }
    return .{
        interfaces_len,
        endpoints_len,
        full_inter_len,
    };
}

fn calc_interfaces(all: []const InnerInterfaces, used: []const @EnumLiteral()) usize {
    var count: usize = 0;
    for (all) |i| {
        const point = std.mem.find(u8, i.parent, ".") orelse i.parent.len;

        for (used) |u| {
            if (std.mem.eql(u8, i.parent[0..point], @tagName(u))) {
                switch (i.meta) {
                    .interface_idx => count += 1,
                    else => {},
                }
            }
        }
    }
    return count;
}

fn calc_endpoints(all: []const InnerInterfaces, interfaces: []const InnerInterfaceMap, used: []const @EnumLiteral()) usize {
    var count: usize = 0;
    for (all) |i| {
        const point = std.mem.find(u8, i.parent, ".") orelse i.parent.len;
        for (used) |u| {
            if (std.mem.eql(u8, i.parent[0..point], @tagName(u))) {
                switch (i.meta) {
                    .interface_idx => count += interfaces[i.meta.interface_idx].data.endpoints.len,
                    else => {},
                }
            }
        }
    }
    return count;
}

fn calc_IADs(all: []const InnerInterfaces, used: []const @EnumLiteral()) usize {
    var count: usize = 0;
    for (all) |i| {
        const point = std.mem.find(u8, i.parent, ".") orelse i.parent.len;
        for (used) |u| {
            if (std.mem.eql(u8, i.parent[0..point], @tagName(u))) count += switch (i.meta) {
                .iad => 1,
                else => 0,
            };
        }
    }
    return count;
}

fn calc_blobs(all: []const InnerInterfaces, interfaces: []const InnerInterfaceMap, used: []const @EnumLiteral()) usize {
    var count: usize = 0;
    for (all) |i| {
        const point = std.mem.find(u8, i.parent, ".") orelse i.parent.len;
        for (used) |u| {
            if (std.mem.eql(u8, i.parent[0..point], @tagName(u))) {
                switch (i.meta) {
                    .interface_idx => {
                        const blobs = interfaces[i.meta.interface_idx].data.blobs;
                        for (blobs) |b| {
                            switch (b) {
                                .Raw => |data| count += data.len,
                                else => count += 1,
                            }
                        }
                    },
                    else => {},
                }
            }
        }
    }
    return count;
}

/// Populates the intermediate representation arrays of Meta, used to generate future configurations
fn get_meta_ir(
    inner_t: type,
    parent: [:0]const u8,
    meta: []const Meta.Meta,
    iface_idx: *usize,
    interfaces: []InnerInterfaceMap,
    eps_idx: *usize,
    eps: []InnerEP,
    lookup_idx: *usize,
    lookup: []InnerInterfaces,
) void {
    for (meta) |m| {
        switch (m) {
            .Interface => |iface| {
                apply_interface(inner_t, iface, eps_idx, eps, iface_idx, interfaces);
                lookup[lookup_idx.*] = InnerInterfaces{
                    .meta = .{ .interface_idx = iface_idx.* },
                    .parent = parent,
                };
                iface_idx.* += 1;
                lookup_idx.* += 1;
            },
            .IAD => |iad| {
                lookup[lookup_idx.*] = InnerInterfaces{
                    .meta = .{ .iad = .{
                        .data = iad,
                        .interfaces_start_idx = iface_idx.*,
                    } },
                    .parent = parent,
                };
                lookup_idx.* += 1;
            },
            .Derive, .FlatDerive => |to_derive| {
                if (@hasField(inner_t, @tagName(to_derive.id))) {
                    get_meta_ir(
                        @FieldType(inner_t, @tagName(to_derive.id)),
                        std.fmt.comptimePrint("{s}.{s}", .{ parent, @tagName(to_derive.id) }),
                        to_derive.meta,
                        iface_idx,
                        interfaces,
                        eps_idx,
                        eps,
                        lookup_idx,
                        lookup,
                    );
                } else {
                    @compileError(std.fmt.comptimePrint("Type {s} does not have a field: {s}", .{
                        @typeName(inner_t),
                        @tagName(to_derive.id),
                    }));
                }
            },
        }
    }
}

/// check for duplicate, save the string in the string blob and return the index of the string in the blob.
fn apply_string(
    comptime langs: usize,
    comptime to_apply: Strings.USBStrings,
    comptime device: DeviceConfig,
    comptime string_blob: [][]const u8,
    comptime string_mapper: [][langs]usize,
    comptime str_blob_idx: *usize,
    comptime str_mapper_idx: *usize,
) usize {
    var mapper: [langs]usize = @splat(0);

    inline for (device.supported_languages, 0..) |lang, i| {
        const maybe_str = to_apply.get_string(lang);
        const maybe_fallback = to_apply.fallback;
        if (maybe_str) |s| {
            const id = check_string_index(s, string_blob, str_blob_idx);
            mapper[i] = id;
        } else if (maybe_fallback) |fallback| {
            const id = check_string_index(fallback, string_blob, str_blob_idx);
            mapper[i] = id;
        }
    }

    for (0..str_mapper_idx.*) |i| {
        if (std.mem.eql(usize, mapper[0..], string_mapper[i][0..]))
            return i;
    }

    string_mapper[str_mapper_idx.*] = mapper;
    const out = str_mapper_idx.*;
    str_mapper_idx.* += 1;
    return out;
}

/// check or add the string to the string blob and return the index of the string in the blob.
fn check_string_index(to_apply: []const u8, blob: [][]const u8, blob_idx: *usize) usize {
    for (0..blob_idx.*) |i| {
        if (std.mem.eql(u8, to_apply, blob[i])) return i;
    }
    blob[blob_idx.*] = to_apply;
    const out = blob_idx.*;
    blob_idx.* += 1;
    return out;
}

fn apply_interface(
    T: type,
    iface: Meta.MetaInterface,
    eps_idx: *usize,
    eps: []InnerEP,
    iface_idx: *usize,
    interfaces: []InnerInterfaceMap,
) void {
    const start_ep = eps_idx.*;
    for (iface.endpoints) |ep| {
        const ep_config = Meta.check_valid_ep(T, ep);
        eps[eps_idx.*] = InnerEP{ .config = ep_config };
        eps_idx.* += 1;
    }
    interfaces[iface_idx.*] = InnerInterfaceMap{
        .runtime_index = iface_idx.*,
        .data = iface,
        .endpoint_start_idx = start_ep,
    };
}

fn check_ep(T: type, path: []const u8) Endpoint.Config {
    const out_t = Utils.PathFieldType(T, path);
    if (@hasDecl(out_t, "get_options")) {
        const opt = out_t.get_options();
        if (std.meta.eql(@TypeOf(opt), Endpoint.Config)) {
            return opt;
        }
    }
    @compileError(std.fmt.comptimePrint("No valid EP on: {s}:{s}", .{ @typeName(T), path }));
}

fn load_used_eps(all: []const InnerInterfaces, interfaces: []const InnerInterfaceMap, used: []const @EnumLiteral(), out: []usize) void {
    var idx: usize = 0;
    for (all) |i| {
        const point = std.mem.find(u8, i.parent, ".") orelse i.parent.len;
        for (used) |u| {
            if (std.mem.eql(u8, i.parent[0..point], @tagName(u))) {
                switch (i.meta) {
                    .interface_idx => |iface| {
                        inner_load(interfaces[iface], &idx, out);
                    },
                    else => {},
                }
            }
        }
    }
}

fn inner_load(interface: InnerInterfaceMap, idx: *usize, out: []usize) void {
    const len = interface.data.endpoints.len;
    const start = interface.endpoint_start_idx;
    for (0..len) |j| {
        out[idx.*] = start + j;
        idx.* += 1;
    }
}

fn automatic_enumarate_ep(
    inner: []InnerEP,
    used: []const usize,
    rules: Driver.EndpointCapabilities,
    assignment: *Driver.ConfigAssignment,
) void {
    // first assign the EPs with hard bias, then the ones with soft bias, then the automatic ones gets assigned to the remaining EP numbers.
    var used_memory: usize = 0;
    //hard bias assignment:
    for (used) |idx| {
        const ep = &inner[idx];

        const assignment_arr = switch (ep.config.direction) {
            .In => assignment.in[0..],
            .Out => assignment.out[0..],
        };

        const rules_arr = switch (ep.config.direction) {
            .In => rules.in[0..],
            .Out => rules.out[0..],
        };
        used_memory += ep.config.max_packet_size;
        switch (ep.config.ep_bias) {
            .hard_bias => |bias| {
                //bias is already checked to be valid ( bias != 0 and bias <= 15 ) in the Endpoint type, so we can just assign it directly.

                const ep_num = bias - 1; //endpoint numbers start from 1, but our array is 0 indexed.
                switch (assignment_arr[ep_num]) {
                    .unused => {},
                    else => {
                        @compileError(std.fmt.comptimePrint("EP bias conflict at EP{d}, EP Config {any} already assigned this EP", .{ bias, inner[assignment_arr[ep_num].assigned.gateway_num].config }));
                    },
                }

                //check for compatibility with the driver rules:
                const rule = rules_arr[ep_num];
                switch (rule.enabled) {
                    .disabled => @compileError(std.fmt.comptimePrint("EP bias conflict at EP{d}, EP Config {any} cannot be assigned to this EP because the driver does not support it", .{ bias, ep.config })),
                    .enabled => |r| {
                        if (!r.supported_types.bulk and ep.config.ep_type == .Bulk) @compileError(std.fmt.comptimePrint("EP bias conflict at EP{d}, EP Config {any} cannot be assigned to this EP because the driver does not support Bulk transfer type", .{ bias, ep.config }));
                        if (!r.supported_types.interrupt and ep.config.ep_type == .Interrupt) @compileError(std.fmt.comptimePrint("EP bias conflict at EP{d}, EP Config {any} cannot be assigned to this EP because the driver does not support Interrupt transfer type", .{ bias, ep.config }));
                        if (!r.supported_types.iso and ep.config.ep_type == .Isochronous) @compileError(std.fmt.comptimePrint("EP bias conflict at EP{d}, EP Config {any} cannot be assigned to this EP because the driver does not support Iso transfer type", .{ bias, ep.config }));
                        if (r.max_packet_size < ep.config.max_packet_size) @compileError(std.fmt.comptimePrint("EP bias conflict at EP{d}, EP Config {any} cannot be assigned to this EP because the driver does not support the required max packet size (max {d})", .{ bias, ep.config, r.max_packet_size }));
                    },
                }

                //assign the EP to the map and the driver assignment:
                assignment_arr[ep_num] = Driver.EPAssigned{
                    .assigned = .{
                        .transfer_type = ep.config.ep_type.into_enum(),
                        .packet_size = ep.config.max_packet_size,
                        .gateway_num = idx,
                    },
                };
                ep.current_address = bias;
            },
            else => {},
        }
    }

    //soft bias assignment: if the preferred EP number is available, assign it, otherwise fallback to automatic enumeration:
    for (used) |idx| {
        const ep = &inner[idx];
        const assignment_arr: []Driver.EPAssigned = switch (ep.config.direction) {
            .In => assignment.in[0..],
            .Out => assignment.out[0..],
        };

        const rules_arr = switch (ep.config.direction) {
            .In => rules.in[0..],
            .Out => rules.out[0..],
        };

        used_memory += ep.config.max_packet_size;

        switch (ep.config.ep_bias) {
            .soft_bias => |bias| {
                //check if the preferred EP number is available:
                ep.current_address = bias;
                //bias is already checked to be valid ( bias != 0 and bias <= 15 ) in the Endpoint type, so we can just assign it directly.

                const ep_num = bias - 1; //endpoint numbers start from 1, but our array is 0 indexed.
                switch (assignment_arr[ep_num]) {
                    .unused => {
                        const rule = rules_arr[ep_num];
                        switch (rule.enabled) {
                            .disabled => {
                                next_available_ep(idx, ep, assignment_arr, rules_arr);
                                continue;
                            },
                            .enabled => |r| {
                                if ((!r.supported_types.bulk and ep.config.ep_type == .Bulk) or
                                    (!r.supported_types.interrupt and ep.config.ep_type == .Interrupt) or
                                    (!r.supported_types.iso and ep.config.ep_type == .Isochronous) or
                                    (r.max_packet_size < ep.config.max_packet_size))
                                {
                                    next_available_ep(idx, ep, assignment_arr, rules_arr);
                                    continue;
                                }
                            },
                        }

                        //assign the EP to the map and the driver assignment:
                        assignment_arr[ep_num] = Driver.EPAssigned{
                            .assigned = .{
                                .transfer_type = ep.config.ep_type.into_enum(),
                                .packet_size = ep.config.max_packet_size,
                                .gateway_num = idx,
                            },
                        };
                        ep.current_address = bias;
                    },
                    else => {
                        next_available_ep(idx, ep, assignment_arr, rules_arr);
                    },
                }
            },
            else => {},
        }
    }

    //automatic
    for (used) |idx| {
        const ep = &inner[idx];
        const assignment_arr: []Driver.EPAssigned = switch (ep.config.direction) {
            .In => assignment.in[0..],
            .Out => assignment.out[0..],
        };

        const rules_arr = switch (ep.config.direction) {
            .In => rules.in[0..],
            .Out => rules.out[0..],
        };
        used_memory += ep.config.max_packet_size;

        switch (ep.config.ep_bias) {
            .automatic => next_available_ep(idx, ep, assignment_arr, rules_arr),
            else => {},
        }
    }

    if (rules.max_memory_bytes) |max| {
        if (used_memory > max) @compileError(std.fmt.comptimePrint("The total memory required by the assigned EPs ({d} bytes) exceeds the driver limit of {d} bytes", .{ used_memory, max }));
    }
}

fn next_available_ep(ep_idx: usize, ep: *InnerEP, assignment_arr: []Driver.EPAssigned, rules_arr: []const Driver.EPConfig) void {
    for (0..15) |ep_num| {
        switch (assignment_arr[ep_num]) {
            .unused => {
                //check for compatibility with the driver rules:
                const rule = rules_arr[ep_num];
                switch (rule) {
                    .disabled => {},
                    .enabled => |r| {
                        if (!r.supported_types.bulk and ep.config.ep_type == .Bulk) continue;
                        if (!r.supported_types.interrupt and ep.config.ep_type == .Interrupt) continue;
                        if (!r.supported_types.iso and ep.config.ep_type == .Isochronous) continue;
                        if (r.max_packet_size < ep.config.max_packet_size) continue;

                        //assign the EP to the map and the driver assignment:
                        assignment_arr[ep_num] = Driver.EPAssigned{
                            .assigned = .{
                                .transfer_type = ep.config.ep_type.into_enum(),
                                .packet_size = ep.config.max_packet_size,
                                .gateway_num = ep_idx,
                            },
                        };
                        ep.current_address = @as(u8, @intCast(ep_num + 1)); //endpoint numbers start from 1, but our array is 0 indexed.
                        return;
                    },
                }
            },
            else => {},
        }
    }
    @compileError(std.fmt.comptimePrint("No available EP for EP Config {any}", .{ep.config}));
}

fn gen_raw_config(
    out: []u8,
    interfaces: []const InnerInterfaceMap,
    lookup: []const InnerInterfaces,
    eps: []const InnerEP,
    used_interfaces: []const @EnumLiteral(),
    interface_map: []usize,
) void {
    var out_idx: usize = 0;
    var iface_idx: usize = 0;

    for (lookup) |l| {
        const point = std.mem.find(u8, l.parent, ".") orelse l.parent.len;
        for (used_interfaces) |u| {
            if (std.mem.eql(u8, l.parent[0..point], @tagName(u))) {
                switch (l.meta) {
                    .iad => |iad| {
                        const iad_desc = iad.data.into_descriptor(iface_idx, iad.inner_string_index);
                        _ = iad_desc.writeTo(out[out_idx .. out_idx + 8]) catch unreachable;
                        out_idx += 8;
                    },
                    .interface_idx => |idx| {
                        const iface = interfaces[idx];
                        inner_gen_raw_config(
                            interfaces,
                            lookup,
                            l.parent,
                            iface,
                            eps,
                            out[out_idx..],
                            &out_idx,
                            &iface_idx,
                        );
                        interface_map[iface_idx] = iface.runtime_index;
                        iface_idx += 1;
                    },
                }
            }
        }
    }
}

fn inner_gen_raw_config(
    interfaces: []const InnerInterfaceMap,
    lookup: []const InnerInterfaces,
    parent: []const u8,
    interface: InnerInterfaceMap,
    eps: []const InnerEP,
    out: []u8,
    out_idx: *usize,
    iface_idx: *usize,
) void {
    const inter_desc = interface.data.into_descriptor(iface_idx.*, interface.inner_string_index);
    const endpoint_len = interface.data.endpoints.len;
    const ep_slice = eps[interface.endpoint_start_idx .. interface.endpoint_start_idx + endpoint_len];
    var start_idx: usize = 9;
    _ = inter_desc.writeTo(out[0..9]) catch unreachable;
    //add blobs if they exist:

    for (interface.data.blobs) |blob| {
        switch (blob) {
            .Raw => |data| {
                std.mem.copyForwards(u8, out[start_idx..], data);
                start_idx += data.len;
            },
            .ExternInterfaceNumber => |id| {
                out[start_idx] = get_blob_iface_num(
                    interfaces,
                    lookup,
                    std.fmt.comptimePrint("{s}.{s}", .{ parent, id.parent }),
                    id.Instance_num,
                );
                start_idx += 1;
            },
            .SelfInterfaceNumber => {
                out[start_idx] = iface_idx.*;
                start_idx += 1;
            },
            else => {}, //TODO
        }
    }

    for (ep_slice) |ep| {
        const ep_desc = Endpoint.Endpoint(ep.config).into_descriptor(@truncate(ep.current_address));
        _ = ep_desc.writeTo(out[start_idx..]) catch unreachable;
        start_idx += 7;
    }
    out_idx.* += start_idx;
}

fn get_blob_iface_num(
    interfaces: []const InnerInterfaceMap,
    lookup: []const InnerInterfaces,
    parent: []const u8,
    id: usize,
) u8 {
    var idx_num: u8 = 0;
    for (lookup) |l| {
        switch (l.meta) {
            .interface_idx => |idx| {
                if (std.mem.eql(u8, l.parent, parent)) {
                    if (interfaces[idx].data.instance_num) |num| {
                        if (num == id) {
                            return idx_num;
                        }
                    }
                }
                idx_num += 1;
            },
            else => {},
        }
    }
    @compileError(std.fmt.comptimePrint("instance_num {d} does not exist in {s} metadata", .{ id, parent }));
}
fn get_interface_paths(all: type) []const InnerMapInterface {
    const size = comptime calc_all_interface(all).@"0";
    comptime var paths: [size]InnerMapInterface = undefined;
    comptime var idx: usize = 0;
    const st = @typeInfo(all).@"struct";
    for (st.field_names, st.field_types) |nf, fd| {
        const base_path = nf;
        const inner = @typeInfo(fd).pointer.child;
        const meta = inner.into_meta();
        inner_interface_paths(inner, base_path, meta, &paths, &idx);
    }
    return paths[0..idx];
}

fn inner_interface_paths(inner: type, comptime base_path: []const u8, meta: []const Meta.Meta, out: []InnerMapInterface, idx: *usize) void {
    for (meta) |m| {
        switch (m) {
            .Interface => |iface| {
                out[idx.*] = InnerMapInterface{
                    .path = base_path,
                    .setup = iface.setup,
                    .instance_num = iface.instance_num,
                };
                idx.* += 1;
            },
            .Derive, .FlatDerive => |derive| {
                //types are already checked in the meta parser, so we can just call the function recursively:
                if (@hasField(inner, @tagName(derive.id))) {
                    const next = @FieldType(inner, @tagName(derive.id));
                    const next_meta = next.into_meta();
                    const next_base_path = std.fmt.comptimePrint("{s}.{s}", .{ base_path, @tagName(derive.id) });
                    inner_interface_paths(next, next_base_path, next_meta, out, idx);
                } else {
                    @compileError(std.fmt.comptimePrint("Type {s} does not have a field: {s}", .{
                        @typeName(inner),
                        @tagName(derive.id),
                    }));
                }
            },
            else => {},
        }
    }
}

fn get_endpoint_paths(all: type) []const []const u8 {
    const size = comptime calc_all_interface(all).@"1";
    comptime var paths: [size][]const u8 = undefined;
    comptime var idx: usize = 0;
    const st = @typeInfo(all).@"struct";
    for (st.field_types, st.field_names) |fd, nf| {
        const base_path = nf;
        const inner = @typeInfo(fd).pointer.child;
        const meta = inner.into_meta();
        inner_endpoint_paths(inner, base_path, meta, &paths, &idx);
    }
    return paths[0..idx];
}

fn inner_endpoint_paths(inner: type, comptime base_path: []const u8, meta: []const Meta.Meta, out: [][]const u8, idx: *usize) void {
    for (meta) |m| {
        switch (m) {
            .Interface => |iface| {
                for (iface.endpoints) |ep| {
                    out[idx.*] = std.fmt.comptimePrint("{s}.{s}", .{ base_path, @tagName(ep) });
                    idx.* += 1;
                }
            },
            .Derive, .FlatDerive => |derive| {
                //types are already checked in the meta parser, so we can just call the function recursively:
                if (@hasField(inner, @tagName(derive.id))) {
                    const next = @FieldType(inner, @tagName(derive.id));
                    const next_meta = next.into_meta();
                    const next_base_path = std.fmt.comptimePrint("{s}.{s}", .{ base_path, @tagName(derive.id) });
                    inner_endpoint_paths(next, next_base_path, next_meta, out, idx);
                } else {
                    @compileError(std.fmt.comptimePrint("Type {s} does not have a field: {s}", .{
                        @typeName(inner),
                        @tagName(derive.id),
                    }));
                }
            },
            else => {},
        }
    }
}
