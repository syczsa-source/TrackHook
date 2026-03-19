#import <UIKit/UIKit.h>

%ctor {
    NSLog(@"[TrackHook] Loaded");
}

%hook UIApplication

// 修复 iOS15+ windows 弃用问题
- (NSArray<UIWindow *> *)windows {
    if (@available(iOS 15.0, *)) {
        NSMutableArray *windows = [NSMutableArray array];
        for (UIScene *scene in self.connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]]) {
                [windows addObjectsFromArray:((UIWindowScene *)scene).windows];
            }
        }
        return windows;
    }
    
    // 旧系统走原始方法
    %orig;
}

%end