//
//  CountlyWebViewManagerTests.swift
//  CountlyTests
//
//  Created on 13/03/2026.
//  Copyright © 2026 Countly. All rights reserved.
//

import XCTest
import WebKit
@testable import Countly

#if os(iOS)

class CountlyWebViewManagerTests: XCTestCase {

    var manager: CountlyWebViewManager!

    override func setUp() {
        super.setUp()
        manager = CountlyWebViewManager()
        // Retry-on-failure is opt-in; enable it so the retry-path tests exercise it.
        CountlyContentBuilderInternal.sharedInstance().enableContentReloadOnStall = true
    }

    override func tearDown() {
        manager = nil
        CountlyContentBuilderInternal.sharedInstance().enableContentReloadOnStall = false
        super.tearDown()
    }

    // MARK: - parseQueryString tests

    func testParseQueryString_basicParams() {
        let url = "https://example.com?key1=value1&key2=value2"
        let result = manager.parseQueryString(url)!

        XCTAssertEqual(result["key1"] as? String, "value1")
        XCTAssertEqual(result["key2"] as? String, "value2")
    }

    func testParseQueryString_noParams() {
        let url = "https://example.com"
        let result = manager.parseQueryString(url)!

        XCTAssertTrue(result.isEmpty)
    }

    func testParseQueryString_closeParam() {
        let url = "https://countly_action_event?close=1&cly_x_action_event=1"
        let result = manager.parseQueryString(url)!

        XCTAssertEqual(result["close"] as? String, "1")
        XCTAssertEqual(result["cly_x_action_event"] as? String, "1")
    }

    func testParseQueryString_actionEvent() {
        let url = "https://countly_action_event?action=event&event=%5B%7B%22key%22%3A%22test%22%7D%5D&cly_x_action_event=1"
        let result = manager.parseQueryString(url)!

        XCTAssertEqual(result["action"] as? String, "event")
        XCTAssertEqual(result["cly_x_action_event"] as? String, "1")
    }

    func testParseQueryString_resizeAction() {
        let url = "https://countly_action_event?action=resize_me&resize_me=%7B%22p%22%3A%7B%22x%22%3A0%2C%22y%22%3A0%2C%22w%22%3A320%2C%22h%22%3A480%7D%7D&cly_x_action_event=1"
        let result = manager.parseQueryString(url)!

        XCTAssertEqual(result["action"] as? String, "resize_me")
    }

    func testParseQueryString_emptyQueryString() {
        let url = "https://example.com?"
        let result = manager.parseQueryString(url)!

        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - notifyPageLoaded tests

    func testNotifyPageLoaded_callsAppearBlock() {
        let expectation = expectation(description: "Appear block called")

        manager.webViewClosed = false
        manager.hasAppeared = false
        manager.appearBlock = {
            expectation.fulfill()
        }

        manager.notifyPageLoaded()

        waitForExpectations(timeout: 1.0)
        XCTAssertTrue(manager.hasAppeared)
    }

    func testNotifyPageLoaded_skipsIfWebViewClosed() {
        manager.webViewClosed = true
        manager.hasAppeared = false
        var blockCalled = false
        manager.appearBlock = {
            blockCalled = true
        }

        manager.notifyPageLoaded()

        XCTAssertFalse(blockCalled)
        XCTAssertFalse(manager.hasAppeared)
    }

    func testNotifyPageLoaded_skipsIfAlreadyAppeared() {
        manager.webViewClosed = false
        manager.hasAppeared = true
        var callCount = 0
        manager.appearBlock = {
            callCount += 1
        }

        manager.notifyPageLoaded()

        XCTAssertEqual(callCount, 0)
    }

    func testNotifyPageLoaded_invalidatesTimer() {
        manager.webViewClosed = false
        manager.hasAppeared = false
        manager.loadTimeoutTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: false, block: { _ in })

        XCTAssertNotNil(manager.loadTimeoutTimer)

        manager.notifyPageLoaded()

        XCTAssertNil(manager.loadTimeoutTimer)
    }

    // MARK: - loadDidTimeout tests

    func testLoadDidTimeout_schedulesRetry() {
        manager.webViewClosed = false
        manager.hasAppeared = false

        manager.loadDidTimeout()

        // A stalled load now triggers a retry (reload) instead of an immediate close.
        XCTAssertFalse(manager.webViewClosed)
        XCTAssertEqual(manager.resourceRetryCount, 1)
        XCTAssertTrue(manager.retryInProgress)
    }

    func testLoadDidTimeout_closesAfterRetriesExhausted() {
        manager.webViewClosed = false
        manager.hasAppeared = false
        manager.resourceRetryCount = 99  // retries already used up

        let bgView = PassThroughBackgroundView(frame: .zero)
        bgView.webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        manager.backgroundView = bgView

        let dismissExpectation = expectation(description: "Dismiss block called")
        manager.dismissBlock = { dismissExpectation.fulfill() }

        manager.loadDidTimeout()

        waitForExpectations(timeout: 3.0)
        XCTAssertTrue(manager.webViewClosed)
    }

    func testLoadDidTimeout_skipsIfAlreadyAppeared() {
        manager.webViewClosed = false
        manager.hasAppeared = true
        var dismissCalled = false
        manager.dismissBlock = {
            dismissCalled = true
        }

        manager.loadDidTimeout()

        // Give dispatch_async a chance to run
        let exp = expectation(description: "wait")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            exp.fulfill()
        }
        waitForExpectations(timeout: 1.0)

        XCTAssertFalse(dismissCalled)
        XCTAssertFalse(manager.webViewClosed)
    }

    func testLoadDidTimeout_skipsIfAlreadyClosed() {
        manager.webViewClosed = true
        manager.hasAppeared = false
        var dismissCalled = false
        manager.dismissBlock = {
            dismissCalled = true
        }

        manager.loadDidTimeout()

        let exp = expectation(description: "wait")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            exp.fulfill()
        }
        waitForExpectations(timeout: 1.0)

        XCTAssertFalse(dismissCalled)
    }

    // MARK: - webViewClosed guard tests

    func testWebViewClosedGuard_notifyPageLoadedIsIdempotent() {
        manager.webViewClosed = false
        manager.hasAppeared = false
        var callCount = 0
        manager.appearBlock = {
            callCount += 1
        }

        manager.notifyPageLoaded()
        manager.notifyPageLoaded()
        manager.notifyPageLoaded()

        XCTAssertEqual(callCount, 1)
        XCTAssertTrue(manager.hasAppeared)
    }

    // MARK: - WKScriptMessageHandler tests

    func testDidReceiveScriptMessage_resourceVerifyResult_allOK() {
        manager.webViewClosed = false
        manager.hasAppeared = false

        let expectation = expectation(description: "Appear block called")
        manager.appearBlock = {
            expectation.fulfill()
        }

        let config = WKWebViewConfiguration()
        let contentController = config.userContentController
        contentController.add(manager, name: "resourceLoadError")
        contentController.add(manager, name: "resourceVerifyResult")

        let webView = WKWebView(frame: .zero, configuration: config)

        let js = """
        window.webkit.messageHandlers.resourceVerifyResult.postMessage({
            results: [
                {tag: "SCRIPT", url: "https://example.com/app.js", status: 200},
                {tag: "LINK", url: "https://example.com/style.css", status: 200}
            ]
        });
        """
        webView.evaluateJavaScript(js, completionHandler: nil)

        waitForExpectations(timeout: 3.0)
        XCTAssertTrue(manager.hasAppeared)

        contentController.removeScriptMessageHandler(forName: "resourceLoadError")
        contentController.removeScriptMessageHandler(forName: "resourceVerifyResult")
    }

    func testDidReceiveScriptMessage_resourceVerifyResult_http500ClosesWebView() {
        // The post-load HEAD verification path closes on a >=400 resource and must NOT
        // retry (a reload would re-fire the page's on-load analytics).
        manager.webViewClosed = false
        manager.hasAppeared = false
        manager.appearBlock = nil

        let config = WKWebViewConfiguration()
        let contentController = config.userContentController
        contentController.add(manager, name: "resourceLoadError")
        contentController.add(manager, name: "resourceVerifyResult")

        let webView = WKWebView(frame: .zero, configuration: config)
        let bgView = PassThroughBackgroundView(frame: .zero)
        bgView.webView = webView
        manager.backgroundView = bgView

        let dismissExpectation = expectation(description: "Dismiss block called")
        manager.dismissBlock = { dismissExpectation.fulfill() }

        let js = """
        window.webkit.messageHandlers.resourceVerifyResult.postMessage({
            results: [
                {tag: "SCRIPT", url: "https://example.com/app.js", status: 200},
                {tag: "LINK", url: "https://example.com/style.css", status: 500}
            ]
        });
        """
        webView.evaluateJavaScript(js, completionHandler: nil)

        waitForExpectations(timeout: 3.0)
        XCTAssertTrue(manager.webViewClosed)
        XCTAssertFalse(manager.hasAppeared)
        XCTAssertEqual(manager.resourceRetryCount, 0)  // verify path does not retry

        contentController.removeScriptMessageHandler(forName: "resourceLoadError")
        contentController.removeScriptMessageHandler(forName: "resourceVerifyResult")
    }

    func testDidReceiveScriptMessage_resourceVerifyResult_defersWhileRetryInProgress() {
        // If a during-load retry (resourceLoadError path) is already scheduled, a post-load
        // verification failure must defer to it, not close.
        manager.webViewClosed = false
        manager.hasAppeared = false
        manager.retryInProgress = true

        let config = WKWebViewConfiguration()
        let contentController = config.userContentController
        contentController.add(manager, name: "resourceLoadError")
        contentController.add(manager, name: "resourceVerifyResult")

        let webView = WKWebView(frame: .zero, configuration: config)
        let bgView = PassThroughBackgroundView(frame: .zero)
        bgView.webView = webView
        manager.backgroundView = bgView

        var dismissCalled = false
        manager.dismissBlock = { dismissCalled = true }

        let js = """
        window.webkit.messageHandlers.resourceVerifyResult.postMessage({
            results: [{tag: "SCRIPT", url: "https://example.com/missing.js", status: 404}]
        });
        """
        webView.evaluateJavaScript(js, completionHandler: nil)

        let settle = expectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { settle.fulfill() }
        waitForExpectations(timeout: 2.0)

        XCTAssertFalse(manager.webViewClosed)  // deferred to the in-flight retry
        XCTAssertFalse(dismissCalled)

        contentController.removeScriptMessageHandler(forName: "resourceLoadError")
        contentController.removeScriptMessageHandler(forName: "resourceVerifyResult")
    }

    func testDidReceiveScriptMessage_resourceVerifyResult_emptyResultsShowsView() {
        manager.webViewClosed = false
        manager.hasAppeared = false

        let expectation = expectation(description: "Appear block called")
        manager.appearBlock = {
            expectation.fulfill()
        }

        let config = WKWebViewConfiguration()
        let contentController = config.userContentController
        contentController.add(manager, name: "resourceLoadError")
        contentController.add(manager, name: "resourceVerifyResult")

        let webView = WKWebView(frame: .zero, configuration: config)

        let js = """
        window.webkit.messageHandlers.resourceVerifyResult.postMessage({
            results: []
        });
        """
        webView.evaluateJavaScript(js, completionHandler: nil)

        waitForExpectations(timeout: 3.0)
        XCTAssertTrue(manager.hasAppeared)

        contentController.removeScriptMessageHandler(forName: "resourceLoadError")
        contentController.removeScriptMessageHandler(forName: "resourceVerifyResult")
    }

    func testDidReceiveScriptMessage_resourceLoadError_schedulesRetry() {
        manager.webViewClosed = false
        manager.hasAppeared = false

        let config = WKWebViewConfiguration()
        let contentController = config.userContentController
        contentController.add(manager, name: "resourceLoadError")
        contentController.add(manager, name: "resourceVerifyResult")

        let webView = WKWebView(frame: .zero, configuration: config)

        // Attach backgroundView with webView so a later reload is a clean no-op
        let bgView = PassThroughBackgroundView(frame: .zero)
        bgView.webView = webView
        manager.backgroundView = bgView

        var dismissCalled = false
        manager.dismissBlock = { dismissCalled = true }

        let js = """
        window.webkit.messageHandlers.resourceLoadError.postMessage({
            tag: "SCRIPT",
            url: "https://example.com/broken.js"
        });
        """
        webView.evaluateJavaScript(js, completionHandler: nil)

        let settle = expectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { settle.fulfill() }
        waitForExpectations(timeout: 2.0)

        XCTAssertFalse(manager.webViewClosed)
        XCTAssertFalse(dismissCalled)
        XCTAssertEqual(manager.resourceRetryCount, 1)
        XCTAssertTrue(manager.retryInProgress)

        contentController.removeScriptMessageHandler(forName: "resourceLoadError")
        contentController.removeScriptMessageHandler(forName: "resourceVerifyResult")
    }

    func testDidReceiveScriptMessage_resourceLoadError_closesWhenReloadDisabled() {
        // With enableContentReloadOnStall off, a critical-resource failure closes (original behavior).
        CountlyContentBuilderInternal.sharedInstance().enableContentReloadOnStall = false
        manager.webViewClosed = false
        manager.hasAppeared = false

        let config = WKWebViewConfiguration()
        let contentController = config.userContentController
        contentController.add(manager, name: "resourceLoadError")
        contentController.add(manager, name: "resourceVerifyResult")

        let webView = WKWebView(frame: .zero, configuration: config)
        let bgView = PassThroughBackgroundView(frame: .zero)
        bgView.webView = webView
        manager.backgroundView = bgView

        let dismissExpectation = expectation(description: "Dismiss block called")
        manager.dismissBlock = { dismissExpectation.fulfill() }

        let js = """
        window.webkit.messageHandlers.resourceLoadError.postMessage({tag: "SCRIPT", url: "https://example.com/broken.js"});
        """
        webView.evaluateJavaScript(js, completionHandler: nil)

        waitForExpectations(timeout: 3.0)
        XCTAssertTrue(manager.webViewClosed)
        XCTAssertEqual(manager.resourceRetryCount, 0)  // did not retry

        contentController.removeScriptMessageHandler(forName: "resourceLoadError")
        contentController.removeScriptMessageHandler(forName: "resourceVerifyResult")
    }

    func testDidReceiveScriptMessage_resourceLoadError_closesAfterRetriesExhausted() {
        manager.webViewClosed = false
        manager.hasAppeared = false
        // Simulate retries already used up so the next failure closes immediately.
        manager.resourceRetryCount = 99

        let config = WKWebViewConfiguration()
        let contentController = config.userContentController
        contentController.add(manager, name: "resourceLoadError")
        contentController.add(manager, name: "resourceVerifyResult")

        let webView = WKWebView(frame: .zero, configuration: config)

        // Attach backgroundView with webView so closeWebView doesn't bail early
        let bgView = PassThroughBackgroundView(frame: .zero)
        bgView.webView = webView
        manager.backgroundView = bgView

        let dismissExpectation = expectation(description: "Dismiss block called")
        manager.dismissBlock = { dismissExpectation.fulfill() }

        let js = """
        window.webkit.messageHandlers.resourceLoadError.postMessage({
            tag: "SCRIPT",
            url: "https://example.com/broken.js"
        });
        """
        webView.evaluateJavaScript(js, completionHandler: nil)

        waitForExpectations(timeout: 3.0)
        XCTAssertTrue(manager.webViewClosed)
    }

    func testRetryOrClose_ignoredAfterContentAppeared() {
        // Once content is visible, a late resource failure must NOT reload or close it.
        manager.webViewClosed = false
        manager.hasAppeared = true
        manager.resourceRetryCount = 0

        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let bgView = PassThroughBackgroundView(frame: .zero)
        bgView.webView = webView
        manager.backgroundView = bgView

        var dismissCalled = false
        manager.dismissBlock = { dismissCalled = true }

        manager.retryOrCloseWebView(forReason: "late failure after appearance")

        let settle = expectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { settle.fulfill() }
        waitForExpectations(timeout: 2.0)

        XCTAssertFalse(manager.webViewClosed)
        XCTAssertFalse(dismissCalled)
        XCTAssertFalse(manager.retryInProgress)
        XCTAssertEqual(manager.resourceRetryCount, 0)
    }

    func testDidReceiveScriptMessage_ignoredWhenWebViewClosed() {
        manager.webViewClosed = true
        manager.hasAppeared = false

        var appearCalled = false
        manager.appearBlock = {
            appearCalled = true
        }
        var dismissCalled = false
        manager.dismissBlock = {
            dismissCalled = true
        }

        let config = WKWebViewConfiguration()
        let contentController = config.userContentController
        contentController.add(manager, name: "resourceLoadError")
        contentController.add(manager, name: "resourceVerifyResult")

        let webView = WKWebView(frame: .zero, configuration: config)

        let js = """
        window.webkit.messageHandlers.resourceVerifyResult.postMessage({
            results: [{tag: "SCRIPT", url: "https://example.com/app.js", status: 200}]
        });
        """
        webView.evaluateJavaScript(js, completionHandler: nil)

        let exp = expectation(description: "wait for JS")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            exp.fulfill()
        }
        waitForExpectations(timeout: 2.0)

        XCTAssertFalse(appearCalled)
        XCTAssertFalse(dismissCalled)
        XCTAssertFalse(manager.hasAppeared)

        contentController.removeScriptMessageHandler(forName: "resourceLoadError")
        contentController.removeScriptMessageHandler(forName: "resourceVerifyResult")
    }

    func testDidReceiveScriptMessage_http404ClosesWebView() {
        // Post-load verification 404 closes without retrying.
        manager.webViewClosed = false
        manager.hasAppeared = false

        let config = WKWebViewConfiguration()
        let contentController = config.userContentController
        contentController.add(manager, name: "resourceLoadError")
        contentController.add(manager, name: "resourceVerifyResult")

        let webView = WKWebView(frame: .zero, configuration: config)
        let bgView = PassThroughBackgroundView(frame: .zero)
        bgView.webView = webView
        manager.backgroundView = bgView

        let dismissExpectation = expectation(description: "Dismiss block called")
        manager.dismissBlock = { dismissExpectation.fulfill() }

        let js = """
        window.webkit.messageHandlers.resourceVerifyResult.postMessage({
            results: [
                {tag: "SCRIPT", url: "https://example.com/missing.js", status: 404}
            ]
        });
        """
        webView.evaluateJavaScript(js, completionHandler: nil)

        waitForExpectations(timeout: 3.0)
        XCTAssertTrue(manager.webViewClosed)
        XCTAssertFalse(manager.hasAppeared)
        XCTAssertEqual(manager.resourceRetryCount, 0)  // verify path does not retry

        contentController.removeScriptMessageHandler(forName: "resourceLoadError")
        contentController.removeScriptMessageHandler(forName: "resourceVerifyResult")
    }

    func testDidReceiveScriptMessage_status399DoesNotClose() {
        manager.webViewClosed = false
        manager.hasAppeared = false

        let expectation = expectation(description: "Appear block called")
        manager.appearBlock = {
            expectation.fulfill()
        }

        let config = WKWebViewConfiguration()
        let contentController = config.userContentController
        contentController.add(manager, name: "resourceLoadError")
        contentController.add(manager, name: "resourceVerifyResult")

        let webView = WKWebView(frame: .zero, configuration: config)

        let js = """
        window.webkit.messageHandlers.resourceVerifyResult.postMessage({
            results: [
                {tag: "SCRIPT", url: "https://example.com/redirect.js", status: 399}
            ]
        });
        """
        webView.evaluateJavaScript(js, completionHandler: nil)

        waitForExpectations(timeout: 3.0)
        XCTAssertTrue(manager.hasAppeared)
        XCTAssertFalse(manager.webViewClosed)

        contentController.removeScriptMessageHandler(forName: "resourceLoadError")
        contentController.removeScriptMessageHandler(forName: "resourceVerifyResult")
    }
}

#endif
