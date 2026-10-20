/* 
    Copyright (C) 2025  Serge Alagon

    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program.  If not, see <https://www.gnu.org/licenses/>. 
*/

/*
    ===== 修改说明 v11（2026-10-20）从"侦察"转"秒过" =====

    【v10 真机报告推翻了之前的全部假设】
    报告显示：
      1. 广告载体不是 AVPlayer，是支付宝自研的 BeeVideoPlayerView / MFCorePlayerView
         （所以 v3~v9 hook AVPlayer 一条都没命中）
      2. 命中的 15 秒 NSTimer 是 DTRpcOperation 的 RPC 超时，跟广告无关
         —— 15 秒不是 NSTimer 跑的
      3. 没有任何第三方广告 SDK（穿山甲/优量汇/快手全部零命中）
         —— 是支付宝自研广告体系
      4. 倒计时冻结的根本原因：不是 scene 事件，是广告自身的计时/播放被 App 主动暂停
         （AdRewardView 里有 pasueTimer: / resumeTimer:，进后台就调 pause）

    结论：v3~v9 方向从一开始就错了。吞 scene 事件对"视频/计时被暂停"毫无作用，
    只会让 App 状态错乱然后被系统杀掉。保活这条路正式关闭。

    【v11 做法：直接让广告"瞬间走完"】
    用 class-dump 解了 373MB 主二进制（AlipayWallet 12.12.30），拿到确定的方法签名：
        AdOpenScreenView    -exitAd                     零参数
        AdOpenScreenView    -exiAdWhenTimeOver          零参数
        CountdownButton     -setRemainingTime:(double)
        CountdownButton     -updateCountdown            零参数
        AdRewardView        -countDownFinish            零参数
        AdRewardedVideoView -countDownEnd               零参数
        BeeVideoPlayerView  -seekToTime:(double)
        BeeVideoPlayerView  -getCurrentTime  -> double
    全部从 __objc_methtype 核对过参数类型，直接 objc_msgSend 调用是安全的。

    点「秒过广告」后，按顺序自动尝试 6 种打法，每步 0.6 秒，一旦广告从视图树消失
    就跳过后续步骤。全程记录哪一步生效，报告里能查。

    【安全设计】
    - 每一步执行前都从视图树重新找"活着的"实例，广告关了就不会碰已释放的对象
    - 自动模式只认 AdOpenScreenView / AdRewardView / AdRewardedVideoView 三类，
      不认 CountdownButton（支付/转账页也有倒计时，误杀风险太高）
    - 自动模式默认关闭，需要手动打开

    ===== 以下是 v10 的原始说明，保留备查 =====
*/

/*
    ===== 修改说明 v10（2026-10-20，侦察版 / 方案 B 第一步）=====

    【为什么改】
    v3 ~ v9 已经证明"保活"这条路在 iOS 27 上封死：
        - 吞 scene 失活事件 → 切回前台必被系统终止（三次独立复现）
        - 不吞          → 广告倒计时在失活那一刻就冻结
    应用层无解。所以不再折腾保活，改为摸清那 15 秒广告到底是什么形态，
    然后直接让它"快速播完并发奖"。

    【v10 干的事】
    一次性把所有能想到的信息全采集下来，边采边写 TXT 到沙盒，
    长按浮窗 → 「导出TXT」→ 系统分享面板 → 存到"文件"/发给元宝。

    采集分六块：
      1. 环境快照      设备型号 / iOS 版本 / App 版本 / 后台模式 / 文件共享开关
      2. 镜像扫描      已加载的 dylib 里含广告 SDK 关键词的（CSJ/GDT/KSAd/…）
      3. 类名扫描      全量 objc_getClassList，筛广告相关类 + 父类
      4. 运行时时间线  VC 出现/present/dismiss、Window level、UILabel 文案、
                       NSTimer 间隔、WKWebView URL、AVPlayer、NSURLSession host
      5. 界面树        广告页出现时 / 手动点按钮时，抓 keyWindow 递归视图树
      6. scene diff    保留 v9 的原始 diff 日志，便于对照

    【关键设计】
    - 所有 hook 一律先调原实现，绝不 return 早退（v4 拦通知把 App 拦死过）
    - 全部用 method_setImplementation，不依赖 substrate / Logos / fishhook
    - 只用 NSClassFromString + respondsToSelector 探测 WebKit / AVFoundation，
      不 import 新头文件，避免 Makefile 增加 framework 链接（少一个失败点）
    - 日志环形缓冲 6000 条，超了丢最旧，绝不无限涨
    - 每 5 秒自动 flush 一次 latest.txt，崩了也不丢数据
    - 网络只记 host（去重），不记参数，避免把日志撑爆

    【默认状态】
    侦察恒开，不需要点任何按钮。保活开关默认关（v9 那套已无价值，留着会干扰日志）。
*/

#import <objc/runtime.h>
#import <objc/message.h>
#import <UserNotifications/UserNotifications.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <sys/sysctl.h>
#import <sys/time.h>
#import <sys/types.h>
#import <time.h>
#import <stdio.h>
#import <stdarg.h>
#import <stdlib.h>
#import "FloatingButtonWindow.h"
#import "PrivateHeaders.h"

#pragma mark - 常量

#define kReconMaxLines      6000
#define kReconMaxReportLen  900000

static BOOL isImmortalized;

#pragma mark - 侦察核心：全局状态

static NSMutableArray<NSString *> *gRecon = nil;      /* 时间线（环形缓冲） */
static NSMutableArray<NSString *> *gEnvLines = nil;   /* 环境 / 静态扫描结果 */
static NSMutableDictionary<NSString *, NSNumber *> *gDedupe = nil;
static NSMutableSet<NSString *> *gSeenHosts = nil;
static BOOL gDirty = YES;
static BOOL gReconEnabled = YES;
static NSUInteger gDroppedLines = 0;
static int gSnapshotCount = 0;
static NSTimeInterval gStartTime = 0;
static BOOL gInternalTimerGuard = NO;

static void reconInitOnce(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gRecon = [NSMutableArray array];
        gEnvLines = [NSMutableArray array];
        gDedupe = [NSMutableDictionary dictionary];
        gSeenHosts = [NSMutableSet set];
        gStartTime = [NSDate date].timeIntervalSince1970;
    });
}

/* 时间戳：绝对时间 + 相对进程启动的秒数，用于判断广告事件的先后顺序 */
static NSString *reconStamp(void) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    double elapsed = (double)tv.tv_sec + (double)tv.tv_usec / 1000000.0 - gStartTime;
    time_t sec = tv.tv_sec;
    struct tm tmv;
    localtime_r(&sec, &tmv);
    char buf[80];
    snprintf(buf, sizeof(buf), "%02d:%02d:%02d.%03d +%7.2fs",
             tmv.tm_hour, tmv.tm_min, tmv.tm_sec,
             (int)(tv.tv_usec / 1000), elapsed);
    return [NSString stringWithUTF8String:buf];
}

static NSString *reconTrim(NSString *s, NSUInteger max) {
    if (![s isKindOfClass:[NSString class]]) {
        return @"(非字符串)";
    }
    if (s.length <= max) {
        return s;
    }
    return [[s substringToIndex:max] stringByAppendingString:@"…"];
}

static void reconAppend(NSString *body) {
    if (!gReconEnabled || body == nil) {
        return;
    }
    reconInitOnce();

    NSString *line = [NSString stringWithFormat:@"%@ %@", reconStamp(), body];

    @synchronized (gRecon) {
        [gRecon addObject:line];
        if (gRecon.count > kReconMaxLines) {
            NSUInteger removeCount = 500;
            [gRecon removeObjectsInRange:NSMakeRange(0, removeCount)];
            gDroppedLines += removeCount;
        }
    }
    gDirty = YES;
}

static void reconLogF(NSString *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    NSString *body = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    reconAppend(body);
}

static void reconBanner(NSString *title) {
    reconAppend(@"");
    reconAppend([NSString stringWithFormat:@"========== %@ ==========", title ?: @""]);
}

/* 同一个 key 在 window 秒内只记一次，防止刷屏（支付宝的定时器/标签调用量极大） */
static BOOL reconAllow(NSString *key, NSTimeInterval window) {
    if (key.length == 0) {
        return YES;
    }
    reconInitOnce();
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    @synchronized (gDedupe) {
        NSNumber *last = gDedupe[key];
        if (last != nil && (now - last.doubleValue) < window) {
            return NO;
        }
        if (gDedupe.count > 900) {
            [gDedupe removeAllObjects];
        }
        gDedupe[key] = @(now);
    }
    return YES;
}

#pragma mark - 环境快照

static NSString *reconSysctlString(NSString *name) {
    size_t size = 0;
    if (sysctlbyname(name.UTF8String, NULL, &size, NULL, 0) != 0 || size == 0) {
        return nil;
    }
    char *buf = malloc(size);
    if (buf == NULL) {
        return nil;
    }
    NSString *result = nil;
    if (sysctlbyname(name.UTF8String, buf, &size, NULL, 0) == 0) {
        result = [NSString stringWithUTF8String:buf];
    }
    free(buf);
    return result;
}

static NSString *reconDocsDir(void) {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    return paths.firstObject;
}

static void reconCollectEnv(void) {
    reconInitOnce();

    UIDevice *device = [UIDevice currentDevice];
    NSDictionary *info = [[NSBundle mainBundle] infoDictionary];

    NSString *modes = @"(无)";
    id bgModes = info[@"UIBackgroundModes"];
    if ([bgModes isKindOfClass:[NSArray class]]) {
        modes = [bgModes componentsJoinedByString:@", "];
    }

    @synchronized (gEnvLines) {
        [gEnvLines addObject:@"扫描器        : AdRecon v11（侦察 + 秒过）"];
        [gEnvLines addObject:[NSString stringWithFormat:@"采集开始      : %@", [NSDate date]]];
        [gEnvLines addObject:[NSString stringWithFormat:@"iOS 版本      : %@", device.systemVersion]];
        [gEnvLines addObject:[NSString stringWithFormat:@"设备型号      : %@", reconSysctlString(@"hw.machine") ?: @"?"]];
        [gEnvLines addObject:[NSString stringWithFormat:@"App 名称      : %@", info[@"CFBundleName"] ?: @"?"]];
        [gEnvLines addObject:[NSString stringWithFormat:@"App 版本      : %@ (%@)",
                              info[@"CFBundleShortVersionString"] ?: @"?",
                              info[@"CFBundleVersion"] ?: @"?"]];
        [gEnvLines addObject:[NSString stringWithFormat:@"Bundle ID     : %@", info[@"CFBundleIdentifier"] ?: @"?"]];
        [gEnvLines addObject:[NSString stringWithFormat:@"后台模式      : %@", modes]];
        [gEnvLines addObject:[NSString stringWithFormat:@"文件共享开关  : %@",
                              [info[@"UIFileSharingEnabled"] boolValue] ? @"YES" : @"NO"]];
        [gEnvLines addObject:[NSString stringWithFormat:@"沙盒 Documents: %@", reconDocsDir() ?: @"?"]];
    }
    gDirty = YES;
}

/* 已加载镜像里含广告 SDK 关键词的 dylib —— 有命中就基本能锁定是哪家 SDK */
static void reconScanImages(void) {
    static NSArray<NSString *> *keywords = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        keywords = @[@"CSJ", @"Pangle", @"BUAd", @"GDT", @"KSAd", @"Kwai", @"BeiZi",
                     @"Taku", @"AnyThink", @"Mintegral", @"AppLovin", @"UnityAds",
                     @"Vungle", @"AdMob", @"GoogleMobileAds", @"PAG", @"AdSDK",
                     @"Menta", @"Ironsource", @"BaiduMobAd", @"WMAd", @"AdFit",
                     @"Sigmob", @"Octopus", @"Fyber", @"Chartboost", @"InMobi"];
    });

    NSMutableArray<NSString *> *hits = [NSMutableArray array];
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *nameC = _dyld_get_image_name(i);
        if (nameC == NULL) {
            continue;
        }
        NSString *path = [NSString stringWithUTF8String:nameC];
        if (path.length == 0) {
            continue;
        }
        for (NSString *kw in keywords) {
            if ([path rangeOfString:kw options:NSCaseInsensitiveSearch].location != NSNotFound) {
                [hits addObject:path.lastPathComponent];
                break;
            }
        }
    }

    [hits sortUsingSelector:@selector(compare:)];

    @synchronized (gEnvLines) {
        [gEnvLines addObject:@""];
        [gEnvLines addObject:[NSString stringWithFormat:@"已加载镜像数  : %u", count]];
        [gEnvLines addObject:[NSString stringWithFormat:@"广告 SDK 镜像 : %lu 个%@",
                              (unsigned long)hits.count,
                              hits.count == 0 ? @"（没命中，可能不是第三方 SDK，或还没加载）" : @""]];
        for (NSString *name in hits) {
            [gEnvLines addObject:[NSString stringWithFormat:@"  · %@", name]];
        }
    }

    /* App 包内的 Frameworks 也要列 —— 有些 SDK 是懒加载的，dyld 里还看不到 */
    NSMutableArray<NSString *> *bundleFrameworks = [NSMutableArray array];
    NSString *bundlePath = [[NSBundle mainBundle] bundlePath];
    NSFileManager *fileManager = [NSFileManager defaultManager];
    for (NSString *subDir in @[@"Frameworks", @"PlugIns"]) {
        NSString *dirPath = [bundlePath stringByAppendingPathComponent:subDir];
        NSArray<NSString *> *items = [fileManager contentsOfDirectoryAtPath:dirPath error:NULL];
        for (NSString *item in items) {
            [bundleFrameworks addObject:[NSString stringWithFormat:@"%@/%@", subDir, item]];
        }
    }
    [bundleFrameworks sortUsingSelector:@selector(compare:)];

    @synchronized (gEnvLines) {
        [gEnvLines addObject:@""];
        [gEnvLines addObject:[NSString stringWithFormat:@"包内 Frameworks 共 %lu 项",
                              (unsigned long)bundleFrameworks.count]];
        NSUInteger limit = MIN(bundleFrameworks.count, (NSUInteger)80);
        for (NSUInteger i = 0; i < limit; i++) {
            [gEnvLines addObject:[NSString stringWithFormat:@"  · %@", bundleFrameworks[i]]];
        }
        if (bundleFrameworks.count > limit) {
            [gEnvLines addObject:[NSString stringWithFormat:@"  …（其余 %lu 项省略）",
                                  (unsigned long)(bundleFrameworks.count - limit)]];
        }
    }
    gDirty = YES;
}

/* 全量类名扫描 —— 广告页/计时器/发奖回调的类名通常一眼能认出来 */
static void reconScanClasses(void) {
    static NSArray<NSString *> *keywordsLower = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        /* 先统一转小写，之后每个类名只做一次 lowercaseString + 普通 rangeOfString，
           比几万次 NSCaseInsensitiveSearch 快一个数量级 */
        NSArray<NSString *> *raw = @[@"Splash", @"Interstitial", @"RewardVideo", @"RewardedVideo",
                                     @"Reward", @"AdView", @"AdScene", @"AdManager", @"AdLoader",
                                     @"AdRequest", @"AdModel", @"AdController", @"AdPlayer",
                                     @"AdVideo", @"AdSDK", @"AdSlot", @"AdPage", @"AdVC",
                                     @"CSJ", @"BUAd", @"GDT", @"KSAd", @"Pangle", @"Promotion",
                                     @"Advertisement", @"Advert", @"APPromotion", @"APAd",
                                     @"FeedAd", @"BannerAd", @"ExpressAd", @"NativeAd",
                                     @"VideoAd", @"AdData", @"AdCache", @"AdConfig"];
        NSMutableArray<NSString *> *lowered = [NSMutableArray arrayWithCapacity:raw.count];
        for (NSString *word in raw) {
            [lowered addObject:[word lowercaseString]];
        }
        keywordsLower = [lowered copy];
    });

    int total = objc_getClassList(NULL, 0);
    if (total <= 0) {
        return;
    }
    Class *classes = (Class *)malloc(sizeof(Class) * (size_t)total);
    if (classes == NULL) {
        return;
    }
    total = objc_getClassList(classes, total);

    NSMutableArray<NSString *> *hits = [NSMutableArray array];

    for (int i = 0; i < total; i++) {
        Class cls = classes[i];
        const char *nameC = class_getName(cls);
        if (nameC == NULL) {
            continue;
        }
        NSString *name = [NSString stringWithUTF8String:nameC];
        if (name.length == 0) {
            continue;
        }

        NSString *nameLower = [name lowercaseString];
        BOOL matched = NO;
        for (NSString *kw in keywordsLower) {
            if ([nameLower rangeOfString:kw].location != NSNotFound) {
                matched = YES;
                break;
            }
        }
        if (!matched) {
            continue;
        }

        Class superCls = class_getSuperclass(cls);
        NSString *superName = superCls ? [NSString stringWithUTF8String:class_getName(superCls)] : @"?";
        [hits addObject:[NSString stringWithFormat:@"%@  (父类 %@)", name, superName]];
    }
    free(classes);

    [hits sortUsingSelector:@selector(compare:)];

    @synchronized (gEnvLines) {
        [gEnvLines addObject:@""];
        [gEnvLines addObject:[NSString stringWithFormat:@"加载类总数    : %d", total]];
        [gEnvLines addObject:[NSString stringWithFormat:@"广告相关类    : %lu 个", (unsigned long)hits.count]];
        NSUInteger limit = MIN(hits.count, (NSUInteger)280);
        for (NSUInteger i = 0; i < limit; i++) {
            [gEnvLines addObject:[NSString stringWithFormat:@"  · %@", hits[i]]];
        }
        if (hits.count > limit) {
            [gEnvLines addObject:[NSString stringWithFormat:@"  …（其余 %lu 个省略）",
                                  (unsigned long)(hits.count - limit)]];
        }
    }
    gDirty = YES;
}

#pragma mark - 判定：这像不像广告

static BOOL reconLooksLikeAd(NSString *className) {
    if (className.length == 0) {
        return NO;
    }
    static NSArray<NSString *> *tokens = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        tokens = @[@"AdPage", @"AdView", @"AdVC", @"AdController", @"AdPlayer",
                   @"AdVideo", @"AdScene", @"AdManager", @"AdLoader", @"Advert",
                   @"Splash", @"Interstitial", @"Reward", @"Promotion", @"Promo"];
    });
    for (NSString *token in tokens) {
        if ([className rangeOfString:token options:NSCaseInsensitiveSearch].location != NSNotFound) {
            return YES;
        }
    }
    return NO;
}

#pragma mark - 界面树抓取

static void reconDumpView(UIView *view, int depth, NSMutableString *out, int *budget) {
    if (view == nil || budget == NULL || *budget <= 0 || depth > 12) {
        return;
    }
    *budget -= 1;

    NSMutableString *indent = [NSMutableString string];
    for (int i = 0; i < depth; i++) {
        [indent appendString:@"  "];
    }

    CGRect frame = view.frame;
    [out appendFormat:@"%@%@ (%.0f,%.0f %.0fx%.0f)%@%@\n",
     indent,
     NSStringFromClass([view class]),
     frame.origin.x, frame.origin.y, frame.size.width, frame.size.height,
     view.hidden ? @" [hidden]" : @"",
     view.alpha < 0.05 ? @" [alpha≈0]" : @""];

    for (UIView *sub in view.subviews) {
        reconDumpView(sub, depth + 1, out, budget);
    }
}

static NSArray<UIWindow *> *reconAllWindows(void) {
    NSMutableArray<UIWindow *> *wins = [NSMutableArray array];
    UIApplication *app = [UIApplication sharedApplication];

    /* 用运行时消息发送，避开 connectedScenes 的 iOS 13 可用性检查 */
    SEL scenesSel = sel_getUid("connectedScenes");
    if ([app respondsToSelector:scenesSel]) {
        id scenes = ((id (*)(id, SEL))objc_msgSend)(app, scenesSel);
        for (id scene in scenes) {
            SEL windowsSel = sel_getUid("windows");
            if (![scene respondsToSelector:windowsSel]) {
                continue;
            }
            id sceneWindows = ((id (*)(id, SEL))objc_msgSend)(scene, windowsSel);
            for (id win in sceneWindows) {
                if ([win isKindOfClass:[UIWindow class]]) {
                    [wins addObject:(UIWindow *)win];
                }
            }
        }
    }
    if (wins.count == 0) {
        [wins addObjectsFromArray:app.windows];
    }
    return wins;
}

static void reconSnapshotUI(NSString *reason) {
    if (![NSThread isMainThread]) {
        NSString *copiedReason = [reason copy];
        dispatch_async(dispatch_get_main_queue(), ^{
            reconSnapshotUI(copiedReason);
        });
        return;
    }

    if (gSnapshotCount >= 5) {
        reconLogF(@"[UI] 已达抓取上限(5)，跳过：%@", reason ?: @"?");
        return;
    }
    gSnapshotCount += 1;

    NSMutableString *out = [NSMutableString string];
    [out appendFormat:@"\n---------- 界面树 #%d（%@）----------\n", gSnapshotCount, reason ?: @"?"];

    NSArray<UIWindow *> *wins = reconAllWindows();
    [out appendFormat:@"窗口数: %lu\n", (unsigned long)wins.count];

    UIWindow *keyWin = nil;
    for (UIWindow *win in wins) {
        [out appendFormat:@"  window %@ level=%.0f alpha=%.2f hidden=%d key=%d\n",
         NSStringFromClass([win class]),
         (double)win.windowLevel,
         win.alpha,
         win.hidden ? 1 : 0,
         [win isKeyWindow] ? 1 : 0];
        if ([win isKeyWindow]) {
            keyWin = win;
        }
    }
    if (keyWin == nil && wins.count > 0) {
        keyWin = wins.lastObject;
    }

    int budget = 420;
    if (keyWin != nil) {
        [out appendString:@"\n-- 主窗口递归视图树（类名 + frame）--\n"];
        reconDumpView(keyWin, 0, out, &budget);
    }
    if (budget <= 0) {
        [out appendString:@"…（节点数超限，已截断）\n"];
    }

    reconAppend(out);
}

/* 延迟版：present 的瞬间新页面还没上屏，等 0.8 秒再抓才看得出层级 */
static void reconSnapshotUILater(NSString *reason, double delay) {
    NSString *copied = [reason copy];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        reconSnapshotUI(copied);
    });
}

#pragma mark - 网络请求（只记 host，去重）

static void reconNoteURL(NSURL *url, NSString *source) {
    if (![url isKindOfClass:[NSURL class]]) {
        return;
    }
    NSString *host = url.host;
    if (host.length == 0) {
        return;
    }

    reconInitOnce();
    @synchronized (gSeenHosts) {
        if ([gSeenHosts containsObject:host]) {
            return;
        }
        if (gSeenHosts.count >= 400) {
            return;
        }
        [gSeenHosts addObject:host];
    }

    static NSArray<NSString *> *hostKeywords = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        hostKeywords = @[@"csj", @"pangolin", @"gdt", @"kuaishou", @"kwai",
                         @"beizi", @"taku", @"anythink", @"mintegral", @"applovin",
                         @"unityads", @"vungle", @"admob", @"doubleclick",
                         @"promotion", @"splash", @"adservice", @"adn", @"ads"];
    });

    BOOL suspect = NO;
    for (NSString *kw in hostKeywords) {
        if ([host rangeOfString:kw options:NSCaseInsensitiveSearch].location != NSNotFound) {
            suspect = YES;
            break;
        }
    }

    reconLogF(@"[NET] %@ %@%@/%@", source ?: @"?", suspect ? @"★ " : @"", host, reconTrim(url.path, 100));
}

static void reconNoteRequest(id request, NSString *source) {
    if (request == nil || ![request respondsToSelector:@selector(URL)]) {
        return;
    }
    id urlObj = [request URL];
    if ([urlObj isKindOfClass:[NSURL class]]) {
        reconNoteURL((NSURL *)urlObj, source);
    }
}

#pragma mark - Hook 安装宏

#define RECON_HOOK_I(clsName, selStr, hookIMP, origSlot)                          \
    do {                                                                          \
        if ((origSlot) == NULL) {                                                 \
            Class _c = objc_getClass(clsName);                                    \
            Method _m = _c ? class_getInstanceMethod(_c, sel_getUid(selStr)) : NULL; \
            if (_m != NULL) {                                                     \
                (origSlot) = (void *)method_getImplementation(_m);                \
                method_setImplementation(_m, (IMP)(hookIMP));                     \
            }                                                                     \
        }                                                                         \
    } while (0)

#define RECON_HOOK_C(clsName, selStr, hookIMP, origSlot)                          \
    do {                                                                          \
        if ((origSlot) == NULL) {                                                 \
            Class _c = objc_getClass(clsName);                                    \
            Method _m = _c ? class_getClassMethod(_c, sel_getUid(selStr)) : NULL;  \
            if (_m != NULL) {                                                     \
                (origSlot) = (void *)method_getImplementation(_m);                \
                method_setImplementation(_m, (IMP)(hookIMP));                     \
            }                                                                     \
        }                                                                         \
    } while (0)

#pragma mark - Hook：UIViewController

static void (*orig_viewDidAppear)(id, SEL, BOOL);
static void hook_viewDidAppear(id self, SEL _cmd, BOOL animated) {
    if (orig_viewDidAppear) {
        orig_viewDidAppear(self, _cmd, animated);
    }
    @try {
        NSString *cls = NSStringFromClass([self class]);
        if (reconAllow([@"vcappear:" stringByAppendingString:cls], 3.0)) {
            reconLogF(@"[VC] 出现 %@", cls);
        }
        if (reconLooksLikeAd(cls) && reconAllow([@"adsnap:" stringByAppendingString:cls], 20.0)) {
            reconLogF(@"[VC] ★ 疑似广告页：%@", cls);
            reconSnapshotUI([NSString stringWithFormat:@"广告页出现 %@", cls]);
        }
    } @catch (NSException *e) {
        (void)e;
    }
}

static void (*orig_viewDidDisappear)(id, SEL, BOOL);
static void hook_viewDidDisappear(id self, SEL _cmd, BOOL animated) {
    if (orig_viewDidDisappear) {
        orig_viewDidDisappear(self, _cmd, animated);
    }
    @try {
        NSString *cls = NSStringFromClass([self class]);
        if (reconAllow([@"vcdis:" stringByAppendingString:cls], 3.0)) {
            reconLogF(@"[VC] 消失 %@", cls);
        }
    } @catch (NSException *e) {
        (void)e;
    }
}

static void (*orig_presentVC)(id, SEL, id, BOOL, id);
static void hook_presentVC(id self, SEL _cmd, id viewController, BOOL animated, id completion) {
    @try {
        if (viewController != nil) {
            NSString *vcCls = NSStringFromClass([viewController class]);
            reconLogF(@"[VC] present %@ ← 来自 %@", vcCls, NSStringFromClass([self class]));
            if (reconLooksLikeAd(vcCls)) {
                reconLogF(@"[VC] ★ 疑似广告页被 present：%@", vcCls);
                reconSnapshotUILater([NSString stringWithFormat:@"present %@", vcCls], 0.8);
            }
        }
    } @catch (NSException *e) {
        (void)e;
    }
    if (orig_presentVC) {
        orig_presentVC(self, _cmd, viewController, animated, completion);
    }
}

static void (*orig_dismissVC)(id, SEL, BOOL, id);
static void hook_dismissVC(id self, SEL _cmd, BOOL animated, id completion) {
    @try {
        if (reconAllow([@"dismiss:" stringByAppendingString:NSStringFromClass([self class])], 1.0)) {
            reconLogF(@"[VC] dismiss %@", NSStringFromClass([self class]));
        }
    } @catch (NSException *e) {
        (void)e;
    }
    if (orig_dismissVC) {
        orig_dismissVC(self, _cmd, animated, completion);
    }
}

#pragma mark - Hook：UIWindow

static void (*orig_makeKeyAndVisible)(id, SEL);
static void hook_makeKeyAndVisible(id self, SEL _cmd) {
    @try {
        if ([self isKindOfClass:[UIWindow class]]) {
            UIWindow *win = (UIWindow *)self;
            reconLogF(@"[WIN] makeKeyAndVisible %@ level=%.0f",
                      NSStringFromClass([self class]), (double)win.windowLevel);
            if (win.windowLevel >= UIWindowLevelAlert) {
                reconSnapshotUILater(@"高 level 窗口现身", 0.5);
            }
        }
    } @catch (NSException *e) {
        (void)e;
    }
    if (orig_makeKeyAndVisible) {
        orig_makeKeyAndVisible(self, _cmd);
    }
}

static void (*orig_setWindowLevel)(id, SEL, CGFloat);
static void hook_setWindowLevel(id self, SEL _cmd, CGFloat level) {
    @try {
        if (level >= UIWindowLevelAlert && reconAllow([@"winlvl" stringByAppendingFormat:@"%.0f", (double)level], 5.0)) {
            reconLogF(@"[WIN] %@ windowLevel → %.0f", NSStringFromClass([self class]), (double)level);
        }
    } @catch (NSException *e) {
        (void)e;
    }
    if (orig_setWindowLevel) {
        orig_setWindowLevel(self, _cmd, level);
    }
}

#pragma mark - Hook：UILabel 文案（找倒计时数字）

static void (*orig_setText)(id, SEL, id);
static void hook_setText(id self, SEL _cmd, id text) {
    if (orig_setText) {
        orig_setText(self, _cmd, text);
    }
    @try {
        if (![text isKindOfClass:[NSString class]]) {
            return;
        }
        NSString *str = (NSString *)text;
        if (str.length == 0 || str.length > 40) {
            return;
        }

        BOOL interesting = NO;
        if ([str rangeOfString:@"秒"].location != NSNotFound) {
            interesting = YES;
        } else if ([str rangeOfString:@"跳过"].location != NSNotFound) {
            interesting = YES;
        } else if ([str rangeOfString:@"skip" options:NSCaseInsensitiveSearch].location != NSNotFound) {
            interesting = YES;
        } else if ([str rangeOfString:@"广告"].location != NSNotFound) {
            interesting = YES;
        } else if ([str rangeOfString:@"奖励"].location != NSNotFound ||
                   [str rangeOfString:@"领取"].location != NSNotFound) {
            interesting = YES;
        }
        if (!interesting) {
            return;
        }

        NSString *key = [NSString stringWithFormat:@"lbl:%@:%@", NSStringFromClass([self class]), str];
        if (reconAllow(key, 1.0)) {
            reconLogF(@"[LBL] %@ →「%@」", NSStringFromClass([self class]), str);
        }
    } @catch (NSException *e) {
        (void)e;
    }
}

#pragma mark - Hook：定时器（找 15 秒倒计时的驱动源）

static NSString *reconTimerStar(double interval) {
    if (interval >= 0.9 && interval <= 1.1) {
        return @" ★1秒";
    }
    if (interval >= 14.0 && interval <= 16.0) {
        return @" ★15秒";
    }
    if (interval >= 0.45 && interval <= 0.55) {
        return @" ★0.5秒";
    }
    return @"";
}

static id (*orig_timerTarget)(id, SEL, double, id, SEL, id, BOOL);
static id hook_timerTarget(id self, SEL _cmd, double interval, id target, SEL sel, id userInfo, BOOL repeats) {
    @try {
        if (target != nil) {
            NSString *key = [NSString stringWithFormat:@"tmr:%.2f:%@:%@",
                             interval, NSStringFromClass([target class]), NSStringFromSelector(sel)];
            if (reconAllow(key, 10.0)) {
                reconLogF(@"[TIMER] %.2fs repeats=%d %@ -%@%@",
                          interval, repeats ? 1 : 0,
                          NSStringFromClass([target class]),
                          NSStringFromSelector(sel),
                          reconTimerStar(interval));
            }
        }
    } @catch (NSException *e) {
        (void)e;
    }
    if (orig_timerTarget == NULL) {
        return nil;
    }
    return orig_timerTarget(self, _cmd, interval, target, sel, userInfo, repeats);
}

/* 第二个构造入口单独一个槽位，否则宏里的 "已挂过" 判断会把它跳过 */
static id (*orig_timerTarget2)(id, SEL, double, id, SEL, id, BOOL);
static id hook_timerTarget2(id self, SEL _cmd, double interval, id target, SEL sel, id userInfo, BOOL repeats) {
    @try {
        if (target != nil) {
            NSString *key = [NSString stringWithFormat:@"tmr2:%.2f:%@:%@",
                             interval, NSStringFromClass([target class]), NSStringFromSelector(sel)];
            if (reconAllow(key, 10.0)) {
                reconLogF(@"[TIMER] %.2fs repeats=%d %@ -%@ (timerWith:)%@",
                          interval, repeats ? 1 : 0,
                          NSStringFromClass([target class]),
                          NSStringFromSelector(sel),
                          reconTimerStar(interval));
            }
        }
    } @catch (NSException *e) {
        (void)e;
    }
    if (orig_timerTarget2 == NULL) {
        return nil;
    }
    return orig_timerTarget2(self, _cmd, interval, target, sel, userInfo, repeats);
}

static id (*orig_timerBlock)(id, SEL, double, BOOL, id);
static id hook_timerBlock(id self, SEL _cmd, double interval, BOOL repeats, id block) {
    @try {
        if (!gInternalTimerGuard) {
            NSString *key = [NSString stringWithFormat:@"tmrb:%.2f", interval];
            if (reconAllow(key, 10.0)) {
                reconLogF(@"[TIMER] %.2fs repeats=%d (block 版%@)",
                          interval, repeats ? 1 : 0, reconTimerStar(interval));
            }
        }
    } @catch (NSException *e) {
        (void)e;
    }
    if (orig_timerBlock == NULL) {
        return nil;
    }
    return orig_timerBlock(self, _cmd, interval, repeats, block);
}

static id (*orig_displayLink)(id, SEL, id, SEL);
static id hook_displayLink(id self, SEL _cmd, id target, SEL sel) {
    @try {
        NSString *key = [NSString stringWithFormat:@"cdl:%@:%@", NSStringFromClass([target class]), NSStringFromSelector(sel)];
        if (reconAllow(key, 10.0)) {
            reconLogF(@"[TIMER] CADisplayLink %@ -%@", NSStringFromClass([target class]), NSStringFromSelector(sel));
        }
    } @catch (NSException *e) {
        (void)e;
    }
    if (orig_displayLink == NULL) {
        return nil;
    }
    return orig_displayLink(self, _cmd, target, sel);
}

#pragma mark - Hook：WKWebView（判断是不是 H5 广告）

static id (*orig_loadRequest)(id, SEL, id);
static id hook_loadRequest(id self, SEL _cmd, id request) {
    @try {
        NSString *urlString = @"(nil)";
        if ([request respondsToSelector:@selector(URL)]) {
            id urlObj = [request URL];
            if ([urlObj isKindOfClass:[NSURL class]]) {
                urlString = [(NSURL *)urlObj absoluteString] ?: @"(nil)";
            }
        }
        reconLogF(@"[WEB] loadRequest %@", reconTrim(urlString, 300));
    } @catch (NSException *e) {
        (void)e;
    }
    if (orig_loadRequest == NULL) {
        return nil;
    }
    return orig_loadRequest(self, _cmd, request);
}

static id (*orig_loadHTML)(id, SEL, id, id);
static id hook_loadHTML(id self, SEL _cmd, id html, id baseURL) {
    @try {
        NSString *base = @"(nil)";
        if ([baseURL isKindOfClass:[NSURL class]]) {
            base = [(NSURL *)baseURL absoluteString] ?: @"(nil)";
        }
        reconLogF(@"[WEB] loadHTMLString base=%@ 长度=%lu", reconTrim(base, 160), (unsigned long)[html length]);
    } @catch (NSException *e) {
        (void)e;
    }
    if (orig_loadHTML == NULL) {
        return nil;
    }
    return orig_loadHTML(self, _cmd, html, baseURL);
}

static void (*orig_addUserScript)(id, SEL, id);
static void hook_addUserScript(id self, SEL _cmd, id script) {
    @try {
        if ([script respondsToSelector:@selector(source)]) {
            NSString *source = [script source];
            if ([source isKindOfClass:[NSString class]]) {
                reconLogF(@"[WEB] addUserScript 前 200 字：%@", reconTrim(source, 200));
            }
        }
    } @catch (NSException *e) {
        (void)e;
    }
    if (orig_addUserScript) {
        orig_addUserScript(self, _cmd, script);
    }
}

#pragma mark - Hook：AVPlayer（判断是不是视频广告）

static void (*orig_avPlay)(id, SEL);
static void hook_avPlay(id self, SEL _cmd) {
    @try {
        reconLogF(@"[VIDEO] AVPlayer play  %@", NSStringFromClass([self class]));
    } @catch (NSException *e) {
        (void)e;
    }
    if (orig_avPlay) {
        orig_avPlay(self, _cmd);
    }
}

static void (*orig_avSetRate)(id, SEL, float);
static void hook_avSetRate(id self, SEL _cmd, float rate) {
    @try {
        if (rate > 0.0f) {
            reconLogF(@"[VIDEO] AVPlayer setRate %.2f  %@", rate, NSStringFromClass([self class]));
        }
    } @catch (NSException *e) {
        (void)e;
    }
    if (orig_avSetRate) {
        orig_avSetRate(self, _cmd, rate);
    }
}

#pragma mark - Hook：NSURLSession（暴露广告 SDK 域名）

static id (*orig_dataTaskReq)(id, SEL, id, id);
static id hook_dataTaskReq(id self, SEL _cmd, id request, id handler) {
    @try {
        reconNoteRequest(request, @"dataTask");
    } @catch (NSException *e) {
        (void)e;
    }
    if (orig_dataTaskReq == NULL) {
        return nil;
    }
    return orig_dataTaskReq(self, _cmd, request, handler);
}

static id (*orig_dataTaskURL)(id, SEL, id, id);
static id hook_dataTaskURL(id self, SEL _cmd, id url, id handler) {
    @try {
        if ([url isKindOfClass:[NSURL class]]) {
            reconNoteURL((NSURL *)url, @"dataTask");
        }
    } @catch (NSException *e) {
        (void)e;
    }
    if (orig_dataTaskURL == NULL) {
        return nil;
    }
    return orig_dataTaskURL(self, _cmd, url, handler);
}

static id (*orig_downloadTaskReq)(id, SEL, id, id);
static id hook_downloadTaskReq(id self, SEL _cmd, id request, id handler) {
    @try {
        reconNoteRequest(request, @"downloadTask");
    } @catch (NSException *e) {
        (void)e;
    }
    if (orig_downloadTaskReq == NULL) {
        return nil;
    }
    return orig_downloadTaskReq(self, _cmd, request, handler);
}

/*
    NSURLSession 是类簇：sharedSession 返回的是 __NSCFURLSession 这类私有子类，
    只在 NSURLSession 上换 IMP 会漏掉子类自己的实现。
    所以遍历所有 NSURLSession 子类，只换"该类自己实现"的那份 method。
*/
static BOOL reconIsSubclassOf(Class cls, Class parent) {
    Class cursor = cls;
    while (cursor != Nil) {
        if (cursor == parent) {
            return YES;
        }
        cursor = class_getSuperclass(cursor);
    }
    return NO;
}

static BOOL reconClassOwnsSelector(Class cls, SEL sel, IMP *outIMP) {
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    BOOL found = NO;
    if (methods != NULL) {
        for (unsigned int i = 0; i < count; i++) {
            if (method_getName(methods[i]) == sel) {
                if (outIMP != NULL) {
                    *outIMP = method_getImplementation(methods[i]);
                }
                found = YES;
                break;
            }
        }
        free(methods);
    }
    return found;
}

static void reconHookURLSessionTasks(void) {
    Class base = objc_getClass("NSURLSession");
    if (base == NULL) {
        return;
    }

    SEL sels[3];
    sels[0] = sel_getUid("dataTaskWithRequest:completionHandler:");
    sels[1] = sel_getUid("dataTaskWithURL:completionHandler:");
    sels[2] = sel_getUid("downloadTaskWithRequest:completionHandler:");

    IMP hooks[3];
    hooks[0] = (IMP)hook_dataTaskReq;
    hooks[1] = (IMP)hook_dataTaskURL;
    hooks[2] = (IMP)hook_downloadTaskReq;

    void **origs[3];
    origs[0] = (void **)&orig_dataTaskReq;
    origs[1] = (void **)&orig_dataTaskURL;
    origs[2] = (void **)&orig_downloadTaskReq;

    int total = objc_getClassList(NULL, 0);
    if (total <= 0) {
        return;
    }
    Class *classes = (Class *)malloc(sizeof(Class) * (size_t)total);
    if (classes == NULL) {
        return;
    }
    total = objc_getClassList(classes, total);

    for (int i = 0; i < total; i++) {
        Class cls = classes[i];
        if (!reconIsSubclassOf(cls, base)) {
            continue;
        }
        for (int k = 0; k < 3; k++) {
            IMP current = NULL;
            if (!reconClassOwnsSelector(cls, sels[k], &current)) {
                continue;
            }
            if (current == hooks[k]) {
                continue;
            }
            Method method = class_getInstanceMethod(cls, sels[k]);
            if (method == NULL) {
                continue;
            }
            if (*(origs[k]) == NULL) {
                *(origs[k]) = (void *)current;
            }
            method_setImplementation(method, hooks[k]);
        }
    }
    free(classes);
}

#pragma mark - Hook 安装

static void reconInstallHooks(void) {
    static BOOL installed = NO;

    @try {
        /* --- UIViewController --- */
        RECON_HOOK_I("UIViewController", "viewDidAppear:", hook_viewDidAppear, orig_viewDidAppear);
        RECON_HOOK_I("UIViewController", "viewDidDisappear:", hook_viewDidDisappear, orig_viewDidDisappear);
        RECON_HOOK_I("UIViewController", "presentViewController:animated:completion:", hook_presentVC, orig_presentVC);
        RECON_HOOK_I("UIViewController", "dismissViewControllerAnimated:completion:", hook_dismissVC, orig_dismissVC);

        /* --- UIWindow --- */
        RECON_HOOK_I("UIWindow", "makeKeyAndVisible", hook_makeKeyAndVisible, orig_makeKeyAndVisible);
        RECON_HOOK_I("UIWindow", "setWindowLevel:", hook_setWindowLevel, orig_setWindowLevel);

        /* --- UILabel --- */
        RECON_HOOK_I("UILabel", "setText:", hook_setText, orig_setText);

        /* --- 定时器 --- */
        RECON_HOOK_C("NSTimer", "scheduledTimerWithTimeInterval:target:selector:userInfo:repeats:", hook_timerTarget, orig_timerTarget);
        RECON_HOOK_C("NSTimer", "timerWithTimeInterval:target:selector:userInfo:repeats:", hook_timerTarget2, orig_timerTarget2);
        RECON_HOOK_C("NSTimer", "scheduledTimerWithTimeInterval:repeats:block:", hook_timerBlock, orig_timerBlock);
        RECON_HOOK_C("CADisplayLink", "displayLinkWithTarget:selector:", hook_displayLink, orig_displayLink);

        /* --- 网络（类簇，单独处理） --- */
        reconHookURLSessionTasks();
    } @catch (NSException *e) {
        reconLogF(@"[INIT] 第一批 hook 异常：%@", e.reason ?: @"?");
    }

    /* WebKit / AVFoundation 可能在启动后才加载，每次调用都会补挂没挂上的 */
    @try {
        RECON_HOOK_I("WKWebView", "loadRequest:", hook_loadRequest, orig_loadRequest);
        RECON_HOOK_I("WKWebView", "loadHTMLString:baseURL:", hook_loadHTML, orig_loadHTML);
        RECON_HOOK_I("WKUserContentController", "addUserScript:", hook_addUserScript, orig_addUserScript);
        RECON_HOOK_I("AVPlayer", "play", hook_avPlay, orig_avPlay);
        RECON_HOOK_I("AVPlayer", "setRate:", hook_avSetRate, orig_avSetRate);
    } @catch (NSException *e) {
        reconLogF(@"[INIT] 第二批 hook 异常：%@", e.reason ?: @"?");
    }

    if (!installed) {
        installed = YES;
        reconLogF(@"[INIT] hook 安装完成 · VC=%d 窗口=%d 标签=%d 定时器=%d 网络=%d 网页=%d 视频=%d",
                  orig_viewDidAppear != NULL,
                  orig_makeKeyAndVisible != NULL,
                  orig_setText != NULL,
                  orig_timerTarget != NULL,
                  orig_dataTaskReq != NULL,
                  orig_loadRequest != NULL,
                  orig_avPlay != NULL);
    }
}

#pragma mark - Scene diff 日志（v9 原有，保留）

static NSMutableArray<NSString *> *gDiffLog = nil;

static void rememberDiff(NSString *line) {
    if (gDiffLog == nil) {
        gDiffLog = [NSMutableArray array];
    }
    if (line.length == 0) {
        line = @"(空)";
    }
    [gDiffLog addObject:line];
    while (gDiffLog.count > 40) {
        [gDiffLog removeObjectAtIndex:0];
    }
}

/* 给浮窗调用：返回当前日志快照 */
NSArray<NSString *> *ImmortalizerCopyDiffLog(void) {
    if (gDiffLog == nil) {
        return @[];
    }
    return [gDiffLog copy];
}

static void prefsChanged() {
    isImmortalized = [[NSUserDefaults standardUserDefaults] boolForKey:@"immortalized"];
}

#pragma mark - Scene 层拦截（v9 逻辑，原样保留，只做记录用）

static void (*original_sceneID_updateWithSettingsDiff_transitionContext_completion)(id, SEL, id, id, id, id);

/* 返回非 nil 表示这条更新要被吞掉，字符串顺便当日志里的原因 */
static NSString *dropReasonForDiff(NSString *diff) {
    if (diff.length == 0) {
        return nil;
    }

    /* iOS 27 新格式：foreground 拆成 flag / obj 两个键 */
    if ([diff containsString:@"foreground [obj] = 0"] ||
        [diff containsString:@"foreground [flag] = No"] ||
        [diff containsString:@"foreground [obj] = No"]) {
        return @"foreground";
    }

    /* iOS 14 ~ 26 旧格式，保留兼容 */
    if ([diff containsString:@"foreground = NotSet"] ||
        [diff containsString:@"foreground = No"] ||
        [diff containsString:@"foreground = BSSettingFlagNo"] ||
        [diff containsString:@"foreground = NO"]) {
        return @"foreground-legacy";
    }

    /*
        deactivationReasons 一律放行。v5 / v6 / v8 都证明：
        只要吞掉失活事件，iOS 27 就会在切回前台时终止进程（作者 issue #7）。
    */

    if ([diff containsString:@"hostContextIdentifierForSnapshotting = 0"] ||
        [diff containsString:@"scenePresenterRenderIdentifierForSnapshotting = 0"] ||
        [diff containsString:@"targetOfEventDeferringEnvironments = (empty)"]) {
        return @"snapshotting";
    }

    if ([diff containsString:@"FBSceneSnapshotAction:"]) {
        return @"snapshot-action";
    }

    return nil;
}

void new_sceneID_updateWithSettingsDiff_transitionContext_completion(id self, SEL _cmd, id arg1, id arg2, id arg3, id arg4) {
    @try {
        NSString *diffDescription = [arg2 description];
        NSString *reason = dropReasonForDiff(diffDescription);
        BOOL shouldDrop = (reason != nil);

        BOOL worthLogging = shouldDrop ||
                            [diffDescription containsString:@"foreground"] ||
                            [diffDescription containsString:@"deactivationReasons"] ||
                            [diffDescription containsString:@"Snapshotting"];

        if (worthLogging) {
            rememberDiff([NSString stringWithFormat:@"%@%@ %@",
                          shouldDrop ? @"DROP" : @"PASS",
                          reason ? [NSString stringWithFormat:@"(%@)", reason] : @"",
                          diffDescription ?: @"(null)"]);
        }

        if (isImmortalized && shouldDrop) {
            return;
        }
    } @catch (NSException *e) {
        (void)e;
    }

    if (original_sceneID_updateWithSettingsDiff_transitionContext_completion) {
        original_sceneID_updateWithSettingsDiff_transitionContext_completion(self, _cmd, arg1, arg2, arg3, arg4);
    }
}

#pragma mark - 状态查询拦截（v9 原样保留）

static UIApplicationState (*orig_applicationState)(id, SEL);

static UIApplicationState realApplicationState(void) {
    if (orig_applicationState == NULL) {
        return UIApplicationStateActive;
    }
    return orig_applicationState((id)UIApplication.sharedApplication, @selector(applicationState));
}

static UIApplicationState hook_applicationState(id self, SEL _cmd) {
    UIApplicationState real = orig_applicationState ? orig_applicationState(self, _cmd) : UIApplicationStateActive;

    if (real == UIApplicationStateActive) {
        return real;
    }

    void *returnAddress = __builtin_extract_return_addr(__builtin_return_address(0));
    Dl_info info;
    if (dladdr(returnAddress, &info) && info.dli_fname) {
        NSString *imageName = [NSString stringWithUTF8String:info.dli_fname];
        if ([imageName containsString:@"UserNotifications"] || [imageName containsString:@"PushKit"]) {
            return real;
        }
    }

    return UIApplicationStateActive;
}

#pragma mark - 通知展示拦截（v9 原样保留）

static void (*orig_willPresent)(id, SEL, UNUserNotificationCenter *, UNNotification *, void (^)(UNNotificationPresentationOptions));
static void hook_willPresent(id self, SEL _cmd, UNUserNotificationCenter *center, UNNotification *notification, void (^completionHandler)(UNNotificationPresentationOptions options)) {
    if (isImmortalized && realApplicationState() != UIApplicationStateActive) {
        completionHandler(UNNotificationPresentationOptionBanner | UNNotificationPresentationOptionSound | UNNotificationPresentationOptionBadge);
    } else if (orig_willPresent) {
        orig_willPresent(self, _cmd, center, notification, completionHandler);
    }
}

static void (*orig_setDelegate)(id, SEL, id<UNUserNotificationCenterDelegate>);
static void hook_setDelegate(id self, SEL _cmd, id<UNUserNotificationCenterDelegate> delegate) {
    if (orig_setDelegate) orig_setDelegate(self, _cmd, delegate);
    if (delegate) {
        Class delegateClass = [delegate class];
        SEL sel = @selector(userNotificationCenter:willPresentNotification:withCompletionHandler:);
        Method method = class_getInstanceMethod(delegateClass, sel);
        if (method) {
            IMP currentIMP = method_getImplementation(method);
            if (currentIMP != (IMP)hook_willPresent) {
                orig_willPresent = (void *)currentIMP;
                method_setImplementation(method, (IMP)hook_willPresent);
            }
        }
    }
}

#pragma mark - 报告生成

static NSString *reconReportTextInternal(void) {
    reconInitOnce();

    NSArray<NSString *> *timeline = nil;
    NSArray<NSString *> *envLines = nil;
    NSUInteger dropped = 0;
    int snapshots = 0;

    @synchronized (gRecon) {
        timeline = [gRecon copy];
        dropped = gDroppedLines;
        snapshots = gSnapshotCount;
    }
    @synchronized (gEnvLines) {
        envLines = [gEnvLines copy];
    }
    NSArray<NSString *> *diffLog = ImmortalizerCopyDiffLog();

    NSMutableString *out = [NSMutableString string];

    [out appendString:@"================================================================\n"];
    [out appendString:@"   支付宝广告 · 侦察 + 秒过报告（AdRecon v11）\n"];
    [out appendString:@"   由注入版 dylib 自动生成，直接把这个文件发给元宝\n"];
    [out appendString:@"================================================================\n\n"];

    /* ---- 高价值摘要 ---- */
    [out appendString:@"【零、★ 高价值摘要（先看这里）】\n"];
    NSMutableArray<NSString *> *stars = [NSMutableArray array];
    for (NSString *line in timeline) {
        if ([line rangeOfString:@"★"].location != NSNotFound) {
            [stars addObject:line];
            if (stars.count >= 80) {
                break;
            }
        }
    }
    if (stars.count == 0) {
        [out appendString:@"（没有命中任何 ★ 行。可能这次没遇到广告，或者广告形态不在已 hook 的范围内。）\n"];
    } else {
        for (NSString *line in stars) {
            [out appendString:line];
            [out appendString:@"\n"];
        }
        if (stars.count >= 80) {
            [out appendString:@"…（★ 行超过 80 条，只列前 80）\n"];
        }
    }
    [out appendString:@"\n"];

    /* ---- 环境 ---- */
    [out appendString:@"【一、环境与静态扫描】\n"];
    if (envLines.count == 0) {
        [out appendString:@"(空)\n"];
    } else {
        for (NSString *line in envLines) {
            [out appendString:line];
            [out appendString:@"\n"];
        }
    }
    [out appendString:@"\n"];

    /* ---- 时间线 ---- */
    [out appendString:@"【二、运行时时间线（时间顺序）】\n"];
    [out appendFormat:@"共 %lu 条%@，界面树抓取 %d 次\n",
     (unsigned long)timeline.count,
     dropped > 0 ? [NSString stringWithFormat:@"（早期 %lu 条已被环形缓冲丢弃）", (unsigned long)dropped] : @"",
     snapshots];
    [out appendString:@"--------------------------------------------------------------\n"];
    if (timeline.count == 0) {
        [out appendString:@"(空)\n"];
    } else {
        for (NSString *line in timeline) {
            [out appendString:line];
            [out appendString:@"\n"];
        }
    }
    [out appendString:@"\n"];

    /* ---- scene diff ---- */
    [out appendString:@"【三、scene settings diff（最近 40 条，v9 逻辑）】\n"];
    if (diffLog.count == 0) {
        [out appendString:@"(空)\n"];
    } else {
        NSInteger index = (NSInteger)diffLog.count;
        for (NSString *line in [diffLog reverseObjectEnumerator]) {
            [out appendFormat:@"[%ld] %@\n", (long)index--, line];
        }
    }
    [out appendString:@"\n"];

    /* ---- 说明 ---- */
    [out appendString:@"【四、怎么看这份报告】\n"];
    [out appendString:@"· 带 ★ 的是脚本判定的高价值线索\n"];
    [out appendString:@"· [NET] ★ 的域名基本就是广告 SDK 的服务器\n"];
    [out appendString:@"· [TIMER] ★1秒 / ★15秒 说明倒计时是原生定时器驱动的\n"];
    [out appendString:@"· [WEB] loadRequest 出现广告域名，说明是 H5 广告\n"];
    [out appendString:@"· [VIDEO] 有记录说明是 AVPlayer 视频广告\n"];
    [out appendString:@"· 界面树里的类名 + frame 能看出广告是独立页面还是覆盖层\n\n"];

    [out appendString:@"【五、本次 hook 覆盖范围】\n"];
    [out appendString:@"UIViewController viewDidAppear / viewDidDisappear / present / dismiss\n"];
    [out appendString:@"UIWindow makeKeyAndVisible / setWindowLevel\n"];
    [out appendString:@"UILabel setText（只记含 秒/跳过/skip/广告/奖励 的文案）\n"];
    [out appendString:@"NSTimer 三个构造入口 + CADisplayLink\n"];
    [out appendString:@"NSURLSession dataTask / downloadTask（只记 host，已去重）\n"];
    [out appendString:@"WKWebView loadRequest / loadHTMLString / addUserScript\n"];
    [out appendString:@"AVPlayer play / setRate\n\n"];
    [out appendString:@"未覆盖：C 函数级定时器（dispatch_source_set_timer）、\n"];
    [out appendString:@"        Swift 内部符号、服务端下发的动态脚本。\n"];
    [out appendString:@"如果报告里一片空白，说明广告全在这些层面，需要换侦察手段。\n\n"];

    [out appendString:@"【六、秒过能力（v11）】\n"];
    [out appendString:@"静态分析自 AlipayWallet 12.12.30 的 __objc_methtype，签名已核对：\n"];
    [out appendString:@"  AdOpenScreenView    -exitAd / -exiAdWhenTimeOver   零参数\n"];
    [out appendString:@"  CountdownButton     -setRemainingTime:(double) + -updateCountdown\n"];
    [out appendString:@"  AdRewardView        -countDownFinish               零参数\n"];
    [out appendString:@"  AdRewardedVideoView -countDownEnd                  零参数\n"];
    [out appendString:@"  BeeVideoPlayerView  -seekToTime:(double) / -getCurrentTime\n"];
    [out appendString:@"执行顺序：倒计时归零 → 视频快进 → 激励结束 → 激励视频结束 → 开屏时间到 → 开屏退出\n"];
    [out appendString:@"每步间隔 0.6 秒，广告一消失就跳过后续步骤。日志里搜 [KILL] 能看到过程。\n\n"];

    [out appendString:@"【七、生成信息】\n"];
    [out appendFormat:@"生成时间: %@\n", [NSDate date]];
    [out appendFormat:@"插件版本: AdRecon v11\n"];
    [out appendFormat:@"设备    : %@ / iOS %@\n",
     reconSysctlString(@"hw.machine") ?: @"?",
     [[UIDevice currentDevice] systemVersion]];

    if (out.length > kReconMaxReportLen) {
        [out setString:[[out substringToIndex:kReconMaxReportLen]
                        stringByAppendingString:@"\n\n…（报告超过 90 万字，已截断）\n"]];
    }

    return out;
}

NSString *ReconReportText(void) {
    @try {
        return reconReportTextInternal();
    } @catch (NSException *e) {
        return [NSString stringWithFormat:@"报告生成失败：%@", e.reason ?: @"未知异常"];
    }
}

NSString *ReconWriteReportFile(void) {
    NSString *text = ReconReportText();
    NSString *dir = reconDocsDir();
    if (dir.length == 0 || text.length == 0) {
        return nil;
    }

    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.dateFormat = @"yyyyMMdd-HHmmss";
    NSString *stamp = [formatter stringFromDate:[NSDate date]];
    NSString *fileName = [NSString stringWithFormat:@"AdRecon-v11-%@.txt", stamp];
    NSString *path = [dir stringByAppendingPathComponent:fileName];

    NSError *error = nil;
    BOOL ok = [text writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:&error];
    if (!ok) {
        return nil;
    }

    NSString *latest = [dir stringByAppendingPathComponent:@"AdRecon-latest.txt"];
    [text writeToFile:latest atomically:YES encoding:NSUTF8StringEncoding error:NULL];

    return path;
}

/* 最近一次自动落盘的文件（5 秒一次），崩了也能找回 */
NSString *ReconLatestFilePath(void) {
    NSString *dir = reconDocsDir();
    if (dir.length == 0) {
        return nil;
    }
    return [dir stringByAppendingPathComponent:@"AdRecon-latest.txt"];
}

static void reconAutoFlush(void) {
    if (!gDirty) {
        return;
    }
    gDirty = NO;

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
        NSString *text = ReconReportText();
        NSString *latest = ReconLatestFilePath();
        if (text.length == 0 || latest.length == 0) {
            return;
        }
        [text writeToFile:latest atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    });
}

/* 供浮窗调用 */
void ReconMark(NSString *label) {
    reconBanner([NSString stringWithFormat:@"用户标记：%@", label ?: @"?"]);
}

void ReconSnapshotUIExternal(void) {
    reconSnapshotUI(@"手动点击抓取");
}

NSInteger ReconLineCount(void) {
    reconInitOnce();
    @synchronized (gRecon) {
        return (NSInteger)gRecon.count;
    }
}

#pragma mark - 广告秒过（v11 新增）
/*
    静态分析依据（class-dump AlipayWallet 12.12.30，__objc_methtype 已核对类型）：
        AdOpenScreenView     -exitAd                        v16@0:8
        AdOpenScreenView     -exiAdWhenTimeOver             v16@0:8
        AdOpenScreenView     -countdownBoutton              @16@0:8
        CountdownButton      -setRemainingTime:             v24@0:8d16
        CountdownButton      -updateCountdown               v16@0:8
        CountdownButton      -cancelCountdown               v16@0:8
        AdRewardView         -countDownFinish               v16@0:8
        AdRewardView         -didCloseView                  v16@0:8
        AdRewardedVideoView  -countDownEnd                  v16@0:8
        AdRewardedVideoView  -closeView                     v16@0:8
        BeeVideoPlayerView   -seekToTime:                   v24@0:8d16
        BeeVideoPlayerView   -getCurrentTime                d16@0:8
*/

static BOOL gAdKillRunning = NO;
static NSTimeInterval gLastAutoKill = 0;
static int gAutoKillCount = 0;

static void adCollectViews(UIView *root, Class cls, NSMutableArray *out, int depth) {
    if (root == nil || out == nil || depth > 40) {
        return;
    }
    if ([root isKindOfClass:cls]) {
        [out addObject:root];
    }
    for (UIView *sub in root.subviews) {
        adCollectViews(sub, cls, out, depth + 1);
    }
}

/* 从当前所有窗口的视图树里找存活实例（拿到的都是强引用，调用期间不会被释放） */
static NSArray *adFindViews(NSString *className) {
    Class cls = NSClassFromString(className);
    if (cls == NULL) {
        return @[];
    }
    NSMutableArray *out = [NSMutableArray array];
    for (UIWindow *win in reconAllWindows()) {
        adCollectViews(win, cls, out, 0);
    }
    return out;
}

static NSInteger adCount(NSString *className) {
    return (NSInteger)adFindViews(className).count;
}

static BOOL adCall(id target, NSString *selName) {
    if (target == nil) {
        return NO;
    }
    SEL sel = NSSelectorFromString(selName);
    if (![target respondsToSelector:sel]) {
        return NO;
    }
    ((void (*)(id, SEL))objc_msgSend)(target, sel);
    return YES;
}

static BOOL adCallD(id target, NSString *selName, double value) {
    if (target == nil) {
        return NO;
    }
    SEL sel = NSSelectorFromString(selName);
    if (![target respondsToSelector:sel]) {
        return NO;
    }
    ((void (*)(id, SEL, double))objc_msgSend)(target, sel, value);
    return YES;
}

static double adCallRetD(id target, NSString *selName) {
    if (target == nil) {
        return 0;
    }
    SEL sel = NSSelectorFromString(selName);
    if (![target respondsToSelector:sel]) {
        return 0;
    }
    return ((double (*)(id, SEL))objc_msgSend)(target, sel);
}

static NSString *adSnapshotState(void) {
    static NSArray<NSString *> *names = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        names = @[@"AdOpenScreenView", @"AdRewardView", @"AdRewardedVideoView",
                  @"AdInterstitialView", @"CDPHugeAdView", @"AdBannerView",
                  @"CountdownButton", @"BeeVideoPlayerView"];
    });

    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (NSString *name in names) {
        NSInteger count = adCount(name);
        if (count > 0) {
            [parts addObject:[NSString stringWithFormat:@"%@×%ld", name, (long)count]];
        }
    }
    return parts.count > 0 ? [parts componentsJoinedByString:@", "] : @"(屏上已无广告视图)";
}

/* 自动模式只认这三个类，绝不碰 CountdownButton（支付页也有倒计时） */
static BOOL adAdPresent(void) {
    return adCount(@"AdOpenScreenView") > 0 ||
           adCount(@"AdRewardView") > 0 ||
           adCount(@"AdRewardedVideoView") > 0;
}

static void adPerformStep(NSString *step) {
    @try {
        if ([step isEqualToString:@"countdown-zero"]) {
            NSArray *buttons = adFindViews(@"CountdownButton");
            if (buttons.count == 0) {
                reconLogF(@"[KILL] ①倒计时归零：屏上没有 CountdownButton，跳过");
                return;
            }
            for (id button in buttons) {
                BOOL set = adCallD(button, @"setRemainingTime:", 0.0);
                BOOL upd = adCall(button, @"updateCountdown");
                reconLogF(@"[KILL] ①倒计时归零 set=%@ update=%@", set ? @"OK" : @"NO", upd ? @"OK" : @"NO");
            }
            return;
        }

        if ([step isEqualToString:@"video-seek-end"]) {
            NSArray *players = adFindViews(@"BeeVideoPlayerView");
            if (players.count == 0) {
                reconLogF(@"[KILL] ②视频快进：屏上没有 BeeVideoPlayerView，跳过");
                return;
            }
            for (id player in players) {
                double now = adCallRetD(player, @"getCurrentTime");
                BOOL ok = adCallD(player, @"seekToTime:", now + 600.0);
                reconLogF(@"[KILL] ②视频快进 当前位置=%.1fs → seek=%@", now, ok ? @"OK" : @"NO");
            }
            return;
        }

        if ([step isEqualToString:@"reward-finish"]) {
            NSArray *views = adFindViews(@"AdRewardView");
            if (views.count == 0) {
                reconLogF(@"[KILL] ③激励倒计时结束：屏上没有 AdRewardView，跳过");
                return;
            }
            for (id view in views) {
                BOOL ok = adCall(view, @"countDownFinish");
                reconLogF(@"[KILL] ③激励倒计时结束 countDownFinish=%@", ok ? @"OK" : @"NO");
            }
            return;
        }

        if ([step isEqualToString:@"rewardvideo-end"]) {
            NSArray *views = adFindViews(@"AdRewardedVideoView");
            if (views.count == 0) {
                reconLogF(@"[KILL] ④激励视频结束：屏上没有 AdRewardedVideoView，跳过");
                return;
            }
            for (id view in views) {
                BOOL end = adCall(view, @"countDownEnd");
                reconLogF(@"[KILL] ④激励视频结束 countDownEnd=%@", end ? @"OK" : @"NO");
            }
            return;
        }

        if ([step isEqualToString:@"openscreen-timeover"]) {
            NSArray *views = adFindViews(@"AdOpenScreenView");
            if (views.count == 0) {
                reconLogF(@"[KILL] ⑤开屏时间到：屏上没有 AdOpenScreenView，跳过");
                return;
            }
            for (id view in views) {
                BOOL ok = adCall(view, @"exiAdWhenTimeOver");
                reconLogF(@"[KILL] ⑤开屏时间到 exiAdWhenTimeOver=%@", ok ? @"OK" : @"NO");
            }
            return;
        }

        if ([step isEqualToString:@"openscreen-exit"]) {
            NSArray *views = adFindViews(@"AdOpenScreenView");
            if (views.count == 0) {
                reconLogF(@"[KILL] ⑥开屏强制退出：屏上没有 AdOpenScreenView，跳过");
                return;
            }
            for (id view in views) {
                BOOL exit1 = adCall(view, @"exitAd");
                reconLogF(@"[KILL] ⑥开屏强制退出 exitAd=%@", exit1 ? @"OK" : @"NO");
            }
            return;
        }
    } @catch (NSException *e) {
        reconLogF(@"[KILL] 步骤 %@ 异常：%@", step, e.reason ?: @"?");
    }
}

void AdKillRun(NSString *reason) {
    if (![NSThread isMainThread]) {
        NSString *copied = [reason copy];
        dispatch_async(dispatch_get_main_queue(), ^{
            AdKillRun(copied);
        });
        return;
    }

    if (gAdKillRunning) {
        reconLogF(@"[KILL] 上一轮还在跑，忽略这次（%@）", reason ?: @"?");
        return;
    }
    gAdKillRunning = YES;

    reconBanner([NSString stringWithFormat:@"秒过广告（%@）", reason ?: @"手动"]);
    reconLogF(@"[KILL] 执行前：%@", adSnapshotState());

    if (!adAdPresent() && adCount(@"CountdownButton") == 0) {
        reconLogF(@"[KILL] 屏上没找到任何广告视图，这次不执行");
        gAdKillRunning = NO;
        return;
    }

    NSArray<NSString *> *steps = @[@"countdown-zero", @"video-seek-end", @"reward-finish",
                                   @"rewardvideo-end", @"openscreen-timeover", @"openscreen-exit"];
    double delay = 0.0;
    for (NSString *step in steps) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            adPerformStep(step);
        });
        delay += 0.6;
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((delay + 0.6) * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        reconLogF(@"[KILL] 执行后：%@", adSnapshotState());
        reconBanner(adAdPresent() ? @"秒过失败：广告还在" : @"秒过完成：广告已消失");
        gAdKillRunning = NO;
    });
}

NSString *AdKillSummary(void) {
    return adSnapshotState();
}

BOOL AdAutoKillEnabled(void) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:@"ad_auto_kill"];
}

void AdSetAutoKill(BOOL enabled) {
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:@"ad_auto_kill"];
    if (enabled) {
        gAutoKillCount = 0;
    }
    reconLogF(@"[KILL] 自动秒过 %@", enabled ? @"已开启" : @"已关闭");
}

/* 每秒巡检一次；只认三个明确的广告类，避免误杀支付页倒计时 */
static void adAutoKillTick(void) {
    if (!AdAutoKillEnabled() || gAdKillRunning) {
        return;
    }
    if (gAutoKillCount >= 5) {
        return;
    }
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    if (now - gLastAutoKill < 3.0) {
        return;
    }
    if (!adAdPresent()) {
        return;
    }
    gLastAutoKill = now;
    gAutoKillCount += 1;
    AdKillRun([NSString stringWithFormat:@"自动第 %d 次", gAutoKillCount]);
}

#pragma mark - Setup

static void setup() {
    dispatch_async(dispatch_get_main_queue(), ^{
        // 1. Scene Hook
        Class targetClass = objc_getClass("FBSWorkspaceScenesClient");
        SEL originalSelector = @selector(sceneID:updateWithSettingsDiff:transitionContext:completion:);
        Method originalMethod = class_getInstanceMethod(targetClass, originalSelector);

        if (originalMethod) {
            original_sceneID_updateWithSettingsDiff_transitionContext_completion = (void (*)(id, SEL, id, id, id, id))method_getImplementation(originalMethod);
            method_setImplementation(originalMethod, (IMP)new_sceneID_updateWithSettingsDiff_transitionContext_completion);
        }

        // 2. Application State Hook
        Class uiAppClass = objc_getClass("UIApplication");
        Method appStateMethod = class_getInstanceMethod(uiAppClass, @selector(applicationState));
        if (appStateMethod) {
            orig_applicationState = (void *)method_getImplementation(appStateMethod);
            method_setImplementation(appStateMethod, (IMP)hook_applicationState);
        }

        // 3. Notification Delegate Hook
        Class unCenterClass = objc_getClass("UNUserNotificationCenter");
        Method setDelegateMethod = class_getInstanceMethod(unCenterClass, @selector(setDelegate:));
        if (setDelegateMethod) {
            orig_setDelegate = (void *)method_getImplementation(setDelegateMethod);
            method_setImplementation(setDelegateMethod, (IMP)hook_setDelegate);
        }

        // 4. 监听保活开关
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, (CFNotificationCallback)prefsChanged, CFSTR("com.sergy.immortalizerjailed.updateprefs"), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);

        // 5. 侦察 hook
        reconInstallHooks();

        // 6. 每 5 秒自动落盘一次，防止崩溃丢日志
        gInternalTimerGuard = YES;
        [NSTimer scheduledTimerWithTimeInterval:5.0 repeats:YES block:^(NSTimer *timer) {
            (void)timer;
            reconAutoFlush();
        }];

        // 6.5 自动秒过巡检（1 秒一次；自动开关关着时只是一次 bool 判断，开销可忽略）
        [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *timer) {
            (void)timer;
            adAutoKillTick();
        }];
        gInternalTimerGuard = NO;

        // 7. 进后台时立刻落盘
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidEnterBackgroundNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *note) {
            (void)note;
            gDirty = YES;
            reconAutoFlush();
        }];

        [[FloatingButtonWindow sharedInstance] showButton];
    });

    // 8. 静态扫描放到后台，不拖慢启动
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
        @try {
            reconScanImages();
            reconScanClasses();
            reconBanner(@"静态扫描完成，等待广告出现");
            reconLogF(@"[INIT] 提示：现在去点开那个 15 秒广告，广告出现时按「抓界面」");
        } @catch (NSException *e) {
            reconLogF(@"[INIT] 静态扫描异常：%@", e.reason ?: @"?");
        }
    });

    // 9. WebKit / AVFoundation 补挂
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        reconInstallHooks();
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        reconInstallHooks();
        reconLogF(@"[INIT] 10 秒补挂完成 · 网页=%d 视频=%d",
                  orig_loadRequest != NULL, orig_avPlay != NULL);
    });
}

__attribute__((constructor)) static void initialize() {
    reconInitOnce();
    prefsChanged();
    reconCollectEnv();
    setup();
}
