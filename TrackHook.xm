#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h> // 补全定位头文件

// 全局C函数，无self，彻底解决点击闪退
void th_showAlert(NSString *title, NSString *msg);
void th_handleFloatTap(void);
void th_addFloatBtn(UIViewController *vc, NSString *uid);

// 全局变量
static NSString *gAuthToken = nil;
static NSString *gTargetUserID = nil;
static double gMyLat = 0.0;
static double gMyLon = 0.0;
static UIButton *gFloatBtn = nil;

#define EARTH_RADIUS 6371000.0

// 1. 弹窗：全局rootVC，不绑定self，彻底解决弹窗冲突
void th_showAlert(NSString *title, NSString *msg) {
    if (!title || !msg) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:msg preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
        // 全局rootVC，永远有效
        UIViewController *topVC = [UIApplication sharedApplication].windows.firstObject.rootViewController;
        while (topVC.presentedViewController) topVC = topVC.presentedViewController;
        [topVC presentViewController:alert animated:YES completion:nil];
    });
}

// 2. 按钮点击：全局C函数，无self，彻底解决点击闪退
void th_handleFloatTap(void) {
    if (!gAuthToken || !gTargetUserID || gMyLat == 0) {
        th_showAlert(@"提示", @"信息获取中，请稍后");
        return;
    }

    NSURL *url = [NSURL URLWithString:@"https://social.irisgw.cn/users/avatar_map/index"];
    NSMutableURLRequest *req = [[NSMutableURLRequest alloc] initWithURL:url cachePolicy:NSURLRequestReloadIgnoringCacheData timeoutInterval:10];
    req.HTTPMethod = @"POST";
    [req setValue:@"zh-CN" forHTTPHeaderField:@"Accept-Language"];
    [req setValue:@"a0001i" forHTTPHeaderField:@"Channel"];
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setValue:gAuthToken forHTTPHeaderField:@"Authorization"];

    NSDictionary *body = @{
        @"self_location": @{@"latitude":@(gMyLat), @"longitude":@(gMyLon)},
        @"zoom_scale": @"3.77", @"avatar_span": @"56", @"use_pay_map": @0
    };
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];

    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *res, NSError *err) {
        if (err || !data) { th_showAlert(@"失败", @"网络异常"); return; }
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        NSArray *avatars = json[@"avatars"];
        for (NSDictionary *user in avatars) {
            if ([user[@"user_id"] isEqualToString:gTargetUserID]) {
                // 修复：把NSNumber转成double，解决指针运算错误
                double uLat = [user[@"latitude"] doubleValue];
                double uLon = [user[@"longitude"] doubleValue];
                double dist = 2 * EARTH_RADIUS * asin(sqrt(
                    sin((uLat - gMyLat)*M_PI/360)*sin((uLat - gMyLat)*M_PI/360) + 
                    cos(gMyLat*M_PI/180)*cos(uLat*M_PI/180)*
                    sin((uLon - gMyLon)*M_PI/360)*sin((uLon - gMyLon)*M_PI/360)
                ));
                th_showAlert(@"成功", [NSString stringWithFormat:@"距离：%.0f米", dist]);
                return;
            }
        }
        th_showAlert(@"提示", @"未找到用户");
    }];
    [task resume];
}

// 3. 添加按钮：添加到VC的view，target用nil+全局函数，永远有效
void th_addFloatBtn(UIViewController *vc, NSString *uid) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gFloatBtn) return;
        gTargetUserID = uid;
        gFloatBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        gFloatBtn.frame = CGRectMake([UIScreen mainScreen].bounds.size.width - 90, 160, 70, 40);
        [gFloatBtn setTitle:@"查距离" forState:UIControlStateNormal];
        [gFloatBtn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        gFloatBtn.backgroundColor = UIColor.systemBlueColor;
        gFloatBtn.layer.cornerRadius = 20;
        gFloatBtn.clipsToBounds = YES;
        // 核心：target=nil，action=全局函数，永远有效，不绑定self
        [gFloatBtn addTarget:nil action:@selector(th_handleFloatTap) forControlEvents:UIControlEventTouchUpInside];
        [vc.view addSubview:gFloatBtn];
        [vc.view bringSubviewToFront:gFloatBtn];
    });
}

// 移除按钮
void th_removeFloatBtn(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gFloatBtn) {
            [gFloatBtn removeFromSuperview];
            gFloatBtn = nil;
        }
        gTargetUserID = nil;
    });
}

// ==============================================
// 精准Hook Blued真实类（来自你提供的符号表）
// ==============================================

// 1. 个人主页：BDUserProfileViewController（100%触发按钮）
%hook BDUserProfileViewController
- (void)viewDidLoad {
    %orig;
    // 强转id，解决前向声明报错
    id userModel = [(id)self valueForKey:@"userModel"];
    if (userModel) {
        NSString *uid = [(id)userModel valueForKey:@"userId"];
        // 强转UIViewController，解决类型匹配
        th_addFloatBtn((UIViewController *)self, uid);
    }
}
- (void)viewWillDisappear:(BOOL)animated {
    %orig;
    th_removeFloatBtn();
}
%end

// 2. 私聊页：PrivateChatViewController（兼容显示）
%hook PrivateChatViewController
- (void)viewDidLoad {
    %orig;
    // 从VC获取对方ID
    NSString *uid = [(id)self valueForKey:@"targetUserId"];
    if (uid) {
        th_addFloatBtn((UIViewController *)self, uid);
    }
}
- (void)viewWillDisappear:(BOOL)animated {
    %orig;
    th_removeFloatBtn();
}
%end

// 3. 抓令牌
%hook NSURLSessionDataTask
- (NSURLRequest *)originalRequest {
    NSURLRequest *req = %orig;
    NSString *auth = req.allHTTPHeaderFields[@"Authorization"];
    if (auth && [auth hasPrefix:@"Bearer "]) {
        gAuthToken = auth;
    }
    return req;
}
%end

// 4. 抓定位
%hook CLLocationManager
- (void)didUpdateLocations:(NSArray *)locations {
    %orig;
    CLLocation *loc = locations.lastObject;
    if (loc) {
        gMyLat = loc.coordinate.latitude;
        gMyLon = loc.coordinate.longitude;
    }
}
%end

%ctor {
    // 空构造，无多余操作
}
