/**
 * Ti.Socketline — native WebSocket client for Titanium.
 * Copyright (c) 2026 Centreville Tech LLC. Licensed under the Apache License, Version 2.0.
 */
#import "TiSocketlineCore.h"

NSString *const TiSocketlineErrorInvalidOptions = @"INVALID_OPTIONS";
NSString *const TiSocketlineErrorCleartextNotPermitted = @"CLEARTEXT_NOT_PERMITTED";
NSString *const TiSocketlineErrorConnectFailed = @"CONNECT_FAILED";
NSString *const TiSocketlineErrorTLSFailed = @"TLS_FAILED";
NSString *const TiSocketlineErrorConnectTimeout = @"CONNECT_TIMEOUT";
NSString *const TiSocketlineErrorHandshakeFailed = @"HANDSHAKE_FAILED";
NSString *const TiSocketlineErrorConnectionLost = @"CONNECTION_LOST";
NSString *const TiSocketlineErrorBinaryFrame = @"BINARY_FRAME";

const NSInteger TiSocketlineAbnormalClosure = 1006;
const NSInteger TiSocketlineNoStatusReceived = 1005;
static const NSInteger kDefaultCloseCode = 1000;
static const NSUInteger kMaxReasonBytes = 123;

@implementation TiSocketlineEvent

- (instancetype)initWithType:(NSString *)type data:(NSString *)data error:(NSString *)error code:(NSInteger)code reason:(NSString *)reason wasClean:(BOOL)wasClean
{
  if (self = [super init]) {
    _type = [type copy];
    _data = [data copy] ?: @"";
    _error = [error copy];
    _code = code;
    _reason = [reason copy] ?: @"";
    _wasClean = wasClean;
  }
  return self;
}

+ (instancetype)open:(NSString *)protocol
{
  return [[self alloc] initWithType:@"open" data:protocol ?: @"" error:nil code:0 reason:nil wasClean:NO];
}

+ (instancetype)message:(NSString *)text
{
  return [[self alloc] initWithType:@"message" data:text error:nil code:0 reason:nil wasClean:NO];
}

+ (instancetype)error:(NSString *)code description:(NSString *)description
{
  return [[self alloc] initWithType:@"error" data:description ?: @"" error:code code:0 reason:nil wasClean:NO];
}

+ (instancetype)close:(NSInteger)code reason:(NSString *)reason clean:(BOOL)clean
{
  return [[self alloc] initWithType:@"close" data:nil error:nil code:code reason:reason ?: @"" wasClean:clean];
}

@end

@implementation TiSocketlineResult

- (instancetype)initWithAction:(TiSocketlineAction)action events:(NSArray<TiSocketlineEvent *> *)events
{
  if (self = [super init]) {
    _action = action;
    _events = [events copy] ?: @[];
  }
  return self;
}

+ (instancetype)nothing
{
  return [[self alloc] initWithAction:TiSocketlineActionNone events:@[]];
}

@end

@implementation TiSocketlineCore {
  BOOL _started;
  BOOL _opened;
  BOOL _closeRequested;
  BOOL _closeFrameReceived;
  BOOL _closeFired;
  NSInteger _receivedCode;
  NSString *_receivedReason;
  NSInteger _requestedCode;
  NSString *_requestedReason;
}

- (instancetype)init
{
  if (self = [super init]) {
    _state = TiSocketlineStateConnecting;
    _receivedReason = @"";
    _requestedCode = kDefaultCloseCode;
    _requestedReason = @"";
  }
  return self;
}

- (BOOL)canSend
{
  return _state == TiSocketlineStateOpen;
}

- (TiSocketlineResult *)connect
{
  if (_started || _closeFired) {
    return [TiSocketlineResult nothing];
  }
  _started = YES;
  return [[TiSocketlineResult alloc] initWithAction:TiSocketlineActionConnect events:@[]];
}

- (TiSocketlineResult *)openedWithProtocol:(NSString *)protocol
{
  if (_state != TiSocketlineStateConnecting || _closeFired || !_started) {
    return [[TiSocketlineResult alloc] initWithAction:TiSocketlineActionTeardown events:@[]];
  }
  _state = TiSocketlineStateOpen;
  _opened = YES;
  return [[TiSocketlineResult alloc] initWithAction:TiSocketlineActionNone events:@[ [TiSocketlineEvent open:protocol] ]];
}

- (BOOL)receiving
{
  return (_state == TiSocketlineStateOpen || _state == TiSocketlineStateClosing) && !_closeFired;
}

- (TiSocketlineResult *)message:(NSString *)text
{
  if (![self receiving]) {
    return [TiSocketlineResult nothing];
  }
  return [[TiSocketlineResult alloc] initWithAction:TiSocketlineActionNone events:@[ [TiSocketlineEvent message:text] ]];
}

- (TiSocketlineResult *)binaryMessage
{
  if (![self receiving]) {
    return [TiSocketlineResult nothing];
  }
  TiSocketlineEvent *event = [TiSocketlineEvent error:TiSocketlineErrorBinaryFrame description:@"A binary frame was received and dropped: only text frames are supported"];
  return [[TiSocketlineResult alloc] initWithAction:TiSocketlineActionNone events:@[ event ]];
}

- (TiSocketlineResult *)requestCloseWithCode:(NSInteger)code reason:(NSString *)reason
{
  if (_closeFired || _state == TiSocketlineStateClosing || _state == TiSocketlineStateClosed) {
    return [TiSocketlineResult nothing];
  }
  _closeRequested = YES;
  _requestedCode = code;
  _requestedReason = reason ?: @"";
  if (_state == TiSocketlineStateConnecting) {
    return [self finishWithAction:(_started ? TiSocketlineActionTeardown : TiSocketlineActionNone) error:nil description:nil];
  }
  _state = TiSocketlineStateClosing;
  return [[TiSocketlineResult alloc] initWithAction:TiSocketlineActionSendClose events:@[]];
}

- (void)closeFrameReceivedWithCode:(NSInteger)code reason:(NSString *)reason
{
  if (!_opened || _closeFired || _closeFrameReceived || _closeRequested) {
    return;
  }
  _closeFrameReceived = YES;
  _receivedCode = code;
  _receivedReason = reason ?: @"";
  if (_state == TiSocketlineStateOpen) {
    _state = TiSocketlineStateClosing;
  }
}

- (TiSocketlineResult *)connectFailedWithError:(NSString *)error description:(NSString *)description
{
  if (_closeFired) {
    return [TiSocketlineResult nothing];
  }
  if (_state != TiSocketlineStateConnecting) {
    return [self transportClosedWithError:error description:description];
  }
  return [self finishWithAction:TiSocketlineActionTeardown error:(_closeRequested ? nil : error) description:description];
}

- (TiSocketlineResult *)transportClosedWithError:(NSString *)error description:(NSString *)description
{
  if (_closeFired) {
    return [TiSocketlineResult nothing];
  }
  if (!_opened) {
    NSString *code = error ?: TiSocketlineErrorConnectFailed;
    return [self finishWithAction:TiSocketlineActionNone error:(_closeRequested ? nil : code) description:description];
  }
  if (_closeFrameReceived) {
    _closeFired = YES;
    _state = TiSocketlineStateClosed;
    NSInteger code = [TiSocketlineCore normalizeReceivedCode:_receivedCode];
    BOOL clean = code != TiSocketlineAbnormalClosure;
    TiSocketlineEvent *event = [TiSocketlineEvent close:code reason:(clean ? _receivedReason : @"") clean:clean];
    return [[TiSocketlineResult alloc] initWithAction:TiSocketlineActionNone events:@[ event ]];
  }
  if (_closeRequested) {
    // The app's close frame was sent on the open connection.
    _closeFired = YES;
    _state = TiSocketlineStateClosed;
    TiSocketlineEvent *event = [TiSocketlineEvent close:_requestedCode reason:_requestedReason clean:YES];
    return [[TiSocketlineResult alloc] initWithAction:TiSocketlineActionNone events:@[ event ]];
  }
  return [self finishWithAction:TiSocketlineActionNone error:TiSocketlineErrorConnectionLost description:description];
}

- (TiSocketlineResult *)releaseSocket
{
  if (_closeFired) {
    return [TiSocketlineResult nothing];
  }
  _closeFired = YES;
  _state = TiSocketlineStateClosed;
  return [[TiSocketlineResult alloc] initWithAction:(_started ? TiSocketlineActionTeardown : TiSocketlineActionNone) events:@[]];
}

- (TiSocketlineResult *)finishWithAction:(TiSocketlineAction)action error:(NSString *)error description:(NSString *)description
{
  _closeFired = YES;
  _state = TiSocketlineStateClosed;
  NSMutableArray *events = [NSMutableArray arrayWithCapacity:2];
  if (error != nil) {
    [events addObject:[TiSocketlineEvent error:error description:description]];
  }
  [events addObject:[TiSocketlineEvent close:TiSocketlineAbnormalClosure reason:@"" clean:NO]];
  return [[TiSocketlineResult alloc] initWithAction:action events:events];
}

#pragma mark Codes and arguments

+ (NSInteger)normalizeReceivedCode:(NSInteger)code
{
  if (code == TiSocketlineNoStatusReceived || [self isValidWireCode:code]) {
    return code;
  }
  return TiSocketlineAbnormalClosure;
}

+ (BOOL)isValidWireCode:(NSInteger)code
{
  return (code >= 1000 && code <= 1003) || (code >= 1007 && code <= 1014) || (code >= 3000 && code <= 4999);
}

static BOOL IsGiven(id value)
{
  return value != nil && value != [NSNull null];
}

static BOOL IsNumber(id value)
{
  return [value isKindOfClass:[NSNumber class]] && CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID();
}

+ (NSString *)validateCloseCode:(id)code reason:(id)reason
{
  if (IsGiven(code)) {
    if (!IsNumber(code)) {
      return @"Ti.Socketline: close code must be a number";
    }
    double value = [code doubleValue];
    if (value != rint(value) || !(value == 1000 || (value >= 3000 && value <= 4999))) {
      return @"Ti.Socketline: close code must be 1000 or an integer from 3000 to 4999";
    }
  }
  if (IsGiven(reason)) {
    if (![reason isKindOfClass:[NSString class]]) {
      return @"Ti.Socketline: close reason must be a string";
    }
    if ([reason lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > kMaxReasonBytes) {
      return @"Ti.Socketline: close reason must be at most 123 bytes in UTF-8";
    }
  }
  return nil;
}

+ (NSInteger)closeCodeOrDefault:(id)code
{
  return IsGiven(code) ? [code integerValue] : kDefaultCloseCode;
}

static NSString *ValidateTimeout(NSString *name, id value)
{
  if (!IsGiven(value)) {
    return nil;
  }
  if (!IsNumber(value)) {
    return [NSString stringWithFormat:@"%@ must be a number of milliseconds", name];
  }
  double ms = [value doubleValue];
  if (!(ms > 0) || ms > INT_MAX) {
    return [NSString stringWithFormat:@"%@ must be greater than 0", name];
  }
  return nil;
}

+ (NSString *)validateOptionsWithURL:(id)url headers:(id)headers protocols:(id)protocols connectTimeout:(id)connectTimeout
{
  if (![url isKindOfClass:[NSString class]]) {
    return @"url must be a string starting with ws:// or wss://";
  }
  NSURL *parsed = [NSURL URLWithString:url];
  if (parsed == nil) {
    return [NSString stringWithFormat:@"url is not a valid URL: %@", url];
  }
  NSString *scheme = parsed.scheme.lowercaseString ?: @"";
  if (!([scheme isEqualToString:@"ws"] || [scheme isEqualToString:@"wss"])) {
    return @"url must start with ws:// or wss://";
  }
  if (parsed.host.length == 0) {
    return [NSString stringWithFormat:@"url has no host: %@", url];
  }
  if (parsed.fragment != nil) {
    return @"url must not have a fragment";
  }
  NSString *message = ValidateTimeout(@"connectTimeout", connectTimeout);
  if (message == nil) {
    message = [self validateHeaders:headers];
  }
  if (message == nil) {
    message = [self validateProtocols:protocols];
  }
  return message;
}

+ (NSString *)validateHeaders:(id)headers
{
  if (!IsGiven(headers)) {
    return nil;
  }
  if (![headers isKindOfClass:[NSDictionary class]]) {
    return @"headers must be an object of strings";
  }
  for (id key in headers) {
    NSString *name = [key description];
    id value = headers[key];
    if (![self isToken:name]) {
      return [NSString stringWithFormat:@"header name is not valid: %@", name];
    }
    if ([name.lowercaseString hasPrefix:@"sec-websocket-"]) {
      return [NSString stringWithFormat:@"header %@ is set by the module (use the protocols option for subprotocols)", name];
    }
    if (![value isKindOfClass:[NSString class]] && ![value isKindOfClass:[NSNumber class]]) {
      return [NSString stringWithFormat:@"header %@ must be a string", name];
    }
    NSString *text = [self headerValue:value];
    if ([text rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"\r\n"]].location != NSNotFound) {
      return [NSString stringWithFormat:@"header %@ must not contain line breaks", name];
    }
  }
  return nil;
}

+ (NSString *)headerValue:(id)value
{
  if ([value isKindOfClass:[NSString class]]) {
    return value;
  }
  if ([value isKindOfClass:[NSNumber class]] && CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) {
    return [value boolValue] ? @"true" : @"false";
  }
  return [value description];
}

+ (NSArray<NSString *> *)protocolList:(id)protocols
{
  if ([protocols isKindOfClass:[NSString class]]) {
    return @[ protocols ];
  }
  if ([protocols isKindOfClass:[NSArray class]]) {
    return protocols;
  }
  return @[];
}

+ (NSString *)validateProtocols:(id)protocols
{
  if (!IsGiven(protocols)) {
    return nil;
  }
  NSArray *items;
  if ([protocols isKindOfClass:[NSString class]]) {
    items = @[ protocols ];
  } else if ([protocols isKindOfClass:[NSArray class]]) {
    items = protocols;
  } else {
    return @"protocols must be a string or an array of strings";
  }
  NSMutableSet *seen = [NSMutableSet set];
  for (id item in items) {
    if (![item isKindOfClass:[NSString class]] || ![self isToken:item]) {
      return [NSString stringWithFormat:@"protocol is not a valid token: %@", item];
    }
    if ([seen containsObject:item]) {
      return [NSString stringWithFormat:@"protocol listed twice: %@", item];
    }
    [seen addObject:item];
  }
  return nil;
}

+ (BOOL)cleartextPermittedForHost:(NSString *)host transportSecurity:(NSDictionary *)ats
{
  NSString *name = host.lowercaseString ?: @"";
  if ([ats isKindOfClass:[NSDictionary class]]) {
    // A matching exception domain decides; the most specific one wins.
    NSDictionary *domains = [ats[@"NSExceptionDomains"] isKindOfClass:[NSDictionary class]] ? ats[@"NSExceptionDomains"] : nil;
    NSString *bestDomain = nil;
    NSDictionary *best = nil;
    for (id key in domains) {
      NSString *domain = [[key description] lowercaseString];
      NSDictionary *exception = [domains[key] isKindOfClass:[NSDictionary class]] ? domains[key] : @{};
      BOOL matches = [name isEqualToString:domain]
          || ([exception[@"NSIncludesSubdomains"] boolValue] && [name hasSuffix:[@"." stringByAppendingString:domain]]);
      if (matches && domain.length > bestDomain.length) {
        bestDomain = domain;
        best = exception;
      }
    }
    if (best != nil) {
      return [best[@"NSExceptionAllowsInsecureHTTPLoads"] boolValue] || [best[@"NSTemporaryExceptionAllowsInsecureHTTPLoads"] boolValue];
    }
  }
  NSDictionary *settings = [ats isKindOfClass:[NSDictionary class]] ? ats : @{};
  if ([settings[@"NSAllowsLocalNetworking"] boolValue] && [self isLocalHost:name]) {
    return YES;
  }
  // As in ATS, NSAllowsArbitraryLoads is ignored when one of the more specific keys is present.
  BOOL specific = settings[@"NSAllowsLocalNetworking"] != nil || settings[@"NSAllowsArbitraryLoadsInWebContent"] != nil
      || settings[@"NSAllowsArbitraryLoadsForMedia"] != nil;
  return [settings[@"NSAllowsArbitraryLoads"] boolValue] && !specific;
}

+ (BOOL)isLocalHost:(NSString *)host
{
  if ([host isEqualToString:@"localhost"] || [host hasSuffix:@".local"] || [host rangeOfString:@"."].location == NSNotFound) {
    return YES; // unqualified names (also IPv6 literals, which have no dots) and .local
  }
  NSCharacterSet *notIPv4 = [[NSCharacterSet characterSetWithCharactersInString:@"0123456789."] invertedSet];
  return [host rangeOfCharacterFromSet:notIPv4].location == NSNotFound;
}

+ (BOOL)isToken:(NSString *)value
{
  if (value.length == 0) {
    return NO;
  }
  static NSCharacterSet *allowed;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    allowed = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!#$%&'*+-.^_`|~"];
  });
  return [value rangeOfCharacterFromSet:allowed.invertedSet].location == NSNotFound;
}

@end
