//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2018 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Dispatch

private final class EmbeddedScheduledTask {
    let task: () -> Void
    let readyTime: NIODeadline

    init(readyTime: NIODeadline, task: @escaping () -> Void) {
        self.readyTime = readyTime
        self.task = task
    }
}

extension EmbeddedScheduledTask: Comparable {
    static func < (lhs: EmbeddedScheduledTask, rhs: EmbeddedScheduledTask) -> Bool {
        return lhs.readyTime < rhs.readyTime
    }
    static func == (lhs: EmbeddedScheduledTask, rhs: EmbeddedScheduledTask) -> Bool {
        return lhs === rhs
    }
}

/// An `EventLoop` that is embedded in the current running context with no external
/// control.
///
/// Unlike more complex `EventLoop`s, such as `SelectableEventLoop`, the `EmbeddedEventLoop`
/// has no proper eventing mechanism. Instead, reads and writes are fully controlled by the
/// entity that instantiates the `EmbeddedEventLoop`. This property makes `EmbeddedEventLoop`
/// of limited use for many application purposes, but highly valuable for testing and other
/// kinds of mocking.
///
/// - warning: Unlike `SelectableEventLoop`, `EmbeddedEventLoop` **is not thread-safe**. This
///     is because it is intended to be run in the thread that instantiated it. Users are
///     responsible for ensuring they never call into the `EmbeddedEventLoop` in an
///     unsynchronized fashion.
public final class EmbeddedEventLoop: EventLoop {
    /// The current "time" for this event loop. This is an amount in nanoseconds.
    private var now: NIODeadline = .uptimeNanoseconds(0)

    private var scheduledTasks = PriorityQueue<EmbeddedScheduledTask>(ascending: true)

    /// - see: `EventLoop.inEventLoop`
    public var inEventLoop: Bool {
        return true
    }

    /// Initialize a new `EmbeddedEventLoop`.
    public init() { }

    /// - see: `EventLoop.scheduleTask(deadline:_:)`
    @discardableResult
    public func scheduleTask<T>(deadline: NIODeadline, _ task: @escaping () throws -> T) -> Scheduled<T> {
        let promise: EventLoopPromise<T> = makePromise()
        let task = EmbeddedScheduledTask(readyTime: deadline) {
            do {
                promise.succeed(try task())
            } catch let err {
                promise.fail(err)
            }
        }

        let scheduled = Scheduled(promise: promise, cancellationTask: {
            self.scheduledTasks.remove(task)
        })
        scheduledTasks.push(task)
        return scheduled
    }

    /// - see: `EventLoop.scheduleTask(in:_:)`
    @discardableResult
    public func scheduleTask<T>(in: TimeAmount, _ task: @escaping () throws -> T) -> Scheduled<T> {
        return scheduleTask(deadline: self.now + `in`, task)
    }

    /// On an `EmbeddedEventLoop`, `execute` will simply use `scheduleTask` with a deadline of _now_. This means that
    /// `task` will be run the next time you call `EmbeddedEventLoop.run`.
    public func execute(_ task: @escaping () -> Void) {
        self.scheduleTask(deadline: self.now, task)
    }

    /// Run all tasks that have previously been submitted to this `EmbeddedEventLoop`, either by calling `execute` or
    /// events that have been enqueued using `scheduleTask`/`scheduleRepeatedTask`/`scheduleRepeatedAsyncTask` and whose
    /// deadlines have expired.
    ///
    /// - seealso: `EmbeddedEventLoop.advanceTime`.
    public func run() {
        // Execute all tasks that are currently enqueued to be executed *now*.
        self.advanceTime(by: .nanoseconds(0))
    }

    /// Runs the event loop and moves "time" forward by the given amount, running any scheduled
    /// tasks that need to be run.
    public func advanceTime(by: TimeAmount) {
        let newTime = self.now + by

        while let nextTask = self.scheduledTasks.peek() {
            guard nextTask.readyTime <= newTime else {
                break
            }

            // Now we want to grab all tasks that are ready to execute at the same
            // time as the first.
            var tasks = Array<EmbeddedScheduledTask>()
            while let candidateTask = self.scheduledTasks.peek(), candidateTask.readyTime == nextTask.readyTime {
                tasks.append(candidateTask)
                self.scheduledTasks.pop()
            }

            // Set the time correctly before we call into user code, then
            // call in for all tasks.
            self.now = nextTask.readyTime

            for task in tasks {
                task.task()
            }
        }

        // Finally ensure we got the time right.
        self.now = newTime
    }

    /// - see: `EventLoop.close`
    func close() throws {
        // Nothing to do here
    }

    /// - see: `EventLoop.shutdownGracefully`
    public func shutdownGracefully(queue: DispatchQueue, _ callback: @escaping (Error?) -> Void) {
        run()
        queue.sync {
            callback(nil)
        }
    }

    deinit {
        precondition(scheduledTasks.isEmpty, "Embedded event loop freed with unexecuted scheduled tasks!")
    }
}

class EmbeddedChannelCore: ChannelCore {
    var isOpen: Bool = true
    var isActive: Bool = false

    var eventLoop: EventLoop
    var closePromise: EventLoopPromise<Void>
    var error: Optional<Error>

    private let pipeline: ChannelPipeline

    init(pipeline: ChannelPipeline, eventLoop: EventLoop) {
        closePromise = eventLoop.makePromise()
        self.pipeline = pipeline
        self.eventLoop = eventLoop
        self.error = nil
    }

    deinit {
        assert(self.pipeline.destroyed, "leaked an open EmbeddedChannel, maybe forgot to call channel.finish()?")
        isOpen = false
        closePromise.succeed(())
    }

    /// Contains the flushed items that went into the `Channel` (and on a regular channel would have hit the network).
    var outboundBuffer: [NIOAny] = []

    /// Contains the unflushed items that went into the `Channel`
    var pendingOutboundBuffer: [(NIOAny, EventLoopPromise<Void>?)] = []

    /// Contains the items that travelled the `ChannelPipeline` all the way and hit the tail channel handler. On a
    /// regular `Channel` these items would be lost.
    var inboundBuffer: [NIOAny] = []

    func localAddress0() throws -> SocketAddress {
        throw ChannelError.operationUnsupported
    }

    func remoteAddress0() throws -> SocketAddress {
        throw ChannelError.operationUnsupported
    }

    func close0(error: Error, mode: CloseMode, promise: EventLoopPromise<Void>?) {
        guard self.isOpen else {
            promise?.fail(ChannelError.alreadyClosed)
            return
        }
        isOpen = false
        isActive = false
        promise?.succeed(())

        // As we called register() in the constructor of EmbeddedChannel we also need to ensure we call unregistered here.
        pipeline.fireChannelInactive0()
        pipeline.fireChannelUnregistered0()

        eventLoop.execute {
            // ensure this is executed in a delayed fashion as the users code may still traverse the pipeline
            self.pipeline.removeHandlers()
            self.closePromise.succeed(())
        }
    }

    func bind0(to address: SocketAddress, promise: EventLoopPromise<Void>?) {
        promise?.succeed(())
    }

    func connect0(to address: SocketAddress, promise: EventLoopPromise<Void>?) {
        isActive = true
        promise?.succeed(())
        pipeline.fireChannelActive0()
    }

    func register0(promise: EventLoopPromise<Void>?) {
        promise?.succeed(())
        pipeline.fireChannelRegistered0()
    }

    func registerAlreadyConfigured0(promise: EventLoopPromise<Void>?) {
        isActive = true
        register0(promise: promise)
        pipeline.fireChannelActive0()
    }

    func write0(_ data: NIOAny, promise: EventLoopPromise<Void>?) {
        self.pendingOutboundBuffer.append((data, promise))
    }

    func flush0() {
        let pendings = self.pendingOutboundBuffer
        self.pendingOutboundBuffer.removeAll(keepingCapacity: true)
        for dataAndPromise in pendings {
            self.addToBuffer(buffer: &self.outboundBuffer, data: dataAndPromise.0)
            dataAndPromise.1?.succeed(())
        }
    }

    func read0() {
        // NOOP
    }

    public final func triggerUserOutboundEvent0(_ event: Any, promise: EventLoopPromise<Void>?) {
        promise?.fail(ChannelError.operationUnsupported)
    }

    func channelRead0(_ data: NIOAny) {
        addToBuffer(buffer: &inboundBuffer, data: data)
    }

    public func errorCaught0(error: Error) {
        if self.error == nil {
            self.error = error
        }
    }

    private func addToBuffer<T>(buffer: inout [T], data: T) {
        buffer.append(data)
    }
}

/// `EmbeddedChannel` is a `Channel` implementation that does neither any
/// actual IO nor has a proper eventing mechanism. The prime use-case for
/// `EmbeddedChannel` is in unit tests when you want to feed the inbound events
/// and check the outbound events manually.
///
/// Please remember to call `finish()` when you are no longer using this
/// `EmbeddedChannel`.
///
/// To feed events through an `EmbeddedChannel`'s `ChannelPipeline` use
/// `EmbeddedChannel.writeInbound` which accepts data of any type. It will then
/// forward that data through the `ChannelPipeline` and the subsequent
/// `ChannelInboundHandler` will receive it through the usual `channelRead`
/// event. The user is responsible for making sure the first
/// `ChannelInboundHandler` expects data of that type.
///
/// `EmbeddedChannel` automatically collects arriving outbound data and makes it
/// available one-by-one through `readOutbound`.
///
/// - note: `EmbeddedChannel` is currently only compatible with
///   `EmbeddedEventLoop`s and cannot be used with `SelectableEventLoop`s from
///   for example `MultiThreadedEventLoopGroup`.
/// - warning: Unlike other `Channel`s, `EmbeddedChannel` **is not thread-safe**. This
///     is because it is intended to be run in the thread that instantiated it. Users are
///     responsible for ensuring they never call into an `EmbeddedChannel` in an
///     unsynchronized fashion. `EmbeddedEventLoop`s notes also apply as
///     `EmbeddedChannel` uses an `EmbeddedEventLoop` as its `EventLoop`.
public final class EmbeddedChannel: Channel {
    /// `LeftOverState` represents any left-over inbound, outbound, and pending outbound events that hit the
    /// `EmbeddedChannel` and were not consumed when `finish` was called on the `EmbeddedChannel`.
    ///
    /// `EmbeddedChannel` is most useful in testing and usually in unit tests, you want to consume all inbound and
    /// outbound data to verify they are what you expect. Therefore, when you `finish` an `EmbeddedChannel` it will
    /// return if it's either `.clean` (no left overs) or that it has `.leftOvers`.
    public enum LeftOverState {
        /// The `EmbeddedChannel` is clean, ie. no inbound, outbound, or pending outbound data left on `finish`.
        case clean

        /// The `EmbeddedChannel` has inbound, outbound, or pending outbound data left on `finish`.
        case leftOvers(inbound: [NIOAny], outbound: [NIOAny], pendingOutbound: [NIOAny])

        /// `true` if the `EmbeddedChannel` was `clean` on `finish`, ie. there is no unconsumed inbound, outbound, or
        /// pending outbound data left on the `Channel`.
        public var isClean: Bool {
            if case .clean = self {
                return true
            } else {
                return false
            }
        }

        /// `true` if the `EmbeddedChannel` if there was unconsumed inbound, outbound, or pending outbound data left
        /// on the `Channel` when it was `finish`ed.
        public var hasLeftOvers: Bool {
            return !self.isClean
        }
    }

    /// `BufferState` represents the state of either the inbound, or the outbound `EmbeddedChannel` buffer. These
    /// buffers contain data that travelled the `ChannelPipeline` all the way.
    ///
    /// If the last `ChannelHandler` explicitly (by calling `fireChannelRead`) or implicitly (by not implementing
    /// `channelRead`) sends inbound data into the end of the `EmbeddedChannel`, it will be held in the
    /// `EmbeddedChannel`'s inbound buffer. Similarly for `write` on the outbound side. The state of the respective
    /// buffer will be returned from `writeInbound`/`writeOutbound` as a `BufferState`.
    public enum BufferState {
        /// The buffer is empty.
        case empty

        /// The buffer is non-empty.
        case full([NIOAny])

        /// Returns `true` is the buffer was empty.
        public var isEmpty: Bool {
            if case .empty = self {
                return true
            } else {
                return false
            }
        }

        /// Returns `true` if the buffer was non-empty.
        public var isFull: Bool {
            return !self.isEmpty
        }
    }

    /// `WrongTypeError` is throws if you use `readInbound` or `readOutbound` and request a certain type but the first
    /// item in the respective buffer is of a different type.
    public struct WrongTypeError: Error, Equatable {
        /// The type you expected.
        public let expected: Any.Type

        /// The type of the actual first element.
        public let actual: Any.Type

        public static func == (lhs: WrongTypeError, rhs: WrongTypeError) -> Bool {
            return lhs.expected == rhs.expected && lhs.actual == rhs.actual
        }
    }

    /// Returns `true` if the `EmbeddedChannel` is 'active'.
    ///
    /// An active `EmbeddedChannel` can be closed by calling `close` or `finish` on the `EmbeddedChannel`.
    ///
    /// - note: An `EmbeddedChannel` starts _inactive_ and can be activated, for example by calling `connect`.
    public var isActive: Bool { return channelcore.isActive }

    /// - see: `Channel.closeFuture`
    public var closeFuture: EventLoopFuture<Void> { return channelcore.closePromise.futureResult }

    private lazy var channelcore: EmbeddedChannelCore = EmbeddedChannelCore(pipeline: self._pipeline, eventLoop: self.eventLoop)

    /// - see: `Channel._channelCore`
    public var _channelCore: ChannelCore {
        return channelcore
    }

    /// - see: `Channel.pipeline`
    public var pipeline: ChannelPipeline {
        return _pipeline
    }

    /// - see: `Channel.isWritable`
    public var isWritable: Bool = true

    /// Synchronously closes the `EmbeddedChannel`.
    ///
    /// Errors in the `EmbeddedChannel` can be consumed using `throwIfErrorCaught`.
    ///
    /// - parameters:
    ///     - acceptAlreadyClosed: Whether `finish` should throw if the `EmbeddedChannel` has been previously `close`d.
    /// - returns: The `LeftOverState` of the `EmbeddedChannel`. If all the inbound and outbound events have been
    ///            consumed (using `readInbound` / `readOutbound`) and there are no pending outbound events (unflushed
    ///            writes) this will be `.clean`. If there are any unconsumed inbound, outbound, or pending outbound
    ///            events, the `EmbeddedChannel` will returns those as `.leftOvers(inbound:outbound:pendingOutbound:)`.
    public func finish(acceptAlreadyClosed: Bool) throws -> LeftOverState {
        do {
            try close().wait()
        } catch let error as ChannelError {
            guard error == .alreadyClosed && acceptAlreadyClosed else {
                throw error
            }
        }
        self.embeddedEventLoop.advanceTime(by: .nanoseconds(.max))
        self.embeddedEventLoop.run()
        try throwIfErrorCaught()
        let c = self.channelcore
        if c.outboundBuffer.isEmpty && c.inboundBuffer.isEmpty && c.pendingOutboundBuffer.isEmpty {
            return .clean
        } else {
            return .leftOvers(inbound: c.inboundBuffer,
                              outbound: c.outboundBuffer,
                              pendingOutbound: c.pendingOutboundBuffer.map { $0.0 })
        }
    }

    /// Synchronously closes the `EmbeddedChannel`.
    ///
    /// This method will throw if the `Channel` hit any unconsumed errors or if the `close` fails. Errors in the
    /// `EmbeddedChannel` can be consumed using `throwIfErrorCaught`.
    ///
    /// - returns: The `LeftOverState` of the `EmbeddedChannel`. If all the inbound and outbound events have been
    ///            consumed (using `readInbound` / `readOutbound`) and there are no pending outbound events (unflushed
    ///            writes) this will be `.clean`. If there are any unconsumed inbound, outbound, or pending outbound
    ///            events, the `EmbeddedChannel` will returns those as `.leftOvers(inbound:outbound:pendingOutbound:)`.
    public func finish() throws -> LeftOverState {
        return try self.finish(acceptAlreadyClosed: false)
    }

    private var _pipeline: ChannelPipeline!

    /// - see: `Channel.allocator`
    public var allocator: ByteBufferAllocator = ByteBufferAllocator()

    /// - see: `Channel.eventLoop`
    public var eventLoop: EventLoop {
        return self.embeddedEventLoop
    }

    /// Returns the `EmbeddedEventLoop` that this `EmbeddedChannel` uses. This will return the same instance as
    /// `EmbeddedChannel.eventLoop` but as the concrete `EmbeddedEventLoop` rather than as `EventLoop` existential.
    public var embeddedEventLoop: EmbeddedEventLoop = EmbeddedEventLoop()

    /// - see: `Channel.localAddress`
    public var localAddress: SocketAddress? = nil

    /// - see: `Channel.remoteAddress`
    public var remoteAddress: SocketAddress? = nil

    /// `nil` because `EmbeddedChannel`s don't have parents.
    public let parent: Channel? = nil

    /// If available, this method reads one element of type `T` out of the `EmbeddedChannel`'s outbound buffer. If the
    /// first element was of a different type than requested, `EmbeddedChannel.WrongTypeError` will be thrown, if there
    /// are no elements in the outbound buffer, `nil` will be returned.
    ///
    /// Data hits the `EmbeddedChannel`'s outbound buffer when data was written using `write`, then `flush`ed, and
    /// then travelled the `ChannelPipeline` all the way too the front. For data to hit the outbound buffer, the very
    /// first `ChannelHandler` must have written and flushed it either explicitly (by calling
    /// `ChannelHandlerContext.write` and `flush`) or implicitly by not implementing `write`/`flush`.
    ///
    /// - note: Outbound events travel the `ChannelPipeline` _back to front_.
    /// - note: `EmbeddedChannel.writeOutbound` will `write` data through the `ChannelPipeline`, starting with last
    ///         `ChannelHandler`.
    public func readOutbound<T>(as type: T.Type = T.self) throws -> T? {
        return try readFromBuffer(buffer: &channelcore.outboundBuffer)
    }

    /// If available, this method reads one element of type `T` out of the `EmbeddedChannel`'s inbound buffer. If the
    /// first element was of a different type than requested, `EmbeddedChannel.WrongTypeError` will be thrown, if there
    /// are no elements in the outbound buffer, `nil` will be returned.
    ///
    /// Data hits the `EmbeddedChannel`'s inbound buffer when data was send through the pipeline using `fireChannelRead`
    /// and then travelled the `ChannelPipeline` all the way too the back. For data to hit the inbound buffer, the
    /// last `ChannelHandler` must have send the event either explicitly (by calling
    /// `ChannelHandlerContext.fireChannelRead`) or implicitly by not implementing `channelRead`.
    ///
    /// - note: `EmbeddedChannel.writeInbound` will fire data through the `ChannelPipeline` using `fireChannelRead`.
    public func readInbound<T>(as type: T.Type = T.self) throws -> T? {
        return try readFromBuffer(buffer: &channelcore.inboundBuffer)
    }

    /// Sends an inbound `channelRead` event followed by a `channelReadComplete` event through the `ChannelPipeline`.
    ///
    /// The immediate effect being that the first `ChannelInboundHandler` will get its `channelRead` method called
    /// with the data you provide.
    ///
    /// - parameters:
    ///    - data: The data to fire through the pipeline.
    /// - returns: The state of the inbound buffer which contains all the events that travelled the `ChannelPipeline`
    //             all the way.
    @discardableResult public func writeInbound<T>(_ data: T) throws -> BufferState {
        pipeline.fireChannelRead(NIOAny(data))
        pipeline.fireChannelReadComplete()
        try throwIfErrorCaught()
        return self.channelcore.inboundBuffer.isEmpty ? .empty : .full(self.channelcore.inboundBuffer)
    }

    /// Sends an outbound `writeAndFlush` event through the `ChannelPipeline`.
    ///
    /// The immediate effect being that the first `ChannelOutboundHandler` will get its `write` method called
    /// with the data you provide. Note that the first `ChannelOutboundHandler` in the pipeline is the _last_ handler
    /// because outbound events travel the pipeline from back to front.
    ///
    /// - parameters:
    ///    - data: The data to fire through the pipeline.
    /// - returns: The state of the outbound buffer which contains all the events that travelled the `ChannelPipeline`
    //             all the way.
    @discardableResult public func writeOutbound<T>(_ data: T) throws -> BufferState {
        try writeAndFlush(NIOAny(data)).wait()
        return self.channelcore.outboundBuffer.isEmpty ? .empty : .full(self.channelcore.outboundBuffer)
    }

    /// This method will throw the error that is stored in the `EmbeddedChannel` if any.
    ///
    /// The `EmbeddedChannel` will store an error some error travels the `ChannelPipeline` all the way past its end.
    public func throwIfErrorCaught() throws {
        if let error = channelcore.error {
            channelcore.error = nil
            throw error
        }
    }

    private func readFromBuffer<T>(buffer: inout [NIOAny]) throws -> T? {
        if buffer.isEmpty {
            return nil
        }
        let elem = buffer.removeFirst()
        guard let t = elem.tryAs(type: T.self) else {
            throw WrongTypeError(expected: T.self, actual: type(of: elem.forceAs(type: Any.self)))
        }
        return t
    }

    /// Create a new instance.
    ///
    /// During creation it will automatically also register itself on the `EmbeddedEventLoop`.
    ///
    /// - parameters:
    ///     - handler: The `ChannelHandler` to add to the `ChannelPipeline` before register or `nil` if none should be added.
    ///     - loop: The `EmbeddedEventLoop` to use.
    public init(handler: ChannelHandler? = nil, loop: EmbeddedEventLoop = EmbeddedEventLoop()) {
        self.embeddedEventLoop = loop
        self._pipeline = ChannelPipeline(channel: self)

        if let handler = handler {
            // This will be propagated via fireErrorCaught
            _ = try? _pipeline.addHandler(handler).wait()
        }

        // This will never throw...
        try! register().wait()
    }

    /// - see: `Channel.setOption`
    public func setOption<Option: ChannelOption>(_ option: Option, value: Option.Value) -> EventLoopFuture<Void> {
        // No options supported
        fatalError("no options supported")
    }

    /// - see: `Channel.getOption`
    public func getOption<Option: ChannelOption>(_ option: Option) -> EventLoopFuture<Option.Value>  {
        if option is ChannelOptions.Types.AutoReadOption {
            return self.eventLoop.makeSucceededFuture(true as! Option.Value)
        }
        fatalError("option \(option) not supported")
    }

    /// Fires the (outbound) `bind` event through the `ChannelPipeline`. If the event hits the `EmbeddedChannel` which
    /// happens when it travels the `ChannelPipeline` all the way to the front, this will also set the
    /// `EmbeddedChannel`'s `localAddress`.
    ///
    /// - parameters:
    ///     - address: The address to fake-bind to.
    ///     - promise: The `EventLoopPromise` which will be fulfilled when the fake-bind operation has been done.
    public func bind(to address: SocketAddress, promise: EventLoopPromise<Void>?) {
        promise?.futureResult.whenSuccess {
            self.localAddress = address
        }
        pipeline.bind(to: address, promise: promise)
    }

    /// Fires the (outbound) `connect` event through the `ChannelPipeline`. If the event hits the `EmbeddedChannel`
    /// which happens when it travels the `ChannelPipeline` all the way to the front, this will also set the
    /// `EmbeddedChannel`'s `remoteAddress`.
    ///
    /// - parameters:
    ///     - address: The address to fake-bind to.
    ///     - promise: The `EventLoopPromise` which will be fulfilled when the fake-bind operation has been done.
    public func connect(to address: SocketAddress, promise: EventLoopPromise<Void>?) {
        promise?.futureResult.whenSuccess {
            self.remoteAddress = address
        }
        pipeline.connect(to: address, promise: promise)
    }
}
