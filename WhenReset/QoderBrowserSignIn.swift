import SwiftUI
import WebKit

struct QoderBrowserRequest: Identifiable {
    let site: QoderSite
    var id: String { site.rawValue }
}

/// In-app sign-in for one Qoder site. The web view's cookie store is not
/// Safari's, and it is discarded with the view. The session that leaves here
/// is the cookie header for the chosen host only.
struct QoderBrowserSignInView: View {
    let site: QoderSite
    let onSession: (String) -> Void
    let onCancel: () -> Void
    @State private var status: String?
    @State private var finishToken = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                QoderSignInWebView(
                    site: site,
                    finishToken: finishToken,
                    status: $status,
                    onSession: onSession
                )
                if let status {
                    Text(status)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity)
                        .background(.bar)
                }
            }
            .navigationTitle("Sign in to Qoder")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { finishToken += 1 }
                }
            }
        }
#if os(macOS)
        .frame(minWidth: 520, minHeight: 680)
#endif
    }
}

#if os(iOS)
private struct QoderSignInWebView: UIViewRepresentable {
    let site: QoderSite
    let finishToken: Int
    @Binding var status: String?
    let onSession: (String) -> Void

    func makeCoordinator() -> QoderSignInWebCoordinator {
        QoderSignInWebCoordinator(site: site, onSession: onSession)
    }

    func makeUIView(context: Context) -> WKWebView {
        context.coordinator.makeWebView()
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.update(finishToken: finishToken, status: $status, onSession: onSession, webView: webView)
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: QoderSignInWebCoordinator) {
        coordinator.teardown(webView)
    }
}
#else
private struct QoderSignInWebView: NSViewRepresentable {
    let site: QoderSite
    let finishToken: Int
    @Binding var status: String?
    let onSession: (String) -> Void

    func makeCoordinator() -> QoderSignInWebCoordinator {
        QoderSignInWebCoordinator(site: site, onSession: onSession)
    }

    func makeNSView(context: Context) -> WKWebView {
        context.coordinator.makeWebView()
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.update(finishToken: finishToken, status: $status, onSession: onSession, webView: webView)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: QoderSignInWebCoordinator) {
        coordinator.teardown(webView)
    }
}
#endif

@MainActor
final class QoderSignInWebCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKHTTPCookieStoreObserver {
    private let site: QoderSite
    private var onSession: (String) -> Void
    private var status: Binding<String?>?
    private var finishToken = 0
    private var didCapture = false
    private var cancelled = false
    private var harvestTask: Task<Void, Never>?
    private var urlObservation: NSKeyValueObservation?
    private weak var cookieStore: WKHTTPCookieStore?
    private weak var webView: WKWebView?
    private var harvestGeneration = 0

    init(site: QoderSite, onSession: @escaping (String) -> Void) {
        self.site = site
        self.onSession = onSession
    }

    func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        let store = configuration.websiteDataStore.httpCookieStore
        store.add(self)
        cookieStore = store
        self.webView = webView
        urlObservation = webView.observe(\.url, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in
                self?.scheduleHarvest(reportFailure: false)
            }
        }
        webView.load(URLRequest(url: site.signInURL))
        return webView
    }

    func update(finishToken: Int, status: Binding<String?>, onSession: @escaping (String) -> Void, webView: WKWebView) {
        self.onSession = onSession
        self.status = status
        guard finishToken != self.finishToken else { return }
        self.finishToken = finishToken
        guard finishToken > 0 else { return }
        harvest(from: webView, reportFailure: true)
    }

    func cookiesDidChange(in _: WKHTTPCookieStore) {
        guard !didCapture else { return }
        scheduleHarvest(reportFailure: false)
    }

    func teardown(_ webView: WKWebView) {
        cancelled = true
        harvestTask?.cancel()
        urlObservation?.invalidate()
        urlObservation = nil
        cookieStore?.remove(self)
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.stopLoading()
    }

    func webView(_: WKWebView, didStartProvisionalNavigation _: WKNavigation!) {
        status?.wrappedValue = nil
    }

    func webView(_: WKWebView, didFinish _: WKNavigation!) {
        scheduleHarvest(reportFailure: false)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        let scheme = navigationAction.request.url?.scheme?.lowercased()
        switch scheme {
        case nil, "http", "https", "about", "blob", "data":
            decisionHandler(.allow)
        default:
            decisionHandler(.cancel)
        }
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith _: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures _: WKWindowFeatures
    ) -> WKWebView? {
        if navigationAction.targetFrame == nil {
            webView.load(navigationAction.request)
        }
        return nil
    }

    private func scheduleHarvest(reportFailure: Bool) {
        harvestTask?.cancel()
        harvestTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled, let webView = self.webView else { return }
            self.harvest(from: webView, reportFailure: reportFailure)
        }
    }

    private func harvest(from webView: WKWebView, reportFailure: Bool) {
        guard !cancelled, !didCapture else { return }
        guard let url = webView.url, QoderBrowserSession.isSignedInAccountPage(url, site: site) else {
            if reportFailure {
                status?.wrappedValue = String.localized(
                    "Sign in on this page first. Blinky continues when the account usage page opens."
                )
            }
            return
        }
        harvestGeneration += 1
        let generation = harvestGeneration
        let site = self.site
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            let header: String?
            let failure: String?
            do {
                header = try QoderBrowserSession.header(from: cookies, site: site)
                failure = nil
            } catch {
                header = nil
                failure = error.localizedDescription
            }
            Task { @MainActor in
                guard let self, self.harvestGeneration == generation, !self.cancelled, !self.didCapture else { return }
                guard let current = self.webView?.url, QoderBrowserSession.isSignedInAccountPage(current, site: site) else {
                    return
                }
                if let header {
                    self.didCapture = true
                    self.onSession(header)
                } else if reportFailure {
                    self.status?.wrappedValue = failure
                }
            }
        }
    }
}
