#import <UIKit/UIKit.h>
#import <substrate.h>
#import <Foundation/Foundation.h>

// 前向声明（保留，无需修改）
@class PrivateChatViewController;
@class CLLocationManager;
@class BDUserProfileViewController;
@class NSURLSessionDataTask;

// 修复：全局C函数，移除self，参数传递控制器（无任何语法错误）
void th_addFloatingButton(UIViewController *vc) {
    UIButton *floatBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    floatBtn.frame = CGRectMake(20, 100, 60, 60);
    floatBtn.backgroundColor = [[UIColor redColor] colorWithAlphaComponent:0.9];
    floatBtn.layer.cornerRadius = 30;
    floatBtn.clipsToBounds = YES;
    [floatBtn setTitle:@"追踪" forState:UIControlStateNormal];
    [floatBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    
    // 核心修复：C函数不能用self，target改为控制器vc
    [floatBtn addTarget:vc action:@selector(floatBtnClicked:) forControlEvents:UIControlEventTouchUpInside];
    
    [vc.view addSubview:floatBtn];
}

%hook BDUserProfileViewController

- (void)viewDidLoad {
    %orig;

    // 修复1：强转id解决前向声明报错
    id userModel = [(id)self valueForKey:@"userModel"];
    NSLog(@"TrackHook: 获取用户模型成功 -> %@", userModel);

    if (userModel) {
        // 修复2：强转类型匹配参数
        th_addFloatingButton((UIViewController *)self);
    }
}

// 修复：点击方法放入hook内部（解决「缺少方法上下文」报错）
- (void)floatBtnClicked:(UIButton *)btn {
    NSLog(@"TrackHook: 悬浮按钮被点击");
    // 在这里写你的按钮点击逻辑
}

%end

%hook PrivateChatViewController

- (void)viewDidLoad {
    %orig;
    
    // 修复3：强转类型匹配参数
    th_addFloatingButton((UIViewController *)self);
}

// 复用点击方法
- (void)floatBtnClicked:(UIButton *)btn {
    NSLog(@"TrackHook: 私聊页悬浮按钮被点击");
}

%end
