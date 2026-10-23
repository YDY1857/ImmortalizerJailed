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
    ===== 修改说明 v17（2026-10-22）v16 的 hook 根本没装上 =====

    【v16 真机结果：进程活了，但拦截 0 次】
    - [ALIVE] 心跳 31.20s / 89.85s 都在 → 后台 65 秒进程没被挂起，音频保活成功了。
    - 但 [BG] ★ 拦截 一条都没有，倒计时照旧不动。

    【根因：hook 装晚了，宏静默跳过】
    报告里启动扫描到 714 个广告相关类，其中**没有** CubeViewNGImpl / CubeView /
    BeeVideoPlayerView / CKPView —— 这些类要等小程序框架加载（约第 9.8 秒）才存在。
    而 hook 是在第 3 秒装的，objc_getClass 返回 NULL，RECON_HOOK_I 直接跳过，
    还不打日志。所以 v16 那几个"真正入口"从来没被挂上，零拦截不是"没触发"。

    【v17 三件事】
    1. 延迟补挂：每 2 秒重试一次（最多 5 分钟），装上一个写一行
       [HOOK] ★ 已挂 类名 -方法名，报告开头就能核对到底挂上没挂上。
       方法不存在会写 [HOOK] ✗，不再静默。
    2. 暂停入口补全到四层：
         Nebula 组件层  NBComponentManager / NBComponentManagerV2 -componentPause
         小程序层      TinyAppConfigImpl -onPauseTinyApp:
         渲染层        CubeViewNGImpl -onPause / CubeView -onPause
         播放器层      BeeVideoPlayerView -audioSessionPause
       componentDidRecivePauseOrResume:scene: 只观察不拦（成对调用，乱吞会状态错乱）。
    3. 两个探针：
         [TICK]  每 5 秒报 Nebula 定时泵（NBComponentTimerProxy -handleTimer:，
                 0.07 秒一次）在后台的活动量。还在涨=JS 泵没停，卡的是渲染；
                 不涨=泵被停了，继续往上层找。
         [INVAL] 定时器被谁失效了（只记 TimerProxy/CKTimer/Render/Cube/NB 类 target）。

    【证据】v16 报告第 9.84 秒有一条 0.07s repeats=1 NBComponentTimerProxy -handleTimer:，
    第 90.33 秒（回前台）又新建了一条同名定时器 —— 说明后台期间它被停过又重建。

*/

/*
    ===== 修改说明 v16（2026-10-22）v15 猜错了对象 =====

    【v15 真机结果】
    报告里只有一行 [BG]：允许后台播放 1/1。
    三条 ★ 拦截（RNGPreloadInstance handleEnterBackground: 等）**一条都没出现**
    —— 说明小游戏进后台根本不走那几个方法，我猜错了。
    而且日志在 28 秒就断了，进程一进后台就被挂起：音频保活压根没开起来。

    【v16 两个修正】
    1. 换真正的暂停入口。把二进制里所有"进后台就暂停"的方法按广告/小游戏域筛了一遍，
       视图树里真实存在的 CubeViewNGImpl -onPause 才是小游戏的暂停开关。新增拦截：
           CubeViewNGImpl -onPause
           CubeView       -onPause
           BeeVideoPlayerView -audioSessionPause / -audioSessionPauseFromNotification
           BeeAudioSessionManager4Video -systemRequestResignActive:
       v15 那三个保留，多拦一层不亏。

    2. 音频保活改成直接调用，不再只靠 Darwin 通知。
       main.m 里用 category 声明了浮窗的 -forceEnableKeepAlive 后直接调，
       通知丢了也不影响；打开结果会写进报告（audioOK=1 / 失败原因）。

    【v16 新增的诊断，回答"到底是不是被挂起了"】
    - [LIFE] 四条生命周期通知全记（WillResignActive / DidEnterBackground /
      WillEnterForeground / DidBecomeActive）
    - [ALIVE] 每 30 秒一条心跳。进后台之后如果还能看到心跳，说明进程活着；
      看不到，就是被系统挂起了 —— 这比任何猜测都准。

    ===== 以下是 v15 的说明，保留备查 =====
*/

/*
    ===== 修改说明 v15（2026-10-22）换回你真正想要的那条路 =====

    【v14 探针结果】
      · [H5·自检] 三个 WebView 全部返回 speed=0
        → 文档期注入那条路对这几个页面不生效，H5 加速打不进去
      · [PROBE] 广告条整条都是原生 Cube 组件：
        CKPView<CKPView<CKPView<CubeViewNGImpl<AntCubeView<RNGOverlayContainerView
        且 text 为空 —— 倒计时不是 UILabel 画的，也不在 H5 的 DOM 里
      · 全程没有 1 秒重复定时器
    合起来：15 秒倒计时既不在 WKWebView 的 window 上，也不是 NSTimer，
    而是小游戏容器（AntCube / RNG）里的原生逻辑。

    【v15 换路：不做"秒过"，做"后台继续跑"】
    从二进制里翻到一个关键方法：
        RNGPreloadInstance  -handleEnterBackground:
        ALTCubeEventHandler -onContainerPause
        ALTCubeEventHandler -onContainerViewDidDisappear
    这三个就是小游戏页面"一进后台就把自己暂停"的入口。
    把它们拦掉，页面根本不知道进了后台，倒计时继续走 —— 这正是用户最初要的效果，
    而且比吞 scene 事件（v5/v6/v8 崩了三次）安全得多，因为它不改变系统状态。

    另外 BeeVideoPlayerView 上有原厂的 -setEnableBackgroudPlay:（拼写就是 Backgroud），
    一并打开，视频在后台不会被主动停。

    配套：检测到播放器就自动把音频保活打开（发 Darwin 通知给浮窗），
    否则进程被挂起，上面这些全白搭。

    【面板变化】
    第一行：导出TXT / 复制全文 / 抓界面 / 后台:开|关   ← 新增
    第二行：秒过广告 / 自动:开|关 / JS加速:开|关
    秒过链保留，多了一步 bg-prime（先让播放器允许后台播放）。

    ===== 以下是 v14 的说明，保留备查 =====
*/

/*
    ===== 修改说明 v14（2026-10-21）加探针，不再瞎猜 =====

    【v13 报告的结果：注入成功，但打不中】
    `★ H5 加速脚本已挂上` 出现 4 次（10.06s / 18.32s，都在页面 load 之前），
    说明搭便车注入这条路是通的。但广告照样没结束。

    报告里另两个硬事实：
      · 整段时间没有 1 秒的重复定时器，只有稀疏的 one-shot（CKTimerTarget 1s，约 10 秒一次）
      · 一条 [LBL] 都没抓到「浏览广告14秒」，连 setAttributedText 也没有
    结论：那行倒计时文字既不是 UILabel，也不是 NSTimer 驱动。
    它跑在小游戏自己的 JS 引擎里（不是 WKWebView 的 window），
    所以我们改 window.setInterval / Date.now 根本碰不到。

    【v14 只做侦察，不再乱打】
    ① 界面树带文字：reconDumpView 现在会把每个节点的 text / attributedText 一起打出来，
       下次报告里能直接看到「浏览广告14秒」画在哪个类上。
    ② 探针 [PROBE]：在广告条那一带（顶部 y=46/62/80/120）做 hitTest，
       打出命中视图的完整类名链；如果文字里带 秒/广告/奖励/跳过，
       顺手把那个类以及它父类的实例方法全表打出来（[CLASS] 行）。
    ③ H5 自检 [H5·自检#n]：evaluateJavaScript 读回 window.__adSpeedOn，
       返回 speed=1 才说明加速脚本真的在页面里跑了；返回 0 说明注入白挂了。
       这一条能一次性判定"H5 路线到底可不可行"。

    拿到这三份数据，下一版就能照着方法名精准调用，不用再一轮一轮试。

    ===== 以下是 v13 的说明，保留备查 =====
*/

/*
    ===== 修改说明 v13（2026-10-21）=====

    【v12 真机报告暴露的两个事实】
    1. 视频快进成功了（4.0s → 108.9s，说明这段视频总长 108.9 秒），但广告没结束。
       用户截图确认：左上角那行「广告 ∨ ｜ 浏览广告14秒得奖励 ｜ 关闭」就是计时条，
       "广告结束"只看这 15 秒走没走完，跟视频播到哪一帧没关系。
       （截图里显示"14秒"是因为已经走过去 1 秒，广告总时长是 15 秒。）
    2. 「H5 加速脚本已挂上」这条日志一次都没出现 —— 注入根本没执行。
       v12 走的是 hook -[WKWebView initWithFrame:configuration:]，那条路没触发。

    【v13 改法：搭支付宝自己的便车】
    支付宝每开一个 WebView，都会往同一个 WKUserContentController 上加七八个文档期脚本
    （日志里那些 [WEB] addUserScript 就是）。我们就在 hook addUserScript 里，
    趁同一个时机往同一个 controller 上挂自己的加速脚本 —— 这条路必然经过，不会再漏。

    【加速范围收窄】
    v12 把所有 setInterval/setTimeout 一律 ÷8，会把游戏页的网络重试、轮询一起加速，
    有风控和卡顿风险。v13 只动两类：
        900~1100ms（典型倒计时）
        90~110ms（平滑倒计时）
    其它间隔原样不动。Date.now 仍 8 倍（应对"用时间戳算剩余秒数"的实现），
    120 秒后全部自动还原。

    【顺手补的观测点】
    - 启动时写一行「H5 加速状态：开/关」，避免再出现不知道当时开没开的情况
    - 白名单页面加载时给 URL 打 ★
    - 新增 hook setAttributedText:（那行倒计时文字可能是富文本，setText 抓不到）
    - 快照类名加 AdTagView / AdMessageView / AdCubeCardView / BeeVideoCountdownPlugin
    - 秒过结束的横幅改成实话：视频层消失 ≠ 广告结束

    ===== 以下是 v11 的说明，保留备查 =====
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
#import <notify.h>
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

/* 浮窗里实现、但没写进 .h 的方法，这里声明一下好直接调（比靠 Darwin 通知可靠） */
@interface FloatingButtonWindow (AdBgKeep)
- (void)forceEnableKeepAlive;
@end

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

/* 广告 / 小游戏页面的域名白名单：只有这里的页面才会被 H5 加速 */
static BOOL adURLIsAdOrGame(NSString *url) {
    if (url.length == 0) {
        return NO;
    }
    static NSArray<NSString *> *tokens = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        tokens = @[@"paladin:", @"antgame", @"yuyan", @"prizeMachine",
                   @"antfarm", @"gameTaskSuspend", @"ad_mgr"];
    });
    for (NSString *token in tokens) {
        if ([url rangeOfString:token options:NSCaseInsensitiveSearch].location != NSNotFound) {
            return YES;
        }
    }
    return NO;
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
        [gEnvLines addObject:@"扫描器        : AdRecon v18（播放器看门狗版）"];
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

    /* v14：把节点上的文字也带出来，才能定位"浏览广告14秒"到底画在哪个类上 */
    NSString *textPart = @"";
    @try {
        SEL textSel = sel_getUid("text");
        if ([view respondsToSelector:textSel]) {
            id value = ((id (*)(id, SEL))objc_msgSend)(view, textSel);
            if ([value isKindOfClass:[NSString class]] && ((NSString *)value).length > 0) {
                textPart = [NSString stringWithFormat:@" 「%@」", reconTrim((NSString *)value, 30)];
            }
        }
        if (textPart.length == 0) {
            SEL attrSel = sel_getUid("attributedText");
            if ([view respondsToSelector:attrSel]) {
                id value = ((id (*)(id, SEL))objc_msgSend)(view, attrSel);
                if ([value respondsToSelector:@selector(string)]) {
                    NSString *s = ((NSString * (*)(id, SEL))objc_msgSend)(value, sel_getUid("string"));
                    if ([s isKindOfClass:[NSString class]] && s.length > 0) {
                        textPart = [NSString stringWithFormat:@" 「%@」", reconTrim(s, 30)];
                    }
                }
            }
        }
    } @catch (NSException *e) {
        (void)e;
    }

    CGRect frame = view.frame;
    [out appendFormat:@"%@%@ (%.0f,%.0f %.0fx%.0f)%@%@%@\n",
     indent,
     NSStringFromClass([view class]),
     frame.origin.x, frame.origin.y, frame.size.width, frame.size.height,
     view.hidden ? @" [hidden]" : @"",
     view.alpha < 0.05 ? @" [alpha≈0]" : @"",
     textPart];

    for (UIView *sub in view.subviews) {
        reconDumpView(sub, depth + 1, out, budget);
    }
}

/* v14：把某个类的实例方法名全列出来，下一版好照着方法名精准调用 */
static void reconDumpClassMethods(Class cls, NSString *why) {
    if (cls == Nil) {
        return;
    }
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    if (methods == NULL) {
        return;
    }
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (unsigned int i = 0; i < count && names.count < 90; i++) {
        NSString *name = NSStringFromSelector(method_getName(methods[i]));
        if (name.length > 0) {
            [names addObject:name];
        }
    }
    free(methods);
    reconLogF(@"[CLASS] %@ 共 %u 个方法（%lu 个已列）· 来源：%@",
              NSStringFromClass(cls), count, (unsigned long)names.count, why ?: @"?");
    reconLogF(@"[CLASS] %@ → %@", NSStringFromClass(cls),
              [names componentsJoinedByString:@", "]);
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
        /* 过滤掉插件自己面板上的文字，不然日志全是自己的噪声 */
        UIView *hostWindow = [self window];
        if (hostWindow != nil &&
            [NSStringFromClass([hostWindow class]) containsString:@"FloatingButton"]) {
            return;
        }

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

#pragma mark - Hook：UILabel 富文本（有些倒计时走 attributedText，setText 抓不到）

static void (*orig_setAttributedText)(id, SEL, id);
static void hook_setAttributedText(id self, SEL _cmd, id attributedText) {
    if (orig_setAttributedText) {
        orig_setAttributedText(self, _cmd, attributedText);
    }
    @try {
        UIView *hostWindow = [self window];
        if (hostWindow != nil &&
            [NSStringFromClass([hostWindow class]) containsString:@"FloatingButton"]) {
            return;
        }
        if (![attributedText respondsToSelector:@selector(string)]) {
            return;
        }
        NSString *str = [attributedText string];
        if (![str isKindOfClass:[NSString class]] || str.length == 0 || str.length > 60) {
            return;
        }
        if ([str rangeOfString:@"秒"].location == NSNotFound &&
            [str rangeOfString:@"广告"].location == NSNotFound &&
            [str rangeOfString:@"奖励"].location == NSNotFound) {
            return;
        }
        NSString *key = [NSString stringWithFormat:@"atxt:%@:%@", NSStringFromClass([self class]), str];
        if (reconAllow(key, 1.0)) {
            reconLogF(@"[LBL·富文本] %@ →「%@」", NSStringFromClass([self class]), str);
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
        reconLogF(@"[WEB] loadRequest %@%@",
                  adURLIsAdOrGame(urlString) ? @"★ 广告/游戏页（H5 加速应在文档期生效） " : @"",
                  reconTrim(urlString, 300));
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

/* 定义在广告秒过模块里 */
static void adPiggybackSpeedScript(id controller);

/* 定义在广告秒过模块里：后台续跑开关 */
BOOL AdBgKeepEnabled(void);
void AdPrimeBackgroundPlayback(void);
void AdSetBgKeep(BOOL enabled);

/* 定义在广告秒过模块里：给浮窗用的日志出口 */
void AdLog(NSString *message);

/*
    v16：v15 那三个方法一次都没被调用（报告里零 [BG] ★ 拦截），
    从二进制里重新翻了所有"进后台就暂停"的入口，真正被走的是下面这批：
        CubeViewNGImpl      -onPause          ← 小游戏渲染根视图，视图树里就有它
        CubeView            -onPause
        BeeVideoPlayerView  -audioSessionPause / -audioSessionPauseFromNotification
        BeeAudioSessionManager4Video -systemRequestResignActive:
    CubeViewNGImpl 才是小游戏真正的暂停开关，v15 猜错了对象。
*/
static void (*orig_cubeNGPause)(id, SEL);
static void hook_cubeNGPause(id self, SEL _cmd) {
    if (AdBgKeepEnabled()) {
        reconLogF(@"[BG] ★ 拦截 CubeViewNGImpl -onPause（小游戏不暂停）");
        return;
    }
    if (orig_cubeNGPause) {
        orig_cubeNGPause(self, _cmd);
    }
}

static void (*orig_cubeViewPause)(id, SEL);
static void hook_cubeViewPause(id self, SEL _cmd) {
    if (AdBgKeepEnabled()) {
        reconLogF(@"[BG] ★ 拦截 %@ -onPause", NSStringFromClass([self class]));
        return;
    }
    if (orig_cubeViewPause) {
        orig_cubeViewPause(self, _cmd);
    }
}

static void (*orig_beeAudioPause)(id, SEL);
static void hook_beeAudioPause(id self, SEL _cmd) {
    if (AdBgKeepEnabled()) {
        reconLogF(@"[BG] ★ 拦截 BeeVideoPlayerView -audioSessionPause");
        return;
    }
    if (orig_beeAudioPause) {
        orig_beeAudioPause(self, _cmd);
    }
}

static void (*orig_beeAudioPauseNote)(id, SEL);
static void hook_beeAudioPauseNote(id self, SEL _cmd) {
    if (AdBgKeepEnabled()) {
        reconLogF(@"[BG] ★ 拦截 BeeVideoPlayerView -audioSessionPauseFromNotification");
        return;
    }
    if (orig_beeAudioPauseNote) {
        orig_beeAudioPauseNote(self, _cmd);
    }
}

static void (*orig_beeSysResign)(id, SEL, id);
static void hook_beeSysResign(id self, SEL _cmd, id arg) {
    if (AdBgKeepEnabled()) {
        reconLogF(@"[BG] ★ 拦截 %@ -systemRequestResignActive:", NSStringFromClass([self class]));
        return;
    }
    if (orig_beeSysResign) {
        orig_beeSysResign(self, _cmd, arg);
    }
}

/*
    v18：v17 拦截成功了、JS 泵也在跑，倒计时还是不动
    → 说明它跟着"播放进度"走。视频进后台被暂停，计时自然停。
    所以这一版直接盯住播放器：
      -pause / -innerPause 只在后台期间拦掉（前台用户自己点暂停不受影响）
      -checkAppState 只记录，看它是不是在查应用状态
*/
static BOOL gAppInBackground = NO;
static void (*orig_beePause)(id, SEL);
static void hook_beePause(id self, SEL _cmd) {
    if (gAppInBackground && AdBgKeepEnabled()) {
        reconLogF(@"[BG] ★ 拦截 BeeVideoPlayerView -pause（后台不让停）");
        return;
    }
    if (orig_beePause) {
        orig_beePause(self, _cmd);
    }
}

static void (*orig_beeInnerPause)(id, SEL);
static void hook_beeInnerPause(id self, SEL _cmd) {
    if (gAppInBackground && AdBgKeepEnabled()) {
        reconLogF(@"[BG] ★ 拦截 BeeVideoPlayerView -innerPause（后台不让停）");
        return;
    }
    if (orig_beeInnerPause) {
        orig_beeInnerPause(self, _cmd);
    }
}

static void (*orig_beeCheckAppState)(id, SEL);
static void hook_beeCheckAppState(id self, SEL _cmd) {
    @try {
        if (reconAllow(@"vid:checkAppState", 5.0)) {
            reconLogF(@"[VID] BeeVideoPlayerView -checkAppState（播放器在查应用状态）");
        }
    } @catch (NSException *e) {
        (void)e;
    }
    if (orig_beeCheckAppState) {
        orig_beeCheckAppState(self, _cmd);
    }
}

/*
    v15：小游戏/小程序页面在进后台时会被这几个方法主动暂停。
    把入口拦掉，页面自己就不知道进了后台，倒计时继续走。
    配合音频保活（进程不被挂起）就是用户最初要的效果。
*/
static void (*orig_rngEnterBackground)(id, SEL, id);
static void hook_rngEnterBackground(id self, SEL _cmd, id arg) {
    if (AdBgKeepEnabled()) {
        reconLogF(@"[BG] ★ 拦截 RNGPreloadInstance -handleEnterBackground:（页面不会暂停）");
        return;
    }
    if (orig_rngEnterBackground) {
        orig_rngEnterBackground(self, _cmd, arg);
    }
}

/*
    v17 关键修正：v16 那批 hook 其实一次都没装上。
    启动第 3 秒时 CubeViewNGImpl / BeeVideoPlayerView 这些类还没被 dyld 加载，
    objc_getClass 返回 NULL，RECON_HOOK_I 静默跳过 —— 报告里零拦截不是"没触发"，是"压根没挂上"。
    所以 v17 改成延迟补挂（每 2 秒重试一次，装上一个记一行），并把暂停入口补全到四层：
        Nebula 组件层   NBComponentManager / NBComponentManagerV2 -componentPause
        小程序层        TinyAppConfigImpl -onPauseTinyApp:
        渲染层          CubeViewNGImpl -onPause / CubeView -onPause
        播放器层        BeeVideoPlayerView -audioSessionPause
*/
static void (*orig_nbMgrPause)(id, SEL);
static void hook_nbMgrPause(id self, SEL _cmd) {
    if (AdBgKeepEnabled()) {
        reconLogF(@"[BG] ★ 拦截 %@ -componentPause（Nebula 组件不暂停）", NSStringFromClass([self class]));
        return;
    }
    if (orig_nbMgrPause) {
        orig_nbMgrPause(self, _cmd);
    }
}

static void (*orig_nbMgrPauseV2)(id, SEL);
static void hook_nbMgrPauseV2(id self, SEL _cmd) {
    if (AdBgKeepEnabled()) {
        reconLogF(@"[BG] ★ 拦截 NBComponentManagerV2 -componentPause");
        return;
    }
    if (orig_nbMgrPauseV2) {
        orig_nbMgrPauseV2(self, _cmd);
    }
}

/* 只观察不拦截：这个方法是暂停/恢复成对的，乱吞会让状态错乱。
   先把参数打出来，看清到底是谁、因为什么被暂停。 */
static NSUInteger gNbPauseSeen = 0;
static void (*orig_nbPauseOrResume)(id, SEL, id, id);
static void hook_nbPauseOrResume(id self, SEL _cmd, id arg1, id arg2) {
    @try {
        if (gNbPauseSeen < 24) {
            gNbPauseSeen++;
            reconLogF(@"[BG·观察] componentDidRecivePauseOrResume: %@ scene=%@",
                      arg1, arg2);
        }
    } @catch (NSException *e) {
        (void)e;
    }
    if (orig_nbPauseOrResume) {
        orig_nbPauseOrResume(self, _cmd, arg1, arg2);
    }
}

static void (*orig_tinyPause)(id, SEL, id);
static void hook_tinyPause(id self, SEL _cmd, id arg) {
    if (AdBgKeepEnabled()) {
        reconLogF(@"[BG] ★ 拦截 TinyAppConfigImpl -onPauseTinyApp:（小程序不暂停）");
        return;
    }
    if (orig_tinyPause) {
        orig_tinyPause(self, _cmd, arg);
    }
}

/*
    v17：Paladin（小游戏容器）层的隐藏开关。
    PLDContainer / PLDJITContainer -onHide 就是"告诉 JS 我进后台了"，
    JS 收到之后才开始停倒计时。拦掉它，JS 根本不知道你切走了。
    isAppShow 强制为 YES，让容器自己认为仍在前台。
*/
static void (*orig_pldHide)(id, SEL);
static void hook_pldHide(id self, SEL _cmd) {
    if (AdBgKeepEnabled()) {
        reconLogF(@"[BG] ★ 拦截 %@ -onHide（Paladin 容器不隐藏）", NSStringFromClass([self class]));
        return;
    }
    if (orig_pldHide) {
        orig_pldHide(self, _cmd);
    }
}

static void (*orig_pldJitHide)(id, SEL);
static void hook_pldJitHide(id self, SEL _cmd) {
    if (AdBgKeepEnabled()) {
        reconLogF(@"[BG] ★ 拦截 PLDJITContainer -onHide");
        return;
    }
    if (orig_pldJitHide) {
        orig_pldJitHide(self, _cmd);
    }
}

static BOOL (*orig_pldIsAppShow)(id, SEL);
static BOOL hook_pldIsAppShow(id self, SEL _cmd) {
    if (AdBgKeepEnabled()) {
        return YES;
    }
    return orig_pldIsAppShow ? orig_pldIsAppShow(self, _cmd) : YES;
}

/* 只观察：暂停音频不影响倒计时，但记下来能看出容器还做了哪些动作 */
static void (*orig_pldPauseAudio)(id, SEL);
static void hook_pldPauseAudio(id self, SEL _cmd) {
    @try {
        reconLogF(@"[BG·观察] %@ -pauseAudio", NSStringFromClass([self class]));
    } @catch (NSException *e) {
        (void)e;
    }
    if (orig_pldPauseAudio) {
        orig_pldPauseAudio(self, _cmd);
    }
}

/*
    探针一：[TICK] Nebula 定时泵计数。
    NBComponentTimerProxy -handleTimer: 是 Nebula 里所有 JS 定时器的驱动源（每 0.07 秒一次）。
    后台期间它还在涨，说明 JS 泵没停，卡住的是渲染；不涨就是泵本身被停了。
*/
static volatile int gNbTickCount = 0;
static void (*orig_nbTimerHandle)(id, SEL, id);
static void hook_nbTimerHandle(id self, SEL _cmd, id timer) {
    gNbTickCount++;
    if (orig_nbTimerHandle) {
        orig_nbTimerHandle(self, _cmd, timer);
    }
}

/* 当前是否在后台（由 [LIFE] 生命周期观察者维护），声明在本文件靠前处 */

/*
    探针二：[INVAL] 谁把定时器失效了。
    只记 target 名字里带 TimerProxy / CKTimer / Render / Cube / NB 的，避免刷屏。
    NSTimer 的真实实例是 __NSCFTimer（类簇），所以两个类都要挂。
*/
static void reconNoteTimerInvalidate(id timer) {
    /* invalidate 调用极频繁，只在后台期间才做检查，避免拖慢主线程 */
    if (!gAppInBackground) {
        return;
    }
    @try {
        id target = [timer valueForKey:@"target"];
        if (target != nil) {
            NSString *tc = NSStringFromClass([target class]);
            if ([tc containsString:@"TimerProxy"] || [tc containsString:@"CKTimer"] ||
                [tc containsString:@"Render"] || [tc containsString:@"Cube"] || [tc containsString:@"NB"]) {
                reconLogF(@"[INVAL] 定时器被失效 · target=%@", tc);
            }
        }
    } @catch (NSException *e) {
        (void)e;
    }
}

static void (*orig_timerInvalidate)(id, SEL);
static void hook_timerInvalidate(id self, SEL _cmd) {
    reconNoteTimerInvalidate(self);
    if (orig_timerInvalidate) {
        orig_timerInvalidate(self, _cmd);
    }
}

static void (*orig_timerInvalidate2)(id, SEL);
static void hook_timerInvalidate2(id self, SEL _cmd) {
    reconNoteTimerInvalidate(self);
    if (orig_timerInvalidate2) {
        orig_timerInvalidate2(self, _cmd);
    }
}

/* [TICK] 每 5 秒汇报一次 Nebula 定时泵的活动量 */
static int gNbTickLast = 0;
static void adTickReport(void) {
    int now = gNbTickCount;
    int delta = now - gNbTickLast;
    gNbTickLast = now;
    /* 注意：不能读 [UIApplication applicationState]，它被 v9 的 hook 强制成 Active 了，
       所以"是否在后台"只能看生命周期通知维护的 gAppInBackground */
    if (gAppInBackground) {
        reconLogF(@"[TICK] Nebula 定时泵：5 秒内 +%d 次（后台中，>0 说明 JS 泵还活着）", delta);
    } else if (delta == 0 && now > 0) {
        reconLogF(@"[TICK] Nebula 定时泵：5 秒内 0 次（前台也停了，异常）");
    }
}

static void (*orig_cubePause)(id, SEL);
static void hook_cubePause(id self, SEL _cmd) {
    if (AdBgKeepEnabled()) {
        reconLogF(@"[BG] ★ 拦截 %@ -onContainerPause（容器不暂停）", NSStringFromClass([self class]));
        return;
    }
    if (orig_cubePause) {
        orig_cubePause(self, _cmd);
    }
}

static void (*orig_cubeDisappear)(id, SEL);
static void hook_cubeDisappear(id self, SEL _cmd) {
    if (AdBgKeepEnabled()) {
        reconLogF(@"[BG] ★ 拦截 %@ -onContainerViewDidDisappear", NSStringFromClass([self class]));
        return;
    }
    if (orig_cubeDisappear) {
        orig_cubeDisappear(self, _cmd);
    }
}

static void (*orig_addUserScript)(id, SEL, id);
static void hook_addUserScript(id self, SEL _cmd, id script) {
    if (orig_addUserScript) {
        orig_addUserScript(self, _cmd, script);
    }
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

    /*
        v13 关键：搭支付宝自己的便车。
        支付宝每开一个 WebView 都会往同一个 controller 上加七八个文档期脚本，
        我们就借着这个时机往同一个 controller 上挂自己的加速脚本。
        这比 hook WKWebView 的初始化可靠得多 —— v12 走 init 那条路一次都没触发。
    */
    @try {
        adPiggybackSpeedScript(self);
    } @catch (NSException *e) {
        (void)e;
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

#pragma mark - 延迟补挂（v17 核心修正）

static NSMutableSet<NSString *> *gDeferredDone = nil;
static NSMutableSet<NSString *> *gDeferredFailed = nil;
static int gDeferredRounds = 0;
static BOOL gDeferredAllLogged = NO;

/* 装一个：类没加载就安静等下一轮，方法不存在才记一行，装上就记一行 */
static void reconTryHookOnce(NSString *clsName, NSString *selStr, IMP hookIMP, void **slot) {
    if (gDeferredDone == nil) {
        gDeferredDone = [NSMutableSet set];
    }
    NSString *key = [NSString stringWithFormat:@"%@|%@", clsName, selStr];
    if ([gDeferredDone containsObject:key]) {
        return;
    }

    Class cls = objc_getClass(clsName.UTF8String);
    if (cls == NULL) {
        return;
    }

    Method m = class_getInstanceMethod(cls, sel_getUid(selStr.UTF8String));
    if (m == NULL) {
        if (gDeferredFailed == nil) {
            gDeferredFailed = [NSMutableSet set];
        }
        if (![gDeferredFailed containsObject:key]) {
            [gDeferredFailed addObject:key];
            reconLogF(@"[HOOK] ✗ %@ 里没有 -%@", clsName, selStr);
        }
        return;
    }

    if (*slot == NULL) {
        *slot = (void *)method_getImplementation(m);
        method_setImplementation(m, hookIMP);
    }
    [gDeferredDone addObject:key];
    reconLogF(@"[HOOK] ★ 已挂 %@ -%@", clsName, selStr);
}

static void reconInstallDeferredHooks(void) {
    gDeferredRounds++;

    /* Nebula 组件层：小程序里所有组件的暂停总开关 */
    reconTryHookOnce(@"NBComponentManager", @"componentPause", (IMP)hook_nbMgrPause, (void **)&orig_nbMgrPause);
    reconTryHookOnce(@"NBComponentManagerV2", @"componentPause", (IMP)hook_nbMgrPauseV2, (void **)&orig_nbMgrPauseV2);
    reconTryHookOnce(@"NBComponentManager", @"componentDidRecivePauseOrResume:scene:", (IMP)hook_nbPauseOrResume, (void **)&orig_nbPauseOrResume);

    /* 小程序层 */
    reconTryHookOnce(@"TinyAppConfigImpl", @"onPauseTinyApp:", (IMP)hook_tinyPause, (void **)&orig_tinyPause);

    /* Paladin 小游戏容器层：告诉 JS "进后台了" 的就是这里 */
    reconTryHookOnce(@"PLDContainer", @"onHide", (IMP)hook_pldHide, (void **)&orig_pldHide);
    reconTryHookOnce(@"PLDJITContainer", @"onHide", (IMP)hook_pldJitHide, (void **)&orig_pldJitHide);
    reconTryHookOnce(@"PLDContainer", @"isAppShow", (IMP)hook_pldIsAppShow, (void **)&orig_pldIsAppShow);
    reconTryHookOnce(@"PLDContainer", @"pauseAudio", (IMP)hook_pldPauseAudio, (void **)&orig_pldPauseAudio);

    /* 渲染层 */
    reconTryHookOnce(@"CubeViewNGImpl", @"onPause", (IMP)hook_cubeNGPause, (void **)&orig_cubeNGPause);
    reconTryHookOnce(@"CubeView", @"onPause", (IMP)hook_cubeViewPause, (void **)&orig_cubeViewPause);
    reconTryHookOnce(@"RNGPreloadInstance", @"handleEnterBackground:", (IMP)hook_rngEnterBackground, (void **)&orig_rngEnterBackground);
    reconTryHookOnce(@"ALTCubeEventHandler", @"onContainerPause", (IMP)hook_cubePause, (void **)&orig_cubePause);
    reconTryHookOnce(@"ALTCubeEventHandler", @"onContainerViewDidDisappear", (IMP)hook_cubeDisappear, (void **)&orig_cubeDisappear);

    /* 播放器层 */
    reconTryHookOnce(@"BeeVideoPlayerView", @"audioSessionPause", (IMP)hook_beeAudioPause, (void **)&orig_beeAudioPause);
    reconTryHookOnce(@"BeeVideoPlayerView", @"audioSessionPauseFromNotification", (IMP)hook_beeAudioPauseNote, (void **)&orig_beeAudioPauseNote);
    reconTryHookOnce(@"BeeAudioSessionManager4Video", @"systemRequestResignActive:", (IMP)hook_beeSysResign, (void **)&orig_beeSysResign);
    reconTryHookOnce(@"BeeVideoPlayerView", @"pause", (IMP)hook_beePause, (void **)&orig_beePause);
    reconTryHookOnce(@"BeeVideoPlayerView", @"innerPause", (IMP)hook_beeInnerPause, (void **)&orig_beeInnerPause);
    reconTryHookOnce(@"BeeVideoPlayerView", @"checkAppState", (IMP)hook_beeCheckAppState, (void **)&orig_beeCheckAppState);

    /* 两个探针 */
    reconTryHookOnce(@"NBComponentTimerProxy", @"handleTimer:", (IMP)hook_nbTimerHandle, (void **)&orig_nbTimerHandle);
    reconTryHookOnce(@"NSTimer", @"invalidate", (IMP)hook_timerInvalidate, (void **)&orig_timerInvalidate);
    reconTryHookOnce(@"__NSCFTimer", @"invalidate", (IMP)hook_timerInvalidate2, (void **)&orig_timerInvalidate2);

    if (gDeferredRounds == 1) {
        reconLogF(@"[HOOK] 第 1 轮补挂：已装 %lu/22（没装上的等类加载后自动补）",
                  (unsigned long)gDeferredDone.count);
    } else if (!gDeferredAllLogged && gDeferredDone.count >= 22) {
        gDeferredAllLogged = YES;
        reconLogF(@"[HOOK] ★ 22 个补挂全部完成（第 %d 轮）", gDeferredRounds);
    }
}

#pragma mark - Hook 安装

/* 定义在下面的广告秒过模块里，这里先声明（否则顺序上找不到） */
static void adInstallSpeedHook(void);

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
        RECON_HOOK_I("UILabel", "setAttributedText:", hook_setAttributedText, orig_setAttributedText);

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

    /* 新建 WebView 时挂 H5 加速脚本（v12）。这个必须单独 try，挂失败不能影响别的 hook */
    @try {
        adInstallSpeedHook();
    } @catch (NSException *e) {
        reconLogF(@"[INIT] WebView 初始化 hook 异常：%@", e.reason ?: @"?");
    }

    /* 后台续跑相关的一律走延迟补挂（见 reconInstallDeferredHooks），
       因为 Cube / Nebula / Bee 这些类要等小程序框架加载后才存在 */
    reconInstallDeferredHooks();

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
    [out appendString:@"   支付宝广告 · 侦察 + 秒过报告（AdRecon v18）\n"];
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

    [out appendString:@"【六、能力清单（v18）】\n"];
    [out appendString:@"A. 后台续跑（默认开，面板第一行「后台:开」）\n"];
    [out appendString:@"   v17 修正：v16 的 hook 一次都没装上 —— 启动第 3 秒 Cube/Nebula/Bee 这些类\n"];
    [out appendString:@"   还没被 dyld 加载，objc_getClass 返回 NULL，宏静默跳过。\n"];
    [out appendString:@"   现在每 2 秒重试补挂，装上一个记一行 [HOOK] ★ 已挂，报告开头就能核对。\n"];
    [out appendString:@"   拦 NBComponentManager   -componentPause（Nebula 组件总开关）\n"];
    [out appendString:@"   拦 NBComponentManagerV2 -componentPause\n"];
    [out appendString:@"   拦 TinyAppConfigImpl    -onPauseTinyApp:（小程序层）\n"];
    [out appendString:@"   拦 PLDContainer / PLDJITContainer -onHide（Paladin 容器层）\n"];
    [out appendString:@"   拦 CubeViewNGImpl / CubeView -onPause（渲染层）\n"];
    [out appendString:@"   拦 BeeVideoPlayerView -audioSessionPause / -audioSessionPauseFromNotification\n"];
    [out appendString:@"   拦 BeeAudioSessionManager4Video -systemRequestResignActive:\n"];
    [out appendString:@"   拦 RNGPreloadInstance -handleEnterBackground:\n"];
    [out appendString:@"   只观察不拦：componentDidRecivePauseOrResume:scene:（暂停/恢复成对，乱吞会错乱）\n"];
    [out appendString:@"D. v18 新增：播放器看门狗（针对\"倒计时跟着播放进度走\"）\n"];
    [out appendString:@"   拦 BeeVideoPlayerView -pause / -innerPause（只在后台期间拦，前台手动暂停不受影响）\n"];
    [out appendString:@"   观察 -checkAppState（播放器在查应用状态就会被记下来）\n"];
    [out appendString:@"   [VID] 后台每秒看一次播放器：isPlaying 和当前播放位置。\n"];
    [out appendString:@"         位置在涨 = 视频还在播，倒计时却不走 → 计时与播放无关，另找；\n"];
    [out appendString:@"         位置不动 = 视频被暂停，这就是原因，看门狗会自动重新 play。\n"];
    [out appendString:@"B. 两个新探针\n"];
    [out appendString:@"   [TICK] 每 5 秒报一次 Nebula 定时泵活动量。后台还在涨=JS 泵没停（卡的是渲染）；\n"];
    [out appendString:@"          不涨=泵本身被停了，那就继续往上层找。\n"];
    [out appendString:@"   [INVAL] 谁把定时器失效了（只记 TimerProxy/CKTimer/Render/Cube/NB 这几类 target）。\n"];
    [out appendString:@"C. 秒过（面板第二行「秒过广告」，本次测试不用点）\n"];
    [out appendString:@"     AdOpenScreenView -exitAd / -exiAdWhenTimeOver   零参数\n"];
    [out appendString:@"     CountdownButton  -setRemainingTime:(double) + -updateCountdown\n"];
    [out appendString:@"     AdRewardView     -countDownFinish               零参数\n"];
    [out appendString:@"     AdRewardedVideoView -countDownEnd               零参数\n"];
    [out appendString:@"     BeeVideoPlayerView -seekToTime:(double) / -getCurrentTime\n\n"];

    [out appendString:@"【七、生成信息】\n"];
    [out appendFormat:@"生成时间: %@\n", [NSDate date]];
    [out appendFormat:@"插件版本: AdRecon v18\n"];
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
    NSString *fileName = [NSString stringWithFormat:@"AdRecon-v18-%@.txt", stamp];
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

/* 供浮窗调用：把浮窗那边的事件也写进同一份报告 */
void AdLog(NSString *message) {
    if (message.length == 0) {
        return;
    }
    reconAppend(message);
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

static BOOL adCallB(id target, NSString *selName, BOOL value) {
    if (target == nil) {
        return NO;
    }
    SEL sel = NSSelectorFromString(selName);
    if (![target respondsToSelector:sel]) {
        return NO;
    }
    ((void (*)(id, SEL, BOOL))objc_msgSend)(target, sel, value);
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

static BOOL adCallRetB(id target, NSString *selName) {
    if (target == nil) {
        return NO;
    }
    SEL sel = NSSelectorFromString(selName);
    if (![target respondsToSelector:sel]) {
        return NO;
    }
    return ((BOOL (*)(id, SEL))objc_msgSend)(target, sel);
}

/*
    v18 后台看门狗：每秒看一眼广告播放器。
    - 报 isPlaying 和当前播放位置 → 判断"倒计时是不是跟着播放进度走"
    - 后台里发现停了就重新 play
*/
static void adKeepVideoAlive(void) {
    if (!gAppInBackground || !AdBgKeepEnabled()) {
        return;
    }
    NSArray *players = adFindViews(@"BeeVideoPlayerView");
    if (players.count == 0) {
        if (reconAllow(@"vid:none", 10.0)) {
            reconLogF(@"[VID] 后台视图树里没找到 BeeVideoPlayerView");
        }
        return;
    }
    for (id player in players) {
        BOOL playing = adCallRetB(player, @"isPlaying");
        double now = adCallRetD(player, @"getCurrentTime");
        if (reconAllow(@"vid:alive", 5.0)) {
            reconLogF(@"[VID] 后台播放器 isPlaying=%d 当前=%.1fs", playing ? 1 : 0, now);
        }
        if (!playing) {
            BOOL ok = adCall(player, @"play");
            if (reconAllow(@"vid:replay", 5.0)) {
                reconLogF(@"[VID] 播放器在后台停住了，重新 play=%@", ok ? @"OK" : @"NO");
            }
        }
    }
}

static NSString *adSnapshotState(void) {
    static NSArray<NSString *> *names = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        names = @[@"AdOpenScreenView", @"AdRewardView", @"AdRewardedVideoView",
                  @"AdInterstitialView", @"CDPHugeAdView", @"AdBannerView",
                  @"AdTagView", @"AdMessageView", @"AdCubeCardView",
                  @"BeeVideoPlayerView", @"BeeVideoCountdownPlugin", @"CountdownButton"];
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

/*
    v12 修正：
    v11 把"自动模式"的严格判断用在了"手动秒过"的入口上，
    导致小游戏里只有 BeeVideoPlayerView 时手动点秒过直接被挡掉
    （真机日志：[KILL] 执行前：BeeVideoPlayerView×1 → 屏上没找到任何广告视图）。
    手动入口必须宽松：只要屏上有任何一种广告载体就执行。
*/
static BOOL adAnyAdViewPresent(void) {
    if (adAdPresent()) {
        return YES;
    }
    return adCount(@"BeeVideoPlayerView") > 0 ||
           adCount(@"CountdownButton") > 0 ||
           adCount(@"AdInterstitialView") > 0 ||
           adCount(@"CDPHugeAdView") > 0;
}

#pragma mark H5 加速（针对小游戏/活动页里自计时的广告）

/*
    为什么需要这一层：
    v11 真机日志显示，这次广告没有 AdRewardView，而是 prizeMachine/antfarm 页面
    自己用 Cube 视频组件播的。倒计时写在 H5 里，native 层完全碰不到。
    所以只能在 JS 层动手：把 setInterval/setTimeout 的间隔缩小 8 倍、把 Date.now 跑快 8 倍。

    两道保险：
      1. 文档开始注入（atDocumentStart）—— 页面自己的 setInterval 一创建就是加速版，
         这是唯一可靠的方式（页面已经创建好的 timer 没法改间隔）
      2. 秒过链最后一步用 evaluateJavaScript 对当前页面补刀（含把 <video> 拖到结尾）
    域名白名单：只在 paladin/antgame/yuyan/prizeMachine/antfarm/gameTaskSuspend/ad_mgr
    这些广告或游戏页生效，支付页面完全不碰。加速 120 秒后自动还原。
*/

static NSString *adSpeedDocumentJS(void) {
    return @"(function(){try{"
            @"var h=String(location.href||'');"
            @"if(!/(paladin:|antgame|yuyan|prizeMachine|antfarm|gameTaskSuspend|ad_mgr)/i.test(h)){return;}"
            @"if(window.__adSpeedOn){return;}window.__adSpeedOn=1;"
            @"var F=8;"
            @"var oSI=window.setInterval,oST=window.setTimeout,oNow=Date.now.bind(Date),t0=oNow();"
            @"function fast(d){"
            @"if(typeof d!=='number'||d<=0){return d;}"
            @"if(d>=900&&d<=1100){return Math.max(1,d/F);}"
            @"if(d>=90&&d<=110){return Math.max(1,d/F);}"
            @"return d;}"
            @"window.setInterval=function(f,d){return oSI.call(window,f,fast(d));};"
            @"window.setTimeout=function(f,d){return oST.call(window,f,fast(d));};"
            @"Date.now=function(){return t0+(oNow()-t0)*F;};"
            @"oST.call(window,function(){window.setInterval=oSI;window.setTimeout=oST;Date.now=oNow;window.__adSpeedOn=0;},120000);"
            @"}catch(e){}})();";
}

static NSString *adSpeedPageJS(void) {
    return @"(function(){try{"
            @"var F=8;"
            @"var oNow=Date.now.bind(Date),t0=oNow();"
            @"Date.now=function(){return t0+(oNow()-t0)*F;};"
            @"var vs=document.querySelectorAll('video,audio');"
            @"for(var i=0;i<vs.length;i++){try{var m=vs[i];"
            @"if(m.duration&&isFinite(m.duration)&&m.duration>0){m.currentTime=Math.max(0,m.duration-0.1);}"
            @"m.playbackRate=16;var p=m.play();if(p&&p.catch){p.catch(function(){});}"
            @"}catch(e){}}"
            @"return 'ok';"
            @"}catch(e){return 'err';}})();";
}

static NSInteger adRunJSOnAllWebViews(NSString *js) {
    Class wkCls = NSClassFromString(@"WKWebView");
    if (wkCls == NULL || js.length == 0) {
        return 0;
    }
    NSMutableArray *webViews = [NSMutableArray array];
    for (UIWindow *win in reconAllWindows()) {
        adCollectViews(win, wkCls, webViews, 0);
    }

    SEL evalSel = sel_getUid("evaluateJavaScript:completionHandler:");
    NSInteger hit = 0;
    for (id webView in webViews) {
        if (![webView respondsToSelector:evalSel]) {
            continue;
        }
        @try {
            ((void (*)(id, SEL, id, id))objc_msgSend)(webView, evalSel, js, nil);
            hit += 1;
        } @catch (NSException *e) {
            (void)e;
        }
    }
    return hit;
}

/* 给每个新建的 WKWebView 的配置挂上文档期脚本，只挂一次 */
static char kAdSpeedKeyStorage;
static const void *kAdSpeedInjectedKey = &kAdSpeedKeyStorage;

BOOL AdJSSpeedEnabled(void) {
    NSNumber *value = [[NSUserDefaults standardUserDefaults] objectForKey:@"ad_js_speed"];
    if (value == nil) {
        return YES;   /* 默认开启：这是唯一能碰到 H5 倒计时的手段 */
    }
    return value.boolValue;
}

void AdSetJSSpeed(BOOL enabled) {
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:@"ad_js_speed"];
    reconLogF(@"[KILL] H5 加速 %@（对之后新打开的页面生效）", enabled ? @"已开启" : @"已关闭");
}

/* 真正干活的：往某个 WKUserContentController 上挂一次加速脚本 */
static void adPiggybackSpeedScript(id controller) {
    if (controller == nil) {
        return;
    }
    if (!AdJSSpeedEnabled()) {
        if (reconAllow(@"h5skip", 60.0)) {
            reconLogF(@"[KILL] H5 加速处于关闭状态，本次不注入（面板第一行可开）");
        }
        return;
    }
    if (objc_getAssociatedObject(controller, kAdSpeedInjectedKey) != nil) {
        return;
    }
    objc_setAssociatedObject(controller, kAdSpeedInjectedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    @try {
        Class scriptCls = NSClassFromString(@"WKUserScript");
        if (scriptCls == NULL || orig_addUserScript == NULL) {
            reconLogF(@"[KILL] 注入失败：WKUserScript=%d orig_addUserScript=%d",
                      scriptCls != NULL, orig_addUserScript != NULL);
            return;
        }
        id alloced = ((id (*)(id, SEL))objc_msgSend)(scriptCls, sel_getUid("alloc"));
        /* injectionTime 0 = AtDocumentStart，forMainFrameOnly NO = iframe 也注入 */
        id mine = ((id (*)(id, SEL, id, NSInteger, BOOL))objc_msgSend)(
            alloced,
            sel_getUid("initWithSource:injectionTime:forMainFrameOnly:"),
            adSpeedDocumentJS(), (NSInteger)0, (BOOL)NO);
        if (mine == nil) {
            reconLogF(@"[KILL] 注入失败：WKUserScript 创建不出来");
            return;
        }
        /* 直接调原实现，绕开自己的 hook，避免递归 */
        orig_addUserScript(controller, sel_getUid("addUserScript:"), mine);
        reconLogF(@"[KILL] ★ H5 加速脚本已挂上（文档开始注入）· %@",
                  NSStringFromClass([controller class]));
    } @catch (NSException *e) {
        reconLogF(@"[KILL] 挂 H5 脚本异常：%@", e.reason ?: @"?");
    }
}

/* 备用入口：从 WKWebViewConfiguration 拿 controller 再挂（v12 那条路，保留兜底） */
static void adInjectSpeedIntoConfiguration(id configuration) {
    if (configuration == nil) {
        return;
    }
    @try {
        SEL uccSel = sel_getUid("userContentController");
        if (![configuration respondsToSelector:uccSel]) {
            return;
        }
        id controller = ((id (*)(id, SEL))objc_msgSend)(configuration, uccSel);
        adPiggybackSpeedScript(controller);
    } @catch (NSException *e) {
        (void)e;
    }
}

static id (*orig_wkInitWithConfig)(id, SEL, CGRect, id);
static id hook_wkInitWithConfig(id self, SEL _cmd, CGRect frame, id configuration) {
    @try {
        adInjectSpeedIntoConfiguration(configuration);
    } @catch (NSException *e) {
        (void)e;
    }
    if (orig_wkInitWithConfig) {
        return orig_wkInitWithConfig(self, _cmd, frame, configuration);
    }
    return nil;
}

static void adInstallSpeedHook(void) {
    RECON_HOOK_I("WKWebView", "initWithFrame:configuration:", hook_wkInitWithConfig, orig_wkInitWithConfig);
}

static void adEvalJSWithLog(id webView, NSString *js, NSString *tag) {
    if (webView == nil || js.length == 0) {
        return;
    }
    SEL sel = sel_getUid("evaluateJavaScript:completionHandler:");
    if (![webView respondsToSelector:sel]) {
        return;
    }
    id handler = ^(id result, NSError *error) {
        NSString *desc = nil;
        if (error != nil) {
            desc = [NSString stringWithFormat:@"error:%@", error.localizedDescription ?: @"?"];
        } else {
            desc = [NSString stringWithFormat:@"%@", result];
        }
        reconLogF(@"[H5·%@] ← %@", tag ?: @"?", reconTrim(desc, 170));
    };
    @try {
        ((void (*)(id, SEL, id, id))objc_msgSend)(webView, sel, js, handler);
    } @catch (NSException *e) {
        reconLogF(@"[H5·%@] 调用异常：%@", tag ?: @"?", e.reason ?: @"?");
    }
}

/* v14：问一下页面里我们的加速脚本到底跑没跑 */
static void adH5SelfCheck(void) {
    NSString *js = @"(function(){try{"
                   @"return 'speed='+(window.__adSpeedOn||0)"
                   @"+' | href='+String(location.href||'').slice(0,110);"
                   @"}catch(e){return 'err:'+e;}})();";

    Class wkCls = NSClassFromString(@"WKWebView");
    NSMutableArray *webViews = [NSMutableArray array];
    for (UIWindow *win in reconAllWindows()) {
        adCollectViews(win, wkCls, webViews, 0);
    }
    NSInteger index = 0;
    for (id webView in webViews) {
        index += 1;
        adEvalJSWithLog(webView, js, [NSString stringWithFormat:@"自检#%ld", (long)index]);
    }
    reconLogF(@"[H5] 自检请求已发往 %ld 个 WebView", (long)index);
}

/* v14：在广告条那一带做命中测试，把类名链打出来 */
static void adProbeTopBar(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            adProbeTopBar();
        });
        return;
    }

    NSArray<NSNumber *> *xs = @[@40, @150, @300, @400];
    NSArray<NSNumber *> *ys = @[@46, @62, @80, @120];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    NSInteger hits = 0;

    for (UIWindow *win in reconAllWindows()) {
        CGRect bounds = win.bounds;
        for (NSNumber *yn in ys) {
            for (NSNumber *xn in xs) {
                CGPoint point = CGPointMake(xn.doubleValue, yn.doubleValue);
                if (!CGRectContainsPoint(bounds, point)) {
                    continue;
                }
                @try {
                    UIView *hit = [win hitTest:point withEvent:nil];
                    if (hit == nil) {
                        continue;
                    }
                    NSMutableArray<NSString *> *chain = [NSMutableArray array];
                    UIView *cursor = hit;
                    int depth = 0;
                    while (cursor != nil && depth < 8) {
                        NSString *cls = NSStringFromClass([cursor class]);
                        [chain addObject:(cls.length > 0 ? cls : @"?")];
                        cursor = cursor.superview;
                        depth += 1;
                    }
                    NSString *key = [chain componentsJoinedByString:@"<"];
                    if ([seen containsObject:key]) {
                        continue;
                    }
                    [seen addObject:key];
                    hits += 1;

                    /* 把命中视图上的文字也带出来 */
                    NSString *text = @"";
                    SEL textSel = sel_getUid("text");
                    if ([hit respondsToSelector:textSel]) {
                        id value = ((id (*)(id, SEL))objc_msgSend)(hit, textSel);
                        if ([value isKindOfClass:[NSString class]]) {
                            text = reconTrim((NSString *)value, 40);
                        }
                    }
                    reconLogF(@"[PROBE] (%.0f,%.0f) → %@  文本「%@」", point.x, point.y, key, text);

                    if ([text rangeOfString:@"秒"].location != NSNotFound ||
                        [text rangeOfString:@"广告"].location != NSNotFound ||
                        [text rangeOfString:@"奖励"].location != NSNotFound ||
                        [text rangeOfString:@"跳过"].location != NSNotFound) {
                        reconLogF(@"[PROBE] ★ 这一层可能就是计时条，把它的方法列出来");
                        reconDumpClassMethods([hit class], @"计时条命中");
                        if (hit.superview != nil) {
                            reconDumpClassMethods([hit.superview class], @"计时条父视图");
                        }
                    }
                } @catch (NSException *e) {
                    (void)e;
                }
            }
        }
    }
    reconLogF(@"[PROBE] 共命中 %ld 个不同层级", (long)hits);
}

static void adPerformStep(NSString *step) {
    @try {
        if ([step isEqualToString:@"bg-prime"]) {
            AdPrimeBackgroundPlayback();
            return;
        }

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

        if ([step isEqualToString:@"video-seek-end"] || [step isEqualToString:@"video-seek-again"]) {
            NSArray *players = adFindViews(@"BeeVideoPlayerView");
            if (players.count == 0) {
                reconLogF(@"[KILL] ②视频快进：屏上没有 BeeVideoPlayerView，跳过");
                return;
            }
            for (id player in players) {
                double before = adCallRetD(player, @"getCurrentTime");
                BOOL ok = adCallD(player, @"seekToTime:", before + 600.0);
                double after = adCallRetD(player, @"getCurrentTime");
                reconLogF(@"[KILL] ②视频快进 %.1fs → seek=%@ → 现在 %.1fs",
                          before, ok ? @"OK" : @"NO", after);
            }
            return;
        }

        if ([step isEqualToString:@"probe-ui"]) {
            adProbeTopBar();
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

        if ([step isEqualToString:@"js-speed"]) {
            /* 小游戏/活动页的广告是 H5 里自己计时的，native 打不到，
               这一刀直接进页面：让时间跑快 8 倍 + 把 <video> 拖到结尾 */
            NSInteger count = adRunJSOnAllWebViews(adSpeedPageJS());
            reconLogF(@"[KILL] ⑦H5 补刀：已注入 %ld 个 WebView", (long)count);
            return;
        }

        if ([step isEqualToString:@"h5-check"]) {
            adH5SelfCheck();
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

    if (!adAnyAdViewPresent()) {
        reconLogF(@"[KILL] 屏上没找到任何广告视图，这次不执行");
        gAdKillRunning = NO;
        return;
    }

    NSArray<NSString *> *steps = @[@"bg-prime", @"countdown-zero", @"video-seek-end", @"video-seek-again",
                                   @"probe-ui", @"reward-finish", @"rewardvideo-end",
                                   @"openscreen-timeover", @"openscreen-exit",
                                   @"js-speed", @"h5-check"];
    double delay = 0.0;
    for (NSString *step in steps) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            adPerformStep(step);
        });
        delay += 0.6;
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((delay + 0.8) * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        reconLogF(@"[KILL] 执行后：%@", adSnapshotState());
        reconBanner(adAnyAdViewPresent() ? @"秒过结束：广告仍在"
                                         : @"秒过执行完毕（视频层已撤，但广告页可能还在，请以屏幕为准）");
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

#pragma mark 后台续跑（v15）

/* 默认开启：这是用户最初要的东西 —— 切后台，倒计时接着走 */
BOOL AdBgKeepEnabled(void) {
    NSNumber *value = [[NSUserDefaults standardUserDefaults] objectForKey:@"ad_bg_keep"];
    return value == nil ? YES : value.boolValue;
}

void AdSetBgKeep(BOOL enabled) {
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:@"ad_bg_keep"];
    reconLogF(@"[BG] 后台续跑 %@", enabled ? @"已开启（页面进后台不再暂停）" : @"已关闭");
}

/*
    让播放器允许后台播放。
    BeeVideoPlayerView 上有现成的 -setEnableBackgroudPlay:（原厂拼写就是 Backgroud），
    开起来之后进后台视频不会被主动停。
*/
void AdPrimeBackgroundPlayback(void) {
    if (!AdBgKeepEnabled()) {
        return;
    }
    NSArray *players = adFindViews(@"BeeVideoPlayerView");
    NSInteger ok = 0;
    for (id player in players) {
        if (adCallB(player, @"setEnableBackgroudPlay:", YES)) {
            ok += 1;
        }
    }
    reconLogF(@"[BG] 允许后台播放：%ld/%lu 个播放器", (long)ok, (unsigned long)players.count);

    /* 直接调浮窗的方法开音频保活（v16：不再只靠 Darwin 通知，避免通知丢了没人接） */
    @try {
        [[FloatingButtonWindow sharedInstance] forceEnableKeepAlive];
    } @catch (NSException *e) {
        reconLogF(@"[BG] 打开音频保活异常：%@", e.reason ?: @"?");
    }
}

static BOOL gBgPrimed = NO;

static void adBgKeepTick(void) {
    if (!AdBgKeepEnabled()) {
        gBgPrimed = NO;
        return;
    }
    NSInteger players = adCount(@"BeeVideoPlayerView");
    if (players == 0) {
        gBgPrimed = NO;
        return;
    }
    if (gBgPrimed) {
        return;
    }
    AdPrimeBackgroundPlayback();
    gBgPrimed = YES;
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
        reconLogF(@"[KILL] H5 加速状态：%@（白名单页面文档期注入）", AdJSSpeedEnabled() ? @"开" : @"关");

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
            adBgKeepTick();
            adKeepVideoAlive();
        }];

        // 6.6 v17 延迟补挂：Cube/Nebula/Bee 这些类要等小程序框架加载后才存在，
        //     每 2 秒重试一次，最多 5 分钟（装上一个记一行 [HOOK]）
        [NSTimer scheduledTimerWithTimeInterval:2.0 repeats:YES block:^(NSTimer *timer) {
            if (gDeferredRounds > 150) {
                [timer invalidate];
                return;
            }
            reconInstallDeferredHooks();
        }];

        // 6.7 探针：[TICK] Nebula 定时泵还活不活
        [NSTimer scheduledTimerWithTimeInterval:5.0 repeats:YES block:^(NSTimer *timer) {
            (void)timer;
            adTickReport();
        }];
        gInternalTimerGuard = NO;

        // 7. 前后台生命周期全部记下来 + 立刻落盘（判断"进程有没有活下来"的唯一依据）
        NSArray<NSString *> *lifecycleNames = @[UIApplicationWillResignActiveNotification,
                                                UIApplicationDidEnterBackgroundNotification,
                                                UIApplicationWillEnterForegroundNotification,
                                                UIApplicationDidBecomeActiveNotification];
        for (NSString *name in lifecycleNames) {
            [[NSNotificationCenter defaultCenter] addObserverForName:name
                                                              object:nil
                                                               queue:[NSOperationQueue mainQueue]
                                                          usingBlock:^(NSNotification *note) {
                reconLogF(@"[LIFE] %@", note.name);
                if ([note.name isEqualToString:UIApplicationWillResignActiveNotification] ||
                    [note.name isEqualToString:UIApplicationDidEnterBackgroundNotification]) {
                    gAppInBackground = YES;
                } else {
                    gAppInBackground = NO;
                    reconLogF(@"[TICK] 回到前台，Nebula 定时泵累计 %d 次", gNbTickCount);
                }
                gDirty = YES;
                reconAutoFlush();
            }];
        }

        // 7.5 30 秒心跳：进后台之后如果还能看到这条，就说明进程没被挂起
        [NSTimer scheduledTimerWithTimeInterval:30.0 repeats:YES block:^(NSTimer *timer) {
            (void)timer;
            reconLogF(@"[ALIVE] 进程存活心跳（%ld 条日志）", (long)ReconLineCount());
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
