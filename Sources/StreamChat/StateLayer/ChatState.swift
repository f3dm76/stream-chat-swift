//
// Copyright © 2024 Stream.io Inc. All rights reserved.
//

import Foundation

/// Represents a ``ChatChannel`` and its state.
@available(iOS 13.0, *)
@MainActor public final class ChatState: ObservableObject {
    private let authenticationRepository: AuthenticationRepository
    private let cid: ChannelId
    private var channelObserver: EntityDatabaseObserverWrapper<ChatChannel, ChannelDTO>?
    private let dataStore: DataStore
    private let paginationStateHandler: MessagesPaginationStateHandling
    private let observer: Observer
    
    init(
        cid: ChannelId,
        channelQuery: ChannelQuery,
        clientConfig: ChatClientConfig,
        messageOrder: MessageOrdering,
        memberListState: MemberListState,
        authenticationRepository: AuthenticationRepository,
        database: DatabaseContainer,
        eventNotificationCenter: EventNotificationCenter,
        paginationStateHandler: MessagesPaginationStateHandling
    ) {
        self.authenticationRepository = authenticationRepository
        self.cid = cid
        dataStore = DataStore(database: database)
        self.messageOrder = messageOrder
        self.paginationStateHandler = paginationStateHandler
        observer = Observer(
            cid: cid,
            channelQuery: channelQuery,
            clientConfig: clientConfig,
            messageOrder: messageOrder,
            memberListState: memberListState,
            database: database,
            eventNotificationCenter: eventNotificationCenter
        )
        observer.start(
            with: .init(
                channelDidChange: { [weak self] in self?.channel = $0 },
                membersDidChange: { [weak self] in self?.members = $0 },
                messagesDidChange: { [weak self] in self?.messages = $0 },
                watchersDidChange: { [weak self] in self?.watchers = $0 }
            )
        )
        channel = observer.channelObserver.item
        members = observer.memberListState.members
        messages = observer.messagesObserver.items
        watchers = observer.watchersObserver.items
    }
    
    // MARK: - Represented Channel
    
    /// The represented ``ChatChannel``.
    @Published public internal(set) var channel: ChatChannel?
    
    // MARK: - Members
    
    /// An array of loaded channel members.
    ///
    /// Use load members in ``Chat`` for loading more members.
    @Published public private(set) var members = StreamCollection<ChatChannelMember>([])
    
    // MARK: - Messages
    
    /// Describes the ordering of messages.
    public let messageOrder: MessageOrdering
    
    /// An array of loaded messages.
    ///
    /// Messages are ordered by timestamp and ``messageOrder`` (In case of ``MessageOrdering/bottomToTop`` the list is sorted in ascending order).
    ///
    /// Use load messages in ``Chat`` for loading more messages.
    @Published public internal(set) var messages = StreamCollection<ChatMessage>([])
    
    /// Access a message which is available locally by its id.
    ///
    /// - Note: This method does a local lookup of the message and returns a message present in ``ChatState/messages``.
    ///
    /// - Parameter messageId: The id of the message which is available locally.
    ///
    /// - Returns: An instance of the locally available chat message
    public func localMessage(for messageId: MessageId) -> ChatMessage? {
        if let message = dataStore.message(id: messageId), message.cid == cid {
            return message
        }
        return nil
    }
    
    /// A Boolean value that returns whether the oldest messages have all been loaded or not.
    public var hasLoadedAllPreviousMessages: Bool {
        paginationStateHandler.state.hasLoadedAllPreviousMessages
    }
    
    /// A Boolean value that returns whether the newest messages have all been loaded or not.
    public var hasLoadedAllNextMessages: Bool {
        paginationStateHandler.state.hasLoadedAllNextMessages || messages.isEmpty
    }

    /// A Boolean value that returns whether the channel is currently in a mid-page.
    /// The value is false if the channel has the first page loaded.
    /// The value is true if the channel is in a mid fragment and didn't load the first page yet.
    public var isJumpingToMessage: Bool {
        paginationStateHandler.state.isJumpingToMessage
    }

    /// A Boolean value that returns whether the channel is currently loading a page around a message.
    public var isLoadingMiddleMessages: Bool {
        paginationStateHandler.state.isLoadingMiddleMessages
    }

    /// A Boolean value that returns whether the channel is currently loading next (new) messages.
    public var isLoadingNextMessages: Bool {
        paginationStateHandler.state.isLoadingNextMessages
    }

    /// A Boolean value that returns whether the channel is currently loading previous (old) messages.
    public var isLoadingPreviousMessages: Bool {
        paginationStateHandler.state.isLoadingPreviousMessages
    }
    
    // MARK: - Message Reading
    
    /// The id of the message which the current user last read.
    public var lastReadMessageId: MessageId? {
        guard let channel else { return nil }
        guard let userId = authenticationRepository.currentUserId else { return nil }
        return channel.lastReadMessageId(userId: userId)
    }
    
    /// The id of the first unread message.
    ///
    /// The returned message id follows requirements:
    /// * Read state is unavailable: oldest message if all the messages have been paginated, otherwise nil
    /// * Unread message count is zero: nil
    /// * Read state's ``ChatChannelRead/lastReadMessageId`` is nil: oldest message if all the messages have been paginated, otherwise nil
    /// * Last read message is unreachable (e.g. channel was truncated): oldest message if all the messages have been paginated, otherwise nil
    /// * Next message after the last read message id not from the current user
    public var firstUnreadMessageId: MessageId? {
        guard let userId = authenticationRepository.currentUserId else { return nil }
        return UnreadMessageLookup.firstUnreadMessage(in: self, userId: userId)
    }

    // MARK: - Throttling and Slow Mode
    
    /// The duration until the current user can't send new messages when the channel has slow mode enabled.
    ///
    /// - SeeAlso: ``Chat/enableSlowMode(cooldownDuration:)``
    /// - Returns: 0, if slow mode is not enabled, otherwise the remining cooldown duration in seconds.
    public var remainingCooldownDuration: Int {
        guard let channel else { return 0 }
        guard channel.cooldownDuration > 0 else { return 0 }
        guard !channel.ownCapabilities.contains(.skipSlowMode) else { return 0 }
        guard let lastMessageTimestamp = channel.lastMessageFromCurrentUser?.createdAt else { return 0 }
        let currentTime = Date().timeIntervalSince(lastMessageTimestamp)
        return max(0, channel.cooldownDuration - Int(currentTime))
    }
    
    // MARK: - Watchers
    
    /// An array of users who are currently watching the channel.
    ///
    /// Use load watchers method in ``Chat`` for populating this array.
    @Published public internal(set) var watchers = StreamCollection<ChatUser>([])
}