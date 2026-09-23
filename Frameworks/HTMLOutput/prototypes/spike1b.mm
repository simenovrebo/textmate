// Spike 1b: Serve file:// resources for command output by (1) rewriting file:// → tm-file:// in the
// streamed HTML (chunk-boundary safe), (2) rewriting src/href set from JavaScript, (3) intercepting
// navigation to file:// URLs. Mirrors the patterns used by bundles (see WKWEBVIEW_MIGRATION.md).
#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>
#include <string>

static NSString* gResDir;

// ====================================================================
// = Streaming rewriter: file:// → tm-file:// when in URL position    =
// = (preceded by " ' = or ( ). Keeps a tail across chunk boundaries. =
// ====================================================================

struct file_url_rewriter_t
{
	std::string feed (char const* bytes, size_t len, bool last = false)
	{
		_pending.append(bytes, len);
		std::string res;
		size_t const keep = last ? 0 : 7; // strlen("file://") so a split match is completed by the next chunk
		size_t i = 0;
		while(i + keep < _pending.size() || (last && i < _pending.size()))
		{
			if(_pending.compare(i, 7, "file://") == 0 && strchr("\"'=(", _prev))
			{
				res += "tm-file://";
				i += 7;
				_prev = '/';
				continue;
			}
			if(!last && i + 7 > _pending.size() && _pending.compare(i, std::string::npos, std::string("file://").substr(0, _pending.size() - i)) == 0)
				break; // possible partial match at the end, wait for more data
			_prev = _pending[i];
			res += _pending[i++];
		}
		_pending.erase(0, i);
		return res;
	}

private:
	std::string _pending;
	char _prev = ' ';
};

// ======================================================
// = Scheme handlers: x-txmt-filehandle and tm-file     =
// ======================================================

@interface SchemeHandler : NSObject <WKURLSchemeHandler>
@end

@implementation SchemeHandler
- (void)webView:(WKWebView*)webView startURLSchemeTask:(id <WKURLSchemeTask>)task
{
	NSURL* url = task.request.URL;
	if([url.scheme isEqualToString:@"x-txmt-filehandle"])
	{
		NSString* r = gResDir;
		NSString* html = [NSString stringWithFormat:@
			"<!DOCTYPE html><html><head><title>Spike</title>\n"
			"<base href='file://%1$@/'>\n"                                           // like htmloutput.rb / Markdown preview
			"<link rel=\"stylesheet\" href=\"file://%1$@/style.css\" type=\"text/css\">\n" // like htmloutput.rb
			"<script src=\"file://%1$@/script.js\"></script>\n"
			"</head><body>\n"
			"<p id='text'>Text mentioning file://example stays unchanged</p>\n"
			"<img id='rel' src='img.png' onload='window.relImg=\"loaded\"' onerror='window.relImg=\"error\"'>\n" // resolved via <base>
			"<script>\n"
			"  var e = document.createElement('img');\n"                              // like webpreview.js
			"  e.onload = () => window.jsImg = 'loaded'; e.onerror = () => window.jsImg = 'error';\n"
			"  e.src = 'file://' + '%1$@' + '/img.png';\n"
			"  var a = document.createElement('img');\n"
			"  a.onload = () => window.attrImg = 'loaded'; a.onerror = () => window.attrImg = 'error';\n"
			"  a.setAttribute('src', 'file://%1$@/img.png');\n"
			"  window.addEventListener('load', () => setTimeout(() => {\n"
			"    window.webkit.messageHandlers.report.postMessage({\n"
			"      stylesheet: getComputedStyle(document.body).color == 'rgb(1, 2, 3)' ? 'loaded' : 'blocked',\n"
			"      script:     window.fromScript == 'yes' ? 'loaded' : 'blocked',\n"
			"      baseRelImg: window.relImg || 'pending',\n"
			"      jsSrcImg:   window.jsImg || 'pending',\n"
			"      jsAttrImg:  window.attrImg || 'pending',\n"
			"      text:       document.getElementById('text').textContent\n"
			"    });\n"
			"  }, 300));\n"
			"</script></body></html>\n", r];

		[task didReceiveResponse:[[NSURLResponse alloc] initWithURL:url MIMEType:@"text/html" expectedContentLength:-1 textEncodingName:@"utf-8"]];

		// Stream in 5-byte chunks so URLs are split across chunk boundaries
		auto rewriter = std::make_shared<file_url_rewriter_t>();
		NSData* data = [html dataUsingEncoding:NSUTF8StringEncoding];
		for(NSUInteger i = 0; i < data.length; i += 5)
		{
			NSUInteger len = MIN(5, data.length - i);
			std::string out = rewriter->feed((char const*)data.bytes + i, len);
			if(!out.empty())
				[task didReceiveData:[NSData dataWithBytes:out.data() length:out.size()]];
		}
		std::string out = rewriter->feed("", 0, true);
		if(!out.empty())
			[task didReceiveData:[NSData dataWithBytes:out.data() length:out.size()]];
		[task didFinish];
	}
	else // tm-file://localhost/path → file on disk
	{
		NSString* path = url.path;
		NSData* data = [NSData dataWithContentsOfFile:path];
		if(!data)
			return (void)[task didFailWithError:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorFileDoesNotExist userInfo:nil]];
		NSDictionary* types = @{ @"css": @"text/css", @"js": @"text/javascript", @"png": @"image/png", @"html": @"text/html" };
		[task didReceiveResponse:[[NSURLResponse alloc] initWithURL:url MIMEType:types[path.pathExtension] ?: @"application/octet-stream" expectedContentLength:data.length textEncodingName:nil]];
		[task didReceiveData:data];
		[task didFinish];
	}
}
- (void)webView:(WKWebView*)webView stopURLSchemeTask:(id <WKURLSchemeTask>)task { }
@end

// Injected at document start: rewrite file:// URLs assigned from JavaScript
static NSString* const kRewriteScript = @
	"(function () {\n"
	"  const fix = v => typeof v === 'string' && v.startsWith('file://') ? 'tm-file://' + v.slice(7) : v;\n"
	"  for(const [cls, prop] of [[HTMLImageElement, 'src'], [HTMLScriptElement, 'src'], [HTMLLinkElement, 'href'], [HTMLIFrameElement, 'src'], [HTMLSourceElement, 'src']]) {\n"
	"    const d = Object.getOwnPropertyDescriptor(cls.prototype, prop);\n"
	"    Object.defineProperty(cls.prototype, prop, { get: d.get, set: function (v) { d.set.call(this, fix(v)); }, configurable: true });\n"
	"  }\n"
	"  const setAttribute = Element.prototype.setAttribute;\n"
	"  Element.prototype.setAttribute = function (name, value) {\n"
	"    return setAttribute.call(this, name, /^(src|href)$/i.test(name) ? fix(value) : value);\n"
	"  };\n"
	"})();\n";

@interface Runner : NSObject <WKScriptMessageHandler, WKNavigationDelegate>
@property (nonatomic) WKWebView* webView;
@property (nonatomic) NSWindow* window;
@property (nonatomic) int step;
@end

@implementation Runner
- (void)start
{
	WKWebViewConfiguration* config = [WKWebViewConfiguration new];
	SchemeHandler* handler = [SchemeHandler new];
	[config setURLSchemeHandler:handler forURLScheme:@"x-txmt-filehandle"];
	[config setURLSchemeHandler:handler forURLScheme:@"tm-file"];
	[config.userContentController addScriptMessageHandler:self name:@"report"];
	[config.userContentController addUserScript:[[WKUserScript alloc] initWithSource:kRewriteScript injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:NO]];

	self.webView = [[WKWebView alloc] initWithFrame:NSMakeRect(0, 0, 400, 300) configuration:config];
	self.webView.navigationDelegate = self;
	self.window.contentView = self.webView;
	[self.webView loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:@"x-txmt-filehandle://job/Spike/1"]]];
}

- (void)userContentController:(WKUserContentController*)controller didReceiveScriptMessage:(WKScriptMessage*)message
{
	NSDictionary* r = message.body;
	printf("stylesheet (file:// in <link>):       %s\n", [r[@"stylesheet"] UTF8String]);
	printf("script (file:// in <script>):         %s\n", [r[@"script"] UTF8String]);
	printf("relative <img> with <base file://>:   %s\n", [r[@"baseRelImg"] UTF8String]);
	printf("img.src = 'file://…' from JS:          %s\n", [r[@"jsSrcImg"] UTF8String]);
	printf("setAttribute('src', 'file://…'):       %s\n", [r[@"jsAttrImg"] UTF8String]);
	printf("text content untouched:               %s\n", [r[@"text"] containsString:@"mentioning file://example"] ? "yes" : [r[@"text"] UTF8String]);

	// Step 2: navigate to a file:// URL like ri_to_html / man2html do
	// Step 2: raw file:// navigation (expected to be blocked by WebKit before reaching the policy delegate)
	self.step = 2;
	[self.webView evaluateJavaScript:[NSString stringWithFormat:@"window.location = 'file://' + '%@/page.html'", gResDir] completionHandler:nil];
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
		printf("raw file:// navigation:               %s\n", [self.webView.URL.scheme isEqualToString:@"x-txmt-filehandle"] ? "blocked (page unchanged)" : self.webView.URL.absoluteString.UTF8String);
		// Step 3: what the stream rewriter turns window.location="file://"+… into (ri_to_html, man2html)
		self.step = 3;
		[self.webView evaluateJavaScript:[NSString stringWithFormat:@"window.location = 'tm-file://' + '%@/page.html'", gResDir] completionHandler:nil];
	});
}

- (void)webView:(WKWebView*)webView decidePolicyForNavigationAction:(WKNavigationAction*)action decisionHandler:(void(^)(WKNavigationActionPolicy))decisionHandler
{
	NSURL* url = action.request.URL;
	if(self.step == 2)
		printf("navigation to %-8s seen by policy delegate: yes\n", [url.scheme stringByAppendingString:@"://"].UTF8String);
	if(url.isFileURL)
	{
		decisionHandler(WKNavigationActionPolicyCancel);
		NSURLComponents* c = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
		c.scheme = @"tm-file";
		c.host   = @"localhost";
		[webView loadRequest:[NSURLRequest requestWithURL:c.URL]];
		return;
	}
	decisionHandler(WKNavigationActionPolicyAllow);
}

- (void)webView:(WKWebView*)webView didFinishNavigation:(WKNavigation*)navigation
{
	if(self.step == 3 && [webView.URL.scheme isEqualToString:@"tm-file"])
	{
		[webView evaluateJavaScript:@"document.body.textContent" completionHandler:^(id result, NSError* error){
			printf("rewritten tm-file:// navigation:       %s\n", [result containsString:@"Hello from page.html"] ? "yes" : "NO");
			[NSApp terminate:nil];
		}];
	}
}
@end

int main (int argc, char const* argv[])
{
	@autoreleasepool {
		gResDir = @(argv[1]);
		[@"<html><body>Hello from page.html</body></html>" writeToFile:[gResDir stringByAppendingPathComponent:@"page.html"] atomically:YES encoding:NSUTF8StringEncoding error:nil];

		// Unit test the rewriter across every possible split point
		std::string const input = "<a href=\"file:///x\">file://y</a><img src='file:///z'><div style=\"background:url(file:///w)\">";
		std::string expected = "<a href=\"tm-file:///x\">file://y</a><img src='tm-file:///z'><div style=\"background:url(tm-file:///w)\">";
		int failures = 0;
		for(size_t split = 0; split <= input.size(); ++split)
		{
			for(size_t split2 = split; split2 <= input.size(); ++split2)
			{
				file_url_rewriter_t rw;
				std::string out = rw.feed(input.data(), split) + rw.feed(input.data() + split, split2 - split) + rw.feed(input.data() + split2, input.size() - split2) + rw.feed("", 0, true);
				if(out != expected)
					++failures;
			}
		}
		printf("rewriter, all 2-split combinations:   %s\n", failures ? [[NSString stringWithFormat:@"%d FAILURES", failures] UTF8String] : "all correct");

		[NSApplication sharedApplication];
		[NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
		Runner* runner = [Runner new];
		runner.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(-10000, -10000, 400, 300) styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
		[runner.window orderBack:nil];
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ printf("TIMEOUT at step %d\n", runner.step); [NSApp terminate:nil]; });
		dispatch_async(dispatch_get_main_queue(), ^{ [runner start]; });
		[NSApp run];
	}
	return 0;
}
