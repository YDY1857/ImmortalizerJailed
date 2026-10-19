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
    ===== 修改说明（2026-10，针对 iOS 27 保活失效）=====
    改动只发生在「音频保活」这一段，界面 / 拖拽 / 停靠逻辑保持原样。

    原来的写法：每 1 秒把 AVAudioPlayer 整个重建一遍（包括重新解码 base64），
    并且 setActive / play 的错误全部用 error:nil 吞掉。后台连续跑一两天后，
    累计 CPU 开销让 runningboardd 把这进程判成高耗能并回收；即使被系统拒绝，
    界面上也完全看不出来。

    现在的写法：
    1. AVAudioPlayer 只创建一次并复用，不再每秒重建
    2. 巡检定时器改成 5 秒一次，只在「真的没在播」的时候才补救
    3. setCategory / setActive / play / initWithData 全部检查返回值
    4. 音频被打断、耳机拔出、路由变化、进出后台，都会自动恢复
    5. 会话激活失败时用 beginBackgroundTask 兜底，并延长重试窗口
    6. 状态变化直接在浮窗的 toast 上写出来，不再静默失效
*/

#import "FloatingButtonWindow.h"

@interface FloatingButtonWindow ()
@property (nonatomic, strong) UIButton *floatingButton;
@property (nonatomic, strong) UIView *handleView;
@property (nonatomic, assign) BOOL isImmortalized;
@property (nonatomic, assign) BOOL isDocked;
@property (nonatomic, strong) AVAudioPlayer *audioPlayer;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, strong) NSTimer *dockTimer;
@property (nonatomic, assign) BOOL audioOK;
@property (nonatomic, assign) BOOL didReportAudioOnce;
@property (nonatomic, assign) UIBackgroundTaskIdentifier bgTask;
@end

static void vibrateDevice() {
    UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleHeavy];
    [feedback prepare];
    [feedback impactOccurred];
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

- (void)updateButtonColor {
    if (self.isImmortalized) {
        self.floatingButton.tintColor = [UIColor systemBlueColor];
    } else {
        self.floatingButton.tintColor = [UIColor systemRedColor];
    }
}

- (void)updateAndShowToast {
    NSString *subtitle = @"";
    NSString *icon = @"";
    NSString *appName = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleName"];

    if (self.isImmortalized) {
        subtitle = [NSString stringWithFormat:@"Immortalized%@", [self audioDetailText]];
        icon = @"hourglass.bottomhalf.fill";
        [self startTimer];
    } else {
        subtitle = @"At Rest";
        icon = @"arrow.uturn.left.circle.fill";
        [self stopTimer];
    }

    CustomToastView *toastView = [[CustomToastView alloc] initWithTitle:appName subtitle:subtitle 
                                    icon:[UIImage systemImageNamed:icon] autoHide:3];

    [toastView presentToastInViewController:self.rootViewController];
}

- (NSString *)audioDetailText {
    if (self.audioOK) {
        return @" · 音频运行中";
    }
    return @" · 音频未启动";
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
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *note) {
        [weakSelf ensureAudioRunning];
    }];
}

- (void)startTimer {
    [self.timer invalidate];
    self.timer = nil;

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
    self.didReportAudioOnce = NO;
}

- (void)timerFired {
    if (!self.isImmortalized) {
        return;
    }
    if (self.audioOK && self.audioPlayer.isPlaying) {
        return;
    }
    [self ensureAudioRunning];
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
        NSData *audioData = [[NSData alloc] initWithBase64EncodedString:kBase64Audio
                                                               options:NSDataBase64DecodingIgnoreUnknownCharacters];
        if (audioData.length == 0) {
            [self setAudioState:NO reason:@"静音音频数据损坏"];
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

        self.audioPlayer.volume = 0.0;
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
    if (self.audioOK == ok) {
        return;
    }

    self.audioOK = ok;

    if (!self.isImmortalized) {
        return;
    }

    if (!self.didReportAudioOnce) {
        self.didReportAudioOnce = YES;
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
