#import <WebKit/WebKit.h>

// Base class for the scheme handlers used by the HTML output view.
//
// WKURLSchemeTask raises an exception when used after the web view has stopped the task (e.g. the user
// pressed ⌘.), so all task methods must go through the methods below, which ignore stopped tasks.
// These methods must be called on the main thread.

@interface HOSchemeHandler : NSObject <WKURLSchemeHandler>
// Subclasses override this instead of webView:startURLSchemeTask:
- (void)startTask:(id <WKURLSchemeTask>)task;
// Called when the web view stops a task that is still active (default does nothing)
- (void)taskWasStopped:(id <WKURLSchemeTask>)task;

- (BOOL)isTaskActive:(id <WKURLSchemeTask>)task;
- (void)task:(id <WKURLSchemeTask>)task didReceiveResponse:(NSURLResponse*)response;
- (void)task:(id <WKURLSchemeTask>)task didReceiveData:(NSData*)data;
- (void)taskDidFinish:(id <WKURLSchemeTask>)task;
- (void)task:(id <WKURLSchemeTask>)task didFailWithError:(NSError*)error;

// Convenience: response, data, and finish in one go
- (void)task:(id <WKURLSchemeTask>)task respondWithData:(NSData*)data MIMEType:(NSString*)mimeType textEncodingName:(NSString*)encoding;
- (void)task:(id <WKURLSchemeTask>)task respondWithHTML:(NSString*)html statusCode:(NSInteger)statusCode;

// Load a protocol-relative URL (e.g. //cdn.example.com/lib.js resolved against a custom scheme) via the
// user’s default protocol (https unless the “defaultURLProtocol” user default is set) and relay the result.
- (void)task:(id <WKURLSchemeTask>)task loadProtocolRelativeURL:(NSURL*)url;

// YES for command output (x-txmt-filehandle://job/…) and local files (tm-file://…), but not for
// protocol-relative URLs using these schemes (e.g. x-txmt-filehandle://cdn.example.com/lib.js)
+ (BOOL)isTrustedURL:(NSURL*)url;

// YES if the request comes from command output, a local file, or a load not initiated by a web page
+ (BOOL)isTrustedRequest:(NSURLRequest*)request;
@end
