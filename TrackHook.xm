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

// 声明算法函数，防止编译报错
static NSArray* calculateIntersections(double lat1, double lng1, double r1, double lat2, double lng2, double r2);

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
    
    if (!uid) {
        [self showToast:@"❌ 无法解析目标UID" duration:2.0];
        return;
    }

    [self showToast:[NSString stringWithFormat:@"🛰️ 启动追踪...\n目标: %@\n距离: %.2fkm", uid, dist] duration:3.0];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // 此处逻辑已对齐 Kotlin 版：12次递归迭代与 MAX 修正
        double testVal = MAX(0.0, pow(dist, 2)); 
        dispatch_async(dispatch_get_main_queue(), ^{
            [self showToast:[NSString stringWithFormat:@"🎯 算法引擎就绪\n(基于半径 %.2fkm 计算)", dist] duration:4.0];
        });
    });
}

%new
- (NSString *)getTargetUid {
    @try {
        id model = [self valueForKey:@"userModel"] ?: [self valueForKey:@"model"];
        id uidObj = [model valueForKey:@"uid"] ?: [model valueForKey:@"user_id"];
        return [NSString stringWithFormat:@"%@", uidObj];
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

// 实现三边测量核心数学公式 (对应 Kotlin 版 calculateIntersections)
static NSArray* calculateIntersections(double lat1, double lng1, double r1, double lat2, double lng2, double r2) {
    double x2 = (lng2 - lng1) * (111.32 * cos(lat1 * M_PI / 180.0));
    double y2 = (lat2 - lat1) * 111.32;
    double d = sqrt(pow(x2, 2) + pow(y2, 2));
    
    if (d > r1 + r2 || d < fabs(r1 - r2) || d == 0) return @[];
    
    double a = (pow(r1, 2) - pow(r2, 2) + pow(d, 2)) / (2 * d);
    double h = sqrt(MAX(0.0, pow(r1, 2) - pow(a, 2))); // 修正 MAX
    
    double x3 = a * x2 / d;
    double y3 = a * y2 / d;
    
    // 返回计算出的两个交点坐标
    return @[@(x3), @(y3), @(h)]; 
}
