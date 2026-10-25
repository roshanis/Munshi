import SwiftUI
import WebKit

/// Shows one chapter of a web-rendered book and reports scrolling and link taps back to the model.
struct ChapterWebView {
    let model: WebReaderModel
    let request: WebReaderModel.LoadRequest
    let appearance: ReaderAppearance
    let openExternal: (URL) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model, openExternal: openExternal)
    }

    private func makeWebView(coordinator: Coordinator) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let controller = WKUserContentController()
        controller.add(coordinator, name: Coordinator.messageName)
        configuration.userContentController = controller
        #if os(iOS)
        configuration.dataDetectorTypes = []
        #endif

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = coordinator
        #if os(iOS)
        webView.isOpaque = false
        webView.scrollView.contentInsetAdjustmentBehavior = .automatic
        #else
        webView.setValue(false, forKey: "drawsBackground")
        #endif
        coordinator.webView = webView
        return webView
    }

    private func update(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.openExternal = openExternal
        coordinator.apply(appearance)
        coordinator.load(request)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        static let messageName = "munshi"

        let model: WebReaderModel
        var openExternal: (URL) -> Void
        weak var webView: WKWebView?
        private var appearance: ReaderAppearance?
        private var loadedToken: UUID?
        private var pendingRequest: WebReaderModel.LoadRequest?

        init(model: WebReaderModel, openExternal: @escaping (URL) -> Void) {
            self.model = model
            self.openExternal = openExternal
        }

        func apply(_ appearance: ReaderAppearance) {
            guard appearance != self.appearance, let webView else { return }
            self.appearance = appearance

            let controller = webView.configuration.userContentController
            controller.removeAllUserScripts()
            controller.addUserScript(WKUserScript(
                source: Self.styleScript(css: appearance.css),
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            ))
            controller.addUserScript(WKUserScript(
                source: Self.trackingScript,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            ))

            webView.pageZoom = appearance.fontScale
            #if os(iOS)
            let background = UIColor(appearance.theme.background)
            webView.backgroundColor = background
            webView.scrollView.backgroundColor = background
            #else
            webView.underPageBackgroundColor = NSColor(appearance.theme.background)
            #endif
            webView.evaluateJavaScript(Self.styleScript(css: appearance.css), completionHandler: nil)
        }

        func load(_ request: WebReaderModel.LoadRequest) {
            guard request.token != loadedToken, let webView else { return }
            loadedToken = request.token
            pendingRequest = request
            webView.loadFileURL(model.fileURL(forChapter: request.chapter), allowingReadAccessTo: model.contentURL)
        }

        /// The content controller retains its message handlers, so break the cycle when the view goes away.
        func tearDown(_ webView: WKWebView) {
            webView.configuration.userContentController.removeScriptMessageHandler(forName: Self.messageName)
            webView.navigationDelegate = nil
        }

        // MARK: WKNavigationDelegate

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard let request = pendingRequest else { return }
            pendingRequest = nil
            let script: String
            if let fragment = request.fragment, let encoded = Self.jsonString(fragment) {
                script = "var el = document.getElementById(\(encoded)); if (el) { el.scrollIntoView(); } else { window.scrollTo(0, 0); }"
            } else {
                script = """
                (function() {
                  var max = document.documentElement.scrollHeight - window.innerHeight;
                  window.scrollTo(0, Math.max(0, max * \(request.fraction)));
                })();
                """
            }
            // Give layout a moment (fonts, viewport) before restoring the position.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                webView.evaluateJavaScript(script, completionHandler: nil)
            }
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction
        ) async -> WKNavigationActionPolicy {
            guard navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url else {
                return .allow
            }
            guard url.isFileURL else {
                openExternal(url)
                return .cancel
            }
            guard let path = model.relativePath(for: url) else { return .cancel }
            if path == model.publication.spine[model.chapter] {
                // An in-page anchor such as a footnote.
                return .allow
            }
            return model.didFollowLink(toPath: path, fragment: url.fragment) ? .cancel : .allow
        }

        // MARK: WKScriptMessageHandler

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let fraction = body["fraction"] as? Double else { return }
            model.didScroll(to: fraction)
        }

        // MARK: Scripts

        private static func jsonString(_ string: String) -> String? {
            guard let data = try? JSONEncoder().encode(string) else { return nil }
            return String(data: data, encoding: .utf8)
        }

        private static func styleScript(css: String) -> String {
            let encoded = jsonString(css) ?? "\"\""
            return """
            (function() {
              var style = document.getElementById('munshi-style');
              if (!style) {
                style = document.createElement('style');
                style.id = 'munshi-style';
                (document.head || document.documentElement).appendChild(style);
              }
              style.textContent = \(encoded);
            })();
            """
        }

        private static let trackingScript = """
        (function() {
          if (!document.querySelector('meta[name=viewport]')) {
            var meta = document.createElement('meta');
            meta.name = 'viewport';
            meta.content = 'width=device-width, initial-scale=1';
            (document.head || document.documentElement).appendChild(meta);
          }
          var style = document.getElementById('munshi-style');
          if (style && style.parentNode) { style.parentNode.appendChild(style); }
          var scheduled = false;
          function report() {
            scheduled = false;
            var max = document.documentElement.scrollHeight - window.innerHeight;
            var fraction = max > 0 ? window.scrollY / max : 0;
            window.webkit.messageHandlers.munshi.postMessage({ fraction: Math.max(0, Math.min(1, fraction)) });
          }
          window.addEventListener('scroll', function() {
            if (!scheduled) { scheduled = true; setTimeout(report, 300); }
          }, { passive: true });
        })();
        """
    }
}

#if os(iOS)
extension ChapterWebView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView {
        makeWebView(coordinator: context.coordinator)
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        update(webView, coordinator: context.coordinator)
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.tearDown(webView)
    }
}
#else
extension ChapterWebView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView {
        makeWebView(coordinator: context.coordinator)
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        update(webView, coordinator: context.coordinator)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.tearDown(webView)
    }
}
#endif
