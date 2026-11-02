// Generated from bridge.schema.json, the Cluefolk bridge contract (sha256 590b0e97b6a5fad00d8d5730b414546200e1fcce768f7adeb4ad3ef7ed901820). Do not edit.

enum BridgeFixtures {
    static let all: [String: String] = [
        "native.authRequired.json": #"""
{
  "protocol": "cluefolk",
  "version": 2,
  "requestId": "00000000-0000-4000-8000-000000000001",
  "type": "native.authRequired",
  "payload": {}
}
"""#,
        "native.close.json": #"""
{
  "protocol": "cluefolk",
  "version": 2,
  "requestId": "00000000-0000-4000-8000-000000000001",
  "type": "native.close",
  "payload": {}
}
"""#,
        "native.conversationCreated.json": #"""
{
  "protocol": "cluefolk",
  "version": 2,
  "requestId": "00000000-0000-4000-8000-000000000001",
  "type": "native.conversationCreated",
  "payload": {
    "conversationId": "7b1c7c3e-1f9a-4a0e-9f4b-1d2e3f4a5b6c"
  }
}
"""#,
        "native.conversationStatusChanged.json": #"""
{
  "protocol": "cluefolk",
  "version": 2,
  "requestId": "00000000-0000-4000-8000-000000000001",
  "type": "native.conversationStatusChanged",
  "payload": {
    "conversationId": "7b1c7c3e-1f9a-4a0e-9f4b-1d2e3f4a5b6c",
    "status": "resolved"
  }
}
"""#,
        "native.draftGet.json": #"""
{
  "protocol": "cluefolk",
  "version": 2,
  "requestId": "00000000-0000-4000-8000-000000000001",
  "type": "native.draftGet",
  "payload": {
    "key": "new"
  }
}
"""#,
        "native.draftPut.json": #"""
{
  "protocol": "cluefolk",
  "version": 2,
  "requestId": "00000000-0000-4000-8000-000000000001",
  "type": "native.draftPut",
  "payload": {
    "key": "new",
    "content": {
      "body": "Hello",
      "attachments": [],
      "clientId": "c3f9",
      "version": 0,
      "visibility": "public",
      "mentions": [],
      "dirty": true
    }
  }
}
"""#,
        "native.historyPage.json": #"""
{
  "protocol": "cluefolk",
  "version": 2,
  "requestId": "00000000-0000-4000-8000-000000000001",
  "type": "native.historyPage",
  "payload": {
    "syncId": "b8f6",
    "index": 0
  }
}
"""#,
        "native.imageGet.json": #"""
{
  "protocol": "cluefolk",
  "version": 2,
  "requestId": "00000000-0000-4000-8000-000000000001",
  "type": "native.imageGet",
  "payload": {
    "id": "00000000-0000-4000-8000-000000000002"
  }
}
"""#,
        "native.imagePut.json": #"""
{
  "protocol": "cluefolk",
  "version": 2,
  "requestId": "00000000-0000-4000-8000-000000000001",
  "type": "native.imagePut",
  "payload": {
    "id": "00000000-0000-4000-8000-000000000002",
    "data": "/9j/4AAQSkZJRg=="
  }
}
"""#,
        "native.messageSent.json": #"""
{
  "protocol": "cluefolk",
  "version": 2,
  "requestId": "00000000-0000-4000-8000-000000000001",
  "type": "native.messageSent",
  "payload": {
    "conversationId": "7b1c7c3e-1f9a-4a0e-9f4b-1d2e3f4a5b6c",
    "messageId": "0f5e3b1a-2c4d-4e6f-8a9b-0c1d2e3f4a5b"
  }
}
"""#,
        "native.ready.json": #"""
{
  "protocol": "cluefolk",
  "version": 2,
  "requestId": "00000000-0000-4000-8000-000000000001",
  "type": "native.ready",
  "payload": {}
}
"""#,
        "native.unreadCountChanged.json": #"""
{
  "protocol": "cluefolk",
  "version": 2,
  "requestId": "00000000-0000-4000-8000-000000000001",
  "type": "native.unreadCountChanged",
  "payload": {
    "count": 3
  }
}
"""#,
        "sdk.ack.json": #"""
{
  "protocol": "cluefolk",
  "version": 2,
  "requestId": "00000000-0000-4000-8000-000000000001",
  "type": "sdk.ack",
  "payload": {}
}
"""#,
        "sdk.bootstrap.json": #"""
{
  "protocol": "cluefolk",
  "version": 2,
  "requestId": "00000000-0000-4000-8000-000000000001",
  "type": "sdk.bootstrap",
  "payload": {
    "code": "ZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ",
    "apiBaseUrl": "https://cluefolk.com",
    "context": {
      "screen": "inventory",
      "_cluefolk": {
        "platform": "android",
        "sdkVersion": "0.2.0"
      }
    },
    "appearance": null,
    "logo": null,
    "language": "en-US",
    "navigation": {
      "screen": "conversation",
      "id": ""
    },
    "unreadCount": 0,
    "eventCursor": "12345:0",
    "historySyncId": "b8f6",
    "historyPageCount": 1,
    "player": {
      "kind": "anonymous",
      "externalUserId": null,
      "claimedExternalId": ""
    }
  }
}
"""#,
        "sdk.error.json": #"""
{
  "protocol": "cluefolk",
  "version": 2,
  "requestId": "00000000-0000-4000-8000-000000000001",
  "type": "sdk.error",
  "payload": {
    "code": "NOT_READY"
  }
}
"""#,
    ]
}
