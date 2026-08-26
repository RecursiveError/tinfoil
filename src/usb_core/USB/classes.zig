const std = @import("std");

// USB class, subclass and protocol codes (USB 2.0 + common class-specific values)
// This file provides enums for device class codes and some common subclasses/protocols.
// This file is no complete and can be extended with more class-specific enums as needed.

pub const DeviceClass = enum(u8) {
    // Defined by USB IF
    PerInterface = 0x00,
    Audio = 0x01,
    Communication = 0x02,
    Hid = 0x03,
    Physical = 0x05,
    Image = 0x06,
    Printer = 0x07,
    MassStorage = 0x08,
    Hub = 0x09,
    CDCData = 0x0A,
    SmartCard = 0x0B,
    ContentSecurity = 0x0D,
    Video = 0x0E,
    PersonalHealthcare = 0x0F,
    AudioVideo = 0x10,
    Billboard = 0x11,
    UsbTypeCBridge = 0x12,
    Diagnostic = 0xDC,
    WirelessController = 0xE0,
    Miscellaneous = 0xEF,
    ApplicationSpecific = 0xFE,
    VendorSpecific = 0xFF,
};

// Common subclass values for Communication (CDC)
pub const CDCSubclass = enum(u8) {
    DirectLineControlModel = 0x01,
    AbstractControlModel = 0x02,
    TelephoneControlModel = 0x03,
    MultiChannel = 0x04,
    CapiControl = 0x05,
    EthernetNetworking = 0x06,
    AtmNetworking = 0x07,
};

// Common protocol values for CDC (Communication Class)
pub const CDCProtocol = enum(u8) {
    None = 0x00,
    ATCommands = 0x01,
    // ... more can be added later
};

// HID subclass/protocol
pub const HIDSubclass = enum(u8) {
    NoBootInterface = 0x00,
    BootInterface = 0x01,
};

pub const HIDProtocol = enum(u8) {
    None = 0x00,
    Keyboard = 0x01,
    Mouse = 0x02,
};

// Mass Storage subclass and protocols
pub const MassStorageSubclass = enum(u8) {
    RBC = 0x01,
    SFF8020i = 0x02,
    QIC157 = 0x03,
    UFI = 0x04,
    SFF8070i = 0x05,
    // 0x06..0x1F reserved
};

pub const MassStorageProtocol = enum(u8) {
    BulkOnly = 0x50,
    CBI = 0x00, // Control/Bulk/Interrupt (obsolete)
};

// Audio subclass/protocol (partial)
pub const AudioSubclass = enum(u8) {
    Undefined = 0x00,
    AudioControl = 0x01,
    AudioStreaming = 0x02,
    MidiStreaming = 0x03,
};

// Add others as needed. This file can be extended with more class-specific enums
// pulled from USB-IF specifications or class docs.

pub fn className(c: DeviceClass) []const u8 {
    return switch (c) {
        .PerInterface => "PerInterface",
        .Audio => "Audio",
        .Communication => "Communication",
        .Hid => "HID",
        .Physical => "Physical",
        .Image => "Image",
        .Printer => "Printer",
        .MassStorage => "MassStorage",
        .Hub => "Hub",
        .CDCData => "CDCData",
        .SmartCard => "SmartCard",
        .ContentSecurity => "ContentSecurity",
        .Video => "Video",
        .PersonalHealthcare => "PersonalHealthcare",
        .AudioVideo => "AudioVideo",
        .Billboard => "Billboard",
        .UsbTypeCBridge => "UsbTypeCBridge",
        .Diagnostic => "Diagnostic",
        .WirelessController => "WirelessController",
        .Miscellaneous => "Miscellaneous",
        .ApplicationSpecific => "ApplicationSpecific",
        .VendorSpecific => "VendorSpecific",
    };
}
