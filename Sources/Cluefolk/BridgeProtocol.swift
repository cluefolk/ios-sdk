// Generated from bridge.schema.json, the Cluefolk bridge contract (sha256 590b0e97b6a5fad00d8d5730b414546200e1fcce768f7adeb4ad3ef7ed901820). Do not edit.

enum BridgeProtocol {
    static let protocolName = "cluefolk"
    static let version = 2
    static let schemaSHA256 = "590b0e97b6a5fad00d8d5730b414546200e1fcce768f7adeb4ad3ef7ed901820"
    static let nativeReady = "native.ready"
    static let nativeAuthRequired = "native.authRequired"
    static let nativeClose = "native.close"
    static let nativeUnreadCountChanged = "native.unreadCountChanged"
    static let nativeHistoryPage = "native.historyPage"
    static let nativeConversationCreated = "native.conversationCreated"
    static let nativeConversationStatusChanged = "native.conversationStatusChanged"
    static let nativeMessageSent = "native.messageSent"
    static let nativeDraftGet = "native.draftGet"
    static let nativeDraftPut = "native.draftPut"
    static let nativeImagePut = "native.imagePut"
    static let nativeImageGet = "native.imageGet"
    static let sdkBootstrap = "sdk.bootstrap"
    static let sdkAck = "sdk.ack"
    static let sdkError = "sdk.error"
    static let nativeRequests: Set<String> = ["native.ready", "native.authRequired", "native.close", "native.unreadCountChanged", "native.historyPage", "native.conversationCreated", "native.conversationStatusChanged", "native.messageSent", "native.draftGet", "native.draftPut", "native.imagePut", "native.imageGet"]
    static let navigationScreens: Set<String> = ["home", "conversation"]
}
