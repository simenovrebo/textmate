// Spike 3: Is HTML from a WKURLSchemeHandler rendered (and are inline scripts run) incrementally while
// the command is still producing output? And what happens when the user stops the load (⌘.)?
#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>

@interface Runner : NSObject <WKURLSchemeHandler, WKScriptMessageHandler>
@property (nonatomic) WKWebView* webView;
@property (nonatomic) NSWindow* window;
@property (nonatomic) CFAbsoluteTime t0;
@property (nonatomic) BOOL stopped;
@property (nonatomic) int phase; // 1: full stream, 2: stopped mid-stream
@end

@implementation Runner
- (void)load
{
	self.stopped = NO;
	self.t0 = CFAbsoluteTimeGetCurrent();
	[self.webView loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:[NSString stringWithFormat:@"x-txmt-filehandle://job/Spike/%d", self.phase]]]];
}

- (void)start
{
	WKWebViewConfiguration* config = [WKWebViewConfiguration new];
	[config setURLSchemeHandler:self forURLScheme:@"x-txmt-filehandle"];
	[config.userContentController addScriptMessageHandler:self name:@"report"];
	self.webView = [[WKWebView alloc] initWithFrame:NSMakeRect(0, 0, 400, 300) configuration:config];
	self.window.contentView = self.webView;
	self.phase = 1;
	[self load];
}

- (void)webView:(WKWebView*)webView startURLSchemeTask:(id <WKURLSchemeTask>)task
{
	[task didReceiveResponse:[[NSURLResponse alloc] initWithURL:task.request.URL MIMEType:@"text/html" expectedContentLength:-1 textEncodingName:@"utf-8"]];

	int const chunks = 8;
	for(int i = 1; i <= chunks; ++i)
	{
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * 0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
			NSString* html = [NSString stringWithFormat:@"<p>line %d</p><script>window.webkit.messageHandlers.report.postMessage({ chunk: %d, paragraphs: document.querySelectorAll('p').length })</script>\n", i, i];
			@try {
				if(self.stopped)
					printf("  chunk %d: sending after stopURLSchemeTask: …\n", i);
				[task didReceiveData:[html dataUsingEncoding:NSUTF8StringEncoding]];
				if(i == chunks)
					[task didFinish];
			} @catch(NSException* e) {
				printf("  chunk %d: EXCEPTION %s: %s\n", i, e.name.UTF8String, e.reason.UTF8String);
			}
			if(i == chunks)
			{
				dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
					if(self.phase == 1)
					{
						printf("phase 2: stop loading after chunk 3 (like ⌘.)\n");
						self.phase = 2;
						[self load];
					}
					else
					{
						[NSApp terminate:nil];
					}
				});
			}
		});
	}
}

- (void)webView:(WKWebView*)webView stopURLSchemeTask:(id <WKURLSchemeTask>)task
{
	printf("  stopURLSchemeTask called at %.0f ms (this is where the command would be killed)\n", (CFAbsoluteTimeGetCurrent() - self.t0) * 1000);
	self.stopped = YES;
}

- (void)userContentController:(WKUserContentController*)controller didReceiveScriptMessage:(WKScriptMessage*)message
{
	NSDictionary* r = message.body;
	printf("  %s chunk %d ran at %4.0f ms, %d paragraphs in DOM\n", self.phase == 1 ? "phase 1:" : "phase 2:", [r[@"chunk"] intValue], (CFAbsoluteTimeGetCurrent() - self.t0) * 1000, [r[@"paragraphs"] intValue]);
	if(self.phase == 2 && [r[@"chunk"] intValue] == 3)
		[self.webView stopLoading];
}
@end

int main ()
{
	@autoreleasepool {
		[NSApplication sharedApplication];
		[NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
		Runner* runner = [Runner new];
		runner.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(-10000, -10000, 400, 300) styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
		[runner.window orderBack:nil];
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ printf("TIMEOUT\n"); [NSApp terminate:nil]; });
		dispatch_async(dispatch_get_main_queue(), ^{ printf("phase 1: 8 chunks, 300 ms apart\n"); [runner start]; });
		[NSApp run];
	}
	return 0;
}
