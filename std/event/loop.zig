const std = @import("../index.zig");
const builtin = @import("builtin");
const assert = std.debug.assert;
const mem = std.mem;
const AtomicRmwOp = builtin.AtomicRmwOp;
const AtomicOrder = builtin.AtomicOrder;
const fs = std.event.fs;
const os = std.os;
const posix = os.posix;
const windows = os.windows;

pub const Loop = struct {
    allocator: *mem.Allocator,
    next_tick_queue: std.atomic.Queue(promise),
    os_data: OsData,
    final_resume_node: ResumeNode,
    pending_event_count: usize,
    extra_threads: []*os.Thread,

    // pre-allocated eventfds. all permanently active.
    // this is how we send promises to be resumed on other threads.
    available_eventfd_resume_nodes: std.atomic.Stack(ResumeNode.EventFd),
    eventfd_resume_nodes: []std.atomic.Stack(ResumeNode.EventFd).Node,

    pub const NextTickNode = std.atomic.Queue(promise).Node;

    pub const ResumeNode = struct {
        id: Id,
        handle: promise,

        pub const Id = enum {
            Basic,
            Stop,
            EventFd,
        };

        pub const EventFd = switch (builtin.os) {
            builtin.Os.macosx => MacOsEventFd,
            builtin.Os.linux => struct {
                base: ResumeNode,
                epoll_op: u32,
                eventfd: i32,
            },
            builtin.Os.windows => struct {
                base: ResumeNode,
                completion_key: usize,
            },
            else => @compileError("unsupported OS"),
        };

        const MacOsEventFd = struct {
            base: ResumeNode,
            kevent: posix.Kevent,
        };
    };

    /// After initialization, call run().
    /// TODO copy elision / named return values so that the threads referencing *Loop
    /// have the correct pointer value.
    fn initSingleThreaded(self: *Loop, allocator: *mem.Allocator) !void {
        return self.initInternal(allocator, 1);
    }

    /// The allocator must be thread-safe because we use it for multiplexing
    /// coroutines onto kernel threads.
    /// After initialization, call run().
    /// TODO copy elision / named return values so that the threads referencing *Loop
    /// have the correct pointer value.
    fn initMultiThreaded(self: *Loop, allocator: *mem.Allocator) !void {
        const core_count = try os.cpuCount(allocator);
        return self.initInternal(allocator, core_count);
    }

    /// Thread count is the total thread count. The thread pool size will be
    /// max(thread_count - 1, 0)
    fn initInternal(self: *Loop, allocator: *mem.Allocator, thread_count: usize) !void {
        self.* = Loop{
            .pending_event_count = 1,
            .allocator = allocator,
            .os_data = undefined,
            .next_tick_queue = std.atomic.Queue(promise).init(),
            .extra_threads = undefined,
            .available_eventfd_resume_nodes = std.atomic.Stack(ResumeNode.EventFd).init(),
            .eventfd_resume_nodes = undefined,
            .final_resume_node = ResumeNode{
                .id = ResumeNode.Id.Stop,
                .handle = undefined,
            },
        };
        const extra_thread_count = thread_count - 1;
        self.eventfd_resume_nodes = try self.allocator.alloc(
            std.atomic.Stack(ResumeNode.EventFd).Node,
            extra_thread_count,
        );
        errdefer self.allocator.free(self.eventfd_resume_nodes);

        self.extra_threads = try self.allocator.alloc(*os.Thread, extra_thread_count);
        errdefer self.allocator.free(self.extra_threads);

        try self.initOsData(extra_thread_count);
        errdefer self.deinitOsData();
    }

    pub fn deinit(self: *Loop) void {
        self.deinitOsData();
        self.allocator.free(self.extra_threads);
    }

    const InitOsDataError = os.LinuxEpollCreateError || mem.Allocator.Error || os.LinuxEventFdError ||
        os.SpawnThreadError || os.LinuxEpollCtlError || os.BsdKEventError ||
        os.WindowsCreateIoCompletionPortError;

    const wakeup_bytes = []u8{0x1} ** 8;

    fn initOsData(self: *Loop, extra_thread_count: usize) InitOsDataError!void {
        switch (builtin.os) {
            builtin.Os.linux => {
                self.os_data.fs_queue = std.atomic.Queue(fs.Request).init();
                self.os_data.fs_queue_len = 0;
                // we need another thread for the file system because Linux does not have an async
                // file system I/O API.
                self.os_data.fs_end_request = fs.RequestNode{
                    .next = undefined,
                    .data = fs.Request{
                        .msg = fs.Request.Msg.End,
                        .finish = fs.Request.Finish.NoAction,
                    },
                };
                self.os_data.fs_thread = try os.spawnThread(self, linuxFsRun);
                errdefer {
                    self.linuxFsRequest(&self.os_data.fs_end_request);
                    self.os_data.fs_thread.wait();
                }

                errdefer {
                    while (self.available_eventfd_resume_nodes.pop()) |node| os.close(node.data.eventfd);
                }
                for (self.eventfd_resume_nodes) |*eventfd_node| {
                    eventfd_node.* = std.atomic.Stack(ResumeNode.EventFd).Node{
                        .data = ResumeNode.EventFd{
                            .base = ResumeNode{
                                .id = ResumeNode.Id.EventFd,
                                .handle = undefined,
                            },
                            .eventfd = try os.linuxEventFd(1, posix.EFD_CLOEXEC | posix.EFD_NONBLOCK),
                            .epoll_op = posix.EPOLL_CTL_ADD,
                        },
                        .next = undefined,
                    };
                    self.available_eventfd_resume_nodes.push(eventfd_node);
                }

                self.os_data.epollfd = try os.linuxEpollCreate(posix.EPOLL_CLOEXEC);
                errdefer os.close(self.os_data.epollfd);

                self.os_data.final_eventfd = try os.linuxEventFd(0, posix.EFD_CLOEXEC | posix.EFD_NONBLOCK);
                errdefer os.close(self.os_data.final_eventfd);

                self.os_data.final_eventfd_event = posix.epoll_event{
                    .events = posix.EPOLLIN,
                    .data = posix.epoll_data{ .ptr = @ptrToInt(&self.final_resume_node) },
                };
                try os.linuxEpollCtl(
                    self.os_data.epollfd,
                    posix.EPOLL_CTL_ADD,
                    self.os_data.final_eventfd,
                    &self.os_data.final_eventfd_event,
                );

                var extra_thread_index: usize = 0;
                errdefer {
                    // writing 8 bytes to an eventfd cannot fail
                    os.posixWrite(self.os_data.final_eventfd, wakeup_bytes) catch unreachable;
                    while (extra_thread_index != 0) {
                        extra_thread_index -= 1;
                        self.extra_threads[extra_thread_index].wait();
                    }
                }
                while (extra_thread_index < extra_thread_count) : (extra_thread_index += 1) {
                    self.extra_threads[extra_thread_index] = try os.spawnThread(self, workerRun);
                }
            },
            builtin.Os.macosx => {
                self.os_data.kqfd = try os.bsdKQueue();
                errdefer os.close(self.os_data.kqfd);

                self.os_data.kevents = try self.allocator.alloc(posix.Kevent, extra_thread_count);
                errdefer self.allocator.free(self.os_data.kevents);

                const eventlist = ([*]posix.Kevent)(undefined)[0..0];

                for (self.eventfd_resume_nodes) |*eventfd_node, i| {
                    eventfd_node.* = std.atomic.Stack(ResumeNode.EventFd).Node{
                        .data = ResumeNode.EventFd{
                            .base = ResumeNode{
                                .id = ResumeNode.Id.EventFd,
                                .handle = undefined,
                            },
                            // this one is for sending events
                            .kevent = posix.Kevent{
                                .ident = i,
                                .filter = posix.EVFILT_USER,
                                .flags = posix.EV_CLEAR | posix.EV_ADD | posix.EV_DISABLE,
                                .fflags = 0,
                                .data = 0,
                                .udata = @ptrToInt(&eventfd_node.data.base),
                            },
                        },
                        .next = undefined,
                    };
                    self.available_eventfd_resume_nodes.push(eventfd_node);
                    const kevent_array = (*[1]posix.Kevent)(&eventfd_node.data.kevent);
                    _ = try os.bsdKEvent(self.os_data.kqfd, kevent_array, eventlist, null);
                    eventfd_node.data.kevent.flags = posix.EV_CLEAR | posix.EV_ENABLE;
                    eventfd_node.data.kevent.fflags = posix.NOTE_TRIGGER;
                    // this one is for waiting for events
                    self.os_data.kevents[i] = posix.Kevent{
                        .ident = i,
                        .filter = posix.EVFILT_USER,
                        .flags = 0,
                        .fflags = 0,
                        .data = 0,
                        .udata = @ptrToInt(&eventfd_node.data.base),
                    };
                }

                // Pre-add so that we cannot get error.SystemResources
                // later when we try to activate it.
                self.os_data.final_kevent = posix.Kevent{
                    .ident = extra_thread_count,
                    .filter = posix.EVFILT_USER,
                    .flags = posix.EV_ADD | posix.EV_DISABLE,
                    .fflags = 0,
                    .data = 0,
                    .udata = @ptrToInt(&self.final_resume_node),
                };
                const kevent_array = (*[1]posix.Kevent)(&self.os_data.final_kevent);
                _ = try os.bsdKEvent(self.os_data.kqfd, kevent_array, eventlist, null);
                self.os_data.final_kevent.flags = posix.EV_ENABLE;
                self.os_data.final_kevent.fflags = posix.NOTE_TRIGGER;

                var extra_thread_index: usize = 0;
                errdefer {
                    _ = os.bsdKEvent(self.os_data.kqfd, kevent_array, eventlist, null) catch unreachable;
                    while (extra_thread_index != 0) {
                        extra_thread_index -= 1;
                        self.extra_threads[extra_thread_index].wait();
                    }
                }
                while (extra_thread_index < extra_thread_count) : (extra_thread_index += 1) {
                    self.extra_threads[extra_thread_index] = try os.spawnThread(self, workerRun);
                }
            },
            builtin.Os.windows => {
                self.os_data.io_port = try os.windowsCreateIoCompletionPort(
                    windows.INVALID_HANDLE_VALUE,
                    null,
                    undefined,
                    undefined,
                );
                errdefer os.close(self.os_data.io_port);

                for (self.eventfd_resume_nodes) |*eventfd_node, i| {
                    eventfd_node.* = std.atomic.Stack(ResumeNode.EventFd).Node{
                        .data = ResumeNode.EventFd{
                            .base = ResumeNode{
                                .id = ResumeNode.Id.EventFd,
                                .handle = undefined,
                            },
                            // this one is for sending events
                            .completion_key = @ptrToInt(&eventfd_node.data.base),
                        },
                        .next = undefined,
                    };
                    self.available_eventfd_resume_nodes.push(eventfd_node);
                }

                var extra_thread_index: usize = 0;
                errdefer {
                    var i: usize = 0;
                    while (i < extra_thread_index) : (i += 1) {
                        while (true) {
                            const overlapped = @intToPtr(?*windows.OVERLAPPED, 0x1);
                            os.windowsPostQueuedCompletionStatus(self.os_data.io_port, undefined, @ptrToInt(&self.final_resume_node), overlapped) catch continue;
                            break;
                        }
                    }
                    while (extra_thread_index != 0) {
                        extra_thread_index -= 1;
                        self.extra_threads[extra_thread_index].wait();
                    }
                }
                while (extra_thread_index < extra_thread_count) : (extra_thread_index += 1) {
                    self.extra_threads[extra_thread_index] = try os.spawnThread(self, workerRun);
                }
            },
            else => {},
        }
    }

    fn deinitOsData(self: *Loop) void {
        switch (builtin.os) {
            builtin.Os.linux => {
                os.close(self.os_data.final_eventfd);
                while (self.available_eventfd_resume_nodes.pop()) |node| os.close(node.data.eventfd);
                os.close(self.os_data.epollfd);
                self.allocator.free(self.eventfd_resume_nodes);
            },
            builtin.Os.macosx => {
                self.allocator.free(self.os_data.kevents);
                os.close(self.os_data.kqfd);
            },
            builtin.Os.windows => {
                os.close(self.os_data.io_port);
            },
            else => {},
        }
    }

    /// resume_node must live longer than the promise that it holds a reference to.
    pub fn addFd(self: *Loop, fd: i32, resume_node: *ResumeNode) !void {
        _ = @atomicRmw(usize, &self.pending_event_count, AtomicRmwOp.Add, 1, AtomicOrder.SeqCst);
        errdefer {
            self.finishOneEvent();
        }
        try self.modFd(
            fd,
            posix.EPOLL_CTL_ADD,
            os.linux.EPOLLIN | os.linux.EPOLLOUT | os.linux.EPOLLET,
            resume_node,
        );
    }

    pub fn modFd(self: *Loop, fd: i32, op: u32, events: u32, resume_node: *ResumeNode) !void {
        var ev = os.linux.epoll_event{
            .events = events,
            .data = os.linux.epoll_data{ .ptr = @ptrToInt(resume_node) },
        };
        try os.linuxEpollCtl(self.os_data.epollfd, op, fd, &ev);
    }

    pub fn removeFd(self: *Loop, fd: i32) void {
        self.removeFdNoCounter(fd);
        self.finishOneEvent();
    }

    fn removeFdNoCounter(self: *Loop, fd: i32) void {
        os.linuxEpollCtl(self.os_data.epollfd, os.linux.EPOLL_CTL_DEL, fd, undefined) catch {};
    }

    pub async fn waitFd(self: *Loop, fd: i32) !void {
        defer self.removeFd(fd);
        suspend |p| {
            // TODO explicitly put this memory in the coroutine frame #1194
            var resume_node = ResumeNode{
                .id = ResumeNode.Id.Basic,
                .handle = p,
            };
            try self.addFd(fd, &resume_node);
        }
    }

    fn dispatch(self: *Loop) void {
        while (self.available_eventfd_resume_nodes.pop()) |resume_stack_node| {
            const next_tick_node = self.next_tick_queue.get() orelse {
                self.available_eventfd_resume_nodes.push(resume_stack_node);
                return;
            };
            const eventfd_node = &resume_stack_node.data;
            eventfd_node.base.handle = next_tick_node.data;
            switch (builtin.os) {
                builtin.Os.macosx => {
                    const kevent_array = (*[1]posix.Kevent)(&eventfd_node.kevent);
                    const eventlist = ([*]posix.Kevent)(undefined)[0..0];
                    _ = os.bsdKEvent(self.os_data.kqfd, kevent_array, eventlist, null) catch {
                        self.next_tick_queue.unget(next_tick_node);
                        self.available_eventfd_resume_nodes.push(resume_stack_node);
                        return;
                    };
                },
                builtin.Os.linux => {
                    // the pending count is already accounted for
                    const epoll_events = posix.EPOLLONESHOT | os.linux.EPOLLIN | os.linux.EPOLLOUT |
                        os.linux.EPOLLET;
                    self.modFd(
                        eventfd_node.eventfd,
                        eventfd_node.epoll_op,
                        epoll_events,
                        &eventfd_node.base,
                    ) catch {
                        self.next_tick_queue.unget(next_tick_node);
                        self.available_eventfd_resume_nodes.push(resume_stack_node);
                        return;
                    };
                },
                builtin.Os.windows => {
                    // this value is never dereferenced but we need it to be non-null so that
                    // the consumer code can decide whether to read the completion key.
                    // it has to do this for normal I/O, so we match that behavior here.
                    const overlapped = @intToPtr(?*windows.OVERLAPPED, 0x1);
                    os.windowsPostQueuedCompletionStatus(
                        self.os_data.io_port,
                        undefined,
                        eventfd_node.completion_key,
                        overlapped,
                    ) catch {
                        self.next_tick_queue.unget(next_tick_node);
                        self.available_eventfd_resume_nodes.push(resume_stack_node);
                        return;
                    };
                },
                else => @compileError("unsupported OS"),
            }
        }
    }

    /// Bring your own linked list node. This means it can't fail.
    pub fn onNextTick(self: *Loop, node: *NextTickNode) void {
        _ = @atomicRmw(usize, &self.pending_event_count, AtomicRmwOp.Add, 1, AtomicOrder.SeqCst);
        self.next_tick_queue.put(node);
        self.dispatch();
    }

    pub fn run(self: *Loop) void {
        self.finishOneEvent(); // the reference we start with

        self.workerRun();

        self.os_data.fs_thread.wait();

        for (self.extra_threads) |extra_thread| {
            extra_thread.wait();
        }
    }

    /// This is equivalent to an async call, except instead of beginning execution of the async function,
    /// it immediately returns to the caller, and the async function is queued in the event loop. It still
    /// returns a promise to be awaited.
    pub fn call(self: *Loop, comptime func: var, args: ...) !(promise->@typeOf(func).ReturnType) {
        const S = struct {
            async fn asyncFunc(loop: *Loop, handle: *promise->@typeOf(func).ReturnType, args2: ...) @typeOf(func).ReturnType {
                suspend |p| {
                    handle.* = p;
                    var my_tick_node = Loop.NextTickNode{
                        .next = undefined,
                        .data = p,
                    };
                    loop.onNextTick(&my_tick_node);
                }
                // TODO guaranteed allocation elision for await in same func as async
                return await (async func(args2) catch unreachable);
            }
        };
        var handle: promise->@typeOf(func).ReturnType = undefined;
        return async<self.allocator> S.asyncFunc(self, &handle, args);
    }

    /// Awaiting a yield lets the event loop run, starting any unstarted async operations.
    /// Note that async operations automatically start when a function yields for any other reason,
    /// for example, when async I/O is performed. This function is intended to be used only when
    /// CPU bound tasks would be waiting in the event loop but never get started because no async I/O
    /// is performed.
    pub async fn yield(self: *Loop) void {
        suspend |p| {
            var my_tick_node = Loop.NextTickNode{
                .next = undefined,
                .data = p,
            };
            self.onNextTick(&my_tick_node);
        }
    }

    fn finishOneEvent(self: *Loop) void {
        if (@atomicRmw(usize, &self.pending_event_count, AtomicRmwOp.Sub, 1, AtomicOrder.SeqCst) == 1) {
            // cause all the threads to stop
            switch (builtin.os) {
                builtin.Os.linux => {
                    self.linuxFsRequest(&self.os_data.fs_end_request);
                    // writing 8 bytes to an eventfd cannot fail
                    os.posixWrite(self.os_data.final_eventfd, wakeup_bytes) catch unreachable;
                    return;
                },
                builtin.Os.macosx => {
                    const final_kevent = (*[1]posix.Kevent)(&self.os_data.final_kevent);
                    const eventlist = ([*]posix.Kevent)(undefined)[0..0];
                    // cannot fail because we already added it and this just enables it
                    _ = os.bsdKEvent(self.os_data.kqfd, final_kevent, eventlist, null) catch unreachable;
                    return;
                },
                builtin.Os.windows => {
                    var i: usize = 0;
                    while (i < self.extra_threads.len + 1) : (i += 1) {
                        while (true) {
                            const overlapped = @intToPtr(?*windows.OVERLAPPED, 0x1);
                            os.windowsPostQueuedCompletionStatus(self.os_data.io_port, undefined, @ptrToInt(&self.final_resume_node), overlapped) catch continue;
                            break;
                        }
                    }
                    return;
                },
                else => @compileError("unsupported OS"),
            }
        }
    }

    fn workerRun(self: *Loop) void {
        while (true) {
            while (true) {
                const next_tick_node = self.next_tick_queue.get() orelse break;
                self.dispatch();
                resume next_tick_node.data;
                self.finishOneEvent();
            }

            switch (builtin.os) {
                builtin.Os.linux => {
                    // only process 1 event so we don't steal from other threads
                    var events: [1]os.linux.epoll_event = undefined;
                    const count = os.linuxEpollWait(self.os_data.epollfd, events[0..], -1);
                    for (events[0..count]) |ev| {
                        const resume_node = @intToPtr(*ResumeNode, ev.data.ptr);
                        const handle = resume_node.handle;
                        const resume_node_id = resume_node.id;
                        switch (resume_node_id) {
                            ResumeNode.Id.Basic => {},
                            ResumeNode.Id.Stop => return,
                            ResumeNode.Id.EventFd => {
                                const event_fd_node = @fieldParentPtr(ResumeNode.EventFd, "base", resume_node);
                                event_fd_node.epoll_op = posix.EPOLL_CTL_MOD;
                                const stack_node = @fieldParentPtr(std.atomic.Stack(ResumeNode.EventFd).Node, "data", event_fd_node);
                                self.available_eventfd_resume_nodes.push(stack_node);
                            },
                        }
                        resume handle;
                        if (resume_node_id == ResumeNode.Id.EventFd) {
                            self.finishOneEvent();
                        }
                    }
                },
                builtin.Os.macosx => {
                    var eventlist: [1]posix.Kevent = undefined;
                    const count = os.bsdKEvent(self.os_data.kqfd, self.os_data.kevents, eventlist[0..], null) catch unreachable;
                    for (eventlist[0..count]) |ev| {
                        const resume_node = @intToPtr(*ResumeNode, ev.udata);
                        const handle = resume_node.handle;
                        const resume_node_id = resume_node.id;
                        switch (resume_node_id) {
                            ResumeNode.Id.Basic => {},
                            ResumeNode.Id.Stop => return,
                            ResumeNode.Id.EventFd => {
                                const event_fd_node = @fieldParentPtr(ResumeNode.EventFd, "base", resume_node);
                                const stack_node = @fieldParentPtr(std.atomic.Stack(ResumeNode.EventFd).Node, "data", event_fd_node);
                                self.available_eventfd_resume_nodes.push(stack_node);
                            },
                        }
                        resume handle;
                        if (resume_node_id == ResumeNode.Id.EventFd) {
                            self.finishOneEvent();
                        }
                    }
                },
                builtin.Os.windows => {
                    var completion_key: usize = undefined;
                    while (true) {
                        var nbytes: windows.DWORD = undefined;
                        var overlapped: ?*windows.OVERLAPPED = undefined;
                        switch (os.windowsGetQueuedCompletionStatus(self.os_data.io_port, &nbytes, &completion_key, &overlapped, windows.INFINITE)) {
                            os.WindowsWaitResult.Aborted => return,
                            os.WindowsWaitResult.Normal => {},
                        }
                        if (overlapped != null) break;
                    }
                    const resume_node = @intToPtr(*ResumeNode, completion_key);
                    const handle = resume_node.handle;
                    const resume_node_id = resume_node.id;
                    switch (resume_node_id) {
                        ResumeNode.Id.Basic => {},
                        ResumeNode.Id.Stop => return,
                        ResumeNode.Id.EventFd => {
                            const event_fd_node = @fieldParentPtr(ResumeNode.EventFd, "base", resume_node);
                            const stack_node = @fieldParentPtr(std.atomic.Stack(ResumeNode.EventFd).Node, "data", event_fd_node);
                            self.available_eventfd_resume_nodes.push(stack_node);
                        },
                    }
                    resume handle;
                    if (resume_node_id == ResumeNode.Id.EventFd) {
                        self.finishOneEvent();
                    }
                },
                else => @compileError("unsupported OS"),
            }
        }
    }

    fn linuxFsRequest(self: *Loop, request_node: *fs.RequestNode) void {
        _ = @atomicRmw(usize, &self.pending_event_count, AtomicRmwOp.Add, 1, AtomicOrder.SeqCst);
        self.os_data.fs_queue.put(request_node);
        _ = @atomicRmw(i32, &self.os_data.fs_queue_len, AtomicRmwOp.Add, 1, AtomicOrder.SeqCst); // let this wrap
        const rc = os.linux.futex_wake(@ptrToInt(&self.os_data.fs_queue_len), os.linux.FUTEX_WAKE, 1);
        switch (os.linux.getErrno(rc)) {
            0 => {},
            posix.EINVAL => unreachable,
            else => unreachable,
        }
    }

    fn linuxFsRun(self: *Loop) void {
        var processed_count: i32 = 0; // we let this wrap
        while (true) {
            while (self.os_data.fs_queue.get()) |node| {
                processed_count +%= 1;
                switch (node.data.msg) {
                    @TagType(fs.Request.Msg).PWriteV => @panic("TODO"),
                    @TagType(fs.Request.Msg).PReadV => |*msg| {
                        msg.result = os.posix_preadv(msg.fd, msg.iov.ptr, msg.iov.len, msg.offset);
                    },
                    @TagType(fs.Request.Msg).OpenRead => |*msg| {
                        const flags = posix.O_LARGEFILE | posix.O_RDONLY;
                        msg.result = os.posixOpenC(msg.path.ptr, flags, 0);
                    },
                    @TagType(fs.Request.Msg).Close => |*msg| os.close(msg.fd),
                    @TagType(fs.Request.Msg).WriteFile => |*msg| blk: {
                        const flags = posix.O_LARGEFILE | posix.O_WRONLY | posix.O_CREAT |
                            posix.O_CLOEXEC | posix.O_TRUNC;
                        const fd = os.posixOpenC(msg.path.ptr, flags, msg.mode) catch |err| {
                            msg.result = err;
                            break :blk;
                        };
                        defer os.close(fd);
                        msg.result = os.posixWrite(fd, msg.contents);
                    },
                    @TagType(fs.Request.Msg).End => return,
                }
                switch (node.data.finish) {
                    @TagType(fs.Request.Finish).TickNode => |*tick_node| self.onNextTick(tick_node),
                    @TagType(fs.Request.Finish).DeallocCloseOperation => |close_op| {
                        self.allocator.destroy(close_op);
                    },
                    @TagType(fs.Request.Finish).NoAction => {},
                }
                self.finishOneEvent();
            }
            const rc = os.linux.futex_wait(@ptrToInt(&self.os_data.fs_queue_len), os.linux.FUTEX_WAIT, processed_count, null);
            switch (os.linux.getErrno(rc)) {
                0 => continue,
                posix.EINTR => continue,
                posix.EAGAIN => continue,
                else => unreachable,
            }
        }
    }

    const OsData = switch (builtin.os) {
        builtin.Os.linux => struct {
            epollfd: i32,
            final_eventfd: i32,
            final_eventfd_event: os.linux.epoll_event,
            fs_thread: *os.Thread,
            fs_queue_len: i32, // we let this wrap
            fs_queue: std.atomic.Queue(fs.Request),
            fs_end_request: fs.RequestNode,
        },
        builtin.Os.macosx => MacOsData,
        builtin.Os.windows => struct {
            io_port: windows.HANDLE,
            extra_thread_count: usize,
        },
        else => struct {},
    };

    const MacOsData = struct {
        kqfd: i32,
        final_kevent: posix.Kevent,
        kevents: []posix.Kevent,
    };
};

test "std.event.Loop - basic" {
    var da = std.heap.DirectAllocator.init();
    defer da.deinit();

    const allocator = &da.allocator;

    var loop: Loop = undefined;
    try loop.initMultiThreaded(allocator);
    defer loop.deinit();

    loop.run();
}

test "std.event.Loop - call" {
    var da = std.heap.DirectAllocator.init();
    defer da.deinit();

    const allocator = &da.allocator;

    var loop: Loop = undefined;
    try loop.initMultiThreaded(allocator);
    defer loop.deinit();

    var did_it = false;
    const handle = try loop.call(testEventLoop);
    const handle2 = try loop.call(testEventLoop2, handle, &did_it);
    defer cancel handle2;

    loop.run();

    assert(did_it);
}

async fn testEventLoop() i32 {
    return 1234;
}

async fn testEventLoop2(h: promise->i32, did_it: *bool) void {
    const value = await h;
    assert(value == 1234);
    did_it.* = true;
}
