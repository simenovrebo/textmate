#import "HOSchemeHandler.h"

// Serves local files for tm-file://[localhost]/path URLs, used by bundles and by command output
// (where file:// URLs are rewritten to tm-file:// as WKWebView does not allow them from custom schemes).
//
// - Directories with an index.html are redirected to it.
// - Missing files show an error page when loaded as a document, and fail when loaded as a resource.
// - HTML files get the same file:// → tm-file:// rewriting as command output.
// - tm-file://example.com/… (a protocol-relative URL resolved against a tm-file:// base) is loaded via https,
//   unless /example.com exists on disk.
// - Requests from web pages that are not command output or local files are refused.

extern NSString* const kHOFileURLScheme; // tm-file

@interface HOFileSchemeHandler : HOSchemeHandler
// Path of the file on disk for a tm-file:// URL, or nil if it is a protocol-relative URL
+ (NSString*)pathForURL:(NSURL*)url;
@end
