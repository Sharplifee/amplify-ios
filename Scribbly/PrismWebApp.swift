import SwiftUI
import UIKit
import WebKit

/// The app and the website are the same Prism: the app shows the live site
/// (https://getamplify.vercel.app/prism) full screen in a WKWebView, so every
/// improvement shipped to the web is in the app the moment it deploys.
/// Native extras: microphone and camera for recording, file uploads, the iOS
/// share sheet (Web Share), and hand-off of sms:, mailto:, WhatsApp, LINE,
/// Instagram and other app links to iOS. Every load, link and error goes to
/// the append-only event log.
enum PrismWeb {
    static let url = URL(string: "https://getamplify.vercel.app/prism")!
    static let host = "getamplify.vercel.app"
}

struct PrismWebApp: View {
    @State private var failed: String?
    @State private var loading = true
    @State private var reloadToken = 0

    var body: some View {
        ZStack {
            Color.white.ignoresSafeArea()
            PrismWebView(reloadToken: reloadToken, loading: $loading, failed: $failed)
                .ignoresSafeArea(edges: .bottom)
            if loading && failed == nil {
                ProgressView().tint(Color(hex: 0x2B6BFF)).scaleEffect(1.2)
            }
            if let failed {
                VStack(spacing: 14) {
                    Text("Can't reach Prism").font(.system(size: 20, weight: .semibold)).foregroundColor(Color(hex: 0x0B1A3A))
                    Text(failed).font(.system(size: 15)).foregroundColor(Color(hex: 0x4A5B7E))
                        .multilineTextAlignment(.center).padding(.horizontal, 32)
                    Button {
                        self.failed = nil; loading = true; reloadToken += 1
                    } label: {
                        Text("Try again").font(.system(size: 17, weight: .semibold)).foregroundColor(.white)
                            .frame(width: 200, height: 50)
                            .background(Capsule().fill(LinearGradient(colors: [Color(hex: 0x2B6BFF), Color(hex: 0x1FA8E8)],
                                                                      startPoint: .leading, endPoint: .trailing)))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.white.ignoresSafeArea())
            }
        }
        .preferredColorScheme(.light)
    }
}

struct PrismWebView: UIViewRepresentable {
    var reloadToken: Int
    @Binding var loading: Bool
    @Binding var failed: String?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.websiteDataStore = .default()          // keeps Early Access, name and market on the device
        config.applicationNameForUserAgent = "LegacyPrismApp/1.0"
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.uiDelegate = context.coordinator
        web.allowsBackForwardNavigationGestures = true
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.isOpaque = false
        web.backgroundColor = .white
        web.scrollView.backgroundColor = .white
        let refresh = UIRefreshControl()
        refresh.addTarget(context.coordinator, action: #selector(Coordinator.pulled(_:)), for: .valueChanged)
        web.scrollView.refreshControl = refresh
        if #available(iOS 16.4, *) { web.isInspectable = true }
        context.coordinator.lastToken = reloadToken
        EventLog.shared.log(.jobStart, "prism_web_load", payload: ["url": PrismWeb.url.absoluteString])
        web.load(URLRequest(url: PrismWeb.url))
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        if context.coordinator.lastToken != reloadToken {
            context.coordinator.lastToken = reloadToken
            EventLog.shared.log(.retry, "prism_web_reload")
            web.load(URLRequest(url: PrismWeb.url))
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let parent: PrismWebView
        var lastToken = 0
        init(_ parent: PrismWebView) { self.parent = parent }

        @objc func pulled(_ sender: UIRefreshControl) {
            (sender.superview?.superview as? WKWebView)?.reload()
            EventLog.shared.log(.action, "prism_web_pull_refresh")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { sender.endRefreshing() }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.loading = false
            parent.failed = nil
            EventLog.shared.log(.jobEnd, "prism_web_load", status: "ok", payload: ["url": webView.url?.absoluteString ?? ""])
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { fail(error) }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { fail(error) }

        private func fail(_ error: Error) {
            let ns = error as NSError
            if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return }
            parent.loading = false
            parent.failed = ns.localizedDescription
            EventLog.shared.log(.error, "prism_web_load", status: "failed",
                                errorCode: "\(ns.domain):\(ns.code)", errorMessage: ns.localizedDescription)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            EventLog.shared.log(.error, "prism_web_process_terminated")
            webView.reload()
        }

        /// Prism pages stay in the app; app links (sms:, mailto:, wa.me, LINE,
        /// Instagram, Telegram, Viber, KakaoTalk...) open the real app.
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url else { return decisionHandler(.allow) }
            let scheme = url.scheme?.lowercased() ?? ""
            let isWeb = scheme == "http" || scheme == "https"
            let stays = isWeb && (url.host == PrismWeb.host || url.host?.hasSuffix(".supabase.co") == true
                                  || url.host?.hasSuffix("sslip.io") == true || action.targetFrame?.isMainFrame == false)
            if scheme == "about" || scheme == "blob" || scheme == "data" || stays {
                return decisionHandler(.allow)
            }
            EventLog.shared.log(.action, "prism_web_open_external", payload: ["scheme": scheme, "host": url.host ?? ""])
            UIApplication.shared.open(url)
            decisionHandler(.cancel)
        }

        /// target=_blank links and window.open: same external hand-off.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = action.request.url {
                if url.host == PrismWeb.host { webView.load(action.request) } else { UIApplication.shared.open(url) }
                EventLog.shared.log(.action, "prism_web_new_window", payload: ["host": url.host ?? ""])
            }
            return nil
        }

        /// Microphone (voice memos) and camera for Prism's own pages only.
        @available(iOS 15.0, *)
        func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                     initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                     decisionHandler: @escaping (WKPermissionDecision) -> Void) {
            let ok = origin.host == PrismWeb.host
            EventLog.shared.log(.action, "prism_web_media_permission", status: ok ? "granted" : "denied",
                                payload: ["host": origin.host])
            decisionHandler(ok ? .grant : .deny)
        }

        // JS alert / confirm / prompt (used for "Your first name").
        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
            present(UIAlertController(title: nil, message: message, preferredStyle: .alert), webView) { a in
                a.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
            } fallback: { completionHandler() }
        }

        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
            present(UIAlertController(title: nil, message: message, preferredStyle: .alert), webView) { a in
                a.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(false) })
                a.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) })
            } fallback: { completionHandler(false) }
        }

        func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
            let a = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
            a.addTextField { $0.text = defaultText; $0.autocapitalizationType = .words }
            present(a, webView) { a in
                a.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(nil) })
                a.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(a.textFields?.first?.text) })
            } fallback: { completionHandler(nil) }
        }

        private func present(_ a: UIAlertController, _ web: WKWebView,
                             configure: (UIAlertController) -> Void, fallback: () -> Void) {
            configure(a)
            var top = web.window?.rootViewController
            while let p = top?.presentedViewController { top = p }
            guard let top else { return fallback() }
            top.present(a, animated: true)
        }
    }
}
