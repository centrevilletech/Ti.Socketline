/**
 * Ti.Socketline — native WebSocket client for Titanium.
 * Copyright (c) 2026 Centreville Tech LLC. Licensed under the Apache License, Version 2.0.
 */
#import "TiSocketlineSocketProxy.h"
#import "TiSocketlineCore.h"
#import "TiUtils.h"

static const double kDefaultConnectTimeoutMs = 15000;
// The connect deadline is this module's own. The request's timeout is an idle timeout in NSURLSession, so
// it is set out of the way: an open socket must not time out while idle (keep-alive is the app's).
static const NSTimeInterval kIdleTimeout = 7 * 24 * 3600;
static const NSInteger kMaximumMessageSize = 16 * 1024 * 1024;

/**
 * Threading: everything runs on the main queue. JavaScript calls arrive there (Titanium runs JavaScript on
 * the main thread), the session's delegate queue is the main queue, and so is the connect timer. The core
 * is therefore only touched from one thread, and events are queued with dispatch_async so they are always
 * delivered after the call that caused them returned, in the order the core decided them.
 *
 * Titanium exposes every zero- and one-argument method of a proxy to JavaScript, so the internals are C
 * functions below, not methods.
 */
@implementation TiSocketlineSocketProxy {
  TiSocketlineCore *_core;
  NSURLSession *_session;
  NSURLSessionWebSocketTask *_task;
  NSArray<NSString *> *_offeredProtocols;
  NSString *_protocol;
  dispatch_block_t _connectTimer;
  BOOL _remembered;
}

static void Apply(TiSocketlineSocketProxy *self, TiSocketlineResult *result);
static void ReceiveNext(TiSocketlineSocketProxy *self);

static void OnMain(dispatch_block_t block)
{
  if ([NSThread isMainThread]) {
    block();
  } else {
    dispatch_sync(dispatch_get_main_queue(), block);
  }
}

static void CancelConnectTimer(TiSocketlineSocketProxy *self)
{
  if (self->_connectTimer != nil) {
    dispatch_block_cancel(self->_connectTimer);
    self->_connectTimer = nil;
  }
}

static void Teardown(TiSocketlineSocketProxy *self)
{
  CancelConnectTimer(self);
  [self->_task cancel]; // completes the task; its late callbacks find the core closed and do nothing
}

/** Performs a core result: tears the transport down if asked, and queues the events. */
static void Apply(TiSocketlineSocketProxy *self, TiSocketlineResult *result)
{
  if (result.action == TiSocketlineActionTeardown) {
    Teardown(self);
  }
  for (TiSocketlineEvent *event in result.events) {
    NSDictionary *data;
    if ([event.type isEqualToString:@"open"]) {
      data = @{ @"protocol" : event.data };
    } else if ([event.type isEqualToString:@"message"]) {
      data = @{ @"data" : event.data };
    } else if ([event.type isEqualToString:@"error"]) {
      data = @{ @"error" : event.data, @"code" : event.error ?: @"" };
    } else {
      data = @{ @"code" : @(event.code), @"reason" : event.reason, @"wasClean" : @(event.wasClean) };
    }
    BOOL isClose = [event.type isEqualToString:@"close"];
    NSString *type = event.type;
    dispatch_async(dispatch_get_main_queue(), ^{
      [self fireEvent:type withObject:data];
      if (isClose && self->_remembered) {
        self->_remembered = NO;
        [self forgetSelf];
      }
    });
  }
}

static NSString *ClassifyConnectError(NSError *error)
{
  if ([error.domain isEqualToString:NSURLErrorDomain]) {
    switch (error.code) {
      case NSURLErrorAppTransportSecurityRequiresSecureConnection:
        return TiSocketlineErrorCleartextNotPermitted;
      case NSURLErrorSecureConnectionFailed:
      case NSURLErrorServerCertificateHasBadDate:
      case NSURLErrorServerCertificateUntrusted:
      case NSURLErrorServerCertificateHasUnknownRoot:
      case NSURLErrorServerCertificateNotYetValid:
      case NSURLErrorClientCertificateRejected:
      case NSURLErrorClientCertificateRequired:
        return TiSocketlineErrorTLSFailed;
      case NSURLErrorTimedOut:
        return TiSocketlineErrorConnectTimeout;
      case NSURLErrorBadServerResponse:
        return TiSocketlineErrorHandshakeFailed;
      default:
        break;
    }
  }
  return TiSocketlineErrorConnectFailed;
}

static void ReceiveNext(TiSocketlineSocketProxy *self)
{
  NSURLSessionWebSocketTask *task = self->_task;
  __weak TiSocketlineSocketProxy *weakSelf = self;
  [task receiveMessageWithCompletionHandler:^(NSURLSessionWebSocketMessage *message, NSError *error) {
    TiSocketlineSocketProxy *strongSelf = weakSelf;
    if (strongSelf == nil || error != nil) {
      return; // the task's completion reports the error and the close
    }
    if (message.type == NSURLSessionWebSocketMessageTypeString) {
      Apply(strongSelf, [strongSelf->_core message:message.string ?: @""]);
    } else {
      Apply(strongSelf, [strongSelf->_core binaryMessage]);
    }
    TiSocketlineState state = strongSelf->_core.state;
    if (state == TiSocketlineStateOpen || state == TiSocketlineStateClosing) {
      ReceiveNext(strongSelf);
    }
  }];
}

static void Connect(TiSocketlineSocketProxy *self)
{
  if ([self->_core connect].action != TiSocketlineActionConnect) {
    NSLog(@"[WARN] Ti.Socketline: connect() ignored: a socket connects once (create a new socket to reconnect)");
    return;
  }
  [self rememberSelf]; // stay alive until "close" was delivered, even if JavaScript drops its reference
  self->_remembered = YES;

  id url = [self valueForUndefinedKey:@"url"];
  id headers = [self valueForUndefinedKey:@"headers"];
  id protocols = [self valueForUndefinedKey:@"protocols"];
  id connectTimeout = [self valueForUndefinedKey:@"connectTimeout"];
  NSString *invalid = [TiSocketlineCore validateOptionsWithURL:url headers:headers protocols:protocols connectTimeout:connectTimeout];
  if (invalid != nil) {
    Apply(self, [self->_core connectFailedWithError:TiSocketlineErrorInvalidOptions description:invalid]);
    return;
  }
  NSURL *parsed = [NSURL URLWithString:url];
  NSString *host = parsed.host;
  if ([parsed.scheme.lowercaseString isEqualToString:@"ws"]
      && ![TiSocketlineCore cleartextPermittedForHost:host transportSecurity:[[NSBundle mainBundle] objectForInfoDictionaryKey:@"NSAppTransportSecurity"]]) {
    NSString *description = [NSString stringWithFormat:@"Cleartext ws:// to %@ is not permitted by the app's App Transport Security settings: use wss://", host];
    Apply(self, [self->_core connectFailedWithError:TiSocketlineErrorCleartextNotPermitted description:description]);
    return;
  }
  double connectTimeoutMs = connectTimeout != nil && connectTimeout != [NSNull null] ? [connectTimeout doubleValue] : kDefaultConnectTimeoutMs;
  self->_offeredProtocols = [TiSocketlineCore protocolList:protocols];

  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:parsed];
  request.timeoutInterval = kIdleTimeout;
  if ([headers isKindOfClass:[NSDictionary class]]) {
    for (id key in headers) {
      [request setValue:[TiSocketlineCore headerValue:headers[key]] forHTTPHeaderField:[key description]];
    }
  }
  if (self->_offeredProtocols.count > 0) {
    // webSocketTaskWithURL:protocols: takes no headers, so the offer goes on the request; NSURLSession sends
    // it and reports the selected subprotocol to didOpenWithProtocol, where it is checked.
    [request setValue:[self->_offeredProtocols componentsJoinedByString:@", "] forHTTPHeaderField:@"Sec-WebSocket-Protocol"];
  }

  NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration defaultSessionConfiguration];
  configuration.timeoutIntervalForRequest = kIdleTimeout;
  self->_session = [NSURLSession sessionWithConfiguration:configuration delegate:self delegateQueue:[NSOperationQueue mainQueue]];
  self->_task = [self->_session webSocketTaskWithRequest:request];
  self->_task.maximumMessageSize = kMaximumMessageSize;

  __weak TiSocketlineSocketProxy *weakSelf = self;
  self->_connectTimer = dispatch_block_create(0, ^{
    TiSocketlineSocketProxy *strongSelf = weakSelf;
    if (strongSelf == nil) {
      return;
    }
    NSString *description = [NSString stringWithFormat:@"No connection within %.0f ms", connectTimeoutMs];
    Apply(strongSelf, [strongSelf->_core connectFailedWithError:TiSocketlineErrorConnectTimeout description:description]);
  });
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(connectTimeoutMs * NSEC_PER_MSEC)), dispatch_get_main_queue(), self->_connectTimer);
  [self->_task resume];
}

#pragma mark Lifecycle and properties

- (instancetype)init
{
  if (self = [super init]) {
    _core = [[TiSocketlineCore alloc] init];
    _protocol = @"";
    _offeredProtocols = @[];
  }
  return self;
}

- (NSString *)apiName
{
  return @"Ti.Socketline.Socket";
}

- (NSNumber *)readyState
{
  __block NSInteger state;
  OnMain(^{
    state = self->_core.state;
  });
  return @(state);
}

- (NSString *)url
{
  return [TiUtils stringValue:[self valueForUndefinedKey:@"url"]];
}

/** The subprotocol the server selected ("" for none, or before open). */
- (NSString *)protocol
{
  __block NSString *protocol;
  OnMain(^{
    protocol = self->_protocol;
  });
  return protocol;
}

#pragma mark Public API

- (void)connect:(id)unused
{
  OnMain(^{
    Connect(self);
  });
}

- (NSNumber *)send:(id)args
{
  ENSURE_SINGLE_ARG(args, NSString);
  __block BOOL sent = NO;
  OnMain(^{
    if (self->_task == nil || !self->_core.canSend) {
      return;
    }
    NSURLSessionWebSocketMessage *message = [[NSURLSessionWebSocketMessage alloc] initWithString:args];
    [self->_task sendMessage:message
           completionHandler:^(NSError *error) {
             if (error != nil) {
               NSLog(@"[WARN] Ti.Socketline: send failed: %@", error.localizedDescription);
             }
           }];
    sent = YES;
  });
  return @(sent);
}

- (void)close:(id)args
{
  NSArray *list = [args isKindOfClass:[NSArray class]] ? args : (args != nil ? @[ args ] : @[]);
  id code = list.count > 0 ? list[0] : nil;
  id reason = list.count > 1 ? list[1] : nil;
  NSString *invalid = [TiSocketlineCore validateCloseCode:code reason:reason];
  if (invalid != nil) {
    [self throwException:invalid subreason:nil location:CODELOCATION];
    return;
  }
  NSInteger closeCode = [TiSocketlineCore closeCodeOrDefault:code];
  NSString *closeReason = reason != nil && reason != [NSNull null] ? reason : @"";
  OnMain(^{
    TiSocketlineResult *result = [self->_core requestCloseWithCode:closeCode reason:closeReason];
    if (result.action == TiSocketlineActionSendClose) {
      // NSURLSession sends the close frame and closes the connection without waiting for the server's answer.
      [self->_task cancelWithCloseCode:(NSURLSessionWebSocketCloseCode)closeCode reason:[closeReason dataUsingEncoding:NSUTF8StringEncoding]];
    }
    Apply(self, result);
  });
}

#pragma mark NSURLSessionWebSocketDelegate

- (void)URLSession:(NSURLSession *)session webSocketTask:(NSURLSessionWebSocketTask *)webSocketTask didOpenWithProtocol:(NSString *)protocol
{
  if (webSocketTask != _task) {
    return;
  }
  NSString *selected = protocol ?: @"";
  if (selected.length > 0 && ![_offeredProtocols containsObject:selected]) {
    NSString *description = [NSString stringWithFormat:@"The server selected a subprotocol that was not offered: %@", selected];
    Apply(self, [_core connectFailedWithError:TiSocketlineErrorHandshakeFailed description:description]);
    return;
  }
  CancelConnectTimer(self);
  _protocol = selected;
  TiSocketlineResult *result = [_core openedWithProtocol:selected];
  Apply(self, result);
  if (result.action != TiSocketlineActionTeardown) {
    ReceiveNext(self);
  }
}

- (void)URLSession:(NSURLSession *)session webSocketTask:(NSURLSessionWebSocketTask *)webSocketTask didCloseWithCode:(NSURLSessionWebSocketCloseCode)closeCode reason:(NSData *)reason
{
  if (webSocketTask != _task) {
    return;
  }
  // The server's close frame, or (after close()) the app's own code reported back: the core only takes it
  // as the server's when the app had not asked to close.
  NSString *text = reason != nil ? [[NSString alloc] initWithData:reason encoding:NSUTF8StringEncoding] : @"";
  [_core closeFrameReceivedWithCode:closeCode reason:text ?: @""];
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error
{
  if (task == _task) {
    CancelConnectTimer(self);
    if (_core.state == TiSocketlineStateConnecting) {
      Apply(self, [_core connectFailedWithError:ClassifyConnectError(error) description:error.localizedDescription ?: @"The connection failed"]);
    } else {
      Apply(self, [_core transportClosedWithError:(error != nil ? TiSocketlineErrorConnectionLost : nil)
                                      description:error.localizedDescription ?: @"The connection closed without a close frame"]);
    }
  }
  [session finishTasksAndInvalidate]; // releases the session's strong reference to this delegate
}

@end
