#import "HOFileSchemeHandler.h"
#import "../helpers/file_url_rewriter.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <sys/stat.h>

NSString* const kHOFileURLScheme = @"tm-file";

static NSString* EscapeHTML (NSString* str)
{
	return [[[str stringByReplacingOccurrencesOfString:@"&" withString:@"&amp;"] stringByReplacingOccurrencesOfString:@"<" withString:@"&lt;"] stringByReplacingOccurrencesOfString:@"\"" withString:@"&quot;"];
}

static NSString* MIMETypeForPath (NSString* path)
{
	UTType* type = [UTType typeWithFilenameExtension:path.pathExtension];
	return type.preferredMIMEType ?: @"application/octet-stream";
}

@implementation HOFileSchemeHandler
+ (NSString*)pathForURL:(NSURL*)url
{
	// A host other than localhost (with a dot) that does not exist on disk is a protocol-relative URL, e.g. //cdn.example.com/lib.js
	// Like the previous tm-file:// → file://localhost/path redirect, the host is otherwise ignored.
	NSString* host = url.host;
	if([host containsString:@"."] && ![NSFileManager.defaultManager fileExistsAtPath:[@"/" stringByAppendingPathComponent:host]])
		return nil;
	return url.path.length ? url.path : @"/";
}

- (void)startTask:(id <WKURLSchemeTask>)task
{
	NSURLRequest* request = task.request;
	if(![HOSchemeHandler isTrustedRequest:request])
	{
		os_log_error(OS_LOG_DEFAULT, "Refusing %{public}@ requested by %{public}@", request.URL, request.mainDocumentURL);
		return [self task:task didFailWithError:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorNoPermissionsToReadFile userInfo:nil]];
	}

	NSString* path = [HOFileSchemeHandler pathForURL:request.URL];
	if(!path)
		return [self task:task loadProtocolRelativeURL:request.URL];

	BOOL isDocument = !request.mainDocumentURL || [request.mainDocumentURL isEqual:request.URL];

	struct stat buf;
	if(stat(path.fileSystemRepresentation, &buf) == 0 && S_ISDIR(buf.st_mode))
	{
		NSString* index = [path stringByAppendingPathComponent:@"index.html"];
		if(![NSFileManager.defaultManager fileExistsAtPath:index])
			return [self task:task fileNotFound:path isDocument:isDocument];

		if(request.URL.hasDirectoryPath)
		{
			path = index;
		}
		else
		{
			// Redirect so that relative URLs in index.html resolve against the directory
			NSURLComponents* components = [NSURLComponents componentsWithURL:request.URL resolvingAgainstBaseURL:YES];
			components.path = [components.path stringByAppendingString:@"/index.html"];
			NSString* json = [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:@[ components.URL.absoluteString ] options:NSJSONWritingWithoutEscapingSlashes error:nil] encoding:NSUTF8StringEncoding];
			return [self task:task respondWithHTML:[NSString stringWithFormat:@"<!DOCTYPE html><script>location.replace(%@[0]);</script>", json] statusCode:200];
		}
	}

	dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
		NSData* data = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nullptr];
		NSString* mimeType = MIMETypeForPath(path);
		if(data && [mimeType isEqualToString:@"text/html"])
		{
			file_url_rewriter_t rewriter;
			std::string const str = rewriter.feed((char const*)data.bytes, data.length, true);
			data = [NSData dataWithBytes:str.data() length:str.size()];
		}

		dispatch_async(dispatch_get_main_queue(), ^{
			if(data)
					[self task:task respondWithData:data MIMEType:mimeType textEncodingName:nil];
			else	[self task:task fileNotFound:path isDocument:isDocument];
		});
	});
}

- (void)task:(id <WKURLSchemeTask>)task fileNotFound:(NSString*)path isDocument:(BOOL)isDocument
{
	if(isDocument)
			[self task:task respondWithHTML:[NSString stringWithFormat:@"<!DOCTYPE html><title>File Not Found</title><h1>File Not Found</h1><p>The requested file was not found: <code>%@</code></p>", EscapeHTML(path)] statusCode:404];
	else	[self task:task didFailWithError:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorFileDoesNotExist userInfo:@{ NSFilePathErrorKey: path }]];
}
@end
