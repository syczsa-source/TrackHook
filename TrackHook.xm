#import <substrate.h>
#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>

#define TRACK_BTN_TAG 100001

// 声明目标类，防止编译警告
@interface UIViewController (TrackHook)
- (void)addTrackButton;
- (void)removeTrackButton;
- (NSString *)getTargetUid;
- (double)getInitialDistance;
- (void)showToast:(NSString *)message duration:(NSTimeInterval)duration;
@end

%hook USER_INFO_FRAGMENT_NEW

// --- 生命周期 Hook ---

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self addTrackButton];
    });
}

- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self removeTrackButton];
    });
}

// --- 通过 %new 注入新方法，解决 Unrecognized Selector 崩溃 ---

%new
- (void)addTrackButton {
    UIWindow *window = nil;
    if (@available(iOS 13.0, *)) {
        for (UIWindowScene* windowScene in [UIApplication sharedApplication].connectedScenes) {
            if (windowScene.activationState == UISceneActivationStateForegroundActive) {
                window = windowScene.windows.firstObject;
                break;
            }
        }
    } else {
        window = [UIApplication sharedApplication].keyWindow;
    }
    
    if (!window) return;
    [self removeTrackButton];

    UIButton *trackBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    trackBtn.tag = TRACK_BTN_TAG;
    [trackBtn setTitle:@"🛰️ 递归几何定位" forState:UIControlStateNormal];
    trackBtn.titleLabel.font = [UIFont boldSystemFontOfSize:12];
    trackBtn.backgroundColor = [UIColor colorWithRed:0.91f green:0.12f blue:0.39f alpha:1.0f];
    trackBtn.layer.cornerRadius = 10.0f;
    
    CGFloat btnWidth = 120.0f;
    CGFloat btnHeight = 40.0f;
    CGFloat screenWidth = [UIScreen mainScreen].bounds.size.width;
    trackBtn.frame = CGRectMake(screenWidth - btnWidth - 20, 150, btnWidth, btnHeight);
    
    [trackBtn addTarget:self action:@selector(trackBtnClicked:) forControlEvents:UIControlEventTouchUpInside];
    [window addSubview:trackBtn];
}

%new
- (void)removeTrackButton {
    UIWindow *window = [UIApplication sharedApplication].windows.firstObject;
    UIView *btn = [window viewWithTag:TRACK_BTN_TAG];
    if (btn) [btn removeFromSuperview];
}

%new
- (void)trackBtnClicked:(UIButton *)sender {
    NSString *uid = [self getTargetUid];
    double dist = [self getInitialDistance];
    
    if (!uid) {
        [self showToast:@"❌ 无法解析UID" duration:2.0];
        return;
    }
    
    [self showToast:[NSString stringWithFormat:@"🛰️ 启动追踪...\n目标: %@\n初始距离: %.2fkm", uid, dist] duration:3.0];
    
    // 异步执行定位逻辑
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // 此处调用您原有的 runRecursiveTrilateration 逻辑...
        // 注意：网络请求部分必须使用 [self showToast:...] 时切回主线程
    });
}

%new
- (NSString *)getTargetUid {
    @try {
        // 这里的 key 需要根据具体 App 的成员变量名微调
        id model = [self valueForKey:@"userModel"] ?: [self valueForKey:@"model"];
        return [model valueForKey:@"uid"] ?: [model valueForKey:@"user_id"];
    } @catch (NSException *exception) {
        return nil;
    }
}

%new
- (double)getInitialDistance {
    @try {
        id model = [self valueForKey:@"userModel"] ?: [self valueForKey:@"model"];
        return [[model valueForKey:@"distance"] doubleValue];
    } @catch (NSException *exception) {
        return -1.0;
    }
}

%new
- (void)showToast:(NSString *)message duration:(NSTimeInterval)duration {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *window = [UIApplication sharedApplication].windows.firstObject;
        UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(50, 100, 250, 60)];
        label.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.7];
        label.textColor = [UIColor whiteColor];
        label.textAlignment = NSTextAlignmentCenter;
        label.numberOfLines = 0;
        label.text = message;
        label.layer.cornerRadius = 10;
        label.clipsToBounds = YES;
        [window addSubview:label];
        
        [UIView animateWithDuration:0.5 delay:duration options:0 animations:^{ label.alpha = 0; } completion:^(BOOL f){ [label removeFromSuperview]; }];
    });
}

%end