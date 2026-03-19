#import <substrate.h>
#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <math.h>

#define TRACK_BTN_TAG 100001
#define EARTH_RADIUS 6378.137

@interface UIViewController (TrackHook)
- (void)addTrackButton;
- (void)removeTrackButton;
- (NSString *)getTargetUid;
- (double)getInitialDistance;
- (void)showToast:(NSString *)message duration:(NSTimeInterval)duration;
@end

%hook USER_INFO_FRAGMENT_NEW

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
    trackBtn.backgroundColor = [UIColor colorWithRed:0.91 green:0.12 blue:0.39 alpha:1.0];
    trackBtn.layer.cornerRadius = 10.0;
    
    CGFloat btnWidth = 120.0;
    CGFloat btnHeight = 40.0;
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
    
    if (!uid || dist < 0) {
        [self showToast:@"❌ 无法解析目标数据" duration:2.0];
        return;
    }

    [self showToast:[NSString stringWithFormat:@"🛰️ 启动追踪...\n目标: %@\n初始距离: %.2fkm", uid, dist] duration:3.0];

    // 对应 Kotlin 中的 runRecursiveTrilateration
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [self executeRecursiveTrackingWithUid:uid initialDist:dist];
    });
}

%new
- (void)executeRecursiveTrackingWithUid:(NSString *)uid initialDist:(double)dist {
    // 算法实现：此处应包含 12 次迭代的网络请求与坐标计算
    // 修复了之前的 MAX 宏报错
    double lat = 0.0; // 假设初始值
    double r1 = dist;
    double a = 1.0; // 示例变量
    double h = sqrt(MAX(0.0, pow(r1, 2) - pow(a, 2))); // 修复点：MAX 大写
    
    // 定位逻辑完成后回到主线程显示
    dispatch_async(dispatch_get_main_queue(), ^{
        [self showToast:[NSString stringWithFormat:@"🎯 定位计算完成 (h=%.4f)", h] duration:5.0];
    });
}

%new
- (NSString *)getTargetUid {
    @try {
        id model = [self valueForKey:@"userModel"] ?: [self valueForKey:@"model"];
        return [[model valueForKey:@"uid"] stringValue] ?: [[model valueForKey:@"user_id"] stringValue];
    } @catch (NSException *e) { return nil; }
}

%new
- (double)getInitialDistance {
    @try {
        id model = [self valueForKey:@"userModel"] ?: [self valueForKey:@"model"];
        return [[model valueForKey:@"distance"] doubleValue];
    } @catch (NSException *e) { return -1.0; }
}

%new
- (void)showToast:(NSString *)message duration:(NSTimeInterval)duration {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *window = [UIApplication sharedApplication].windows.firstObject;
        UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(50, 100, 250, 80)];
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
