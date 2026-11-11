/**
 * Ti.Socketline — native WebSocket client for Titanium.
 * Copyright (c) 2026 Centreville Tech LLC. Licensed under the Apache License, Version 2.0.
 */
#import "TiProxy.h"

/**
 * One WebSocket connection, created with createSocket({ url, headers, connectTimeout }).
 * Single use, like a browser WebSocket: connect() once, close() once, then create a new socket.
 * Events: open, message { data }, error { error }, close { code, reason, wasClean }.
 */
@interface TiSocketlineSocketProxy : TiProxy <NSURLSessionWebSocketDelegate>

@end
