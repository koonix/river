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
const util = @import("../util.zig");

const Error = @import("../command.zig").Error;
const Seat = @import("../Seat.zig");

const log = std.log.scoped(.xcursor_theme);

pub fn xcursorTheme(
    seat: *Seat,
    args: []const [:0]const u8,
    _: *?[]const u8,
) Error!void {
    if (args.len < 3) return Error.NotEnoughArguments;
    if (args.len > 4) return Error.TooManyArguments;

    const name = args[1];
    const name_hidden = args[2];
    server.config.cursor_size = if (args.len == 4) try std.fmt.parseInt(u32, args[3], 10) else null;

    if (name.len > 0) {
        if (server.config.cursor_theme) |theme| {
            util.gpa.free(theme);
        }
        server.config.cursor_theme = try util.gpa.dupeZ(u8, name);
    } else {
        server.config.cursor_theme = null;
    }

    if (name_hidden.len > 0) {
        if (server.config.cursor_theme_hidden) |theme| {
            util.gpa.free(theme);
        }
        server.config.cursor_theme_hidden = try util.gpa.dupeZ(u8, name_hidden);
    } else {
        server.config.cursor_theme_hidden = null;
    }

    if (server.config.cursor_theme) |theme| {
        seat.cursor.setTheme(theme.ptr, server.config.cursor_size, true) catch {};
    } else {
        seat.cursor.setTheme(null, server.config.cursor_size, true) catch {};
    }

    if (seat.cursor.hidden) {
        seat.cursor.hide();
    }
}
