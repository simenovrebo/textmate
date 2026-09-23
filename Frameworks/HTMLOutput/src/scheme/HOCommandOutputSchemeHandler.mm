#import "HOCommandOutputSchemeHandler.h"
#import "../helpers/file_url_rewriter.h"
#import <OakSystem/process.h>
#import <oak/debug.h>
#import <memory>
#import <map>

NSString* const kHOCommandOutputURLScheme = @"x-txmt-filehandle";

// ==================
// = Command Output =
// ==================

// All state is accessed on the main thread, except for the file handle which is read on a background queue.

@interface HOCommandOutput : NSObject
{
	@public
	NSFileHandle*  _fileHandle;
	pid_t          _processIdentifier;
	NSMutableData* _data;
	BOOL           _started;
	BOOL           _complete;

	// Tasks receiving output as it arrives, each with its own rewriter (they may have joined at different offsets)
	std::map<void*, std::pair<id <WKURLSchemeTask>, std::shared_ptr<file_url_rewriter_t>>> _listeners;
}
@end

@implementation HOCommandOutput
@end

static NSMutableDictionary<NSURL*, HOCommandOutput*>* Outputs ()
{
	static NSMutableDictionary* outputs = [NSMutableDictionary dictionary];
	return outputs;
}

@implementation HOCommandOutputSchemeHandler
+ (NSURL*)URLForOutputFromFileHandle:(NSFileHandle*)fileHandle processIdentifier:(pid_t)processIdentifier name:(NSString*)name
{
	ASSERT(NSThread.isMainThread);

	static NSInteger uniqueKey = 0; // Make each URL unique to avoid caching and allow several outputs for the same command
	NSString* encodedName = [name stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLPathAllowedCharacterSet];
	encodedName = [encodedName stringByReplacingOccurrencesOfString:@"/" withString:@"%2F"];
	NSURL* url = [NSURL URLWithString:[NSString stringWithFormat:@"%@://job/%@/%ld", kHOCommandOutputURLScheme, encodedName, ++uniqueKey]];

	HOCommandOutput* output = [HOCommandOutput new];
	output->_fileHandle        = fileHandle;
	output->_processIdentifier = processIdentifier;
	output->_data              = [NSMutableData data];
	Outputs()[url] = output;

	return url;
}

+ (NSData*)outputForURL:(NSURL*)url
{
	ASSERT(NSThread.isMainThread);
	HOCommandOutput* output = Outputs()[url];
	return output ? [output->_data copy] : nil;
}

+ (BOOL)isOutputCompleteForURL:(NSURL*)url
{
	ASSERT(NSThread.isMainThread);
	HOCommandOutput* output = Outputs()[url];
	return output && output->_complete;
}

+ (void)removeOutputForURL:(NSURL*)url
{
	ASSERT(NSThread.isMainThread);
	[Outputs() removeObjectForKey:url];
}

// ===================
// = Scheme Handling =
// ===================

- (void)startTask:(id <WKURLSchemeTask>)task
{
	NSURLRequest* request = task.request;
	if(![request.URL.host isEqualToString:@"job"])
	{
		if(![HOSchemeHandler isTrustedRequest:request])
			return [self task:task didFailWithError:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorNoPermissionsToReadFile userInfo:nil]];
		return [self task:task loadProtocolRelativeURL:request.URL];
	}

	HOCommandOutput* output = Outputs()[request.URL];
	if(!output)
	{
		os_log_error(OS_LOG_DEFAULT, "No command output for %{public}@", request.URL);
		return [self task:task respondWithHTML:@"<!DOCTYPE html><title>No Output</title><p>The output of this command is no longer available.</p>" statusCode:404];
	}

	[self task:task didReceiveResponse:[[NSURLResponse alloc] initWithURL:request.URL MIMEType:@"text/html" expectedContentLength:-1 textEncodingName:@"utf-8"]];

	// Send what has been received so far
	auto rewriter = std::make_shared<file_url_rewriter_t>();
	if(output->_data.length || output->_complete)
	{
		std::string const str = rewriter->feed((char const*)output->_data.bytes, output->_data.length, output->_complete);
		if(!str.empty())
			[self task:task didReceiveData:[NSData dataWithBytes:str.data() length:str.size()]];
	}

	if(output->_complete)
		return [self taskDidFinish:task];

	output->_listeners.emplace((__bridge void*)task, std::make_pair(task, rewriter));
	if(!output->_started)
	{
		output->_started = YES;
		[self readOutput:output];
	}
}

- (void)taskWasStopped:(id <WKURLSchemeTask>)task
{
	for(HOCommandOutput* output in Outputs().allValues)
	{
		if(output->_listeners.erase((__bridge void*)task) && !output->_complete && output->_processIdentifier)
			oak::kill_process_group_in_background(output->_processIdentifier);
	}
}

- (void)readOutput:(HOCommandOutput*)output
{
	NSFileHandle* fileHandle = output->_fileHandle;
	dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
		char buf[8192];
		ssize_t len;
		while((len = read(fileHandle.fileDescriptor, buf, sizeof(buf))) > 0)
		{
			NSData* data = [NSData dataWithBytes:buf length:len];
			dispatch_sync(dispatch_get_main_queue(), ^{ // dispatch_sync: do not read faster than the web view receives
				[self output:output didReceiveData:data complete:NO];
			});
		}

		if(len == -1)
			perror("HTMLOutput: read");
		[fileHandle closeFile];

		dispatch_async(dispatch_get_main_queue(), ^{
			[self output:output didReceiveData:nil complete:YES];
		});
	});
}

- (void)output:(HOCommandOutput*)output didReceiveData:(NSData*)data complete:(BOOL)complete
{
	if(data)
		[output->_data appendData:data];
	if(complete)
		output->_complete = YES;

	auto listeners = output->_listeners; // copy, as sending data can stop tasks (which modifies _listeners)
	for(auto const& pair : listeners)
	{
		auto const& [task, rewriter] = pair.second;
		std::string const str = rewriter->feed(data ? (char const*)data.bytes : "", data ? data.length : 0, complete);
		if(!str.empty())
			[self task:task didReceiveData:[NSData dataWithBytes:str.data() length:str.size()]];
		if(complete)
			[self taskDidFinish:task];
	}

	if(complete)
		output->_listeners.clear();
}
@end
