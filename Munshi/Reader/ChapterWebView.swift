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
        model.page = coordinator
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
        private var pendingNavigation: WKNavigation?
        private var loadWaiters: [CheckedContinuation<Void, Never>] = []
        private var isTornDown = false

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
            pendingNavigation = webView.loadFileURL(model.fileURL(forChapter: request.chapter), allowingReadAccessTo: model.contentURL)
        }

        /// The content controller retains its message handlers, so break the cycle when the view goes away.
        func tearDown(_ webView: WKWebView) {
            webView.configuration.userContentController.removeScriptMessageHandler(forName: Self.messageName)
            webView.navigationDelegate = nil
            isTornDown = true
            resumeLoadWaiters()
        }

        // MARK: Reading aloud

        /// True once the chapter the model asked for has finished loading.
        private var isLoaded: Bool {
            loadedToken == model.request.token && pendingRequest == nil
        }

        private func resumeLoadWaiters() {
            let waiters = loadWaiters
            loadWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }

        /// The readable blocks of the current chapter, waiting for it to load first if needed.
        func speechSection(fromStart: Bool) async -> SpeechSection? {
            while !isLoaded && !isTornDown {
                await withCheckedContinuation { loadWaiters.append($0) }
            }
            guard !isTornDown, let webView else { return nil }
            let json: String? = await withCheckedContinuation { continuation in
                webView.evaluateJavaScript(Self.speechScript(fromStart: fromStart)) { result, _ in
                    continuation.resume(returning: result as? String)
                }
            }
            struct Result: Decodable {
                var texts: [String]
                var start: Int
            }
            guard let data = json?.data(using: .utf8),
                  let result = try? JSONDecoder().decode(Result.self, from: data)
            else { return nil }
            return SpeechSection(blocks: result.texts, startIndex: result.start)
        }

        func highlightSpeechBlock(_ index: Int?) {
            webView?.evaluateJavaScript("window.munshiHighlight && window.munshiHighlight(\(index ?? -1));", completionHandler: nil)
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
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(100))
                self.resumeLoadWaiters()
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            navigationFailed(navigation)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            navigationFailed(navigation)
        }

        /// A chapter that fails to load shouldn't leave read-aloud waiting for it.
        private func navigationFailed(_ navigation: WKNavigation?) {
            guard let navigation, navigation === pendingNavigation else { return }
            pendingRequest = nil
            pendingNavigation = nil
            resumeLoadWaiters()
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

        /// Collects the chapter's readable blocks (paragraphs, headings, list items), tags each one so it
        /// can be highlighted, and returns their text as JSON along with the first block on screen.
        private static func speechScript(fromStart: Bool) -> String {
            """
            (function(fromStart) {
              var selector = 'p,h1,h2,h3,h4,h5,h6,li,blockquote,dt,dd,pre,figcaption,caption,td,th,div';
              var tagged = document.querySelectorAll('[data-munshi-speech]');
              for (var i = 0; i < tagged.length; i++) { tagged[i].removeAttribute('data-munshi-speech'); }
              var texts = [];
              var start = -1;
              var nodes = document.body ? document.body.querySelectorAll(selector) : [];
              for (var j = 0; j < nodes.length; j++) {
                var el = nodes[j];
                if (el.querySelector(selector)) { continue; }
                var text = (el.innerText || '').replace(/\\s+/g, ' ').trim();
                if (!/[0-9A-Za-z\\u00C0-\\uFFFF]/.test(text)) { continue; }
                el.setAttribute('data-munshi-speech', String(texts.length));
                if (start < 0 && !fromStart && el.getBoundingClientRect().bottom > 4) { start = texts.length; }
                texts.push(text);
              }
              if (texts.length === 0 && document.body) {
                start = 0;
                texts = (document.body.innerText || '').split(/\\n\\s*\\n/)
                  .map(function(t) { return t.replace(/\\s+/g, ' ').trim(); })
                  .filter(function(t) { return t.length > 0; });
              }
              window.munshiHighlight = function(index) {
                var old = document.querySelectorAll('.munshi-speaking');
                for (var k = 0; k < old.length; k++) { old[k].classList.remove('munshi-speaking'); }
                if (index < 0) { return; }
                var target = document.querySelector('[data-munshi-speech="' + index + '"]');
                if (!target) { return; }
                target.classList.add('munshi-speaking');
                var rect = target.getBoundingClientRect();
                if (rect.top < 0 || rect.bottom > window.innerHeight) {
                  var tall = rect.height > window.innerHeight * 0.7;
                  target.scrollIntoView({ behavior: 'smooth', block: tall ? 'start' : 'center' });
                }
              };
              // Scrolled past every block: start with the last one rather than jumping back to the top.
              if (start < 0) { start = fromStart ? 0 : texts.length - 1; }
              return JSON.stringify({ texts: texts, start: Math.max(0, start) });
            })(\(fromStart));
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
