// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Ben Weaver and Guillotine contributors
#import <AppKit/AppKit.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/pwr_mgt/IOPMLib.h>
#import <IOKit/pwr_mgt/IOPMLibDefs.h>
#import <IOKit/ps/IOPowerSources.h>
#import <IOKit/ps/IOPSKeys.h>
#import <dlfcn.h>
#import <sys/file.h>
#import <fcntl.h>
#import <unistd.h>
#import <float.h>
#import <math.h>

// Private API declarations verified against upstream implementations; resolved at runtime.
@interface NSObject (GuillotineKeyboard)
- (NSArray<NSNumber *> *)copyKeyboardBacklightIDs;
- (float)brightnessForKeyboard:(uint64_t)keyboard;
- (BOOL)setBrightness:(float)value forKeyboard:(uint64_t)keyboard;
@end
typedef kern_return_t (*OpenPanel)(io_service_t, task_port_t, unsigned int, void **);
typedef kern_return_t (*SetPanelPower)(void *, uint32_t);
static void *panel;
static SetPanelPower setPanel;
static id keyboard;
static NSMutableDictionary *saved;
static NSString *journal, *restoreRequest;
static BOOL fake, finished, ready, restoreSleep, restoreWake, sleepPending;
static NSTimeInterval deadline;
static int lockFD;
static BOOL allowBattery, closedLid;
static io_connect_t powerConnection;
static NSString *directory;
static void emit(NSString *line) { puts(line.UTF8String); fflush(stdout); }
static BOOL saveJournal(void) {
    if (![saved writeToFile:journal atomically:YES]) return NO;
    int descriptor=open(journal.fileSystemRepresentation,O_RDONLY);
    BOOL ok=descriptor>=0 && fsync(descriptor)==0;
    if (descriptor>=0) close(descriptor);
    return ok;
}
static BOOL externalPower(void) {
    if (fake) {
        NSString *value=[NSString stringWithContentsOfFile:[directory stringByAppendingPathComponent:@"test-power"] encoding:NSUTF8StringEncoding error:nil];
        return ![value isEqualToString:@"battery"];
    }
    CFTypeRef info=IOPSCopyPowerSourcesInfo(); if (!info) return NO;
    CFStringRef type=IOPSGetProvidingPowerSourceType(info);
    BOOL ac=type && CFEqual(type,CFSTR(kIOPSACPowerValue)); CFRelease(info); return ac;
}
static BOOL tooHot(void) {
    if (fake) return [[NSFileManager defaultManager] fileExistsAtPath:[directory stringByAppendingPathComponent:@"test-hot"]];
    return NSProcessInfo.processInfo.thermalState>=NSProcessInfoThermalStateSerious;
}
static IOReturn lidControl(BOOL disable) {
    if (fake) return KERN_SUCCESS;
    if (!powerConnection) powerConnection=IOPMFindPowerManagement(MACH_PORT_NULL);
    uint64_t value=disable?1:0;
    return IOConnectCallScalarMethod(powerConnection,kPMSetClamshellSleepState,&value,1,NULL,NULL);
}
static BOOL lidCausesSleep(void) {
    if (fake) return YES;
    io_registry_entry_t root=IORegistryEntryFromPath(kIOMainPortDefault,"IOPower:/IOPowerConnection/IOPMrootDomain");
    if (!root) root=IOServiceGetMatchingService(kIOMainPortDefault,IOServiceMatching("IOPMrootDomain"));
    id value=CFBridgingRelease(IORegistryEntryCreateCFProperty(root,CFSTR("AppleClamshellCausesSleep"),NULL,0));
    IOObjectRelease(root);
    return !value || [value boolValue];
}
static BOOL restore(void) {
    BOOL ok=YES;
    if ([saved[@"panelOwned"] boolValue] && !fake) ok=(setPanel(panel,1)==KERN_SUCCESS);
    NSDictionary *values=saved[@"keyboards"];
    for (NSString *key in values) {
        uint64_t kid=key.longLongValue;
        // A nonzero current value belongs to the user/OS and must not be overwritten.
        if (!fake && [keyboard brightnessForKeyboard:kid] <= 0.00001f)
            ok=[keyboard setBrightness:[values[key] floatValue] forKeyboard:kid] && ok;
    }
    // The shared private bit is touched only if this session changed a sleep-causing policy.
    if ([saved[@"lidOwned"] boolValue]) ok=(lidControl(NO)==KERN_SUCCESS) && ok;
    if (ok) [[NSFileManager defaultManager] removeItemAtPath:journal error:nil];
    return ok;
}
static void finish(int code, NSString *reason) {
    if (finished) return; finished=YES;
    BOOL restored=restore();
    [reason writeToFile:[directory stringByAppendingPathComponent:@"last-stop.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    emit([NSString stringWithFormat:@"STOP %@%@",reason,restored?@"":@"; restoration failed; reopen Guillotine to retry"]);
    exit(restored?code:3);
}
static void thermalCutout(void) {
    if (finished) return; finished=YES;
    BOOL restored=restore();
    [@"Thermal cutout: controls restored; system sleep requested." writeToFile:[directory stringByAppendingPathComponent:@"last-stop.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    if (fake) {
        [@"sleep" writeToFile:[directory stringByAppendingPathComponent:@"test-sleep-request"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
        emit(@"STOP Thermal cutout: restored before sleep request"); exit(restored?0:3);
    }
    if (!powerConnection) powerConnection=IOPMFindPowerManagement(MACH_PORT_NULL);
    IOReturn result=IOPMSleepSystem(powerConnection);
    NSString *outcome=[NSString stringWithFormat:@"Thermal cutout: restoration %@; sleep request %@ (0x%x).",restored?@"succeeded":@"failed",result==KERN_SUCCESS?@"accepted":@"rejected",result];
    [outcome writeToFile:[directory stringByAppendingPathComponent:@"last-stop.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    emit([@"STOP " stringByAppendingString:outcome]);
    exit(restored && result==KERN_SUCCESS?0:3);
}
static void enforcePolicy(void) {
    if (externalPower()) return;
    if (tooHot()) thermalCutout();
    if (!allowBattery) finish(0,@"External power disconnected; battery use is disabled");
}
static void powerChanged(void *context) { if (ready) enforcePolicy(); }
static BOOL applyOff(NSString **error) {
    enforcePolicy();
    if (closedLid && lidCausesSleep()) {
        saved[@"lidOwned"]=@YES;
        if (!saveJournal() || lidControl(YES)!=KERN_SUCCESS) {
            *error=@"Closed-lid control was rejected. Disable the experimental option or use native clamshell hardware."; return NO;
        }
    }
    NSMutableDictionary *values=saved[@"keyboards"];
    for (NSString *key in values.allKeys) {
        uint64_t kid=key.longLongValue;
        float current=fake?0:[keyboard brightnessForKeyboard:kid];
        if (current>0.00001f) {
            // Retain the latest user/ambient change for eventual restoration.
            values[key]=@(current);
            if (!saveJournal()) { *error=@"Could not record keyboard restoration state."; return NO; }
        }
        if (!fake && (![keyboard setBrightness:0 forKeyboard:kid] || [keyboard brightnessForKeyboard:kid]>0.00001f)) {
            *error=@"macOS rejected keyboard backlight control."; return NO;
        }
    }
    if (!fake && setPanel(panel,0)!=KERN_SUCCESS) { *error=@"macOS rejected built-in panel power control."; return NO; }
    return YES;
}
static BOOL loadHardware(NSString **error) {
    if (fake) return YES;
#if !defined(__arm64__)
    *error=@"Panel power control requires an Apple Silicon MacBook."; return NO;
#endif
    void *lib=dlopen("/System/Library/PrivateFrameworks/IOMobileFramebuffer.framework/IOMobileFramebuffer",RTLD_NOW);
    OpenPanel open=lib?(OpenPanel)dlsym(lib,"IOMobileFramebufferOpen"):NULL;
    setPanel=lib?(SetPanelPower)dlsym(lib,"IOMobileFramebufferRequestPowerChange"):NULL;
    if (!open || !setPanel) { *error=@"Panel power API unavailable on this macOS version."; return NO; }
    io_iterator_t iterator=0;
    IOServiceGetMatchingServices(kIOMainPortDefault,IOServiceMatching("IOMobileFramebuffer"),&iterator);
    io_service_t service;
    while ((service=IOIteratorNext(iterator))) {
        NSString *name=CFBridgingRelease(IORegistryEntryCreateCFProperty(service,CFSTR("IONameMatched"),NULL,0));
        if ([name hasPrefix:@"disp0,"]) open(service,mach_task_self(),0,&panel);
        IOObjectRelease(service);
    }
    IOObjectRelease(iterator);
    if (!panel) { *error=@"No controllable built-in Apple Silicon panel found. Desktop/external displays are not supported."; return NO; }
    dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness",RTLD_NOW);
    keyboard=[[NSClassFromString(@"KeyboardBrightnessClient") alloc] init];
    if (![keyboard respondsToSelector:@selector(copyKeyboardBacklightIDs)] ||
        ![keyboard respondsToSelector:@selector(brightnessForKeyboard:)] ||
        ![keyboard respondsToSelector:@selector(setBrightness:forKeyboard:)]) {
        *error=@"Keyboard backlight API unavailable on this macOS version."; return NO;
    }
    return YES;
}
int main(int argc, char **argv) { @autoreleasepool {
    signal(SIGPIPE,SIG_IGN);
    NSArray *args=NSProcessInfo.processInfo.arguments;
    fake=[args containsObject:@"--test-guard"];
    allowBattery=[args containsObject:@"--allow-battery"];
    closedLid=[args containsObject:@"--closed-lid"];
    restoreSleep=[args containsObject:@"--restore-on-sleep"];
    restoreWake=[args containsObject:@"--restore-on-wake"];
    directory=fake?args.lastObject:[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Guillotine"];
    [[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:nil];
    journal=[directory stringByAppendingPathComponent:@"hardware-session.plist"];
    restoreRequest=[directory stringByAppendingPathComponent:@"restore.request"];
    lockFD=open([[directory stringByAppendingPathComponent:@"guard.lock"] fileSystemRepresentation],O_CREAT|O_RDWR,0600);
    if (lockFD<0 || flock(lockFD,LOCK_EX|LOCK_NB)!=0) {
        if ([args containsObject:@"--restore"]) {
            BOOL requested=[@"restore" writeToFile:restoreRequest atomically:YES encoding:NSUTF8StringEncoding error:nil];
            emit(requested?@"RESTORE REQUESTED":@"ERROR Could not request restoration"); return requested?0:2;
        }
        emit(@"ERROR Another Guillotine hardware session is already running."); return 2;
    }
    [[NSFileManager defaultManager] removeItemAtPath:restoreRequest error:nil];
    NSString *error=nil;
    if (!loadHardware(&error)) { emit([@"ERROR " stringByAppendingString:error]); return 2; }
    saved=[[NSDictionary dictionaryWithContentsOfFile:journal] mutableCopy];
    if (saved && !restore()) { emit(@"ERROR Previous hardware session could not be restored. Restart macOS or retry."); return 3; }
    if ([args containsObject:@"--recover"] || [args containsObject:@"--restore"]) { emit(@"RECOVERED"); return 0; }
    if (!externalPower() && (!allowBattery || tooHot())) { emit(@"ERROR Battery use is disabled or macOS thermal pressure is too high. Connect power or wait for cooling."); return 2; }
    NSMutableDictionary *values=[NSMutableDictionary dictionary];
    NSArray *ids=fake?@[@1]:[keyboard copyKeyboardBacklightIDs];
    for (NSNumber *kid in ids) {
        float b=fake?0.5f:[keyboard brightnessForKeyboard:kid.unsignedLongLongValue];
        if (!isfinite(b) || b<0 || b>1) { emit(@"ERROR Invalid keyboard brightness readback."); return 2; }
        values[kid.stringValue]=@(b);
    }
    if (!values.count) { emit(@"ERROR No supported backlit keyboard found."); return 2; }
    saved=[@{@"panelOwned":@YES,@"keyboards":values} mutableCopy];
    if (!saveJournal()) { emit(@"ERROR Could not save restoration journal; nothing changed."); return 2; }
    CFRunLoopSourceRef power=IOPSNotificationCreateRunLoopSource(powerChanged,NULL);
    if (!power && !fake) finish(2,@"Power notification setup failed");
    if (power) CFRunLoopAddSource(CFRunLoopGetMain(),power,kCFRunLoopCommonModes);
    [NSNotificationCenter.defaultCenter addObserverForName:NSProcessInfoThermalStateDidChangeNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n){ if (ready) enforcePolicy(); }];
    if (!applyOff(&error)) { emit([@"ERROR " stringByAppendingString:error]); finish(2,error); }
    ready=YES; deadline=NSProcessInfo.processInfo.systemUptime+5;
    emit(@"READY");
    fcntl(STDIN_FILENO,F_SETFL,O_NONBLOCK);
    dispatch_source_t input=dispatch_source_create(DISPATCH_SOURCE_TYPE_READ,STDIN_FILENO,0,dispatch_get_main_queue());
    dispatch_source_set_event_handler(input,^{
        char bytes[128]; ssize_t n=read(STDIN_FILENO,bytes,sizeof(bytes));
        if (n==0) finish(0,@"App disconnected");
        if (n>0) {
            NSString *message=[[NSString alloc] initWithBytes:bytes length:n encoding:NSUTF8StringEncoding];
            if ([message containsString:@"battery=0"]) allowBattery=NO;
            else if ([message containsString:@"battery=1"]) allowBattery=YES;
            deadline=NSProcessInfo.processInfo.systemUptime+5;
            enforcePolicy();
        }
    }); dispatch_resume(input);
    for (NSNumber *number in @[@(SIGTERM),@(SIGINT)]) {
        int sig=number.intValue; signal(sig,SIG_IGN);
        dispatch_source_t source=dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL,sig,0,dispatch_get_main_queue());
        dispatch_source_set_event_handler(source,^{ finish(0,@"Guard stopped"); }); dispatch_resume(source);
        // Sources live for the process lifetime; keep them retained under ARC.
        CFBridgingRetain(source);
    }
    NSNotificationCenter *workspace=NSWorkspace.sharedWorkspace.notificationCenter;
    [workspace addObserverForName:NSWorkspaceWillSleepNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n){
        if (restoreSleep) finish(0,@"Sleep restoration enabled");
        else { sleepPending=YES; deadline=NSProcessInfo.processInfo.systemUptime+8; }
    }];
    [workspace addObserverForName:NSWorkspaceDidWakeNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n){
        if (restoreWake) finish(0,@"Wake restoration enabled");
        else { sleepPending=NO; deadline=NSProcessInfo.processInfo.systemUptime+8; }
    }];
    [NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer *timer){
        if ([[NSFileManager defaultManager] fileExistsAtPath:restoreRequest]) {
            [[NSFileManager defaultManager] removeItemAtPath:restoreRequest error:nil];
            finish(0,@"Remote restoration requested");
        }
        // Grant one bounded wake grace even if the workspace wake notice is delayed.
        if (sleepPending) { sleepPending=NO; deadline=NSProcessInfo.processInfo.systemUptime+8; }
        if (NSProcessInfo.processInfo.systemUptime>deadline) finish(0,@"Five-second lease expired");
        NSString *failure=nil;
        if (!applyOff(&failure)) finish(2,failure);
    }];
    [[NSRunLoop mainRunLoop] run];
    return 0;
}}
