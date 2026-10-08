//
// Copyright 2026 Wild Dolphin
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI
import WebKit

/// Full-screen WebRTC call into rtc.wilddolphin.us for a built-in test contact.
final class GatewayCallViewController: OWSViewController, WKUIDelegate, WKNavigationDelegate {
    private let contact: SignalGatewayContacts.Contact
    private let withVideo: Bool
    private var webView: WKWebView!

    init(contact: SignalGatewayContacts.Contact, withVideo: Bool) {
        self.contact = contact
        self.withVideo = withVideo || contact.wantsVideo
        super.init()
        modalPresentationStyle = .fullScreen
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsAirPlayForMediaPlayback = false

        webView = WKWebView(frame: .zero, configuration: config)
        webView.uiDelegate = self
        webView.navigationDelegate = self
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)

        let hangup = UIButton(type: .system)
        hangup.setTitle(OWSLocalizedString(
            "CALL_VIEW_HANGUP_LABEL",
            comment: "Label to display on the button which hangs up a gateway test call.",
        ), for: .normal)
        hangup.setTitleColor(.white, for: .normal)
        hangup.backgroundColor = UIColor(red: 0.90, green: 0.28, blue: 0.30, alpha: 1)
        hangup.layer.cornerRadius = 24
        hangup.ows_contentEdgeInsets = UIEdgeInsets(top: 12, leading: 28, bottom: 12, trailing: 28)
        hangup.addTarget(self, action: #selector(hangUp), for: .touchUpInside)
        hangup.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hangup)

        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            hangup.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            hangup.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
        ])

        var components = URLComponents(url: contact.callURL, resolvingAgainstBaseURL: false)
        var items = components?.queryItems ?? []
        items.removeAll { $0.name == "video" }
        items.append(URLQueryItem(name: "video", value: withVideo ? "1" : "0"))
        components?.queryItems = items
        if let url = components?.url {
            webView.load(URLRequest(url: url))
        }
    }

    @objc
    private func hangUp() {
        dismiss(animated: true)
    }

    func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping (WKPermissionDecision) -> Void,
    ) {
        decisionHandler(.grant)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        presentError(error.localizedDescription)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        presentError(error.localizedDescription)
    }

    private func presentError(_ message: String) {
        OWSActionSheets.showActionSheet(
            title: contact.displayName,
            message: message,
            fromViewController: self,
        )
    }
}
