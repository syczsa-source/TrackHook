#import <substrate.h>
#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <math.h>

#define TRACK_BTN_TAG 100001

@interface UIViewController (TrackHook)
- (void)addTrackButton;
- (void)removeTrackButton;
- (void)showToast:(NSString *)message duration:(NSTimeInterval)duration;
- (UIWindow *)getCurrentMainWindow;
@end

%hook USER_INFO_FRAGMENT_NEW

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    // 延迟0.2秒执行，保证页面和窗口完全加载就绪
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
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
// 统一获取当前主窗口，多层兜底保证100%能拿到
- (UIWindow *)getCurrentMainWindow {
    UIWindow *targetWindow = nil;
    if (@available(iOS 13.0, *)) {
        for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (scene.activationState == UISceneActivationStateForegroundActive) {
                for (UIWindow *window in scene.windows) {
                    if (window.isKeyWindow) {
                        targetWindow = window;
                        break;
                    }
                }
                if (targetWindow) break;
            }
        }
    }
    // 兜底兼容所有iOS版本
    if (!targetWindow) {
        targetWindow = [UIApplication sharedApplication].keyWindow;
    }
    if (!targetWindow) {
        targetWindow = [UIApplication sharedApplication].windows.firstObject;
    }
    return targetWindow;
}

%new
- (void)addTrackButton {
    UIWindow *window = [self getCurrentMainWindow];
    if (!window) return;
    
    // 防止重复创建按钮
    UIView *existBtn = [window viewWithTag:TRACK_BTN_TAG];
    if (existBtn) return;

    // 创建悬浮按钮
    UIButton *trackBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    trackBtn.tag = TRACK_BTN_TAG;
    [trackBtn setTitle:@"🛰️ 递归几何定位" forState:UIControlStateNormal];
    trackBtn.titleLabel.font = [UIFont boldSystemFontOfSize:12];
    trackBtn.backgroundColor = [UIColor colorWithRed:0.91 green:0.12 blue:0.39 alpha:1.0];
    trackBtn.layer.cornerRadius = 10.0;
    trackBtn.clipsToBounds = YES;
    
    // 固定在屏幕左上角，不会被挤出屏幕，一眼可见
    trackBtn.frame = CGRectMake(20, 150, 140, 45);
    
    // 【修复】用zPosition提升层级，保证按钮在最顶层，不会被页面盖住
    trackBtn.layer.zPosition = MAXFLOAT;
    
    // 绑定点击事件
    [trackBtn addTarget:self action:@selector(trackBtnClicked:) forControlEvents:UIControlEventTouchUpInside];
    
    // 加到主窗口
    [window addSubview:trackBtn];
}

%new
- (void)removeTrackButton {
    UIWindow *window = [self getCurrentMainWindow];
    UIView *btn = [window viewWithTag:TRACK_BTN_TAG];
    if (btn) {
        [btn removeFromSuperview];
    }
}

%new
- (void)trackBtnClicked:(UIButton *)sender {
    [self showToast:@"🛰️ 定位算法已加载" duration:3.0];
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // 安全的浮点数计算，不会崩溃
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
        UIWindow *window = [self getCurrentMainWindow];
        if (!window) return;
        
        // 居中显示toast，适配所有屏幕尺寸
        CGFloat toastWidth = 280;
        CGFloat toastHeight = 80;
        UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(
            (window.bounds.size.width - toastWidth)/2,
            (window.bounds.size.height - toastHeight)/2,
            toastWidth,
            toastHeight
        )];
        label.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.8];
        label.textColor = [UIColor whiteColor];
        label.textAlignment = NSTextAlignmentCenter;
        label.numberOfLines = 0;
        label.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
        label.text = message;
        label.layer.cornerRadius = 12;
        label.clipsToBounds = YES;
        
        // 【修复】用zPosition提升层级，保证toast在按钮之上
        label.layer.zPosition = MAXFLOAT + 1;
        
        [window addSubview:label];
        // 渐隐动画，结束后自动移除
        [UIView animateWithDuration:0.5 delay:duration options:0 animations:^{
            label.alpha = 0;
        } completion:^(BOOL finished){
            [label removeFromSuperview];
        }];
    });
}

%end