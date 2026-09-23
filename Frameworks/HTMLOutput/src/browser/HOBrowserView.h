#import <oak/misc.h>

@class HOStatusBar;

// A WKWebView with a status bar (back/forward, link under the mouse, progress), used for HTML output and
// for windows opened by it. Command output (x-txmt-filehandle://) and local files (tm-file://) are served by
// the scheme handlers in src/scheme; links to other schemes, such as txmt://, are opened with openExternalURL:.
//
// Subclasses overriding a navigation or UI delegate method must call super.

@interface HOBrowserView : NSView <WKNavigationDelegate, WKUIDelegate>
// A configuration with the scheme handlers and scripts needed by browser views. Views created by
// initWithFrame: use a new one; subclasses can add to it and pass it to initWithFrame:configuration:.
+ (WKWebViewConfiguration*)makeConfiguration;
- (instancetype)initWithFrame:(NSRect)frame configuration:(WKWebViewConfiguration*)configuration;
- (instancetype)initWithFrame:(NSRect)frame;

@property (nonatomic, readonly) WKWebView* webView;
@property (nonatomic, readonly) HOStatusBar* statusBar;
@property (nonatomic) BOOL showsProgress; // update the progress bar while loading (default YES)

// Called for links the web view does not handle (txmt://, mailto:, …)
- (void)openExternalURL:(NSURL*)url;

// Used by printDocument: (margins set to the printable area)
- (NSPrintOperation*)printOperationWithPrintInfo:(NSPrintInfo*)info;

// Like window.close(): hide the HTML output pane or close the window
- (void)close;
@end
