#import "scheme_test_support.h"
#import "../src/scheme/HOFileSchemeHandler.h"

static NSString* Directory;

void setup_fixtures ()
{
	Directory = MakeTemporaryDirectory();
	NSFileManager* fm = NSFileManager.defaultManager;
	[fm createDirectoryAtPath:[Directory stringByAppendingPathComponent:@"site/css"] withIntermediateDirectories:YES attributes:nil error:nil];
	[fm createDirectoryAtPath:[Directory stringByAppendingPathComponent:@"empty dir"] withIntermediateDirectories:YES attributes:nil error:nil];
	[@"body { color: red; }"                                 writeToFile:[Directory stringByAppendingPathComponent:@"site/css/style.css"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
	[@"<link href=\"file:///x.css\"><p>index</p>"            writeToFile:[Directory stringByAppendingPathComponent:@"site/index.html"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
	[@"Grønn & <tekst>"                                     writeToFile:[Directory stringByAppendingPathComponent:@"site/æøå.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

static NSString* URL (NSString* relativePath)
{
	NSString* path = [Directory stringByAppendingPathComponent:relativePath];
	if([relativePath hasSuffix:@"/"])
		path = [path stringByAppendingString:@"/"];
	return [@"tm-file://" stringByAppendingString:[path stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLPathAllowedCharacterSet]];
}

void test_serves_file_with_mime_type ()
{
	HOFileSchemeHandler* handler = [HOFileSchemeHandler new];
	FakeSchemeTask* task = StartTask(handler, URL(@"site/css/style.css"), @"x-txmt-filehandle://job/Test/1");
	OAK_ASSERT(WaitForTask(task));
	OAK_ASSERT(task.finished);
	OAK_ASSERT_EQ(to_s(task.response.MIMEType), "text/css");
	OAK_ASSERT_EQ(to_s([task string]), "body { color: red; }");
}

void test_percent_encoded_path ()
{
	HOFileSchemeHandler* handler = [HOFileSchemeHandler new];
	FakeSchemeTask* task = StartTask(handler, URL(@"site/æøå.txt"));
	OAK_ASSERT(WaitForTask(task));
	OAK_ASSERT_EQ(to_s([task string]), "Grønn & <tekst>");
	OAK_ASSERT_EQ(to_s(task.response.MIMEType), "text/plain");
}

void test_html_is_rewritten ()
{
	HOFileSchemeHandler* handler = [HOFileSchemeHandler new];
	FakeSchemeTask* task = StartTask(handler, URL(@"site/index.html"));
	OAK_ASSERT(WaitForTask(task));
	OAK_ASSERT_EQ(to_s(task.response.MIMEType), "text/html");
	OAK_ASSERT_EQ(to_s([task string]), "<link href=\"tm-file:///x.css\"><p>index</p>");
}

void test_directory_with_index ()
{
	HOFileSchemeHandler* handler = [HOFileSchemeHandler new];

	// With a trailing slash, index.html is served directly
	FakeSchemeTask* task = StartTask(handler, URL(@"site/"));
	OAK_ASSERT(WaitForTask(task));
	OAK_ASSERT([[task string] containsString:@"<p>index</p>"]);

	// Without, redirect so relative URLs resolve against the directory
	task = StartTask(handler, [URL(@"site") stringByAppendingString:@"?q=1#top"]);
	OAK_ASSERT(WaitForTask(task));
	OAK_ASSERT([[task string] containsString:@"location.replace"]);
	OAK_ASSERT([[task string] containsString:@"/site/index.html?q=1#top"]);
}

void test_missing_file ()
{
	HOFileSchemeHandler* handler = [HOFileSchemeHandler new];

	// As a document: an error page (with the path escaped)
	FakeSchemeTask* task = StartTask(handler, URL(@"<missing>.html"));
	OAK_ASSERT(WaitForTask(task));
	OAK_ASSERT(task.finished);
	OAK_ASSERT_EQ(((NSHTTPURLResponse*)task.response).statusCode, (NSInteger)404);
	OAK_ASSERT([[task string] containsString:@"File Not Found"]);
	OAK_ASSERT([[task string] containsString:@"&lt;missing>.html"]);

	// As a resource: an error
	task = StartTask(handler, URL(@"missing.png"), @"x-txmt-filehandle://job/Test/1");
	OAK_ASSERT(WaitForTask(task));
	OAK_ASSERT(!task.finished);
	OAK_ASSERT_EQ(task.error.code, (NSInteger)NSURLErrorFileDoesNotExist);

	// Directory without index.html
	task = StartTask(handler, URL(@"empty dir/"));
	OAK_ASSERT(WaitForTask(task));
	OAK_ASSERT_EQ(((NSHTTPURLResponse*)task.response).statusCode, (NSInteger)404);
}

void test_untrusted_page_is_refused ()
{
	HOFileSchemeHandler* handler = [HOFileSchemeHandler new];
	FakeSchemeTask* task = StartTask(handler, URL(@"site/css/style.css"), @"https://example.com/");
	OAK_ASSERT(WaitForTask(task));
	OAK_ASSERT(!task.finished);
	OAK_ASSERT_EQ(task.error.code, (NSInteger)NSURLErrorNoPermissionsToReadFile);
	OAK_ASSERT_EQ(task.data.length, (NSUInteger)0);
}

void test_stopped_task_is_not_used ()
{
	HOFileSchemeHandler* handler = [HOFileSchemeHandler new];
	// Start and stop in the same run loop cycle, so the file (read on a background queue) cannot be sent in between
	NSMutableURLRequest* request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:URL(@"site/css/style.css")]];
	FakeSchemeTask* task = [[FakeSchemeTask alloc] initWithRequest:request];
	OnMain(^{
		StartSchemeTask(handler, task);
		task.stopped = YES;
		StopSchemeTask(handler, task);
	});

	OAK_ASSERT(!WaitForTask(task, 1));
	OAK_ASSERT(!task.usedAfterStop);
}

void test_path_for_url ()
{
	OAK_ASSERT_EQ(to_s([HOFileSchemeHandler pathForURL:[NSURL URLWithString:@"tm-file:///etc/hosts"]]),          "/etc/hosts");
	OAK_ASSERT_EQ(to_s([HOFileSchemeHandler pathForURL:[NSURL URLWithString:@"tm-file://localhost/etc/hosts"]]), "/etc/hosts");
	OAK_ASSERT_EQ(to_s([HOFileSchemeHandler pathForURL:[NSURL URLWithString:@"tm-file:///a%20b"]]),              "/a b");
	OAK_ASSERT([HOFileSchemeHandler pathForURL:[NSURL URLWithString:@"tm-file://cdn.example.com/lib.js"]] == nil);
}
