# Migrating HTML Output from WebView to WKWebView

Status: plan, nothing implemented yet.

The HTML output view (`OakHTMLOutputView`, used for bundle commands with HTML output) is built on the legacy `WebView`, deprecated since macOS 10.14 and responsible for 73 of the remaining deprecation warnings. This document describes what has to change, what bundles depend on, the risks, and the order of work.

## Current Architecture

| Piece | File | What it does |
|---|---|---|
| Output view | `src/OakHTMLOutputView.mm` | Loads command output, injects the `TextMate` JavaScript object, handles `txmt://` links, printing, stop/reload. |
| Browser view | `src/browser/HOBrowserView.mm` | Owns the `WebView` and status bar, progress, swipe back/forward, key event handling. |
| Delegate helper | `src/browser/HOWebViewDelegateHelper.mm` | `alert`/`confirm`, file upload, new windows, `window.close()`, link hover status text, console logging, rewriting `tm-file://`, protocol-relative, and directory URLs. |
| JavaScript bridge | `src/helpers/HOJSBridge.mm` | The `TextMate` object: `system()`, `log()`, `open()`, `isBusy`, `progress`. |
| Auto scroll | `src/helpers/HOAutoScroll.mm` | Keeps the view scrolled to the bottom while output streams in. |
| Find, view source | `src/helpers/WebView Additions.mm` | Find next/previous, copy selection to find pasteboard, View Source. |
| Output stream | `Frameworks/OakCommand/src/OakCommand.mm` | Writes command output to a pipe, served by `OakFileHandleURLProtocol` (an `NSURLProtocol`) as `x-txmt-filehandle://job/<name>/<n>`. Request properties carry the command, process ID, and name. |
| HTML tooltips | `PlugIns/dialog/Commands/tooltip/TMDHTMLTips.mm` | Separate `WebView` in the Dialog2 plug-in (a submodule of textmate/dialog). |

## What Must Keep Working

Survey of the bundles installed in `~/Library/Application Support/TextMate/Managed/Bundles`:

| JavaScript API | Uses | Bundles |
|---|---|---|
| `TextMate.system(cmd, null)` — synchronous | 22 | Bundle Support, Git, Mercurial, PHP, Python, Ruby, SQL, Subversion |
| `TextMate.system(cmd, handler)` — asynchronous | 28 | same 8 bundles |
| `.outputString` on the result | 18 | 7 bundles |
| `onreadoutput` / `onreaderror` | 8 | Mercurial, Subversion |
| `TextMate.isBusy = …` | 41 | Mercurial, PHP, Ruby, SQL, Subversion |
| `TextMate.log()` | 3 | PHP |
| `TextMate.progress`, `TextMate.open()` | 0 | — |
| `file://` / `tm-file://` in `src`/`href` of generated HTML | 7 files | Bundle Support, Diff, Markdown, Python, SQL |

Two requirements follow that `WKWebView` does not support directly:

1. **Synchronous `TextMate.system()`**: `WKWebView` has no synchronous bridge from JavaScript to native code.
2. **Command output loading `file://` resources**: output is served from a custom scheme, and `WebView` allowed it to load local stylesheets, scripts, and images because the scheme was registered with `registerURLSchemeAsLocal:`. `WKWebView` has no public equivalent, and it does not allow handling the `file` scheme with a `WKURLSchemeHandler`.

## API Mapping

| Legacy | WKWebView |
|---|---|
| `NSURLProtocol` for `x-txmt-filehandle` | `WKURLSchemeHandler`: `didReceiveResponse:`, then `didReceiveData:` per chunk (streaming works), `didFinish`. `stopURLSchemeTask:` kills the process group. |
| Request properties (`command`, `processIdentifier`, …) | Not passed through the web process. Keep a table from the (already unique) URL to the command. |
| `tm-file://` rewritten to `file://` | `WKURLSchemeHandler` for `tm-file` that serves files from disk, including the `index.html` and not-found handling. |
| Protocol-relative URLs (`x-txmt-…://example.com`) | Navigation: rewrite in `decidePolicyForNavigationAction:`. Subresources: the scheme handler fetches them over `https` (no public redirect API for scheme tasks). |
| `didClearWindowObject:` + `WebScriptObject` | `WKUserScript` at document start defining `TextMate` in JavaScript, plus `WKScriptMessageHandlerWithReply` (macOS 11) for calls into native code. |
| Asynchronous `system()` and live `outputString` | JavaScript object keeps state; native code pushes output/exit events with `evaluateJavaScript:` and receives `write`/`close`/`cancel` as messages. |
| Synchronous `system()` | See Spike 2. |
| `isBusy`, `progress` setters | JavaScript setters that post messages to update the status bar. |
| `decidePolicyForNavigationAction:` (`txmt://`, external URLs) | `WKNavigationDelegate` `decidePolicyForNavigationAction:decisionHandler:`. |
| `alert`, `confirm`, file upload, new windows, `window.close()` | `WKUIDelegate` equivalents (`runJavaScriptAlertPanel…`, `runOpenPanelWithParameters…`, `createWebViewWithConfiguration…`, `webViewDidClose:`). |
| Link hover status text (`mouseDidMoveOverElement:`) | No API. Injected script listening for `mouseover` on links posts the URL. |
| Console logging (undocumented `addMessageToConsole:`) | Injected script wrapping `console.*` and `window.onerror`. |
| Progress notifications | KVO on `estimatedProgress`, `loading`, `title`, `canGoBack`, `canGoForward`. |
| `HOAutoScroll` (observes the document view frame) | Injected script: `ResizeObserver` on the body, scroll to bottom if the user was at the bottom. |
| Restoring scroll position after `setContent:` | Save `scrollY` with `evaluateJavaScript:` before, restore after `didFinishNavigation:`. |
| `searchFor:direction:caseSensitive:wrap:` | `findString:withConfiguration:completionHandler:` (`WKFindConfiguration`, macOS 11). |
| Selection for the find pasteboard | `evaluateJavaScript:@"getSelection().toString()"` (asynchronous). |
| View Source (`dataSource.data`) | Keep a copy of the streamed output in the scheme handler. For other pages, re-fetch the URL (or fall back to `outerHTML`). |
| Printing via the frame view | `printOperationWithPrintInfo:` (macOS 11). |
| Swipe back/forward | `allowsBackForwardNavigationGestures`. |
| `needsNewWebView` (WebKit bug 121232) | Verify whether still needed; likely removable. |

## Risks and Spikes

Each spike is a small prototype that answers one question before committing to the design.

**Spike 1: `file://` resources from command output (highest risk).**
Question: can a page served by a `WKURLSchemeHandler` load `file://` stylesheets, scripts, and images?
Candidates, in order of preference:
1. It works with public API (e.g. with `allowFileAccessFromFileURLs`-style preferences); verify.
2. The scheme handler rewrites `file://` and `tm-file://` URLs in `src`/`href` attributes of the streamed HTML to a custom scheme it also serves. Risk: HTML is streamed in arbitrary chunks, so the rewriter must handle URLs split across chunks, and must leave text content alone.
3. Private SPI to register the scheme as local. Works but can break with any macOS update; only as a last resort.
Also check `file://` references created at runtime by JavaScript (e.g. `img.src = …`), which option 2 would miss.

**Spike 2: synchronous `TextMate.system()`.**
Plan: implement the synchronous form with `prompt()` (JavaScript blocks, and `WKUIDelegate`'s `runJavaScriptTextInputPanelWithPrompt:…completionHandler:` replies when the command finishes). The prompt text carries a marker so real `prompt()` calls still show a panel. Alternative: synchronous `XMLHttpRequest` to a custom scheme, if WebKit allows synchronous loads from scheme handlers. Verify:
- behavior when the command runs for a long time (the current 15-second “stop command?” alert should keep working),
- that the app stays responsive while a page is blocked (it should: the page runs in a separate process),
- `outputString` and `status` are available on the returned object.

**Spike 3: streaming.**
Verify that a `WKURLSchemeHandler` response is rendered incrementally while data arrives (it should be, for `text/html` with unknown length), and measure against the current view with a command that prints output slowly.

**Security.** The `TextMate` object can run shell commands, so it must only be available to command output and local files, as today (checked in `didClearWindowObject:`). With `WKWebView` the user script is injected into every page, so the message handlers must check the frame’s origin (`WKScriptMessage.frameInfo`) and ignore messages from any other scheme, and `disableJavaScriptAPI` must remove the script before loading.

## Phases

Each phase is committed and pushed separately and leaves TextMate working.

1. **Spikes 1–3** as standalone test programs (not committed to the app), with results added to this document.
2. **Scheme handlers.** `WKURLSchemeHandler` for `x-txmt-filehandle` (streaming output, stop kills the process) and `tm-file`, independent of the view. Unit tests: a fake command writing to a pipe, served to a hidden `WKWebView`, checking the rendered text.
3. **JavaScript bridge.** User script with the `TextMate` object and message handlers; asynchronous and synchronous `system()`, `outputString`, `onreadoutput`/`onreaderror`, `write`/`close`/`cancel`, `isBusy`, `progress`, `log`, `open`. Tests: an HTML test page exercising every call, run in a hidden `WKWebView`, reporting results back through the bridge.
4. **Browser view.** Replace the `WebView` in `HOBrowserView` and `HOWebViewDelegateHelper`: navigation policy (`txmt://`, external links, protocol-relative URLs), UI delegate (alerts, file upload, new windows, `window.close()`), status text, console logging, progress, back/forward. Update the three `webView` uses in `OakCommand.mm`.
5. **Output view features.** Auto scroll, scroll restore for atomic updates, find, copy selection to find/replace pasteboard, View Source, printing, stop/reload with the “Stop command?” sheet.
6. **Remove the legacy code** (`OakFileHandleURLProtocol`, `HTMLTMFileDummyProtocol`, `WebView Additions.mm`, WebKit-legacy imports), and update the documentation of the JavaScript API.
7. **HTML tooltips** in the Dialog2 plug-in. Requires a fork of textmate/dialog; independent of phases 1–6.

## Testing

Automated (via `ninja HTMLOutput/test`): scheme handler streaming and stop, `tm-file` resolution (files, directories with `index.html`, missing files), and the JavaScript API test page.

Manual, with real bundles, comparing old and new builds side by side:

| Bundle / command | Exercises |
|---|---|
| Ruby → Run Script | streaming output, auto scroll, `isBusy`, `file://` stylesheet |
| Git → Log / Show Uncommitted Changes | synchronous and asynchronous `system()`, `outputString` |
| Subversion or Mercurial → Status | `onreadoutput`, `isBusy`, interactive buttons |
| Markdown → Preview | `file://` resources, links, find, printing |
| PHP → Run | `TextMate.log()` |
| Any output with `txmt://` links | opening files at a line |
| Stop a long-running command (⌘.) | stop sheet, process killed |

## Open Decisions

1. If Spike 1 only works with private API: accept it, rewrite URLs in the stream, or require bundles to switch to a custom scheme?
2. Should `TextMate.system()` in the synchronous form keep blocking the page (compatible) or also be offered as a `Promise` (new, optional API)?
3. Minimum behavior for View Source of non-command pages (original source requires re-fetching).
