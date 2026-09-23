#import "../scheme/HOSchemeHandler.h"
#import <oak/misc.h>

// Native side of the TextMate JavaScript object for WKWebView (see HOScriptBridgeJS.h), replacing
// HOJSBridge (WebScriptObject). Messages and requests are only accepted from command output and
// local files (x-txmt-filehandle and tm-file origins).

@protocol HOScriptBridgeDelegate <NSObject>
@property (nonatomic, getter = isBusy) BOOL busy;
@property (nonatomic) double progress;
@end

extern NSString* const kHOScriptBridgeURLScheme; // x-txmt-js (synchronous TextMate.system)

@interface HOScriptBridge : HOSchemeHandler <WKScriptMessageHandler>
// Add the TextMate object to web views created with this configuration.
- (void)addToConfiguration:(WKWebViewConfiguration*)configuration;

@property (nonatomic, weak) WKWebView* webView;
@property (nonatomic, weak) id <HOScriptBridgeDelegate> delegate;
@property (nonatomic) std::map<std::string, std::string> environment; // for commands run by TextMate.system()

// When NO, the TextMate object is not added to pages loaded afterwards and messages are ignored.
@property (nonatomic, getter = isEnabled) BOOL enabled;

// Seconds before asking whether to stop a synchronous TextMate.system() command (default 15, 0 to never ask)
@property (nonatomic) NSTimeInterval synchronousCommandWarningDelay;

// Default: NSLog / open the document in TextMate
@property (nonatomic, copy) void(^logHandler)(NSString* message);
@property (nonatomic, copy) void(^openHandler)(NSString* path, id options);

// Stop all running commands, e.g. when the page is replaced
- (void)cancelAllCommands;
@end
