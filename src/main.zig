const std = @import("std");
const posix = std.posix;
const fs = std.fs;
const Allocator = std.mem.Allocator;

const ParseError = error{
    NoCmd,
    UnknownCmd,
    FailedParseArgs,
    Failed,
    TooManyArgs,
    MissingArg,
};

const Builtin = enum {
    exit,
    echo,
    type_, // this may raise problems

    const builtins = std.StaticStringMap(Builtin).initComptime(.{
        .{ "exit", .exit },
        .{ "echo", .echo },
        .{ "type", .type_ },
    });

    pub fn isBuiltin(s: []const u8) bool {
        return builtins.has(s);
    }

    pub fn getBuiltinFromStr(s: []const u8) Builtin {
        return builtins.get(s) orelse unreachable;
    }
};

const External = struct {
    path: []const u8,
    args: ?[][]const u8,
};

const Command = struct {
    kind: union(enum) {
        builtin: union(Builtin) {
            exit: u8,
            echo: []const u8,
            type_: ?*Command,
        },
        extern_: External,
        not_found: void,
    },
    name: []const u8,

    pub fn printType(out: std.io.Writer, c: Command) !void {
        switch (c.kind) {
            .builtin => {
                try out.print("{s} is a shell builtin\n", c.name);
            },
            .extern_ => |ext| {
                try out.print("{s} is {s}\n", c.name, ext.path);
            },
            .not_found => {
                try out.print("{s}: not found\n", c.name);
            },
        }
    }

    pub fn parse(allocator: Allocator, src: []const u8) ParseError!*Command {
        var token_iter = std.mem.tokenizeSequence(u8, src, " ");

        // in case of no token then there is no command
        const cmd_tok = token_iter.next() orelse return ParseError.NoCmd;

        if (Builtin.isBuiltin(cmd_tok)) {
            return parseBuiltin(allocator, cmd_tok, &token_iter);
        } else {
            return parseExternal(allocator, cmd_tok, &token_iter);
        }
    }

    fn parseBuiltin(allocator: Allocator, name: []const u8, token_iter: *std.mem.TokenIterator(u8, .sequence)) ParseError!*Command {
        const cmdPtr = allocator.create(Command) catch return ParseError.Failed;
        errdefer allocator.destroy(cmdPtr);

        return switch (Builtin.getBuiltinFromStr(name)) {
            .exit => {
                const exit_code_str = token_iter.next() orelse {
                    cmdPtr.* = Command{ .kind = .{ .builtin = .{ .exit = 0 } }, .name = name };
                    return cmdPtr;
                };
                const exit_code = std.fmt.parseInt(u8, exit_code_str, 10) catch return ParseError.FailedParseArgs;
                if (token_iter.peek() != null) {
                    return ParseError.TooManyArgs;
                }
                cmdPtr.* = Command{ .kind = .{ .builtin = .{ .exit = exit_code } }, .name = name };
                return cmdPtr;
            },
            .echo => {
                const text = token_iter.rest();
                cmdPtr.* = Command{ .kind = .{ .builtin = .{ .echo = text } }, .name = name };
                return cmdPtr;
            },
            .type_ => {
                const target = token_iter.next() orelse return ParseError.MissingArg;
                if (token_iter.peek() != null) {
                    return ParseError.TooManyArgs;
                }

                if (std.mem.eql(u8, target, "type")) {
                    cmdPtr.* = Command{ .kind = .{ .builtin = .{
                        .type_ = null,
                    } }, .name = name };

                    return cmdPtr;
                }

                const targetCmd = try Command.parse(allocator, target);
                cmdPtr.* = Command{ .kind = .{ .builtin = .{ .type_ = targetCmd } }, .name = name };
                return cmdPtr;
            },
        };
    }

    fn parseExternal(allocator: Allocator, cmd: []const u8, token_iter: *std.mem.TokenIterator(u8, .sequence)) ParseError!*Command {
        const cmdPtr = allocator.create(Command) catch return ParseError.Failed;
        errdefer allocator.destroy(cmdPtr);

        const path_env = posix.getenv("PATH") orelse {
            cmdPtr.* = Command{ .kind = .not_found, .name = cmd };
            // return Command{ .not_found = void, .name = cmd };
            return cmdPtr;
        };
        var path_iter = std.mem.tokenizeSequence(u8, path_env, ":");

        // unuesed for now
        _ = token_iter;

        while (path_iter.peek() != null) {
            const path = path_iter.next().?;
            const file_path = std.fs.path.join(allocator, &.{ path, cmd }) catch continue;

            const file = std.fs.openFileAbsolute(file_path, .{}) catch continue;
            defer file.close();

            const mode = file.mode() catch continue; // 0o777 -> rwxrwxrwx -> 0b111 111 111 -> 0x1 1111 1111 -> 0x100100100
            // if (mode & 0b00000000000000000000000100100100 != 0) {
            if (mode & 0x124 != 0) {
                cmdPtr.* = Command{ .kind = .{ .extern_ = .{ .path = file_path, .args = null } }, .name = cmd };
                return cmdPtr;
            }
            allocator.free(file_path);
        }
        cmdPtr.* = Command{ .kind = .not_found, .name = cmd };
        return cmdPtr;
    }
};

fn repl(allocator: Allocator) !void {
    const stdout = std.io.getStdOut().writer();
    const stdin = std.io.getStdIn().reader();
    const prompt = "$ ";
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    while (true) { // the 'L' in 'REPL'
        defer _ = arena.reset(.free_all);
        var buffer: [1024]u8 = undefined;

        try stdout.print(prompt, .{});

        // The 'R' in 'REPL'
        const user_input = stdin.readUntilDelimiter(&buffer, '\n') catch return;
        const cmd = Command.parse(arena.allocator(), user_input) catch |err| switch (err) {
            ParseError.NoCmd => continue,

            ParseError.UnknownCmd => {
                try stdout.print("{s}: command not found\n", .{user_input});
                continue;
            },
            ParseError.FailedParseArgs => {
                try stdout.print("{s}: bad arguments\n", .{user_input});
                continue;
            },
            ParseError.TooManyArgs => {
                try stdout.print("Too many arguments: {s}\n", .{user_input});
                continue;
            },
            ParseError.MissingArg => {
                try stdout.print("Missing argument in command: {s}\n", .{user_input});
                continue;
            },
            ParseError.Failed => {
                try stdout.print("something went wrong\n", .{});
                posix.exit(1); // something failed
            },
        };

        switch (cmd.kind) {
            .builtin => |b| {
                switch (b) {
                    .exit => |exit_code| {
                        posix.exit(exit_code);
                    },
                    .echo => |str| {
                        try stdout.print("{s}\n", .{str});
                    },
                    .type_ => |maybe_arg| {
                        const arg = maybe_arg orelse {
                            try stdout.print("type is a shell builtin\n", .{});
                            continue;
                        };
                        switch (arg.kind) {
                            .builtin => {
                                try stdout.print("{s} is a shell builtin\n", .{arg.name});
                            },
                            .extern_ => |exe| {
                                try stdout.print("{s} is {s}\n", .{ arg.name, exe.path });
                            },
                            .not_found => {
                                try stdout.print("{s}: not found\n", .{arg.name});
                            },
                        }
                    },
                }
            },
            .extern_ => {
                continue; // nothing for now
            },
            .not_found => {
                try stdout.print("{s}: not found\n", .{cmd.name});
            },
        }
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    try repl(gpa.allocator());
}
