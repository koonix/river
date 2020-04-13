const std = @import("std");
const c = @import("c.zig");
const util = @import("util.zig");

const Box = @import("box.zig").Box;
const Log = @import("log.zig").Log;
const Output = @import("output.zig").Output;
const Server = @import("server.zig").Server;
const Seat = @import("seat.zig").Seat;
const View = @import("view.zig").View;
const ViewStack = @import("view_stack.zig").ViewStack;

/// Responsible for all windowing operations
pub const Root = struct {
    const Self = @This();

    server: *Server,

    wlr_output_layout: *c.wlr_output_layout,
    outputs: std.TailQueue(Output),

    /// Number of pending configures sent in the current transaction.
    /// A value of 0 means there is no current transaction.
    pending_configures: u32,

    /// Handles timeout of transactions
    transaction_timer: ?*c.wl_event_source,

    pub fn init(self: *Self, server: *Server) !void {
        self.server = server;

        // Create an output layout, which a wlroots utility for working with an
        // arrangement of screens in a physical layout.
        self.wlr_output_layout = c.wlr_output_layout_create() orelse
            return error.CantCreateWlrOutputLayout;
        errdefer c.wlr_output_layout_destroy(self.wlr_output_layout);

        self.outputs = std.TailQueue(Output).init();

        self.pending_configures = 0;

        self.transaction_timer = null;
    }

    pub fn destroy(self: Self) void {
        c.wlr_output_layout_destroy(self.wlr_output_layout);
    }

    pub fn addOutput(self: *Self, wlr_output: *c.wlr_output) void {
        // TODO: Handle failure
        const node = self.outputs.allocateNode(self.server.allocator) catch unreachable;
        node.data.init(self, wlr_output) catch unreachable;
        self.outputs.append(node);
    }

    /// TODO: move this to seat, it's just a stop gap hack
    pub fn focusedOutput(self: Self) *Output {
        return &self.outputs.first.?.data;
    }

    /// Finds the topmost view under the output layout coordinates lx, ly
    /// returns the view if found, and a pointer to the wlr_surface as well as the surface coordinates
    pub fn viewAt(self: Self, lx: f64, ly: f64, surface: *?*c.wlr_surface, sx: *f64, sy: *f64) ?*View {
        // Iterate over all views of all outputs
        var output_it = self.outputs.first;
        while (output_it) |node| : (output_it = node.next) {
            const output = &node.data;
            var view_it = ViewStack(View).iterator(output.views.first, 0xFFFFFFFF);
            while (view_it.next()) |view_node| {
                if (view_node.view.isAt(lx, ly, surface, sx, sy)) {
                    return &view_node.view;
                }
            }
        }
        return null;
    }

    /// Clear the current focus.
    pub fn clearFocus(self: *Self) void {
        if (self.focused_view) |view| {
            _ = c.wlr_xdg_toplevel_set_activated(view.wlr_xdg_surface, false);
        }
        self.focused_view = null;
    }

    /// Arrange all outputs and then a transaction.
    pub fn arrange(self: *Self) void {
        var it = self.outputs.first;
        while (it) |node| : (it = node.next) {
            const output = &node.data;
            output.arrange();
        }
        self.startTransaction();
    }

    /// Initiate an atomic change to the layout. This change will not be
    /// applied until all affected clients ack a configure and commit a buffer.
    fn startTransaction(self: *Self) void {
        // If a new transaction is started while another is in progress, we need
        // to reset the pending count to 0 and clear serials from the views
        self.pending_configures = 0;

        // Iterate over all views of all outputs
        var output_it = self.outputs.first;
        while (output_it) |node| : (output_it = node.next) {
            const output = &node.data;
            var view_it = ViewStack(View).iterator(output.views.first, 0xFFFFFFFF);
            while (view_it.next()) |view_node| {
                const view = &view_node.view;
                // Clear the serial in case this transaction is interrupting a prior one.
                view.pending_serial = null;

                if (view.needsConfigure()) {
                    view.configurePending();
                    self.pending_configures += 1;

                    // We save the current buffer, so we can send an early
                    // frame done event to give the client a head start on
                    // redrawing.
                    view.sendFrameDone();
                }

                // If there is a saved buffer present, then this transaction is interrupting
                // a previous transaction and we should keep the old buffer.
                if (view.stashed_buffer == null) {
                    view.stashBuffer();
                }
            }
        }

        Log.Debug.log(
            "Started transaction with {} pending configures.",
            .{self.pending_configures},
        );

        if (self.pending_configures > 0) {
            // TODO: log failure to create timer and commit immediately
            self.transaction_timer = c.wl_event_loop_add_timer(
                self.server.wl_event_loop,
                handle_timeout,
                self,
            );
            // Set timeout to 200ms
            if (c.wl_event_source_timer_update(self.transaction_timer, 200) == -1) {
                // TODO: handle failure
            }
        } else {
            self.commitTransaction();
        }
    }

    fn handle_timeout(data: ?*c_void) callconv(.C) c_int {
        const root = @ptrCast(*Root, @alignCast(@alignOf(*Root), data));

        Log.Error.log("Transaction timed out. Some imperfect frames may be shown.", .{});

        root.commitTransaction();

        return 0;
    }

    pub fn notifyConfigured(self: *Self) void {
        self.pending_configures -= 1;
        if (self.pending_configures == 0) {
            // Stop the timer, as we didn't timeout
            if (c.wl_event_source_timer_update(self.transaction_timer, 0) == -1) {
                // TODO: handle failure
            }
            self.commitTransaction();
        }
    }

    /// Apply the pending state and drop stashed buffers. This means that
    /// the next frame drawn will be the post-transaction state of the
    /// layout. Should only be called after all clients have configured for
    /// the new layout. If called early imperfect frames may be drawn.
    fn commitTransaction(self: *Self) void {
        // TODO: apply damage properly

        // Ensure this is set to 0 to avoid entering invalid state (e.g. if called due to timeout)
        self.pending_configures = 0;

        // Iterate over all views of all outputs
        var output_it = self.outputs.first;
        while (output_it) |output_node| : (output_it = output_node.next) {
            const output = &output_node.data;

            // If there were pending focused tags, make them the current focus
            if (output.pending_focused_tags) |tags| {
                Log.Debug.log(
                    "changing current focus: {b:0>10} to {b:0>10}",
                    .{ output.current_focused_tags, tags },
                );
                output.current_focused_tags = tags;
                output.pending_focused_tags = null;
            }

            var view_it = ViewStack(View).iterator(output.views.first, 0xFFFFFFFF);
            while (view_it.next()) |view_node| {
                const view = &view_node.view;
                // Ensure that all pending state is cleared
                view.pending_serial = null;
                if (view.pending_box) |state| {
                    view.current_box = state;
                    view.pending_box = null;
                }

                // Apply possible pending tags
                if (view.pending_tags) |tags| {
                    view.current_tags = tags;
                    view.pending_tags = null;
                }

                view.dropStashedBuffer();
            }
        }

        // Iterate over all seats and update focus
        var it = self.server.input_manager.seats.first;
        while (it) |seat_node| : (it = seat_node.next) {
            seat_node.data.focus(null);
        }
    }
};