/**
 * Ti.Socketline — native WebSocket client for Titanium.
 * Copyright (c) 2026 Centreville Tech LLC. Licensed under the Apache License, Version 2.0.
 */
#import "TiSocketlineModule.h"
#import "TiBase.h"
#import "TiUtils.h"

@implementation TiSocketlineModule

#pragma mark Internal

- (id)moduleGUID
{
  return @"c08cd554-273c-47f5-8dad-ac1591915c01";
}

- (NSString *)moduleId
{
  return @"ti.socketline";
}

#pragma mark Constants

MAKE_SYSTEM_PROP(CONNECTING, 0);
MAKE_SYSTEM_PROP(OPEN, 1);
MAKE_SYSTEM_PROP(CLOSING, 2);
MAKE_SYSTEM_PROP(CLOSED, 3);

@end
