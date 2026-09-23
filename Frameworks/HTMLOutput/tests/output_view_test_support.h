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

#endif /* end of include guard: OUTPUT_VIEW_TEST_SUPPORT_H_5KQ7WM2B */
