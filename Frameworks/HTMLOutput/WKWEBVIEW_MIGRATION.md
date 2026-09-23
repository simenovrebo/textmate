# Migrating HTML Output from WebView to WKWebView

Status: phases 1–2 done (prototypes, scheme handlers). The handlers are not yet used by the view.

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
| Synchronous `system()` | Synchronous `XMLHttpRequest` to a custom scheme (see Prototype Results). |
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

## Prototype Results

The prototypes are standalone programs in `prototypes/` (not part of the build). Each loads real pages into an off-screen `WKWebView` and prints what it measured. Build and run with, for example:

    cp -R prototypes/res /tmp/res
    clang++ -std=c++2a -fobjc-arc -framework Cocoa -framework WebKit prototypes/spike1b.mm -o /tmp/spike1b && /tmp/spike1b /tmp/res

### 1. `file://` resources from command output — solved without private API

`spike1.mm`: a page served by a `WKURLSchemeHandler` cannot load `file://` resources, not even with the private `allowFileAccessFromFileURLs`/`allowUniversalAccessFromFileURLs` preferences. Serving the same files from a custom scheme works for stylesheets, scripts, and images (static and created from JavaScript):

| Variant | Stylesheet | Script | `<img>` | Image created by JS |
|---|---|---|---|---|
| Default configuration | blocked | blocked | error | error |
| Private file access preferences | blocked | blocked | error | error |
| Custom scheme | loaded | loaded | loaded | loaded |

How bundles reference local files (installed bundles):

- In markup: `<link href="file://…">`, `<script src="file://…">`, `<img src="file://…">` (Bundle Support’s `htmloutput.rb`, Diff, SQL, Mercurial, Git).
- `<base href="file://…">`, which makes all relative URLs local (Markdown preview, `htmloutput.rb`).
- From JavaScript: `element.src = 'file://' + …` in `webpreview.js`, which is loaded by every page using `htmloutput.rb`.
- Navigation: `window.location = "file://" + …` in inline scripts (Ruby’s `ri_to_html`, `man2html`).

`spike1b.mm` implements and verifies the design:

1. **Stream rewriter**: `file://` → `tm-file://` when in URL position, i.e. preceded by `"`, `'`, `=`, or `(`. This covers attributes, `<base>`, CSS `url(…)`, and the inline `window.location = "file://" + …` scripts, while text such as “see file://…” is left alone. It holds back up to 7 bytes at the end of a chunk, so URLs split across chunks are rewritten; verified for every combination of two split points.
2. **Injected script** (document start): rewrites `file://` values assigned to `src`/`href` of `img`, `script`, `link`, `iframe`, `source`, and in `setAttribute()`.
3. **`tm-file` scheme handler** serving files from disk (with the existing `index.html` and not-found handling).

Results: stylesheet, script, `<base>`-relative image, `img.src` and `setAttribute('src')` from JavaScript all load, text is unchanged, and navigating to the rewritten `tm-file://` URL works.

Limitation: a raw `window.location = 'file://…'` is blocked by WebKit before the navigation delegate is asked, so it cannot be intercepted. It only works when the rewriter sees it, i.e. in the streamed HTML. No installed bundle builds such a navigation in a separate `.js` file.

### 2. Synchronous `TextMate.system()` — use synchronous XHR

`spike2.mm` compares two techniques, running a command that prints to stdout and stderr, sleeps 1.5 s, and exits with 3:

| | Result | Page blocked | App main thread meanwhile |
|---|---|---|---|
| `prompt()` answered by `WKUIDelegate` | correct (UTF-8 output, stderr, status 3) | 1511 ms | kept running (15 timer ticks of 100 ms) |
| Synchronous `XMLHttpRequest` to a custom scheme | correct | 1508 ms | kept running (16 ticks) |

Both block only the page’s JavaScript, which runs in a separate process, so TextMate stays responsive. This is an improvement: today the synchronous form runs a nested run loop in TextMate itself.

Decision: **synchronous XHR** to `x-txmt-js://system`. The request carries an `Origin` header set by WebKit (`x-txmt-filehandle://job`) that page JavaScript cannot forge, so the handler can verify that the caller is command output or a local file. The `prompt()` technique (which gets the frame’s origin from `WKFrameInfo`) is the fallback should WebKit restrict synchronous XHR. A real `prompt()` still works either way.

### 3. Streaming — works, with one rule

`spike3.mm` streams 8 chunks, 300 ms apart, each with a paragraph and an inline script:

- Each chunk is rendered and its script runs as it arrives (about 315 ms apart; the first after 525 ms including web process start).
- `stopLoading` (⌘.) calls `stopURLSchemeTask:` after 7 ms, which is where the command must be killed.
- **Any call to the task after `stopURLSchemeTask:` raises `NSInternalInconsistencyException`** (“This task has already been stopped”). The handler must record that the task was stopped and never use it afterwards; unlike `NSURLProtocol`, forgetting this crashes.

### Security

The `TextMate` object can run shell commands, so it must only be available to command output and local files, as today (checked in `didClearWindowObject:`). With `WKWebView` the user script is injected into every page, so the native side checks the caller: the `Origin` header for the `x-txmt-js` scheme handler and `WKScriptMessage.frameInfo.securityOrigin` for messages, accepting only `x-txmt-filehandle` and `tm-file`. `disableJavaScriptAPI` removes the script before loading.

## Phases

Each phase is committed and pushed separately and leaves TextMate working.

1. **Prototypes** — done, see Prototype Results.
2. **Scheme handlers** — done:
   - `src/helpers/file_url_rewriter.h`: the streaming `file://` → `tm-file://` rewriter.
   - `src/scheme/HOSchemeHandler`: base class that never uses a task after it was stopped, loads protocol-relative URLs over https, and only trusts requests from command output and local files.
   - `src/scheme/HOFileSchemeHandler`: `tm-file://` (files, directories with `index.html`, not-found page, HTML rewriting). Refuses requests from other pages, so a web page cannot read local files through it.
   - `src/scheme/HOCommandOutputSchemeHandler`: streams command output (`URLForOutputFromFileHandle:processIdentifier:name:` replaces the request properties), kills the process group when stopped, and records the output so it can be reloaded and shown by View Source (previously a reload showed no output).
   - Tests (`ninja HTMLOutput/test`): unit tests with a fake `WKURLSchemeTask` (which, like WebKit, flags use after stop) and an end-to-end test streaming output into a `WKWebView`.
3. **JavaScript bridge.** User script with the `TextMate` object (including the `src`/`href` rewriting) and message handlers; asynchronous `system()`, synchronous `system()` via XHR, `outputString`, `onreadoutput`/`onreaderror`, `write`/`close`/`cancel`, `isBusy`, `progress`, `log`, `open`. Tests: an HTML test page exercising every call, run in a hidden `WKWebView`, reporting results back through the bridge.
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

1. Should `TextMate.system()` also be offered with a `Promise` (new, optional API) in addition to the compatible synchronous and callback forms?
2. Minimum behavior for View Source of non-command pages (original source requires re-fetching).

Resolved by the prototypes: local files do not require private API (stream rewriting plus a small injected script), and the synchronous form keeps blocking the page, as bundles expect, without blocking TextMate.
