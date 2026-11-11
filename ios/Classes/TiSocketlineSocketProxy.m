/**
 * Ti.Socketline — native WebSocket client for Titanium.
 * Copyright (c) 2026 Centreville Tech LLC. Licensed under the Apache License, Version 2.0.
 */
#import "TiSocketlineSocketProxy.h"
#import "TiUtils.h"

static const NSInteger kStateConnecting = 0;
static const NSInteger kStateOpen = 1;
static const NSInteger kStateClosing = 2;
static const NSInteger kStateClosed = 3;
static const double kDefaultConnectTimeoutMs = 15000;

@implementation TiSocketlineSocketProxy {
  NSURLSession *_session;
  NSURLSessionWebSocketTask *_task;
  NSInteger _readyState;
  BOOL _started;
  BOOL _closeFired;
  NSInteger _requestedCloseCode;
  NSString *_requestedCloseReason;
}

- (NSString *)apiName
{
  return @"Ti.Socketline.Socket";
}

- (NSNumber *)readyState
{
  return @(_readyState);
}

- (NSString *)url
{
  return [TiUtils stringValue:[self valueForUndefinedKey:@"url"]];
}

#pragma mark Public API

- (void)connect:(id)unused
{
  if (_started) {
    NSLog(@"[WARN] Ti.Socketline: connect() called twice: create a new socket to reconnect");
    return;
  }
  _started = YES;
  _readyState = kStateConnecting;

  NSString *urlString = [self url];
  NSURL *url = urlString != nil ? [NSURL URLWithString:urlString] : nil;
  NSString *scheme = url.scheme.lowercaseString;
  if (url == nil || !([scheme isEqualToString:@"ws"] || [scheme isEqualToString:@"wss"])) {
    [self failWithMessage:@"The url must start with ws:// or wss://"];
    return;
  }

  double timeoutMs = [TiUtils doubleValue:[self valueForUndefinedKey:@"connectTimeout"] def:kDefaultConnectTimeoutMs];
  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
  request.timeoutInterval = timeoutMs / 1000.0;
  id headers = [self valueForUndefinedKey:@"headers"];
  if ([headers isKindOfClass:[NSDictionary class]]) {
    for (id key in headers) {
      [request setValue:[TiUtils stringValue:headers[key]] forHTTPHeaderField:[TiUtils stringValue:key]];
    }
  }

  NSOperationQueue *queue = [[NSOperationQueue alloc] init];
  queue.maxConcurrentOperationCount = 1;
  _session = [NSURLSession sessionWithConfiguration:[NSURLSessionConfiguration defaultSessionConfiguration]
                                           delegate:self
                                      delegateQueue:queue];
  _task = [_session webSocketTaskWithRequest:request];
  [self rememberSelf]; // stay alive while the connection is open, even if JavaScript drops its reference
  [_task resume];
}

- (NSNumber *)send:(id)args
{
  ENSURE_SINGLE_ARG(args, NSString);
  if (_task == nil || _readyState != kStateOpen) {
    return @(NO);
  }
  NSURLSessionWebSocketMessage *message = [[NSURLSessionWebSocketMessage alloc] initWithString:args];
  [_task sendMessage:message
      completionHandler:^(NSError *error) {
        if (error != nil) {
          NSLog(@"[WARN] Ti.Socketline: send failed: %@", error.localizedDescription);
        }
      }];
  return @(YES);
}

- (void)close:(id)args
{
  if (_task == nil || _readyState >= kStateClosing) {
    return;
  }
  NSArray *list = [args isKindOfClass:[NSArray class]] ? args : @[];
  NSInteger code = list.count > 0 && list[0] != [NSNull null] ? [TiUtils intValue:list[0] def:1000] : 1000;
  NSString *reason = list.count > 1 ? [TiUtils stringValue:list[1]] : @"";
  _readyState = kStateClosing;
  _requestedCloseCode = code;
  _requestedCloseReason = reason ?: @"";
  [_task cancelWithCloseCode:(NSURLSessionWebSocketCloseCode)code reason:[_requestedCloseReason dataUsingEncoding:NSUTF8StringEncoding]];
}

#pragma mark Receiving

- (void)receiveNext
{
  NSURLSessionWebSocketTask *task = _task;
  __weak TiSocketlineSocketProxy *weakSelf = self;
  [task receiveMessageWithCompletionHandler:^(NSURLSessionWebSocketMessage *message, NSError *error) {
    TiSocketlineSocketProxy *strongSelf = weakSelf;
    if (strongSelf == nil || error != nil) {
      return; // the task's completion reports the error and the close
    }
    NSString *text = message.type == NSURLSessionWebSocketMessageTypeString
        ? message.string
        : [[NSString alloc] initWithData:message.data encoding:NSUTF8StringEncoding];
    if (text != nil) {
      [strongSelf fireEvent:@"message" withObject:@{ @"data" : text }];
    }
    [strongSelf receiveNext];
  }];
}

#pragma mark NSURLSessionWebSocketDelegate

- (void)URLSession:(NSURLSession *)session webSocketTask:(NSURLSessionWebSocketTask *)webSocketTask didOpenWithProtocol:(NSString *)protocol
{
  _readyState = kStateOpen;
  [self fireEvent:@"open" withObject:@{}];
  [self receiveNext];
}

- (void)URLSession:(NSURLSession *)session webSocketTask:(NSURLSessionWebSocketTask *)webSocketTask didCloseWithCode:(NSURLSessionWebSocketCloseCode)closeCode reason:(NSData *)reason
{
  NSString *text = reason != nil ? [[NSString alloc] initWithData:reason encoding:NSUTF8StringEncoding] : @"";
  [self fireCloseWithCode:closeCode reason:text ?: @""];
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error
{
  if (_requestedCloseCode != 0) {
    [self fireCloseWithCode:_requestedCloseCode reason:_requestedCloseReason];
  } else if (error != nil) {
    [self fireEvent:@"error" withObject:@{ @"error" : error.localizedDescription ?: @"Connection failed" }];
    [self fireCloseWithCode:1006 reason:error.localizedDescription ?: @""];
  } else {
    [self fireCloseWithCode:1006 reason:@""];
  }
  [session finishTasksAndInvalidate]; // releases the session's strong reference to this delegate
}

#pragma mark Helpers

- (void)fireCloseWithCode:(NSInteger)code reason:(NSString *)reason
{
  if (_closeFired) {
    return;
  }
  _closeFired = YES;
  _readyState = kStateClosed;
  BOOL clean = code == 1000 || code == 1001;
  [self fireEvent:@"close" withObject:@{ @"code" : @(code), @"reason" : reason ?: @"", @"wasClean" : @(clean) }];
  [self forgetSelf];
}

- (void)failWithMessage:(NSString *)message
{
  _readyState = kStateClosed;
  _closeFired = YES;
  [self fireEvent:@"error" withObject:@{ @"error" : message }];
  [self fireEvent:@"close" withObject:@{ @"code" : @(1006), @"reason" : message, @"wasClean" : @(NO) }];
}

@end
