// Spike 1: Can a page served by a WKURLSchemeHandler (like command output) load file:// resources?
//
// Variants:
//   default      – default configuration, page references file:// URLs
//   fileaccess   – private preferences allowFileAccessFromFileURLs/allowUniversalAccessFromFileURLs
//   rewrite      – page references x-txmt-file:// URLs, served by a second scheme handler from disk
#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>

static NSString* gResDir;

@interface SchemeHandler : NSObject <WKURLSchemeHandler>
@property (nonatomic) NSString* resourcePrefix;
@end

@implementation SchemeHandler
- (void)webView:(WKWebView*)webView startURLSchemeTask:(id <WKURLSchemeTask>)task
{
	NSURL* url = task.request.URL;
	NSData* data; NSString* mime;
	if([url.scheme isEqualToString:@"x-txmt-filehandle"])
	{
		NSString* p = self.resourcePrefix;
		NSString* html = [NSString stringWithFormat:@
			"<!DOCTYPE html><html><head><title>Spike</title>"
			"<link rel='stylesheet' href='%1$@/style.css'>"
			"<script src='%1$@/script.js'></script>"
			"</head><body>Hello"
			"<img id='static' src='%1$@/img.png' onload='window.staticImg=\"loaded\"' onerror='window.staticImg=\"error\"'>"
			"<script>"
			"  var dyn = new Image(); dyn.onload = () => window.dynImg = 'loaded'; dyn.onerror = () => window.dynImg = 'error'; dyn.src = '%1$@/img.png';"
			"  window.addEventListener('load', () => setTimeout(() => {"
			"    window.webkit.messageHandlers.report.postMessage({"
			"      stylesheet: getComputedStyle(document.body).color == 'rgb(1, 2, 3)' ? 'loaded' : 'blocked',"
			"      script:     window.fromScript == 'yes' ? 'loaded' : 'blocked',"
			"      staticImg:  window.staticImg || 'pending',"
			"      dynamicImg: window.dynImg || 'pending',"
			"      origin:     location.origin"
			"    });"
			"  }, 300));"
			"</script></body></html>", p];
		data = [html dataUsingEncoding:NSUTF8StringEncoding];
		mime = @"text/html";
	}
	else // x-txmt-file: serve from disk
	{
		data = [NSData dataWithContentsOfFile:url.path];
		NSDictionary* types = @{ @"css": @"text/css", @"js": @"text/javascript", @"png": @"image/png" };
		mime = types[url.pathExtension] ?: @"application/octet-stream";
		if(!data)
		{
			[task didFailWithError:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorFileDoesNotExist userInfo:nil]];
			return;
		}
	}
	[task didReceiveResponse:[[NSURLResponse alloc] initWithURL:url MIMEType:mime expectedContentLength:data.length textEncodingName:@"utf-8"]];
	[task didReceiveData:data];
	[task didFinish];
}
- (void)webView:(WKWebView*)webView stopURLSchemeTask:(id <WKURLSchemeTask>)task { }
@end

@interface Runner : NSObject <WKScriptMessageHandler>
@property (nonatomic) NSMutableArray* variants;
@property (nonatomic) WKWebView* webView;
@property (nonatomic) NSWindow* window;
@property (nonatomic) NSString* current;
@end

@implementation Runner
- (void)next
{
	if(self.variants.count == 0)
		return (void)[NSApp terminate:nil];
	self.current = self.variants.firstObject;
	[self.variants removeObjectAtIndex:0];

	SchemeHandler* handler = [SchemeHandler new];
	handler.resourcePrefix = [self.current isEqualToString:@"rewrite"] ? [@"x-txmt-file://localhost" stringByAppendingString:gResDir] : [@"file://" stringByAppendingString:gResDir];

	WKWebViewConfiguration* config = [WKWebViewConfiguration new];
	[config setURLSchemeHandler:handler forURLScheme:@"x-txmt-filehandle"];
	[config setURLSchemeHandler:handler forURLScheme:@"x-txmt-file"];
	[config.userContentController addScriptMessageHandler:self name:@"report"];
	if([self.current isEqualToString:@"fileaccess"])
	{
		@try {
			[config.preferences setValue:@YES forKey:@"allowFileAccessFromFileURLs"];
			[config setValue:@YES forKey:@"allowUniversalAccessFromFileURLs"];
		} @catch(NSException* e) {
			printf("  (setting private preferences failed: %s)\n", e.reason.UTF8String);
		}
	}

	self.webView = [[WKWebView alloc] initWithFrame:NSMakeRect(0, 0, 400, 300) configuration:config];
	self.window.contentView = self.webView;
	[self.webView loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:@"x-txmt-filehandle://job/Spike/1"]]];
}

- (void)userContentController:(WKUserContentController*)controller didReceiveScriptMessage:(WKScriptMessage*)message
{
	NSDictionary* r = message.body;
	printf("%-11s stylesheet=%-8s script=%-8s image=%-8s js-image=%-8s (origin %s)\n", self.current.UTF8String,
		[r[@"stylesheet"] UTF8String], [r[@"script"] UTF8String], [r[@"staticImg"] UTF8String], [r[@"dynamicImg"] UTF8String], [r[@"origin"] UTF8String]);
	[controller removeScriptMessageHandlerForName:@"report"];
	dispatch_async(dispatch_get_main_queue(), ^{ [self next]; });
}
@end

int main (int argc, char const* argv[])
{
	@autoreleasepool {
		gResDir = @(argv[1]);
		[NSApplication sharedApplication];
		[NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];

		Runner* runner = [Runner new];
		runner.variants = [@[ @"default", @"fileaccess", @"rewrite" ] mutableCopy];
		runner.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(-10000, -10000, 400, 300) styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
		[runner.window orderBack:nil];

		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
			printf("TIMEOUT in variant %s\n", runner.current.UTF8String);
			[NSApp terminate:nil];
		});
		dispatch_async(dispatch_get_main_queue(), ^{ [runner next]; });
		[NSApp run];
	}
	return 0;
}
