import WebKit
import XCTest

@testable import Cluefolk

final class WidgetSchemeHandlerTests: XCTestCase {
  @MainActor func testPolicyFollowsTheAPIOrigin() {
    let policy = WidgetSchemeHandler.policy(apiURL: URL(string: "https://cluefolk.com")!)
    XCTAssertTrue(policy.contains("connect-src https://cluefolk.com wss://cluefolk.com https://files.cluefolk.com;"))
    XCTAssertTrue(policy.contains("img-src 'self' data: blob:;"))
    XCTAssertTrue(policy.hasPrefix("default-src 'none'; script-src 'self';"))
  }

  /// The built-in widget runs from the SDK alone: its script starts, UUIDs work
  /// on the custom scheme, and unknown paths are not served.
  @MainActor func testBuiltInWidgetRunsFromTheScheme() async throws {
    let handler = WidgetSchemeHandler(apiURL: URL(string: "https://cluefolk.com")!)
    let config = WKWebViewConfiguration()
    config.websiteDataStore = .nonPersistent()
    config.setURLSchemeHandler(handler, forURLScheme: WidgetSchemeHandler.scheme)
    config.userContentController.addUserScript(WKUserScript(
      source: "window.__errors = []; addEventListener('error', e => __errors.push(String(e.message)))",
      injectionTime: .atDocumentStart, forMainFrameOnly: true))
    let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: config)
    view.load(URLRequest(url: WidgetSchemeHandler.entry))
    func run(_ script: String) async -> String {
      await withCheckedContinuation { done in
        view.evaluateJavaScript("String(" + script + ")") { value, error in
          done.resume(returning: (value as? String) ?? "error: \(String(describing: error))")
        }
      }
    }
    var children = "0"
    for _ in 0..<100 where children == "0" {
      try await Task.sleep(nanoseconds: 100_000_000)
      children = await run("document.getElementById('root')?.childElementCount ?? 0")
    }
    let state = await run("JSON.stringify({href: location.href, ready: document.readyState, secure: isSecureContext, errors: window.__errors})")
    XCTAssertNotEqual(children, "0", "the widget did not render: \(state)")
    let uuid = await run("crypto.randomUUID()")
    XCTAssertNotNil(UUID(uuidString: uuid), "randomUUID: \(uuid) \(state)")
    XCTAssertTrue(state.contains("\"secure\":true"), state)
  }

  /// Only the generated widget files are served, with the content policy.
  @MainActor func testServesOnlyWidgetFiles() {
    let handler = WidgetSchemeHandler(apiURL: URL(string: "https://cluefolk.com")!)
    let view = WKWebView()
    let page = FakeTask(URL(string: "cluefolk-widget://app/index.html")!)
    handler.webView(view, start: page)
    XCTAssertEqual(page.response?.statusCode, 200)
    XCTAssertEqual(page.response?.value(forHTTPHeaderField: "Content-Security-Policy"), WidgetSchemeHandler.policy(apiURL: URL(string: "https://cluefolk.com")!))
    XCTAssertTrue(String(decoding: page.body, as: UTF8.self).contains("<div id=\"root\">"))
    for path in ["cluefolk-widget://app/secret.txt", "cluefolk-widget://other/index.html", "cluefolk-widget://app/../index.html"] {
      let task = FakeTask(URL(string: path)!)
      handler.webView(view, start: task)
      XCTAssertEqual(task.response?.statusCode, 404, path)
      XCTAssertTrue(task.body.isEmpty, path)
    }
  }
}

private final class FakeTask: NSObject, WKURLSchemeTask {
  let request: URLRequest
  var response: HTTPURLResponse?
  var body = Data()
  init(_ url: URL) { request = URLRequest(url: url) }
  func didReceive(_ response: URLResponse) { self.response = response as? HTTPURLResponse }
  func didReceive(_ data: Data) { body.append(data) }
  func didFinish() {}
  func didFailWithError(_ error: any Error) {}
}
