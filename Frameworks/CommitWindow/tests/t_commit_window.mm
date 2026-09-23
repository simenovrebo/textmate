#import "../src/CommitWindow.h"
#import <oak/ipc.h>
#import <ns/ns.h>
#import <mach-o/dyld.h>
#import "commit_window_test_support.h"

// Runs the commit tool against the server in this process, like a bundle command does, and completes the
// commit window with the given action (performCommit: or cancel:).

static NSString* ToolPath ()
{
	char buf[PATH_MAX];
	uint32_t size = sizeof(buf);
	if(_NSGetExecutablePath(buf, &size) != 0)
		return nil;
	// <build>/_Test/CommitWindow/test_CommitWindow → <build>/Frameworks/CommitWindow/CommitWindowTool
	NSString* build = [[[@(buf) stringByResolvingSymlinksInPath] stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"../.."];
	return [[build stringByAppendingPathComponent:@"Frameworks/CommitWindow/CommitWindowTool"] stringByStandardizingPath];
}

static NSWindowController* WaitForCommitWindow (NSWindow* projectWindow)
{
	for(size_t i = 0; i < 200; ++i) // up to 10 s
	{
		__block NSWindowController* res;
		dispatch_sync(dispatch_get_main_queue(), ^{
			if([projectWindow.attachedSheet.delegate isKindOfClass:NSClassFromString(@"OakCommitWindow")])
				res = (NSWindowController*)projectWindow.attachedSheet.delegate;
		});
		if(res)
			return res;
		usleep(50000);
	}
	return nil;
}

struct result_t
{
	int status;
	std::string output;
	std::string error;
};

static result_t RunCommit (NSArray* arguments, SEL action)
{
	__block result_t res = { -1 };

	NSString* toolPath = ToolPath();
	if(![NSFileManager.defaultManager isExecutableFileAtPath:toolPath])
	{
		res.error = "tool not found: " + to_s(toolPath);
		return res;
	}

	// The commit window is shown as a sheet on the project window
	__block NSWindow* projectWindow;
	__block ProjectWindowDelegate* projectDelegate;
	NSString* projectIdentifier = NSUUID.UUID.UUIDString;
	dispatch_sync(dispatch_get_main_queue(), ^{
		[NSApplication sharedApplication];
		[OakCommitWindowServer sharedInstance];

		projectDelegate = [ProjectWindowDelegate new];
		projectDelegate.identifier = projectIdentifier;
		projectWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 700, 500) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
		projectWindow.releasedWhenClosed = NO;
		projectWindow.delegate = projectDelegate;
		[projectWindow orderFront:nil];
	});

	NSTask* task = [NSTask new];
	NSPipe* outPipe = [NSPipe pipe];
	NSPipe* errPipe = [NSPipe pipe];
	task.launchPath     = toolPath;
	task.arguments      = arguments;
	task.standardOutput = outPipe;
	task.standardError  = errPipe;
	NSMutableDictionary* env = [NSProcessInfo.processInfo.environment mutableCopy];
	env[@"TM_PID"]          = [NSString stringWithFormat:@"%d", getpid()];
	env[@"TM_PROJECT_UUID"] = projectIdentifier;
	task.environment = env;
	[task launch];

	if(NSWindowController* commitWindow = WaitForCommitWindow(projectWindow))
	{
		dispatch_sync(dispatch_get_main_queue(), ^{
			[NSApp sendAction:action to:commitWindow from:nil];
		});
	}

	NSData* output = [outPipe.fileHandleForReading readDataToEndOfFile];
	NSData* error  = [errPipe.fileHandleForReading readDataToEndOfFile];
	[task waitUntilExit];

	dispatch_sync(dispatch_get_main_queue(), ^{
		projectWindow.delegate = nil;
		[projectWindow close];
	});

	res.status = task.terminationStatus;
	res.output = std::string((char const*)output.bytes, output.length);
	res.error  = std::string((char const*)error.bytes, error.length);
	return res;
}

void test_commit ()
{
	result_t res = RunCommit(@[ @"--log", @"It's a fix", @"--status", @"M", @"file one.txt" ], @selector(performCommit:));
	OAK_ASSERT_EQ(res.error, "");
	OAK_ASSERT_EQ(res.status, 0);
	OAK_ASSERT_EQ(res.output, " -m 'It'\"'\"'s a fix'  file\\ one.txt \n");
}

void test_cancel ()
{
	result_t res = RunCommit(@[ @"--status", @"M", @"file.txt" ], @selector(cancel:));
	OAK_ASSERT_EQ(res.status, 1);
	OAK_ASSERT_EQ(res.output, "");
}

void test_no_server ()
{
	NSTask* task = [NSTask new];
	task.launchPath      = ToolPath();
	task.arguments       = @[ @"file.txt" ];
	task.standardError   = [NSFileHandle fileHandleWithNullDevice];
	NSMutableDictionary* env = [NSProcessInfo.processInfo.environment mutableCopy];
	env[@"TM_PID"] = @"1"; // launchd, no commit window server
	task.environment = env;
	[task launch];
	[task waitUntilExit];
	OAK_ASSERT_EQ(task.terminationStatus, EX_UNAVAILABLE);
}
