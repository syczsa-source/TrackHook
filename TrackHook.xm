#import <substrate.h>
#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <math.h>
#import <objc/runtime.h>

#define TRACK_BTN_TAG 100001
#define MAX_RECURSIVE_ATTEMPTS 12
#define LOCK_THRESHOLD 0.01
#define EARTH_RADIUS_KM 111.32

static NSString *g_bluedBasicToken = nil;
static NSString *g_currentTargetUid = nil;
static double g_initialDistance = -1.0;
static UIButton *g_trackButton = nil;
#define BLUED_BUNDLE_ID @"com.soft.blued"

%hook NSURLSession
- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSData *data, NSURLResponse *response, NSError *error))completionHandler {
    NSDictionary *headers = request.allHTTPHeaderFields;
    NSString *authHeader = headers[@"Authorization"] ?: headers[@"authorization"];
    if (authHeader && [authHeader hasPrefix:@"Basic "]) {
        NSString *token = [authHeader substringFromIndex:6];
        if (token.length > 0 && ![g_bluedBasicToken isEqualToString:token]) {
            g_bluedBasicToken = token;
        }
    }
    return %orig(request, completionHandler);
}
%end

%hook UIViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig(animated);
    dispatch_async(dispatch_get_main_queue(), ^{
        [self addTrackFloatButton];
    });
}

%new
- (void)addTrackFloatButton {
    UIWindow *keyWindow = [UIApplication sharedApplication].keyWindow;
    if (!keyWindow) return;

    if (g_trackButton || [keyWindow viewWithTag:TRACK_BTN_TAG]) return;

    CGFloat screenWidth = keyWindow.bounds.size.width;
    g_trackButton = [UIButton buttonWithType:UIButtonTypeCustom];
    g_trackButton.frame = CGRectMake(screenWidth - 150, 180, 130, 44);
    g_trackButton.tag = TRACK_BTN_TAG;
    g_trackButton.backgroundColor = [UIColor colorWithRed:0.91 green:0.12 blue:0.39 alpha:1.0];
    [g_trackButton setTitle:@"🛰️ 定位" forState:UIControlStateNormal];
    [g_trackButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    g_trackButton.titleLabel.font = [UIFont boldSystemFontOfSize:12];
    g_trackButton.layer.cornerRadius = 22;
    g_trackButton.clipsToBounds = YES;
    g_trackButton.layer.zPosition = 9999;

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(dragButton:)];
    [g_trackButton addGestureRecognizer:pan];
    [g_trackButton addTarget:self action:@selector(onTrackButtonClick) forControlEvents:UIControlEventTouchUpInside];

    [keyWindow addSubview:g_trackButton];
    [keyWindow bringSubviewToFront:g_trackButton];
}

%new
- (void)dragButton:(UIPanGestureRecognizer *)pan {
    UIView *btn = pan.view;
    UIWindow *window = btn.superview;
    if (!window) return;

    CGPoint trans = [pan translationInView:window];
    btn.center = CGPointMake(btn.center.x + trans.x, btn.center.y + trans.y);
    [pan setTranslation:CGPointZero inView:window];

    CGFloat margin = 10;
    CGRect f = btn.frame;
    f.origin.x = MAX(margin, MIN(f.origin.x, window.bounds.size.width - f.size.width - margin));
    f.origin.y = MAX(margin, MIN(f.origin.y, window.bounds.size.height - f.size.height - margin));
    btn.frame = f;
}

%new
- (UIViewController *)topViewController {
    UIViewController *top = [UIApplication sharedApplication].keyWindow.rootViewController;
    while (top.presentedViewController) {
        top = top.presentedViewController;
    }
    return top;
}

%new
- (void)showToast:(NSString *)msg duration:(NSTimeInterval)dur {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *window = [UIApplication sharedApplication].keyWindow;
        for (UIView *v in window.subviews) {
            if (v.tag == 99999) [v removeFromSuperview];
        }

        UILabel *lab = [[UILabel alloc] initWithFrame:CGRectMake(0,0,300,100)];
        lab.center = window.center;
        lab.tag = 99999;
        lab.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.8];
        lab.textColor = UIColor.whiteColor;
        lab.textAlignment = NSTextAlignmentCenter;
        lab.numberOfLines = 0;
        lab.layer.cornerRadius = 12;
        lab.clipsToBounds = YES;
        lab.text = msg;
        lab.layer.zPosition = 99999;

        [window addSubview:lab];
        [UIView animateWithDuration:0.5 delay:dur options:0 animations:^{
            lab.alpha = 0;
        } completion:^(BOOL b){
            [lab removeFromSuperview];
        }];
    });
}

%new
- (void)showResult:(BOOL)success msg:(NSString *)msg lat:(double)lat lng:(double)lng {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *top = [self topViewController];
        if (success) {
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"定位成功" message:msg preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"复制" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){
                UIPasteboard.generalPasteboard.string = [NSString stringWithFormat:@"%.8f,%.8f", lat, lng];
            }]];
            [alert addAction:[UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleCancel handler:nil]];
            [top presentViewController:alert animated:YES completion:nil];
        } else {
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"失败" message:msg preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleCancel handler:nil]];
            [top presentViewController:alert animated:YES completion:nil];
        }
    });
}

%new
- (double)fetchDistanceWithUid:(NSString *)uid token:(NSString *)token lat:(double)lat lng:(double)lng {
    NSString *urlStr = [NSString stringWithFormat:@"https://argo.blued.cn/users/%@/basic", uid];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlStr]];
    [req setValue:[NSString stringWithFormat:@"Basic %@", token] forHTTPHeaderField:@"Authorization"];
    req.timeoutInterval = 3;

    __block double dist = -1;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);

    NSURLSessionDataTask *task = [NSURLSession.sharedSession dataTaskWithRequest:req completionHandler:^(NSData *d, NSURLResponse *r, NSError *e){
        if (d && !e) {
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
            NSDictionary *data = json[@"data"];
            if (data && [data[@"is_hide_distance"] intValue] == 0) {
                dist = [data[@"distance"] doubleValue];
            }
        }
        dispatch_semaphore_signal(sem);
    }];
    [task resume];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4 * NSEC_PER_SEC)));
    return dist;
}

%new
- (void)autoFetchUserInfo {
    g_currentTargetUid = nil;
    g_initialDistance = -1;
    UIViewController *top = [self topViewController];

    unsigned int count = 0;
    objc_property_t *props = class_copyPropertyList(top.class, &count);
    for (int i=0; i<count; i++) {
        NSString *name = [NSString stringWithUTF8String:property_getName(props[i])];
        @try {
            id obj = [top valueForKey:name];
            NSString *uid = [obj valueForKey:@"uid"] ?: [obj valueForKey:@"user_id"];
            if (uid) {
                g_currentTargetUid = uid;
                id dist = [obj valueForKey:@"distance"];
                if ([dist isKindOfClass:NSNumber.class]) {
                    g_initialDistance = [dist doubleValue];
                } else if ([dist isKindOfClass:NSString.class]) {
                    g_initialDistance = [dist doubleValue];
                }
                break;
            }
        } @catch (id e) {}
    }
    free(props);
}

%new
- (void)onTrackButtonClick {
    [self autoFetchUserInfo];

    if (!g_currentTargetUid) {
        [self showToast:@"请先打开用户主页" duration:2];
        return;
    }
    if (g_initialDistance <= 0 || g_initialDistance >= 9999) {
        [self showResult:NO msg:@"对方隐藏了距离" lat:0 lng:0];
        return;
    }
    if (!g_bluedBasicToken) {
        [self showToast:@"请先刷新附近页获取Token" duration:2];
        return;
    }

    NSUserDefaults *ud = [[NSUserDefaults alloc] initWithSuiteName:BLUED_BUNDLE_ID];
    double lat = [ud doubleForKey:@"current_latitude"];
    double lng = [ud doubleForKey:@"current_longitude"];

    if (lat ==0 || lng ==0) {
        [self showToast:@"未获取到自身坐标" duration:2];
        return;
    }

    [self showToast:@"开始定位..." duration:2];

    dispatch_async(dispatch_get_global_queue(0,0), ^{
        double cLat = lat;
        double cLng = lng;
        double cDist = g_initialDistance;

        for (int i=0; i<8; i++) {
            double oLng = cLng + (cDist / (EARTH_RADIUS_KM * cos(cLat * M_PI/180)));
            double nDist = [self fetchDistanceWithUid:g_currentTargetUid token:g_bluedBasicToken lat:cLat lng:oLng];
            if (nDist <0) break;

            cLat = (cLat + cLat)/2;
            cLng = (cLng + oLng)/2;
            cDist = (cDist + nDist)/2;
        }

        NSString *msg = [NSString stringWithFormat:@"纬度：%.8f\n经度：%.8f", cLat, cLng];
        [self showResult:YES msg:msg lat:cLat lng:cLng];
    });
}

%end
