const std = @import("std");
const String = @import("strings.zig");

pub fn PathFieldType(comptime T: type, comptime path: []const u8) type {
    return InnerPathFieldType(T, comptime path, path);
}
fn InnerPathFieldType(comptime T: type, comptime path: []const u8, full_path: []const u8) type {
    if (std.mem.indexOfScalar(u8, path, '.')) |dot| {
        const fd_t = @FieldType(T, path[0..dot]);
        const next = path[dot + 1 ..];
        if (@hasField(fd_t, next)) {
            return InnerPathFieldType(fd_t, next, full_path);
        } else {
            @compileError(std.fmt.comptimePrint(
                \\ERROR ON PATH: {s}
                \\Type {s} has no field named {s}.
                \\
            , .{
                full_path,
                @typeName(T),
                path,
            }));
        }
    }
    if (@hasField(T, path)) return @FieldType(T, path);
    @compileError(std.fmt.comptimePrint(
        \\ERROR ON PATH: {s}
        \\Type {s} has no field named {s}.
        \\
    , .{
        full_path,
        @typeName(T),
        path,
    }));
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
