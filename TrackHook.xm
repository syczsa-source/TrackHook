> Making all for tweak TrackHook…
==> Preprocessing TrackHook.xm…
==> Compiling TrackHook.xm (arm64)…
TrackHook.xm:115:15: error: no visible @interface for 'UIViewController' declares the selector 'th_showToast:duration:'
        [self th_showToast:@"数据已导出到剪贴板" duration:2.0];
         ~~~~ ^~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
TrackHook.xm:117:15: error: no visible @interface for 'UIViewController' declares the selector 'th_showToast:duration:'
        [self th_showToast:@"导出失败" duration:2.0];
         ~~~~ ^~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
TrackHook.xm:133:11: error: no visible @interface for 'UIViewController' declares the selector 'th_showToast:duration:'
    [self th_showToast:@"所有数据已清除" duration:2.0];
     ~~~~ ^~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
TrackHook.xm:159:11: error: no visible @interface for 'UIViewController' declares the selector 'th_showToast:duration:'
    [self th_showToast:@"测试请求已执行" duration:2.0];
     ~~~~ ^~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
TrackHook.xm:164:11: error: no visible @interface for 'UIViewController' declares the selector 'th_showToast:duration:'
    [self th_showToast:@"系统日志功能需要额外权限" duration:2.0];
     ~~~~ ^~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
TrackHook.xm:212:15: error: no visible @interface for 'UIViewController' declares the selector 'th_exportAllData'
        [self th_exportAllData];
         ~~~~ ^~~~~~~~~~~~~~~~
TrackHook.xm:216:15: error: no visible @interface for 'UIViewController' declares the selector 'th_clearAllData'
        [self th_clearAllData];
         ~~~~ ^~~~~~~~~~~~~~~
TrackHook.xm:220:15: error: no visible @interface for 'UIViewController' declares the selector 'th_testCoordinateRequest'
        [self th_testCoordinateRequest];
         ~~~~ ^~~~~~~~~~~~~~~~~~~~~~~~
TrackHook.xm:224:15: error: no visible @interface for 'UIViewController' declares the selector 'th_showSystemLog'
        [self th_showSystemLog];
         ~~~~ ^~~~~~~~~~~~~~~~
TrackHook.xm:333:19: error: no visible @interface for 'UIViewController' declares the selector 'th_showToast:duration:'
            [self th_showToast:@"Token已复制到剪贴板" duration:2.0];
             ~~~~ ^~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
TrackHook.xm:335:19: error: no visible @interface for 'UIViewController' declares the selector 'th_showToast:duration:'
            [self th_showToast:@"无Token可复制" duration:2.0];
             ~~~~ ^~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
TrackHook.xm:340:15: error: no visible @interface for 'UIViewController' declares the selector 'th_showAllRequests'
        [self th_showAllRequests];
         ~~~~ ^~~~~~~~~~~~~~~~~~
TrackHook.xm:346:15: error: no visible @interface for 'UIViewController' declares the selector 'th_showToast:duration:'
        [self th_showToast:msg duration:2.0];
         ~~~~ ^~~~~~~~~~~~~~~~~~~~~~~~~
TrackHook.xm:362:19: error: no visible @interface for 'UIViewController' declares the selector 'addTrackHookButton'
            [self addTrackHookButton];
             ~~~~ ^~~~~~~~~~~~~~~~~~
14 errors generated.
make[3]: *** [/Users/runner/work/TrackHook/TrackHook/.theos/obj/arm64/TrackHook.xm.9b1a04af.o] Error 1
rm /Users/runner/work/TrackHook/TrackHook/.theos/obj/arm64/TrackHook.xm.mm
make[2]: *** [/Users/runner/work/TrackHook/TrackHook/.theos/obj/arm64/TrackHook.dylib] Error 2
make[1]: *** [internal-library-all_] Error 2
make: *** [TrackHook.all.tweak.variables] Error 2
Error: Process completed with exit code 2.
