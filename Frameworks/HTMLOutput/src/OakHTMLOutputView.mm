#import "OakHTMLOutputView.h"
#import "browser/HOStatusBar.h"
#import "browser/HOBrowserViewJS.h"
#import "bridge/HOScriptBridge.h"
#import "scheme/HOCommandOutputSchemeHandler.h"
#import <OakFoundation/OakFoundation.h>
#import <OakFoundation/NSString Additions.h>
#import <OakAppKit/NSAlert Additions.h>
#import <oak/debug.h>

// Command output is kept so that it can be shown again when going back (and for View Source), but only for the
// most recent pages of each view.
static NSUInteger const kMaximumRecordedOutputs = 10;

@interface HOStatusBar (BusyAndProgressProperties) <HOScriptBridgeDelegate>
@end

@interface OakHTMLOutputView ()
@property (nonatomic, getter = isRunningCommand, readwrite) BOOL runningCommand;
@property (nonatomic, getter = isVisible) BOOL visible;
@property (nonatomic) NSString* commandName;
@property (nonatomic) id command; // until it terminates
@property (nonatomic) id commandTerminationObserver;
@property (nonatomic) HOScriptBridge* bridge;
@property (nonatomic) std::map<std::string, std::string> environment;
@property (nonatomic) NSMutableArray<NSURL*>* outputURLs;
@property (nonatomic) NSURL* autoScrollURL;
@property (nonatomic) NSArray* pendingScrollPosition;
@end

@implementation OakHTMLOutputView
+ (NSSet*)keyPathsForValuesAffectingMainFrameTitle
{
	return [NSSet setWithObjects:@"webView.title", @"commandName", nil];
}

- (instancetype)initWithFrame:(NSRect)aRect
{
	WKWebViewConfiguration* configuration = [HOBrowserView makeConfiguration];
	HOScriptBridge* bridge = [HOScriptBridge new];
	[bridge addToConfiguration:configuration];

	if(self = [super initWithFrame:aRect configuration:configuration])
	{
		_reusable   = YES;
		_outputURLs = [NSMutableArray array];

		_bridge = bridge;
		_bridge.webView  = self.webView;
		_bridge.delegate = self.statusBar;
	}
	return self;
}

- (void)dealloc
{
	[_bridge cancelAllCommands];
	if(_commandTerminationObserver)
		[NSNotificationCenter.defaultCenter removeObserver:_commandTerminationObserver];
	for(NSURL* url in _outputURLs)
		[HOCommandOutputSchemeHandler removeOutputForURL:url];
}

- (void)setDisableJavaScriptAPI:(BOOL)flag
{
	_disableJavaScriptAPI = flag;
	_bridge.enabled = !flag;
}

- (void)loadOutputFromFileHandle:(NSFileHandle*)fileHandle processIdentifier:(pid_t)processIdentifier name:(NSString*)name command:(id)command environment:(std::map<std::string, std::string> const&)anEnvironment autoScrolls:(BOOL)flag
{
	NSURL* url = [HOCommandOutputSchemeHandler URLForOutputFromFileHandle:fileHandle processIdentifier:processIdentifier name:name];

	self.environment        = anEnvironment;
	self.bridge.environment = anEnvironment;
	self.commandName        = name;
	self.autoScrollURL      = flag ? url : nil;
	self.runningCommand     = YES;
	self.command            = command;

	if(_commandTerminationObserver)
		[NSNotificationCenter.defaultCenter removeObserver:_commandTerminationObserver];

	__weak OakHTMLOutputView* weakSelf = self;
	_commandTerminationObserver = command ? [NSNotificationCenter.defaultCenter addObserverForName:@"OakCommandDidTerminateNotification" object:command queue:nil usingBlock:^(NSNotification* notification){
		if(OakHTMLOutputView* strongSelf = weakSelf)
		{
			[NSNotificationCenter.defaultCenter removeObserver:strongSelf.commandTerminationObserver];
			strongSelf.commandTerminationObserver = nil;
			strongSelf.command = nil;
		}
	}] : nil;

	[self loadOutputURL:url];
}

- (void)setContent:(NSString*)someHTML
{
	NSURL* url = [HOCommandOutputSchemeHandler URLForOutput:[someHTML dataUsingEncoding:NSUTF8StringEncoding] name:self.commandName ?: @"Output"];

	// Keep the scroll position when the page is replaced
	[self.webView evaluateJavaScript:@"[window.scrollX, window.scrollY]" inFrame:nil inContentWorld:WKContentWorld.defaultClientWorld completionHandler:^(id result, NSError* error){
		self.pendingScrollPosition = [result isKindOfClass:[NSArray class]] && [result count] == 2 ? result : nil;
		[self loadOutputURL:url];
	}];
}

- (void)loadOutputURL:(NSURL*)url
{
	[_outputURLs addObject:url];
	while(_outputURLs.count > kMaximumRecordedOutputs)
	{
		[HOCommandOutputSchemeHandler removeOutputForURL:_outputURLs.firstObject];
		[_outputURLs removeObjectAtIndex:0];
	}

	[self.webView loadRequest:[NSURLRequest requestWithURL:url]];
}

- (void)stopLoadingWithUserInteraction:(BOOL)askUserFlag completionHandler:(void(^)(BOOL didStop))handler
{
	id command = self.command;
	if(!self.isRunningCommand || !command)
		return handler(YES);

	NSAlert* alert = askUserFlag ? [NSAlert tmAlertWithMessageText:[NSString stringWithFormat:@"Stop “%@”?", self.commandName] informativeText:@"The job that the task is performing will not be completed." buttons:@"Stop", @"Cancel", nil] : nil;

	__weak __block id token = [NSNotificationCenter.defaultCenter addObserverForName:@"OakCommandDidTerminateNotification" object:command queue:nil usingBlock:^(NSNotification* notification){
		if(alert)
			[self.window endSheet:alert.window returnCode:NSAlertFirstButtonReturn];
		handler(YES);
		[NSNotificationCenter.defaultCenter removeObserver:token];
	}];

	if(alert)
	{
		[alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse returnCode){
			if(returnCode == NSAlertFirstButtonReturn) /* "Stop" */
			{
				[self.webView stopLoading];
			}
			else
			{
				handler(NO);
				[NSNotificationCenter.defaultCenter removeObserver:token];
			}
		}];
	}
	else
	{
		[self.webView stopLoading];
	}
}

- (NSString*)mainFrameTitle
{
	return OakNotEmptyString(self.webView.title) ? self.webView.title : (self.commandName ?: @"");
}

- (void)openExternalURL:(NSURL*)url
{
	if([url.scheme isEqualToString:@"txmt"])
	{
		auto projectUUID = _environment.find("TM_PROJECT_UUID");
		if(projectUUID != _environment.end())
			url = [NSURL URLWithString:[[url absoluteString] stringByAppendingFormat:@"&project=%@", [NSString stringWithCxxString:projectUUID->second]]];
	}
	[super openExternalURL:url];
}

- (void)viewDidMoveToWindow
{
	[NSNotificationCenter.defaultCenter removeObserver:self name:NSWindowWillCloseNotification object:nil];
	if(self.window)
		[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(windowWillClose:) name:NSWindowWillCloseNotification object:self.window];
	self.visible = self.window ? YES : NO;
}

- (void)windowWillClose:(NSNotification*)aNotification
{
	self.visible = NO;
}

// ============================
// = Navigation Notifications =
// ============================

- (void)webView:(WKWebView*)webView didStartProvisionalNavigation:(WKNavigation*)navigation
{
	[super webView:webView didStartProvisionalNavigation:navigation];
	self.showsProgress = !self.isRunningCommand;
}

- (void)webView:(WKWebView*)webView didCommitNavigation:(WKNavigation*)navigation
{
	[super webView:webView didCommitNavigation:navigation];

	// Commands started by the previous page’s TextMate.system() are no longer needed
	[self.bridge cancelAllCommands];

	if(self.autoScrollURL && [webView.URL isEqual:self.autoScrollURL])
		[webView evaluateJavaScript:@(kHOAutoScrollJavaScript) inFrame:nil inContentWorld:WKContentWorld.defaultClientWorld completionHandler:nil];
}

- (void)webView:(WKWebView*)webView didFinishNavigation:(WKNavigation*)navigation
{
	self.runningCommand = NO;
	self.autoScrollURL  = nil;

	if(NSArray* position = self.pendingScrollPosition)
		[webView evaluateJavaScript:[NSString stringWithFormat:@"window.scrollTo(%f, %f)", [position[0] doubleValue], [position[1] doubleValue]] inFrame:nil inContentWorld:WKContentWorld.defaultClientWorld completionHandler:nil];
	self.pendingScrollPosition = nil;

	[super webView:webView didFinishNavigation:navigation];
}

- (void)webView:(WKWebView*)webView didFailProvisionalNavigation:(WKNavigation*)navigation withError:(NSError*)error
{
	self.runningCommand = NO;
	self.autoScrollURL  = nil;
	[super webView:webView didFailProvisionalNavigation:navigation withError:error];
}

- (void)webView:(WKWebView*)webView didFailNavigation:(WKNavigation*)navigation withError:(NSError*)error
{
	self.runningCommand = NO;
	self.autoScrollURL  = nil;
	[super webView:webView didFailNavigation:navigation withError:error];
}
@end
