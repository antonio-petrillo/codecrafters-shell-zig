const std = @import("std");

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

    pub fn to_str(c: Command) [:0]const u8 {
        return switch (c) {
            .exit => "exit",
            .echo => "echo",
            .type_ => "type",
            .bad => "", // bad command: honestly I don't like it
        };
    }
};

const RunCommand = union(Command) {
    exit: u8, // exit code, default to 0
    echo: []const u8,
    type_: Command,
    bad: []const u8, // bad command

    // see: https://github.com/ziglang/zig/blob/master/lib/std/zig/tokenizer.zig
    const available_commands = std.StaticStringMap(Command).initComptime(.{
        .{ "exit", .exit },
        .{ "echo", .echo },
        .{ "type", .type_ },
    });

    pub fn parse(src: []const u8) ParseError!RunCommand {
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

                return if (available_commands.get(arg)) |target| {
                    return RunCommand{ .type_ = target };
                } else {
                    return RunCommand{ .bad = arg };
                };
            },
            .bad => unreachable,
        };
    }
};

fn repl() !void {
    const stdout = std.io.getStdOut().writer();
    const stdin = std.io.getStdIn().reader();
    const prompt = "$ ";

    while (true) { // the 'L' in 'REPL'
        var buffer: [1024]u8 = undefined;

        try stdout.print(prompt, .{});

        // The 'R' in 'REPL'
        const user_input = try stdin.readUntilDelimiter(&buffer, '\n');

        // (Handle Error) The 'E' in 'REPL'
        const cmd = RunCommand.parse(user_input) catch |err| switch (err) {
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
                try stdout.print("Missing argument in: {s}\n", .{user_input});
                continue;
            },
        };

        // The 'E' in 'REPL'
        switch (cmd) {
            .exit => |exit_value| {
                std.posix.exit(exit_value);
            },
            .echo => |str| {
                try stdout.print("{s}\n", .{str});
            },
            .type_ => |c| {
                try stdout.print("{s} is a shell builtin\n", .{c.to_str()});
            },
            .bad => |s| {
                try stdout.print("{s}: not found\n", .{s});
            },
        }
    }
}

pub fn main() !void {
    try repl();
}
