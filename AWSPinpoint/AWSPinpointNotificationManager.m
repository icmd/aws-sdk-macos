/*
 Copyright 2010-2017 Amazon.com, Inc. or its affiliates. All Rights Reserved.
 
 Licensed under the Apache License, Version 2.0 (the "License").
 You may not use this file except in compliance with the License.
 A copy of the License is located at
 
 http://aws.amazon.com/apache2.0
 
 or in the "license" file accompanying this file. This file is distributed
 on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either
 express or implied. See the License for the specific language governing
 permissions and limitations under the License.
 */

#import <Foundation/Foundation.h>

#import "AWSPinpointNotificationManager.h"
#import "AWSPinpointTargetingClient.h"
#import "AWSPinpointAnalyticsClient.h"
#import "AWSPinpointService.h"
#import "AWSPinpointEvent.h"
#import "AWSPinpointContext.h"

static NSString *const AWSCampaignDeepLinkKey = @"deeplink";
static NSString *const AWSAttributeApplicationStateKey = @"applicationState";
static NSString *const AWSAttributeActionIdentifierKey = @"actionIdentifier";
static NSString *const AWSEventTypeOpened = @"_campaign.opened_notification";
static NSString *const AWSEventTypeReceivedForeground = @"_campaign.received_foreground";
static NSString *const AWSEventTypeReceivedBackground = @"_campaign.received_background";
NSString *const AWSDeviceTokenKey = @"com.amazonaws.AWSDeviceTokenKey";
NSString *const AWSDataKey = @"data";
NSString *const AWSPinpointKey = @"pinpoint";
NSString *const AWSPinpointCampaignKey = @"campaign";

@interface AWSPinpointNotificationManager()
@property (nonatomic, strong) AWSPinpointContext *context;
@end

@interface AWSPinpointAnalyticsClient()
- (void) setCampaignAttributes:(NSDictionary*) campaign;
@end

@implementation AWSPinpointNotificationManager

- (instancetype)init {
    @throw [NSException exceptionWithName:NSInternalInconsistencyException
                                   reason:@"You must not initialize this class directly. Access the AWSPinpointNotificationManager from AWSPinpoint."
                                 userInfo:nil];
}

- (instancetype) initWithContext:(AWSPinpointContext*) context {
    if (self = [super init]) {
        _context = context;
    }
    return self;
}

+ (BOOL)isNotificationEnabled {
    BOOL optOut = ![[UIApplication sharedApplication] isRegisteredForRemoteNotifications];
    if ([[UIApplication sharedApplication] currentUserNotificationSettings].types == UIUserNotificationTypeNone) {
        optOut = YES;
    }
    return !optOut;
}

+ (BOOL)validCampaignPushForNotification:(NSDictionary*) notification {
    if (![notification[AWSDataKey] isKindOfClass:[NSDictionary class]] || ![notification[AWSDataKey][AWSPinpointKey] isKindOfClass:[NSDictionary class]]) {
        return NO;
    } else {
        return YES;
    }
}

#pragma mark - User action methods
- (BOOL)interceptDidFinishLaunchingWithOptions:(nullable NSDictionary *)launchOptions {
    NSDictionary *notificationPayload = launchOptions[UIApplicationLaunchOptionsRemoteNotificationKey];
    if(notificationPayload)
    {
        if (![AWSPinpointNotificationManager validCampaignPushForNotification:notificationPayload]) {
            return YES;
        }
        
        [self addGlobalCampaignMetadataForNotification:notificationPayload];
        
        // Application launch because of notification
        [self recordMessageOpenedEventForNotification:notificationPayload
                                       withIdentifier:nil
                                 withApplicationState:[[UIApplication sharedApplication] applicationState]];
    }
    
    return YES;
}

- (void)interceptDidRegisterForRemoteNotificationsWithDeviceToken:(NSData *)deviceToken {
    NSUserDefaults *userDefaults = [NSUserDefaults standardUserDefaults];
    //Check if device token has changed
    NSData *currentToken = [userDefaults objectForKey:AWSDeviceTokenKey];
    if (![currentToken isEqualToData:deviceToken]) {
        [userDefaults setObject:deviceToken forKey:AWSDeviceTokenKey];
        [userDefaults synchronize];
        //Update endpoint
        AWSLogInfo(@"Calling endpoint Service to register token");
        
        [self.context.targetingClient updateEndpointProfile];
    }
}

- (void)interceptDidReceiveRemoteNotification:(NSDictionary *)userInfo
                       fetchCompletionHandler:(void (^)(UIBackgroundFetchResult result))handler {
    [self handleNotificationReceived:[UIApplication sharedApplication] withNotification:userInfo];
    //We must rely on the user calling the completion handler because if we call it ourselves as well as the user it would cause a crash due to calling it twice.
}

#pragma mark - Handlers
- (void)handleNotificationDeepLinkForNotification:(NSDictionary*) userInfo {
    if (![AWSPinpointNotificationManager validCampaignPushForNotification:userInfo]) {
        return;
    }
    NSDictionary *amaDict = userInfo[AWSDataKey][AWSPinpointKey];
    if ([amaDict[AWSCampaignDeepLinkKey] isKindOfClass:[NSString class]]) {
        AWSLogVerbose(@"Received Deep Link: %@", amaDict[AWSCampaignDeepLinkKey]);
        NSURL *deepLinkURL = [NSURL URLWithString:amaDict[AWSCampaignDeepLinkKey]];
        if ([[UIApplication sharedApplication] canOpenURL:deepLinkURL]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [[UIApplication sharedApplication] openURL:deepLinkURL];
            });
        }
    }
}

- (void)handleNotificationReceived:(UIApplication *) app
                  withNotification:(NSDictionary *) userInfo {
    UIApplicationState state = [app applicationState];
    
    if (state == UIApplicationStateInactive) {
        AWSLogVerbose(@"App launched from received notification.");
        [self addGlobalCampaignMetadataForNotification:userInfo];
        [self recordMessageOpenedEventForNotification:userInfo
                                       withIdentifier:nil
                                 withApplicationState:state];
        [self handleNotificationDeepLinkForNotification:userInfo];
    } else if (state == UIApplicationStateBackground) {
        AWSLogVerbose(@"Received notification with app on background.");
        [self addGlobalCampaignMetadataForNotification:userInfo];
        [self recordMessageReceivedEventForNotification:userInfo
                                              eventType:AWSEventTypeReceivedBackground
                                   withApplicationState:state];
    } else {
        AWSLogVerbose(@"Received notification with app on foreground.");
        [self recordMessageReceivedEventForNotification:userInfo
                                              eventType:AWSEventTypeReceivedForeground
                                   withApplicationState:state];
    }
}

#pragma mark - Event recorders
- (void)recordMessageReceivedEventForNotification:(NSDictionary *) userInfo
                                        eventType:(NSString*) eventType
                             withApplicationState:(UIApplicationState) state {
    //Silent notification
    AWSPinpointEvent *pushNotificationEvent = [self.context.analyticsClient createEventWithEventType:eventType];
    
    [self addApplicationStateAttributeToEvent:pushNotificationEvent
                         withApplicationState:state];
    [self addCampaignMetadataForEvent:pushNotificationEvent
                     withNotification:userInfo];
    
    [self.context.analyticsClient recordEvent:pushNotificationEvent];
}

- (void)recordMessageOpenedEventForNotification:(NSDictionary *) userInfo
                                 withIdentifier:(NSString *) identifier
                           withApplicationState:(UIApplicationState) state {
    //User tapped on notification
    AWSPinpointEvent *pushNotificationEvent = [self.context.analyticsClient createEventWithEventType:AWSEventTypeOpened];
    
    if (identifier) {
        [pushNotificationEvent addAttribute:identifier forKey:AWSAttributeActionIdentifierKey];
    }
    
    [self addApplicationStateAttributeToEvent:pushNotificationEvent
                         withApplicationState:state];
    [self.context.analyticsClient recordEvent:pushNotificationEvent];
}

#pragma mark - Helpers
- (void)addCampaignMetadataForEvent:(AWSPinpointEvent *) event
                   withNotification:(NSDictionary *) userInfo {
    if (![AWSPinpointNotificationManager validCampaignPushForNotification:userInfo]) {
        return;
    }
    NSDictionary *campaign = userInfo[AWSDataKey][AWSPinpointKey][AWSPinpointCampaignKey];
    AWSLogVerbose(@"Adding campaign attributes to event[%@]: %@",event.eventType, campaign);
    
    for (NSString *key in [campaign allKeys]) {
        [event addAttribute:campaign[key] forKey:key];
    }
}

- (void)addGlobalCampaignMetadataForNotification:(NSDictionary *) userInfo {
    if (![AWSPinpointNotificationManager validCampaignPushForNotification:userInfo]) {
        return;
    }
    
    NSDictionary *campaign = userInfo[AWSDataKey][AWSPinpointKey][AWSPinpointCampaignKey];
    AWSLogVerbose(@"Adding campaign global attributes: %@", campaign);
    [self.context.analyticsClient setCampaignAttributes:campaign];
    
    for (NSString *key in [campaign allKeys]) {
        [self.context.analyticsClient addGlobalAttribute:campaign[key] forKey:key];
    }
}

- (void)addApplicationStateAttributeToEvent:(AWSPinpointEvent *) event
                       withApplicationState:(UIApplicationState) state {
    switch (state) {
        case UIApplicationStateActive:
        {
            [event addAttribute:@"UIApplicationStateActive" forKey:AWSAttributeApplicationStateKey];
        }
            break;
        case UIApplicationStateInactive:
        {
            [event addAttribute:@"UIApplicationStateInactive" forKey:AWSAttributeApplicationStateKey];
        }
            break;
        case UIApplicationStateBackground:
        {
            [event addAttribute:@"UIApplicationStateBackground" forKey:AWSAttributeApplicationStateKey];
        }
            break;
        default:
            break;
    }
}

@end
