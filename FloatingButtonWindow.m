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
    ===== 修改说明 v6（2026-10，针对 iOS 27 保活失效）=====

    改动只发生在「音频保活」这一段，界面 / 拖拽 / 停靠逻辑保持原样。

    【问题一：音频负载本身是错的】
    原来内嵌的 kBase64Audio 是一段满刻度噪声（峰值 100%、RMS 24%），
    靠 volume = 0 压成无声。系统看到的是一个音量恒为 0 的音频流，
    iOS 27 对「零输出电平」的后台音频越来越不宽容。

    现在改为运行时合成 18 Hz 超低频正弦波，音量 1.0：
    - 有真实、非零的采样数据和输出电平
    - 18 Hz 低于人耳下限，手机扬声器也根本放不出来，实际听感为零
    - 不再需要内嵌 60KB 的 base64，代码里直接算出来

    【问题二：每 1 秒重建一次播放器】
    原来每秒 [[AVAudioPlayer alloc] initWithData:...] 一次，一天 8.6 万次，
    后台 CPU 预算被耗光后进程被 runningboardd 回收。现在只建一次并复用，
    巡检改成 5 秒一次，只在真的没在播时才补救。

    【问题三：错误被 error:nil 吞掉，界面上看不出失效】
    现在 setCategory / setActive / play 全部检查返回值，
    失败原因直接写在浮窗 toast 上；长按浮窗可随时查看实时状态。

    【问题四：进程被挂起，但界面上看不出来】
    音频会话是活动的，不代表进程真的在跑。iOS 把进程挂起时，
    音频对象照样报 isPlaying = YES，定时器却全部停摆（广告倒计时不走就是这个）。
    现在每 5 秒打一次心跳，回到前台时用墙钟时间对比，算出后台被挂起了多久，
    直接显示在 toast 上。这是判断"到底有没有被挂起"的唯一可靠依据。
*/

#import "FloatingButtonWindow.h"
#import <math.h>

@interface FloatingButtonWindow ()
@property (nonatomic, strong) UIButton *floatingButton;
@property (nonatomic, strong) UIView *handleView;
@property (nonatomic, assign) BOOL isImmortalized;
@property (nonatomic, assign) BOOL isDocked;
@property (nonatomic, strong) AVAudioPlayer *audioPlayer;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, strong) NSTimer *dockTimer;
@property (nonatomic, assign) BOOL audioOK;
@property (nonatomic, copy) NSString *audioLastError;
@property (nonatomic, assign) BOOL suppressStateToast;
@property (nonatomic, assign) NSTimeInterval lastHeartbeat;
@property (nonatomic, assign) NSTimeInterval suspendedGap;
@property (nonatomic, assign) UIBackgroundTaskIdentifier bgTask;
@end

static void vibrateDevice() {
    UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleHeavy];
    [feedback prepare];
    [feedback impactOccurred];
}

/*
    合成一段 16bit / 22050Hz / 单声道 的 2 秒正弦波。

    频率 18 Hz：低到人耳听不见，手机扬声器（几百 Hz 以下就急剧衰减）
    也根本发不出这个频段，所以听感上等于静音。
    但采样数据是真实的非零波形，输出电平也是真的，
    系统判定「正在播放音频」时不会被当成空流。

    想微调就改这两个常量：
    frequency 再低一点更保险，amplitude 越小越安静。
*/
static const double kKeepAliveFrequency = 18.0;
static const double kKeepAliveAmplitude = 0.10;

static NSData *makeInaudibleWav(void) {
    static NSData *cached = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        const uint32_t sampleRate = 22050;
        const uint32_t frameCount = sampleRate * 2;

        uint32_t dataSize = frameCount * 2;
        uint32_t riffSize = 36 + dataSize;
        uint32_t fmtSize = 16;
        uint16_t audioFormat = 1;
        uint16_t channels = 1;
        uint32_t byteRate = sampleRate * channels * 2;
        uint16_t blockAlign = channels * 2;
        uint16_t bitsPerSample = 16;

        NSMutableData *wav = [NSMutableData dataWithCapacity:44 + dataSize];

        [wav appendBytes:"RIFF" length:4];
        [wav appendBytes:&riffSize length:4];
        [wav appendBytes:"WAVE" length:4];
        [wav appendBytes:"fmt " length:4];
        [wav appendBytes:&fmtSize length:4];
        [wav appendBytes:&audioFormat length:2];
        [wav appendBytes:&channels length:2];
        [wav appendBytes:&sampleRate length:4];
        [wav appendBytes:&byteRate length:4];
        [wav appendBytes:&blockAlign length:2];
        [wav appendBytes:&bitsPerSample length:2];
        [wav appendBytes:"data" length:4];
        [wav appendBytes:&dataSize length:4];

        int16_t *samples = (int16_t *)calloc(frameCount, sizeof(int16_t));
        if (samples != NULL) {
            for (uint32_t i = 0; i < frameCount; i++) {
                double t = (double)i / (double)sampleRate;
                double v = kKeepAliveAmplitude * 32767.0 * sin(2.0 * M_PI * kKeepAliveFrequency * t);
                samples[i] = (int16_t)lrint(v);
            }
            [wav appendBytes:samples length:dataSize];
            free(samples);
        }

        cached = [wav copy];
    });
    return cached;
}

@implementation FloatingButtonWindow

+ (instancetype)sharedInstance {
    static FloatingButtonWindow *sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[FloatingButtonWindow alloc] init];
    });
    return sharedInstance;
}

- (instancetype)init {
    self = [super initWithFrame:UIScreen.mainScreen.bounds];
    if (self) {
        self.bgTask = UIBackgroundTaskInvalid;
        self.isImmortalized = [[NSUserDefaults standardUserDefaults] boolForKey:@"immortalized"];
        [self setupWindow];
        [self registerAudioObservers];
        [self updateAndShowToast];
        [self setupButton];
        [self setupHandle];
    }
    return self;
}

- (void)setupWindow {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]]) {
            self.windowScene = (UIWindowScene *)scene;
            break;
        }
    }
    self.windowLevel = UIWindowLevelAlert + 1;
    self.userInteractionEnabled = YES;
    self.backgroundColor = [UIColor clearColor];
    self.rootViewController = [[UIViewController alloc] init];
    self.rootViewController.view.backgroundColor = [UIColor clearColor];
    self.hidden = YES;
}

- (void)setupButton {
    _floatingButton = [UIButton buttonWithType:UIButtonTypeCustom];
    _floatingButton.frame = CGRectMake(UIScreen.mainScreen.bounds.size.width - 50 - 30, 200, 50, 50);
    _floatingButton.backgroundColor = [UIColor colorWithRed:0.125 green:0.125 blue:0.125 alpha:1.0];
    [self updateButtonColor];
    _floatingButton.layer.cornerRadius = 25;
    _floatingButton.layer.masksToBounds = YES;

    UIImage *icon = [UIImage systemImageNamed:@"hourglass.tophalf.fill"];
    [_floatingButton setImage:icon forState:UIControlStateNormal];
    
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    [_floatingButton addGestureRecognizer:pan];
    
    [_floatingButton addTarget:self action:@selector(buttonTapped) forControlEvents:UIControlEventTouchUpInside];

    UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleLongPress:)];
    longPress.minimumPressDuration = 1.0;
    [_floatingButton addGestureRecognizer:longPress];
    
    [self.rootViewController.view addSubview:_floatingButton];
    [self snapButtonToNearestEdge:_floatingButton];
}

- (void)setupHandle {
    _handleView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 15, 50)];
    _handleView.backgroundColor = [UIColor colorWithWhite:0.2 alpha:0.7];
    _handleView.layer.cornerRadius = 6;
    _handleView.layer.masksToBounds = YES;
    _handleView.alpha = 0;
    _handleView.hidden = YES;  

    UIView *line = [[UIView alloc] initWithFrame:CGRectMake((_handleView.frame.size.width - 2)/2, 
                                                          (_handleView.frame.size.height - 30)/2, 
                                                          3, 30)];
    line.backgroundColor = [UIColor whiteColor];
    line.layer.cornerRadius = 1;
    line.autoresizingMask = UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
    [_handleView addSubview:line];

    UIPanGestureRecognizer *handlePan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handleHandlePan:)];
    [_handleView addGestureRecognizer:handlePan];
    
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(undockButton)];
    [_handleView addGestureRecognizer:tap];

    [self.rootViewController.view addSubview:_handleView];
}

- (void)makeKeyWindow {
    [super makeKeyWindow];
    dispatch_async(dispatch_get_main_queue(), ^{
        [UIApplication.sharedApplication.windows.firstObject makeKeyWindow];
    });
}

- (void)handlePan:(UIPanGestureRecognizer *)gesture {
    [self resetDockTimer];
    
    CGPoint translation = [gesture translationInView:self];
    
    [UIView animateWithDuration:0.2 animations:^{
        gesture.view.center = CGPointMake(gesture.view.center.x + translation.x,
                                        gesture.view.center.y + translation.y);
        [gesture setTranslation:CGPointZero inView:self];
    }];
    
    if (gesture.state == UIGestureRecognizerStateEnded) {
        [self snapButtonToNearestEdge:(UIButton *)gesture.view];
        [self startDockTimer];
    }
}

- (void)handleHandlePan:(UIPanGestureRecognizer *)gesture {
    CGPoint translation = [gesture translationInView:self];
    
    if (gesture.state == UIGestureRecognizerStateBegan) {
        [self undockButton];
        return;
    }
    
    CGPoint newCenter = CGPointMake(gesture.view.center.x + translation.x,
                                   gesture.view.center.y + translation.y);
    self.floatingButton.center = newCenter;
    [gesture setTranslation:CGPointZero inView:self];
    
    if (gesture.state == UIGestureRecognizerStateEnded) {
        [self snapButtonToNearestEdge:self.floatingButton];
        [self startDockTimer];
    }
}

- (void)snapButtonToNearestEdge:(UIButton *)button {
    CGRect buttonFrame = button.frame;
    CGPoint newCenter = button.center;
    CGFloat screenWidth = self.bounds.size.width;
    CGFloat buttonWidth = buttonFrame.size.width;
    
    if (newCenter.x < screenWidth / 2) {
        newCenter.x = buttonWidth / 2;
    } else {
        newCenter.x = screenWidth - buttonWidth / 2;
    }
    
    newCenter.y = MAX(buttonFrame.size.height / 2, MIN(self.bounds.size.height - buttonFrame.size.height / 2, newCenter.y));
    
    [UIView animateWithDuration:0.3 animations:^{
        button.center = newCenter;
    }];
}

- (void)startDockTimer {
    [self.dockTimer invalidate];
    self.dockTimer = [NSTimer scheduledTimerWithTimeInterval:5.0
                                                    target:self
                                                  selector:@selector(dockButton)
                                                  userInfo:nil
                                                   repeats:NO];
}

- (void)resetDockTimer {
    if (self.isDocked) return;
    [self.dockTimer invalidate];
    [self startDockTimer];
}

- (void)dockButton {
    if (self.isDocked) return;
    
    self.isDocked = YES;
    
    CGRect buttonFrame = self.floatingButton.frame;
    CGRect handleFrame = self.handleView.frame;
    
    BOOL isLeftEdge = self.floatingButton.center.x < self.bounds.size.width / 2;
    CGFloat handleX = isLeftEdge ? 0 : self.bounds.size.width - handleFrame.size.width;
    
    handleFrame.origin = CGPointMake(handleX, buttonFrame.origin.y + (buttonFrame.size.height - handleFrame.size.height)/2);
    self.handleView.frame = handleFrame;
    
    [UIView animateWithDuration:0.3 animations:^{
        self.floatingButton.alpha = 0;
        self.floatingButton.transform = CGAffineTransformMakeScale(0.5, 0.5);
    } completion:^(BOOL finished) {
        self.floatingButton.hidden = YES;
        self.handleView.hidden = NO;
        
        [UIView animateWithDuration:0.2 animations:^{
            self.handleView.alpha = 1;
        }];
    }];
}

- (void)undockButton {
    if (!self.isDocked) return;
    
    self.isDocked = NO;
    self.floatingButton.hidden = NO;
    
    BOOL isLeftEdge = self.handleView.frame.origin.x < self.bounds.size.width / 2;
    CGPoint buttonCenter = self.handleView.center;
    buttonCenter.x = isLeftEdge ? self.handleView.frame.size.width + self.floatingButton.frame.size.width/2 : 
                                 self.bounds.size.width - self.handleView.frame.size.width - self.floatingButton.frame.size.width/2;
    
    self.floatingButton.center = buttonCenter;
    
    [UIView animateWithDuration:0.3 animations:^{
        self.handleView.alpha = 0;
        self.floatingButton.alpha = 1;
        self.floatingButton.transform = CGAffineTransformIdentity;
    } completion:^(BOOL finished) {
        self.handleView.hidden = YES;
        [self startDockTimer];
    }];
}

- (void)showButton {
    self.hidden = NO;
    [self makeKeyAndVisible];
    if (!self.isDocked) {
        [self startDockTimer];
    }
}

- (void)hideButton {
    self.hidden = YES;
    [self.dockTimer invalidate];
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    CGPoint buttonPoint = [self convertPoint:point toView:self.floatingButton];
    if (!self.floatingButton.hidden && [self.floatingButton pointInside:buttonPoint withEvent:event]) {
        return [super hitTest:point withEvent:event];
    }
    
    CGPoint handlePoint = [self convertPoint:point toView:self.handleView];
    if (!self.handleView.hidden && [self.handleView pointInside:handlePoint withEvent:event]) {
        return [super hitTest:point withEvent:event];
    }
    
    return nil;
}

- (void)buttonTapped {
    [UIView animateWithDuration:0.1 animations:^{
        self.floatingButton.transform = CGAffineTransformMakeScale(1.2, 1.2);
        vibrateDevice();
    } completion:^(BOOL finished) {
        [UIView animateWithDuration:0.1 animations:^{
            self.floatingButton.transform = CGAffineTransformIdentity;
        }];
        [[NSUserDefaults standardUserDefaults] setBool:!self.isImmortalized forKey:@"immortalized"];
        self.isImmortalized = !self.isImmortalized;
        notify_post("com.sergy.immortalizerjailed.updateprefs");
        [self updateButtonColor];
        [self updateAndShowToast];
    }];
}

- (void)handleLongPress:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan) {
        return;
    }
    vibrateDevice();
    [self ensureAudioRunning];
    [self showStatusToast];
}

- (void)updateButtonColor {
    if (self.isImmortalized) {
        self.floatingButton.tintColor = [UIColor systemBlueColor];
    } else {
        self.floatingButton.tintColor = [UIColor systemRedColor];
    }
}

- (void)updateAndShowToast {
    NSString *icon = @"";
    NSString *appName = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleName"];

    self.suppressStateToast = YES;

    if (self.isImmortalized) {
        [self startTimer];
        icon = @"hourglass.bottomhalf.fill";
    } else {
        [self stopTimer];
        icon = @"arrow.uturn.left.circle.fill";
    }

    NSString *subtitle = [self statusText];

    self.suppressStateToast = NO;

    CustomToastView *toastView = [[CustomToastView alloc] initWithTitle:appName subtitle:subtitle 
                                    icon:[UIImage systemImageNamed:icon] autoHide:3];

    [toastView presentToastInViewController:self.rootViewController];
}

- (void)showStatusToast {
    NSString *appName = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleName"];
    NSString *subtitle = [self statusText];

    NSInteger sceneDropped = [[NSUserDefaults standardUserDefaults] integerForKey:@"immortalizer_scene_drop_count"];
    if (sceneDropped > 0) {
        subtitle = [subtitle stringByAppendingFormat:@" · 场%ld", (long)sceneDropped];
    }

    CustomToastView *toastView = [[CustomToastView alloc] initWithTitle:appName subtitle:subtitle
                                                                  icon:[UIImage systemImageNamed:@"info.circle.fill"]
                                                              autoHide:5];
    [toastView presentToastInViewController:self.rootViewController];
}

- (NSString *)statusText {
    if (!self.isImmortalized) {
        return @"At Rest";
    }
    if (self.audioOK) {
        if (self.suspendedGap > 3.0) {
            return [NSString stringWithFormat:@"v6 · 后台被挂起 %@", [self formatDuration:self.suspendedGap]];
        }
        return @"v6 · 音频运行中";
    }
    NSString *reason = self.audioLastError;
    if (reason.length == 0) {
        return @"v6 · 音频未启动";
    }
    if (reason.length > 22) {
        reason = [[reason substringToIndex:22] stringByAppendingString:@"…"];
    }
    return [NSString stringWithFormat:@"v6 · 音频未启动 · %@", reason];
}

#pragma mark - 音频保活（iOS 27 修正版）

- (void)registerAudioObservers {
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];

    __weak typeof(self) weakSelf = self;

    [center addObserverForName:AVAudioSessionInterruptionNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *note) {
        NSNumber *type = note.userInfo[AVAudioSessionInterruptionTypeKey];
        if (type.unsignedIntegerValue == AVAudioSessionInterruptionTypeEnded) {
            [weakSelf ensureAudioRunning];
        }
    }];

    [center addObserverForName:AVAudioSessionRouteChangeNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *note) {
        [weakSelf ensureAudioRunning];
    }];

    [center addObserverForName:UIApplicationDidEnterBackgroundNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *note) {
        [weakSelf ensureAudioRunning];
    }];

    [center addObserverForName:UIApplicationWillEnterForegroundNotification
                        object:nil
                         queue:nil
                    usingBlock:^(NSNotification *note) {
        [weakSelf measureSuspensionGap];
        [weakSelf ensureAudioRunning];
        [weakSelf showStatusToast];
    }];
}

/*
    回到前台的第一时间，用墙钟时间和最后一次心跳对比。
    进程要是被挂起了，定时器整段时间都没走，缺口会非常大；
    如果进程真的在跑，缺口最多就是一个 5 秒的巡检周期再加一点抖动。
    注意：这个观察者必须用 queue:nil 同步执行，否则会被恢复的定时器抢先，
    拿到一个"看起来很健康"的假数据。
*/
- (void)measureSuspensionGap {
    if (self.lastHeartbeat <= 0) {
        return;
    }
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    NSTimeInterval gap = now - self.lastHeartbeat - 5.0;
    if (gap > 3.0) {
        self.suspendedGap = gap;
    } else {
        self.suspendedGap = 0;
    }
}

- (void)startTimer {
    [self.timer invalidate];
    self.timer = nil;

    self.suspendedGap = 0;
    self.lastHeartbeat = [NSDate date].timeIntervalSince1970;

    [self ensureAudioRunning];

    NSTimer *watchdog = [NSTimer timerWithTimeInterval:5.0
                                                target:self
                                              selector:@selector(timerFired)
                                              userInfo:nil
                                               repeats:YES];
    watchdog.tolerance = 1.0;
    [[NSRunLoop mainRunLoop] addTimer:watchdog forMode:NSRunLoopCommonModes];
    self.timer = watchdog;
}

- (void)stopTimer {
    [self.timer invalidate];
    self.timer = nil;

    [self.audioPlayer stop];
    self.audioPlayer = nil;

    [self endFallbackBackgroundTask];

    [[AVAudioSession sharedInstance] setActive:NO
                                   withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
                                         error:nil];

    self.audioOK = NO;
    self.audioLastError = nil;
}

- (void)timerFired {
    self.lastHeartbeat = [NSDate date].timeIntervalSince1970;

    if (!self.isImmortalized) {
        return;
    }
    if (self.audioOK && self.audioPlayer.isPlaying) {
        return;
    }
    [self ensureAudioRunning];
}

- (NSString *)formatDuration:(NSTimeInterval)seconds {
    NSInteger total = (NSInteger)llround(seconds);
    if (total < 60) {
        return [NSString stringWithFormat:@"%ld 秒", (long)total];
    }
    return [NSString stringWithFormat:@"%ld 分 %ld 秒", (long)(total / 60), (long)(total % 60)];
}

- (void)ensureAudioRunning {
    if (!self.isImmortalized) {
        return;
    }

    AVAudioSession *session = [AVAudioSession sharedInstance];

    NSError *categoryError = nil;
    BOOL categoryOK = [session setCategory:AVAudioSessionCategoryPlayback
                               withOptions:AVAudioSessionCategoryOptionMixWithOthers
                                     error:&categoryError];

    NSError *activeError = nil;
    BOOL activeOK = [session setActive:YES error:&activeError];

    if (!categoryOK || !activeOK) {
        [self beginFallbackBackgroundTask];
        NSString *reason = activeError.localizedDescription;
        if (reason.length == 0) {
            reason = categoryError.localizedDescription;
        }
        if (reason.length == 0) {
            reason = @"音频会话被系统拒绝";
        }
        [self setAudioState:NO reason:reason];
        return;
    }

    if (self.audioPlayer == nil) {
        NSData *audioData = makeInaudibleWav();
        if (audioData.length == 0) {
            [self setAudioState:NO reason:@"音频数据生成失败"];
            return;
        }

        NSError *playerError = nil;
        self.audioPlayer = [[AVAudioPlayer alloc] initWithData:audioData error:&playerError];
        if (self.audioPlayer == nil) {
            NSString *reason = playerError.localizedDescription;
            if (reason.length == 0) {
                reason = @"播放器创建失败";
            }
            [self setAudioState:NO reason:reason];
            return;
        }

        // 音量保持 1.0：18 Hz 本身听不见，不要再用 0 音量去"补一刀"，
        // 零输出电平正是 iOS 27 不认的地方。
        self.audioPlayer.volume = 1.0;
        self.audioPlayer.numberOfLoops = -1;
        [self.audioPlayer prepareToPlay];
    }

    if (!self.audioPlayer.isPlaying) {
        if (![self.audioPlayer play]) {
            [self setAudioState:NO reason:@"播放启动失败"];
            return;
        }
    }

    [self endFallbackBackgroundTask];
    [self setAudioState:YES reason:nil];
}

- (void)setAudioState:(BOOL)ok reason:(NSString *)reason {
    if (ok) {
        self.audioLastError = nil;
    } else if (reason.length > 0) {
        self.audioLastError = reason;
    }

    if (self.audioOK == ok) {
        return;
    }

    self.audioOK = ok;

    if (!self.isImmortalized || self.suppressStateToast) {
        return;
    }

    NSString *appName = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleName"];
    NSString *subtitle = ok ? @"保活已恢复 · 音频运行中"
                            : [NSString stringWithFormat:@"保活失效 · %@", reason ?: @"音频被拒"];
    NSString *iconName = ok ? @"hourglass.bottomhalf.fill" : @"exclamationmark.triangle.fill";

    CustomToastView *toastView = [[CustomToastView alloc] initWithTitle:appName
                                                              subtitle:subtitle
                                                                  icon:[UIImage systemImageNamed:iconName]
                                                              autoHide:3];
    [toastView presentToastInViewController:self.rootViewController];
}

- (void)beginFallbackBackgroundTask {
    if (self.bgTask != UIBackgroundTaskInvalid) {
        return;
    }

    __weak typeof(self) weakSelf = self;
    self.bgTask = [UIApplication.sharedApplication beginBackgroundTaskWithName:@"ImmortalizerFallback"
                                                            expirationHandler:^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        [strongSelf endFallbackBackgroundTask];
    }];
}

- (void)endFallbackBackgroundTask {
    if (self.bgTask == UIBackgroundTaskInvalid) {
        return;
    }
    [UIApplication.sharedApplication endBackgroundTask:self.bgTask];
    self.bgTask = UIBackgroundTaskInvalid;
}

@end
