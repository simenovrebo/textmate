#import "scheme_test_support.h"
#import "../src/OakHTMLOutputView.h"
#import "../src/browser/HOStatusBar.h"
#import "output_view_test_support.h"
#import <spawn.h>

static OakHTMLOutputView* MakeView ()
{
	__block OakHTMLOutputView* view;
	OnMain(^{
		view = [[OakHTMLOutputView alloc] initWithFrame:NSMakeRect(0, 0, 400, 300)];
		[view layoutSubtreeIfNeeded]; // give the web view a size (for scrolling)
	});
	return view;
}

static void Write (NSFileHandle* fh, NSString* str)
{
	[fh writeData:[str dataUsingEncoding:NSUTF8StringEncoding]];
}

// Wait (up to 10 s) for a condition evaluated on the main thread
static BOOL WaitOnMain (BOOL(^condition)())
{
	for(size_t i = 0; i < 200; ++i)
	{
		__block BOOL res;
		OnMain(^{ res = condition(); });
		if(res)
			return YES;
		usleep(50000);
	}
	return NO;
}

static void SetContent (OakHTMLOutputView* view, NSString* html, NSString* condition)
{
	OnMain(^{ [view setContent:html]; });
	if(!WaitForJavaScript(view.webView, [NSString stringWithFormat:@"document.readyState == 'complete' && (%@)", condition]))
		fprintf(stderr, "*** timeout waiting for %s\n", condition.UTF8String);
}

void test_trusted_url ()
{
	OAK_ASSERT( [HOSchemeHandler isTrustedURL:[NSURL URLWithString:@"x-txmt-filehandle://job/Command/1"]]);
	OAK_ASSERT(![HOSchemeHandler isTrustedURL:[NSURL URLWithString:@"x-txmt-filehandle://cdn.example.com/lib.js"]]);
	OAK_ASSERT( [HOSchemeHandler isTrustedURL:[NSURL URLWithString:@"tm-file:///tmp/index.html"]]);
	OAK_ASSERT( [HOSchemeHandler isTrustedURL:[NSURL URLWithString:@"tm-file://localhost/tmp/index.html"]]);
	OAK_ASSERT(![HOSchemeHandler isTrustedURL:[NSURL URLWithString:@"tm-file://cdn.example.com/lib.js"]]);
	OAK_ASSERT(![HOSchemeHandler isTrustedURL:[NSURL URLWithString:@"https://example.com/"]]);
}

void test_command_output ()
{
	OakHTMLOutputView* view = MakeView();
	NSPipe* pipe = [NSPipe pipe];
	NSObject* command = [NSObject new];
	OnMain(^{
		[view loadOutputFromFileHandle:pipe.fileHandleForReading processIdentifier:0 name:@"Output Test" command:command environment:{ { "TM_TEST_VARIABLE", "grønn" } } autoScrolls:NO];
	});

	Write(pipe.fileHandleForWriting, @"<!DOCTYPE html><p id='one'>one</p>\n");
	OAK_ASSERT(WaitForJavaScript(view.webView, @"document.getElementById('one') != null"));

	// While the command runs, the title is the command name
	__block BOOL running;
	__block NSString* title;
	OnMain(^{ running = view.isRunningCommand; title = view.mainFrameTitle; });
	OAK_ASSERT(running);
	OAK_ASSERT_EQ(to_s(title), "Output Test");

	// The TextMate object, with the command’s environment
	id res = CallAsyncJavaScript(view.webView, @"return TextMate.system('echo $TM_TEST_VARIABLE', null).outputString;");
	OAK_ASSERT_EQ(to_s(res), "grønn\n");

	// file:// URLs set from JavaScript are changed to tm-file://
	res = CallAsyncJavaScript(view.webView, @"const img = document.createElement('img'); img.src = 'file:///tmp/a.png'; const link = document.createElement('link'); link.setAttribute('href', 'file:///tmp/b.css'); return img.getAttribute('src') + ' ' + link.getAttribute('href');");
	OAK_ASSERT_EQ(to_s(res), "tm-file:///tmp/a.png tm-file:///tmp/b.css");

	Write(pipe.fileHandleForWriting, @"<title>Page Title</title><p id='two'>two</p>\n");
	[pipe.fileHandleForWriting closeFile];

	OAK_ASSERT(WaitOnMain(^{ return (BOOL)!view.isRunningCommand; }));
	OAK_ASSERT_EQ(to_s(EvaluateJavaScript(view.webView, @"document.getElementById('two').textContent")), "two");
	OnMain(^{ title = view.mainFrameTitle; });
	OAK_ASSERT_EQ(to_s(title), "Page Title");

	// When the command is not running, there is nothing to stop
	__block BOOL didStop = NO;
	OnMain(^{ [view stopLoadingWithUserInteraction:NO completionHandler:^(BOOL flag){ didStop = flag; }]; });
	OAK_ASSERT(didStop);
}

void test_stop ()
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

	OakHTMLOutputView* view = MakeView();
	NSPipe* pipe = [NSPipe pipe];
	NSObject* command = [NSObject new];
	OnMain(^{
		[view loadOutputFromFileHandle:pipe.fileHandleForReading processIdentifier:pid name:@"Stop Test" command:command environment:{ } autoScrolls:YES];
	});

	Write(pipe.fileHandleForWriting, @"<!DOCTYPE html><p id='running'>running</p>\n");
	OAK_ASSERT(WaitForJavaScript(view.webView, @"document.getElementById('running') != null"));

	__block BOOL called = NO, didStop = NO;
	OnMain(^{
		[view stopLoadingWithUserInteraction:NO completionHandler:^(BOOL flag){
			called  = YES;
			didStop = flag;
		}];
	});

	// The process group is killed…
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

	// …and the completion handler is called when the command has terminated
	OnMain(^{ OAK_ASSERT(!called); });
	OnMain(^{ [NSNotificationCenter.defaultCenter postNotificationName:@"OakCommandDidTerminateNotification" object:command]; });
	OAK_ASSERT(WaitOnMain(^{ return called; }));
	OAK_ASSERT(didStop);
	OAK_ASSERT(WaitOnMain(^{ return (BOOL)!view.isRunningCommand; }));

	[pipe.fileHandleForWriting closeFile];
}

void test_set_content ()
{
	OakHTMLOutputView* view = MakeView();
	SetContent(view, @"<!DOCTYPE html><div style='height: 3000px'><a id='first' href='file:///tmp/file.txt'>link</a></div>", @"document.getElementById('first') != null");

	// Like command output: file:// is rewritten and the TextMate object is available
	OAK_ASSERT_EQ(to_s(EvaluateJavaScript(view.webView, @"document.getElementById('first').getAttribute('href')")), "tm-file:///tmp/file.txt");
	OAK_ASSERT_EQ(to_s(EvaluateJavaScript(view.webView, @"typeof TextMate")), "object");

	// The scroll position is kept when the content is replaced
	EvaluateJavaScript(view.webView, @"window.scrollTo(0, 500)");
	OAK_ASSERT(WaitForJavaScript(view.webView, @"window.scrollY == 500"));
	SetContent(view, @"<!DOCTYPE html><div style='height: 3000px' id='second'>replaced</div>", @"document.getElementById('second') != null");
	OAK_ASSERT(WaitForJavaScript(view.webView, @"window.scrollY == 500"));
}

void test_status_text ()
{
	OakHTMLOutputView* view = MakeView();
	SetContent(view, @"<!DOCTYPE html><a id='link' href='txmt://open?url=file:///tmp/a%20b.txt&amp;line=3'>link</a>", @"document.getElementById('link') != null");

	EvaluateJavaScript(view.webView, @"document.getElementById('link').dispatchEvent(new MouseEvent('mouseover', { bubbles: true })); true");
	OAK_ASSERT(WaitOnMain(^{ return [view.statusBar.statusText isEqualToString:@"txmt://open?url=file:///tmp/a b.txt&line=3"]; }));

	EvaluateJavaScript(view.webView, @"document.getElementById('link').dispatchEvent(new MouseEvent('mouseout', { bubbles: true, relatedTarget: null })); true");
	OAK_ASSERT(WaitOnMain(^{ return [view.statusBar.statusText isEqualToString:@""]; }));
}

void test_txmt_link ()
{
	__block TxMtURLRecorder* recorder;
	OnMain(^{
		recorder = [TxMtURLRecorder new];
		[NSApplication sharedApplication].delegate = recorder;
	});

	OakHTMLOutputView* view = MakeView();
	NSPipe* pipe = [NSPipe pipe];
	OnMain(^{
		[view loadOutputFromFileHandle:pipe.fileHandleForReading processIdentifier:0 name:@"Link Test" command:nil environment:{ { "TM_PROJECT_UUID", "F1C1A5E2-0000-4000-8000-000000000001" } } autoScrolls:NO];
	});
	Write(pipe.fileHandleForWriting, @"<!DOCTYPE html><a id='link' href='txmt://open?url=file:///tmp/file.txt&amp;line=2'>link</a>");
	[pipe.fileHandleForWriting closeFile];
	OAK_ASSERT(WaitForJavaScript(view.webView, @"document.readyState == 'complete' && document.getElementById('link') != null"));

	EvaluateJavaScript(view.webView, @"document.getElementById('link').click(); true");
	OAK_ASSERT(WaitOnMain(^{ return (BOOL)(recorder.urls.count == 1); }));
	OnMain(^{
		OAK_ASSERT_EQ(to_s(recorder.urls.firstObject.absoluteString), "txmt://open?url=file:///tmp/file.txt&line=2&project=F1C1A5E2-0000-4000-8000-000000000001");
		NSApp.delegate = nil;
	});

	// The page is not replaced
	OAK_ASSERT_EQ(to_s(EvaluateJavaScript(view.webView, @"location.protocol")), "x-txmt-filehandle:");
}

void test_protocol_relative_link ()
{
	// //example.invalid/page.html in command output resolves to x-txmt-filehandle://example.invalid/page.html,
	// which must be loaded as a web page (https), not as trusted command output
	OakHTMLOutputView* view = MakeView();
	SetContent(view, @"<!DOCTYPE html><a id='link' href='//example.invalid/page.html'>link</a>", @"document.getElementById('link') != null");
	EvaluateJavaScript(view.webView, @"document.getElementById('link').click(); true");

	// example.invalid never resolves, so the load fails
	OAK_ASSERT(WaitForJavaScript(view.webView, @"document.title == 'Load Error' && document.body.textContent.includes('https://example.invalid/page.html')"));
	OAK_ASSERT_EQ(to_s(EvaluateJavaScript(view.webView, @"typeof TextMate")), "undefined");
}
