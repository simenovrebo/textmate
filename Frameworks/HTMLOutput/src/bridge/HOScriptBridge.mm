#import "HOScriptBridge.h"
#import "HOScriptBridgeJS.h"
#import "../helpers/add_to_buffer.h"
#import <OakAppKit/NSAlert Additions.h>
#import <OakFoundation/NSString Additions.h>
#import <document/OakDocument.h>
#import <document/OakDocumentController.h>
#import <io/exec.h>
#import <ns/ns.h>
#import <oak/debug.h>

NSString* const kHOScriptBridgeURLScheme = @"x-txmt-js";

static BOOL IsTrustedScheme (NSString* scheme)
{
	return [@[ @"x-txmt-filehandle", @"tm-file" ] containsObject:scheme];
}

static NSString* JSONString (id obj)
{
	NSData* data = [NSJSONSerialization dataWithJSONObject:obj options:NSJSONWritingFragmentsAllowed|NSJSONWritingWithoutEscapingSlashes error:nullptr];
	return data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"null";
}

// ===================
// = Running Command =
// ===================

// Runs a shell command, reporting output (split at UTF-8 character boundaries) and exit on the main thread.
@interface HOScriptCommand : NSObject
- (instancetype)initWithCommand:(NSString*)command environment:(std::map<std::string, std::string> const&)environment closeInput:(BOOL)closeInput output:(void(^)(NSString* str, BOOL isError))outputHandler exit:(void(^)(int status))exitHandler;
- (void)write:(NSString*)str;
- (void)closeInput;
- (void)cancel;
@property (nonatomic, readonly) pid_t processIdentifier;
@end

@implementation HOScriptCommand
{
	io::process_t _process;
	void(^_outputHandler)(NSString*, BOOL);
	void(^_exitHandler)(int);
	BOOL _cancelled;
}

- (instancetype)initWithCommand:(NSString*)command environment:(std::map<std::string, std::string> const&)environment closeInput:(BOOL)closeInput output:(void(^)(NSString* str, BOOL isError))outputHandler exit:(void(^)(int status))exitHandler
{
	if(!(self = [super init]))
		return nil;

	_outputHandler = outputHandler;
	_exitHandler   = exitHandler;
	_process       = io::spawn(std::vector<std::string>{ "/bin/sh", "-c", to_s(command) }, environment);
	if(!_process)
	{
		dispatch_async(dispatch_get_main_queue(), ^{ if(_exitHandler) _exitHandler(-1); });
		return self;
	}

	if(closeInput)
		[self closeInput];

	dispatch_group_t group = dispatch_group_create();
	[self readFileDescriptor:_process.out isError:NO group:group];
	[self readFileDescriptor:_process.err isError:YES group:group];

	pid_t pid = _process.pid;
	__block int status = -1;
	dispatch_group_async(group, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
		int result = 0;
		if(waitpid(pid, &result, 0) == pid && WIFEXITED(result))
			status = WEXITSTATUS(result);
	});

	dispatch_group_notify(group, dispatch_get_main_queue(), ^{
		_process.pid = -1;
		if(_exitHandler && !_cancelled)
			_exitHandler(status);
		_outputHandler = nil;
		_exitHandler   = nil;
	});

	return self;
}

- (pid_t)processIdentifier
{
	return _process.pid;
}

- (void)readFileDescriptor:(int)fd isError:(BOOL)isError group:(dispatch_group_t)group
{
	dispatch_group_async(group, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
		std::string buf;
		char tmp[4096];
		ssize_t len;
		while((len = read(fd, tmp, sizeof(tmp))) > 0)
		{
			auto range = add_bytes_to_utf8_buffer(buf, tmp, tmp + len, true);
			if(range.first == range.second)
				continue;

			NSString* str = [NSString stringWithCxxString:std::string(range.first, range.second)];
			dispatch_sync(dispatch_get_main_queue(), ^{
				if(_outputHandler && !_cancelled)
					_outputHandler(str, isError);
			});
		}
		close(fd);
	});
}

- (void)write:(NSString*)str
{
	if(_process.in == -1)
		return;

	char const* bytes = str.UTF8String;
	size_t len = strlen(bytes);
	while(len > 0)
	{
		ssize_t written = ::write(_process.in, bytes, len);
		if(written <= 0)
			break;
		bytes += written;
		len   -= written;
	}
}

- (void)closeInput
{
	if(_process.in != -1)
	{
		close(_process.in);
		_process.in = -1;
	}
}

- (void)cancel
{
	_cancelled     = YES;
	_outputHandler = nil;
	_exitHandler   = nil;
	[self closeInput];
	if(_process.pid != -1)
	{
		// Like before, first SIGINT so scripts can clean up, but escalate if the command does not exit (it may ignore
		// SIGINT, which is also inherited when TextMate was started with SIGINT ignored). _process.pid is reset when
		// the process has been reaped, so a reused process ID is never signalled.
		kill(_process.pid, SIGINT);
		[self escalateTermination:@[ @(SIGTERM), @(SIGKILL) ]];
	}
}

- (void)escalateTermination:(NSArray<NSNumber*>*)signals
{
	if(signals.count == 0)
		return;

	pid_t pid = _process.pid;
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
		if(_process.pid == pid && pid != -1)
		{
			kill(pid, signals.firstObject.intValue);
			[self escalateTermination:[signals subarrayWithRange:NSMakeRange(1, signals.count-1)]];
		}
	});
}

- (void)dealloc
{
	_cancelled = YES;
	[self closeInput];
	if(_process.pid != -1)
		kill(_process.pid, SIGINT);
}
@end

// =================
// = Script Bridge =
// =================

@interface HOScriptBridge ()
{
	WKUserScript* _userScript;
	__weak WKUserContentController* _userContentController;

	// Asynchronous commands, key is the (unique) command ID from JavaScript
	NSMutableDictionary<NSString*, HOScriptCommand*>* _commands;
	// Synchronous commands, key is the scheme task
	NSMapTable<id, HOScriptCommand*>* _synchronousCommands;
}
@end

@implementation HOScriptBridge
- (instancetype)init
{
	if(self = [super init])
	{
		_enabled    = YES;
		_commands   = [NSMutableDictionary dictionary];
		_userScript = [[WKUserScript alloc] initWithSource:@(kHOScriptBridgeJavaScript) injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:NO];
		_synchronousCommands = [NSMapTable mapTableWithKeyOptions:NSPointerFunctionsStrongMemory|NSPointerFunctionsObjectPointerPersonality valueOptions:NSPointerFunctionsStrongMemory];
		_synchronousCommandWarningDelay = 15;

		_logHandler = ^(NSString* message){
			NSLog(@"JavaScript Log: %@", message);
		};

		_openHandler = ^(NSString* path, id options){
			text::range_t range = text::range_t::undefined;
			if([options isKindOfClass:[NSNumber class]])
				range = text::pos_t([options intValue]-1, 0);
			else if([options isKindOfClass:[NSString class]])
				range = to_s(options);
			if(OakDocument* doc = [OakDocumentController.sharedInstance documentWithPath:path])
				[OakDocumentController.sharedInstance showDocument:doc andSelect:range inProject:nil bringToFront:YES];
		};
	}
	return self;
}

- (void)dealloc
{
	[self cancelAllCommands];
}

- (void)addToConfiguration:(WKWebViewConfiguration*)configuration
{
	_userContentController = configuration.userContentController;
	[_userContentController addScriptMessageHandler:self name:@"textmate"];
	[configuration setURLSchemeHandler:self forURLScheme:kHOScriptBridgeURLScheme];
	if(_enabled)
		[_userContentController addUserScript:_userScript];
}

- (void)setEnabled:(BOOL)flag
{
	if(_enabled == flag)
		return;

	_enabled = flag;
	if(WKUserContentController* controller = _userContentController)
	{
		// There is no API to remove a single user script, so remove all and re-add the others
		NSArray<WKUserScript*>* others = [controller.userScripts filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(WKUserScript* script, NSDictionary*){ return script != _userScript; }]];
		[controller removeAllUserScripts];
		for(WKUserScript* script in others)
			[controller addUserScript:script];
		if(_enabled)
			[controller addUserScript:_userScript];
	}
}

- (void)cancelAllCommands
{
	for(HOScriptCommand* command in _commands.allValues)
		[command cancel];
	[_commands removeAllObjects];
}

// ============================
// = Messages from JavaScript =
// ============================

- (void)userContentController:(WKUserContentController*)controller didReceiveScriptMessage:(WKScriptMessage*)message
{
	if(!_enabled || !IsTrustedScheme(message.frameInfo.securityOrigin.protocol) || ![message.body isKindOfClass:[NSDictionary class]])
	{
		os_log_error(OS_LOG_DEFAULT, "Ignoring TextMate JavaScript message from %{public}@://%{public}@", message.frameInfo.securityOrigin.protocol, message.frameInfo.securityOrigin.host);
		return;
	}

	NSDictionary* body = message.body;
	NSString* type = body[@"type"];
	NSString* key  = [body[@"id"] isKindOfClass:[NSString class]] ? body[@"id"] : @"";

	if([type isEqualToString:@"system"])
	{
		WKFrameInfo* frame = message.frameInfo;
		id commandIdentifier = body[@"id"];
		__weak HOScriptBridge* weakSelf = self;

		void(^send)(NSString*, id) = ^(NSString* kind, id value){
			NSString* script = [NSString stringWithFormat:@"TextMate._commandEvent(%@, %@, %@)", JSONString(commandIdentifier), JSONString(kind), JSONString(value)];
			[weakSelf.webView evaluateJavaScript:script inFrame:frame inContentWorld:WKContentWorld.pageWorld completionHandler:nil];
		};

		_commands[key] = [[HOScriptCommand alloc] initWithCommand:body[@"command"] environment:_environment closeInput:NO output:^(NSString* str, BOOL isError){
			send(isError ? @"error" : @"output", str);
		} exit:^(int status){
			send(@"exit", @(status));
			[weakSelf removeCommandForKey:key];
		}];
	}
	else if([type isEqualToString:@"write"])
	{
		[_commands[key] write:body[@"data"]];
	}
	else if([type isEqualToString:@"close"])
	{
		[_commands[key] closeInput];
	}
	else if([type isEqualToString:@"cancel"])
	{
		[_commands[key] cancel];
		[_commands removeObjectForKey:key];
	}
	else if([type isEqualToString:@"busy"])
	{
		_delegate.busy = [body[@"value"] boolValue];
	}
	else if([type isEqualToString:@"progress"])
	{
		_delegate.progress = [body[@"value"] doubleValue];
	}
	else if([type isEqualToString:@"log"])
	{
		if(_logHandler)
			_logHandler(body[@"message"]);
	}
	else if([type isEqualToString:@"open"])
	{
		if(_openHandler)
			_openHandler(body[@"path"], [body[@"options"] isKindOfClass:[NSNull class]] ? nil : body[@"options"]);
	}
}

- (void)removeCommandForKey:(NSString*)key
{
	[_commands removeObjectForKey:key];
}

// ==============================================================
// = Synchronous TextMate.system(): XHR to x-txmt-js://system   =
// ==============================================================

- (void)startTask:(id <WKURLSchemeTask>)task
{
	NSURLRequest* request = task.request;
	NSString* origin = [request valueForHTTPHeaderField:@"Origin"];
	NSDictionary* body = request.HTTPBody ? [NSJSONSerialization JSONObjectWithData:request.HTTPBody options:0 error:nullptr] : nil;
	if(!_enabled || !IsTrustedScheme([NSURL URLWithString:origin].scheme) || ![request.URL.host isEqualToString:@"system"] || ![body[@"command"] isKindOfClass:[NSString class]])
	{
		os_log_error(OS_LOG_DEFAULT, "Refusing %{public}@ from %{public}@", request.URL, origin);
		return [self task:task didFailWithError:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorNoPermissionsToReadFile userInfo:nil]];
	}

	NSString* commandString = body[@"command"];
	__block std::string output, error;
	__weak HOScriptBridge* weakSelf = self;

	HOScriptCommand* command = [[HOScriptCommand alloc] initWithCommand:commandString environment:_environment closeInput:YES output:^(NSString* str, BOOL isError){
		(isError ? error : output) += to_s(str);
	} exit:^(int status){
		HOScriptBridge* strongSelf = weakSelf;
		if(!strongSelf)
			return;
		NSDictionary* result = @{ @"outputString": [NSString stringWithCxxString:output] ?: @"", @"errorString": [NSString stringWithCxxString:error] ?: @"", @"status": @(status) };
		NSData* data = [JSONString(result) dataUsingEncoding:NSUTF8StringEncoding];
		[strongSelf task:task didReceiveResponse:[[NSHTTPURLResponse alloc] initWithURL:task.request.URL statusCode:200 HTTPVersion:@"HTTP/1.1" headerFields:@{ @"Content-Type": @"application/json; charset=utf-8" }]];
		[strongSelf task:task didReceiveData:data];
		[strongSelf taskDidFinish:task];
		[strongSelf->_synchronousCommands removeObjectForKey:task];
	}];
	[_synchronousCommands setObject:command forKey:task];

	if(_synchronousCommandWarningDelay > 0)
		[self warnAboutSynchronousCommand:command string:commandString task:task];
}

- (void)warnAboutSynchronousCommand:(HOScriptCommand*)command string:(NSString*)commandString task:(id <WKURLSchemeTask>)task
{
	__weak HOScriptBridge* weakSelf = self;
	__weak HOScriptCommand* weakCommand = command;
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(_synchronousCommandWarningDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
		HOScriptBridge* strongSelf = weakSelf;
		if(!strongSelf || !weakCommand || ![strongSelf isTaskActive:task])
			return;

		NSAlert* alert        = [[NSAlert alloc] init];
		alert.messageText     = @"JavaScript Warning";
		alert.informativeText = [NSString stringWithFormat:@"The command ‘%@’ has been running for %.0f seconds. Would you like to stop it?\n\nTo avoid this warning, the bundle command should use the asynchronous version of TextMate.system().", commandString, strongSelf.synchronousCommandWarningDelay];
		[alert addButtons:@"Stop Command", @"Cancel", nil];

		void(^handler)(NSModalResponse) = ^(NSModalResponse response){
			if(response == NSAlertFirstButtonReturn) // Stop Command
			{
				pid_t pid = weakCommand.processIdentifier;
				if(pid != -1)
					kill(pid, SIGINT);
			}
			else if(weakCommand)
			{
				[weakSelf warnAboutSynchronousCommand:weakCommand string:commandString task:task];
			}
		};

		if(NSWindow* window = strongSelf.webView.window)
				[alert beginSheetModalForWindow:window completionHandler:handler];
		else	handler([alert runModal]);
	});
}

- (void)taskWasStopped:(id <WKURLSchemeTask>)task
{
	[[_synchronousCommands objectForKey:task] cancel];
	[_synchronousCommands removeObjectForKey:task];
}
@end
