//  CountlyContentConfig.h
//
// This code is provided under the MIT License.
//
// Please visit www.count.ly for more information.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#if (TARGET_OS_IOS)
typedef enum : NSUInteger
{
    COMPLETED,
    CLOSED,
} ContentStatus;

typedef enum: NSUInteger
{
    IMMERSIVE,
    SAFE_AREA
} WebViewDisplayOption;

typedef void (^ContentCallback)(ContentStatus contentStatus, NSDictionary<NSString *, id>* contentData);
#endif

@interface CountlyContentConfig : NSObject

#if (TARGET_OS_IOS)
/**
 * This is an experimental feature and it can have breaking changes
 * Register global completion blocks to be executed on content.
 */
- (void)setGlobalContentCallback:(ContentCallback) callback;

/**
 * This is an experimental feature and it can have breaking changes
 * Get content callback
 */
- (ContentCallback) getGlobalContentCallback;

/**
 * This is an experimental feature and it can have breaking changes
 * Set the interval for the automatic content update calls
 * @param zoneTimerIntervalSeconds in seconds
 *
 */
-(void)setZoneTimerInterval:(NSUInteger)zoneTimerIntervalSeconds;

/**
 * This is an experimental feature and it can have breaking changes
 * Get zone timer interval
 */
- (NSUInteger) getZoneTimerInterval;

/**
 * To control how content and feedback widgets displayed. Default is IMMERSIVE (full screen contents)
 */
- (void) setWebviewDisplayOption:(WebViewDisplayOption) webViewDisplayOption;

- (WebViewDisplayOption)getWebViewDisplayOption;

/**
 * This is an experimental feature and it can have breaking changes.
 * Enables reloading the content web view when a load stalls (does not appear within ~1
 * second) instead of closing it. A reload reuses the already-warm connection and cached
 * assets, which recovers loads that fail because a server/edge drops the initial burst of
 * parallel resource connections. This is a one-way switch: once enabled it stays enabled.
 * Disabled by default.
 */
- (void)enableContentReloadOnStall;
- (BOOL)getEnableContentReloadOnStall;

/**
 * This is an experimental feature and it can have breaking changes.
 * Sets how long a content load may stall (not appear) before the SDK reloads it, in
 * milliseconds. Only used when reload-on-stall is enabled (see enableContentReloadOnStall).
 * Default is 1000 (1 second). Can be changed at any time before starting the SDK.
 */
- (void)setContentReloadOnStallTimeout:(NSUInteger)milliseconds;
- (NSUInteger)getContentReloadOnStallTimeout;
#endif

NS_ASSUME_NONNULL_END

@end
