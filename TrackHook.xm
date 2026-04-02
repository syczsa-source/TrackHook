#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <WebKit/WebKit.h>

// 全局缓存变量
static NSString *gAuthToken = nil;
static NSString *gTargetUserID = nil;
static double gMyLatitude = 0.0;
static double gMyLongitude = 0.0;
static UIButton *gFloatButton = nil;

#define EARTH_RADIUS 6371000.0

// 弹窗
void showAlert(NSString *title, NSString *msg) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:msg preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
        UIViewController *topVC = [UIApplication sharedApplication].keyWindow.rootViewController;
        while (topVC.presentedViewController) topVC = topVC.presentedViewController;
        [topVC presentViewController:alert animated:YES completion:nil];
    });
}

// 距离计算
double calculateDistance(double myLat, double myLon, double userLat, double userLon) {
    double rad = M_PI / 180.0;
    double dLat = (userLat - myLat) * rad;
    double dLon = (userLon - myLon) * rad;
    double a = sin(dLat/2) * sin(dLat/2) + cos(myLat*rad) * cos(userLat*rad) * sin(dLon/2) * sin(dLon/2);
    double c = 2 * atan2(sqrt(a), sqrt(1-a));
    return EARTH_RADIUS * c;
}

// 提取自身经纬度
void extractMyLocationFromURL(NSURL *url) {
    if (!url || ![[url host] containsString:@"social.irisgw.cn"]) return;
    NSURLComponents *comps = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    for (NSURLQueryItem *item in comps.queryItems) {
        if ([item.name isEqualToString:@"latitude"]) gMyLatitude = [item.value doubleValue];
        if ([item.name isEqualToString:@"longitude"]) gMyLongitude = [item.value doubleValue];
    }
}

// 提取对方用户ID
NSString *extractTargetUserID(NSURL *url) {
    if (!url || ![[url host] containsString:@"argo.blued.cn"]) return nil;
    NSArray *parts = url.pathComponents;
    for (NSInteger i=0; i<parts.count; i++) {
        if ([parts[i] isEqualToString:@"users"] && i+1 < parts.count) return parts[i+1];
    }
    return nil;
}

// 查询距离
void requestUserDistance(void) {
    if (!gAuthToken || !gTargetUserID || gMyLatitude == 0 || gMyLongitude == 0) {
        showAlert(@"提示", @"未获取到令牌/位置/用户ID");
        return;
    }

    NSURL *url = [NSURL URLWithString:@"https://social.irisgw.cn/users/avatar_map/index"];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url timeoutInterval:10];
    req.HTTPMethod = @"POST";

    [req setValue:@"zh-CN" forHTTPHeaderField:@"Accept-Language"];
    [req setValue:@"a0001i" forHTTPHeaderField:@"Channel"];
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 16_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148" forHTTPHeaderField:@"ua"];
    [req setValue:@"dark" forHTTPHeaderField:@"X-CLIENT-COLOR"];
    [req setValue:@"social.irisgw.cn" forHTTPHeaderField:@"Host"];
    [req setValue:@"Mozilla/5.0 (iPhone; iOS 16.5; Scale/3.00; CPU iPhone OS 16_5 like Mac OS X) iOS/120547_2.54.7_6552_9711 (Asia/Shanghai) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 ibb/1.0.0 app/7" forHTTPHeaderField:@"User-Agent"];
    [req setValue:gAuthToken forHTTPHeaderField:@"Authorization"];
    [req setValue:@"https://social.irisgw.cn/users/avatar_map/index" forHTTPHeaderField:@"Referer"];
    [req setValue:@"br, gzip, deflate" forHTTPHeaderField:@"Accept-Encoding"];
    [req setValue:@"" forHTTPHeaderField:@"Cookie"];

    NSDictionary *body = @{
        @"self_location": @{
            @"latitude": [NSString stringWithFormat:@"%.15f", gMyLatitude],
            @"longitude": [NSString stringWithFormat:@"%.15f", gMyLongitude]
        },
        @"a": @{@"longitude": @"114.3785283207845", @"latitude": @"22.75266864772926"},
        @"b": @{@"longitude": @"114.39289441701", @"latitude": @"22.72386786230426"},
        @"zoom_scale": @"3.77",
        @"avatar_span": @"56",
        @"use_pay_map": @0
    };
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];

    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *res, NSError *err) {
        if (err || !data) { showAlert(@"请求失败", err.localizedDescription ?: @"网络错误"); return; }
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        NSArray *avatars = json[@"avatars"];
        for (NSDictionary *user in avatars) {
            NSString *uid = user[@"user_id"];
            if ([uid isEqualToString:gTargetUserID]) {
                double lat = [user[@"latitude"] doubleValue];
                double lon = [user[@"longitude"] doubleValue];
                double dist = calculateDistance(gMyLatitude, gMyLongitude, lat, lon);
                NSString *msg = [NSString stringWithFormat:@"对方ID：%@\n距离：%.1f 米", uid, dist];
                showAlert(@"查询成功", msg);
                return;
            }
        }
        showAlert(@"未找到", @"对方不在地图范围");
    }];
    [task resume];
}

// 悬浮按钮
void addFloatBtn() {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gFloatButton) return;
        UIWindow *window = [UIApplication sharedApplication].keyWindow;
        gFloatButton = [UIButton buttonWithType:UIButtonTypeSystem];
        gFloatButton.frame = CGRectMake([UIScreen mainScreen].bounds.size.width - 80, 120, 60, 44);
        [gFloatButton setTitle:@"查距离" forState:UIControlStateNormal];
        [gFloatButton setBackgroundColor:[UIColor systemBlueColor]];
        [gFloatButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        gFloatButton.layer.cornerRadius = 22;
        [gFloatButton addTarget:nil action:@selector(requestUserDistance) forControlEvents:UIControlEventTouchUpInside];
        [window addSubview:gFloatButton];
    });
}

void removeFloatBtn() {
    dispatch_async(dispatch_get_main_queue(), ^{
        [gFloatButton removeFromSuperview];
        gFloatButton = nil;
    });
}

// ==============================================
// 🔥 修复核心：%hook 全部写在全局作用域，不嵌套
// ==============================================

// 1. 抓取 Authorization 令牌
%hook NSURLRequest
- (NSDictionary *)allHTTPHeaderFields {
    NSDictionary *orig = %orig;
    NSString *auth = orig[@"Authorization"];
    if (auth && [auth hasPrefix:@"Basic "]) {
        gAuthToken = auth;
    }
    return orig;
}
%end

// 2. 抓取自身实时坐标
%hook NSURLSessionTask
- (NSURL *)currentRequest {
    NSURL *url = %orig;
    extractMyLocationFromURL(url);
    return url;
}
%end

// 3. 个人主页抓取用户ID + 按钮
%hook UIViewController
- (void)viewDidLoad {
    %orig;
    for (UIView *v in self.view.subviews) {
        if ([v isKindOfClass:[WKWebView class]]) {
            WKWebView *web = (WKWebView *)v;
            gTargetUserID = extractTargetUserID(web.URL);
            if (gTargetUserID) {
                addFloatBtn();
            }
        }
    }
}

- (void)viewWillDisappear:(BOOL)animated {
    %orig;
    removeFloatBtn();
    gTargetUserID = nil;
}
%end

// 构造函数（仅初始化，无hook）
%ctor {
    // 空即可，所有hook已在全局定义
}
