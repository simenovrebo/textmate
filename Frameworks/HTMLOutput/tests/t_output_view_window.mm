#import "scheme_test_support.h"
#import "../src/OakHTMLOutputView.h"
#import "output_view_test_support.h"

// The output view in a window, receiving key events like in TextMate

struct window_fixture_t
{
	NSWindow* window;
	OakHTMLOutputView* view;
	WindowRecorder* recorder;
};

static window_fixture_t MakeWindow (NSString* html)
{
	__block window_fixture_t f;
	OnMain(^{
		[NSApplication sharedApplication];
		f.recorder = [WindowRecorder new];
		f.window   = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 600, 400) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO];
		f.window.releasedWhenClosed = NO;
		f.window.delegate = f.recorder;
		f.view = [[OakHTMLOutputView alloc] initWithFrame:NSMakeRect(0, 0, 600, 400)];
		f.window.contentView = f.view;
		[f.window layoutIfNeeded];
		[f.window makeFirstResponder:f.view.webView];
		[f.view setContent:html];
	});
	if(!WaitForJavaScript(f.view.webView, @"document.readyState == 'complete' && document.getElementById('ready') != null"))
		fprintf(stderr, "*** timeout loading page\n");
	return f;
}

static void CloseWindow (window_fixture_t& f)
{
	OnMain(^{
		f.window.delegate = nil;
		[f.window close];
		f.window = nil;
		f.view   = nil;
	});
}

static void SendKey (window_fixture_t const& f, NSString* characters, unsigned short keyCode, NSEventModifierFlags modifiers = 0)
{
	OnMain(^{
		NSEvent* event = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:modifiers timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:f.window.windowNumber context:nil characters:characters charactersIgnoringModifiers:characters isARepeat:NO keyCode:keyCode];
		if(!(modifiers & NSEventModifierFlagCommand) || ![f.window performKeyEquivalent:event])
			[f.window sendEvent:event];
	});
}

static BOOL WaitOnMain (BOOL(^condition)(), double seconds = 5)
{
	for(size_t i = 0; i < seconds * 20; ++i)
	{
		__block BOOL res;
		OnMain(^{ res = condition(); });
		if(res)
			return YES;
		usleep(50000);
	}
	return NO;
}

void test_escape ()
{
	window_fixture_t f = MakeWindow(@"<!DOCTYPE html><p id='ready'>Press escape</p>");
	SendKey(f, @"\e", 53);
	OAK_ASSERT(WaitOnMain(^{ return (BOOL)(f.recorder.cancelOperations == 1); }));

	// Not when the page handles it
	EvaluateJavaScript(f.view.webView, @"document.addEventListener('keydown', (e) => { if(e.key == 'Escape') { window.handled = true; e.preventDefault(); } }); true");
	SendKey(f, @"\e", 53);
	OAK_ASSERT(WaitForJavaScript(f.view.webView, @"window.handled === true"));
	usleep(300000);
	OnMain(^{ OAK_ASSERT_EQ(f.recorder.cancelOperations, (NSUInteger)1); });
	CloseWindow(f);
}

void test_command_period ()
{
	window_fixture_t f = MakeWindow(@"<!DOCTYPE html><p id='ready'>Press ⌘.</p>");
	SendKey(f, @".", 47, NSEventModifierFlagCommand);
	OAK_ASSERT(WaitOnMain(^{ return (BOOL)(f.recorder.cancelOperations == 1); }));
	CloseWindow(f);
}

void test_window_close ()
{
	window_fixture_t f = MakeWindow(@"<!DOCTYPE html><p id='ready'>close</p>");
	EvaluateJavaScript(f.view.webView, @"window.close(); true");
	OAK_ASSERT(WaitOnMain(^{ return (BOOL)(f.recorder.toggles == 1); }));

	// The view can be used again afterwards
	OnMain(^{ [f.view setContent:@"<!DOCTYPE html><p id='again'>again</p>"]; });
	OAK_ASSERT(WaitForJavaScript(f.view.webView, @"document.getElementById('again') != null"));
	CloseWindow(f);
}

void test_find ()
{
	window_fixture_t f = MakeWindow(@"<!DOCTYPE html><p id='ready'>alpha beta gamma Beta</p>");

	__block FakeFindServer* server = [FakeFindServer new];
	server.findOperation = kFindOperationFind;
	server.findString    = @"beta";
	OnMain(^{ OAK_ASSERT([f.window.firstResponder tryToPerform:@selector(performFindOperation:) with:server]); }); // like the Find window
	OAK_ASSERT(WaitOnMain(^{ return (BOOL)(server.found != -1); }));
	OAK_ASSERT_EQ(server.found, (NSInteger)1);
	OAK_ASSERT_EQ(to_s(EvaluateJavaScript(f.view.webView, @"getSelection().toString()")), "beta");

	server = [FakeFindServer new];
	server.findOperation = kFindOperationFind;
	server.findString    = @"delta";
	OnMain(^{ [f.window.firstResponder tryToPerform:@selector(performFindOperation:) with:server]; });
	OAK_ASSERT(WaitOnMain(^{ return (BOOL)(server.found != -1); }));
	OAK_ASSERT_EQ(server.found, (NSInteger)0);
	CloseWindow(f);
}

void test_print ()
{
	window_fixture_t f = MakeWindow(@"<!DOCTYPE html><h1 id='ready' style='font-size: 120px'>Printed</h1>");

	NSString* path = [MakeTemporaryDirectory() stringByAppendingPathComponent:@"print.pdf"];
	__block PrintRecorder* recorder = [PrintRecorder new];
	OnMain(^{
		NSPrintInfo* info = [NSPrintInfo.sharedPrintInfo copy];
		info.jobDisposition = NSPrintSaveJob;
		info.dictionary[NSPrintJobSavingURL] = [NSURL fileURLWithPath:path];
		NSPrintOperation* printer = [f.view printOperationWithPrintInfo:info];
		printer.showsPrintPanel    = NO;
		printer.showsProgressPanel = NO;
		[printer runOperationModalForWindow:f.window delegate:recorder didRunSelector:@selector(printOperationDidRun:success:contextInfo:) contextInfo:nullptr]; // like printDocument:
	});
	OAK_ASSERT(WaitOnMain(^{ return recorder.done; }, 30));
	OAK_ASSERT(recorder.success);

	// The page is not blank
	CGPDFDocumentRef pdf = CGPDFDocumentCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path]);
	OAK_ASSERT(pdf != nullptr);
	OAK_ASSERT_EQ(CGPDFDocumentGetNumberOfPages(pdf), (size_t)1); // a one line page

	size_t const width = 200, height = 260;
	std::vector<uint8_t> pixels(width * height, 255);
	CGColorSpaceRef gray = CGColorSpaceCreateDeviceGray();
	CGContextRef context = CGBitmapContextCreate(pixels.data(), width, height, 8, width, gray, kCGImageAlphaNone);
	CGPDFPageRef page = CGPDFDocumentGetPage(pdf, 1);
	CGRect box = CGPDFPageGetBoxRect(page, kCGPDFMediaBox);
	CGContextScaleCTM(context, width / box.size.width, height / box.size.height);
	CGContextDrawPDFPage(context, page);
	size_t dark = std::count_if(pixels.begin(), pixels.end(), [](uint8_t v){ return v < 128; });
	CGContextRelease(context);
	CGColorSpaceRelease(gray);
	CGPDFDocumentRelease(pdf);
	OAK_ASSERT(dark > 50);
	CloseWindow(f);
}
