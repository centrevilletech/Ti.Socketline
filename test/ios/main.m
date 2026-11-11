/**
 * Ti.Socketline — runs test/vectors.json against TiSocketlineCore (the iOS state machine and validation).
 * Copyright (c) 2026 Centreville Tech LLC. Licensed under the Apache License, Version 2.0.
 */
#import "TiSocketlineCore.h"

static int passed, failed;

static void Fail(NSString *name, NSString *why)
{
  failed++;
  printf("FAIL %s: %s\n", name.UTF8String, why.UTF8String);
}

static id Value(NSDictionary *c, NSString *key)
{
  id v = c[key];
  return v == [NSNull null] ? nil : v;
}

static NSString *Describe(TiSocketlineEvent *e)
{
  if ([e.type isEqualToString:@"open"]) {
    return [@"open:" stringByAppendingString:e.data];
  }
  if ([e.type isEqualToString:@"message"]) {
    return [@"message:" stringByAppendingString:e.data];
  }
  if ([e.type isEqualToString:@"error"]) {
    return [@"error:" stringByAppendingString:e.error];
  }
  return [NSString stringWithFormat:@"close:%ld:%@:%@", (long)e.code, e.reason, e.wasClean ? @"true" : @"false"];
}

static BOOL Expect(NSString *name, NSString *what, NSArray *expected, NSArray *actual)
{
  if ([expected isEqualToArray:actual]) {
    return YES;
  }
  Fail(name, [NSString stringWithFormat:@"%@: expected %@, got %@", what, [expected componentsJoinedByString:@","], [actual componentsJoinedByString:@","]]);
  return NO;
}

int main(int argc, const char *argv[])
{
  @autoreleasepool {
    NSData *data = [NSData dataWithContentsOfFile:[NSString stringWithUTF8String:argv[1]]];
    NSDictionary *v = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];

    for (NSDictionary *c in v[@"closeArguments"]) {
      NSString *message = [TiSocketlineCore validateCloseCode:Value(c, @"code") reason:Value(c, @"reason")];
      BOOL valid = [c[@"valid"] boolValue];
      if ((valid && message == nil) || (!valid && message != nil && (c[@"error"] == nil || [c[@"error"] isEqualToString:message]))) {
        passed++;
      } else {
        Fail([@"closeArguments: " stringByAppendingString:c[@"name"]], [NSString stringWithFormat:@"expected %@, got %@", valid ? @"valid" : c[@"error"], message ?: @"valid"]);
      }
    }

    for (NSDictionary *c in v[@"options"]) {
      NSString *message = [TiSocketlineCore validateOptionsWithURL:Value(c, @"url") headers:Value(c, @"headers") protocols:Value(c, @"protocols") connectTimeout:Value(c, @"connectTimeout")];
      BOOL valid = [c[@"valid"] boolValue];
      if (valid == (message == nil)) {
        passed++;
      } else {
        Fail([@"options: " stringByAppendingString:c[@"name"]], [NSString stringWithFormat:@"expected %@, got %@", valid ? @"valid" : @"invalid", message ?: @"valid"]);
      }
    }

    for (NSArray *pair in v[@"normalizeReceivedCode"]) {
      NSInteger actual = [TiSocketlineCore normalizeReceivedCode:[pair[0] integerValue]];
      if (actual == [pair[1] integerValue]) {
        passed++;
      } else {
        Fail([NSString stringWithFormat:@"normalizeReceivedCode %@", pair[0]], [NSString stringWithFormat:@"expected %@, got %ld", pair[1], (long)actual]);
      }
    }

    for (NSDictionary *c in v[@"atsCleartext"]) {
      BOOL permitted = [TiSocketlineCore cleartextPermittedForHost:c[@"host"] transportSecurity:Value(c, @"ats")];
      if (permitted == [c[@"permitted"] boolValue]) {
        passed++;
      } else {
        Fail([@"atsCleartext: " stringByAppendingString:c[@"name"]], [NSString stringWithFormat:@"expected %@, got %@", c[@"permitted"], permitted ? @"YES" : @"NO"]);
      }
    }

    NSArray *actionNames = @[ @"NONE", @"CONNECT", @"SEND_CLOSE", @"TEARDOWN" ];
    for (NSDictionary *c in v[@"sequences"]) {
      NSString *name = [@"sequence: " stringByAppendingString:c[@"name"]];
      TiSocketlineCore *core = [[TiSocketlineCore alloc] init];
      NSMutableArray *actions = [NSMutableArray array];
      NSMutableArray *events = [NSMutableArray array];
      BOOL ok = YES;
      for (NSArray *step in c[@"steps"]) {
        NSString *op = step[0];
        TiSocketlineResult *r = nil;
        if ([op isEqualToString:@"connect"]) {
          r = [core connect];
        } else if ([op isEqualToString:@"opened"]) {
          r = [core openedWithProtocol:step[1]];
        } else if ([op isEqualToString:@"message"]) {
          r = [core message:step[1]];
        } else if ([op isEqualToString:@"binary"]) {
          r = [core binaryMessage];
        } else if ([op isEqualToString:@"requestClose"]) {
          r = [core requestCloseWithCode:[step[1] integerValue] reason:step[2]];
        } else if ([op isEqualToString:@"closeFrame"]) {
          [core closeFrameReceivedWithCode:[step[1] integerValue] reason:step[2]];
        } else if ([op isEqualToString:@"connectFailed"]) {
          r = [core connectFailedWithError:step[1] description:@"test"];
        } else if ([op isEqualToString:@"transportClosed"]) {
          r = [core transportClosedWithError:(step[1] == [NSNull null] ? nil : step[1]) description:@"test"];
        } else if ([op isEqualToString:@"release"]) {
          r = [core releaseSocket];
        } else if ([op isEqualToString:@"canSend"]) {
          if (core.canSend != [step[1] boolValue]) {
            Fail(name, @"canSend differs");
            ok = NO;
          }
        } else {
          Fail(name, [@"unknown step " stringByAppendingString:op]);
          ok = NO;
        }
        if (r != nil) {
          if (r.action != TiSocketlineActionNone) {
            [actions addObject:actionNames[r.action]];
          }
          for (TiSocketlineEvent *e in r.events) {
            [events addObject:Describe(e)];
          }
        }
      }
      ok &= Expect(name, @"actions", c[@"actions"], actions);
      ok &= Expect(name, @"events", c[@"events"], events);
      ok &= Expect(name, @"state", @[ c[@"state"] ], @[ @(core.state) ]);
      if (ok) {
        passed++;
      }
    }
    printf("ios: %d passed, %d failed\n", passed, failed);
    return failed == 0 ? 0 : 1;
  }
}
