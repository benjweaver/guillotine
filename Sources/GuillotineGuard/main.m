// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (c) 2026 Ben Weaver and Guillotine contributors
#import <AppKit/AppKit.h>
#import <CoreAudio/CoreAudio.h>
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
#import "../Shared/LidService.h"

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
static BOOL allowBattery, closedLid, muteSpeakers;
static NSInteger sleepBelow=10, lowPowerBelow;
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
// Only built-in output devices are eligible. Virtual, aggregate, HDMI, USB,
// and Bluetooth outputs retain their routing, volume, and mute state.
static NSDictionary<NSString *, NSNumber *> *speakerDevices(void) {
    if (fake) return @{@"builtin-speakers": @1};
    AudioObjectPropertyAddress address={kAudioHardwarePropertyDevices,kAudioObjectPropertyScopeGlobal,kAudioObjectPropertyElementMain};
    UInt32 size=0;
    if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject,&address,0,NULL,&size)!=noErr) return nil;
    NSMutableData *data=[NSMutableData dataWithLength:size];
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject,&address,0,NULL,&size,data.mutableBytes)!=noErr) return nil;
    NSMutableDictionary *devices=[NSMutableDictionary dictionary];
    AudioDeviceID *ids=data.mutableBytes;
    for (NSUInteger i=0;i<size/sizeof(AudioDeviceID);i++) {
        AudioDeviceID device=ids[i]; UInt32 transport=0, length=sizeof(transport);
        address=(AudioObjectPropertyAddress){kAudioDevicePropertyTransportType,kAudioObjectPropertyScopeGlobal,kAudioObjectPropertyElementMain};
        if (AudioObjectGetPropertyData(device,&address,0,NULL,&length,&transport)!=noErr || transport!=kAudioDeviceTransportTypeBuiltIn) continue;
        address=(AudioObjectPropertyAddress){kAudioDevicePropertyStreams,kAudioObjectPropertyScopeOutput,kAudioObjectPropertyElementMain};
        length=0;
        if (AudioObjectGetPropertyDataSize(device,&address,0,NULL,&length)!=noErr || !length) continue;
        address=(AudioObjectPropertyAddress){kAudioDevicePropertyDeviceUID,kAudioObjectPropertyScopeGlobal,kAudioObjectPropertyElementMain};
        CFStringRef uid=NULL; length=sizeof(uid);
        if (AudioObjectGetPropertyData(device,&address,0,NULL,&length,&uid)!=noErr || !uid) return nil;
        devices[CFBridgingRelease(uid)]=@(device);
    }
    return devices;
}
static BOOL readMute(AudioDeviceID device, UInt32 *value) {
    if (fake) {
        NSString *text=[NSString stringWithContentsOfFile:[directory stringByAppendingPathComponent:@"test-mute"] encoding:NSUTF8StringEncoding error:nil];
        *value=text.intValue?1:0; return YES;
    }
    AudioObjectPropertyAddress address={kAudioDevicePropertyMute,kAudioObjectPropertyScopeOutput,kAudioObjectPropertyElementMain};
    UInt32 size=sizeof(*value);
    return AudioObjectGetPropertyData(device,&address,0,NULL,&size,value)==noErr;
}
static BOOL writeMute(AudioDeviceID device, UInt32 value) {
    if (fake) return [[NSString stringWithFormat:@"%u",value] writeToFile:[directory stringByAppendingPathComponent:@"test-mute"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    AudioObjectPropertyAddress address={kAudioDevicePropertyMute,kAudioObjectPropertyScopeOutput,kAudioObjectPropertyElementMain};
    Boolean settable=false;
    return AudioObjectIsPropertySettable(device,&address,&settable)==noErr && settable &&
        AudioObjectSetPropertyData(device,&address,0,NULL,sizeof(value),&value)==noErr;
}
static BOOL restoreAudio(void) {
    NSDictionary *owned=saved[@"speakerMutes"];
    if (!owned.count) return YES;
    NSDictionary *devices=speakerDevices();
    if (!devices) return NO;
    for (NSString *uid in owned) {
        // Stable UIDs avoid restoring a newly assigned numeric device ID.
        // Keep the journal pending if the original device is temporarily absent.
        NSNumber *device=devices[uid]; UInt32 current=0;
        if (!device || !readMute(device.unsignedIntValue,&current)) return NO;
        if (current==1 && !writeMute(device.unsignedIntValue,[owned[uid] unsignedIntValue])) return NO;
    }
    return YES;
}
static BOOL applyAudio(NSString **error) {
    if (!muteSpeakers) {
        if (!restoreAudio()) { *error=@"Could not restore built-in speaker mute. Retry Restore."; return NO; }
        if (saved[@"speakerMutes"]) { [saved removeObjectForKey:@"speakerMutes"]; if (!saveJournal()) { *error=@"Could not record speaker restoration."; return NO; } }
        return YES;
    }
    NSDictionary *devices=speakerDevices();
    if (!devices.count) { *error=@"No built-in speaker output found. Uncheck Mute built-in speakers while headless to continue."; return NO; }
    NSMutableDictionary *owned=[saved[@"speakerMutes"] mutableCopy] ?: [NSMutableDictionary dictionary];
    for (NSString *uid in devices) {
        AudioDeviceID device=[devices[uid] unsignedIntValue]; UInt32 current=0;
        if (!readMute(device,&current)) { *error=@"Built-in speaker mute is unavailable. Uncheck Mute built-in speakers while headless to continue."; return NO; }
        // Already-muted speakers need no override and must stay muted on exit.
        if (current==1) continue;
        owned[uid]=@(current); saved[@"speakerMutes"]=owned;
        if (!saveJournal()) { *error=@"Could not save speaker restoration state; audio unchanged."; return NO; }
        if (!writeMute(device,1)) { *error=@"macOS rejected built-in speaker mute. Uncheck Mute built-in speakers while headless to continue."; return NO; }
    }
    return YES;
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
static double batteryPercentage(void) {
    if (fake) {
        NSString *value=[NSString stringWithContentsOfFile:[directory stringByAppendingPathComponent:@"test-percentage"] encoding:NSUTF8StringEncoding error:nil];
        if (!value) return -1;
        NSScanner *scanner=[NSScanner scannerWithString:value]; double number=0;
        return [scanner scanDouble:&number] && scanner.isAtEnd && isfinite(number) && number>=0 && number<=100?number:-1;
    }
    CFTypeRef info=IOPSCopyPowerSourcesInfo(); if (!info) return -1;
    NSArray *sources=CFBridgingRelease(IOPSCopyPowerSourcesList(info));
    double percentage=-1;
    for (id source in sources) {
        NSDictionary *description=(__bridge NSDictionary *)IOPSGetPowerSourceDescription(info,(__bridge CFTypeRef)source);
        if (![description[@kIOPSTypeKey] isEqual:@kIOPSInternalBatteryType]) continue;
        NSNumber *current=description[@kIOPSCurrentCapacityKey], *maximum=description[@kIOPSMaxCapacityKey];
        if (![current isKindOfClass:NSNumber.class] || ![maximum isKindOfClass:NSNumber.class]) continue;
        double c=current.doubleValue, m=maximum.doubleValue;
        if (isfinite(c) && isfinite(m) && m>0 && c>=0 && c<=m) percentage=100*c/m;
        break;
    }
    CFRelease(info); return percentage;
}
static NSInteger percentageOption(NSArray *args, NSString *flag, NSInteger fallback) {
    NSUInteger index=[args indexOfObject:flag];
    if (index==NSNotFound) return fallback;
    if (index+1>=args.count) return -1;
    NSScanner *scanner=[NSScanner scannerWithString:args[index+1]]; NSInteger number=0;
    return [scanner scanInteger:&number] && scanner.isAtEnd && number>=0 && number<=100?number:-1;
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
static NSXPCConnection *lidConnection;
static BOOL lidServiceCall(BOOL releasing, NSString **error) {
    double percentage=batteryPercentage();
    BOOL lowPower=lowPowerBelow>0 && !externalPower() && percentage>=0 && percentage<=lowPowerBelow;
    if (fake) return [@{@"released":@(releasing),@"closedLid":@(closedLid),@"lowPowerMode":@(lowPower)} writeToFile:[directory stringByAppendingPathComponent:@"test-helper-policy.plist"] atomically:YES];
    if (!lidConnection) {
        lidConnection=[[NSXPCConnection alloc] initWithMachServiceName:GUILLOTINE_LID_SERVICE options:NSXPCConnectionPrivileged];
        lidConnection.remoteObjectInterface=[NSXPCInterface interfaceWithProtocol:@protocol(GuillotineLidService)];
        [lidConnection setCodeSigningRequirement:GUILLOTINE_HELPER_REQUIREMENT];
        [lidConnection resume];
    }
    dispatch_semaphore_t done=dispatch_semaphore_create(0);
    __block BOOL ok=NO;
    __block NSString *failure=@"Closed-lid helper unavailable. Install and approve it in Settings.";
    id<GuillotineLidService> proxy=[lidConnection remoteObjectProxyWithErrorHandler:^(NSError *e){ failure=[@"Power helper unavailable or out of date. In Settings, Remove Helper, then Install Helper and approve it again. " stringByAppendingString:e.localizedDescription]; dispatch_semaphore_signal(done); }];
    void (^reply)(BOOL,NSString *)=^(BOOL success,NSString *message){ ok=success; failure=message; dispatch_semaphore_signal(done); };
    if (releasing) [proxy releaseWithReply:reply];
    else if (lowPowerBelow>0 || !closedLid) {
        [proxy renewWithBatteryAllowed:allowBattery closedLid:closedLid lowPowerMode:lowPower reply:reply];
    } else [proxy renewWithBatteryAllowed:allowBattery reply:reply];
    if (dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC))) ok=NO;
    if (releasing || !ok) { [lidConnection invalidate]; lidConnection=nil; }
    if (!ok && error) *error=failure;
    return ok;
}
static BOOL requestPanelPower(uint32_t state) {
    if (!fake) return setPanel(panel,state)==KERN_SUCCESS;
    NSString *path=[directory stringByAppendingPathComponent:@"test-panel-requests"];
    NSString *previous=[NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil] ?: @"";
    return [[previous stringByAppendingFormat:@"%u\n",state] writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
}
static BOOL restore(void) {
    BOOL ok=restoreAudio();
    if ([saved[@"panelOwned"] boolValue]) ok=requestPanelPower(1) && ok;
    NSDictionary *values=saved[@"keyboards"];
    for (NSString *key in values) {
        uint64_t kid=key.longLongValue;
        // A nonzero current value belongs to the user/OS and must not be overwritten.
        if (!fake && [keyboard brightnessForKeyboard:kid] <= 0.00001f)
            ok=[keyboard setBrightness:[values[key] floatValue] forKeyboard:kid] && ok;
    }
    // The shared private bit is touched only if this session changed a sleep-causing policy.
    if ([saved[@"lidOwned"] boolValue]) ok=(lidControl(NO)==KERN_SUCCESS) && ok;
    if ([saved[@"lidService"] boolValue]) ok=lidServiceCall(YES,NULL) && ok;
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
static void sleepCutout(NSString *cause) {
    if (finished) return; finished=YES;
    BOOL restored=restore();
    [[cause stringByAppendingString:@": controls restored; system sleep requested."] writeToFile:[directory stringByAppendingPathComponent:@"last-stop.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    if (fake) {
        [@"sleep" writeToFile:[directory stringByAppendingPathComponent:@"test-sleep-request"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
        emit([NSString stringWithFormat:@"STOP %@: restored before sleep request",cause]); exit(restored?0:3);
    }
    if (!powerConnection) powerConnection=IOPMFindPowerManagement(MACH_PORT_NULL);
    IOReturn result=IOPMSleepSystem(powerConnection);
    NSString *outcome=[NSString stringWithFormat:@"%@: restoration %@; sleep request %@ (0x%x).",cause,restored?@"succeeded":@"failed",result==KERN_SUCCESS?@"accepted":@"rejected",result];
    [outcome writeToFile:[directory stringByAppendingPathComponent:@"last-stop.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    emit([@"STOP " stringByAppendingString:outcome]);
    exit(restored && result==KERN_SUCCESS?0:3);
}
static void enforcePolicy(void) {
    if (externalPower()) return;
    if (tooHot()) sleepCutout(@"Thermal cutout");
    if (!allowBattery) finish(0,@"External power disconnected; battery use is disabled");
    double percentage=batteryPercentage();
    if (sleepBelow>0 && percentage>=0 && percentage<=sleepBelow)
        sleepCutout([NSString stringWithFormat:@"Battery cutoff (%.0f%%, threshold %ld%%)",percentage,(long)sleepBelow]);
}
static void powerChanged(void *context) { if (ready) enforcePolicy(); }
static BOOL maintainControls(NSString **error) {
    enforcePolicy();
    if (!applyAudio(error)) return NO;
    if (closedLid || lowPowerBelow>0 || [saved[@"lidService"] boolValue]) {
        saved[@"lidService"]=@YES;
        if (!saveJournal() || !lidServiceCall(NO,error)) {
            if (!*error) *error=@"Could not journal closed-lid helper ownership.";
            return NO;
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
    return YES;
}
static BOOL loadHardware(BOOL needsPanel, NSString **error) {
    if (fake) return YES;
#if !defined(__arm64__)
    *error=@"Panel power control requires an Apple Silicon MacBook."; return NO;
#else
    if (needsPanel) {
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
    }
    dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness",RTLD_NOW);
    keyboard=[[NSClassFromString(@"KeyboardBrightnessClient") alloc] init];
    if (![keyboard respondsToSelector:@selector(copyKeyboardBacklightIDs)] ||
        ![keyboard respondsToSelector:@selector(brightnessForKeyboard:)] ||
        ![keyboard respondsToSelector:@selector(setBrightness:forKeyboard:)]) {
        *error=@"Keyboard backlight API unavailable on this macOS version."; return NO;
    }
    return YES;
#endif
}
int main(int argc, char **argv) { @autoreleasepool {
    signal(SIGPIPE,SIG_IGN);
    NSArray *args=NSProcessInfo.processInfo.arguments;
    fake=[args containsObject:@"--test-guard"];
    allowBattery=[args containsObject:@"--allow-battery"];
    closedLid=[args containsObject:@"--closed-lid"];
    muteSpeakers=[args containsObject:@"--mute-speakers"];
    sleepBelow=percentageOption(args,@"--sleep-below",10);
    lowPowerBelow=percentageOption(args,@"--low-power-below",0);
    if (sleepBelow<0 || lowPowerBelow<0) { emit(@"ERROR Battery percentages must be 0 (off) through 100."); return 2; }
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
    saved=[[NSDictionary dictionaryWithContentsOfFile:journal] mutableCopy];
    // Recovery must restore recorded panel ownership, including journals from older builds.
    BOOL needsPanel=![args containsObject:@"--recover"] || [saved[@"panelOwned"] boolValue];
    if (!loadHardware(needsPanel,&error)) { emit([@"ERROR " stringByAppendingString:error]); return 2; }
    if (saved && !restore()) { emit(@"ERROR Previous hardware session could not be restored. Restart macOS or retry."); return 3; }
    if ([args containsObject:@"--recover"] || [args containsObject:@"--restore"]) {
        // Explicit rescue may power the panel on even with no remaining ownership
        // journal. Ordinary startup recovery never wakes an unowned display.
        if ([args containsObject:@"--restore"]) {
            BOOL restored=requestPanelPower(1);
            if (fake && restored) restored=[@"on" writeToFile:[directory stringByAppendingPathComponent:@"test-panel-on"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
            if (!restored) { emit(@"ERROR Could not power the built-in panel on."); return 3; }
        }
        emit(@"RECOVERED"); return 0;
    }
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
    if (!maintainControls(&error)) { emit([@"ERROR " stringByAppendingString:error]); finish(2,error); }
    // Panel power is a session transition, not a periodically enforced policy.
    // Repeated requests can compete with macOS lid and display wake transitions.
    // Ownership was journaled before this write so failures and crashes can restore it.
    if (!requestPanelPower(0)) {
        emit(@"ERROR macOS rejected built-in panel power control.");
        finish(2,@"Panel power control failed");
    }
    ready=YES; deadline=NSProcessInfo.processInfo.systemUptime+5;
    emit(@"READY");
    fcntl(STDIN_FILENO,F_SETFL,O_NONBLOCK);
    dispatch_source_t input=dispatch_source_create(DISPATCH_SOURCE_TYPE_READ,STDIN_FILENO,0,dispatch_get_main_queue());
    NSMutableData *pending=[NSMutableData data];
    dispatch_source_set_event_handler(input,^{
        char bytes[128]; ssize_t n=read(STDIN_FILENO,bytes,sizeof(bytes));
        if (n==0) finish(0,@"App disconnected");
        if (n>0) {
            [pending appendBytes:bytes length:(NSUInteger)n];
            if (pending.length>4096) finish(2,@"Invalid app lease message");
            for (;;) {
                const char *buffer=pending.bytes;
                const char *newline=memchr(buffer,'\n',pending.length);
                if (!newline) break;
                NSUInteger length=(NSUInteger)(newline-buffer);
                NSString *message=[[NSString alloc] initWithBytes:buffer length:length encoding:NSUTF8StringEncoding];
                [pending replaceBytesInRange:NSMakeRange(0,length+1) withBytes:NULL length:0];
                if (![message hasPrefix:@"renew"]) continue;
                if ([message containsString:@"battery=0"]) allowBattery=NO;
                else if ([message containsString:@"battery=1"]) allowBattery=YES;
                if ([message containsString:@"mute=0"]) muteSpeakers=NO;
                else if ([message containsString:@"mute=1"]) muteSpeakers=YES;
                for (NSString *token in [message componentsSeparatedByString:@" "]) {
                    BOOL sleepToken=[token hasPrefix:@"sleep="], lowToken=[token hasPrefix:@"lowpower="];
                    if (!sleepToken && !lowToken) continue;
                    NSInteger value=percentageOption(@[@"value",[[token componentsSeparatedByString:@"="] lastObject]],@"value",-1);
                    if (value<0) finish(2,@"Invalid battery percentage policy");
                    if (sleepToken) sleepBelow=value; else lowPowerBelow=value;
                }
                deadline=NSProcessInfo.processInfo.systemUptime+5;
                enforcePolicy();
                NSString *audioError=nil;
                if (!applyAudio(&audioError)) finish(2,audioError);
            }
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
        if (!maintainControls(&failure)) finish(2,failure);
    }];
    [[NSRunLoop mainRunLoop] run];
    return 0;
}}
