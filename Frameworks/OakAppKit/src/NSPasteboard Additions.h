@interface NSPasteboard (OakFileURLs)
// Paths of all file URLs on the pasteboard, or nil if there are none
@property (nonatomic, readonly) NSArray<NSString*>* filePaths;
// YES if the pasteboard contains at least one file URL
@property (nonatomic, readonly) BOOL hasFilePaths;
@end
