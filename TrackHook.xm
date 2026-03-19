#import <substrate.h>
#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <math.h>

#define TRACK_BTN_TAG 100001

@interface UIViewController (TrackHook)
- (void)addTrackButton;
- (void)removeTrackButton;
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
    
    CGFloat screenWidth = [UIScreen mainScreen].bounds.size.width;
    trackBtn.frame = CGRectMake(screenWidth - 140, 150, 120, 40);
    
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
    [self showToast:@"🛰️ 定位算法已加载" duration:3.0];
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // 修复浮点数宏错误，用fmax替代MAX
        double dist = 1.0;
        double h = sqrt(fmax(0.0, pow(dist, 2) - 0.25));
        
        dispatch_async(dispatch_get_main_queue(), ^{
            [self showToast:[NSString stringWithFormat:@"🎯 计算就绪\n偏移量: %.4f", h] duration:4.0];
        });
    });
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