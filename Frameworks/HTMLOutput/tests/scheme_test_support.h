#ifndef SCHEME_TEST_SUPPORT_H_8NVX2Q4L
#define SCHEME_TEST_SUPPORT_H_8NVX2Q4L

#import <WebKit/WebKit.h>
#import "../src/scheme/HOSchemeHandler.h"
#import <ns/ns.h>
#include <string>

// A WKURLSchemeTask that records what the handler does with it. Like WebKit, using the task after it
// was stopped is an error (WebKit raises NSInternalInconsistencyException), recorded in usedAfterStop.

@interface FakeSchemeTask : NSObject <WKURLSchemeTask>
@property (nonatomic, readonly, copy) NSURLRequest* request;
@property (nonatomic) NSURLResponse* response;
@property (nonatomic) NSMutableData* data;
@property (nonatomic) NSUInteger chunks;
@property (nonatomic) BOOL finished;
@property (nonatomic) NSError* error;
@property (nonatomic) BOOL stopped;
@property (nonatomic) BOOL usedAfterStop;
@property (nonatomic) dispatch_semaphore_t done;
@end

@implementation FakeSchemeTask
- (instancetype)initWithRequest:(NSURLRequest*)request
{
	if(self = [super init])
	{
		_request = request;
		_data    = [NSMutableData data];
		_done    = dispatch_semaphore_create(0);
	}
	return self;
}
- (void)didReceiveResponse:(NSURLResponse*)response { if(_stopped) _usedAfterStop = YES; _response = response; }
- (void)didReceiveData:(NSData*)data                { if(_stopped) _usedAfterStop = YES; [_data appendData:data]; ++_chunks; }
- (void)didFinish                                   { if(_stopped) _usedAfterStop = YES; _finished = YES; dispatch_semaphore_signal(_done); }
- (void)didFailWithError:(NSError*)error            { if(_stopped) _usedAfterStop = YES; _error = error; dispatch_semaphore_signal(_done); }
- (NSString*)string                                 { return [[NSString alloc] initWithData:_data encoding:NSUTF8StringEncoding]; }
@end

// Tests run on background threads while the main run loop runs; scheme handlers are used on the main thread.

// The handlers do not use the web view argument
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wnonnull"
static void StartSchemeTask (HOSchemeHandler* handler, id <WKURLSchemeTask> task) { [handler webView:nil startURLSchemeTask:task]; }
static void StopSchemeTask (HOSchemeHandler* handler, id <WKURLSchemeTask> task)  { [handler webView:nil stopURLSchemeTask:task]; }
#pragma clang diagnostic pop
static void OnMain (void(^block)())
{
	dispatch_sync(dispatch_get_main_queue(), block);
}

static FakeSchemeTask* StartTask (HOSchemeHandler* handler, NSString* urlString, NSString* mainDocumentURLString = nil)
{
	NSMutableURLRequest* request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlString]];
	request.mainDocumentURL = mainDocumentURLString ? [NSURL URLWithString:mainDocumentURLString] : request.URL;
	FakeSchemeTask* task = [[FakeSchemeTask alloc] initWithRequest:request];
	OnMain(^{ StartSchemeTask(handler, task); });
	return task;
}

static void StopTask (HOSchemeHandler* handler, FakeSchemeTask* task)
{
	OnMain(^{
		task.stopped = YES;
		StopSchemeTask(handler, task);
	});
}

static BOOL WaitForTask (FakeSchemeTask* task, double seconds = 10)
{
	return dispatch_semaphore_wait(task.done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC))) == 0;
}

static NSString* MakeTemporaryDirectory ()
{
	std::string tmpl = std::string(NSTemporaryDirectory().fileSystemRepresentation) + "/HTMLOutput-test.XXXXXX";
	return mkdtemp(&tmpl[0]) ? [NSString stringWithUTF8String:tmpl.c_str()] : nil;
}

#endif /* end of include guard: SCHEME_TEST_SUPPORT_H_8NVX2Q4L */
