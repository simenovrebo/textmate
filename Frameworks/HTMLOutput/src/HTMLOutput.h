#include <oak/misc.h>

@interface OakHTMLOutputView : NSView
// Show the HTML written to fileHandle as it arrives. Stopping the load kills the process group of processIdentifier.
// The command object posts OakCommandDidTerminateNotification when done (used by stopLoadingWithUserInteraction:…).
- (void)loadOutputFromFileHandle:(NSFileHandle*)fileHandle processIdentifier:(pid_t)processIdentifier name:(NSString*)name command:(id)command environment:(std::map<std::string, std::string> const&)anEnvironment autoScrolls:(BOOL)flag;
- (void)stopLoadingWithUserInteraction:(BOOL)askUserFlag completionHandler:(void(^)(BOOL didStop))handler;
- (void)setContent:(NSString*)someHTML;

// Like window.close(): hide the HTML output pane or close the window
- (void)close;

@property (nonatomic) NSUUID* commandIdentifier; // identifier of the command whose output is shown
@property (nonatomic, getter = isRunningCommand, readonly) BOOL runningCommand;
@property (nonatomic, getter = isVisible, readonly) BOOL visible;
@property (nonatomic, getter = isReusable) BOOL reusable;
@property (nonatomic) BOOL disableJavaScriptAPI;

// Read-only access to the webview is given to allow reading page title, etc.
@property (nonatomic, readonly) WKWebView* webView;
@end
