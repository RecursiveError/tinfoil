const std = @import("std");

// USB 2.0 generic descriptor definitions and small helpers.

pub const DescriptorType = enum(u8) {
    Device = 1,
    Configuration = 2,
    String = 3,
    Interface = 4,
    Endpoint = 5,
    DeviceQualifier = 6,
    OtherSpeedConfiguration = 7,
    InterfacePower = 8,
    InterfaceAssociation = 11,
    // Common class-specific / vendor values can be added when needed
};

pub const TransferType = enum(u8) {
    Control = 0,
    Isochronous = 1,
    Bulk = 2,
    Interrupt = 3,
};

pub const EndpointDirection = enum(u8) {
    Out = 0x00,
    In = 0x80,
};

pub fn endpointAddress(dir: EndpointDirection, ep_number: u8) u8 {
    return @backingInt(dir) | (ep_number & 0x0F);
}

pub fn endpointAttributes(transfer: TransferType) u8 {
    // bmAttributes: bits 0..1 Transfer type
    return @intCast(transfer);
}

pub const DEVICE_DESCRIPTOR_SIZE: u8 = 18;
pub const CONFIGURATION_DESCRIPTOR_SIZE: u8 = 9;
pub const INTERFACE_DESCRIPTOR_SIZE: u8 = 9;
pub const ENDPOINT_DESCRIPTOR_SIZE: u8 = 7;
pub const IAD_DESCRIPTOR_SIZE: u8 = 8;

pub const DeviceDescriptor = packed struct {
    bLength: u8,
    bDescriptorType: u8,
    bcdUSB: u16,
    bDeviceClass: u8,
    bDeviceSubClass: u8,
    bDeviceProtocol: u8,
    bMaxPacketSize0: u8,
    idVendor: u16,
    idProduct: u16,
    bcdDevice: u16,
    iManufacturer: u8,
    iProduct: u8,
    iSerialNumber: u8,
    bNumConfigurations: u8,

    pub fn init(
        bcdUSB: u16,
        bDeviceClass: u8,
        bDeviceSubClass: u8,
        bDeviceProtocol: u8,
        bMaxPacketSize0: u8,
        idVendor: u16,
        idProduct: u16,
        bcdDevice: u16,
        iManufacturer: u8,
        iProduct: u8,
        iSerialNumber: u8,
        bNumConfigurations: u8,
    ) DeviceDescriptor {
        return DeviceDescriptor{
            .bLength = DEVICE_DESCRIPTOR_SIZE,
            .bDescriptorType = DescriptorType.Device,
            .bcdUSB = bcdUSB,
            .bDeviceClass = bDeviceClass,
            .bDeviceSubClass = bDeviceSubClass,
            .bDeviceProtocol = bDeviceProtocol,
            .bMaxPacketSize0 = bMaxPacketSize0,
            .idVendor = idVendor,
            .idProduct = idProduct,
            .bcdDevice = bcdDevice,
            .iManufacturer = iManufacturer,
            .iProduct = iProduct,
            .iSerialNumber = iSerialNumber,
            .bNumConfigurations = bNumConfigurations,
        };
    }

    pub fn size() u8 {
        return DEVICE_DESCRIPTOR_SIZE;
    }

    pub fn writeTo(self: DeviceDescriptor, dst: []u8) !usize {
        if (dst.len < DEVICE_DESCRIPTOR_SIZE) return DescriptorError.OutOfBounds;
        dst[0] = self.bLength;
        dst[1] = self.bDescriptorType;
        dst[2] = @intCast(self.bcdUSB & 0xFF);
        dst[3] = @intCast((self.bcdUSB >> 8) & 0xFF);
        dst[4] = self.bDeviceClass;
        dst[5] = self.bDeviceSubClass;
        dst[6] = self.bDeviceProtocol;
        dst[7] = self.bMaxPacketSize0;
        dst[8] = @intCast(self.idVendor & 0xFF);
        dst[9] = @intCast((self.idVendor >> 8) & 0xFF);
        dst[10] = @intCast(self.idProduct & 0xFF);
        dst[11] = @intCast((self.idProduct >> 8) & 0xFF);
        dst[12] = @intCast(self.bcdDevice & 0xFF);
        dst[13] = @intCast((self.bcdDevice >> 8) & 0xFF);
        dst[14] = self.iManufacturer;
        dst[15] = self.iProduct;
        dst[16] = self.iSerialNumber;
        dst[17] = self.bNumConfigurations;
        return DEVICE_DESCRIPTOR_SIZE;
    }
};

pub const ConfigurationDescriptor = packed struct {
    bLength: u8,
    bDescriptorType: u8,
    wTotalLength: u16,
    bNumInterfaces: u8,
    bConfigurationValue: u8,
    iConfiguration: u8,
    bmAttributes: u8,
    bMaxPower: u8,

    pub fn init(
        wTotalLength: u16,
        bNumInterfaces: u8,
        bConfigurationValue: u8,
        iConfiguration: u8,
        bmAttributes: u8,
        bMaxPower: u8,
    ) ConfigurationDescriptor {
        return ConfigurationDescriptor{
            .bLength = CONFIGURATION_DESCRIPTOR_SIZE,
            .bDescriptorType = DescriptorType.Configuration,
            .wTotalLength = wTotalLength,
            .bNumInterfaces = bNumInterfaces,
            .bConfigurationValue = bConfigurationValue,
            .iConfiguration = iConfiguration,
            .bmAttributes = bmAttributes,
            .bMaxPower = bMaxPower,
        };
    }

    pub fn size() u8 {
        return CONFIGURATION_DESCRIPTOR_SIZE;
    }

    pub fn writeTo(self: ConfigurationDescriptor, dst: []u8) !usize {
        if (dst.len < CONFIGURATION_DESCRIPTOR_SIZE) return DescriptorError.OutOfBounds;
        dst[0] = self.bLength;
        dst[1] = self.bDescriptorType;
        dst[2] = @intCast(self.wTotalLength & 0xFF);
        dst[3] = @intCast(((self.wTotalLength >> 8) & 0xFF));
        dst[4] = self.bNumInterfaces;
        dst[5] = self.bConfigurationValue;
        dst[6] = self.iConfiguration;
        dst[7] = self.bmAttributes;
        dst[8] = self.bMaxPower;
        return CONFIGURATION_DESCRIPTOR_SIZE;
    }
};

pub const InterfaceDescriptor = packed struct {
    bLength: u8,
    bDescriptorType: u8,
    bInterfaceNumber: u8,
    bAlternateSetting: u8,
    bNumEndpoints: u8,
    bInterfaceClass: u8,
    bInterfaceSubClass: u8,
    bInterfaceProtocol: u8,
    iInterface: u8,

    pub fn init(
        bInterfaceNumber: u8,
        bAlternateSetting: u8,
        bNumEndpoints: u8,
        bInterfaceClass: u8,
        bInterfaceSubClass: u8,
        bInterfaceProtocol: u8,
        iInterface: u8,
    ) InterfaceDescriptor {
        return InterfaceDescriptor{
            .bLength = INTERFACE_DESCRIPTOR_SIZE,
            .bDescriptorType = DescriptorType.Interface,
            .bInterfaceNumber = bInterfaceNumber,
            .bAlternateSetting = bAlternateSetting,
            .bNumEndpoints = bNumEndpoints,
            .bInterfaceClass = bInterfaceClass,
            .bInterfaceSubClass = bInterfaceSubClass,
            .bInterfaceProtocol = bInterfaceProtocol,
            .iInterface = iInterface,
        };
    }

    pub fn size() u8 {
        return INTERFACE_DESCRIPTOR_SIZE;
    }

    pub fn writeTo(self: InterfaceDescriptor, dst: []u8) !usize {
        if (dst.len < INTERFACE_DESCRIPTOR_SIZE) return DescriptorError.OutOfBounds;
        dst[0] = self.bLength;
        dst[1] = self.bDescriptorType;
        dst[2] = self.bInterfaceNumber;
        dst[3] = self.bAlternateSetting;
        dst[4] = self.bNumEndpoints;
        dst[5] = self.bInterfaceClass;
        dst[6] = self.bInterfaceSubClass;
        dst[7] = self.bInterfaceProtocol;
        dst[8] = self.iInterface;
        return INTERFACE_DESCRIPTOR_SIZE;
    }
};

pub const EndpointDescriptor = packed struct {
    bLength: u8,
    bDescriptorType: u8,
    bEndpointAddress: u8,
    bmAttributes: u8,
    wMaxPacketSize: u16,
    bInterval: u8,

    pub fn init(bEndpointAddress: u8, bmAttributes: u8, wMaxPacketSize: u16, bInterval: u8) EndpointDescriptor {
        return EndpointDescriptor{
            .bLength = ENDPOINT_DESCRIPTOR_SIZE,
            .bDescriptorType = DescriptorType.Endpoint,
            .bEndpointAddress = bEndpointAddress,
            .bmAttributes = bmAttributes,
            .wMaxPacketSize = wMaxPacketSize,
            .bInterval = bInterval,
        };
    }

    pub fn size() u8 {
        return ENDPOINT_DESCRIPTOR_SIZE;
    }

    pub fn writeTo(self: EndpointDescriptor, dst: []u8) !usize {
        if (dst.len < ENDPOINT_DESCRIPTOR_SIZE) return DescriptorError.OutOfBounds;
        dst[0] = self.bLength;
        dst[1] = self.bDescriptorType;
        dst[2] = self.bEndpointAddress;
        dst[3] = self.bmAttributes;
        dst[4] = @intCast(self.wMaxPacketSize & 0xFF);
        dst[5] = @intCast((self.wMaxPacketSize >> 8) & 0xFF);
        dst[6] = self.bInterval;
        return ENDPOINT_DESCRIPTOR_SIZE;
    }
};

pub const InterfaceAssociationDescriptor = packed struct {
    bLength: u8,
    bDescriptorType: u8,
    bFirstInterface: u8,
    bInterfaceCount: u8,
    bFunctionClass: u8,
    bFunctionSubClass: u8,
    bFunctionProtocol: u8,
    iFunction: u8,

    pub fn init(
        bFirstInterface: u8,
        bInterfaceCount: u8,
        bFunctionClass: u8,
        bFunctionSubClass: u8,
        bFunctionProtocol: u8,
        iFunction: u8,
    ) InterfaceAssociationDescriptor {
        return InterfaceAssociationDescriptor{
            .bLength = IAD_DESCRIPTOR_SIZE,
            .bDescriptorType = DescriptorType.InterfaceAssociation,
            .bFirstInterface = bFirstInterface,
            .bInterfaceCount = bInterfaceCount,
            .bFunctionClass = bFunctionClass,
            .bFunctionSubClass = bFunctionSubClass,
            .bFunctionProtocol = bFunctionProtocol,
            .iFunction = iFunction,
        };
    }

    pub fn writeTo(self: InterfaceAssociationDescriptor, dst: []u8) !usize {
        if (dst.len < IAD_DESCRIPTOR_SIZE) return DescriptorError.OutOfBounds;
        dst[0] = self.bLength;
        dst[1] = self.bDescriptorType;
        dst[2] = self.bFirstInterface;
        dst[3] = self.bInterfaceCount;
        dst[4] = self.bFunctionClass;
        dst[5] = self.bFunctionSubClass;
        dst[6] = self.bFunctionProtocol;
        dst[7] = self.iFunction;
        return IAD_DESCRIPTOR_SIZE;
    }

    pub fn size() u8 {
        return IAD_DESCRIPTOR_SIZE;
    }
};

// USB Setup Packet (8 bytes) used in control transfers (standard requests)
pub const RequestDirection = enum(u8) {
    HostToDevice = 0,
    DeviceToHost = 1,
};

pub const RequestType = enum(u8) {
    Standard = 0,
    Class = 1,
    Vendor = 2,
    Reserved = 3,
};

pub const RequestRecipient = enum(u8) {
    Device = 0,
    Interface = 1,
    Endpoint = 2,
    Other = 3,
};

pub const StandardRequest = enum(u8) {
    GetStatus = 0,
    ClearFeature = 1,
    SetFeature = 3,
    SetAddress = 5,
    GetDescriptor = 6,
    SetDescriptor = 7,
    GetConfiguration = 8,
    SetConfiguration = 9,
    GetInterface = 10,
    SetInterface = 11,
    SynchFrame = 12,
};

pub const StandardRequestData = union(enum) {
    GetStatus: void,
    ClearFeature: u16,
    SetFeature: u16,
    SetAddress: u16,
    GetDescriptor: struct {
        descriptor_type: u8,
        index: u8,
        length: u16,
    },
    SetDescriptor: struct {
        descriptor_type: u8,
        index: u8,
        length: u16,
    },
    GetConfiguration: void,
    SetConfiguration: u8,
    GetInterface: void,
    SetInterface: u8,
    SynchFrame: void,
};

pub const SetupPacket = packed struct {
    bmRequestType: u8,
    bRequest: u8,
    wValue: u16,
    wIndex: u16,
    wLength: u16,

    pub fn parse(buf: []const u8) !SetupPacket {
        if (buf.len < 8) return DescriptorError.OutOfBounds;
        return SetupPacket{
            .bmRequestType = buf[0],
            .bRequest = buf[1],
            .wValue = @as(u16, buf[2]) | @as(u16, buf[3]) << 8,
            .wIndex = @as(u16, buf[4]) | @as(u16, buf[5]) << 8,
            .wLength = @as(u16, buf[6]) | @as(u16, buf[7]) << 8,
        };
    }

    pub fn writeTo(self: SetupPacket, dst: []u8) !usize {
        if (dst.len < 8) return DescriptorError.OutOfBounds;
        dst[0] = self.bmRequestType;
        dst[1] = self.bRequest;
        dst[2] = @intCast(self.wValue & 0xFF);
        dst[3] = @intCast((self.wValue >> 8) & 0xFF);
        dst[4] = @intCast(self.wIndex & 0xFF);
        dst[5] = @intCast((self.wIndex >> 8) & 0xFF);
        dst[6] = @intCast(self.wLength & 0xFF);
        dst[7] = @intCast((self.wLength >> 8) & 0xFF);
        return 8;
    }

    pub fn direction(self: SetupPacket) RequestDirection {
        return @as(RequestDirection, @fromBackingInt(@intCast((self.bmRequestType & 0x80) >> 7)));
    }

    pub fn typ(self: SetupPacket) RequestType {
        return @as(RequestType, @fromBackingInt(@intCast((self.bmRequestType >> 5) & 0x03)));
    }

    pub fn recipient(self: SetupPacket) RequestRecipient {
        return @as(RequestRecipient, @fromBackingInt(@intCast(self.bmRequestType & 0x1F)));
    }

    pub fn standardRequest(self: SetupPacket) !StandardRequestData {
        if (self.typ() != .Standard) return DescriptorError.NotStandardRequest;

        return switch (self.bRequest) {
            0 => .{ .GetStatus = {} },
            1 => .{ .ClearFeature = self.wValue },
            3 => .{ .SetFeature = self.wValue },
            5 => .{ .SetAddress = self.wValue },
            6 => .{ .GetDescriptor = .{
                .descriptor_type = @intCast(self.wValue >> 8),
                .index = @intCast(self.wValue & 0xff),
                .length = self.wLength,
            } },
            7 => .{ .SetDescriptor = .{
                .descriptor_type = @intCast(self.wValue >> 8),
                .index = @intCast(self.wValue & 0xff),
                .length = self.wLength,
            } },
            8 => .{ .GetConfiguration = {} },
            9 => .{ .SetConfiguration = @intCast(self.wValue & 0xff) },
            10 => .{ .GetInterface = {} },
            11 => .{ .SetInterface = @intCast(self.wValue & 0xff) },
            12 => .{ .SynchFrame = {} },
            else => DescriptorError.UnsupportedRequest,
        };
    }

    pub fn size() u8 {
        return 8;
    }
};

pub const DescriptorError = error{ OutOfBounds, NotStandardRequest, UnsupportedRequest };
