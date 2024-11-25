const std = @import("std");
const posix = std.posix;
const fs = std.fs;
const Allocator = std.mem.Allocator;

const ParseError = error{
    NoCmd,
    UnknownCmd,
    FailedParseArgs,
    TooManyArgs,
    MissingArg,
};

const Command = enum {
    exit, // built-in exit cmd
    echo,
    type_,
    bad,
    executable,

    pub fn to_str(c: Command) [:0]const u8 {
        return switch (c) {
            .exit => "exit",
            .echo => "echo",
            .type_ => "type",
            .executable => "external executable",
            .bad => "", // bad command: honestly I don't like it
        };
    }
};

const RunCommand = union(Command) {
    exit: u8, // exit code, default to 0
    echo: []const u8,
    type_: Command,
    bad: []const u8, // bad command
    executable: [2][]const u8,

    // see: https://github.com/ziglang/zig/blob/master/lib/std/zig/tokenizer.zig
    const available_commands = std.StaticStringMap(Command).initComptime(.{
        .{ "exit", .exit },
        .{ "echo", .echo },
        .{ "type", .type_ },
    });

    pub fn parse(allocator: Allocator, src: []const u8) ParseError!RunCommand {
        var token_iter = std.mem.tokenizeSequence(u8, src, " ");

        // in case of no token then there is no command
        const cmd_tok = token_iter.next() orelse return ParseError.NoCmd;

        // if token is not in the available commands the it is an unknonw command
        const cmd = available_commands.get(cmd_tok) orelse return ParseError.UnknownCmd;

        return switch (cmd) {
            .exit => {
                // if no more parameter are given the return `exit 0`
                const exit_num_code = token_iter.next() orelse return RunCommand{ .exit = 0 };
                const exit_value = std.fmt.parseInt(u8, exit_num_code, 10) catch return ParseError.FailedParseArgs;

                if (token_iter.peek() != null) {
                    return ParseError.TooManyArgs;
                }

                return RunCommand{ .exit = exit_value };
            },
            .echo => {
                const first = token_iter.next() orelse return RunCommand{ .echo = "" };
                const start = token_iter.index - first.len;
                while (token_iter.peek() != null) : (_ = token_iter.next()) {}
                const end = token_iter.index;
                return RunCommand{
                    .echo = src[start..end],
                };
            },
            .type_ => {
                const arg = token_iter.next() orelse return ParseError.MissingArg;

                if (token_iter.peek() != null) {
                    return ParseError.TooManyArgs;
                }

                if (available_commands.get(arg)) |target| {
                    return RunCommand{ .type_ = target };
                } else {
                    return executablePathLookup(allocator, arg);
                }
            },
            .bad, .executable => unreachable,
        };
    }
};

fn executablePathLookup(allocator: Allocator, prog_name: []const u8) RunCommand {
    const path_env = posix.getenv("PATH") orelse return RunCommand{ .bad = prog_name };
    var path_iter = std.mem.tokenizeSequence(u8, path_env, ":");

    while (path_iter.peek() != null) {
        const path = path_iter.next().?;
        const file_path = std.fs.path.join(allocator, &.{ path, prog_name }) catch continue;

        const file = std.fs.openFileAbsolute(file_path, .{}) catch continue;
        defer file.close();

        const mode = file.mode() catch continue; // 0o777 -> rwxrwxrwx -> 0b111 111 111 -> 0x1 1111 1111 -> 0x100100100
        if (mode & 0x100100100 != 0) {
            return RunCommand{ .executable = [2][]const u8{ prog_name, file_path } };
        }
        allocator.free(file_path);
    }

    return RunCommand{ .bad = prog_name };
}

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
        const user_input = try stdin.readUntilDelimiter(&buffer, '\n');

        // (Handle Error) The 'E' in 'REPL'
        const cmd = RunCommand.parse(arena.allocator(), user_input) catch |err| switch (err) {
            error.NoCmd => continue,
            error.UnknownCmd => {
                try stdout.print("{s}: command not found\n", .{user_input});
                continue;
            },
            error.FailedParseArgs => {
                try stdout.print("{s}: bad arguments\n", .{user_input});
                continue;
            },
            error.TooManyArgs => {
                try stdout.print("Too many arguments: {s}\n", .{user_input});
                continue;
            },
            error.MissingArg => {
                try stdout.print("Missing argument in command: {s}\n", .{user_input});
                continue;
            },
        };

        // The 'E' in 'REPL'
        switch (cmd) {
            .exit => |exit_value| {
                posix.exit(exit_value);
            },
            .echo => |str| {
                try stdout.print("{s}\n", .{str});
            },
            .type_ => |c| {
                try stdout.print("{s} is a shell builtin\n", .{c.to_str()});
            },
            .executable => |arr| {
                try stdout.print("{s} is {s}\n", .{ arr[0], arr[1] });
            },
            .bad => |s| {
                try stdout.print("{s}: not found\n", .{s});
            },
        }
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    try repl(gpa.allocator());
}
