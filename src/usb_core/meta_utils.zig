const std = @import("std");
const String = @import("strings.zig");

pub fn PathFieldType(comptime T: type, comptime path: []const u8) type {
    if (std.mem.indexOfScalar(u8, path, '.')) |dot|
        return PathFieldType(@FieldType(T, path[0..dot]), path[dot + 1 ..]);
    return @FieldType(T, path);
}

fn check(base: type, comptime path: []const u8) type {
    const info = @typeInfo(base);
    switch (info) {
        .pointer => |ptr| {
            const inner = @typeInfo(ptr.child);
            switch (inner) {
                .@"struct" => {
                    return PathFieldType(ptr.child, path);
                },
                else => {},
            }
        },
        else => {},
    }
    @compileError("Resolver expects a Pointer to a Struct");
}

pub fn resolve_path(obj: anytype, comptime path: []const u8) *check(@TypeOf(obj), path) {
    const dot = comptime std.mem.indexOfScalar(u8, path, '.');
    if (dot) |d| return resolve_path(&@field(obj.*, path[0..d]), path[d + 1 ..]);
    return &@field(obj.*, path);
}
