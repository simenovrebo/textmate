#import "HOSchemeHandler.h"
#import <oak/debug.h>

static NSString* const kUserDefaultsDefaultURLProtocolKey = @"defaultURLProtocol";

@interface HOSchemeHandler ()
{
	NSHashTable* _activeTasks;                       // tasks that have been started and not finished, failed, or stopped
	NSMapTable<id, NSURLSessionTask*>* _proxyTasks;  // scheme task → URL session task for protocol-relative URLs
}
@end

@implementation HOSchemeHandler
+ (void)initialize
{
	[NSUserDefaults.standardUserDefaults registerDefaults:@{
		kUserDefaultsDefaultURLProtocolKey: @"https",
	}];
}

+ (BOOL)isTrustedURL:(NSURL*)url
{
	NSString* host = url.host;
	if([url.scheme isEqualToString:@"x-txmt-filehandle"])
		return [host isEqualToString:@"job"];
	else if([url.scheme isEqualToString:@"tm-file"]) // same rule as HOFileSchemeHandler’s pathForURL:
		return ![host containsString:@"."] || [NSFileManager.defaultManager fileExistsAtPath:[@"/" stringByAppendingPathComponent:host]];
	return NO;
}

+ (BOOL)isTrustedRequest:(NSURLRequest*)request
{
	return !request.mainDocumentURL || [self isTrustedURL:request.mainDocumentURL];
}

- (instancetype)init
{
	if(self = [super init])
	{
		_activeTasks = [NSHashTable hashTableWithOptions:NSPointerFunctionsStrongMemory|NSPointerFunctionsObjectPointerPersonality];
		_proxyTasks  = [NSMapTable mapTableWithKeyOptions:NSPointerFunctionsStrongMemory|NSPointerFunctionsObjectPointerPersonality valueOptions:NSPointerFunctionsStrongMemory];
	}
	return self;
}

// ======================
// = WKURLSchemeHandler =
// ======================

- (void)webView:(WKWebView*)webView startURLSchemeTask:(id <WKURLSchemeTask>)task
{
	[_activeTasks addObject:task];
	[self startTask:task];
}

- (void)webView:(WKWebView*)webView stopURLSchemeTask:(id <WKURLSchemeTask>)task
{
	if(![_activeTasks containsObject:task])
		return;

	[_activeTasks removeObject:task];
	[[_proxyTasks objectForKey:task] cancel];
	[_proxyTasks removeObjectForKey:task];
	[self taskWasStopped:task];
}

- (void)startTask:(id <WKURLSchemeTask>)task
{
	[self task:task didFailWithError:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorUnsupportedURL userInfo:nil]];
}

- (void)taskWasStopped:(id <WKURLSchemeTask>)task
{
}

// =================
// = Task Wrappers =
// =================

- (BOOL)isTaskActive:(id <WKURLSchemeTask>)task
{
	ASSERT(NSThread.isMainThread);
	return [_activeTasks containsObject:task];
}

- (void)task:(id <WKURLSchemeTask>)task didReceiveResponse:(NSURLResponse*)response
{
	if([self isTaskActive:task])
		[task didReceiveResponse:response];
}

- (void)task:(id <WKURLSchemeTask>)task didReceiveData:(NSData*)data
{
	if([self isTaskActive:task])
		[task didReceiveData:data];
}

- (void)taskDidFinish:(id <WKURLSchemeTask>)task
{
	if([self isTaskActive:task])
	{
		[_activeTasks removeObject:task];
		[_proxyTasks removeObjectForKey:task];
		[task didFinish];
	}
}

- (void)task:(id <WKURLSchemeTask>)task didFailWithError:(NSError*)error
{
	if([self isTaskActive:task])
	{
		[_activeTasks removeObject:task];
		[_proxyTasks removeObjectForKey:task];
		[task didFailWithError:error];
	}
}

- (void)task:(id <WKURLSchemeTask>)task respondWithData:(NSData*)data MIMEType:(NSString*)mimeType textEncodingName:(NSString*)encoding
{
	[self task:task didReceiveResponse:[[NSURLResponse alloc] initWithURL:task.request.URL MIMEType:mimeType expectedContentLength:data.length textEncodingName:encoding]];
	[self task:task didReceiveData:data];
	[self taskDidFinish:task];
}

- (void)task:(id <WKURLSchemeTask>)task respondWithHTML:(NSString*)html statusCode:(NSInteger)statusCode
{
	NSData* data = [html dataUsingEncoding:NSUTF8StringEncoding];
	NSDictionary* headers = @{ @"Content-Type": @"text/html; charset=utf-8", @"Content-Length": [NSString stringWithFormat:@"%lu", data.length] };
	[self task:task didReceiveResponse:[[NSHTTPURLResponse alloc] initWithURL:task.request.URL statusCode:statusCode HTTPVersion:@"HTTP/1.1" headerFields:headers]];
	[self task:task didReceiveData:data];
	[self taskDidFinish:task];
}

// ===========================
// = Protocol-relative URLs =
// ===========================

- (void)task:(id <WKURLSchemeTask>)task loadProtocolRelativeURL:(NSURL*)url
{
	NSURLComponents* components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:YES];
	components.scheme = [NSUserDefaults.standardUserDefaults stringForKey:kUserDefaultsDefaultURLProtocolKey];

	NSURLSessionDataTask* dataTask = [NSURLSession.sharedSession dataTaskWithURL:components.URL completionHandler:^(NSData* data, NSURLResponse* response, NSError* error){
		dispatch_async(dispatch_get_main_queue(), ^{
			if(error)
			{
				[self task:task didFailWithError:error];
			}
			else
			{
				// The response must use the URL of the request, not the URL we fetched
				NSInteger statusCode = [response isKindOfClass:[NSHTTPURLResponse class]] ? ((NSHTTPURLResponse*)response).statusCode : 200;
				NSMutableDictionary* headers = [NSMutableDictionary dictionary];
				if(response.MIMEType)
					headers[@"Content-Type"] = response.textEncodingName ? [NSString stringWithFormat:@"%@; charset=%@", response.MIMEType, response.textEncodingName] : response.MIMEType;
				[self task:task didReceiveResponse:[[NSHTTPURLResponse alloc] initWithURL:task.request.URL statusCode:statusCode HTTPVersion:@"HTTP/1.1" headerFields:headers]];
				[self task:task didReceiveData:data ?: [NSData data]];
				[self taskDidFinish:task];
			}
		});
	}];
	[_proxyTasks setObject:dataTask forKey:task];
	[dataTask resume];
}
@end
