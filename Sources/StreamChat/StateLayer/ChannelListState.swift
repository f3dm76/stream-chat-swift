//
// Copyright © 2024 Stream.io Inc. All rights reserved.
//

import Foundation
import OSLog

/// Represents a list of channels matching to the specified query.
@MainActor public final class ChannelListState: ObservableObject {
    private let observer: Observer
    
    init(
        query: ChannelListQuery,
        dynamicFilter: ((ChatChannel) -> Bool)?,
        clientConfig: ChatClientConfig,
        channelListUpdater: ChannelListUpdater,
        database: DatabaseContainer,
        eventNotificationCenter: EventNotificationCenter
    ) {
        self.query = query
        observer = Observer(
            query: query,
            dynamicFilter: dynamicFilter,
            clientConfig: clientConfig,
            channelListUpdater: channelListUpdater,
            database: database,
            eventNotificationCenter: eventNotificationCenter
        )
        channels = observer.start(
            with: .init(channelsDidChange: { [weak self] in 
                self?.channels = $0
                debugChatPrint("STEP 3 ChannelListState received update", $0.map { "channel id: \($0.cid) name: \($0.name ?? "") isUnread: \($0.isUnread)" })
            })
        )
    }
    
    /// The query used for filtering the list of channels.
    public let query: ChannelListQuery
    
    /// An array of channels for the specified ``ChannelListQuery``.
    @Published public internal(set) var channels = StreamCollection<ChatChannel>([])
}

func debugChatPrint(_ items: Any...) {
    let log = items.reduce("") { partialResult, next in
        partialResult + "\(next)"
    }
#if swift(>=5.6)
    if #available(iOS 14.0, *) {
        os_log("bynd stream chat: \(log)")
    } else {
        // Fallback on earlier versions
    }
#endif
}
