#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>

// 全局变量
static NSString *gAuthToken = nil;
static NSString *gTargetUserID = nil;
static double gMyLat = 0.0;
static double gMyLon = 0.0;
static UIButton *gFloatBtn = nil;

#define EARTH_RADIUS 6371000.0

// 弹窗
void th_showAlert(NSString *title, NSString *msg) {
    if (!title || !msg) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:msg preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
        UIViewController *topVC = [UIApplication sharedApplication].windows.firstObject.rootViewController;
        while (topVC.presentedViewController) topVC = topVC.presentedViewController;
        [topVC presentViewController:alert animated:YES completion:nil];
    });
}

// 按钮点击
void th_floatBtnTapped(void) {
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

// 按钮拖动
void th_handlePan(UIPanGestureRecognizer *pan) {
    CGPoint point = [pan locationInView:gFloatBtn.superview];
    gFloatBtn.center = CGPointMake(point.x, point.y);
}

// 添加按钮
void th_addFloatBtn(UIViewController *vc, NSString *uid) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gFloatBtn) return;
        gTargetUserID = uid;
        
        // 按钮样式
        gFloatBtn = [UIButton buttonWithType:UIButtonTypeCustom];
        gFloatBtn.frame = CGRectMake([UIScreen mainScreen].bounds.size.width - 90, 160, 70, 40);
        gFloatBtn.backgroundColor = [[UIColor redColor] colorWithAlphaComponent:0.9];
        gFloatBtn.layer.cornerRadius = 20;
        gFloatBtn.clipsToBounds = YES;
        [gFloatBtn setTitle:@"查距离" forState:UIControlStateNormal];
        [gFloatBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        gFloatBtn.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
        
        // 点击事件
        [gFloatBtn addTarget:nil action:@selector(th_floatBtnTapped) forControlEvents:UIControlEventTouchUpInside];
        
        // 拖动事件
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:nil action:@selector(th_handlePan:)];
        [gFloatBtn addGestureRecognizer:pan];
        
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
// 仅保留个人主页的Hook，删掉了私聊页的逻辑
// ==============================================

// 个人主页：BDUserProfileViewController
// 核心：Hook viewDidAppear，确保userModel已经加载完成，100%能取到
%hook BDUserProfileViewController
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    // 这时候异步加载的userModel已经完成，100%非nil
    id userModel = [(id)self valueForKey:@"userModel"];
    if (userModel) {
        NSString *uid = [(id)userModel valueForKey:@"userId"];
        th_addFloatBtn((UIViewController *)self, uid);
    }
}
- (void)viewWillDisappear:(BOOL)animated {
    %orig;
    th_removeFloatBtn();
}
%end

// 抓令牌：Hook Blued自己的BDAPIManager，100%能抓到
%hook BDAPIManager
- (void)requestWithPath:(id)path method:(id)method parameters:(id)params completion:(id)completion {
    %orig;
    NSString *auth = [(id)self valueForKey:@"authorization"];
    if (auth) {
        gAuthToken = auth;
    }
}
%end

// 抓定位：Hook Blued自己的BLLocationManager，100%能抓到
%hook BLLocationManager
- (void)locationManager:(id)manager didUpdateLocations:(NSArray *)locations {
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
