#import "scheme_test_support.h"
#import "../src/scheme/HOCommandOutputSchemeHandler.h"
#import "../src/scheme/HOFileSchemeHandler.h"
#import <spawn.h>

static NSString* Directory;

void setup_command_output ()
{
	Directory = MakeTemporaryDirectory();
	[@"body { color: rgb(1, 2, 3); }" writeToFile:[Directory stringByAppendingPathComponent:@"style.css"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

static void Write (NSFileHandle* fh, NSString* str)
{
	[fh writeData:[str dataUsingEncoding:NSUTF8StringEncoding]];
}

static NSURL* Register (NSPipe* pipe, pid_t pid = 0)
{
	__block NSURL* url;
	OnMain(^{ url = [HOCommandOutputSchemeHandler URLForOutputFromFileHandle:pipe.fileHandleForReading processIdentifier:pid name:@"Test/Command"]; });
	return url;
}

// Wait (up to 10 s) until the task has received data containing the string
static BOOL WaitForData (FakeSchemeTask* task, NSString* str)
{
	for(size_t i = 0; i < 1000; ++i)
	{
		__block BOOL found;
		OnMain(^{ found = [[task string] containsString:str]; });
		if(found)
			return YES;
		usleep(10000);
	}
	return NO;
}

void test_url ()
{
	NSURL* url = Register([NSPipe pipe]);
	OAK_ASSERT_EQ(to_s(url.scheme), "x-txmt-filehandle");
	OAK_ASSERT_EQ(to_s(url.host), "job");
	OAK_ASSERT([url.absoluteString containsString:@"/Test%2FCommand/"]);
	OAK_ASSERT(![url isEqual:Register([NSPipe pipe])]);
}

void test_streams_and_rewrites_output ()
{
	HOCommandOutputSchemeHandler* handler = [HOCommandOutputSchemeHandler new];
	NSPipe* pipe = [NSPipe pipe];
	NSURL* url = Register(pipe);

	FakeSchemeTask* task = StartTask(handler, url.absoluteString);
	Write(pipe.fileHandleForWriting, @"<link href=\"file:///a.css\"><p>one</p>");
	OAK_ASSERT(WaitForData(task, @"<p>one</p>"));
	OAK_ASSERT(!task.finished);

	Write(pipe.fileHandleForWriting, @"<p>two</p><img src='fi");
	OAK_ASSERT(WaitForData(task, @"<p>two</p>"));
	Write(pipe.fileHandleForWriting, @"le:///b.png'>");
	[pipe.fileHandleForWriting closeFile];

	OAK_ASSERT(WaitForTask(task));
	OAK_ASSERT(task.finished);
	OAK_ASSERT_EQ(to_s(task.response.MIMEType), "text/html");
	OAK_ASSERT_EQ(to_s(task.response.textEncodingName), "utf-8");
	OAK_ASSERT_EQ(to_s([task string]), "<link href=\"tm-file:///a.css\"><p>one</p><p>two</p><img src='tm-file:///b.png'>");
	OAK_ASSERT(task.chunks >= 3);

	// The original output is recorded (for View Source) and can be loaded again (reload, back/forward)
	__block NSData* recorded;
	OnMain(^{ recorded = [HOCommandOutputSchemeHandler outputForURL:url]; });
	OAK_ASSERT_EQ(to_s([[NSString alloc] initWithData:recorded encoding:NSUTF8StringEncoding]), "<link href=\"file:///a.css\"><p>one</p><p>two</p><img src='file:///b.png'>");

	FakeSchemeTask* reload = StartTask(handler, url.absoluteString);
	OAK_ASSERT(WaitForTask(reload));
	OAK_ASSERT_EQ(to_s([reload string]), to_s([task string]));

	OnMain(^{ [HOCommandOutputSchemeHandler removeOutputForURL:url]; });
	FakeSchemeTask* removed = StartTask(handler, url.absoluteString);
	OAK_ASSERT(WaitForTask(removed));
	OAK_ASSERT_EQ(((NSHTTPURLResponse*)removed.response).statusCode, (NSInteger)404);
}

void test_second_task_while_running ()
{
	HOCommandOutputSchemeHandler* handler = [HOCommandOutputSchemeHandler new];
	NSPipe* pipe = [NSPipe pipe];
	NSURL* url = Register(pipe);

	FakeSchemeTask* first = StartTask(handler, url.absoluteString);
	Write(pipe.fileHandleForWriting, @"<p>one</p>");
	OAK_ASSERT(WaitForData(first, @"<p>one</p>"));

	FakeSchemeTask* second = StartTask(handler, url.absoluteString);
	Write(pipe.fileHandleForWriting, @"<p>two</p>");
	[pipe.fileHandleForWriting closeFile];

	OAK_ASSERT(WaitForTask(first));
	OAK_ASSERT(WaitForTask(second));
	OAK_ASSERT_EQ(to_s([first string]),  "<p>one</p><p>two</p>");
	OAK_ASSERT_EQ(to_s([second string]), "<p>one</p><p>two</p>");
}

void test_stop_kills_command ()
{
	// A “command” in its own process group, like bundle commands
	posix_spawnattr_t attr;
	posix_spawnattr_init(&attr);
	posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETPGROUP);
	posix_spawnattr_setpgroup(&attr, 0);
	pid_t pid;
	char const* argv[] = { "/bin/sleep", "30", nullptr };
	OAK_ASSERT_EQ(posix_spawn(&pid, argv[0], nullptr, &attr, (char* const*)argv, nullptr), 0);
	posix_spawnattr_destroy(&attr);

	HOCommandOutputSchemeHandler* handler = [HOCommandOutputSchemeHandler new];
	NSPipe* pipe = [NSPipe pipe];
	NSURL* url = Register(pipe, pid);

	FakeSchemeTask* task = StartTask(handler, url.absoluteString);
	Write(pipe.fileHandleForWriting, @"<p>running</p>");
	OAK_ASSERT(WaitForData(task, @"<p>running</p>"));

	StopTask(handler, task);

	int status = 0;
	pid_t res = 0;
	for(size_t i = 0; i < 500 && res == 0; ++i) // up to 5 s
	{
		res = waitpid(pid, &status, WNOHANG);
		if(res == 0)
			usleep(10000);
	}
	OAK_ASSERT_EQ(res, pid);
	OAK_ASSERT(WIFSIGNALED(status));

	// Output after the stop must not be sent to the (stopped) task
	Write(pipe.fileHandleForWriting, @"<p>after stop</p>");
	[pipe.fileHandleForWriting closeFile];
	for(size_t i = 0; i < 500; ++i)
	{
		__block BOOL complete;
		OnMain(^{ complete = [HOCommandOutputSchemeHandler isOutputCompleteForURL:url]; });
		if(complete)
			break;
		usleep(10000);
	}
	OAK_ASSERT(!task.usedAfterStop);
	OAK_ASSERT(!task.finished);
	OAK_ASSERT(![[task string] containsString:@"after stop"]);
}

void test_unknown_and_untrusted ()
{
	HOCommandOutputSchemeHandler* handler = [HOCommandOutputSchemeHandler new];

	FakeSchemeTask* task = StartTask(handler, @"x-txmt-filehandle://job/Unknown/999999");
	OAK_ASSERT(WaitForTask(task));
	OAK_ASSERT_EQ(((NSHTTPURLResponse*)task.response).statusCode, (NSInteger)404);

	task = StartTask(handler, @"x-txmt-filehandle://cdn.example.com/lib.js", @"https://example.com/");
	OAK_ASSERT(WaitForTask(task));
	OAK_ASSERT_EQ(task.error.code, (NSInteger)NSURLErrorNoPermissionsToReadFile);
}

// ============================================================
// = End to end: streamed command output in a real WKWebView =
// ============================================================

static id EvaluateJavaScript (WKWebView* webView, NSString* script)
{
	__block id result;
	dispatch_semaphore_t sem = dispatch_semaphore_create(0);
	OnMain(^{
		[webView evaluateJavaScript:script completionHandler:^(id res, NSError* error){
			result = res;
			dispatch_semaphore_signal(sem);
		}];
	});
	dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
	return result;
}

static BOOL WaitForJavaScript (WKWebView* webView, NSString* condition)
{
	for(size_t i = 0; i < 200; ++i) // up to 10 s
	{
		if([EvaluateJavaScript(webView, condition) boolValue])
			return YES;
		usleep(50000);
	}
	return NO;
}

void test_web_view ()
{
	__block WKWebView* webView;
	NSPipe* pipe = [NSPipe pipe];
	NSURL* url = Register(pipe);

	OnMain(^{
		WKWebViewConfiguration* config = [WKWebViewConfiguration new];
		[config setURLSchemeHandler:[HOCommandOutputSchemeHandler new] forURLScheme:kHOCommandOutputURLScheme];
		[config setURLSchemeHandler:[HOFileSchemeHandler new] forURLScheme:kHOFileURLScheme];
		webView = [[WKWebView alloc] initWithFrame:NSMakeRect(0, 0, 400, 300) configuration:config];
		[webView loadRequest:[NSURLRequest requestWithURL:url]];
	});

	NSString* css = [@"file://" stringByAppendingString:[[Directory stringByAppendingPathComponent:@"style.css"] stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLPathAllowedCharacterSet]];
	Write(pipe.fileHandleForWriting, [NSString stringWithFormat:@"<!DOCTYPE html><html><head><link rel=\"stylesheet\" href=\"%@\"></head><body><p id=\"one\">Grønn</p>\n", css]);

	// Rendered while the command is still running
	OAK_ASSERT(WaitForJavaScript(webView, @"document.getElementById('one') != null"));
	OAK_ASSERT_EQ(to_s(EvaluateJavaScript(webView, @"document.getElementById('one').textContent")), "Grønn");

	Write(pipe.fileHandleForWriting, @"<p id=\"two\">file://not/a/url</p></body></html>\n");
	[pipe.fileHandleForWriting closeFile];

	OAK_ASSERT(WaitForJavaScript(webView, @"document.readyState == 'complete' && document.getElementById('two') != null"));
	OAK_ASSERT_EQ(to_s(EvaluateJavaScript(webView, @"document.getElementById('two').textContent")), "file://not/a/url");

	// The file:// stylesheet was loaded (via tm-file://)
	OAK_ASSERT(WaitForJavaScript(webView, @"getComputedStyle(document.body).color == 'rgb(1, 2, 3)'"));
	OAK_ASSERT([EvaluateJavaScript(webView, @"document.styleSheets[0].href") hasPrefix:@"tm-file://"]);

	OnMain(^{ webView = nil; });
}
