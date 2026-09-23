#import "NSPasteboard Additions.h"

static NSDictionary* const kFileURLsOnly = @{ NSPasteboardURLReadingFileURLsOnlyKey: @YES };

@implementation NSPasteboard (OakFileURLs)
- (NSArray<NSString*>*)filePaths
{
	NSArray<NSURL*>* urls = [self readObjectsForClasses:@[ NSURL.class ] options:kFileURLsOnly];
	return urls.count ? [urls valueForKeyPath:@"path"] : nil;
}

- (BOOL)hasFilePaths
{
	return [self canReadObjectForClasses:@[ NSURL.class ] options:kFileURLsOnly];
}
@end
