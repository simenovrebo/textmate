#import "HOBrowserView.h"
#import "HOBrowserViewJS.h"
#import "HOStatusBar.h"
#import "../scheme/HOCommandOutputSchemeHandler.h"
#import "../scheme/HOFileSchemeHandler.h"
#import <OakAppKit/NSAlert Additions.h>
#import <OakAppKit/OakPasteboard.h>
#import <OakAppKit/OakUIConstructionFunctions.h>
#import <OakFoundation/OakFoundation.h>
#import <OakFoundation/OakFindProtocol.h>
#import <document/OakDocument.h>
#import <document/OakDocumentController.h>
#import <oak/debug.h>

static void* kObserveWebViewContext = &kObserveWebViewContext;

static NSString* EscapeHTML (NSString* str)
{
	return [[[str stringByReplacingOccurrencesOfString:@"&" withString:@"&amp;"] stringByReplacingOccurrencesOfString:@"<" withString:@"&lt;"] stringByReplacingOccurrencesOfString:@"\"" withString:@"&quot;"];
}

static NSString* JSONString (id obj)
{
	NSData* data = [NSJSONSerialization dataWithJSONObject:obj options:NSJSONWritingFragmentsAllowed|NSJSONWritingWithoutEscapingSlashes error:nullptr];
	return data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"null";
}

// A URL like x-txmt-filehandle://cdn.example.com/page.html is a protocol-relative URL (//cdn.example.com/page.html)
// resolved against command output or a local file. Returns the URL to load instead, or nil.
static NSURL* ProtocolRelativeURL (NSURL* url)
{
	if(!url.host.length || ![@[ kHOCommandOutputURLScheme, kHOFileURLScheme ] containsObject:url.scheme] || [HOSchemeHandler isTrustedURL:url])
		return nil;

	NSURLComponents* components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:YES];
	components.scheme = [NSUserDefaults.standardUserDefaults stringForKey:@"defaultURLProtocol"] ?: @"https";
	return components.URL;
}

static BOOL ShouldShowError (NSError* error)
{
	if([error.domain isEqualToString:NSURLErrorDomain] && error.code == NSURLErrorCancelled)
		return NO;
	if([error.domain isEqualToString:@"WebKitErrorDomain"] && (error.code == 102 || error.code == 204)) // frame load interrupted by policy change, plug-in will handle load
		return NO;
	return YES;
}

@interface HOBrowserView ()
@property (nonatomic, readwrite) WKWebView* webView;
@property (nonatomic, readwrite) HOStatusBar* statusBar;
- (void)didReceiveBrowserMessage:(NSDictionary*)message;
@end

// Receives messages from kHOBrowserViewJavaScript. Windows opened by a page share its configuration (and so
// this handler), so messages are passed to the browser view of the web view that sent them.
@interface HOBrowserViewMessageHandler : NSObject <WKScriptMessageHandler>
@end

@implementation HOBrowserViewMessageHandler
- (void)userContentController:(WKUserContentController*)userContentController didReceiveScriptMessage:(WKScriptMessage*)message
{
	if(![message.body isKindOfClass:[NSDictionary class]])
		return;

	for(NSView* view = message.webView; view; view = view.superview)
	{
		if([view isKindOfClass:[HOBrowserView class]])
			return [(HOBrowserView*)view didReceiveBrowserMessage:message.body];
	}
}
@end

@implementation HOBrowserView
+ (WKWebViewConfiguration*)makeConfiguration
{
	WKWebViewConfiguration* configuration = [WKWebViewConfiguration new];
	[configuration setURLSchemeHandler:[HOCommandOutputSchemeHandler new] forURLScheme:kHOCommandOutputURLScheme];
	[configuration setURLSchemeHandler:[HOFileSchemeHandler new] forURLScheme:kHOFileURLScheme];
	configuration.preferences.javaScriptCanOpenWindowsAutomatically = YES;

	WKUserContentController* controller = configuration.userContentController;
	[controller addScriptMessageHandler:[HOBrowserViewMessageHandler new] name:@"textmateBrowser"];
	[controller addUserScript:[[WKUserScript alloc] initWithSource:@(kHOBrowserViewJavaScript) injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:NO]];
	return configuration;
}

- (instancetype)initWithFrame:(NSRect)frame
{
	return [self initWithFrame:frame configuration:[HOBrowserView makeConfiguration]];
}

- (instancetype)initWithFrame:(NSRect)frame configuration:(WKWebViewConfiguration*)configuration
{
	if(self = [super initWithFrame:frame])
	{
		_showsProgress = YES;

		_webView = [[WKWebView alloc] initWithFrame:NSZeroRect configuration:configuration];
		_webView.navigationDelegate = self;
		_webView.UIDelegate         = self;
		_webView.allowsBackForwardNavigationGestures = YES;
		if(@available(macOS 13.3, *))
			_webView.inspectable = [NSUserDefaults.standardUserDefaults boolForKey:@"WebKitDeveloperExtras"];

		_statusBar = [[HOStatusBar alloc] initWithFrame:NSZeroRect];
		_statusBar.delegate = _webView;

		NSDictionary* views = @{
			@"webView":   _webView,
			@"statusBar": _statusBar
		};

		OakAddAutoLayoutViewsToSuperview([views allValues], self);

		[self addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"H:|[webView(>=10)]|"            options:0                                                      metrics:nil views:views]];
		[self addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"V:|[webView(>=10)][statusBar]|" options:NSLayoutFormatAlignAllLeft|NSLayoutFormatAlignAllRight metrics:nil views:views]];

		for(NSString* keyPath in @[ @"estimatedProgress", @"canGoBack", @"canGoForward" ])
			[_webView addObserver:self forKeyPath:keyPath options:0 context:kObserveWebViewContext];
	}
	return self;
}

- (void)dealloc
{
	for(NSString* keyPath in @[ @"estimatedProgress", @"canGoBack", @"canGoForward" ])
		[_webView removeObserver:self forKeyPath:keyPath context:kObserveWebViewContext];
	_webView.navigationDelegate = nil;
	_webView.UIDelegate         = nil;
	[_webView stopLoading];
}

- (void)observeValueForKeyPath:(NSString*)keyPath ofObject:(id)object change:(NSDictionary*)change context:(void*)context
{
	if(context != kObserveWebViewContext)
		return [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];

	if([keyPath isEqualToString:@"estimatedProgress"])
	{
		if(_showsProgress && _webView.isLoading)
			_statusBar.progress = _webView.estimatedProgress;
	}
	else
	{
		_statusBar.canGoBack    = _webView.canGoBack;
		_statusBar.canGoForward = _webView.canGoForward;
	}
}

- (void)didReceiveBrowserMessage:(NSDictionary*)message
{
	NSString* type = message[@"type"];
	if([type isEqualToString:@"status"])
	{
		NSString* text = [message[@"text"] isKindOfClass:[NSString class]] ? message[@"text"] : @"";
		_statusBar.statusText = [text stringByRemovingPercentEncoding] ?: text;
	}
	else if([type isEqualToString:@"console"])
	{
		os_log(OS_LOG_DEFAULT, "%{public}@: %{public}@ on line %d", message[@"url"], message[@"message"], [message[@"line"] intValue]);
	}
}

- (void)openExternalURL:(NSURL*)url
{
	if([url.scheme isEqualToString:@"txmt"])
			[NSApp sendAction:@selector(handleTxMtURL:) to:nil from:url];
	else	[NSWorkspace.sharedWorkspace openURL:url];
}

- (void)close
{
	if(![self tryToPerform:@selector(toggleHTMLOutput:) with:self])
		[self.window performClose:self];
}

// ==============
// = Key Events =
// ==============

/*
Since the webView is typically the first responder, the path for key events is as follows:

For keyDown:
	webView
	HOBrowserView
	OakHTMLOutputView
	NSWindow

For performKeyEquivalent:
	NSWindow
	OakHTMLOutputView
	HOBrowserView
	webView

A webView default implementation passes all key events, including potential key equivalents (except ESC),
to the webpage so that it may have a chance to respond. Unfortunately, we cannot know if these events are
handled so the events are still forwarded down their respective chains as shown above. So to avoid the
NSBeep when hitting the end of the responder chain, we let HOBrowserView swallow all key events. This is
safe since performKeyEquivalent: is called first, which leads to another problem: we can pass
the key event back to the webView (minus the modifier). Therefore, we also terminate the above chain for
performKeyEquivalent: by overriding the method here and returning just NO. Note: that if none of the views
in the hierachy returns YES, the key (equivalent) event is then passed to the menus.
*/

- (BOOL)performKeyEquivalent
{
	return NO;
}

- (void)keyDown:(NSEvent*)anEvent
{
}

// =====================
// = Navigation Policy =
// =====================

- (void)webView:(WKWebView*)webView decidePolicyForNavigationAction:(WKNavigationAction*)navigationAction decisionHandler:(void(^)(WKNavigationActionPolicy))decisionHandler
{
	NSURL* url = navigationAction.request.URL;
	if(NSURL* redirectURL = ProtocolRelativeURL(url))
	{
		// Do not load a web page as (trusted) command output or local file
		decisionHandler(WKNavigationActionPolicyCancel);
		WKFrameInfo* frame = navigationAction.targetFrame;
		if(!frame || frame.isMainFrame)
				[webView loadRequest:[NSURLRequest requestWithURL:redirectURL]];
		else	[webView evaluateJavaScript:[NSString stringWithFormat:@"location.replace(%@)", JSONString(redirectURL.absoluteString)] inFrame:frame inContentWorld:WKContentWorld.defaultClientWorld completionHandler:nil];
	}
	else if([WKWebView handlesURLScheme:url.scheme] || [webView.configuration urlSchemeHandlerForURLScheme:url.scheme])
	{
		decisionHandler(WKNavigationActionPolicyAllow);
	}
	else
	{
		decisionHandler(WKNavigationActionPolicyCancel);
		[self openExternalURL:url];
	}
}

- (void)webView:(WKWebView*)webView decidePolicyForNavigationResponse:(WKNavigationResponse*)navigationResponse decisionHandler:(void(^)(WKNavigationResponsePolicy))decisionHandler
{
	if(navigationResponse.canShowMIMEType)
		return decisionHandler(WKNavigationResponsePolicyAllow);

	// Open what the web view cannot show (e.g. a link to a zip file) in the default application
	decisionHandler(WKNavigationResponsePolicyCancel);
	NSURL* url = navigationResponse.response.URL;
	if([url.scheme isEqualToString:kHOFileURLScheme])
	{
		if(NSString* path = [HOFileSchemeHandler pathForURL:url])
			[NSWorkspace.sharedWorkspace openURL:[NSURL fileURLWithPath:path]];
	}
	else if([@[ @"http", @"https" ] containsObject:url.scheme])
	{
		[NSWorkspace.sharedWorkspace openURL:url];
	}
}

// ============================
// = Navigation Notifications =
// ============================

- (void)webView:(WKWebView*)webView didStartProvisionalNavigation:(WKNavigation*)navigation
{
	_statusBar.busy = YES;
}

- (void)webView:(WKWebView*)webView didCommitNavigation:(WKNavigation*)navigation
{
}

- (void)webView:(WKWebView*)webView didFinishNavigation:(WKNavigation*)navigation
{
	[self didStopLoading];
}

- (void)webView:(WKWebView*)webView didFailProvisionalNavigation:(WKNavigation*)navigation withError:(NSError*)error
{
	[self showLoadError:error];
	[self didStopLoading];
}

- (void)webView:(WKWebView*)webView didFailNavigation:(WKNavigation*)navigation withError:(NSError*)error
{
	[self showLoadError:error];
	[self didStopLoading];
}

- (void)webViewWebContentProcessDidTerminate:(WKWebView*)webView
{
	os_log_error(OS_LOG_DEFAULT, "Web content process terminated while showing %{public}@", webView.URL);
	[self didStopLoading];
}

- (void)didStopLoading
{
	_statusBar.busy     = NO;
	_statusBar.progress = 0;
}

- (void)showLoadError:(NSError*)error
{
	if(!ShouldShowError(error))
		return;

	NSURL* url = error.userInfo[NSURLErrorFailingURLErrorKey] ?: _webView.URL;
	NSString* errorMsg = [NSString stringWithFormat:@"<!DOCTYPE html><title>Load Error</title><h1>Load Error</h1><p>WebKit reported <em>%@</em> while loading <tt>%@</tt>.</p>", EscapeHTML(error.localizedDescription), EscapeHTML(url.absoluteString ?: @"")];
	[_webView loadHTMLString:errorMsg baseURL:nil];
}

// ===============
// = UI Delegate =
// ===============

- (void)runAlert:(NSAlert*)alert completionHandler:(void(^)(NSModalResponse))handler
{
	if(NSWindow* window = self.window)
			[alert beginSheetModalForWindow:window completionHandler:handler];
	else	handler([alert runModal]);
}

- (void)webView:(WKWebView*)webView runJavaScriptAlertPanelWithMessage:(NSString*)message initiatedByFrame:(WKFrameInfo*)frame completionHandler:(void(^)())completionHandler
{
	NSAlert* alert = [NSAlert tmAlertWithMessageText:NSLocalizedString(@"Script Message", @"JavaScript alert title") informativeText:message buttons:NSLocalizedString(@"OK", @"JavaScript alert confirmation"), nil];
	[self runAlert:alert completionHandler:^(NSModalResponse){
		completionHandler();
	}];
}

- (void)webView:(WKWebView*)webView runJavaScriptConfirmPanelWithMessage:(NSString*)message initiatedByFrame:(WKFrameInfo*)frame completionHandler:(void(^)(BOOL result))completionHandler
{
	NSAlert* alert = [NSAlert tmAlertWithMessageText:NSLocalizedString(@"Script Message", @"JavaScript alert title") informativeText:message buttons:NSLocalizedString(@"OK", @"JavaScript alert confirmation"), NSLocalizedString(@"Cancel", @"JavaScript alert cancel"), nil];
	[self runAlert:alert completionHandler:^(NSModalResponse response){
		completionHandler(response == NSAlertFirstButtonReturn);
	}];
}

- (void)webView:(WKWebView*)webView runJavaScriptTextInputPanelWithPrompt:(NSString*)prompt defaultText:(NSString*)defaultText initiatedByFrame:(WKFrameInfo*)frame completionHandler:(void(^)(NSString* result))completionHandler
{
	NSTextField* textField = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 300, 22)];
	textField.stringValue = defaultText ?: @"";

	NSAlert* alert = [NSAlert tmAlertWithMessageText:NSLocalizedString(@"Script Message", @"JavaScript alert title") informativeText:prompt buttons:NSLocalizedString(@"OK", @"JavaScript alert confirmation"), NSLocalizedString(@"Cancel", @"JavaScript alert cancel"), nil];
	alert.accessoryView = textField;
	alert.window.initialFirstResponder = textField;
	[self runAlert:alert completionHandler:^(NSModalResponse response){
		completionHandler(response == NSAlertFirstButtonReturn ? textField.stringValue : nil);
	}];
}

- (void)webView:(WKWebView*)webView runOpenPanelWithParameters:(WKOpenPanelParameters*)parameters initiatedByFrame:(WKFrameInfo*)frame completionHandler:(void(^)(NSArray<NSURL*>* URLs))completionHandler
{
	NSOpenPanel* panel = [NSOpenPanel openPanel];
	panel.directoryURL            = [NSURL fileURLWithPath:NSHomeDirectory()];
	panel.allowsMultipleSelection = parameters.allowsMultipleSelection;
	panel.canChooseDirectories    = parameters.allowsDirectories;

	void(^handler)(NSModalResponse) = ^(NSModalResponse response){
		completionHandler(response == NSModalResponseOK ? panel.URLs : nil);
	};

	if(NSWindow* window = self.window)
			[panel beginSheetModalForWindow:window completionHandler:handler];
	else	handler([panel runModal]);
}

- (WKWebView*)webView:(WKWebView*)webView createWebViewWithConfiguration:(WKWebViewConfiguration*)configuration forNavigationAction:(WKNavigationAction*)navigationAction windowFeatures:(WKWindowFeatures*)windowFeatures
{
	NSSize size = NSMakeSize(windowFeatures.width ? windowFeatures.width.doubleValue : 750, windowFeatures.height ? windowFeatures.height.doubleValue : 800);

	NSRect contentRect = { NSZeroPoint, size };
	if(NSWindow* parent = webView.window)
	{
		NSPoint topLeft = [parent cascadeTopLeftFromPoint:NSMakePoint(NSMinX(parent.frame), NSMaxY(parent.frame))];
		contentRect.origin = NSMakePoint(topLeft.x, topLeft.y - size.height);
	}

	HOBrowserView* view = [[HOBrowserView alloc] initWithFrame:contentRect configuration:configuration];
	NSWindow* window = [[NSWindow alloc] initWithContentRect:contentRect
	                                               styleMask:(NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskResizable|NSWindowStyleMaskMiniaturizable)
	                                                 backing:NSBackingStoreBuffered
	                                                   defer:NO];
	[window bind:NSTitleBinding toObject:view.webView withKeyPath:@"title" options:@{ NSNullPlaceholderBindingOption: @"" }];
	[window setContentView:view];

	// The window is released when closed
	__attribute__ ((unused)) CFTypeRef dummy = CFBridgingRetain(window);
	[window setReleasedWhenClosed:YES];
	[window makeKeyAndOrderFront:self];

	return view.webView;
}

- (void)webViewDidClose:(WKWebView*)webView
{
	[self close];
}

// ===========================
// = Find and Find Clipboard =
// ===========================

- (void)findString:(NSString*)aString backwards:(BOOL)backwards ignoreCase:(BOOL)ignoreCase wrapAround:(BOOL)wrapAround completionHandler:(void(^)(BOOL found))handler
{
	WKFindConfiguration* configuration = [WKFindConfiguration new];
	configuration.backwards     = backwards;
	configuration.caseSensitive = !ignoreCase;
	configuration.wraps         = wrapAround;
	[_webView findString:aString withConfiguration:configuration completionHandler:^(WKFindResult* result){
		if(handler)
			handler(result.matchFound);
	}];
}

- (void)performFindOperation:(id <OakFindServerProtocol>)aFindServer
{
	if(aFindServer.findOperation != kFindOperationFind && aFindServer.findOperation != kFindOperationFindInSelection)
		return;

	NSString* findString = aFindServer.findString;
	find::options_t options = aFindServer.findOptions;
	[self findString:findString backwards:(options & find::backwards) ignoreCase:(options & find::ignore_case) wrapAround:(options & find::wrap_around) completionHandler:^(BOOL found){
		[aFindServer didFind:(found ? 1 : 0) occurrencesOf:findString atPosition:text::pos_t::undefined wrapped:NO];
	}];
}

- (void)findNextOrPrevious:(BOOL)backwards
{
	OakPasteboardEntry* entry = [OakPasteboard.findPasteboard current];
	if(OakNotEmptyString(entry.string))
		[self findString:entry.string backwards:backwards ignoreCase:[NSUserDefaults.standardUserDefaults boolForKey:kUserDefaultsFindIgnoreCase] wrapAround:[NSUserDefaults.standardUserDefaults boolForKey:kUserDefaultsFindWrapAround] completionHandler:nil];
}

- (IBAction)findNext:(id)sender     { [self findNextOrPrevious:NO]; }
- (IBAction)findPrevious:(id)sender { [self findNextOrPrevious:YES]; }

- (void)getSelection:(void(^)(NSString*))handler
{
	[_webView evaluateJavaScript:@"getSelection().toString()" inFrame:nil inContentWorld:WKContentWorld.defaultClientWorld completionHandler:^(id result, NSError* error){
		handler([result isKindOfClass:[NSString class]] && OakNotEmptyString(result) ? result : nil);
	}];
}

- (IBAction)copySelectionToFindPboard:(id)sender
{
	[self getSelection:^(NSString* str){
		if(str)
				[OakPasteboard.findPasteboard addEntryWithString:str];
		else	NSBeep();
	}];
}

- (IBAction)copySelectionToReplacePboard:(id)sender
{
	[self getSelection:^(NSString* str){
		if(str)
				[OakPasteboard.replacePasteboard addEntryWithString:str];
		else	NSBeep();
	}];
}

// ===============
// = View Source =
// ===============

- (void)viewSource:(id)sender
{
	NSURL* url = _webView.URL;
	NSString* name = OakNotEmptyString(_webView.title) ? _webView.title : nil;

	// For command output and local files, show the original source rather than the (rewritten) document
	NSData* data = [HOCommandOutputSchemeHandler outputForURL:url];
	if(!data && [url.scheme isEqualToString:kHOFileURLScheme])
	{
		if(NSString* path = [HOFileSchemeHandler pathForURL:url])
			data = [NSData dataWithContentsOfFile:path];
	}

	if(data)
	{
		NSString* str = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: [[NSString alloc] initWithData:data encoding:NSMacOSRomanStringEncoding];
		OakDocument* doc = [OakDocument documentWithString:str fileType:@"text.html.basic" customName:name];
		[OakDocumentController.sharedInstance showDocument:doc inProject:nil bringToFront:YES];
		return;
	}

	[_webView evaluateJavaScript:@"(document.doctype ? new XMLSerializer().serializeToString(document.doctype) + '\\n' : '') + document.documentElement.outerHTML" inFrame:nil inContentWorld:WKContentWorld.defaultClientWorld completionHandler:^(id result, NSError* error){
		if(![result isKindOfClass:[NSString class]])
			return NSBeep();
		OakDocument* doc = [OakDocument documentWithString:result fileType:@"text.html.basic" customName:name];
		[OakDocumentController.sharedInstance showDocument:doc inProject:nil bringToFront:YES];
	}];
}

// ============
// = Printing =
// ============

- (NSPrintOperation*)printOperationWithPrintInfo:(NSPrintInfo*)info
{
	info = [info copy];
	NSRect display = NSIntersectionRect(info.imageablePageBounds, (NSRect){ NSZeroPoint, info.paperSize });
	info.leftMargin   = NSMinX(display);
	info.rightMargin  = info.paperSize.width - NSMaxX(display);
	info.topMargin    = info.paperSize.height - NSMaxY(display);
	info.bottomMargin = NSMinY(display);

	NSPrintOperation* printer = [_webView printOperationWithPrintInfo:info];
	printer.view.frame = _webView.bounds; // Without a frame, the pages are blank
	[[printer printPanel] setOptions:[[printer printPanel] options] | NSPrintPanelShowsPaperSize | NSPrintPanelShowsOrientation];
	return printer;
}

- (IBAction)printDocument:(id)sender
{
	// WKWebView must print asynchronously: a synchronous runOperation keeps rendering pages
	if(NSWindow* window = self.window)
			[[self printOperationWithPrintInfo:NSPrintInfo.sharedPrintInfo] runOperationModalForWindow:window delegate:nil didRunSelector:NULL contextInfo:nil];
	else	NSBeep();
}
@end
