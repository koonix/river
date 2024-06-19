// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2020 The River Developers
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, version 3.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.

const std = @import("std");

const server = &@import("../main.zig").server;

const Error = @import("../command.zig").Error;
const Seat = @import("../Seat.zig");

pub fn xcursorTheme(
    seat: *Seat,
    args: []const [:0]const u8,
    _: *?[]const u8,
) Error!void {
    if (args.len < 3) return Error.NotEnoughArguments;
    if (args.len > 4) return Error.TooManyArguments;

    const name = args[1];
    const name_hidden = args[2];
    const size = if (args.len == 4) try std.fmt.parseInt(u32, args[3], 10) else null;

    server.config.cursor_theme = if (name.len == 0) null else name;
    server.config.cursor_theme_hidden = if (name_hidden.len == 0) null else name_hidden;

    try seat.cursor.setTheme(name, size, true);

    if (seat.cursor.hidden) {
        try seat.cursor.setTheme(name_hidden, size, false);
    }
}
