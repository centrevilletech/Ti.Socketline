/**
 * Ti.Socketline — native WebSocket client for Titanium.
 * Copyright (c) 2026 Centreville Tech LLC. Licensed under the Apache License, Version 2.0.
 */
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * The socket's state machine and argument validation, Foundation only, so it can be tested without
 * Titanium (test/run-ios-unit.sh). It is the iOS twin of the Android module's SocketCore.java, and both
 * are checked against test/vectors.json. Not thread-safe: the proxy uses it on the main queue only.
 */

typedef NS_ENUM(NSInteger, TiSocketlineState) {
  TiSocketlineStateConnecting = 0,
  TiSocketlineStateOpen = 1,
  TiSocketlineStateClosing = 2,
  TiSocketlineStateClosed = 3
};

typedef NS_ENUM(NSInteger, TiSocketlineAction) {
  TiSocketlineActionNone = 0,      // nothing to do with the transport
  TiSocketlineActionConnect = 1,   // start connecting
  TiSocketlineActionSendClose = 2, // send a close frame and close the connection
  TiSocketlineActionTeardown = 3   // tear the transport down now (abort a connect, release)
};

extern NSString *const TiSocketlineErrorInvalidOptions;
extern NSString *const TiSocketlineErrorCleartextNotPermitted;
extern NSString *const TiSocketlineErrorConnectFailed;
extern NSString *const TiSocketlineErrorTLSFailed;
extern NSString *const TiSocketlineErrorConnectTimeout;
extern NSString *const TiSocketlineErrorHandshakeFailed;
extern NSString *const TiSocketlineErrorConnectionLost;
extern NSString *const TiSocketlineErrorBinaryFrame;

extern const NSInteger TiSocketlineAbnormalClosure;  // 1006
extern const NSInteger TiSocketlineNoStatusReceived; // 1005

@interface TiSocketlineEvent : NSObject
@property (nonatomic, readonly, copy) NSString *type;   // open, message, error, close
@property (nonatomic, readonly, copy) NSString *data;   // message: text; open: subprotocol; error: description
@property (nonatomic, readonly, copy, nullable) NSString *error; // error: one of the error codes
@property (nonatomic, readonly) NSInteger code;         // close
@property (nonatomic, readonly, copy) NSString *reason; // close
@property (nonatomic, readonly) BOOL wasClean;          // close
@end

@interface TiSocketlineResult : NSObject
@property (nonatomic, readonly) TiSocketlineAction action;
@property (nonatomic, readonly, copy) NSArray<TiSocketlineEvent *> *events;
@end

@interface TiSocketlineCore : NSObject

@property (nonatomic, readonly) TiSocketlineState state;
@property (nonatomic, readonly) BOOL canSend;

- (TiSocketlineResult *)connect;
- (TiSocketlineResult *)openedWithProtocol:(nullable NSString *)protocol;
- (TiSocketlineResult *)message:(NSString *)text;
- (TiSocketlineResult *)binaryMessage;
/** close(code, reason) after validation. On an open socket "close" then reports this code and reason, clean. */
- (TiSocketlineResult *)requestCloseWithCode:(NSInteger)code reason:(nullable NSString *)reason;
- (void)closeFrameReceivedWithCode:(NSInteger)code reason:(nullable NSString *)reason;
- (TiSocketlineResult *)connectFailedWithError:(NSString *)error description:(nullable NSString *)description;
- (TiSocketlineResult *)transportClosedWithError:(nullable NSString *)error description:(nullable NSString *)description;
- (TiSocketlineResult *)releaseSocket;

+ (NSInteger)normalizeReceivedCode:(NSInteger)code;
+ (BOOL)isValidWireCode:(NSInteger)code;
/** nil when valid, otherwise the message of the exception to throw. nil/NSNull mean "not given". */
+ (nullable NSString *)validateCloseCode:(nullable id)code reason:(nullable id)reason;
+ (NSInteger)closeCodeOrDefault:(nullable id)code;
/** nil when valid, otherwise a description for the INVALID_OPTIONS error. */
+ (nullable NSString *)validateOptionsWithURL:(nullable id)url
                                      headers:(nullable id)headers
                                    protocols:(nullable id)protocols
                               connectTimeout:(nullable id)connectTimeout;
/** The subprotocols of a valid protocols option. */
+ (NSArray<NSString *> *)protocolList:(nullable id)protocols;
/** A header value as text (numbers and booleans as JavaScript prints them). */
+ (NSString *)headerValue:(id)value;
+ (BOOL)isToken:(nullable NSString *)value;
/**
 * Whether the app's App Transport Security settings (Info.plist NSAppTransportSecurity) permit cleartext to
 * this host. NSURLSession does not apply ATS to ws:// (observed on iOS 27), so the module applies the
 * cleartext rules itself: a matching NSExceptionDomains entry decides; otherwise NSAllowsLocalNetworking
 * for localhost, .local, unqualified names and IP literals; otherwise NSAllowsArbitraryLoads (ignored, as in
 * ATS, when NSAllowsLocalNetworking, NSAllowsArbitraryLoadsInWebContent or NSAllowsArbitraryLoadsForMedia is set).
 */
+ (BOOL)cleartextPermittedForHost:(NSString *)host transportSecurity:(nullable NSDictionary *)ats;
+ (BOOL)isLocalHost:(NSString *)host;

@end

NS_ASSUME_NONNULL_END
