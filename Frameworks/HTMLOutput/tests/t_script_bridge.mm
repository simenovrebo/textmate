#import "scheme_test_support.h"
#import "../src/bridge/HOScriptBridge.h"
#import "../src/scheme/HOCommandOutputSchemeHandler.h"
#import "../src/scheme/HOFileSchemeHandler.h"
#import "bridge_test_support.h"

static NSString* JSONString (id obj)
{
	NSData* data = [NSJSONSerialization dataWithJSONObject:obj ?: [NSNull null] options:NSJSONWritingFragmentsAllowed|NSJSONWritingWithoutEscapingSlashes error:nullptr];
	return data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"<not JSON>";
}

struct fixture_t
{
	WKWebView* webView;
	HOScriptBridge* bridge;
	BridgeRecorder* recorder;
};

// Load a page (command output unless an untrusted URL is given) with the bridge and wait for it
static fixture_t LoadPage (BOOL enabled = YES, NSString* untrustedURL = nil)
{
	__block fixture_t res;
	__block NSURL* url;
	NSPipe* pipe = [NSPipe pipe];

	OnMain(^{
		res.recorder = [BridgeRecorder new];
		res.bridge   = [HOScriptBridge new];
		res.bridge.delegate    = res.recorder;
		res.bridge.environment = { { "TM_TEST_VARIABLE", "grønn" } };
		res.bridge.synchronousCommandWarningDelay = 0;
		res.bridge.enabled     = enabled;

		BridgeRecorder* recorder = res.recorder;
		res.bridge.logHandler  = ^(NSString* message){ [recorder.logs addObject:message]; };
		res.bridge.openHandler = ^(NSString* path, id options){ [recorder.opens addObject:@[ path, options ?: [NSNull null] ]]; };

		WKWebViewConfiguration* config = [WKWebViewConfiguration new];
		[config setURLSchemeHandler:[HOCommandOutputSchemeHandler new] forURLScheme:kHOCommandOutputURLScheme];
		[config setURLSchemeHandler:[HOFileSchemeHandler new] forURLScheme:kHOFileURLScheme];
		[config setURLSchemeHandler:[UntrustedSchemeHandler new] forURLScheme:@"x-test-untrusted"];
		[res.bridge addToConfiguration:config];

		res.webView = [[WKWebView alloc] initWithFrame:NSMakeRect(0, 0, 400, 300) configuration:config];
		res.bridge.webView = res.webView;

		url = untrustedURL ? [NSURL URLWithString:untrustedURL] : [HOCommandOutputSchemeHandler URLForOutputFromFileHandle:pipe.fileHandleForReading processIdentifier:0 name:@"Bridge Test"];
		[res.webView loadRequest:[NSURLRequest requestWithURL:url]];
	});

	[pipe.fileHandleForWriting writeData:[@"<!DOCTYPE html><title>Bridge Test</title><p>ready</p>" dataUsingEncoding:NSUTF8StringEncoding]];
	[pipe.fileHandleForWriting closeFile];

	// The initial about:blank is also “complete”, so wait for the page itself
	NSString* condition = [NSString stringWithFormat:@"location.href == '%@' && document.readyState == 'complete'", url.absoluteString];
	if(!WaitForJavaScript(res.webView, condition))
		fprintf(stderr, "*** timeout loading %s\n", url.absoluteString.UTF8String);
	return res;
}

static void Close (fixture_t& fixture)
{
	OnMain(^{
		[fixture.bridge cancelAllCommands];
		fixture.webView = nil;
		fixture.bridge  = nil;
	});
}

void test_synchronous_system ()
{
	fixture_t f = LoadPage();
	NSError* error;
	NSDictionary* res = CallAsyncJavaScript(f.webView, @"const r = TextMate.system('echo \"$TM_TEST_VARIABLE wørld\"; echo oops >&2; exit 3', null); return { out: r.outputString, err: r.errorString, status: r.status };", &error);
	OAK_ASSERT_EQ(to_s(error.description ?: @""), ""); // show the JavaScript error, if any
	OAK_ASSERT_EQ(to_s(res[@"out"]), "grønn wørld\n");
	OAK_ASSERT_EQ(to_s(res[@"err"]), "oops\n");
	OAK_ASSERT_EQ([res[@"status"] intValue], 3);

	// Single argument is also synchronous; stdin is closed, so cat does not block
	res = CallAsyncJavaScript(f.webView, @"const r = TextMate.system('cat; echo done'); return { out: r.outputString, status: r.status };");
	OAK_ASSERT_EQ(to_s(res[@"out"]), "done\n");
	OAK_ASSERT_EQ([res[@"status"] intValue], 0);
	Close(f);
}

void test_asynchronous_system ()
{
	fixture_t f = LoadPage();

	// Without onreadoutput, outputString accumulates
	NSDictionary* res = CallAsyncJavaScript(f.webView, @"return await new Promise(resolve => { TextMate.system('printf x; sleep 0.1; printf y; exit 2', function (cmd) { resolve({ out: cmd.outputString, status: cmd.status, thisIsHandler: this === arguments.callee }); }); });");
	OAK_ASSERT_EQ(to_s(res[@"out"]), "xy");
	OAK_ASSERT_EQ([res[@"status"] intValue], 2);
	OAK_ASSERT([res[@"thisIsHandler"] boolValue]); // called as handler.call(handler, cmd), like WebView

	// With onreadoutput, it gets each chunk as it arrives and outputString holds the last chunk
	res = CallAsyncJavaScript(f.webView, @"return await new Promise(resolve => {\n"
		"  const chunks = [];\n"
		"  const cmd = TextMate.system('echo one; sleep 0.3; echo two', (c) => resolve({ chunks: chunks, out: c.outputString }));\n"
		"  cmd.onreadoutput = (str) => chunks.push(str);\n"
		"});");
	NSArray* chunks = [res[@"chunks"] isKindOfClass:[NSArray class]] ? res[@"chunks"] : @[];
	OAK_ASSERT_EQ(to_s([chunks componentsJoinedByString:@""]), "one\ntwo\n");
	OAK_ASSERT(chunks.count >= 3); // initial call with the current output (empty), then at least one per echo
	OAK_ASSERT_EQ(to_s(res[@"out"]), "two\n");

	// stderr
	NSString* errorString = CallAsyncJavaScript(f.webView, @"return await new Promise(resolve => { TextMate.system('echo fejl >&2', (c) => resolve(c.errorString)); });");
	OAK_ASSERT_EQ(to_s(errorString), "fejl\n");
	Close(f);
}

void test_write_and_close ()
{
	fixture_t f = LoadPage();
	id res = CallAsyncJavaScript(f.webView, @"return await new Promise(resolve => { const cmd = TextMate.system('cat', (c) => resolve(c.outputString)); cmd.write('hello '); cmd.write('wørld'); cmd.close(); });");
	OAK_ASSERT_EQ(to_s(res), "hello wørld");
	Close(f);
}

void test_cancel ()
{
	fixture_t f = LoadPage();
	NSString* marker = [NSString stringWithFormat:@"sleep 29.%d", arc4random_uniform(1000000)]; // identifies the process
	id res = CallAsyncJavaScript(f.webView, [NSString stringWithFormat:@"return await new Promise(resolve => { const cmd = TextMate.system('%@', () => resolve('exit handler called')); setTimeout(() => cmd.cancel(), 200); setTimeout(() => resolve('not called'), 1000); });", marker]);
	OAK_ASSERT_EQ(to_s(res), "not called");

	// The process is gone (SIGINT is ignored when tests run in the background, so this relies on the escalation)
	int pgrepStatus = 0;
	for(size_t i = 0; i < 40 && pgrepStatus != 1; ++i) // up to 4 s
	{
		NSTask* pgrep = [NSTask new];
		pgrep.launchPath     = @"/usr/bin/pgrep";
		pgrep.arguments      = @[ @"-f", marker ];
		pgrep.standardOutput = NSFileHandle.fileHandleWithNullDevice;
		[pgrep launch];
		[pgrep waitUntilExit];
		if((pgrepStatus = pgrep.terminationStatus) != 1)
			usleep(100000);
	}
	OAK_ASSERT_EQ(pgrepStatus, 1); // no process found
	Close(f);
}

void test_properties_log_and_open ()
{
	fixture_t f = LoadPage();
	id res = CallAsyncJavaScript(f.webView, @"TextMate.isBusy = true; TextMate.progress = 0.25; TextMate.log('hello'); TextMate.open('/tmp/file.txt', 12); TextMate.open('/tmp/other.txt', '3:4'); TextMate.open('/tmp/plain.txt'); return [TextMate.isBusy, TextMate.progress];");
	OAK_ASSERT_EQ(to_s(JSONString(res)), "[true,0.25]");

	// Messages are delivered asynchronously
	for(size_t i = 0; i < 100 && [f.recorder.opens count] < 3; ++i)
		usleep(20000);

	__block BridgeRecorder* recorder = f.recorder;
	OnMain(^{
		OAK_ASSERT(recorder.busy);
		OAK_ASSERT_EQ(recorder.progress, 0.25);
		OAK_ASSERT_EQ(to_s([recorder.logs componentsJoinedByString:@","]), "hello");
		OAK_ASSERT_EQ(recorder.opens.count, (NSUInteger)3);
		OAK_ASSERT_EQ(to_s(JSONString(recorder.opens)), "[[\"/tmp/file.txt\",12],[\"/tmp/other.txt\",\"3:4\"],[\"/tmp/plain.txt\",null]]");
	});

	CallAsyncJavaScript(f.webView, @"TextMate.isBusy = false;");
	for(size_t i = 0; i < 100 && recorder.busy; ++i)
		usleep(20000);
	OAK_ASSERT(!recorder.busy);
	Close(f);
}

void test_untrusted_page ()
{
	fixture_t f = LoadPage(YES, @"x-test-untrusted://example/page");
	OAK_ASSERT_EQ(to_s(EvaluateJavaScript(f.webView, @"typeof window.TextMate")), "undefined");

	// Messages and synchronous requests made without the TextMate object are refused by the native side
	id res = CallAsyncJavaScript(f.webView, @"window.webkit.messageHandlers.textmate.postMessage({ type: 'log', message: 'sneaky' });\n"
		"const xhr = new XMLHttpRequest();\n"
		"xhr.open('POST', 'x-txmt-js://system', false);\n"
		"try { xhr.send(JSON.stringify({ command: 'echo sneaky' })); } catch(e) { return 'refused: ' + e.name; }\n"
		"return 'status ' + xhr.status + ': ' + xhr.responseText;");
	OAK_ASSERT([res hasPrefix:@"refused"] || [res isEqualToString:@"status 0: "]);

	usleep(300000);
	__block NSUInteger logCount;
	OnMain(^{ logCount = f.recorder.logs.count; });
	OAK_ASSERT_EQ(logCount, (NSUInteger)0);
	Close(f);
}

void test_disabled ()
{
	fixture_t f = LoadPage(NO);
	OAK_ASSERT_EQ(to_s(EvaluateJavaScript(f.webView, @"typeof window.TextMate")), "undefined");

	CallAsyncJavaScript(f.webView, @"window.webkit.messageHandlers.textmate.postMessage({ type: 'log', message: 'ignored' });");
	usleep(300000);
	__block NSUInteger logCount;
	OnMain(^{ logCount = f.recorder.logs.count; });
	OAK_ASSERT_EQ(logCount, (NSUInteger)0);
	Close(f);
}
