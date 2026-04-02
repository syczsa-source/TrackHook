#import <UIKit/UIKit.h>
#import <substrate.h>
#import <Foundation/Foundation.h>

// 保留原有的前向声明（无需修改）
@class PrivateChatViewController;
@class CLLocationManager;
@class BDUserProfileViewController;
@class NSURLSessionDataTask;

// 原有的悬浮按钮函数（无需修改）
void th_addFloatingButton(UIViewController *vc) {
    // 你的悬浮按钮实现代码（保留原有逻辑）
    UIButton *floatBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    floatBtn.frame = CGRectMake(20, 100, 60, 60);
    floatBtn.backgroundColor = [UIColor redColor];
    floatBtn.layer.cornerRadius = 30;
    floatBtn.clipsToBounds = YES;
    [floatBtn setTitle:@"追踪" forState:UIControlStateNormal];
    [floatBtn addTarget:self action:@selector(floatBtnClicked:) forControlEvents:UIControlEventTouchUpInside];
    [vc.view addSubview:floatBtn];
}

// 追踪按钮点击事件（保留原有逻辑）
- (void)floatBtnClicked:(UIButton *)btn {
    NSLog(@"TrackHook: 悬浮按钮点击");
    // 你的业务逻辑
}

%hook BDUserProfileViewController

// 原有的方法（修复第127行、第130行）
- (void)viewDidLoad {
    %orig;
    
    // ===================== 修复点1：强转id解决前向声明报错 =====================
    id userModel = [(id)self valueForKey:@"userModel"];
    NSLog(@"TrackHook: 获取用户模型 %@", userModel);
    
    // 你的原有业务逻辑
    if (userModel) {
        // ===================== 修复点2：强转UIViewController*解决类型不匹配 =====================
        th_addFloatingButton((UIViewController *)self);
    }
}

%end

%hook PrivateChatViewController

// 原有的方法（修复第143行）
- (void)viewDidLoad {
    %orig;
    
    // ===================== 修复点3：强转UIViewController*解决类型不匹配 =====================
    th_addFloatingButton((UIViewController *)self);
}

%end
