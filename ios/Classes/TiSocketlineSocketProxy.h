/**
 * Ti.Socketline — native WebSocket client for Titanium.
 * Copyright (c) 2026 Centreville Tech LLC. Licensed under the Apache License, Version 2.0.
 */
#import "TiProxy.h"

/**
 * One WebSocket connection, created with createSocket({ url, headers, protocols, connectTimeout }).
 * Single use, like a browser WebSocket: connect() once, close() once, then create a new socket.
 * Events: open { protocol }, message { data }, error { error, code }, close { code, reason, wasClean }.
 * The state machine is TiSocketlineCore (shared contract with Android, see test/vectors.json).
 */
@interface TiSocketlineSocketProxy : TiProxy <NSURLSessionWebSocketDelegate>

@end
