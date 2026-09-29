import SwiftUI
import WebKit
import os

private let log = Logger(subsystem: "com.agartner.streamlink", category: "WebView")

/// A WKWebView backed by the shared persistent cookie store, so a Twitch login
/// performed in any instance (chat or the dedicated login page) persists and its
/// `auth-token` cookie is available to `TwitchAuth`.
struct WebView: UIViewRepresentable {
    let url: URL
    /// Load BetterTTV (emotes, chat enhancements) into Twitch pages.
    var betterTTV = false
    /// Pin the page in place: for full-height layouts (Twitch popout chat) that
    /// scroll internally, so WebKit's own scroll view never needs to move.
    var fixedViewport = false

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.websiteDataStore = .default()   // persistent, shared cookie store
        config.applicationNameForUserAgent = TwitchAPI.safariApplicationName   // same "Safari" as our API calls
        if betterTTV {
            config.userContentController.addUserScript(WKUserScript(
                source: Self.betterTTVLoaderJS, injectionTime: .atDocumentEnd,
                forMainFrameOnly: true))
        }
        if fixedViewport {
            config.userContentController.addUserScript(WKUserScript(
                source: Self.chatInputAboveOverlaysJS, injectionTime: .atDocumentEnd,
                forMainFrameOnly: true))
            if !ProcessInfo.processInfo.isiOSAppOnMac {   // no on-screen keyboard on a Mac
                config.userContentController.addUserScript(WKUserScript(
                    source: Self.noPickerAutofocusJS, injectionTime: .atDocumentStart,
                    forMainFrameOnly: true))
            }
        }
        if ProcessInfo.processInfo.isiOSAppOnMac {
            // WebKit derives the text input traits from the focused element, and
            // with autocorrect/suggestions on, the shortcuts bar shows predictions.
            config.userContentController.addUserScript(WKUserScript(
                source: Self.disableSuggestionsJS, injectionTime: .atDocumentStart,
                forMainFrameOnly: false))
        }
        #if DEBUG
        if DebugServer.enabled {
            config.userContentController.addUserScript(WKUserScript(
                source: DebugServer.consoleHookJS, injectionTime: .atDocumentStart,
                forMainFrameOnly: true))
            config.userContentController.addUserScript(WKUserScript(
                source: DebugServer.focusTraceJS, injectionTime: .atDocumentStart,
                forMainFrameOnly: true))
            config.userContentController.add(DebugLogHandler(), name: "debugLog")
        }
        #endif
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.scrollView.backgroundColor = .clear
        webView.uiDelegate = context.coordinator
        if fixedViewport {
            // When the keyboard shows, WebKit scrolls its scroll view to reveal the
            // focused input and adds a keyboard-sized bottom inset — on top of the
            // chat we already shrink above the keyboard, so the page could be
            // dragged ~90% off screen. Keep it pinned at the origin instead.
            let scrollView = webView.scrollView
            scrollView.isScrollEnabled = false
            scrollView.bounces = false
            scrollView.contentInsetAdjustmentBehavior = .never
            context.coordinator.offsetObservation = scrollView.observe(\.contentOffset) { sv, _ in
                if sv.contentOffset != .zero { sv.contentOffset = .zero }
            }
        }
        if ProcessInfo.processInfo.isiOSAppOnMac {
            // The form accessory bar (prev/next/Done) normally rides on the
            // on-screen keyboard; on a Mac it pops up alone at the window bottom.
            // Likewise the iPad shortcuts bar (undo/redo/paste + predictions),
            // which spans the whole bottom of the screen on a Mac.
            webView.hideInputBars()
        } else if fixedViewport {
            // On a phone the prev/next/Done bar just eats chat height above the
            // keyboard; the keyboard itself (and its shortcuts bar) stays.
            webView.hideInputBars(accessoryOnly: true)
        }
        #if DEBUG
        // Chat only: the login sheet's webview would steal the target and then
        // go away when the sheet closes.
        if DebugServer.enabled, fixedViewport { DebugServer.shared.attach(webView) }
        #endif
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        if webView.url != url {
            webView.load(URLRequest(url: url))
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// The BetterTTV userscript's loader: pull the hosted production build into
    /// Twitch pages (it keeps itself up to date, like the browser extension).
    private static let betterTTVLoaderJS = """
    (function () {
      if (!/(^|\\.)twitch\\.tv$/.test(location.hostname) || window.__bttvInjected) return;
      window.__bttvInjected = true;
      var script = document.createElement('script');
      script.src = 'https://cdn.betterttv.net/betterttv.js';
      (document.head || document.documentElement).appendChild(script);
    })();
    """

    /// Popups anchored to the chat input (the emote picker) live in its
    /// `z-index: 1` layer, so overlays in the message list — drop/sub banners,
    /// pinned messages — painted over them and hid the picker's search bar.
    /// Lift the whole input layer above the message list.
    private static let chatInputAboveOverlaysJS = """
    (function () {
      if (!/(^|\\.)twitch\\.tv$/.test(location.hostname)) return;
      var style = document.createElement('style');
      style.textContent = '.chat-input { position: relative; z-index: 10; }';
      (document.head || document.documentElement).appendChild(style);
    })();
    """

    /// Emote pickers (Twitch's and BetterTTV's) focus the search box when they
    /// open and the chat input when an emote is picked. On a phone that brings
    /// up the keyboard, which collapses the video and resizes chat under the
    /// picker (and BetterTTV closes its menu once focus leaves it). So right
    /// after a tap, `focus()` on a field other than the one tapped is skipped;
    /// any focus that still lands on such a field gets `inputmode="none"` (set
    /// in capturing `focusin`, before WebKit reads the traits) — no keyboard.
    /// Tapping the field drops that and refocuses it with the keyboard.
    private static let noPickerAutofocusJS = """
    (function () {
      if (!/(^|\\.)twitch\\.tv$/.test(location.hostname)) return;
      var marked = null;   // the field currently focused without a keyboard
      var tapTarget = null, tapTime = 0;
      var typingIn = null; // at the last tap, the field the keyboard was up for
      // BetterTTV's emote menu uses a closed shadow root; opening it lets us see
      // (via composedPath) which field inside gets focus. This opens every
      // closed root on twitch.tv, but BetterTTV's is the only one on the page.
      var attachShadow = Element.prototype.attachShadow;
      Element.prototype.attachShadow = function (init) {
        return attachShadow.call(this, Object.assign({}, init, { mode: 'open' }));
      };
      function target(e) { return e.composedPath ? e.composedPath()[0] : e.target; }
      function editable(el) {
        return el.isContentEditable || /^(INPUT|TEXTAREA)$/.test(el.tagName);
      }
      // The tap was on the field, inside it, or on a wrapper around it.
      function tapped(el) {
        return tapTarget && tapTarget.contains && (el.contains(tapTarget) || tapTarget.contains(el));
      }
      function unmark() {
        if (marked) { marked.removeAttribute('inputmode'); marked = null; }
      }
      function deepActive() {
        var a = document.activeElement;
        while (a && a.shadowRoot && a.shadowRoot.activeElement) a = a.shadowRoot.activeElement;
        return a;
      }
      // Right after a tap elsewhere, unless it's the field the keyboard was
      // already up for (e.g. Send refocusing the input mid-conversation).
      function suppress(el) {
        return el !== typingIn && tapTarget && Date.now() - tapTime < 1000 && !tapped(el);
      }
      // BetterTTV closes its menu after each emote unless Shift is held, which
      // a phone can't do. Its keyup handler only records modifier state, so a
      // synthetic Shift keyup around the tap keeps the menu open (and skips
      // focusing the input); a plain keyup after the click resets it.
      function bttvShift(el, down) {
        el.dispatchEvent(new KeyboardEvent('keyup', {
          key: 'Shift', shiftKey: down, bubbles: true, composed: true }));
      }
      function bttvEmote(el) {
        return el.closest && el.closest('[class*="bttv-EmoteMenu-module__"]') &&
          el.closest('[class*="bttv-Emote-module__"]');
      }
      document.addEventListener('click', function (e) {
        var el = target(e);
        if (bttvEmote(el)) setTimeout(function () { if (el.isConnected) bttvShift(el, false); }, 0);
      }, true);
      document.addEventListener('pointerdown', function (e) {
        var active = deepActive();
        typingIn = active && active.getAttribute && editable(active) && active !== marked ? active : null;
        tapTarget = target(e); tapTime = Date.now();
        if (bttvEmote(tapTarget)) bttvShift(tapTarget, true);
        if (marked && tapped(marked)) {
          // A real tap on the keyboard-less field: let this tap focus it normally.
          var field = marked;
          unmark();
          field.blur();
        }
      }, true);
      var focus = HTMLElement.prototype.focus;
      HTMLElement.prototype.focus = function () {
        if (editable(this) && suppress(this)) return;
        return focus.apply(this, arguments);
      };
      document.addEventListener('focusin', function (e) {
        var el = target(e);
        if (!el.getAttribute || !editable(el) || el === marked) return;
        if (el !== typingIn && !(tapped(el) && Date.now() - tapTime < 1000)) {
          unmark();
          el.setAttribute('inputmode', 'none');
          marked = el;
        }
      }, true);
      // Only for this focus: a later tap-less focus is judged afresh.
      document.addEventListener('focusout', function (e) {
        if (target(e) === marked) unmark();
      }, true);
    })();
    """

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
        var offsetObservation: NSKeyValueObservation?

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
    /// `inputAccessoryView` and — unless `accessoryOnly` — an empty
    /// `inputAssistantItem` and an empty `inputView`. There's no public API to
    /// drop these bars.
    func hideInputBars(accessoryOnly: Bool = false) {
        if !accessoryOnly { WKWebView.patchFloatingAssistantPadding() }
        guard let contentView = scrollView.subviews.first(where: {
            String(describing: type(of: $0)).hasPrefix("WKContent")
        }), let baseClass = object_getClass(contentView) else {
            log.error("hideInputBars: WKContentView not found")
            return
        }

        let name = "\(NSStringFromClass(baseClass))_\(accessoryOnly ? "NoAccessory" : "NoInputBars")"
        var subclass: AnyClass? = NSClassFromString(name)
        if subclass == nil, let newClass = objc_allocateClassPair(baseClass, name, 0) {
            let noAccessory: @convention(block) (AnyObject) -> UIView? = { _ in nil }
            let emptyAssistant: @convention(block) (AnyObject) -> UITextInputAssistantItem = { _ in
                WKWebView.emptyAssistantItem
            }
            let emptyInput: @convention(block) (AnyObject) -> UIView? = { _ in
                WKWebView.emptyInputView
            }
            var overrides: [(Selector, AnyObject)] = [
                (#selector(getter: UIResponder.inputAccessoryView), noAccessory as AnyObject),
            ]
            if !accessoryOnly {
                overrides += [
                    (#selector(getter: UIResponder.inputView), emptyInput as AnyObject),
                    (#selector(getter: UIResponder.inputAssistantItem), emptyAssistant as AnyObject),
                ]
            }
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
