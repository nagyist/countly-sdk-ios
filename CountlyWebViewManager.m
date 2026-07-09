// CountlyWebViewManager.m
//
// This code is provided under the MIT License.
//
// Please visit www.count.ly for more information.
#import "CountlyWebViewManager.h"
#import "CountlyCommon.h"
#import "CountlyOverlayWindow.h"
#import "CountlyWebViewController.h"
#import "PassThroughBackgroundView.h"
#import "CountlyContentBuilderInternal.h"

#if (TARGET_OS_IOS)
// Critical-resource load retries: how many times to reload the web view before
// giving up when a critical (JS/CSS) resource fails to load. A single transient
// network hiccup — e.g. a connection stalled under a burst of parallel asset
// requests against an HTTP/1.1 / rate-limited edge — should not tear down otherwise
// valid content. On reload, already-loaded resources are served from the in-session
// cache, so the retry re-fetches only what failed. Mirrors the more tolerant Android
// behavior (which never closes on a transient JS error event).
static const NSInteger kCLYMaxResourceRetries = 2;
static const NSTimeInterval kCLYResourceRetryBaseDelay = 0.6;
// Fallback stall timeout (seconds) used only when reload-on-stall is enabled but no
// timeout was configured (e.g. the SDK was not started via config in a unit test). The
// real value comes from CountlyContentConfig setContentReloadOnStallTimeout: (default
// 1000 ms). Kept short because a manual reload is observed to recover reliably: on reload
// the already-fetched assets come from cache and the rest reuse the warm connection, so
// the parallel-connection burst shrinks below the edge's limit. A stalled load fires no
// JS 'error' event, so this timer is what triggers the reload for that case. When the
// flag is off, the 60s safety-net timeout is used and the view closes on failure.
static const NSTimeInterval kCLYLoadStallTimeout = 1.0;
static const NSTimeInterval kCLYDefaultLoadTimeout = 60.0;

// TODO: improve logging, check edge cases
@interface CountlyWebViewManager ()

@property(nonatomic, strong) PassThroughBackgroundView *backgroundView;
@property(nonatomic, copy) void (^dismissBlock)(void);
@property(nonatomic, copy) void (^appearBlock)(void);
@property(nonatomic, strong) NSTimer *loadTimeoutTimer;
@property(nonatomic, strong) NSDate *loadStartDate;
@property(nonatomic) BOOL hasAppeared;
@property(nonatomic) BOOL webViewClosed;
@property(nonatomic) NSInteger resourceRetryCount;
@property(nonatomic) BOOL retryInProgress;
@property(nonatomic) NSTimeInterval loadTimeoutInterval;
@property(nonatomic, copy) dispatch_block_t pendingReloadBlock;
@property(nonatomic, strong) CountlyWebViewController *presentingController;
@property(nonatomic, strong) CountlyOverlayWindow *window;
@end

@implementation CountlyWebViewManager
  #if (TARGET_OS_IOS)
- (void)createWebViewWithURL:(NSURL *)url
                       frame:(CGRect)frame
                 appearBlock:(void(^ __nullable)(void))appearBlock
                dismissBlock:(void(^ __nullable)(void))dismissBlock {
    self.dismissBlock = dismissBlock;
    self.appearBlock = appearBlock;
    self.hasAppeared = NO;
    self.webViewClosed = NO;
    self.resourceRetryCount = 0;
    self.retryInProgress = NO;
    // TODO: keyWindow deprecation fix
    _window = [CountlyOverlayWindow new];
    CountlyWebViewController *modal = [CountlyWebViewController new];
    modal.modalPresentationStyle = UIModalPresentationOverFullScreen;
    modal.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
    _window.rootViewController = modal;
    UIViewController *rootViewController = UIApplication.sharedApplication.keyWindow.rootViewController;
    modal.modalPresentationCapturesStatusBarAppearance = YES;
    CGRect backgroundFrame = rootViewController.view.bounds;
    self.backgroundView = [[PassThroughBackgroundView alloc] initWithFrame:backgroundFrame];
    self.backgroundView.backgroundColor = [UIColor clearColor];
    self.backgroundView.hidden = YES;
    modal.contentView = self.backgroundView;

    _window.hidden = NO;
    self.presentingController = modal;
    
    NSString *jsString = @"(function(){"
     // 1) Catch network-level failures (connection refused, DNS, etc.) for SCRIPT/LINK
     "window.addEventListener('error',function(e){"
     "if(!e.target)return;"
     "var url=e.target.src||e.target.href;"
     "if(!url)return;"
     "if(url.includes('favicon.ico'))return;"
     "if(e.target.tagName&&(e.target.tagName==='SCRIPT'||e.target.tagName==='LINK')){"
     "window.webkit.messageHandlers.resourceLoadError.postMessage({"
     "tag:e.target.tagName,"
     "url:url"
     "});}"
     "},true);"
     // 2) Catch HTTP errors (4xx/5xx) on CSS/JS via PerformanceObserver
     "if(window.PerformanceObserver){"
     "var obs=new PerformanceObserver(function(list){"
     "list.getEntries().forEach(function(entry){"
     "if(entry.responseStatus&&entry.responseStatus>=400){"
     "var tag='';"
     "if(entry.initiatorType==='link')tag='LINK';"
     "else if(entry.initiatorType==='script')tag='SCRIPT';"
     "if(tag){"
     "window.webkit.messageHandlers.resourceLoadError.postMessage({"
     "tag:tag,"
     "url:entry.name"
     "});}}"
     "});"
     "});"
     "obs.observe({type:'resource',buffered:true});"
     "}"
     "})();";
       WKUserContentController *contentController = [[WKUserContentController alloc] init];

       WKUserScript *resourceErrorScript =
       [[WKUserScript alloc] initWithSource:jsString
                              injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                           forMainFrameOnly:NO];

       [contentController addUserScript:resourceErrorScript];
       [contentController addScriptMessageHandler:self name:@"resourceLoadError"];
       [contentController addScriptMessageHandler:self name:@"resourceVerifyResult"];

    WKWebViewConfiguration *configuration = [[WKWebViewConfiguration alloc] init];
    configuration.websiteDataStore = [WKWebsiteDataStore nonPersistentDataStore];
    configuration.userContentController = contentController;

    WKWebView *webView = [[WKWebView alloc] initWithFrame:frame configuration:configuration];
    if (@available(iOS 11.0, *)) {
        webView.scrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    }
    // When SDK debug is enabled, expose the content web view to Safari Web Inspector
    // (iOS 16.4+ requires this to be set explicitly). Lets you inspect the Network and
    // Console tabs of the content web view live from a Mac. Off in production.
    if (@available(iOS 16.4, *)) {
        webView.inspectable = CountlyCommon.sharedInstance.enableDebug;
    }
    [self configureWebView:webView];

    NSURLRequest *request = [NSURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:60];
    [webView loadRequest:request];

    CLYButton *dismissButton = [CLYButton dismissAlertButton:@"X"];
    [self configureDismissButton:dismissButton forWebView:webView];

    self.backgroundView.webView = webView;
    self.backgroundView.dismissButton = dismissButton;
}

- (void)configureWebView:(WKWebView *)webView {
    webView.layer.shadowColor = UIColor.blackColor.CGColor;
    webView.layer.shadowOpacity = 0.5;
    webView.layer.shadowOffset = CGSizeMake(0.0f, 5.0f);
    webView.layer.masksToBounds = NO;
    webView.opaque = NO;
    webView.scrollView.bounces = NO;
    webView.navigationDelegate = self;

    [self.backgroundView addSubview:webView];
}

- (void)configureDismissButton:(CLYButton *)dismissButton forWebView:(WKWebView *)webView {
    dismissButton.onClick = ^(id sender) {
        if (self.dismissBlock) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.loadTimeoutTimer invalidate];
                self.loadTimeoutTimer = nil;
                self.loadStartDate = nil;
                self.dismissBlock();
                [self closeWebView];
            });
        }
    };

    [self.backgroundView addSubview:dismissButton];
    [dismissButton positionToTopRight];
    [self.backgroundView bringSubviewToFront:webView];
    [webView bringSubviewToFront:dismissButton];

    self.backgroundView.dismissButton = dismissButton;
    dismissButton.hidden = YES;
}

- (void)webView:(WKWebView *)webView decidePolicyForNavigationAction:(WKNavigationAction *)navigationAction decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
    NSString *url = navigationAction.request.URL.absoluteString;

    if (!url) {
        CLY_LOG_I(@"%s Navigation action with nil URL (possible proxy tunnel), allowing", __FUNCTION__);
        decisionHandler(WKNavigationActionPolicyAllow);
        return;
    }

    if ([url containsString:@"cly_x_int=1"]) {
        CLY_LOG_I(@"%s Opening url [%@] in external browser", __FUNCTION__, url);
        [[UIApplication sharedApplication] openURL:navigationAction.request.URL options:@{} completionHandler:^(BOOL success) {
            if (success) {
                CLY_LOG_I(@"%s url [%@] opened in external browser", __FUNCTION__, url);
            }
            else {
                CLY_LOG_I(@"%s unable to open url [%@] in external browser", __FUNCTION__, url);
            }
        }];
        decisionHandler(WKNavigationActionPolicyCancel);
        return;
    }

    if ([url hasPrefix:@"https://countly_action_event"]) {
        NSDictionary *queryParameters = [self parseQueryString:url];

        if([url containsString:@"cly_x_action_event=1"]){
            [self contentURLAction:queryParameters];
        } else if([url containsString:@"cly_widget_command=1"]){
            [self widgetURLAction:queryParameters];
        }

        if ([queryParameters[@"close"] boolValue]) {
            [self closeWebView];
        }

        decisionHandler(WKNavigationActionPolicyCancel);
    } else {
        decisionHandler(WKNavigationActionPolicyAllow);
    }
}

- (void)webView:(WKWebView *)webView decidePolicyForNavigationResponse:(WKNavigationResponse *)navigationResponse decisionHandler:(void (^)(WKNavigationResponsePolicy))decisionHandler {
    NSURLResponse *response = navigationResponse.response;
    NSString *mimeType = response.MIMEType ?: @"(unknown)";
    long statusCode = 0;
    NSDictionary *headers = nil;
    if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
        statusCode = http.statusCode;
        headers = http.allHeaderFields;
    }

    CLY_LOG_I(@"%s Navigation response received: URL=%@, MIME=%@, status=%ld, headers=%@", __FUNCTION__, response.URL.absoluteString, mimeType, statusCode, headers);

    if (statusCode >= 400) {
        CLY_LOG_I(@"%s Cancelling navigation due to HTTP status code: %ld", __FUNCTION__, statusCode);
        decisionHandler(WKNavigationResponsePolicyCancel);
        dispatch_async(dispatch_get_main_queue(), ^{
            [self closeWebView];
        });
        return;
    }

    decisionHandler(WKNavigationResponsePolicyAllow);
}

- (void)webView:(WKWebView *)webView didReceiveServerRedirectForProvisionalNavigation:(WKNavigation *)navigation {
    CLY_LOG_I(@"%s Server redirect received for navigation: %@", __FUNCTION__, navigation);
}

- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    [self.loadTimeoutTimer invalidate];
    self.loadTimeoutTimer = nil;
    CLY_LOG_I(@"%s Provisional navigation failed: %@ (%ld). Closing web view.", __FUNCTION__, error.localizedDescription, (long)error.code);
    [self closeWebView];
}

- (void)webView:(WKWebView *)webView didCommitNavigation:(WKNavigation *)navigation {
    CLY_LOG_I(@"%s Content started arriving (didCommitNavigation).", __FUNCTION__);
}

- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    [self.loadTimeoutTimer invalidate];
    self.loadTimeoutTimer = nil;
    CLY_LOG_I(@"%s Navigation failed after commit: %@ (%ld). Closing web view.", __FUNCTION__, error.localizedDescription, (long)error.code);
    [self closeWebView];
}

- (void)webView:(WKWebView *)webView didReceiveAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition disposition, NSURLCredential *credential))completionHandler {
    CLY_LOG_I(@"%s Received authentication challenge for host: %@, protectionSpace: %@", __FUNCTION__, challenge.protectionSpace.host, challenge.protectionSpace.authenticationMethod);
    // sth custom if needed later?
    completionHandler(NSURLSessionAuthChallengePerformDefaultHandling, nil);
}

- (void)webViewWebContentProcessDidTerminate:(WKWebView *)webView {
    CLY_LOG_I(@"%s Web content process terminated for URL: %@.", __FUNCTION__, webView.URL.absoluteString);
    // reload?
}

- (void)webView:(WKWebView *)webView didStartProvisionalNavigation:(WKNavigation *)navigation {
    CLY_LOG_I(@"%s Web view has started loading", __FUNCTION__);
    [self.loadTimeoutTimer invalidate];
    __weak typeof(self) weakSelf = self;
    // Fast stall-detect (reload) when enabled, using the configurable stall timeout;
    // otherwise a plain 60s safety-net close.
    NSTimeInterval stall = CountlyContentBuilderInternal.sharedInstance.contentReloadOnStallTimeout;
    if (stall <= 0) stall = kCLYLoadStallTimeout; // fallback default (e.g. SDK not started via config)
    NSTimeInterval timeout = CountlyContentBuilderInternal.sharedInstance.enableContentReloadOnStall ? stall : kCLYDefaultLoadTimeout;
    self.loadTimeoutInterval = timeout;
    self.loadTimeoutTimer = [NSTimer scheduledTimerWithTimeInterval:timeout repeats:NO block:^(NSTimer * _Nonnull timer) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf loadDidTimeout];
    }];
    self.loadStartDate = [NSDate date];
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    // Don't invalidate the timeout timer here — keep it running until
    // the view actually appears or resource verification completes.
    // This ensures a 60s safety net even if fetch() calls hang.

    if (self.webViewClosed) return;

    CLY_LOG_I(@"%s Web view has finished loading", __FUNCTION__);
    if (self.loadStartDate) {
        NSTimeInterval loadDuration = [[NSDate date] timeIntervalSinceDate:self.loadStartDate];
        CLY_LOG_I(@"%s Web view load duration: %.3f seconds", __FUNCTION__, loadDuration);
        self.loadStartDate = nil;
    }

    [self verifyResourceStatuses:webView];
}

// After page load, fetch each CSS/JS URL with HEAD to verify HTTP status.
// Results are sent back via postMessage since evaluateJavaScript can't handle Promises.
- (void)verifyResourceStatuses:(WKWebView *)webView {
    if (self.webViewClosed) return;

    NSString *js =
        @"(function(){"
         "var urls=[];"
         "document.querySelectorAll('link[rel=\"stylesheet\"]').forEach(function(l){if(l.href)urls.push({tag:'LINK',url:l.href});});"
         "document.querySelectorAll('script[src]').forEach(function(s){urls.push({tag:'SCRIPT',url:s.src});});"
         "if(urls.length===0){"
         "window.webkit.messageHandlers.resourceVerifyResult.postMessage({results:[]});"
         "return;"
         "}"
         "Promise.all(urls.map(function(r){"
         "return fetch(r.url,{method:'HEAD'}).then(function(resp){"
         "return {tag:r.tag,url:r.url,status:resp.status};"
         "}).catch(function(){"
         "return {tag:r.tag,url:r.url,status:0};"
         "});"
         "})).then(function(results){"
         "window.webkit.messageHandlers.resourceVerifyResult.postMessage({results:results});"
         "});"
         "})()";

    [webView evaluateJavaScript:js completionHandler:^(id result, NSError *error) {
        if (error) {
            CLY_LOG_I(@"%s Error injecting verify script: %@", __FUNCTION__, error.localizedDescription);
            [self notifyPageLoaded];
        }
    }];
}

- (void)notifyPageLoaded {
    if (self.webViewClosed || self.hasAppeared) return;

    // Reaching here means the load verified good (all resources OK, or verification could
    // not run). A successful load wins over a retry still pending from an earlier failure
    // in this cycle: cancel it, otherwise the stale reload would wipe the now-good page and
    // re-fire the page's on-load [CLY]_content_shown.
    [self cancelPendingReload];

    [self.loadTimeoutTimer invalidate];
    self.loadTimeoutTimer = nil;

    [self.presentingController updatePlacementRespectToSafeAreas];
    self.hasAppeared = YES;
    self.backgroundView.hidden = NO;
    if (self.appearBlock) {
        self.appearBlock();
    }
}

// A critical (JS/CSS) resource failed to load. Rather than closing the content
// immediately, reload the web view up to kCLYMaxResourceRetries times before giving
// up. This turns a transient network hiccup (e.g. a connection stalled under a burst
// of parallel asset requests against a rate-limited / HTTP-1.1 edge) into a recoverable
// event instead of a dismissed content. Multiple failures from the same load are
// coalesced into a single reload. Must be called on the main thread.
- (void)retryOrCloseWebViewForReason:(NSString *)reason {
    if (self.webViewClosed) return;

    // Once the content is visible, a late resource failure must not reload or tear it
    // down: the injected error listener / PerformanceObserver stay active for the whole
    // page life, so a dynamically-loaded or lazy resource failing after appearance would
    // otherwise re-run the page (flashing it, discarding scroll / in-progress survey
    // input, and re-firing on-load analytics) or dismiss content the user is using. The
    // retry mechanism only recovers failures during the initial load.
    if (self.hasAppeared) {
        CLY_LOG_I(@"%s %@ — content already visible, treating as non-fatal.", __FUNCTION__, reason);
        return;
    }

    // Reload-on-failure is opt-in. When disabled, keep the original behavior: close on failure.
    if (!CountlyContentBuilderInternal.sharedInstance.enableContentReloadOnStall) {
        CLY_LOG_I(@"%s %@ — reload-on-stall disabled, closing web view.", __FUNCTION__, reason);
        [self closeWebView];
        return;
    }

    // A reload is already scheduled for this load cycle — coalesce further failures.
    if (self.retryInProgress) {
        CLY_LOG_I(@"%s %@ — retry already scheduled, ignoring.", __FUNCTION__, reason);
        return;
    }

    if (self.resourceRetryCount >= kCLYMaxResourceRetries) {
        CLY_LOG_I(@"%s %@ — retries exhausted (%ld/%ld). Closing web view.", __FUNCTION__, reason, (long)self.resourceRetryCount, (long)kCLYMaxResourceRetries);
        [self closeWebView];
        return;
    }

    self.resourceRetryCount += 1;
    self.retryInProgress = YES;
    // Cancel the in-flight stall timer: we have committed to a reload, and the reload's
    // own didStartProvisionalNavigation: will arm a fresh one. Leaving the old timer live
    // risks a spurious loadDidTimeout in the reload-delay window.
    [self.loadTimeoutTimer invalidate];
    self.loadTimeoutTimer = nil;
    NSTimeInterval delay = kCLYResourceRetryBaseDelay * self.resourceRetryCount;
    CLY_LOG_I(@"%s %@ — retrying load (%ld/%ld) in %.1fs.", __FUNCTION__, reason, (long)self.resourceRetryCount, (long)kCLYMaxResourceRetries, delay);

    __weak typeof(self) weakSelf = self;
    // Cancellable so a load that succeeds during the delay window can cancel this reload
    // (see cancelPendingReload / notifyPageLoaded). Otherwise a stale reload would wipe the
    // now-good page and re-fire the page's on-load [CLY]_content_shown.
    dispatch_block_t reloadBlock = dispatch_block_create(0, ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.pendingReloadBlock = nil;
        // hasAppeared / webViewClosed are belt-and-suspenders: a successful load normally
        // cancels this block outright, but never reload content that already loaded/closed.
        if (strongSelf.webViewClosed || strongSelf.hasAppeared) return;
        strongSelf.retryInProgress = NO;
        WKWebView *webView = strongSelf.backgroundView.webView;
        if (!webView) {
            [strongSelf closeWebView];
            return;
        }
        CLY_LOG_I(@"%s Reloading web view (retry %ld/%ld).", __FUNCTION__, (long)strongSelf.resourceRetryCount, (long)kCLYMaxResourceRetries);
        [webView reload];
    });
    self.pendingReloadBlock = reloadBlock;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), reloadBlock);
}

// Cancel a reload scheduled by retryOrCloseWebViewForReason: that has not fired yet, and
// clear the in-progress flag. Called when a load succeeds (notifyPageLoaded) or the view
// closes, so a stale reload can't reload a page that already loaded.
- (void)cancelPendingReload {
    if (self.pendingReloadBlock) {
        dispatch_block_cancel(self.pendingReloadBlock);
        self.pendingReloadBlock = nil;
    }
    self.retryInProgress = NO;
}

- (void)userContentController:(WKUserContentController *)userContentController
      didReceiveScriptMessage:(WKScriptMessage *)message
{
    if (self.webViewClosed) return;

    if ([message.name isEqualToString:@"resourceLoadError"]) {
        NSDictionary *body = message.body;
        NSString *tag = body[@"tag"];
        NSString *url = body[@"url"];

        CLY_LOG_I(@"%s Critical resource (%@) failed to load: [%@].", __FUNCTION__, tag, url);

        NSString *reason = [NSString stringWithFormat:@"Critical resource (%@) failed to load: [%@]", tag, url];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self retryOrCloseWebViewForReason:reason];
        });
    }
    else if ([message.name isEqualToString:@"resourceVerifyResult"]) {
        NSDictionary *body = message.body;
        NSArray *results = body[@"results"];

        if ([results isKindOfClass:[NSArray class]]) {
            for (NSDictionary *entry in results) {
                NSInteger status = [entry[@"status"] integerValue];
                if (status >= 400) {
                    CLY_LOG_I(@"%s Critical resource (%@) returned HTTP %ld: [%@].",
                              __FUNCTION__, entry[@"tag"], (long)status, entry[@"url"]);
                    // This is the post-load HEAD verification (runs on didFinishNavigation):
                    // the page has already finished loading and run its on-load JS, so a
                    // reload from here would re-fire any analytics it recorded. Do NOT retry
                    // from this path. Retries are driven only by the during-load
                    // resourceLoadError path. Defer to an in-flight retry if one is already
                    // scheduled, never tear down already-visible content, otherwise close.
                    if (self.hasAppeared || self.retryInProgress) {
                        return;
                    }
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [self closeWebView];
                    });
                    return;
                }
            }
        }

        [self notifyPageLoaded];
    }
}

- (void)animateView:(UIView *)view withAnimationType:(AnimationType)animationType {
    NSTimeInterval animationDuration = 0;
    CGAffineTransform initialTransform = CGAffineTransformIdentity;

    switch (animationType) {
        case AnimationTypeSlideInFromBottom:
            initialTransform = CGAffineTransformMakeTranslation(0, view.superview.frame.size.height);
            break;
        case AnimationTypeSlideInFromTop:
            initialTransform = CGAffineTransformMakeTranslation(0, -view.superview.frame.size.height);
            break;
        case AnimationTypeSlideInFromLeft:
            initialTransform = CGAffineTransformMakeTranslation(-view.superview.frame.size.width, 0);
            break;
        case AnimationTypeSlideInFromRight:
            initialTransform = CGAffineTransformMakeTranslation(view.superview.frame.size.width, 0);
            break;
        case AnimationTypeIncreaseHeight: {
            CGRect originalFrame = view.frame;
            view.frame = CGRectMake(originalFrame.origin.x, originalFrame.origin.y, originalFrame.size.width, 0);
            [UIView animateWithDuration:animationDuration animations:^{
                view.frame = originalFrame;
            }];
            return;
        }
        default:
            return;
    }

    view.transform = initialTransform;
    [UIView animateWithDuration:animationDuration animations:^{
        view.transform = CGAffineTransformIdentity;
    }];
}

- (void)contentURLAction:(NSDictionary *)queryParameters {
    NSString *action = queryParameters[@"action"];
    if(action) {
        if ([action isEqualToString:@"event"]) {
            NSString *eventsJson = queryParameters[@"event"];
            if(eventsJson) {
                [self recordEventsWithJSONString:eventsJson];
            }
        } else if ([action isEqualToString:@"link"]) {
            NSString *link = queryParameters[@"link"];
            if(link) {
                [self openExternalLink:link];
            }
        } else if ([action isEqualToString:@"resize_me"]) {
            NSString *resize = queryParameters[@"resize_me"];
            if(resize) {
                [self resizeWebViewWithJSONString:resize];
            }
        }
    }
}

- (void)widgetURLAction:(NSDictionary *)queryParameters {
    // none action yet
}

- (NSDictionary *)parseQueryString:(NSString *)url {
    NSMutableDictionary *queryDict = [NSMutableDictionary dictionary];
    NSArray *urlComponents = [url componentsSeparatedByString:@"?"];

    if (urlComponents.count > 1) {
        NSArray *queryItems = [urlComponents[1] componentsSeparatedByString:@"&"];
        
        for (NSString *item in queryItems) {
            NSArray *keyValue = [item componentsSeparatedByString:@"="];
            if (keyValue.count == 2) {
                NSString *key = keyValue[0];
                NSString *value = keyValue[1];
                queryDict[key] = value;
            }
        }
    }

    return queryDict;
}

- (void)recordEventsWithJSONString:(NSString *)jsonString {
    // Decode the URL-encoded JSON string
    NSString *decodedString = [jsonString stringByRemovingPercentEncoding];

    // Convert the decoded string to NSData
    NSData *data = [decodedString dataUsingEncoding:NSUTF8StringEncoding];

    // Parse the JSON data
    NSError *error = nil;
    NSArray *events = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];

    if (error) {
        CLY_LOG_I(@"%s Error parsing JSON: %@", __FUNCTION__, error);
    } else {
        CLY_LOG_I(@"%s Parsed JSON: %@", __FUNCTION__, events);
    }

    if (!events || ![events isKindOfClass:[NSArray class]]) {
            CLY_LOG_I(@"Events array should not be empty or nil, and should be of type NSArray");
            return;
    }
    for (NSDictionary *event in events) {
            NSString *key = event[@"key"];
            NSDictionary *segmentation = event[@"segmentation"];
            NSDictionary *sg = event[@"sg"];
            if(!key) {
                CLY_LOG_I(@"Skipping the event due to key is empty or nil");
                continue;
            }
            if(sg) {
                segmentation = sg;
            }
            if(!segmentation) {
                CLY_LOG_I(@"Skipping the event due to missing segmentation");
                continue;
            }

            [Countly.sharedInstance recordEvent:key segmentation:segmentation];
    }

    [CountlyConnectionManager.sharedInstance attemptToSendStoredRequests];
}

- (void)openExternalLink:(NSString *)urlString {
    NSURL *url = [NSURL URLWithString:urlString];
    if (url) {
        [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:^(BOOL success) {
            if (success) {
                CLY_LOG_I(@"URL [%@] opened in external browser", urlString);
            } else {
                CLY_LOG_I(@"Unable to open URL [%@] in external browser", urlString);
            }
        }];
    }
}

- (void)resizeWebViewWithJSONString:(NSString *)jsonString {

    // Decode the URL-encoded JSON string
    NSString *decodedString = [jsonString stringByRemovingPercentEncoding];

    // Convert the decoded string to NSData
    NSData *data = [decodedString dataUsingEncoding:NSUTF8StringEncoding];

    // Parse the JSON data
    NSError *error = nil;
    NSDictionary *resizeDict = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];

    if (!resizeDict) {
        CLY_LOG_I(@"Resize dictionary should not be empty or nil. Error: %@", error);
        return;
    }

    // Ensure resizeDict is a dictionary
    if (![resizeDict isKindOfClass:[NSDictionary class]]) {
        CLY_LOG_I(@"Resize dictionary should be of type NSDictionary");
        return;
    }

    // Retrieve portrait and landscape dimensions
    NSDictionary *portraitDimensions = resizeDict[@"p"];
    NSDictionary *landscapeDimensions = resizeDict[@"l"];

    if (!portraitDimensions && !landscapeDimensions) {
        CLY_LOG_I(@"Resize dimensions should not be empty or nil");
        return;
    }

    // Determine the current orientation
    UIInterfaceOrientation orientation = [UIApplication sharedApplication].statusBarOrientation;
    BOOL isLandscape = UIInterfaceOrientationIsLandscape(orientation);

    // Select the appropriate dimensions based on orientation
    NSDictionary *dimensions = isLandscape ? landscapeDimensions : portraitDimensions;

    // Get the dimension values
    CGFloat x = [dimensions[@"x"] floatValue];
    CGFloat y = [dimensions[@"y"] floatValue];
    CGFloat width = [dimensions[@"w"] floatValue];
    CGFloat height = [dimensions[@"h"] floatValue];

    // Animate the resizing of the web view
    [UIView animateWithDuration:0.3 animations:^{
        CGRect frame = self.backgroundView.webView.frame;
        frame.origin.x = x;
        frame.origin.y = y;
        frame.size.width = width;
        frame.size.height = height;
        self.backgroundView.webView.frame = frame;
        [self.presentingController updatePlacementRespectToSafeAreas];
    } completion:^(BOOL finished) {
        CLY_LOG_I(@"%s, Resized web view to width: %f, height: %f", __FUNCTION__, width, height);
    }];
}

- (void)closeWebView
{
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.backgroundView.webView) {
            return;
        }
        self.webViewClosed = YES;
        self.window.hidden = YES;
        self.loadStartDate = nil;
        [self.loadTimeoutTimer invalidate];
        self.loadTimeoutTimer = nil;
        [self cancelPendingReload];
        if (self.backgroundView) {
            [self.backgroundView.webView stopLoading];
            self.backgroundView.webView.navigationDelegate = nil;
            self.backgroundView.webView.UIDelegate = nil;
            [self.backgroundView removeFromSuperview];
            WKUserContentController *controller = self.backgroundView.webView.configuration.userContentController;
            [controller removeScriptMessageHandlerForName:@"resourceLoadError"];
            [controller removeScriptMessageHandlerForName:@"resourceVerifyResult"];
        }
        if (self.dismissBlock) {
            self.dismissBlock();
        }
        if(self.presentingController) {
            [self.presentingController dismissViewControllerAnimated:NO completion:nil];
        }
        if(self.window) {
            if(self.window.rootViewController) {
                [self.window.rootViewController.view removeFromSuperview];
            }
            self.window.rootViewController = nil;
            if (@available(iOS 13.0, *)) {
                self.window.windowScene = nil;
            }
        }
        
        self.backgroundView = nil;
        self.presentingController = nil;
        self.window = nil;
    });
}

- (void)loadDidTimeout {
    if (self.hasAppeared || self.webViewClosed) return;
    CLY_LOG_I(@"%s Web view load stalled after %.1fs.", __FUNCTION__, self.loadTimeoutInterval);
    // A stalled load fires no JS 'error' event, so it never reaches the resource-error
    // retry path. Route it through the same retry here: reload (observed to recover)
    // up to the retry cap, then close. Do NOT set webViewClosed first — that would make
    // retryOrCloseWebViewForReason: bail out before it can retry.
    [self retryOrCloseWebViewForReason:@"load stalled (no appearance)"];
}
  #endif
@end
#endif
