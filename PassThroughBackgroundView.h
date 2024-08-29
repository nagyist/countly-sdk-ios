// PassThroughBackgroundView.h
//
// This code is provided under the MIT License.
//
// Please visit www.count.ly for more information.

#if (TARGET_OS_IOS)
#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import "CountlyCommon.h"

@interface PassThroughBackgroundView : UIView

@property (nonatomic, strong) WKWebView *webView;
@property (nonatomic, strong) CLYButton *dismissButton;


@end
#endif
