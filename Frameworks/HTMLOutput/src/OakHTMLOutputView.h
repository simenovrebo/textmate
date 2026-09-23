#import "browser/HOBrowserView.h"
@interface OakHTMLOutputView : HOBrowserView
- (void)loadOutputFromFileHandle:(NSFileHandle*)fileHandle processIdentifier:(pid_t)processIdentifier name:(NSString*)name command:(id)command environment:(std::map<std::string, std::string> const&)anEnvironment autoScrolls:(BOOL)flag;
- (void)stopLoadingWithUserInteraction:(BOOL)askUserFlag completionHandler:(void(^)(BOOL didStop))handler;
- (void)setContent:(NSString*)someHTML;

@property (nonatomic, readonly) NSString* mainFrameTitle;
@property (nonatomic) NSUUID* commandIdentifier;
@property (nonatomic, getter = isRunningCommand, readonly) BOOL runningCommand;
@property (nonatomic, getter = isReusable) BOOL reusable;
@property (nonatomic) BOOL disableJavaScriptAPI;
@end
