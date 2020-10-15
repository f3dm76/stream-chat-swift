//
// Copyright © 2020 Stream.io Inc. All rights reserved.
//

import Foundation

/// A channel query.
public struct ChannelQuery<ExtraData: ExtraDataTypes>: Encodable {
    private enum CodingKeys: String, CodingKey {
        case data
        case messages
        case members
        case watchers
    }

    /// Channel id this query handles.
    public let id: String?
    /// Channel type this query handles.
    public let type: ChannelType
    /// A pagination for messages (see `Pagination`).
    public var messagesPagination: Pagination
    /// A pagination for members (see `Pagination`). You can use `.limit` and `.offset`.
    public let membersPagination: Pagination
    /// A pagination for watchers (see `Pagination`). You can use `.limit` and `.offset`.
    public let watchersPagination: Pagination
    /// A query options.
    var options: QueryOptions = .all
    /// ChannelCreatePayload that is needed only when creating channel
    let channelPayload: ChannelEditDetailPayload<ExtraData>?
    
    /// `ChannelId` this query handles.
    /// If `id` part is missing then it's impossible to create valid `ChannelId`.
    public var cid: ChannelId? {
        id.map { ChannelId(type: type, id: $0) }
    }
    
    /// Path parameters that are used in endpoints.
    var pathParameters: String {
        guard let id = id else { return "\(type)" }
        return "\(type)/\(id)"
    }

    /// Init a channel query.
    /// - Parameters:
    ///   - cid: a channel cid.
    ///   - messagesPagination: a pagination for messages.
    ///   - membersPagination: a pagination for members. You can use `.limit` and `.offset`.
    ///   - watchersPagination: a pagination for watchers. You can use `.limit` and `.offset`.
    ///   - options: a query options (see `QueryOptions`).
    public init(
        cid: ChannelId,
        messagesPagination: Pagination = [],
        membersPagination: Pagination = [],
        watchersPagination: Pagination = []
    ) {
        id = cid.id
        type = cid.type
        channelPayload = nil
        self.messagesPagination = messagesPagination
        self.membersPagination = membersPagination
        self.watchersPagination = watchersPagination
    }

    /// Init a channel query.
    /// - Parameters:
    ///   - channelPayload: a payload that has data needed for channel creation.
    init(channelPayload: ChannelEditDetailPayload<ExtraData>) {
        id = channelPayload.id
        type = channelPayload.type
        self.channelPayload = channelPayload
        messagesPagination = []
        membersPagination = []
        watchersPagination = []
    }

    /// Init a channel query.
    /// - Parameters:
    ///   - cid: New `ChannelId` for channel query..
    ///   - channelQuery: ChannelQuery with old cid.
    init(cid: ChannelId, channelQuery: Self) {
        self.init(
            cid: cid,
            messagesPagination: channelQuery.messagesPagination,
            membersPagination: channelQuery.membersPagination,
            watchersPagination: channelQuery.watchersPagination
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        try options.encode(to: encoder)

        // Only needed for channel creation
        try container.encodeIfPresent(channelPayload, forKey: .data)
        
        if !messagesPagination.isEmpty {
            try container.encode(messagesPagination, forKey: .messages)
        }
        
        if !membersPagination.isEmpty {
            try container.encode(membersPagination, forKey: .members)
        }
        
        if !watchersPagination.isEmpty {
            try container.encode(watchersPagination, forKey: .watchers)
        }
    }
}

///// An answer for an invite to a channel.
// public struct ChannelInviteAnswer: Encodable {
//    private enum CodingKeys: String, CodingKey {
//        case accept = "accept_invite"
//        case reject = "reject_invite"
//        case message
//    }
//
//    /// A channel.
//    let channel: Channel
//    /// Accept the invite.
//    let accept: Bool?
//    /// Reject the invite.
//    let reject: Bool?
//    /// Additional message.
//    let message: Message?
// }
//
///// An answer for an invite to a channel.
// public struct ChannelInviteResponse: Decodable {
//    /// A channel.
//    let channel: Channel
//    /// Members.
//    let members: [Member]
//    /// Accept the invite.
//    let message: Message?
// }
//
// public struct ChannelUpdate: Encodable {
//    struct ChannelData: Encodable {
//        let channel: Channel
//
//        init(_ channel: Channel) {
//            self.channel = channel
//        }
//
//        func encode(to encoder: Encoder) throws {
//            var container = encoder.container(keyedBy: Channel.EncodingKeys.self)
//            try container.encode(channel.name, forKey: .name)
//            try container.encodeIfPresent(channel.imageURL, forKey: .imageURL)
//            channel.extraData?.encodeSafely(to: encoder, logMessage: "📦 when encoding a channel extra data")
//        }
//    }
//
//    let data: ChannelData
// }
