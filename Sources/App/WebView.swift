import SwiftUI
import WebKit
import os

private let log = Logger(subsystem: "com.agartner.streamlink", category: "WebView")

/// A WKWebView backed by the shared persistent cookie store, so a Twitch login
/// performed in any instance (chat or the dedicated login page) persists and its
/// `auth-token` cookie is available to `TwitchAuth`.
struct WebView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.websiteDataStore = .default()   // persistent, shared cookie store
        if ProcessInfo.processInfo.isiOSAppOnMac {
            // WebKit derives the text input traits from the focused element, and
            // with autocorrect/suggestions on, the shortcuts bar shows predictions.
            config.userContentController.addUserScript(WKUserScript(
                source: Self.disableSuggestionsJS, injectionTime: .atDocumentStart,
                forMainFrameOnly: false))
        }
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.scrollView.backgroundColor = .clear
        webView.uiDelegate = context.coordinator
        if ProcessInfo.processInfo.isiOSAppOnMac {
            // The form accessory bar (prev/next/Done) normally rides on the
            // on-screen keyboard; on a Mac it pops up alone at the window bottom.
            // Likewise the iPad shortcuts bar (undo/redo/paste + predictions),
            // which spans the whole bottom of the screen on a Mac.
            webView.hideInputBars()
        }
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        if webView.url != url {
            webView.load(URLRequest(url: url))
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Turn off autocorrect/spellcheck/suggestions on whatever gets focus (Twitch
    /// chat is a contenteditable), capturing before WebKit reads the traits.
    private static let disableSuggestionsJS = """
    document.addEventListener('focusin', function (e) {
      for (var el = e.target; el && el.setAttribute; el = el.parentElement) {
        el.setAttribute('autocorrect', 'off');
        el.setAttribute('autocapitalize', 'off');
        el.setAttribute('spellcheck', 'false');
        el.setAttribute('writingsuggestions', 'false');
        el.setAttribute('autocomplete', 'off');
        if (!el.parentElement || !el.parentElement.isContentEditable) break;
      }
    }, true);
    """

    final class Coordinator: NSObject, WKUIDelegate {
        /// Load target=_blank links (e.g. a login popup) in the same webview
        /// instead of silently dropping them.
        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if navigationAction.targetFrame == nil {
                webView.load(navigationAction.request)
            }
            return nil
        }
    }
}

private extension WKWebView {
    /// Shared, permanently empty assistant item: no shortcut groups means the
    /// shortcuts bar has nothing to show.
    static let emptyAssistantItem: UITextInputAssistantItem = {
        let item = UITextInputAssistantItem()
        item.leadingBarButtonGroups = []
        item.trailingBarButtonGroups = []
        item.allowsHidingShortcuts = true
        return item
    }()

    /// Zero-height stand-in keyboard. With a custom `inputView` UIKit doesn't
    /// bring up the system keyboard — and the shortcuts bar rides on that, even
    /// when empty. Hardware key presses still go to the responder.
    static let emptyInputView: UIView = {
        let view = UIView(frame: .zero)
        view.autoresizingMask = []
        return view
    }()

    /// With a custom `inputView`, UIKit on macOS sizes the input window via
    /// `+[UISystemInputAssistantViewController floatingAssistantBottomPadding]`,
    /// which the Mac UIKit doesn't implement — an uncaught unrecognized-selector
    /// crash while typing. Supply it (0 padding) only if it's missing.
    static func patchFloatingAssistantPadding() {
        let sel = NSSelectorFromString("floatingAssistantBottomPadding")
        guard let cls = NSClassFromString("UISystemInputAssistantViewController"),
              let meta = object_getClass(cls),
              class_getClassMethod(cls, sel) == nil else { return }
        let zero: @convention(block) (AnyObject) -> CGFloat = { _ in 0 }
        class_addMethod(meta, sel, imp_implementationWithBlock(zero), "d@:")
        log.notice("patched +floatingAssistantBottomPadding")
    }

    /// Swap WebKit's private content view for a runtime subclass with no
    /// `inputAccessoryView`, an empty `inputAssistantItem` and an empty
    /// `inputView`. There's no public API to drop these bars.
    func hideInputBars() {
        WKWebView.patchFloatingAssistantPadding()
        guard let contentView = scrollView.subviews.first(where: {
            String(describing: type(of: $0)).hasPrefix("WKContent")
        }), let baseClass = object_getClass(contentView) else {
            log.error("hideInputBars: WKContentView not found")
            return
        }

        let name = "\(NSStringFromClass(baseClass))_NoInputBars"
        var subclass: AnyClass? = NSClassFromString(name)
        if subclass == nil, let newClass = objc_allocateClassPair(baseClass, name, 0) {
            let noAccessory: @convention(block) (AnyObject) -> UIView? = { _ in nil }
            let emptyAssistant: @convention(block) (AnyObject) -> UITextInputAssistantItem = { _ in
                WKWebView.emptyAssistantItem
            }
            let emptyInput: @convention(block) (AnyObject) -> UIView? = { _ in
                WKWebView.emptyInputView
            }
            let overrides: [(Selector, AnyObject)] = [
                (#selector(getter: UIResponder.inputView), emptyInput as AnyObject),
                (#selector(getter: UIResponder.inputAccessoryView), noAccessory as AnyObject),
                (#selector(getter: UIResponder.inputAssistantItem), emptyAssistant as AnyObject),
            ]
            for (sel, block) in overrides {
                if let method = class_getInstanceMethod(UIView.self, sel) {
                    class_addMethod(newClass, sel, imp_implementationWithBlock(block),
                                    method_getTypeEncoding(method))
                }
            }
            objc_registerClassPair(newClass)
            subclass = newClass
        }
        if let subclass {
            object_setClass(contentView, subclass)
            log.notice("hideInputBars: patched \(NSStringFromClass(baseClass), privacy: .public)")
        }
    }
}

/// Full-page Twitch login, opened from the info panel. On dismissal the caller
/// re-reads the auth token from the shared cookie store.
struct TwitchLoginView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            WebView(url: URL(string: "https://www.twitch.tv/login")!)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("Twitch Login")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { dismiss() }
                    }
                }
        }
    }
}
