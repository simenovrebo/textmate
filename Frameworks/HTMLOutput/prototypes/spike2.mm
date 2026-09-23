// Spike 2: Synchronous TextMate.system() with WKWebView.
//
// A: prompt() — JavaScript blocks until the WKUIDelegate calls the completion handler, which
//    we do after running the command asynchronously. A marker distinguishes it from real prompt() calls.
// B: synchronous XMLHttpRequest to a custom scheme served by a WKURLSchemeHandler.
//
// Measures: result correctness, that JS is blocked for the command's duration, and that the app's
// main thread keeps running meanwhile (timer ticks), plus that a normal prompt() still works.
#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>

static NSString* const kMarker = @"\x01TextMate.system\x01";

static void RunCommand (NSString* command, void(^handler)(NSDictionary* result))
{
	NSTask* task = [NSTask new];
	task.launchPath = @"/bin/sh";
	task.arguments  = @[ @"-c", command ];
	NSPipe* out = [NSPipe pipe], *err = [NSPipe pipe];
	task.standardOutput = out; task.standardError = err;
	task.terminationHandler = ^(NSTask* t){
		NSData* o = [out.fileHandleForReading readDataToEndOfFile], *e = [err.fileHandleForReading readDataToEndOfFile];
		NSDictionary* r = @{ @"outputString": [[NSString alloc] initWithData:o encoding:NSUTF8StringEncoding] ?: @"", @"errorString": [[NSString alloc] initWithData:e encoding:NSUTF8StringEncoding] ?: @"", @"status": @(t.terminationStatus) };
		dispatch_async(dispatch_get_main_queue(), ^{ handler(r); });
	};
	[task launch];
}

static NSString* JSON (id obj) { return [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:obj options:NSJSONWritingFragmentsAllowed error:nil] encoding:NSUTF8StringEncoding]; }

@interface Runner : NSObject <WKUIDelegate, WKURLSchemeHandler, WKScriptMessageHandler>
@property (nonatomic) WKWebView* webView;
@property (nonatomic) NSWindow* window;
@property (nonatomic) NSInteger ticks;
@end

@implementation Runner
- (void)start
{
	[NSTimer scheduledTimerWithTimeInterval:0.1 repeats:YES block:^(NSTimer*){ ++self.ticks; }];

	WKWebViewConfiguration* config = [WKWebViewConfiguration new];
	[config setURLSchemeHandler:self forURLScheme:@"x-txmt-js"];
	[config setURLSchemeHandler:self forURLScheme:@"x-txmt-filehandle"];
	[config.userContentController addScriptMessageHandler:self name:@"report"];

	// The compatibility shim: TextMate.system(cmd, null) is synchronous
	NSString* shim = [NSString stringWithFormat:@
		"window.TextMate = {\n"
		"  systemViaPrompt: function (cmd) { return JSON.parse(prompt('%@', JSON.stringify({ command: cmd }))); },\n"
		"  systemViaXHR:    function (cmd) {\n"
		"    var xhr = new XMLHttpRequest();\n"
		"    xhr.open('POST', 'x-txmt-js://system', false);\n"
		"    try { xhr.send(JSON.stringify({ command: cmd })); } catch(e) { return { error: String(e) }; }\n"
		"    return xhr.status == 200 ? JSON.parse(xhr.responseText) : { error: 'status ' + xhr.status };\n"
		"  },\n"
		"};\n", kMarker];
	[config.userContentController addUserScript:[[WKUserScript alloc] initWithSource:shim injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:NO]];

	self.webView = [[WKWebView alloc] initWithFrame:NSMakeRect(0, 0, 400, 300) configuration:config];
	self.webView.UIDelegate = self;
	self.window.contentView = self.webView;
	[self.webView loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:@"x-txmt-filehandle://job/Spike/2"]]];
}

// Page with the tests (served from the custom scheme like command output)
- (void)webView:(WKWebView*)webView startURLSchemeTask:(id <WKURLSchemeTask>)task
{
	NSURL* url = task.request.URL;
	if([url.scheme isEqualToString:@"x-txmt-filehandle"])
	{
		NSString* html = @
			"<script>\n"
			"function test (name, fn) {\n"
			"  var t0 = Date.now(), r = fn('echo \"hello wørld\"; echo oops >&2; sleep 1.5; exit 3'), ms = Date.now() - t0;\n"
			"  return { name: name, result: r, ms: ms };\n"
			"}\n"
			"var results = [ test('prompt', TextMate.systemViaPrompt), test('xhr', TextMate.systemViaXHR) ];\n"
			"results.push({ name: 'real prompt()', result: prompt('What is your name?', 'default') });\n"
			"window.webkit.messageHandlers.report.postMessage(results);\n"
			"</script>";
		NSData* data = [html dataUsingEncoding:NSUTF8StringEncoding];
		[task didReceiveResponse:[[NSURLResponse alloc] initWithURL:url MIMEType:@"text/html" expectedContentLength:data.length textEncodingName:@"utf-8"]];
		[task didReceiveData:data];
		[task didFinish];
	}
	else // x-txmt-js://system — variant B
	{
		NSDictionary* args = [NSJSONSerialization JSONObjectWithData:task.request.HTTPBody ?: [NSData data] options:0 error:nil];
		if(!args)
			printf("  (xhr: request body not available to scheme handler: %s)\n", task.request.HTTPBody ? "?" : "HTTPBody is nil");
		NSInteger ticksBefore = self.ticks;
		RunCommand(args[@"command"] ?: @"true", ^(NSDictionary* r){
			printf("  xhr:    app main thread ticked %ld times while page was blocked\n", (long)(self.ticks - ticksBefore));
			NSData* data = [JSON(r) dataUsingEncoding:NSUTF8StringEncoding];
			[task didReceiveResponse:[[NSHTTPURLResponse alloc] initWithURL:url statusCode:200 HTTPVersion:@"HTTP/1.1" headerFields:@{ @"Content-Type": @"application/json" }]];
			[task didReceiveData:data];
			[task didFinish];
		});
	}
}
- (void)webView:(WKWebView*)webView stopURLSchemeTask:(id <WKURLSchemeTask>)task { }

// Variant A
- (void)webView:(WKWebView*)webView runJavaScriptTextInputPanelWithPrompt:(NSString*)prompt defaultText:(NSString*)defaultText initiatedByFrame:(WKFrameInfo*)frame completionHandler:(void(^)(NSString* result))completionHandler
{
	if([prompt isEqualToString:kMarker])
	{
		NSDictionary* args = [NSJSONSerialization JSONObjectWithData:[defaultText dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
		NSInteger ticksBefore = self.ticks;
		printf("  prompt: request from %s://%s\n", frame.securityOrigin.protocol.UTF8String, frame.securityOrigin.host.UTF8String);
		RunCommand(args[@"command"], ^(NSDictionary* r){
			printf("  prompt: app main thread ticked %ld times while page was blocked\n", (long)(self.ticks - ticksBefore));
			completionHandler(JSON(r));
		});
	}
	else
	{
		printf("  real prompt() reached the UI delegate: “%s” (default “%s”)\n", prompt.UTF8String, defaultText.UTF8String);
		completionHandler(@"Simen");
	}
}

- (void)userContentController:(WKUserContentController*)controller didReceiveScriptMessage:(WKScriptMessage*)message
{
	for(NSDictionary* r in message.body)
		printf("%-14s -> %s%s\n", [r[@"name"] UTF8String], [JSON(r[@"result"] ?: [NSNull null]) UTF8String], r[@"ms"] ? [[NSString stringWithFormat:@"  (page blocked %@ ms)", r[@"ms"]] UTF8String] : "");
	[NSApp terminate:nil];
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
		dispatch_async(dispatch_get_main_queue(), ^{ [runner start]; });
		[NSApp run];
	}
	return 0;
}
