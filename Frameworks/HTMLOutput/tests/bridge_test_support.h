#ifndef BRIDGE_TEST_SUPPORT_H_3DLW9K7A
#define BRIDGE_TEST_SUPPORT_H_3DLW9K7A

// Objective-C classes for t_script_bridge.mm (test files are wrapped in a namespace by gen_test,
// where Objective-C declarations are not allowed)

#import "../src/bridge/HOScriptBridge.h"

// Records what the TextMate object asks the native side to do
@interface BridgeRecorder : NSObject <HOScriptBridgeDelegate>
@property (nonatomic, getter = isBusy) BOOL busy;
@property (nonatomic) double progress;
@property (nonatomic) NSMutableArray* logs;
@property (nonatomic) NSMutableArray* opens;
@end

@implementation BridgeRecorder
- (instancetype)init
{
	if(self = [super init])
	{
		_logs  = [NSMutableArray array];
		_opens = [NSMutableArray array];
	}
	return self;
}
@end

// Serves a page from a scheme that is not trusted with the TextMate object
@interface UntrustedSchemeHandler : HOSchemeHandler
@end

@implementation UntrustedSchemeHandler
- (void)startTask:(id <WKURLSchemeTask>)task
{
	[self task:task respondWithHTML:@"<!DOCTYPE html><p>untrusted</p>" statusCode:200];
}
@end

#endif /* end of include guard: BRIDGE_TEST_SUPPORT_H_3DLW9K7A */
