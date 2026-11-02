import Foundation
import WebKit

/// Serves the widget built into the SDK (WidgetAssets, generated from the widget
/// build) at cluefolk-widget://app, so opening support downloads no page.
@MainActor
final class WidgetSchemeHandler: NSObject, WKURLSchemeHandler {
  static let scheme = "cluefolk-widget"
  static let entry = URL(string: "cluefolk-widget://app/index.html")!
  private static let files: [String: (type: String, data: Data)] = WidgetAssets.files.compactMapValues {
    file in Data(base64Encoded: file.base64).map { (file.type, $0) }
  }
  private let policy: String

  init(apiURL: URL) {
    policy = Self.policy(apiURL: apiURL)
  }

  /// Only the API origin of these options and the files host next to it
  /// (files.cluefolk.com, uploads only); images are inline or blobs.
  static func policy(apiURL: URL) -> String {
    let api = Cluefolk.origin(apiURL)
    let host = api.components(separatedBy: "://").last ?? ""
    let files = "https://files." + (apiURL.host ?? "")
    return "default-src 'none'; script-src 'self'; style-src 'self'; font-src 'self'; "
      + "img-src 'self' data: blob:; connect-src \(api) wss://\(host) \(files); "
      + "object-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"
  }

  func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
    guard let url = task.request.url else { return task.didFailWithError(URLError(.badURL)) }
    let headers: [String: String]
    let body: Data
    var status = 200
    if url.host == "app", let file = Self.files[String(url.path.dropFirst())] {
      headers = [
        "Content-Type": file.type + "; charset=utf-8", "Content-Security-Policy": policy,
        "X-Content-Type-Options": "nosniff", "Referrer-Policy": "no-referrer", "Cache-Control": "no-store",
      ]
      body = file.data
    } else {
      status = 404
      headers = ["Content-Type": "text/plain"]
      body = Data()
    }
    task.didReceive(HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!)
    task.didReceive(body)
    task.didFinish()
  }

  func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}
