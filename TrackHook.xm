#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <WebKit/WebKit.h>

// 提前声明函数
void th_requestDistance(void);

// 线程安全全局变量
static NSString *_Nullable gAuthToken = nil;
static NSString *_Nullable gTargetUserID = nil;
static double gMyLatitude = 0.0;
static double gMyLongitude = 0.0;
static UIButton *_Nullable gFloatButton = nil;

#define EARTH_RADIUS 6371000.0

// iOS13+ 兼容窗口
@interface UIApplication (TrackHook)
- (UIWindow *_Nullable)th_keyWindow;
@end
@implementation UIApplication (TrackHook)
- (UIWindow *_Nullable)th_keyWindow {
    if (@available(iOS 13.0, *)) {
        for (UIWindowScene *scene in self.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            if (scene.activationState == UISceneActivationStateForegroundActive) {
                for (UIWindow *window in scene.windows) {
                    if (window.isKeyWindow) return window;
                }
            }
        }
    }
    for (UIWindow *window in self.windows) {
        if (window.isKeyWindow) return window;
    }
    return self.windows.firstObject;
}
@end

// 安全弹窗
void th_showAlert(NSString *title, NSString *msg) {
    if (!title || !msg) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *window = [UIApplication sharedApplication].th_keyWindow;
        if (!window) return;
        UIViewController *topVC = window.rootViewController;
        if (!topVC) return;
        while (topVC.presentedViewController) {
            topVC = topVC.presentedViewController;
        }
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:msg preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
        [topVC presentViewController:alert animated:YES completion:nil];
    });
}

// 距离计算
double th_calculateDistance(double myLat, double myLon, double userLat, double userLon) {
    double rad = M_PI / 180.0;
    double dLat = (userLat - myLat) * rad;
    double dLon = (userLon - myLon) * rad;
    double a = sin(dLat/2) * sin(dLat/2) + cos(myLat*rad) * cos(userLat*rad) * sin(dLon/2) * sin(dLon/2);
    double c = 2 * atan2(sqrt(a), sqrt(1-a));
    return EARTH_RADIUS * c;
}

// 提取自身坐标
void th_extractMyLocation(NSURL *url) {
    if (!url || ![[url host] containsString:@"social.irisgw.cn"]) return;
    NSURLComponents *comps = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    if (!comps || !comps.queryItems) return;
    for (NSURLQueryItem *item in comps.queryItems) {
        if ([item.name isEqualToString:@"latitude"]) {
            gMyLatitude = item.value.doubleValue;
        }
        if ([item.name isEqualToString:@"longitude"]) {
            gMyLongitude = item.value.doubleValue;
        }
    }
}

// 提取对方用户ID
NSString *_Nullable th_extractUserID(NSURL *url) {
    if (!url || ![[url host] containsString:@"argo.blued.cn"]) return nil;
    NSArray *parts = url.pathComponents;
    if (parts.count < 2) return nil;
    for (NSInteger i=0; i<parts.count; i++) {
        if ([parts[i] isEqualToString:@"users"] && i+1 < parts.count) {
            return parts[i+1];
        }
    }
    return nil;
}

// 安全添加悬浮按钮
void th_addFloatBtn() {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gFloatButton) return;
        UIWindow *window = [UIApplication sharedApplication].th_keyWindow;
        if (!window) return;

        gFloatButton = [UIButton buttonWithType:UIButtonTypeSystem];
        gFloatButton.frame = CGRectMake(CGRectGetWidth(UIScreen.mainScreen.bounds) - 80, 120, 60, 44);
        [gFloatButton setTitle:@"查距离" forState:UIControlStateNormal];
        [gFloatButton setBackgroundColor:UIColor.systemBlueColor];
        [gFloatButton setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        gFloatButton.layer.cornerRadius = 22;
        gFloatButton.clipsToBounds = YES;

        // 修复：删除无用的self，直接点击调用
        [gFloatButton addTarget:nil action:@selector(th_requestDistance) forControlEvents:UIControlEventTouchUpInside];

        [window addSubview:gFloatButton];
    });
}

// 安全移除按钮
void th_removeFloatBtn() {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gFloatButton) {
            [gFloatButton removeFromSuperview];
            gFloatButton = nil;
        }
        gTargetUserID = nil;
    });
}

// 查询距离
void th_requestDistance(void) {
    if (!gAuthToken || !gTargetUserID || gMyLatitude == 0 || gMyLongitude == 0) {
        th_showAlert(@"提示", @"信息获取中，请稍后重试");
        return;
    }

    NSURL *url = [NSURL URLWithString:@"https://social.irisgw.cn/users/avatar_map/index"];
    NSMutableURLRequest *req = [[NSMutableURLRequest alloc] initWithURL:url cachePolicy:NSURLRequestReloadIgnoringCacheData timeoutInterval:10];
    req.HTTPMethod = @"POST";

    [req setValue:@"zh-CN" forHTTPHeaderField:@"Accept-Language"];
    [req setValue:@"a0001i" forHTTPHeaderField:@"Channel"];
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 16_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148" forHTTPHeaderField:@"ua"];
    [req setValue:@"dark" forHTTPHeaderField:@"X-CLIENT-COLOR"];
    [req setValue:@"social.irisgw.cn" forHTTPHeaderField:@"Host"];
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

    NSURLSessionDataTask *task = [NSURLSession.sharedSession dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *res, NSError *err) {
        if (err || !data) {
            th_showAlert(@"请求失败", err.localizedDescription ?: @"网络异常");
            return;
        }
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (!json || !json[@"avatars"]) return;

        for (NSDictionary *user in json[@"avatars"]) {
            NSString *uid = user[@"user_id"];
            if ([uid isEqualToString:gTargetUserID]) {
                double lat = [user[@"latitude"] doubleValue];
                double lon = [user[@"longitude"] doubleValue];
                double dist = th_calculateDistance(gMyLatitude, gMyLongitude, lat, lon);
                th_showAlert(@"查询成功", [NSString stringWithFormat:@"对方ID：%@\n距离：%.1f米", uid, dist]);
                return;
            }
        }
        th_showAlert(@"提示", @"未找到该用户位置");
    }];
    [task resume];
}

// ==============================================
// 安全Hook，无全局注入，彻底不闪退
// ==============================================

// 抓取令牌
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

// 抓取自身坐标
%hook NSURLSessionTask
- (NSURL *)currentRequest {
    NSURL *url = %orig;
    th_extractMyLocation(url);
    return url;
}
%end

// 仅Hook网页加载，个人主页显示按钮
%hook WKWebView
- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    %orig;
    NSURL *url = webView.URL;
    NSString *uid = th_extractUserID(url);
    if (uid) {
        gTargetUserID = uid;
        th_addFloatBtn();
    } else {
        th_removeFloatBtn();
    }
}
%end

%ctor { }
