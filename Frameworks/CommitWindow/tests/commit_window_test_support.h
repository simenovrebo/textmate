#ifndef COMMIT_WINDOW_TEST_SUPPORT_H_2HX8NQ4R
#define COMMIT_WINDOW_TEST_SUPPORT_H_2HX8NQ4R

// Objective-C classes for t_commit_window.mm (test files are wrapped in a namespace by gen_test)

// Delegate of a project window, which the server finds via TM_PROJECT_UUID
@interface ProjectWindowDelegate : NSObject <NSWindowDelegate>
@property (nonatomic) NSString* identifier;
@end

@implementation ProjectWindowDelegate
@end

#endif /* end of include guard: COMMIT_WINDOW_TEST_SUPPORT_H_2HX8NQ4R */
