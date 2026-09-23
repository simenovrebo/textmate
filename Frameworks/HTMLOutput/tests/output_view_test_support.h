#ifndef OUTPUT_VIEW_TEST_SUPPORT_H_5KQ7WM2B
#define OUTPUT_VIEW_TEST_SUPPORT_H_5KQ7WM2B

// Objective-C classes for t_output_view.mm (test files are wrapped in a namespace by gen_test,
// where Objective-C declarations are not allowed)

// Application delegate receiving the txmt: URLs opened by the view (sent as handleTxMtURL: to the responder chain)
@interface TxMtURLRecorder : NSObject <NSApplicationDelegate>
@property (nonatomic) NSMutableArray<NSURL*>* urls;
@end

@implementation TxMtURLRecorder
- (instancetype)init
{
	if(self = [super init])
		_urls = [NSMutableArray array];
	return self;
}

- (void)handleTxMtURL:(NSURL*)url
{
	[_urls addObject:url];
}
@end

// Window delegate recording actions sent up the responder chain by the view
@interface WindowRecorder : NSObject <NSWindowDelegate>
@property (nonatomic) NSUInteger cancelOperations;
@property (nonatomic) NSUInteger toggles;
@end

@implementation WindowRecorder
- (void)cancelOperation:(id)sender  { ++_cancelOperations; }
- (void)toggleHTMLOutput:(id)sender { ++_toggles; }
@end

// Find server as used by the Find window
#import <OakFoundation/OakFindProtocol.h>

@interface FakeFindServer : NSObject <OakFindServerProtocol>
@property (nonatomic) find_operation_t findOperation;
@property (nonatomic) NSString* findString;
@property (nonatomic) NSString* replaceString;
@property (nonatomic) find::options_t findOptions;
@property (nonatomic) NSInteger found; // -1 until didFind:… is called
@end

@implementation FakeFindServer
- (instancetype)init
{
	if(self = [super init])
		_found = -1;
	return self;
}
- (void)didFind:(NSUInteger)aNumber occurrencesOf:(NSString*)aFindString atPosition:(text::pos_t const&)aPosition wrapped:(BOOL)didWrap { _found = aNumber; }
- (void)didReplace:(NSUInteger)aNumber occurrencesOf:(NSString*)aFindString with:(NSString*)aReplacementString { }
@end

// Delegate for NSPrintOperation’s runOperationModalForWindow:…
@interface PrintRecorder : NSObject
@property (nonatomic) BOOL done;
@property (nonatomic) BOOL success;
@end

@implementation PrintRecorder
- (void)printOperationDidRun:(NSPrintOperation*)printOperation success:(BOOL)success contextInfo:(void*)contextInfo
{
	_success = success;
	_done    = YES;
}
@end

#endif /* end of include guard: OUTPUT_VIEW_TEST_SUPPORT_H_5KQ7WM2B */
