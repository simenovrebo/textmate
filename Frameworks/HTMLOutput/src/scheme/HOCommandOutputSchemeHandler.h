#import "HOSchemeHandler.h"

// Serves the HTML output of bundle commands as x-txmt-filehandle://job/<name>/<n> URLs, replacing
// OakFileHandleURLProtocol (WKWebView does not support NSURLProtocol).
//
// Output is read from a file handle and passed to the web view as it arrives, with file:// URLs
// rewritten to tm-file:// (see file_url_rewriter.h). Stopping the load (⌘.) while the command runs
// kills its process group. The output is recorded, so the URL can be loaded again (reload, back/forward)
// and the original HTML is available for View Source.
//
// Other hosts than “job” are protocol-relative URLs (e.g. //cdn.example.com/lib.js) and are loaded via https.

extern NSString* const kHOCommandOutputURLScheme; // x-txmt-filehandle

@interface HOCommandOutputSchemeHandler : HOSchemeHandler
// Register command output. The returned URL is unique. Reading starts when the URL is first loaded.
// processIdentifier is the process group killed when the load is stopped (0 for none).
+ (NSURL*)URLForOutputFromFileHandle:(NSFileHandle*)fileHandle processIdentifier:(pid_t)processIdentifier name:(NSString*)name;

// Register complete output, e.g. when a command’s output replaces the page in one go
+ (NSURL*)URLForOutput:(NSData*)data name:(NSString*)name;

// Output received so far (as written by the command, i.e. without URL rewriting), or nil if not registered
+ (NSData*)outputForURL:(NSURL*)url;
+ (BOOL)isOutputCompleteForURL:(NSURL*)url;

// Free the recorded output when it is no longer needed
+ (void)removeOutputForURL:(NSURL*)url;
@end
