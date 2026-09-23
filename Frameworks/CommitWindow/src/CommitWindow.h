// The commit tool (tool/commit.mm) connects to TextMate’s server socket, oak::ipc::socket_path(kOakCommitWindowSocketName, TM_PID),
// sends the arguments and environment, and receives the output and return code (see oak/ipc.h).
static char const* const kOakCommitWindowSocketName          = "tm-commit-window";

static NSString* const kOakCommitWindowArguments            = @"arguments";
static NSString* const kOakCommitWindowEnvironment          = @"environment";
static NSString* const kOakCommitWindowStandardOutput       = @"stdout";
static NSString* const kOakCommitWindowStandardError        = @"stderr";
static NSString* const kOakCommitWindowReturnCode           = @"returnCode";
static NSString* const kOakCommitWindowContinue             = @"continue";

@interface OakCommitWindowServer : NSObject
@property (class, readonly) OakCommitWindowServer* sharedInstance;
@end
